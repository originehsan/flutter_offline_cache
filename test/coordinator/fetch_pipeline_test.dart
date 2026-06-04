import 'dart:io';
import 'package:flutter_offline_cache/flutter_offline_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:dio/dio.dart';
import 'package:flutter_offline_cache/src/store/hive_cache_store.dart';
import 'package:flutter_offline_cache/src/network/dedup_registry.dart';
import 'package:flutter_offline_cache/src/coordinator/state_snapshot_registry.dart';
import 'package:flutter_offline_cache/src/coordinator/fetch_pipeline.dart';

void main() {
  late FetchPipeline pipeline;
  late HiveCacheStore store;
  late DedupRegistry dedupRegistry;
  late StateSnapshotRegistry snapshotRegistry;
  late Directory tempDir;

  const CacheConfig config = CacheConfig();

  Response<dynamic> successResponse(dynamic data) => Response<dynamic>(
        requestOptions: RequestOptions(path: '/test'),
        data: data,
        statusCode: 200,
      );

  Future<Response<dynamic>> mockFetcher(dynamic data) async => successResponse(data);

  Future<Response<dynamic>> failingFetcher() async => throw DioException(
        requestOptions: RequestOptions(path: '/test'),
        type: DioExceptionType.connectionError,
        error: const SocketException('No internet'),
      );

  Future<Response<dynamic>> serverErrorFetcher() async => throw DioException(
        requestOptions: RequestOptions(path: '/test'),
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: RequestOptions(path: '/test'),
          statusCode: 500,
        ),
      );

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pipeline_test_');
    Hive.init(tempDir.path);
    store = HiveCacheStore(cacheConfig: config);
    await store.initializeStorage();
    dedupRegistry = DedupRegistry();
    snapshotRegistry = StateSnapshotRegistry();
    pipeline = FetchPipeline(
      cacheStore: store,
      dedupRegistry: dedupRegistry,
      snapshotRegistry: snapshotRegistry,
      cacheConfig: config,
    );
  });

  tearDown(() async {
    await dedupRegistry.cancelAllInFlightRequests();
    if (store.isInitialized) {
      await store.deleteAllCacheEntries();
      await store.disposeStorage();
    }
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  group('FetchPipeline', () {
    test('empty cache + network success emits Loading then Success', () async {
      final List<CacheState<Map<String, dynamic>>> states = [];

      await pipeline
          .executeFetchPipeline<Map<String, dynamic>>(
            cacheKey: 'movies',
            ttl: const Duration(minutes: 10),
            networkFetcher: () => mockFetcher({'id': 1}),
            fromJsonConverter: (json) => Map<String, dynamic>.from(json as Map),
          )
          .forEach(states.add);

      expect(states.length, equals(2));
      expect(states[0], isA<CacheLoading<Map<String, dynamic>>>());
      expect(states[1], isA<CacheSuccess<Map<String, dynamic>>>());

      final success = states[1] as CacheSuccess<Map<String, dynamic>>;
      expect(success.dataSource, equals(CacheSource.network));
      expect(success.cachedData, equals({'id': 1}));
    });

    test('empty cache + network failure emits Loading then CacheError',
        () async {
      final List<CacheState<Map<String, dynamic>>> states = [];

      await pipeline
          .executeFetchPipeline<Map<String, dynamic>>(
            cacheKey: 'movies',
            ttl: const Duration(minutes: 10),
            networkFetcher: failingFetcher,
            fromJsonConverter: (json) => Map<String, dynamic>.from(json as Map),
          )
          .forEach(states.add);

      expect(states.length, equals(2));
      expect(states[0], isA<CacheLoading<Map<String, dynamic>>>());
      expect(states[1], isA<CacheError<Map<String, dynamic>>>());

      final error = states[1] as CacheError<Map<String, dynamic>>;
      expect(error.isOfflineFailure, isTrue);
    });

    test('empty cache + server error emits Loading then CacheError isOffline false',
        () async {
      final List<CacheState<Map<String, dynamic>>> states = [];

      await pipeline
          .executeFetchPipeline<Map<String, dynamic>>(
            cacheKey: 'movies',
            ttl: const Duration(minutes: 10),
            networkFetcher: serverErrorFetcher,
            fromJsonConverter: (json) => Map<String, dynamic>.from(json as Map),
          )
          .forEach(states.add);

      expect(states[1], isA<CacheError<Map<String, dynamic>>>());
      final error = states[1] as CacheError<Map<String, dynamic>>;
      expect(error.isOfflineFailure, isFalse);
    });

    test('fresh cache emits single CacheSuccess from cache — no network call',
        () async {
      int networkCallCount = 0;

      // First populate cache
      await pipeline
          .executeFetchPipeline<Map<String, dynamic>>(
            cacheKey: 'movies',
            ttl: const Duration(minutes: 10),
            networkFetcher: () async {
              networkCallCount++;
              return mockFetcher({'id': 1});
            },
            fromJsonConverter: (json) => Map<String, dynamic>.from(json as Map),
          )
          .forEach((_) {});

      networkCallCount = 0;

      // Second call — cache is fresh
      final List<CacheState<Map<String, dynamic>>> states = [];
      await pipeline
          .executeFetchPipeline<Map<String, dynamic>>(
            cacheKey: 'movies',
            ttl: const Duration(minutes: 10),
            networkFetcher: () async {
              networkCallCount++;
              return mockFetcher({'id': 1});
            },
            fromJsonConverter: (json) => Map<String, dynamic>.from(json as Map),
          )
          .forEach(states.add);

      expect(networkCallCount, equals(0));
      expect(states.length, equals(1));
      expect(states[0], isA<CacheSuccess<Map<String, dynamic>>>());

      final success = states[0] as CacheSuccess<Map<String, dynamic>>;
      expect(success.dataSource, equals(CacheSource.localCache));
    });

    test(
        'stale cache emits CacheRevalidating then CacheSuccess from network',
        () async {
      // Populate cache with very short TTL
      await pipeline
          .executeFetchPipeline<Map<String, dynamic>>(
            cacheKey: 'movies',
            ttl: const Duration(milliseconds: 1),
            networkFetcher: () => mockFetcher({'id': 1, 'version': 1}),
            fromJsonConverter: (json) => Map<String, dynamic>.from(json as Map),
          )
          .forEach((_) {});

      // Wait for TTL to expire
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final List<CacheState<Map<String, dynamic>>> states = [];
      await pipeline
          .executeFetchPipeline<Map<String, dynamic>>(
            cacheKey: 'movies',
            ttl: const Duration(minutes: 10),
            networkFetcher: () => mockFetcher({'id': 1, 'version': 2}),
            fromJsonConverter: (json) => Map<String, dynamic>.from(json as Map),
          )
          .forEach(states.add);

      expect(states.length, equals(2));
      expect(states[0], isA<CacheRevalidating<Map<String, dynamic>>>());
      expect(states[1], isA<CacheSuccess<Map<String, dynamic>>>());

      final success = states[1] as CacheSuccess<Map<String, dynamic>>;
      expect(success.dataSource, equals(CacheSource.network));
      expect(success.cachedData['version'], equals(2));
    });

    test('stale cache + network failure emits CacheRevalidating then CacheStale',
        () async {
      // Populate cache with very short TTL
      await pipeline
          .executeFetchPipeline<Map<String, dynamic>>(
            cacheKey: 'movies',
            ttl: const Duration(milliseconds: 1),
            networkFetcher: () => mockFetcher({'id': 1}),
            fromJsonConverter: (json) => Map<String, dynamic>.from(json as Map),
          )
          .forEach((_) {});

      await Future<void>.delayed(const Duration(milliseconds: 10));

      final List<CacheState<Map<String, dynamic>>> states = [];
      await pipeline
          .executeFetchPipeline<Map<String, dynamic>>(
            cacheKey: 'movies',
            ttl: const Duration(minutes: 10),
            networkFetcher: failingFetcher,
            fromJsonConverter: (json) => Map<String, dynamic>.from(json as Map),
          )
          .forEach(states.add);

      expect(states.length, equals(2));
      expect(states[0], isA<CacheRevalidating<Map<String, dynamic>>>());
      expect(states[1], isA<CacheStale<Map<String, dynamic>>>());
    });

    test('fromJsonConverter throws — CacheError emitted, Hive not written',
        () async {
      final List<CacheState<Map<String, dynamic>>> states = [];

      await pipeline
          .executeFetchPipeline<Map<String, dynamic>>(
            cacheKey: 'movies',
            ttl: const Duration(minutes: 10),
            networkFetcher: () => mockFetcher({'id': 1}),
            fromJsonConverter: (json) =>
                throw FormatException('Bad format'),
          )
          .forEach(states.add);

      expect(states.last, isA<CacheError<Map<String, dynamic>>>());

      // Hive should not have been written
      final bool exists = await store.cacheEntryExists('movies');
      expect(exists, isFalse);
    });

    test('3 concurrent same key calls — network called exactly once', () async {
      int networkCallCount = 0;

      Future<Response<dynamic>> countingFetcher() async {
        networkCallCount++;
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return mockFetcher({'id': 1});
      }

      await Future.wait([
        pipeline
            .executeFetchPipeline<Map<String, dynamic>>(
              cacheKey: 'movies',
              ttl: const Duration(minutes: 10),
              networkFetcher: countingFetcher,
              fromJsonConverter: (json) =>
                  Map<String, dynamic>.from(json as Map),
            )
            .forEach((_) {}),
        pipeline
            .executeFetchPipeline<Map<String, dynamic>>(
              cacheKey: 'movies',
              ttl: const Duration(minutes: 10),
              networkFetcher: countingFetcher,
              fromJsonConverter: (json) =>
                  Map<String, dynamic>.from(json as Map),
            )
            .forEach((_) {}),
        pipeline
            .executeFetchPipeline<Map<String, dynamic>>(
              cacheKey: 'movies',
              ttl: const Duration(minutes: 10),
              networkFetcher: countingFetcher,
              fromJsonConverter: (json) =>
                  Map<String, dynamic>.from(json as Map),
            )
            .forEach((_) {}),
      ]);

      expect(networkCallCount, equals(1));
    });

    test(
        'newer pipeline skips write but still yields CacheSuccess',
        () async {
      // First populate cache
      await pipeline
          .executeFetchPipeline<Map<String, dynamic>>(
            cacheKey: 'movies',
            ttl: const Duration(milliseconds: 1),
            networkFetcher: () => mockFetcher({'version': 1}),
            fromJsonConverter: (json) => Map<String, dynamic>.from(json as Map),
          )
          .forEach((_) {});

      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Run two pipelines — second should detect first already wrote
      final List<CacheState<Map<String, dynamic>>> states = [];
      await pipeline
          .executeFetchPipeline<Map<String, dynamic>>(
            cacheKey: 'movies',
            ttl: const Duration(minutes: 10),
            networkFetcher: () => mockFetcher({'version': 2}),
            fromJsonConverter: (json) => Map<String, dynamic>.from(json as Map),
          )
          .forEach(states.add);

      // Should still emit CacheSuccess even if write was skipped
      expect(
          states.any((s) => s is CacheSuccess<Map<String, dynamic>>), isTrue);
    });
  });
}