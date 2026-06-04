import 'dart:developer';
import 'package:flutter/foundation.dart';
import 'package:mutex/mutex.dart';
import '../models/cache_entry.dart';
import '../models/cache_config.dart';
import 'cache_store.dart';
import 'hive_box_manager.dart';
import 'cache_store_validator.dart';

/// Hive-backed implementation of [CacheStore].
/// Handles all read, write, delete operations on the Hive cache box.
/// Uses [HiveBoxManager] for box lifecycle.
/// Uses [CacheStoreValidator] to detect and remove corrupt entries.
class HiveCacheStore implements CacheStore {
  final HiveBoxManager _boxManager;
  final CacheConfig _cacheConfig;

  /// Protects all write and delete operations against concurrent access.
  final Mutex _writeOperationMutex = Mutex();

  HiveCacheStore({
    required CacheConfig cacheConfig,
  })  : _cacheConfig = cacheConfig,
        _boxManager = HiveBoxManager(cacheConfig: cacheConfig);

  @override
  bool get isInitialized => _boxManager.isBoxOpen;

  @override
  Future<void> initializeStorage() async {
    await _boxManager.openCacheBox();
    _debugLog(
        'HiveCacheStore initialized — box: ${_cacheConfig.hiveBoxName}');
  }

  @override
  Future<CacheEntry?> readCacheEntry(String cacheKey) async {
    _assertInitialized();

    final dynamic rawValue = _boxManager.openedCacheBox.get(cacheKey);

    if (rawValue == null) return null;

    final CacheEntry? parsedEntry = CacheEntry.fromHiveMap(rawValue);

    final validationResult =
        CacheStoreValidator.validateCacheEntry(parsedEntry);

    if (!validationResult.isValidEntry) {
      _debugLog(
        'Corrupt entry detected for key: $cacheKey — '
        'reason: ${validationResult.invalidationReason?.name}. '
        'Deleting entry.',
      );
      // Bug 10 fix — delete wrapped in mutex
      await _deleteEntryFromBox(cacheKey);
      return null;
    }

    // Bug 9 fix — removed fetch count increment from read path.
    // Incrementing fetch count on every read caused a write storm
    // when multiple widgets read the same key simultaneously.
    // Fetch count is updated only during explicit writeCacheEntry calls.
    return parsedEntry;
  }

  @override
  Future<void> writeCacheEntry(
    String cacheKey,
    CacheEntry entryToWrite,
  ) async {
    _assertInitialized();
    await _writeEntryToBox(cacheKey, entryToWrite);
    _debugLog('Written cache entry for key: $cacheKey');
  }

  @override
  Future<void> deleteCacheEntry(String cacheKey) async {
    _assertInitialized();

    final bool exists = _boxManager.openedCacheBox.containsKey(cacheKey);
    if (!exists) return;

    // Bug 10 fix — delete wrapped in mutex
    await _deleteEntryFromBox(cacheKey);
    _debugLog('Deleted cache entry for key: $cacheKey');
  }

  @override
  Future<void> deleteAllCacheEntries() async {
    _assertInitialized();

    // Bug 10 fix — clear wrapped in mutex to prevent
    // concurrent read during full box clear
    await _writeOperationMutex.protect(() async {
      await _boxManager.openedCacheBox.clear();
    });

    _debugLog(
        'Deleted all cache entries from box: ${_cacheConfig.hiveBoxName}');
  }

  @override
  Future<bool> cacheEntryExists(String cacheKey) async {
    _assertInitialized();
    return _boxManager.openedCacheBox.containsKey(cacheKey);
  }

  @override
  Future<void> disposeStorage() async {
    await _boxManager.closeCacheBox();
    _debugLog('HiveCacheStore disposed.');
  }

  /// Writes a [CacheEntry] to the Hive box under [cacheKey].
  /// Protected by [_writeOperationMutex] to prevent concurrent write corruption.
  Future<void> _writeEntryToBox(
    String cacheKey,
    CacheEntry entryToWrite,
  ) async {
    await _writeOperationMutex.protect(() async {
      await _boxManager.openedCacheBox.put(
        cacheKey,
        entryToWrite.toHiveMap(),
      );
    });
  }

  /// Deletes a single entry from the Hive box under [cacheKey].
  /// Protected by [_writeOperationMutex].
  Future<void> _deleteEntryFromBox(String cacheKey) async {
    await _writeOperationMutex.protect(() async {
      await _boxManager.openedCacheBox.delete(cacheKey);
    });
  }

  /// Throws [StateError] if storage has not been initialized.
  void _assertInitialized() {
    if (!isInitialized) {
      throw StateError(
        'HiveCacheStore: Storage not initialized. '
        'Call initializeStorage() before performing cache operations.',
      );
    }
  }

  /// Logs a debug message via dart:developer.
  /// Only active when [CacheConfig.enableDebugLogs] is true
  /// and app is running in debug mode.
  void _debugLog(String message) {
    if (_cacheConfig.enableDebugLogs && kDebugMode) {
      log(message, name: 'flutter_offline_cache');
    }
  }
}