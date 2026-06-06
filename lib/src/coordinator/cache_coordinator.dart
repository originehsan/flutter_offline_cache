import 'dart:async';
import 'dart:developer';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
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
/// forceRevalidate intentionally absent — never store transient flags.
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

/// Main entry point for flutter_offline_cache.
///
/// Implements stale-while-revalidate caching with:
/// - Automatic TTL-based background revalidation
/// - Offline fallback via cached data
/// - Request deduplication
/// - App lifecycle awareness (pause/resume timers)
///
/// ## Basic usage
/// ```dart
/// final coordinator = CacheCoordinator();
/// await coordinator.initialize();
///
/// final stream = coordinator.cachedFetch<List<Post>>(
///   namespace: 'PostRepository',
///   key: 'all_posts',
///   networkFetcher: () => dio.get('/posts'),
///   fromJsonConverter: (json) => (json as List)
///       .map((e) => Post.fromJson(e))
///       .toList(),
/// );
/// ```
///
/// ## Lifecycle management
/// Call [attachFlutterLifecycle] to pause TTL timers when app
/// goes to background and resume when app comes back:
/// ```dart
/// await coordinator.initialize();
/// coordinator.attachFlutterLifecycle();
/// ```
class CacheCoordinator {
  final CacheConfig _cacheConfig;
  final CacheStore _cacheStore;
  final ConnectivityChecker _connectivityChecker;
  final DedupRegistry _dedupRegistry;
  final StateSnapshotRegistry _snapshotRegistry;

  final Map<String, BehaviorSubject<CacheState<dynamic>>>
      _activeBehaviorSubjectMap = {};
  final Map<String, _CacheFetcherConfig<dynamic>> _fetcherConfigMap = {};

  /// Tracks active pipeline ID per key.
  /// Emissions from superseded pipelines are discarded.
  final Map<String, int> _activePipelineIdMap = {};

  /// Tracks active subscription per key.
  /// Old subscription cancelled before starting new pipeline.
  final Map<String, StreamSubscription<dynamic>> _pipelineSubscriptionMap = {};

  /// One cancellable Timer per key for TTL auto-revalidation.
  final Map<String, Timer> _ttlTimerMap = {};

  /// Tracks exact deadline per key for accurate resume after background.
  /// Used to calculate remaining TTL when app resumes.
  final Map<String, DateTime> _ttlDeadlineMap = {};

  late final FetchPipeline _fetchPipeline;
  late final InvalidationHandler _invalidationHandler;

  bool _isInitialized = false;
  bool _isDisposed = false;
  bool _isAppActive = true;
  Completer<void>? _initializationCompleter;

