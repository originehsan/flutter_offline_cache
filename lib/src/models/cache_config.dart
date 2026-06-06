import 'cache_policy.dart';

/// Sentinel value — pass as [ttl] to [CacheCoordinator.cachedFetch]
/// to cache an entry indefinitely with no automatic revalidation.
///
/// Useful for static data that never changes:
/// ```dart
/// coordinator.cachedFetch(
///   ttl: CacheConfig.forever,
///   ...
/// )
/// ```
const Duration cacheForever = Duration(microseconds: -1);

/// Developer-level configuration for [CacheCoordinator].
/// Pass this once when creating the coordinator.
/// All fields have sensible defaults — only override what you need.
class CacheConfig {
  /// Default TTL applied to all cache entries unless overridden per request.
  ///
  /// Special values:
  /// - [cacheForever] — entry never expires, no revalidation timer scheduled
  /// - [Duration.zero] — entry is always stale, revalidates immediately after
  ///   every fetch (pure SWR behavior)
  ///
  /// Defaults to 10 minutes.
  final Duration defaultTtl;

  /// Minimum allowed TTL per cache entry.
  /// Prevents accidental network hammering from very short TTLs.
  /// Defaults to 1 second.
  ///
  /// Ignored when [cacheForever] or [Duration.zero] is passed explicitly.
  final Duration minTtl;

  /// Default caching strategy applied unless overridden per request.
  /// Defaults to [CachePolicy.cacheFirst].
  final CachePolicy defaultCachePolicy;

  /// Maximum allowed size in bytes for a single cache entry.
  /// Entries exceeding this limit are not written to Hive.
  /// Defaults to 512KB.
  final int maxEntrySizeBytes;

  /// Name of the Hive box used by this package.
  /// Override if this conflicts with your app's existing Hive boxes.
  ///
  /// Default uses a prefixed name to avoid collisions with
  /// developer's own Hive boxes.
  /// Defaults to '__foc_cache_v1__'.
  final String hiveBoxName;

  /// Optional AES encryption key for encrypting Hive box contents.
  /// Must be exactly 32 bytes if provided.
  /// If null, Hive box is stored unencrypted.
  /// Use [SecureKeyGenerator] to generate and store this key safely.
  final List<int>? encryptionKey;

  /// Whether to emit debug logs via dart:developer.
  /// Automatically disabled in release builds.
  /// Defaults to false.
  final bool enableDebugLogs;

  /// Whether to pause TTL revalidation timers when app goes to background.
  ///
  /// When true — timers pause on [AppLifecycleState.paused] and resume
  /// on [AppLifecycleState.resumed] with accurate remaining duration.
  /// Prevents background network calls while app is not in use.
  ///
  /// Requires calling [CacheCoordinator.attachFlutterLifecycle] after
  /// initialization.
  ///
  /// Defaults to true.
  final bool pauseRevalidationWhenBackgrounded;

const CacheConfig({
    this.defaultTtl = const Duration(minutes: 10),
    this.minTtl = const Duration(seconds: 1),
    this.defaultCachePolicy = CachePolicy.cacheFirst,
    this.maxEntrySizeBytes = 524288,
    this.hiveBoxName = '__foc_cache_v1__',
    this.encryptionKey,
    this.enableDebugLogs = false,
    this.pauseRevalidationWhenBackgrounded = true,
  }) : assert(
          encryptionKey == null || encryptionKey.length == 32,
          'encryptionKey must be exactly 32 bytes for AES-256 encryption.',
        );

  /// Returns true if encryption is enabled.
  bool get isEncryptionEnabled => encryptionKey != null;

  /// Returns true if this TTL represents infinite caching.
  static bool isForever(Duration ttl) =>
      ttl.inMicroseconds == cacheForever.inMicroseconds;

  /// Returns true if this TTL means always stale — revalidate immediately.
  static bool isAlwaysStale(Duration ttl) => ttl == Duration.zero;

  /// Resolves effective TTL — clamps to [minTtl] if below minimum.
  /// Returns null for [cacheForever].
  /// Returns [Duration.zero] for always-stale behavior.
  Duration? resolveEffectiveTtl(Duration? ttl) {
    final Duration resolved = ttl ?? defaultTtl;

    // cacheForever — no timer, cache indefinitely
    if (resolved.inMicroseconds == cacheForever.inMicroseconds) return null;

    // Duration.zero — always stale, revalidate immediately
    if (resolved == Duration.zero) return Duration.zero;

    // Clamp to minTtl — prevents network hammering
    if (resolved < minTtl) return minTtl;

    return resolved;
  }

  /// Creates a copy of this config with updated fields.
  CacheConfig copyWith({
    Duration? defaultTtl,
    Duration? minTtl,
    CachePolicy? defaultCachePolicy,
    int? maxEntrySizeBytes,
    String? hiveBoxName,
    List<int>? encryptionKey,
    bool? enableDebugLogs,
    bool? pauseRevalidationWhenBackgrounded,
  }) {
    return CacheConfig(
      defaultTtl: defaultTtl ?? this.defaultTtl,
      minTtl: minTtl ?? this.minTtl,
      defaultCachePolicy: defaultCachePolicy ?? this.defaultCachePolicy,
      maxEntrySizeBytes: maxEntrySizeBytes ?? this.maxEntrySizeBytes,
      hiveBoxName: hiveBoxName ?? this.hiveBoxName,
      encryptionKey: encryptionKey ?? this.encryptionKey,
      enableDebugLogs: enableDebugLogs ?? this.enableDebugLogs,
      pauseRevalidationWhenBackgrounded: pauseRevalidationWhenBackgrounded ??
          this.pauseRevalidationWhenBackgrounded,
    );
  }
}
