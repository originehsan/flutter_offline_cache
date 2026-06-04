/// Defines the caching strategy used by [CacheCoordinator].
enum CachePolicy {
  /// Return cached data immediately, refresh in background.
  /// UI never shows blank screen. Fresh data updates silently.
  cacheFirst,

  /// Explicit alias for [cacheFirst].
  /// Use this when you want to be clear about SWR behavior.
  staleWhileRevalidate,

  /// Try network first. Fall back to cache only if network fails.
  /// Use for data that must be fresh when online.
  networkFirst,

  /// Never hit network. Return cache only.
  /// Use for static data that never changes.
  cacheOnly,

  /// Never use cache. Always hit network.
  /// Use for real-time data where stale data is unacceptable.
  networkOnly;

  /// Returns true if this policy requires a network call.
  bool get isNetworkRequired =>
      this == networkFirst || this == networkOnly;

  /// Returns true if this policy allows serving cached data.
  bool get isCacheAllowed =>
      this != networkOnly;

  /// Returns true if this policy does background revalidation.
  bool get doesRevalidate =>
      this == cacheFirst || this == staleWhileRevalidate;
}