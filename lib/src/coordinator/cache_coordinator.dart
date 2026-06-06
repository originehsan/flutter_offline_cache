import 'dart:async';
import 'dart:developer';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:rxdart/rxdart.dart';
import '../models/cache_state.dart';
import '../models/cache_config.dart';
import '../store/cache_store.dart';
import '../store/hive_cache_store.dart';
import '../network/connectivity_checker.dart';
import '../network/default_connectivity_checker.dart';
import '../network/dedup_registry.dart';
import '../utils/key_builder.dart';
import 'fetch_pipeline.dart';
import 'state_snapshot_registry.dart';
import 'invalidation_handler.dart';

/// Holds stable fetcher configuration per cache key.
/// Bug 3 fix — forceRevalidate removed entirely.
/// Never store transient intent flags in long-lived config.
class _CacheFetcherConfig<T> {
  final Future<Response<dynamic>> Function() networkFetcher;
  final T Function(dynamic json) fromJsonConverter;
  final Duration resolvedTtl;
  final Duration? networkTimeout;

  const _CacheFetcherConfig({
    required this.networkFetcher,
    required this.fromJsonConverter,
    required this.resolvedTtl,
    this.networkTimeout,
  });
}

class CacheCoordinator {
  final CacheConfig _cacheConfig;
  final CacheStore _cacheStore;
  final ConnectivityChecker _connectivityChecker;
  final DedupRegistry _dedupRegistry;
  final StateSnapshotRegistry _snapshotRegistry;

  final Map<String, BehaviorSubject<CacheState<dynamic>>>
      _activeBehaviorSubjectMap = {};
  final Map<String, _CacheFetcherConfig<dynamic>> _fetcherConfigMap = {};

  /// Bug 2 fix — tracks active pipeline ID per key.
  /// Emissions from superseded pipelines are discarded.
  final Map<String, int> _activePipelineIdMap = {};

  /// Bug 2 fix — tracks active subscription per key.
  /// Old subscription cancelled before starting new pipeline.
  final Map<String, StreamSubscription<dynamic>> _pipelineSubscriptionMap = {};

  late final FetchPipeline _fetchPipeline;
  late final InvalidationHandler _invalidationHandler;

  bool _isInitialized = false;
  bool _isDisposed = false;
  Completer<void>? _initializationCompleter;

  CacheCoordinator({
    CacheConfig? cacheConfig,
    CacheStore? cacheStore,
    ConnectivityChecker? connectivityChecker,
  })  : _cacheConfig = cacheConfig ?? const CacheConfig(),
        _cacheStore = cacheStore ??
            HiveCacheStore(
              cacheConfig: cacheConfig ?? const CacheConfig(),
            ),
        _connectivityChecker =
            connectivityChecker ?? DefaultConnectivityChecker(),
        _dedupRegistry = DedupRegistry(),
        _snapshotRegistry = StateSnapshotRegistry() {
    _fetchPipeline = FetchPipeline(
      cacheStore: _cacheStore,
      dedupRegistry: _dedupRegistry,
      snapshotRegistry: _snapshotRegistry,
      cacheConfig: _cacheConfig,
    );
    _invalidationHandler = InvalidationHandler(
      cacheStore: _cacheStore,
      snapshotRegistry: _snapshotRegistry,
      activeBehaviorSubjectMap: _activeBehaviorSubjectMap,
      enableDebugLogs: _cacheConfig.enableDebugLogs,
    );
  }

  /// Initializes coordinator and opens Hive storage box.
  /// Must be called and awaited before any [cachedFetch] call.
  /// Safe to call multiple times — subsequent calls are no-ops.
  /// Thread safe — concurrent calls wait for first to complete.
  Future<void> initialize() async {
    // Bug 7 fix — check disposed before initialized
    if (_isDisposed) {
      throw StateError(
        'CacheCoordinator: Already disposed. '
        'Create a new CacheCoordinator instance.',
      );
    }

    if (_isInitialized) return;

    if (_initializationCompleter != null) {
      return _initializationCompleter!.future;
    }

    _initializationCompleter = Completer<void>();

    try {
      await _cacheStore.initializeStorage();
      _isInitialized = true;
      _initializationCompleter!.complete();
      _debugLog('✅ CacheCoordinator initialized');
    } catch (error) {
      // Bug 6 fix — null completer BEFORE completeError
      // so concurrent callers can retry after failure
      final Completer<void> failedCompleter = _initializationCompleter!;
      _initializationCompleter = null;
      failedCompleter.completeError(error);
      rethrow;
    }
  }

