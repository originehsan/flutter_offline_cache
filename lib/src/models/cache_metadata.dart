import '../utils/timestamp_helper.dart';

/// Represents the origin of a cache entry.
enum CacheSource {
  /// Data was fetched fresh from the network.
  network,

  /// Data was served from local Hive storage.
  localCache,
}

/// Stores metadata about a cache entry.
/// Contains timing, source, usage, and pipeline generation information.
/// Does NOT contain the actual cached data — see [CacheEntry].
class CacheMetadata {
  /// Milliseconds since epoch when this entry was written to Hive.
  final int cachedAtMillis;

  /// TTL duration in milliseconds set by the developer.
  final int ttlMillis;

  /// Pre-computed expiry time in milliseconds since epoch.
  /// Equal to [cachedAtMillis] + [ttlMillis].
  final int expiresAtMillis;

  /// Where this data originally came from.
  final CacheSource source;

  /// How many times this entry has been served from cache.
  final int fetchCount;

  /// Monotonic pipeline ID assigned when this entry was written.
  /// Used to detect if a newer pipeline has already written to this key.
  /// Defaults to 0 for entries written before this field existed.
  final int pipelineId;

  const CacheMetadata({
    required this.cachedAtMillis,
    required this.ttlMillis,
    required this.expiresAtMillis,
    required this.source,
    this.fetchCount = 0,
    this.pipelineId = 0,
  });

  /// Returns true if this entry has passed its TTL expiry time.
  bool get isExpired =>
      TimestampHelper.now() > expiresAtMillis;

  /// Returns true if this entry is still within its TTL window.
  bool get isFresh => !isExpired;

  /// Returns how long until this entry expires.
  /// Returns [Duration.zero] if already expired.
  Duration get remainingValidDuration {
    final remainingMillis = expiresAtMillis - TimestampHelper.now();
    return remainingMillis > 0
        ? Duration(milliseconds: remainingMillis)
        : Duration.zero;
  }

  /// Returns how long ago this entry was cached.
  Duration get ageOfCachedData =>
      Duration(milliseconds: TimestampHelper.now() - cachedAtMillis);

  /// Creates a new [CacheMetadata] with updated fields.
  CacheMetadata copyWith({
    int? cachedAtMillis,
    int? ttlMillis,
    int? expiresAtMillis,
    CacheSource? source,
    int? fetchCount,
    int? pipelineId,
  }) {
    return CacheMetadata(
      cachedAtMillis: cachedAtMillis ?? this.cachedAtMillis,
      ttlMillis: ttlMillis ?? this.ttlMillis,
      expiresAtMillis: expiresAtMillis ?? this.expiresAtMillis,
      source: source ?? this.source,
      fetchCount: fetchCount ?? this.fetchCount,
      pipelineId: pipelineId ?? this.pipelineId,
    );
  }

  /// Creates [CacheMetadata] for a freshly fetched network response.
  factory CacheMetadata.fromNetworkResponse({
    required Duration ttl,
    required int pipelineId,
  }) {
    final now = TimestampHelper.now();
    return CacheMetadata(
      cachedAtMillis: now,
      ttlMillis: ttl.inMilliseconds,
      expiresAtMillis: now + ttl.inMilliseconds,
      source: CacheSource.network,
      fetchCount: 0,
      pipelineId: pipelineId,
    );
  }

  /// Serializes to a [Map] for storage in Hive.
  Map<String, dynamic> toHiveMap() => {
        'cachedAtMillis': cachedAtMillis,
        'ttlMillis': ttlMillis,
        'expiresAtMillis': expiresAtMillis,
        'source': source.name,
        'fetchCount': fetchCount,
        'pipelineId': pipelineId,
      };

  /// Deserializes from a [Map] read from Hive.
  /// [pipelineId] defaults to 0 for entries written before this field existed.
  factory CacheMetadata.fromHiveMap(Map<String, dynamic> map) {
    return CacheMetadata(
      cachedAtMillis: map['cachedAtMillis'] as int,
      ttlMillis: map['ttlMillis'] as int,
      expiresAtMillis: map['expiresAtMillis'] as int,
      source: CacheSource.values.firstWhere(
        (s) => s.name == map['source'],
        orElse: () => CacheSource.network,
      ),
      fetchCount: map['fetchCount'] as int? ?? 0,
      pipelineId: map['pipelineId'] as int? ?? 0,
    );
  }
}