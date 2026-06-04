import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:flutter_offline_cache/src/network/error_classifier.dart';

void main() {
  group('ErrorClassifier', () {
    test('connectionError classifies as offlineFailure', () {
      final DioException error = DioException(
        requestOptions: RequestOptions(path: '/test'),
        type: DioExceptionType.connectionError,
      );
      final ErrorClassification result =
          ErrorClassifier.classifyNetworkError(error);
      expect(result, equals(ErrorClassification.offlineFailure));
    });

    test('badResponse classifies as serverFailure', () {
      final DioException error = DioException(
        requestOptions: RequestOptions(path: '/test'),
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: RequestOptions(path: '/test'),
          statusCode: 500,
        ),
      );
      final ErrorClassification result =
          ErrorClassifier.classifyNetworkError(error);
      expect(result, equals(ErrorClassification.serverFailure));
    });

    test('cancel classifies as serverFailure', () {
      final DioException error = DioException(
        requestOptions: RequestOptions(path: '/test'),
        type: DioExceptionType.cancel,
      );
      final ErrorClassification result =
          ErrorClassifier.classifyNetworkError(error);
      expect(result, equals(ErrorClassification.serverFailure));
    });

    test('badCertificate classifies as serverFailure', () {
      final DioException error = DioException(
        requestOptions: RequestOptions(path: '/test'),
        type: DioExceptionType.badCertificate,
      );
      final ErrorClassification result =
          ErrorClassifier.classifyNetworkError(error);
      expect(result, equals(ErrorClassification.serverFailure));
    });

    test('non-Dio error classifies as serverFailure', () {
      final Exception error = Exception('Unknown error');
      final ErrorClassification result =
          ErrorClassifier.classifyNetworkError(error);
      expect(result, equals(ErrorClassification.serverFailure));
    });

    test('connectionTimeout with SocketException classifies as offlineFailure',
        () {
      final DioException error = DioException(
        requestOptions: RequestOptions(path: '/test'),
        type: DioExceptionType.connectionTimeout,
        error: const SocketException('No internet'),
      );
      final ErrorClassification result =
          ErrorClassifier.classifyNetworkError(error);
      expect(result, equals(ErrorClassification.offlineFailure));
    });

    test('connectionTimeout without SocketException classifies as serverFailure',
        () {
      final DioException error = DioException(
        requestOptions: RequestOptions(path: '/test'),
        type: DioExceptionType.connectionTimeout,
      );
      final ErrorClassification result =
          ErrorClassifier.classifyNetworkError(error);
      expect(result, equals(ErrorClassification.serverFailure));
    });

    test('unknown with SocketException classifies as offlineFailure', () {
      final DioException error = DioException(
        requestOptions: RequestOptions(path: '/test'),
        type: DioExceptionType.unknown,
        error: const SocketException('No internet'),
      );
      final ErrorClassification result =
          ErrorClassifier.classifyNetworkError(error);
      expect(result, equals(ErrorClassification.offlineFailure));
    });
  });
}