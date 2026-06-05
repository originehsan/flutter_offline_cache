import 'package:dio/dio.dart';
import 'package:flutter_offline_cache/flutter_offline_cache.dart';
import '../models/crypto_coin.dart';

/// Crypto repository using CoinGecko public API.
/// Demonstrates flutter_offline_cache with real changing data.
class CryptoRepository {
  final CacheCoordinator _coordinator;
  final Dio _dio;

  bool isOfflineSimulated = false;

  CryptoRepository({required CacheCoordinator coordinator})
      : _coordinator = coordinator,
        _dio = Dio(
          BaseOptions(
            baseUrl: 'https://api.coingecko.com/api/v3',
            connectTimeout: const Duration(seconds: 10),
            receiveTimeout: const Duration(seconds: 10),
            headers: {
              'Accept': 'application/json',
            },
          ),
        );

  /// Watches top 10 coins by market cap.
  /// TTL set to 30 seconds — cache expires quickly so
  /// data changes are visible without waiting long.
  Stream<CacheState<List<CryptoCoin>>> watchTopCoins() {
    return _coordinator.cachedFetch<List<CryptoCoin>>(
      namespace: 'CryptoRepository',
      key: 'top_coins',
      ttl: const Duration(seconds: 30),
      networkFetcher: _fetchTopCoins,
      fromJsonConverter: (json) => (json as List<dynamic>)
          .map((e) => CryptoCoin.fromJson(
                Map<String, dynamic>.from(e as Map),
              ))
          .toList(),
    );
  }

  /// Hard resets cache — clears and refetches from network.
  Future<void> hardResetCoins() async {
    await _coordinator.invalidate(
      namespace: 'CryptoRepository',
      key: 'top_coins',
    );
  }

  Future<Response<dynamic>> _fetchTopCoins() async {
    if (isOfflineSimulated) {
      throw DioException(
        requestOptions: RequestOptions(path: '/coins/markets'),
        type: DioExceptionType.connectionError,
      );
    }

    return _dio.get(
      '/coins/markets',
      queryParameters: {
        'vs_currency': 'usd',
        'order': 'market_cap_desc',
        'per_page': 10,
        'page': 1,
        'sparkline': false,
      },
    );
  }
}