import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_offline_cache/flutter_offline_cache.dart';

void main() {
  group('flutter_offline_cache', () {
    test('CacheConfig has correct defaults', () {
  const config = CacheConfig();
  expect(config.defaultTtl, equals(const Duration(minutes: 10)));
  expect(config.defaultCachePolicy, equals(CachePolicy.cacheFirst));
  expect(config.maxEntrySizeBytes, equals(524288));
  expect(config.hiveBoxName, equals('__foc_cache_v1__'));
  expect(config.isEncryptionEnabled, isFalse);
  expect(config.enableDebugLogs, isFalse);
  expect(config.minTtl, equals(const Duration(seconds: 1)));
  expect(config.pauseRevalidationWhenBackgrounded, isTrue);
});

test('CacheConfig.resolveEffectiveTtl returns null for cacheForever', () {
  const config = CacheConfig();
  expect(config.resolveEffectiveTtl(cacheForever), isNull);
});

test('CacheConfig.resolveEffectiveTtl returns zero for Duration.zero', () {
  const config = CacheConfig();
  expect(config.resolveEffectiveTtl(Duration.zero), equals(Duration.zero));
});

test('CacheConfig.resolveEffectiveTtl clamps below minTtl', () {
  const config = CacheConfig();
  expect(
    config.resolveEffectiveTtl(const Duration(milliseconds: 100)),
    equals(const Duration(seconds: 1)),
  );
});

test('CacheConfig.resolveEffectiveTtl returns ttl when above minTtl', () {
  const config = CacheConfig();
  expect(
    config.resolveEffectiveTtl(const Duration(minutes: 5)),
    equals(const Duration(minutes: 5)),
  );
});

test('CacheConfig.isForever returns true for cacheForever', () {
  expect(CacheConfig.isForever(cacheForever), isTrue);
});

test('CacheConfig.isAlwaysStale returns true for Duration.zero', () {
  expect(CacheConfig.isAlwaysStale(Duration.zero), isTrue);
});
  });
}