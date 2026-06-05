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

class _CacheFetcherConfig<T> {
  final Future<Response<dynamic>> Function() networkFetcher;
  final T Function(dynamic json) fromJsonConverter;
  final Duration resolvedTtl;
  final bool forceRevalidate;

  const _CacheFetcherConfig({
    required this.networkFetcher,
    required this.fromJsonConverter,
    required this.resolvedTtl,
    this.forceRevalidate = false,
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

  Future<void> initialize() async {
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
      _initializationCompleter!.completeError(error);
      _initializationCompleter = null;
      rethrow;
    }
  }

  Stream<CacheState<T>> cachedFetch<T>({
    required String namespace,
    required String key,
    required Future<Response<dynamic>> Function() networkFetcher,
    required T Function(dynamic json) fromJsonConverter,
    Duration? ttl,
    Duration? networkTimeout,
    bool forceRevalidate = false,
  }) {
    _assertInitialized();
    _assertNotDisposed();

    final String namespacedCacheKey = KeyBuilder.build(namespace, key);
    final Duration resolvedTtl = ttl ?? _cacheConfig.defaultTtl;

    final bool subjectExists =
        _activeBehaviorSubjectMap.containsKey(namespacedCacheKey);
    final bool subjectClosed =
        _activeBehaviorSubjectMap[namespacedCacheKey]?.isClosed ?? true;

    _debugLog(
      '┌─────────────────────────────────────\n'
      '│ cachedFetch called\n'
      '│ namespace: $namespace\n'
      '│ key: $key\n'
      '│ forceRevalidate: $forceRevalidate\n'
      '│ subjectExists: $subjectExists\n'
      '│ subjectClosed: $subjectClosed\n'
      '│ ttl: ${resolvedTtl.inSeconds}s\n'
      '└─────────────────────────────────────',
    );

    _fetcherConfigMap[namespacedCacheKey] = _CacheFetcherConfig<T>(
      networkFetcher: networkFetcher,
      fromJsonConverter: fromJsonConverter,
      resolvedTtl: resolvedTtl,
      forceRevalidate: forceRevalidate,
    );

    if (forceRevalidate) {
      final existing = _activeBehaviorSubjectMap[namespacedCacheKey];
      if (existing != null && !existing.isClosed) {
        _debugLog(
          '🔄 forceRevalidate=true — existing subject OPEN\n'
          '   restarting pipeline into same subject\n'
          '   subscribers will see CacheRevalidating immediately',
        );
        _feedPipelineIntoSubject<T>(
          namespacedCacheKey: namespacedCacheKey,
          resolvedTtl: resolvedTtl,
          networkFetcher: networkFetcher,
          fromJsonConverter: fromJsonConverter,
          behaviorSubject: existing,
          networkTimeout: networkTimeout,
          forceRevalidate: true,
        );
        return existing.stream.cast<CacheState<T>>();
      }
      _debugLog(
        '🔄 forceRevalidate=true — no open subject found\n'
        '   creating new subject and pipeline',
      );
      _activeBehaviorSubjectMap.remove(namespacedCacheKey);
    }

    if (_activeBehaviorSubjectMap.containsKey(namespacedCacheKey)) {
      final existing = _activeBehaviorSubjectMap[namespacedCacheKey]!;
      if (!existing.isClosed) {
        _debugLog('♻️  returning existing open subject — no new pipeline');
        return existing.stream.cast<CacheState<T>>();
      }
      _activeBehaviorSubjectMap.remove(namespacedCacheKey);
    }

    _debugLog('🆕 creating new BehaviorSubject and starting pipeline');

    final BehaviorSubject<CacheState<dynamic>> behaviorSubject =
        BehaviorSubject<CacheState<dynamic>>();

    _activeBehaviorSubjectMap[namespacedCacheKey] = behaviorSubject;

    _feedPipelineIntoSubject<T>(
      namespacedCacheKey: namespacedCacheKey,
      resolvedTtl: resolvedTtl,
      networkFetcher: networkFetcher,
      fromJsonConverter: fromJsonConverter,
      behaviorSubject: behaviorSubject,
      networkTimeout: networkTimeout,
      forceRevalidate: forceRevalidate,
    );

    return behaviorSubject.stream.cast<CacheState<T>>();
  }

  Future<void> refresh({
    required String namespace,
    required String key,
    Duration? networkTimeout,
  }) async {
    _assertInitialized();
    _assertNotDisposed();

    final String namespacedCacheKey = KeyBuilder.build(namespace, key);

    _debugLog('🔃 refresh() called for key: $namespacedCacheKey');

    await _snapshotRegistry.removeStateForKey(namespacedCacheKey);

    _restartPipelineForKey(
      namespacedCacheKey: namespacedCacheKey,
      networkTimeout: networkTimeout,
      forceRevalidate: true,
    );
  }

  Future<void> invalidate({
    required String namespace,
    required String key,
  }) async {
    _assertInitialized();
    _assertNotDisposed();

    final String namespacedCacheKey = KeyBuilder.build(namespace, key);

    _debugLog('🗑️  invalidate() called for key: $namespacedCacheKey');

    await _invalidationHandler.invalidateSingleKey(namespacedCacheKey);
    _restartPipelineForKey(namespacedCacheKey: namespacedCacheKey);
  }

  Future<void> invalidateAll() async {
    _assertInitialized();
    _assertNotDisposed();

    _debugLog('🗑️  invalidateAll() called');

    await _invalidationHandler.invalidateAllKeys();

    final List<String> activeKeys =
        List.from(_activeBehaviorSubjectMap.keys);
    for (final activeKey in activeKeys) {
      _restartPipelineForKey(namespacedCacheKey: activeKey);
    }
  }

  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;

    _debugLog('♻️  CacheCoordinator disposing...');

    for (final subject in _activeBehaviorSubjectMap.values) {
      if (!subject.isClosed) subject.close();
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
          '⚠️  _restartPipelineForKey — no config found for: $namespacedCacheKey');
      return;
    }

