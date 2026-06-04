import 'package:mutex/mutex.dart';
import 'package:dio/dio.dart';

/// Manages deduplication of in-flight network requests.
/// If the same cache key is already being fetched, returns the
/// existing Future instead of starting a duplicate network request.
///
/// ## CancelToken Semantics
/// Cancellation is per-key not per-subscriber. Cancelling a key's
/// request cancels ALL waiters for that key. This is intentional —
/// only cancel on coordinator dispose, not on individual subscriber dispose.
/// Document this limitation in README.
class DedupRegistry {
  /// Protects read/write access to [_inFlightRequestMap]
  /// and [_cancelTokenMap].
  /// Bug E fix — mutex protects map access only, never network execution.
  final Mutex _mapAccessMutex = Mutex();

  /// Map of currently in-flight network request futures keyed by cache key.
  final Map<String, Future<dynamic>> _inFlightRequestMap = {};

  /// Map of [CancelToken] per in-flight request.
  /// Used to actually cancel underlying Dio requests on disposal.
  final Map<String, CancelToken> _cancelTokenMap = {};

  /// Executes [networkFetcher] for [cacheKey] with deduplication.
  /// If a request for [cacheKey] is already in flight, waits for
  /// the existing Future — no duplicate network request is made.
  ///
  /// Bug E fix — future reference captured inside mutex,
  /// awaited OUTSIDE mutex so other keys are never blocked.
  Future<dynamic> executeWithDeduplication(
    String cacheKey,
    Future<Response<dynamic>> Function() networkFetcher,
  ) async {
    // Capture future reference inside mutex — map access only
    final Future<dynamic> targetFuture =
        await _mapAccessMutex.protect(() async {
      if (!_inFlightRequestMap.containsKey(cacheKey)) {
        final CancelToken cancelToken = CancelToken();
        _cancelTokenMap[cacheKey] = cancelToken;
        _inFlightRequestMap[cacheKey] = _executeFetch(
          cacheKey,
          networkFetcher,
          cancelToken,
        );
      }
      return _inFlightRequestMap[cacheKey]!;
    });

    // Await future OUTSIDE mutex — other keys unblocked immediately
    return await targetFuture;
  }

  /// Returns true if a request for [cacheKey] is currently in flight.
  Future<bool> isRequestInFlight(String cacheKey) async {
    return await _mapAccessMutex.protect(() async {
      return _inFlightRequestMap.containsKey(cacheKey);
    });
  }

  /// Cancels the in-flight request for [cacheKey] if one exists.
  /// Cancels the underlying Dio request via [CancelToken].
  /// Note: cancels ALL waiters for this key, not just one subscriber.
  Future<void> cancelRequest(String cacheKey) async {
    await _mapAccessMutex.protect(() async {
      final CancelToken? cancelToken = _cancelTokenMap[cacheKey];
      if (cancelToken != null && !cancelToken.isCancelled) {
        cancelToken.cancel(
          'flutter_offline_cache: Request cancelled for key: $cacheKey',
        );
      }
      _cancelTokenMap.remove(cacheKey);
      _inFlightRequestMap.remove(cacheKey);
    });
  }

  /// Cancels all in-flight Dio requests and clears both maps.
  /// Call this on coordinator dispose.
  Future<void> cancelAllInFlightRequests() async {
    await _mapAccessMutex.protect(() async {
      for (final CancelToken cancelToken in _cancelTokenMap.values) {
        if (!cancelToken.isCancelled) {
          cancelToken.cancel(
            'flutter_offline_cache: All requests cancelled — '
            'coordinator disposed.',
          );
        }
      }
      _cancelTokenMap.clear();
      _inFlightRequestMap.clear();
    });
  }

  /// Executes the network fetch and removes both map entries
  /// on both success and failure via finally block.
  Future<dynamic> _executeFetch(
    String cacheKey,
    Future<Response<dynamic>> Function() networkFetcher,
    CancelToken cancelToken,
  ) async {
    try {
      final Response<dynamic> response = await networkFetcher();
      return response.data;
    } finally {
      // Bug 13 fix — check key exists before removing
      // in case cancelAllInFlightRequests already cleared the map
      await _mapAccessMutex.protect(() async {
        if (_inFlightRequestMap.containsKey(cacheKey)) {
          _inFlightRequestMap.remove(cacheKey);
        }
        if (_cancelTokenMap.containsKey(cacheKey)) {
          _cancelTokenMap.remove(cacheKey);
        }
      });
    }
  }
}