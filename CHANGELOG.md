## 0.1.1

Initial release.

- Offline-first stale-while-revalidate (SWR) caching for Flutter
- Automatic TTL-based background revalidation with cancellable Timer
- 6 typed cache states — CacheInitial, CacheLoading, CacheSuccess, CacheRevalidating, CacheStale, CacheError
- Request deduplication — concurrent calls for same key share one network request
- App lifecycle awareness — TTL timers pause on background, resume accurately
- Optional AES-256 encryption via SecureKeyGenerator
- Riverpod integration support
- Cross-session generation token via microsecond timestamps
- cacheForever and Duration.zero TTL semantics
- minTtl validation prevents accidental network hammering
- 61+ passing tests