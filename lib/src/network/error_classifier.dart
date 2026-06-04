import 'dart:io';
import 'package:dio/dio.dart';

/// Classification of a network error.
enum ErrorClassification {
  /// Error was caused by no internet connectivity.
  /// Show offline message to user.
  offlineFailure,

  /// Error was caused by server response or request issue.
  /// Show generic error message to user.
  serverFailure,
}

/// Classifies network errors into offline or server failures.
/// Used by [FetchPipeline] to decide which [CacheState] to emit.
class ErrorClassifier {
  ErrorClassifier._();

  /// Classifies [networkError] as either [ErrorClassification.offlineFailure]
  /// or [ErrorClassification.serverFailure].
  static ErrorClassification classifyNetworkError(Object networkError) {
    if (networkError is! DioException) {
      return ErrorClassification.serverFailure;
    }

    switch (networkError.type) {
      case DioExceptionType.connectionError:
        return ErrorClassification.offlineFailure;

      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.sendTimeout:
        return _classifyTimeoutError(networkError);

      case DioExceptionType.unknown:
        return _classifyUnknownError(networkError);

      case DioExceptionType.badResponse:
      case DioExceptionType.cancel:
      case DioExceptionType.badCertificate:
        return ErrorClassification.serverFailure;
    }
  }

  /// Timeout errors can be offline or server slowness.
  /// Check inner error for [SocketException] to confirm offline.
  static ErrorClassification _classifyTimeoutError(DioException error) {
    if (error.error is SocketException) {
      return ErrorClassification.offlineFailure;
    }
    return ErrorClassification.serverFailure;
  }

  /// Unknown Dio errors with [SocketException] inside are offline failures.
  static ErrorClassification _classifyUnknownError(DioException error) {
    if (error.error is SocketException) {
      return ErrorClassification.offlineFailure;
    }
    return ErrorClassification.serverFailure;
  }
}