  /// Returns a typed stream of [CacheState] for the given cache key.
  /// Implements stale-while-revalidate.
  ///
  /// Bug 1 fix — returns _rehydratedStream instead of .cast()
  /// Bug 3 fix — forceRevalidate passed as runtime param, not stored
  /// Bug 4 fix — subject created once, never recreated
  Stream<CacheState<T>> cachedFetch<T>({
    required String namespace,
    required String key,
    required Future<Response<dynamic>> Function() networkFetcher,
    required T Function(dynamic json) fromJsonConverter,
    Duration? ttl,
    Duration? networkTimeout,
    bool forceRevalidate = false,
  }) {
    _assertUsable();

    final String namespacedCacheKey = KeyBuilder.build(namespace, key);
    final Duration resolvedTtl = ttl ?? _cacheConfig.defaultTtl;

    _debugLog(
      '┌─────────────────────────────────────\n'
      '│ cachedFetch called\n'
      '│ namespace: $namespace key: $key\n'
      '│ forceRevalidate: $forceRevalidate\n'
      '│ subjectExists: ${_activeBehaviorSubjectMap.containsKey(namespacedCacheKey)}\n'
      '│ subjectClosed: ${_activeBehaviorSubjectMap[namespacedCacheKey]?.isClosed}\n'
      '│ ttl: ${resolvedTtl.inSeconds}s\n'
      '└─────────────────────────────────────',
    );

    // Always update fetcher config with latest values
    // Bug 3 fix — forceRevalidate NOT stored in config
    _fetcherConfigMap[namespacedCacheKey] = _CacheFetcherConfig<T>(
      networkFetcher: networkFetcher,
      fromJsonConverter: fromJsonConverter,
      resolvedTtl: resolvedTtl,
      networkTimeout: networkTimeout,
    );

    // Bug 4 fix — subject created only here, never in _restartPipelineForKey
    final BehaviorSubject<CacheState<dynamic>> behaviorSubject =
        _activeBehaviorSubjectMap.putIfAbsent(
      namespacedCacheKey,
      () {
        _debugLog('🆕 creating new BehaviorSubject for: $namespacedCacheKey');
        return BehaviorSubject<CacheState<dynamic>>();
      },
    );

    // If forceRevalidate or no pipeline running — start pipeline
    final bool pipelineAlreadyRunning =
        _pipelineSubscriptionMap.containsKey(namespacedCacheKey);

    if (forceRevalidate || !pipelineAlreadyRunning) {
      _debugLog(
        forceRevalidate
            ? '🔄 forceRevalidate=true — starting new pipeline'
            : '▶️  no active pipeline — starting pipeline',
      );
      _feedPipelineIntoSubject<T>(
        namespacedCacheKey: namespacedCacheKey,
        resolvedTtl: resolvedTtl,
        networkFetcher: networkFetcher,
        fromJsonConverter: fromJsonConverter,
        behaviorSubject: behaviorSubject,
        networkTimeout: networkTimeout,
        forceRevalidate: forceRevalidate,
      );
    } else {
      _debugLog('♻️  pipeline already running — returning existing subject');
    }

    // Bug 1 fix — rehydrate stream instead of cast
    return _rehydratedStream<T>(behaviorSubject, fromJsonConverter);
  }

  /// Force-refreshes cache for given key.
  /// Bypasses TTL — triggers network fetch regardless of freshness.
  Future<void> refresh({
    required String namespace,
    required String key,
    Duration? networkTimeout,
  }) async {
    _assertUsable();

    final String namespacedCacheKey = KeyBuilder.build(namespace, key);
    _debugLog('🔃 refresh() called for key: $namespacedCacheKey');

    _restartPipelineForKey(
      namespacedCacheKey: namespacedCacheKey,
      networkTimeout: networkTimeout,
      forceRevalidate: true,
    );
  }

  /// Invalidates cache entry for given key.
  /// Deletes cached data and restarts pipeline.
  Future<void> invalidate({
    required String namespace,
    required String key,
  }) async {
    _assertUsable();

    final String namespacedCacheKey = KeyBuilder.build(namespace, key);
    _debugLog('🗑️  invalidate() called for key: $namespacedCacheKey');

    await _invalidationHandler.invalidateSingleKey(namespacedCacheKey);
    _restartPipelineForKey(namespacedCacheKey: namespacedCacheKey);
  }

