import 'cache_policy.dart';

/// Developer-level configuration for [CacheCoordinator].
/// Pass this once when creating the coordinator.
/// All fields have sensible defaults — only override what you need.
class CacheConfig {
  /// Default TTL applied to all cache entries unless overridden per request.
  /// Defaults to 10 minutes.
  final Duration defaultTtl;

  /// Default caching strategy applied unless overridden per request.
  /// Defaults to [CachePolicy.cacheFirst].
  final CachePolicy defaultCachePolicy;

  /// Maximum allowed size in bytes for a single cache entry.
  /// Entries exceeding this limit are not written to Hive.
  /// Defaults to 512KB.
  final int maxEntrySizeBytes;

  /// Name of the Hive box used by this package.
  /// Override if this conflicts with your app's existing Hive boxes.
  /// Defaults to 'flutter_offline_cache'.
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

  const CacheConfig({
    this.defaultTtl = const Duration(minutes: 10),
    this.defaultCachePolicy = CachePolicy.cacheFirst,
    this.maxEntrySizeBytes = 524288,
    this.hiveBoxName = 'flutter_offline_cache',
    this.encryptionKey,
    this.enableDebugLogs = false,
  }) : assert(
          encryptionKey == null || encryptionKey.length == 32,
          'encryptionKey must be exactly 32 bytes for AES-256 encryption.',
        );

  /// Returns true if encryption is enabled.
  bool get isEncryptionEnabled => encryptionKey != null;

  /// Creates a copy of this config with updated fields.
  CacheConfig copyWith({
    Duration? defaultTtl,
    CachePolicy? defaultCachePolicy,
    int? maxEntrySizeBytes,
    String? hiveBoxName,
    List<int>? encryptionKey,
    bool? enableDebugLogs,
  }) {
    return CacheConfig(
      defaultTtl: defaultTtl ?? this.defaultTtl,
      defaultCachePolicy: defaultCachePolicy ?? this.defaultCachePolicy,
      maxEntrySizeBytes: maxEntrySizeBytes ?? this.maxEntrySizeBytes,
      hiveBoxName: hiveBoxName ?? this.hiveBoxName,
      encryptionKey: encryptionKey ?? this.encryptionKey,
      enableDebugLogs: enableDebugLogs ?? this.enableDebugLogs,
    );
  }
}