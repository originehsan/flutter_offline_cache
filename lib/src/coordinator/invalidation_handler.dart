import 'dart:developer';
import 'package:flutter/foundation.dart';
import 'package:rxdart/rxdart.dart';
import '../models/cache_state.dart';
import '../store/cache_store.dart';
import 'state_snapshot_registry.dart';

/// Handles cache invalidation for single keys and full cache clears.
/// Deletes entries from storage, removes state snapshots,
/// and notifies active streams so UI knows to refetch.
class InvalidationHandler {
  final CacheStore _cacheStore;
  final StateSnapshotRegistry _snapshotRegistry;
  final Map<String, BehaviorSubject<CacheState<dynamic>>>
      _activeBehaviorSubjectMap;
  final bool _enableDebugLogs;

  InvalidationHandler({
    required CacheStore cacheStore,
    required StateSnapshotRegistry snapshotRegistry,
    required Map<String, BehaviorSubject<CacheState<dynamic>>>
        activeBehaviorSubjectMap,
    bool enableDebugLogs = false,
  })  : _cacheStore = cacheStore,
        _snapshotRegistry = snapshotRegistry,
        _activeBehaviorSubjectMap = activeBehaviorSubjectMap,
        _enableDebugLogs = enableDebugLogs;

  /// Invalidates the cache entry for [cacheKey].
  /// Deletes from storage, removes snapshot, notifies active stream.
  Future<void> invalidateSingleKey(String cacheKey) async {
    await _cacheStore.deleteCacheEntry(cacheKey);
    await _snapshotRegistry.removeStateForKey(cacheKey);
    _notifyStreamOfInvalidation(cacheKey);
    _debugLog('Invalidated cache key: $cacheKey');
  }

  /// Invalidates all cache entries.
  /// Deletes all from storage, removes all snapshots,
  /// notifies all active streams.
  Future<void> invalidateAllKeys() async {
    await _cacheStore.deleteAllCacheEntries();
    await _snapshotRegistry.removeAllStates();
    _notifyAllStreamsOfInvalidation();
    _debugLog('Invalidated all cache entries.');
  }

  /// Emits [CacheLoading] to the active stream for [cacheKey] if one exists.
  void _notifyStreamOfInvalidation(String cacheKey) {
    final BehaviorSubject<CacheState<dynamic>>? subject =
        _activeBehaviorSubjectMap[cacheKey];
    if (subject == null || subject.isClosed) return;
    subject.add(CacheLoading<dynamic>());
  }

  /// Emits [CacheLoading] to all active streams.
  void _notifyAllStreamsOfInvalidation() {
    for (final entry in _activeBehaviorSubjectMap.entries) {
      if (!entry.value.isClosed) {
        entry.value.add(CacheLoading<dynamic>());
      }
    }
  }

  /// Logs a debug message via dart:developer.
  /// Only active when [_enableDebugLogs] is true and in debug mode.
  void _debugLog(String message) {
    if (_enableDebugLogs && kDebugMode) {
      log(message, name: 'flutter_offline_cache');
    }
  }
}