  /// Flutter lifecycle listener — attached via [attachFlutterLifecycle].
  AppLifecycleListener? _lifecycleListener;

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
      final Completer<void> failedCompleter = _initializationCompleter!;
      _initializationCompleter = null;
      failedCompleter.completeError(error);
      rethrow;
    }
  }

  /// Attaches Flutter app lifecycle listener to pause and resume
  /// TTL revalidation timers based on app state.
  ///
  /// Call this once after [initialize]:
  /// ```dart
  /// await coordinator.initialize();
  /// coordinator.attachFlutterLifecycle();
  /// ```
  ///
  /// Only attaches if [CacheConfig.pauseRevalidationWhenBackgrounded]
  /// is true (default). Safe to call multiple times — subsequent
  /// calls are no-ops.
  ///
  /// This keeps the coordinator core pure Dart — Flutter lifecycle
  /// is opt-in via this method.
  void attachFlutterLifecycle() {
    if (!_cacheConfig.pauseRevalidationWhenBackgrounded) return;
    if (_lifecycleListener != null) return;
    if (_isDisposed) return;

    _lifecycleListener = AppLifecycleListener(
      onPause: _handleAppPaused,
      onDetach: _handleAppPaused,
      // Do NOT pause on inactive — iOS fires inactive frequently
      // during phone calls, app switcher, etc. causing visible flicker.
      onResume: _handleAppResumed,
      onRestart: _handleAppResumed,
    );

    _debugLog('📱 Flutter lifecycle listener attached');
  }

  /// Returns a typed stream of [CacheState] for the given cache key.
  /// Implements stale-while-revalidate.
  ///
  /// [ttl] — how long cached data is considered fresh.
  /// Pass [cacheForever] to never auto-revalidate.
  /// Pass [Duration.zero] for always-stale SWR behavior.
  /// Defaults to [CacheConfig.defaultTtl].
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

    // Resolve effective TTL using CacheConfig rules
    final Duration resolvedTtl =
        _cacheConfig.resolveEffectiveTtl(ttl) ?? cacheForever;

    _debugLog(
      '┌─────────────────────────────────────\n'
      '│ cachedFetch called\n'
      '│ namespace: $namespace key: $key\n'
      '│ forceRevalidate: $forceRevalidate\n'
      '│ subjectExists: ${_activeBehaviorSubjectMap.containsKey(namespacedCacheKey)}\n'
      '│ subjectClosed: ${_activeBehaviorSubjectMap[namespacedCacheKey]?.isClosed}\n'
      '│ ttl: ${CacheConfig.isForever(resolvedTtl) ? 'forever' : '${resolvedTtl.inSeconds}s'}\n'
      '└─────────────────────────────────────',
    );

    // Always update fetcher config with latest values
    _fetcherConfigMap[namespacedCacheKey] = _CacheFetcherConfig<T>(
      networkFetcher: networkFetcher,
      fromJsonConverter: fromJsonConverter,
      resolvedTtl: resolvedTtl,
      networkTimeout: networkTimeout,
    );

    // Subject created only here — never recreated elsewhere
    final BehaviorSubject<CacheState<dynamic>> behaviorSubject =
        _activeBehaviorSubjectMap.putIfAbsent(
      namespacedCacheKey,
      () {
        _debugLog('🆕 creating new BehaviorSubject for: $namespacedCacheKey');
        return BehaviorSubject<CacheState<dynamic>>();
      },
    );

    // Prevent duplicate pipelines from Riverpod re-evaluation.
    // CacheLoading and CacheRevalidating mean pipeline is actively
    // running even if subscription was already removed from map.
    final bool pipelineEffectivelyRunning =
        _pipelineSubscriptionMap.containsKey(namespacedCacheKey) ||
            (behaviorSubject.hasValue &&
                (behaviorSubject.value is CacheLoading<dynamic> ||
                    behaviorSubject.value is CacheRevalidating<dynamic>));

    if (forceRevalidate) {
      _cancelTtlTimer(namespacedCacheKey);
      _debugLog('🔄 forceRevalidate=true — starting new pipeline');
      _feedPipelineIntoSubject<T>(
        namespacedCacheKey: namespacedCacheKey,
        resolvedTtl: resolvedTtl,
        networkFetcher: networkFetcher,
        fromJsonConverter: fromJsonConverter,
        behaviorSubject: behaviorSubject,
        networkTimeout: networkTimeout,
        forceRevalidate: true,
      );
    } else if (!pipelineEffectivelyRunning) {
      _debugLog('▶️  no active pipeline — starting pipeline');
      _feedPipelineIntoSubject<T>(
        namespacedCacheKey: namespacedCacheKey,
        resolvedTtl: resolvedTtl,
        networkFetcher: networkFetcher,
        fromJsonConverter: fromJsonConverter,
        behaviorSubject: behaviorSubject,
        networkTimeout: networkTimeout,
        forceRevalidate: false,
      );
    } else {
      _debugLog(
        '♻️  pipeline effectively running — skipping\n'
        '   subscriptionInMap: ${_pipelineSubscriptionMap.containsKey(namespacedCacheKey)}\n'
        '   subjectState: ${behaviorSubject.hasValue ? behaviorSubject.value.runtimeType : "no value"}',
      );
    }

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

    _cancelTtlTimer(namespacedCacheKey);
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

    _cancelTtlTimer(namespacedCacheKey);
    await _invalidationHandler.invalidateSingleKey(namespacedCacheKey);
    _restartPipelineForKey(namespacedCacheKey: namespacedCacheKey);
  }

  /// Invalidates all cache entries.
  /// Call this on user logout.
  Future<void> invalidateAll() async {
    _assertUsable();

    _debugLog('🗑️  invalidateAll() called');

    for (final key in _ttlTimerMap.keys.toList()) {
      _cancelTtlTimer(key);
    }

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
    _isDisposed = true;

    _debugLog('♻️  CacheCoordinator disposing...');

    // Dispose lifecycle listener first
    _lifecycleListener?.dispose();
    _lifecycleListener = null;

    // Cancel all TTL timers — prevents revalidation after dispose
    for (final timer in _ttlTimerMap.values) {
      timer.cancel();
    }
    _ttlTimerMap.clear();
    _ttlDeadlineMap.clear();

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

  /// Called when app goes to background.
  /// Cancels all TTL timers and records remaining time per key.
  void _handleAppPaused() {
    if (_isDisposed) return;
    if (!_isAppActive) return;

    _isAppActive = false;
    _debugLog('📱 app paused — pausing all TTL timers');

    final DateTime now = DateTime.now();

    for (final key in _ttlTimerMap.keys.toList()) {
      final DateTime? deadline = _ttlDeadlineMap[key];
      if (deadline != null) {
        final Duration remaining = deadline.difference(now);
        // Store remaining time — used to reschedule on resume
        // If already past deadline store zero — fires immediately on resume
        _ttlDeadlineMap[key] = now.add(
          remaining.isNegative ? Duration.zero : remaining,
        );
      }
      _ttlTimerMap[key]?.cancel();
      _ttlTimerMap.remove(key);
    }
  }

  /// Called when app comes to foreground.
  /// Reschedules TTL timers with accurate remaining duration.
  void _handleAppResumed() {
    if (_isDisposed) return;
    if (_isAppActive) return;

    _isAppActive = true;
    _debugLog('📱 app resumed — resuming TTL timers');

    final DateTime now = DateTime.now();
    final List<String> keys = _ttlDeadlineMap.keys.toList();

    for (final key in keys) {
      final DateTime? deadline = _ttlDeadlineMap[key];
      final _CacheFetcherConfig<dynamic>? config = _fetcherConfigMap[key];

      if (deadline == null || config == null) continue;

      final Duration remaining = deadline.difference(now);

      if (remaining <= Duration.zero) {
        // TTL already expired while in background — revalidate immediately
        _ttlDeadlineMap.remove(key);
        _debugLog('⏰ TTL expired in background — revalidating: $key');
        _restartPipelineForKey(namespacedCacheKey: key);
      } else {
        // Reschedule with accurate remaining duration
        _ttlDeadlineMap.remove(key);
        _scheduleWithDeadline(key, remaining);
        _debugLog(
            '⏰ rescheduling TTL timer — ${remaining.inSeconds}s remaining for: $key');
      }
    }
  }

  /// Restarts pipeline for key using stored fetcher config.
  /// Never creates new subject — subject only created in cachedFetch.
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

    if (subject == null || subject.isClosed) {
      _debugLog(
          '⚠️  _restartPipelineForKey — no open subject for: $namespacedCacheKey');
      return;
    }

    _debugLog(
        '🔄 _restartPipelineForKey — reusing subject for: $namespacedCacheKey');

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
  void _feedPipelineIntoSubject<T>({
    required String namespacedCacheKey,
    required Duration resolvedTtl,
    required Future<Response<dynamic>> Function() networkFetcher,
    required T Function(dynamic json) fromJsonConverter,
    required BehaviorSubject<CacheState<dynamic>> behaviorSubject,
    Duration? networkTimeout,
    bool forceRevalidate = false,
  }) {
    final int thisPipelineId = _fetchPipeline.nextPipelineId();
    _activePipelineIdMap[namespacedCacheKey] = thisPipelineId;

    _debugLog(
      '▶️  _feedPipelineIntoSubject\n'
      '   key: $namespacedCacheKey\n'
      '   pipelineId: $thisPipelineId\n'
      '   forceRevalidate: $forceRevalidate',
    );

    _pipelineSubscriptionMap[namespacedCacheKey]?.cancel();
    _cancelTtlTimer(namespacedCacheKey);

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
            final int? activePipelineId =
                _activePipelineIdMap[namespacedCacheKey];
            if (activePipelineId != thisPipelineId) {
              _debugLog(
                '⏭️  onDone from superseded pipeline #$thisPipelineId — ignoring\n'
                '   active pipeline is #$activePipelineId',
              );
              return;
            }

            _pipelineSubscriptionMap.remove(namespacedCacheKey);
            _debugLog(
                '✅ pipeline #$thisPipelineId done for: $namespacedCacheKey');

            _scheduleTtlRevalidation(namespacedCacheKey);
          },
          cancelOnError: false,
        );

    _pipelineSubscriptionMap[namespacedCacheKey] = subscription;
  }

  /// Schedules TTL revalidation timer.
  /// Skips scheduling for [cacheForever] entries.
  /// Handles app-backgrounded state correctly.
  void _scheduleTtlRevalidation(String namespacedCacheKey) {
    if (_isDisposed) return;

    final _CacheFetcherConfig<dynamic>? config =
        _fetcherConfigMap[namespacedCacheKey];
    if (config == null) return;

    // cacheForever — no timer needed
    if (CacheConfig.isForever(config.resolvedTtl)) {
      _debugLog('♾️  cacheForever — no TTL timer for: $namespacedCacheKey');
      return;
    }

    // Duration.zero — always stale — revalidate on next event loop turn
    if (CacheConfig.isAlwaysStale(config.resolvedTtl)) {
      _debugLog('⚡ alwaysStale — scheduling immediate revalidation for: $namespacedCacheKey');
      _cancelTtlTimer(namespacedCacheKey);
      _ttlTimerMap[namespacedCacheKey] = Timer(Duration.zero, () {
        _ttlTimerMap.remove(namespacedCacheKey);
        if (_isDisposed) return;
        _restartPipelineForKey(namespacedCacheKey: namespacedCacheKey);
      });
      return;
    }

    // App is in background — store deadline for accurate resume
    if (!_isAppActive && _cacheConfig.pauseRevalidationWhenBackgrounded) {
      _ttlDeadlineMap[namespacedCacheKey] =
          DateTime.now().add(config.resolvedTtl);
      _debugLog(
          '📱 app in background — storing TTL deadline for: $namespacedCacheKey');
      return;
    }

    _scheduleWithDeadline(namespacedCacheKey, config.resolvedTtl);
  }

  /// Schedules Timer with given duration and records deadline.
  void _scheduleWithDeadline(
      String namespacedCacheKey, Duration duration) {
    _cancelTtlTimer(namespacedCacheKey);

    _ttlDeadlineMap[namespacedCacheKey] =
        DateTime.now().add(duration);

    _debugLog(
        '⏰ scheduling TTL revalidation in ${duration.inSeconds}s for: $namespacedCacheKey');

    _ttlTimerMap[namespacedCacheKey] = Timer(duration, () {
      _ttlTimerMap.remove(namespacedCacheKey);
      _ttlDeadlineMap.remove(namespacedCacheKey);
      if (_isDisposed) return;
      final BehaviorSubject<CacheState<dynamic>>? subject =
          _activeBehaviorSubjectMap[namespacedCacheKey];
      if (subject == null || subject.isClosed) return;
      _debugLog('⏰ TTL expired — auto-revalidating: $namespacedCacheKey');
      _restartPipelineForKey(namespacedCacheKey: namespacedCacheKey);
    });
  }

  /// Cancels and removes TTL timer and deadline for key.
  void _cancelTtlTimer(String namespacedCacheKey) {
    _ttlTimerMap.remove(namespacedCacheKey)?.cancel();
    _ttlDeadlineMap.remove(namespacedCacheKey);
  }

  /// Maps BehaviorSubject<CacheState<dynamic to typed
  /// Stream<CacheState<T using safe rehydration.
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
  T _coerceOrConvert<T>(
    dynamic value,
    T Function(dynamic json) fromJsonConverter,
  ) {
    if (value is T) return value;
    return fromJsonConverter(value);
  }

  /// Checks disposed BEFORE initialized.
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