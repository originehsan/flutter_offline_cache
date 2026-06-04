import '../models/cache_entry.dart';

/// Abstract interface for cache storage operations.
/// Implement this to swap the storage backend.
/// Default implementation is [HiveCacheStore].
abstract class CacheStore {
  /// Whether the storage backend has been initialized and is ready.
  bool get isInitialized;

  /// Initializes the storage backend.
  /// Must be called before any read or write operation.
  /// Safe to call multiple times — subsequent calls are no-ops.
  Future<void> initializeStorage();

  /// Reads a [CacheEntry] from storage by [cacheKey].
  /// Returns null if the key does not exist or the entry is corrupt.
  Future<CacheEntry?> readCacheEntry(String cacheKey);

  /// Writes a [CacheEntry] to storage under [cacheKey].
  /// Overwrites any existing entry for the same key.
  Future<void> writeCacheEntry(String cacheKey, CacheEntry entryToWrite);

  /// Deletes the cache entry for [cacheKey].
  /// No-op if the key does not exist.
  Future<void> deleteCacheEntry(String cacheKey);

  /// Deletes all cache entries from storage.
  /// Use on logout or full cache invalidation.
  Future<void> deleteAllCacheEntries();

  /// Returns true if a cache entry exists for [cacheKey].
  Future<bool> cacheEntryExists(String cacheKey);

  /// Closes the storage backend cleanly.
  /// Call this when the coordinator is disposed.
  Future<void> disposeStorage();
}