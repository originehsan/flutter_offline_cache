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
    });
  });
}