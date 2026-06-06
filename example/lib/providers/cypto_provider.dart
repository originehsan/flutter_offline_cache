import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_offline_cache/flutter_offline_cache.dart';
import '../models/crypto_coin.dart';
import '../repositories/crypto_repository.dart';

final cacheCoordinatorProvider = Provider<CacheCoordinator>((ref) {
  final coordinator = CacheCoordinator(
    cacheConfig: const CacheConfig(
      defaultTtl: Duration(seconds: 30),
      enableDebugLogs: true,
    ),
  );
  ref.onDispose(coordinator.dispose);
  return coordinator;
});
final cryptoRepositoryProvider = Provider<CryptoRepository>((ref) {
  final coordinator = ref.watch(cacheCoordinatorProvider);
  return CryptoRepository(coordinator: coordinator);
});

final topCoinsProvider =
    StreamProvider<CacheState<List<CryptoCoin>>>((ref) {
  final repository = ref.watch(cryptoRepositoryProvider);
  return repository.watchTopCoins();
});