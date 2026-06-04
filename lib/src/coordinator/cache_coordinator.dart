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

/// Holds the fetcher configuration for a single cache key.
/// Used to restart pipelines after invalidation.
class _CacheFetcherConfig<T> {
  final Future<Response<dynamic>> Function() networkFetcher;
  final T Function(dynamic json) fromJsonConverter;
  final Duration resolvedTtl;

  const _CacheFetcherConfig({
    required this.networkFetcher,
    required this.fromJsonConverter,
    required this.resolvedTtl,
  });
}

/// The main entry point for flutter_offline_cache.
/// Wires all internal components together and exposes a clean public API.
///
/// ## Usage
/// ```dart
/// final coordinator = CacheCoordinator();
/// await coordinator.initialize(); // must await this
///
/// Stream<CacheState<List<Movie>>> stream = coordinator.cachedFetch(
///   namespace: 'MovieRepository',
///   key: 'movies',
///   ttl: Duration(minutes: 10),
///   networkFetcher: () => dio.get('/movies'),
///   fromJsonConverter: (json) => (json as List)
///       .map((e) => Movie.fromJson(e))
///       .toList(),
/// );
/// ```
///
/// ## Important
/// Always `await coordinator.initialize()` before calling [cachedFetch].
/// Failing to await will throw a [StateError].
class CacheCoordinator {
  final CacheConfig _cacheConfig;
  final CacheStore _cacheStore;
  final ConnectivityChecker _connectivityChecker;
  final DedupRegistry _dedupRegistry;
  final StateSnapshotRegistry _snapshotRegistry;

  /// Active BehaviorSubjects per namespaced cache key.
  final Map<String, BehaviorSubject<CacheState<dynamic>>>
      _activeBehaviorSubjectMap = {};

  /// Fetcher configs per namespaced cache key.
  /// Used to restart pipelines after invalidation.
  final Map<String, _CacheFetcherConfig<dynamic>> _fetcherConfigMap = {};

  late final FetchPipeline _fetchPipeline;
  late final InvalidationHandler _invalidationHandler;

  bool _isInitialized = false;
  bool _isDisposed = false;

  /// Completer used to prevent concurrent double initialization.
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

  /// Initializes the coordinator and opens the Hive storage box.
  /// Must be called and awaited before any [cachedFetch] call.
  /// Safe to call multiple times — subsequent calls are no-ops.
  /// Thread safe — concurrent calls wait for first initialization to complete.
  Future<void> initialize() async {
    if (_isInitialized) return;

    // Bug 8 fix — prevent concurrent double initialization
    if (_initializationCompleter != null) {
      return _initializationCompleter!.future;
    }

    _initializationCompleter = Completer<void>();

    try {
      await _cacheStore.initializeStorage();
      _isInitialized = true;
      _initializationCompleter!.complete();
      _debugLog('CacheCoordinator initialized.');
    } catch (error) {
      _initializationCompleter!.completeError(error);
      _initializationCompleter = null;
      rethrow;
    }
  }

  /// Returns a [Stream] of [CacheState] for the given cache key.
  /// Implements stale-while-revalidate — serves cache immediately,
  /// revalidates in background, updates stream when fresh data arrives.
  ///
  /// [namespace] — groups keys by repository. Use your repository class name.
  /// [key] — unique identifier for this data within the namespace.
  /// [ttl] — how long cached data is considered fresh. Overrides config default.
  /// [networkFetcher] — Dio request function for this endpoint.
  /// [fromJsonConverter] — converts Dio response JSON to your domain type [T].
  /// [networkTimeout] — max time to wait for network. Defaults to 30 seconds.
  Stream<CacheState<T>> cachedFetch<T>({
    required String namespace,
    required String key,
    required Future<Response<dynamic>> Function() networkFetcher,
    required T Function(dynamic json) fromJsonConverter,
    Duration? ttl,
    Duration? networkTimeout,
  }) {
    _assertInitialized();
    _assertNotDisposed();

    final String namespacedCacheKey = KeyBuilder.build(namespace, key);
    final Duration resolvedTtl = ttl ?? _cacheConfig.defaultTtl;

    // Bug 5 fix — always update fetcher config on each call
    // so latest converter and fetcher are used on next pipeline restart
    _fetcherConfigMap[namespacedCacheKey] = _CacheFetcherConfig<T>(
      networkFetcher: networkFetcher,
      fromJsonConverter: fromJsonConverter,
      resolvedTtl: resolvedTtl,
    );

    // Bug 6 fix — check isClosed before returning existing subject
    if (_activeBehaviorSubjectMap.containsKey(namespacedCacheKey)) {
      final existing = _activeBehaviorSubjectMap[namespacedCacheKey]!;
      if (!existing.isClosed) {
        return existing.stream.cast<CacheState<T>>();
      }
      // Subject closed — remove and create fresh one below
      _activeBehaviorSubjectMap.remove(namespacedCacheKey);
    }

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
    );