  /// Invalidates all cache entries.
  /// Call this on user logout.
  Future<void> invalidateAll() async {
    _assertUsable();

    _debugLog('🗑️  invalidateAll() called');

    await _invalidationHandler.invalidateAllKeys();

    final List<String> activeKeys =
        List.from(_activeBehaviorSubjectMap.keys);
    for (final activeKey in activeKeys) {
      _restartPipelineForKey(namespacedCacheKey: activeKey);
    }
  }

  /// Disposes all resources.
  /// Safe to call multiple times — subsequent calls are no-ops.
  Future<void> dispose() async {
    if (_isDisposed) return;

    // Bug 7 fix — set disposed before closing subjects
    _isDisposed = true;

    _debugLog('♻️  CacheCoordinator disposing...');

    // Cancel all active pipeline subscriptions
    for (final subscription in _pipelineSubscriptionMap.values) {
      await subscription.cancel();
    }
    _pipelineSubscriptionMap.clear();
    _activePipelineIdMap.clear();

    // Close all active subjects
    for (final subject in _activeBehaviorSubjectMap.values) {
      if (!subject.isClosed) await subject.close();
    }
    _activeBehaviorSubjectMap.clear();
    _fetcherConfigMap.clear();

    await _dedupRegistry.cancelAllInFlightRequests();
    await _connectivityChecker.disposeConnectivityResources();
    await _snapshotRegistry.removeAllStates();
    await _cacheStore.disposeStorage();

    _isInitialized = false;
    _debugLog('✅ CacheCoordinator disposed');
  }

  /// Restarts pipeline for key using stored fetcher config.
  /// Bug 4 fix — NEVER creates new subject here.
  /// Returns early if no subject or config exists.
  void _restartPipelineForKey({
    required String namespacedCacheKey,
    Duration? networkTimeout,
    bool forceRevalidate = false,
  }) {
    final BehaviorSubject<CacheState<dynamic>>? subject =
        _activeBehaviorSubjectMap[namespacedCacheKey];
    final _CacheFetcherConfig<dynamic>? config =
        _fetcherConfigMap[namespacedCacheKey];

    if (config == null) {
      _debugLog(
          '⚠️  _restartPipelineForKey — no config for: $namespacedCacheKey');
      return;
    }

    // Bug 4 fix — if no subject exists, nothing to restart
    // Subject only created in cachedFetch
    if (subject == null || subject.isClosed) {
      _debugLog(
          '⚠️  _restartPipelineForKey — no open subject for: $namespacedCacheKey');
      return;
    }

    _debugLog(
        '🔄 _restartPipelineForKey — reusing existing subject for: $namespacedCacheKey');

    _feedPipelineIntoSubject(
      namespacedCacheKey: namespacedCacheKey,
      resolvedTtl: config.resolvedTtl,
      networkFetcher: config.networkFetcher,
      fromJsonConverter: config.fromJsonConverter,
      behaviorSubject: subject,
      networkTimeout: networkTimeout ?? config.networkTimeout,
      forceRevalidate: forceRevalidate,
    );
  }

