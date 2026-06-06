import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';

/// Classification of a network error.
enum ErrorClassification {
  /// Device has no internet connectivity.
  /// Show offline message. Serve cached data if available.
  offlineFailure,

  /// Network request timed out.
  /// Server may be slow or unreachable.
  /// Not necessarily offline — serve cached data if available.
  timeoutFailure,

  /// API rate limit exceeded — HTTP 429.
  /// Developer should handle retry logic in their networkFetcher.
  rateLimitFailure,

  /// Error caused by server response or request issue.
  /// Show generic error message.
  serverFailure,
}

/// Classifies network errors into specific failure types.
/// Used by [FetchPipeline] to decide which [CacheState] to emit.
class ErrorClassifier {
  ErrorClassifier._();

  /// Classifies [networkError] into an [ErrorClassification].
  ///
  /// Classification order:
  /// 1. [TimeoutException] from dart:async `.timeout()` → timeoutFailure
  /// 2. Non-Dio errors → serverFailure
  /// 3. HTTP 429 → rateLimitFailure
  /// 4. Dio connection errors → offlineFailure
  /// 5. Dio timeout errors → timeoutFailure
  /// 6. Everything else → serverFailure
  static ErrorClassification classifyNetworkError(Object networkError) {
    // Bug 5 fix — TimeoutException from dart:async .timeout() call
    // is not a DioException — must be checked first
    if (networkError is TimeoutException) {
      return ErrorClassification.timeoutFailure;
    }

    if (networkError is! DioException) {
      return ErrorClassification.serverFailure;
    }

    // Bug 10 fix — 429 rate limit deserves explicit classification
    if (networkError.response?.statusCode == 429) {
      return ErrorClassification.rateLimitFailure;
    }

    switch (networkError.type) {
      case DioExceptionType.connectionError:
        return ErrorClassification.offlineFailure;

      case DioExceptionType.connectionTimeout:
        // Connection timeout with SocketException = offline
        // Without SocketException = timeout (server unreachable)
        if (networkError.error is SocketException) {
          return ErrorClassification.offlineFailure;
        }
        return ErrorClassification.timeoutFailure;

      case DioExceptionType.receiveTimeout:
      case DioExceptionType.sendTimeout:
        return ErrorClassification.timeoutFailure;

      case DioExceptionType.unknown:
        return _classifyUnknownError(networkError);

      case DioExceptionType.badResponse:
      case DioExceptionType.cancel:
      case DioExceptionType.badCertificate:
        return ErrorClassification.serverFailure;
    }
  }

  /// Returns true if error should trigger cached data fallback.
  /// Both offline and timeout failures should serve cached data.
  static bool shouldServeCachedData(ErrorClassification classification) {
    return classification == ErrorClassification.offlineFailure ||
        classification == ErrorClassification.timeoutFailure;
  }

  /// Unknown Dio errors with [SocketException] inside are offline failures.
  static ErrorClassification _classifyUnknownError(DioException error) {
    if (error.error is SocketException) {
      return ErrorClassification.offlineFailure;
    }
    return ErrorClassification.serverFailure;
  }
}