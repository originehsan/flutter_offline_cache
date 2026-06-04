import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:flutter_offline_cache/src/models/cache_entry.dart';
import 'package:flutter_offline_cache/src/models/cache_metadata.dart';
import 'package:flutter_offline_cache/src/models/cache_config.dart';
import 'package:flutter_offline_cache/src/store/hive_cache_store.dart';

void main() {
  late HiveCacheStore store;
  late Directory tempDir;

  CacheEntry buildEntry({
    String payload = '{"id":1,"title":"Test"}',
    Duration ttl = const Duration(minutes: 10),
    int pipelineId = 1,
  }) {
    return CacheEntry(
      encodedPayload: payload,
      entryMetadata: CacheMetadata.fromNetworkResponse(
        ttl: ttl,
        pipelineId: pipelineId,
      ),
    );
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('hive_test_');
    Hive.init(tempDir.path);
    store = HiveCacheStore(cacheConfig: const CacheConfig());
    await store.initializeStorage();
  });

  tearDown(() async {
    if (store.isInitialized) {
      await store.deleteAllCacheEntries();
      await store.disposeStorage();
    }
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  group('HiveCacheStore', () {
    test('write then read within TTL returns entry', () async {
      final CacheEntry entry = buildEntry();
      await store.writeCacheEntry('movies', entry);

      final CacheEntry? result = await store.readCacheEntry('movies');

      expect(result, isNotNull);
      expect(result!.encodedPayload, equals('{"id":1,"title":"Test"}'));
    });

    test('read non-existent key returns null', () async {
      final CacheEntry? result = await store.readCacheEntry('nonexistent');
      expect(result, isNull);
    });

    test('write then read after TTL returns expired entry', () async {
      final CacheEntry entry = buildEntry(
        ttl: const Duration(milliseconds: 1),
      );
      await store.writeCacheEntry('movies', entry);

      await Future<void>.delayed(const Duration(milliseconds: 10));

      final CacheEntry? result = await store.readCacheEntry('movies');

      expect(result, isNotNull);
      expect(result!.hasExpired, isTrue);
    });

    test('delete key then read returns null', () async {
      final CacheEntry entry = buildEntry();
      await store.writeCacheEntry('movies', entry);
      await store.deleteCacheEntry('movies');

      final CacheEntry? result = await store.readCacheEntry('movies');
      expect(result, isNull);
    });

    test('delete non-existent key is no-op', () async {
      expect(
        () async => store.deleteCacheEntry('nonexistent'),
        returnsNormally,
      );
    });

    test('deleteAllCacheEntries clears all entries', () async {
      await store.writeCacheEntry('movies', buildEntry());
      await store.writeCacheEntry('series', buildEntry());
      await store.writeCacheEntry('users', buildEntry());

      await store.deleteAllCacheEntries();

      expect(await store.readCacheEntry('movies'), isNull);
      expect(await store.readCacheEntry('series'), isNull);
      expect(await store.readCacheEntry('users'), isNull);
    });

    test('cacheEntryExists returns true for existing key', () async {
      await store.writeCacheEntry('movies', buildEntry());
      expect(await store.cacheEntryExists('movies'), isTrue);
    });

    test('cacheEntryExists returns false for non-existent key', () async {
      expect(await store.cacheEntryExists('nonexistent'), isFalse);
    });

    test('corrupt entry returns null and is deleted', () async {
      final box = Hive.box<dynamic>(const CacheConfig().hiveBoxName);
      await box.put('corrupt_key', 'not_a_valid_map');

      final CacheEntry? result = await store.readCacheEntry('corrupt_key');

      expect(result, isNull);
      expect(await store.cacheEntryExists('corrupt_key'), isFalse);
    });

    test('overwrite existing entry with new entry', () async {
      await store.writeCacheEntry(
          'movies', buildEntry(payload: '{"old":true}'));
      await store.writeCacheEntry(
          'movies', buildEntry(payload: '{"new":true}'));

      final CacheEntry? result = await store.readCacheEntry('movies');
      expect(result!.encodedPayload, equals('{"new":true}'));
    });

    test('isInitialized returns true after initializeStorage', () {
      expect(store.isInitialized, isTrue);
    });

    test('isInitialized returns false after disposeStorage', () async {
      await store.disposeStorage();
      expect(store.isInitialized, isFalse);
    });
  });
}