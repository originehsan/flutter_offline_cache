/// Converts between [DateTime] and [int] milliseconds since epoch.
/// Hive cannot serialize [DateTime] natively — always store as [int].
class TimestampHelper {
  TimestampHelper._();

  /// Converts [DateTime] to milliseconds since epoch.
  static int toMillis(DateTime dateTime) =>
      dateTime.millisecondsSinceEpoch;

  /// Converts milliseconds since epoch to [DateTime].
  static DateTime fromMillis(int millis) =>
      DateTime.fromMillisecondsSinceEpoch(millis);

  /// Returns current time in milliseconds since epoch.
  static int now() => DateTime.now().millisecondsSinceEpoch;

  /// Returns true if the given timestamp has passed the TTL duration.
  static bool isExpired(int cachedAtMillis, Duration ttl) {
    final expiresAt = cachedAtMillis + ttl.inMilliseconds;
    return now() > expiresAt;
  }

  /// Returns remaining TTL. Returns [Duration.zero] if already expired.
  static Duration remainingTtl(int cachedAtMillis, Duration ttl) {
    final expiresAt = cachedAtMillis + ttl.inMilliseconds;
    final remaining = expiresAt - now();
    return remaining > 0 ? Duration(milliseconds: remaining) : Duration.zero;
  }
}