    final BehaviorSubject<CacheState<dynamic>> activeSubject =
        (subject == null || subject.isClosed)
            ? BehaviorSubject<CacheState<dynamic>>()
            : subject;

    if (subject == null || subject.isClosed) {
      _activeBehaviorSubjectMap[namespacedCacheKey] = activeSubject;
      _debugLog(
          '🆕 _restartPipelineForKey — created new subject for: $namespacedCacheKey');
    } else {
      _debugLog(
          '🔄 _restartPipelineForKey — reusing existing subject for: $namespacedCacheKey');
    }

    _feedPipelineIntoSubject(
      namespacedCacheKey: namespacedCacheKey,
      resolvedTtl: config.resolvedTtl,
      networkFetcher: config.networkFetcher,
      fromJsonConverter: config.fromJsonConverter,
      behaviorSubject: activeSubject,
      networkTimeout: networkTimeout,
      forceRevalidate: forceRevalidate,
    );
  }

  void _feedPipelineIntoSubject<T>({
    required String namespacedCacheKey,
    required Duration resolvedTtl,
    required Future<Response<dynamic>> Function() networkFetcher,
    required T Function(dynamic json) fromJsonConverter,
    required BehaviorSubject<CacheState<dynamic>> behaviorSubject,
    Duration? networkTimeout,
    bool forceRevalidate = false,
  }) {
    _debugLog(
      '▶️  _feedPipelineIntoSubject\n'
      '   key: $namespacedCacheKey\n'
      '   forceRevalidate: $forceRevalidate',
    );

    _fetchPipeline
        .executeFetchPipeline<T>(
          cacheKey: namespacedCacheKey,
          ttl: resolvedTtl,
          networkFetcher: networkFetcher,
          fromJsonConverter: fromJsonConverter,
          networkTimeout: networkTimeout,
          forceRevalidate: forceRevalidate,
        )
        .listen(
          (CacheState<T> state) {
            if (_isDisposed) return;
            if (!behaviorSubject.isClosed) {
              _debugLog(
                  '📡 subject.add(${state.runtimeType}) for: $namespacedCacheKey');
              behaviorSubject.add(state);
            } else {
              _debugLog(
                  '⚠️  tried to emit ${state.runtimeType} but subject is closed');
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            if (_isDisposed) return;
            if (!behaviorSubject.isClosed) {
              _debugLog('❌ subject.addError: $error');
              behaviorSubject.addError(error, stackTrace);
            }
          },
          onDone: () {
            _debugLog(
                '✅ pipeline done for key: $namespacedCacheKey — subject kept alive');
          },
        );
  }

  void _assertInitialized() {
    if (!_isInitialized) {
      throw StateError(
        'CacheCoordinator: Not initialized. '
        'Always await initialize() before calling cachedFetch().',
      );
    }
  }

  void _assertNotDisposed() {
    if (_isDisposed) {
      throw StateError(
        'CacheCoordinator: Already disposed. '
        'Create a new CacheCoordinator instance.',
      );
    }
  }

  void _debugLog(String message) {
    if (_cacheConfig.enableDebugLogs && kDebugMode) {
      log(message, name: 'FOC');
    }
  }
}