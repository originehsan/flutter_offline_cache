import '../models/cache_entry.dart';

/// Reasons why a cache entry failed structural validation.
enum CacheEntryInvalidationReason {
  /// [CacheEntry.fromHiveMap] returned null — entry is corrupt or missing fields.
  nullEntry,

  /// The encoded payload string is empty.
  emptyPayload,

  /// cachedAtMillis is negative or suspiciously in the future.
  invalidTimestamp,

  /// ttlMillis is zero or negative — unusable TTL.
  invalidTtl,

  /// expiresAtMillis is less than cachedAtMillis — impossible value, likely tampered.
  impossibleExpiry,
}

/// Result of a cache entry structural validation check.
/// Result of a cache entry structural validation check.
class CacheEntryValidationResult {
  /// Whether the entry passed all structural validation checks.
  final bool isValidEntry;

  /// Reason for failure if [isValidEntry] is false. Null if valid.
  final CacheEntryInvalidationReason? invalidationReason;

  const CacheEntryValidationResult.passed()
      : isValidEntry = true,
        invalidationReason = null;

  const CacheEntryValidationResult.failed(
    CacheEntryInvalidationReason reason,
  )   : isValidEntry = false,
        invalidationReason = reason;
}

/// Validates structural integrity of cache entries read from Hive.
/// Does NOT check TTL expiry — that is coordinator responsibility.
/// Call [validateCacheEntry] before returning an entry to the coordinator.
class CacheStoreValidator {
  CacheStoreValidator._();

  /// Maximum allowed future clock skew in milliseconds.
  /// Entries cached more than 60 seconds in the future are considered tampered.
  static const int _maxAllowedClockSkewMillis = 60000;

  /// Validates structural integrity of a [CacheEntry].
  /// Returns [CacheEntryValidationResult.failed] if any check fails.
  static CacheEntryValidationResult validateCacheEntry(CacheEntry? entry) {
    if (entry == null) {
      return const CacheEntryValidationResult.failed(
        CacheEntryInvalidationReason.nullEntry,
      );
    }

    if (entry.encodedPayload.isEmpty) {
      return const CacheEntryValidationResult.failed(
        CacheEntryInvalidationReason.emptyPayload,
      );
    }

    final metadata = entry.entryMetadata;

    if (metadata.cachedAtMillis <= 0) {
      return const CacheEntryValidationResult.failed(
        CacheEntryInvalidationReason.invalidTimestamp,
      );
    }

    final nowMillis = DateTime.now().millisecondsSinceEpoch;
    if (metadata.cachedAtMillis > nowMillis + _maxAllowedClockSkewMillis) {
      return const CacheEntryValidationResult.failed(
        CacheEntryInvalidationReason.invalidTimestamp,
      );
    }

    if (metadata.ttlMillis <= 0) {
      return const CacheEntryValidationResult.failed(
        CacheEntryInvalidationReason.invalidTtl,
      );
    }

    if (metadata.expiresAtMillis < metadata.cachedAtMillis) {
      return const CacheEntryValidationResult.failed(
        CacheEntryInvalidationReason.impossibleExpiry,
      );
    }

    return const CacheEntryValidationResult.passed();
  }
}