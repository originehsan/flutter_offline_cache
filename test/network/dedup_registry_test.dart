import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:flutter_offline_cache/src/network/dedup_registry.dart';

void main() {
  group('DedupRegistry', () {
    late DedupRegistry registry;

    setUp(() {
      registry = DedupRegistry();
    });

    tearDown(() async {
      await registry.cancelAllInFlightRequests();
    });

    test('two concurrent calls same key — network called exactly once',
        () async {
      int callCount = 0;

      Future<Response<dynamic>> mockFetcher() async {
        callCount++;
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return Response<dynamic>(
          requestOptions: RequestOptions(path: '/test'),
          data: {'result': 'data'},
          statusCode: 200,
        );
      }

      final Future<dynamic> call1 =
          registry.executeWithDeduplication('movies', mockFetcher);
      final Future<dynamic> call2 =
          registry.executeWithDeduplication('movies', mockFetcher);

      await Future.wait([call1, call2]);

      expect(callCount, equals(1));
    });

    test('two concurrent calls same key — both receive same result', () async {
      Future<Response<dynamic>> mockFetcher() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return Response<dynamic>(
          requestOptions: RequestOptions(path: '/test'),
          data: {'result': 'shared'},
          statusCode: 200,
        );
      }

      final Future<dynamic> call1 =
          registry.executeWithDeduplication('movies', mockFetcher);
      final Future<dynamic> call2 =
          registry.executeWithDeduplication('movies', mockFetcher);

      final List<dynamic> results = await Future.wait([call1, call2]);

      expect(results[0], equals({'result': 'shared'}));
      expect(results[1], equals({'result': 'shared'}));
    });

    test('different keys fire separate network requests', () async {
      int moviesCallCount = 0;
      int seriesCallCount = 0;

      Future<Response<dynamic>> moviesFetcher() async {
        moviesCallCount++;
        return Response<dynamic>(
          requestOptions: RequestOptions(path: '/movies'),
          data: 'movies',
          statusCode: 200,
        );
      }

      Future<Response<dynamic>> seriesFetcher() async {
        seriesCallCount++;
        return Response<dynamic>(
          requestOptions: RequestOptions(path: '/series'),
          data: 'series',
          statusCode: 200,
        );
      }

      await Future.wait([
        registry.executeWithDeduplication('movies', moviesFetcher),
        registry.executeWithDeduplication('series', seriesFetcher),
      ]);

      expect(moviesCallCount, equals(1));
      expect(seriesCallCount, equals(1));
    });

    test('failed request removes key from map — next call retries network',
        () async {
      int callCount = 0;

      Future<Response<dynamic>> failingFetcher() async {
        callCount++;
        throw DioException(
          requestOptions: RequestOptions(path: '/test'),
          type: DioExceptionType.connectionError,
        );
      }

      try {
        await registry.executeWithDeduplication('movies', failingFetcher);
      } catch (_) {}

      try {
        await registry.executeWithDeduplication('movies', failingFetcher);
      } catch (_) {}

      expect(callCount, equals(2));
    });

    test('map is empty after successful request completes', () async {
      Future<Response<dynamic>> mockFetcher() async {
        return Response<dynamic>(
          requestOptions: RequestOptions(path: '/test'),
          data: 'data',
          statusCode: 200,
        );
      }

      await registry.executeWithDeduplication('movies', mockFetcher);

      final bool inFlight = await registry.isRequestInFlight('movies');
      expect(inFlight, isFalse);
    });

    test('map is empty after failed request completes', () async {
      Future<Response<dynamic>> failingFetcher() async {
        throw DioException(
          requestOptions: RequestOptions(path: '/test'),
          type: DioExceptionType.connectionError,
        );
      }

      try {
        await registry.executeWithDeduplication('movies', failingFetcher);
      } catch (_) {}

      final bool inFlight = await registry.isRequestInFlight('movies');
      expect(inFlight, isFalse);
    });

    test('cancelAllInFlightRequests clears all entries', () async {
      Future<Response<dynamic>> hangingFetcher() async {
        await Future<void>.delayed(const Duration(seconds: 60));
        return Response<dynamic>(
          requestOptions: RequestOptions(path: '/test'),
          data: 'data',
          statusCode: 200,
        );
      }

      // Start request but do not await it
      unawaited(
        registry
            .executeWithDeduplication('movies', hangingFetcher)
            .catchError((_) => null),
      );

      // Give it a moment to register in map
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final bool inFlightBefore = await registry.isRequestInFlight('movies');
      expect(inFlightBefore, isTrue);

      await registry.cancelAllInFlightRequests();

      final bool inFlightAfter = await registry.isRequestInFlight('movies');
      expect(inFlightAfter, isFalse);
    });
  });
}