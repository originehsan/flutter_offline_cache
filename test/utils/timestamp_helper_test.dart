import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_offline_cache/src/utils/timestamp_helper.dart';

void main() {
  group('TimestampHelper', () {
    test('toMillis converts DateTime to milliseconds correctly', () {
      final DateTime dateTime = DateTime(2024, 1, 1, 12, 0, 0);
      final int millis = TimestampHelper.toMillis(dateTime);
      expect(millis, equals(dateTime.millisecondsSinceEpoch));
    });

    test('fromMillis converts milliseconds back to DateTime correctly', () {
      final DateTime original = DateTime(2024, 1, 1, 12, 0, 0);
      final int millis = TimestampHelper.toMillis(original);
      final DateTime converted = TimestampHelper.fromMillis(millis);
      expect(converted, equals(original));
    });

    test('toMillis and fromMillis round trip produces same DateTime', () {
      final DateTime now = DateTime.now();
      final int millis = TimestampHelper.toMillis(now);
      final DateTime roundTripped = TimestampHelper.fromMillis(millis);
      expect(roundTripped.millisecondsSinceEpoch,
          equals(now.millisecondsSinceEpoch));
    });

    test('isExpired returns false when TTL has not passed', () {
      final int cachedAtMillis = TimestampHelper.now();
      const Duration ttl = Duration(minutes: 10);
      expect(TimestampHelper.isExpired(cachedAtMillis, ttl), isFalse);
    });

    test('isExpired returns true when TTL has passed', () {
      final int cachedAtMillis =
          TimestampHelper.now() - const Duration(minutes: 11).inMilliseconds;
      const Duration ttl = Duration(minutes: 10);
      expect(TimestampHelper.isExpired(cachedAtMillis, ttl), isTrue);
    });

    test('isExpired returns true when TTL is exactly zero', () {
      final int cachedAtMillis =
          TimestampHelper.now() - const Duration(seconds: 1).inMilliseconds;
      const Duration ttl = Duration.zero;
      expect(TimestampHelper.isExpired(cachedAtMillis, ttl), isTrue);
    });

    test('remainingTtl returns Duration.zero when already expired', () {
      final int cachedAtMillis =
          TimestampHelper.now() - const Duration(minutes: 11).inMilliseconds;
      const Duration ttl = Duration(minutes: 10);
      expect(TimestampHelper.remainingTtl(cachedAtMillis, ttl),
          equals(Duration.zero));
    });

    test('remainingTtl returns positive duration when not expired', () {
      final int cachedAtMillis = TimestampHelper.now();
      const Duration ttl = Duration(minutes: 10);
      final Duration remaining =
          TimestampHelper.remainingTtl(cachedAtMillis, ttl);
      expect(remaining.inMilliseconds, greaterThan(0));
    });
  });
}