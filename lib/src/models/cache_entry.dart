import 'cache_metadata.dart';

/// Represents a single cache entry stored in Hive.
/// Contains the encoded JSON payload and its associated metadata.
/// This is the exact object written to and read from Hive storage.
class CacheEntry {
  /// The JSON-encoded string of the cached API response.
  /// Always a valid JSON string — never empty.
  final String encodedPayload;

  /// Metadata about when this entry was cached, its TTL, and source.
  final CacheMetadata entryMetadata;

  const CacheEntry({
    required this.encodedPayload,
    required this.entryMetadata,
  }) : assert(encodedPayload.length > 0, 'encodedPayload must not be empty');

  /// Returns true if this entry has passed its TTL expiry time.
  bool get hasExpired => entryMetadata.isExpired;

  /// Returns true if this entry is still within its TTL window.
  bool get isStillFresh => entryMetadata.isFresh;

  /// Returns how long ago this entry was written to Hive.
  Duration get ageOfCachedData => entryMetadata.ageOfCachedData;

  /// Serializes this entry to a [Map] for writing to Hive.
  Map<String, dynamic> toHiveMap() => {
        'encodedPayload': encodedPayload,
        'entryMetadata': entryMetadata.toHiveMap(),
      };

  /// Deserializes a [Map] read from Hive into a [CacheEntry].
  /// Returns null if the map is corrupt or missing required fields.
  static CacheEntry? fromHiveMap(dynamic rawValue) {
    try {
      if (rawValue == null) return null;
      if (rawValue is! Map) return null;

      final map = Map<String, dynamic>.from(rawValue);

      final encodedPayload = map['encodedPayload'];
      final rawMetadata = map['entryMetadata'];

      if (encodedPayload == null || encodedPayload is! String) return null;
      if (encodedPayload.isEmpty) return null;
      if (rawMetadata == null || rawMetadata is! Map) return null;

      final metadata = CacheMetadata.fromHiveMap(
        Map<String, dynamic>.from(rawMetadata),
      );

      return CacheEntry(
        encodedPayload: encodedPayload,
        entryMetadata: metadata,
      );
    } catch (_) {
      return null;
    }
  }

  /// Creates a new [CacheEntry] with incremented fetch count.
  CacheEntry withIncrementedFetchCount() {
    return CacheEntry(
      encodedPayload: encodedPayload,
      entryMetadata: entryMetadata.copyWith(
        fetchCount: entryMetadata.fetchCount + 1,
      ),
    );
  }
}