import 'package:mutex/mutex.dart';
import '../models/cache_state.dart';

/// Stores the last known [CacheState] per cache key.
/// Enables new stream subscribers to receive the latest state immediately.
/// Solves the "new subscriber misses first emission" problem.
class StateSnapshotRegistry {
  /// Protects read/write access to [_stateSnapshotMap].
  final Mutex _mapAccessMutex = Mutex();

  /// Map of last known [CacheState] per cache key.
  final Map<String, CacheState<dynamic>> _stateSnapshotMap = {};

  /// Saves [latestState] as the most recent state for [cacheKey].
  Future<void> saveLatestState(
    String cacheKey,
    CacheState<dynamic> latestState,
  ) async {
    await _mapAccessMutex.protect(() async {
      _stateSnapshotMap[cacheKey] = latestState;
    });
  }

  /// Returns the last known [CacheState] for [cacheKey].
  /// Returns null if no state has been saved for this key yet.
  Future<CacheState<dynamic>?> getLatestState(String cacheKey) async {
    return await _mapAccessMutex.protect(() async {
      return _stateSnapshotMap[cacheKey];
    });
  }

  /// Returns true if a state snapshot exists for [cacheKey].
  Future<bool> hasStateForKey(String cacheKey) async {
    return await _mapAccessMutex.protect(() async {
      return _stateSnapshotMap.containsKey(cacheKey);
    });
  }

  /// Removes the state snapshot for [cacheKey].
  /// Call this when a cache key is invalidated.
  Future<void> removeStateForKey(String cacheKey) async {
    await _mapAccessMutex.protect(() async {
      _stateSnapshotMap.remove(cacheKey);
    });
  }

  /// Removes all state snapshots.
  /// Call this on full cache invalidation or coordinator dispose.
  Future<void> removeAllStates() async {
    await _mapAccessMutex.protect(() async {
      _stateSnapshotMap.clear();
    });
  }
}