    return behaviorSubject.stream.cast<CacheState<T>>();
  }

  /// Force-refreshes the cache for the given [namespace] and [key].
  /// Bypasses TTL — triggers immediate network fetch regardless of freshness.
  /// Active subscribers receive updated state when fetch completes.
  /// No-op if no active subscription exists for the key.
  Future<void> refresh({
    required String namespace,
    required String key,
    Duration? networkTimeout,
  }) async {
    _assertInitialized();
    _assertNotDisposed();

    final String namespacedCacheKey = KeyBuilder.build(namespace, key);

    // Invalidate first so pipeline treats cache as stale
    await _invalidationHandler.invalidateSingleKey(namespacedCacheKey);

    // Restart pipeline if active subject and fetcher config exist
    _restartPipelineForKey(
      namespacedCacheKey: namespacedCacheKey,
      networkTimeout: networkTimeout,
    );

    _debugLog('Force refresh triggered for key: $namespacedCacheKey');
  }

  /// Invalidates the cache entry for the given [namespace] and [key].
  /// Active stream subscribers receive [CacheLoading].
  /// Call [cachedFetch] again to restart the pipeline.
  Future<void> invalidate({
    required String namespace,
    required String key,
  }) async {
    _assertInitialized();
    _assertNotDisposed();

    final String namespacedCacheKey = KeyBuilder.build(namespace, key);
    await _invalidationHandler.invalidateSingleKey(namespacedCacheKey);

    // Bug 21 fix — restart pipeline after invalidation
    _restartPipelineForKey(namespacedCacheKey: namespacedCacheKey);

    _debugLog(
        'Invalidated and restarted pipeline for key: $namespacedCacheKey');
  }

  /// Invalidates all cache entries.
  /// All active stream subscribers receive [CacheLoading] then refetch.
  /// Call this on user logout.
  Future<void> invalidateAll() async {
    _assertInitialized();
    _assertNotDisposed();

    await _invalidationHandler.invalidateAllKeys();

    // Bug 21 fix — restart all active pipelines after invalidation
    final List<String> activeKeys = List.from(_activeBehaviorSubjectMap.keys);
    for (final activeKey in activeKeys) {
      _restartPipelineForKey(namespacedCacheKey: activeKey);
    }

    _debugLog('Invalidated all keys and restarted active pipelines.');
  }

  /// Disposes all resources held by this coordinator.
  /// Call this when your app is closing or coordinator is no longer needed.
  /// Safe to call multiple times — subsequent calls are no-ops.
  Future<void> dispose() async {
    if (_isDisposed) return;

    // Bug 7 fix — set disposed flag before closing subjects
    // so any in-flight pipeline emissions are ignored
    _isDisposed = true;

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
    _debugLog('CacheCoordinator disposed.');
  }

  /// Restarts the fetch pipeline for [namespacedCacheKey] if
  /// an active subject and fetcher config exist for that key.
  void _restartPipelineForKey({
    required String namespacedCacheKey,
    Duration? networkTimeout,
  }) {
    final BehaviorSubject<CacheState<dynamic>>? subject =
        _activeBehaviorSubjectMap[namespacedCacheKey];
    final _CacheFetcherConfig<dynamic>? config =
        _fetcherConfigMap[namespacedCacheKey];

    if (subject == null || subject.isClosed || config == null) return;

    _feedPipelineIntoSubject(
      namespacedCacheKey: namespacedCacheKey,
      resolvedTtl: config.resolvedTtl,
      networkFetcher: config.networkFetcher,
      fromJsonConverter: config.fromJsonConverter,
      behaviorSubject: subject,
      networkTimeout: networkTimeout,
    );
  }

  /// Starts listening to [FetchPipeline] and feeds each state into [behaviorSubject].
  /// Removes subject from map when pipeline completes so next call starts fresh.
  void _feedPipelineIntoSubject<T>({
    required String namespacedCacheKey,
    required Duration resolvedTtl,
    required Future<Response<dynamic>> Function() networkFetcher,
    required T Function(dynamic json) fromJsonConverter,
    required BehaviorSubject<CacheState<dynamic>> behaviorSubject,
    Duration? networkTimeout,
  }) {
    _fetchPipeline
        .executeFetchPipeline<T>(
      cacheKey: namespacedCacheKey,
      ttl: resolvedTtl,
      networkFetcher: networkFetcher,
      fromJsonConverter: fromJsonConverter,
      networkTimeout: networkTimeout,
    )
        .listen(
      (CacheState<T> state) {
        // Bug 7 fix — check disposed flag before emitting
        if (_isDisposed) return;
        if (!behaviorSubject.isClosed) {
          behaviorSubject.add(state);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (_isDisposed) return;
        if (!behaviorSubject.isClosed) {
          behaviorSubject.addError(error, stackTrace);
        }
      },
      onDone: () {
        _activeBehaviorSubjectMap.remove(namespacedCacheKey);
        if (!behaviorSubject.isClosed) behaviorSubject.close();
        _debugLog('Pipeline completed for key: $namespacedCacheKey');
      },
    );
  }

  /// Throws [StateError] if coordinator has not been initialized.
  /// Always await [initialize] before calling [cachedFetch].
  void _assertInitialized() {
    if (!_isInitialized) {
      throw StateError(
        'CacheCoordinator: Not initialized. '
        'Always await initialize() before calling cachedFetch(). '
        'Example: await coordinator.initialize();',
      );
    }
  }

  /// Throws [StateError] if coordinator has been disposed.
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
      log(message, name: 'flutter_offline_cache');
    }
  }
}
