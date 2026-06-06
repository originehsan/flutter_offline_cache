import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_offline_cache/flutter_offline_cache.dart';
import '../models/crypto_coin.dart';
import '../repositories/crypto_repository.dart';

/// Global CacheCoordinator instance.
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

/// Global CryptoRepository instance.
final cryptoRepositoryProvider = Provider<CryptoRepository>((ref) {
  final coordinator = ref.watch(cacheCoordinatorProvider);
  return CryptoRepository(coordinator: coordinator);
});

/// Counter to force hard reset — incremented by Hard Reset button.
final cryptoResetCounterProvider = StateProvider<int>((ref) => 0);

/// Stream provider for top 10 coins.
/// Automatically revalidates when TTL expires (every 30 seconds).
/// Hard reset when counter changes.
final topCoinsProvider =
    StreamProvider<CacheState<List<CryptoCoin>>>((ref) {
  ref.watch(cryptoResetCounterProvider);
  final repository = ref.watch(cryptoRepositoryProvider);
  return repository.watchTopCoins();
});