  /// Starts pipeline and feeds emissions into subject.
  /// Bug 2 fix — assigns pipeline ID per key.
  /// Discards emissions from superseded pipelines.
  /// Cancels previous subscription before starting new one.
  void _feedPipelineIntoSubject<T>({
    required String namespacedCacheKey,
    required Duration resolvedTtl,
    required Future<Response<dynamic>> Function() networkFetcher,
    required T Function(dynamic json) fromJsonConverter,
    required BehaviorSubject<CacheState<dynamic>> behaviorSubject,
    Duration? networkTimeout,
    bool forceRevalidate = false,
  }) {
    // Bug 2 fix — get next pipeline ID from instance counter
    final int thisPipelineId = _fetchPipeline.nextPipelineId();
    _activePipelineIdMap[namespacedCacheKey] = thisPipelineId;

    _debugLog(
      '▶️  _feedPipelineIntoSubject\n'
      '   key: $namespacedCacheKey\n'
      '   pipelineId: $thisPipelineId\n'
      '   forceRevalidate: $forceRevalidate',
    );

    // Bug 2 fix — cancel previous subscription before starting new one
    _pipelineSubscriptionMap[namespacedCacheKey]?.cancel();

    final StreamSubscription<CacheState<T>> subscription = _fetchPipeline
        .executeFetchPipeline<T>(
          cacheKey: namespacedCacheKey,
          ttl: resolvedTtl,
          networkFetcher: networkFetcher,
          fromJsonConverter: fromJsonConverter,
          networkTimeout: networkTimeout,
          forceRevalidate: forceRevalidate,
          pipelineId: thisPipelineId,
        )
        .listen(
          (CacheState<T> state) {
            if (_isDisposed) return;

            // Bug 2 fix — discard emissions from superseded pipelines
            final int? activePipelineId =
                _activePipelineIdMap[namespacedCacheKey];
            if (activePipelineId != thisPipelineId) {
              _debugLog(
                '⏭️  discarding emission from superseded pipeline '
                '#$thisPipelineId (active: #$activePipelineId)',
              );
              return;
            }

            if (!behaviorSubject.isClosed) {
              _debugLog(
                  '📡 subject.add(${state.runtimeType}) pipeline #$thisPipelineId');
              behaviorSubject.add(state);
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            if (_isDisposed) return;

            final int? activePipelineId =
                _activePipelineIdMap[namespacedCacheKey];
            if (activePipelineId != thisPipelineId) return;

            if (!behaviorSubject.isClosed) {
              _debugLog('❌ pipeline #$thisPipelineId addError: $error');
              behaviorSubject.addError(error, stackTrace);
            }
          },
          onDone: () {
            // Clean up subscription map when pipeline completes
            _pipelineSubscriptionMap.remove(namespacedCacheKey);
            _debugLog(
                '✅ pipeline #$thisPipelineId done for: $namespacedCacheKey');
          },
          cancelOnError: false,
        );

    _pipelineSubscriptionMap[namespacedCacheKey] = subscription;
  }

  /// Bug 1 fix — maps BehaviorSubject_CacheState_dynamic to
  /// typed StreamCacheStateT using safe rehydration.
  /// Never uses .cast() — rehydrates each state individually.
  Stream<CacheState<T>> _rehydratedStream<T>(
    BehaviorSubject<CacheState<dynamic>> subject,
    T Function(dynamic json) fromJsonConverter,
  ) {
    return subject.stream.map((CacheState<dynamic> state) {
      return switch (state) {
        CacheSuccess<dynamic>(
          :final cachedData,
          :final dataSource,
          :final entryMetadata,
        ) =>
          CacheSuccess<T>(
            cachedData: _coerceOrConvert<T>(cachedData, fromJsonConverter),
            dataSource: dataSource,
            entryMetadata: entryMetadata,
          ),
        CacheRevalidating<dynamic>(
          :final cachedData,
          :final entryMetadata,
        ) =>
          CacheRevalidating<T>(
            cachedData: _coerceOrConvert<T>(cachedData, fromJsonConverter),
            entryMetadata: entryMetadata,
          ),
        CacheStale<dynamic>(
          :final cachedData,
          :final refreshError,
          :final refreshErrorStackTrace,
        ) =>
          CacheStale<T>(
            cachedData: _coerceOrConvert<T>(cachedData, fromJsonConverter),
            refreshError: refreshError,
            refreshErrorStackTrace: refreshErrorStackTrace,
          ),
        CacheLoading<dynamic>() => CacheLoading<T>(),
        CacheInitial<dynamic>() => CacheInitial<T>(),
        CacheError<dynamic>(
          :final networkError,
          :final errorClassification,
          :final networkErrorStackTrace,
        ) =>
          CacheError<T>(
            networkError: networkError,
            errorClassification: errorClassification,
            networkErrorStackTrace: networkErrorStackTrace,
          ),
      };
    });
  }

  /// Returns value directly if already typed as T.
  /// Only calls fromJsonConverter if value is raw JSON.
  /// Prevents double-conversion crash when cached data is
  /// already typed from a previous emission.
  T _coerceOrConvert<T>(
    dynamic value,
    T Function(dynamic json) fromJsonConverter,
  ) {
    if (value is T) return value;
    return fromJsonConverter(value);
  }

  /// Bug 7 fix — checks disposed BEFORE initialized.
  /// Gives correct error message for each lifecycle state.
  void _assertUsable() {
    if (_isDisposed) {
      throw StateError(
        'CacheCoordinator: Already disposed. '
        'Create a new CacheCoordinator instance.',
      );
    }
    if (!_isInitialized) {
      throw StateError(
        'CacheCoordinator: Not initialized. '
        'Always await initialize() before calling cachedFetch(). '
        'Example: await coordinator.initialize();',
      );
    }
  }

  void _debugLog(String message) {
    if (_cacheConfig.enableDebugLogs && kDebugMode) {
      log(message, name: 'FOC');
    }
  }
}