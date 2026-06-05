import 'package:flutter/material.dart';
import 'package:flutter_offline_cache_example/providers/cypto_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_offline_cache/flutter_offline_cache.dart';
import '../models/crypto_coin.dart';

class CryptoScreen extends ConsumerStatefulWidget {
  const CryptoScreen({super.key});

  @override
  ConsumerState<CryptoScreen> createState() => _CryptoScreenState();
}

class _CryptoScreenState extends ConsumerState<CryptoScreen> {
  bool _isOfflineSimulated = false;
  bool _isInitialized = false;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    final coordinator = ref.read(cacheCoordinatorProvider);
    await coordinator.initialize();
    if (mounted) setState(() => _isInitialized = true);
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) {
      return const Scaffold(
        backgroundColor: Color(0xFF0D1117),
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFF58A6FF)),
        ),
      );
    }

    final coinsAsync = ref.watch(topCoinsProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: _buildAppBar(),
      body: coinsAsync.when(
        data: (cacheState) => _buildBody(cacheState),
        loading: () => const Center(
          child: CircularProgressIndicator(color: Color(0xFF58A6FF)),
        ),
        error: (e, _) => _buildErrorBody(e.toString()),
      ),
      bottomNavigationBar: _buildBottomBar(),
    );
  }

  AppBar _buildAppBar() {
    return AppBar(
      backgroundColor: const Color(0xFF161B22),
      elevation: 0,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'flutter_offline_cache',
            style: TextStyle(
              color: Color(0xFF58A6FF),
              fontSize: 14,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
            ),
          ),
          const Text(
            'Top 10 Coins — CoinGecko',
            style: TextStyle(
              color: Color(0xFF8B949E),
              fontSize: 11,
            ),
          ),
        ],
      ),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Row(
            children: [
              Text(
                _isOfflineSimulated ? 'Offline' : 'Online',
                style: TextStyle(
                  color: _isOfflineSimulated
                      ? const Color(0xFFF85149)
                      : const Color(0xFF3FB950),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Switch(
                value: _isOfflineSimulated,
                onChanged: (value) {
                  setState(() => _isOfflineSimulated = value);
                  ref.read(cryptoRepositoryProvider).isOfflineSimulated =
                      value;
                },
                activeColor: const Color(0xFFF85149),
                inactiveThumbColor: const Color(0xFF3FB950),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildBody(CacheState<List<CryptoCoin>> cacheState) {
    return switch (cacheState) {
      CacheInitial() => const Center(
          child: CircularProgressIndicator(color: Color(0xFF58A6FF)),
        ),
      CacheLoading() => const Center(
          child: CircularProgressIndicator(color: Color(0xFF58A6FF)),
        ),
      CacheSuccess(:final cachedData, :final dataSource, :final entryMetadata) =>
        _buildCoinList(
          coins: cachedData,
          dataSource: dataSource,
          metadata: entryMetadata,
          isRevalidating: false,
        ),
      CacheRevalidating(:final cachedData, :final entryMetadata) =>
        _buildCoinList(
          coins: cachedData,
          dataSource: CacheSource.localCache,
          metadata: entryMetadata,
          isRevalidating: true,
        ),
      CacheStale(:final cachedData) => _buildCoinList(
          coins: cachedData,
          dataSource: CacheSource.localCache,
          metadata: null,
          isRevalidating: false,
          isStale: true,
        ),
      CacheError(:final isOfflineFailure) => _buildErrorState(isOfflineFailure),
    };
  }

  Widget _buildCoinList({
    required List<CryptoCoin> coins,
    required CacheSource dataSource,
    required CacheMetadata? metadata,
    required bool isRevalidating,
    bool isStale = false,
  }) {
    return Column(
      children: [
        _buildStatusBanner(
          dataSource: dataSource,
          metadata: metadata,
          isRevalidating: isRevalidating,
          isStale: isStale,
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            itemCount: coins.length,
            itemBuilder: (context, index) =>
                _buildCoinCard(coins[index], index),
          ),
        ),
      ],
    );
  }

  Widget _buildStatusBanner({
    required CacheSource dataSource,
    required CacheMetadata? metadata,
    required bool isRevalidating,
    bool isStale = false,
  }) {
    Color bannerColor;
    String bannerText;

    if (isStale) {
      bannerColor = const Color(0xFF3D2900);
      bannerText = 'Could not refresh — showing cached data';
    } else if (isRevalidating) {
      bannerColor = const Color(0xFF0D2137);
      bannerText = 'Fetching latest prices...';
    } else if (dataSource == CacheSource.localCache) {
      final age = metadata?.ageOfCachedData;
      final remaining = metadata?.remainingValidDuration;
      bannerColor = const Color(0xFF1A1033);
      bannerText = metadata != null
          ? 'Cached ${_formatDuration(age!)} ago — refreshes in ${_formatDuration(remaining!)}'
          : 'Served from cache';
    } else {
      bannerColor = const Color(0xFF0D2119);
      bannerText = metadata != null
          ? 'Live data — cached at ${_formatTime(metadata.cachedAtMillis)}'
          : 'Live data from network';
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: bannerColor,
      child: Row(
        children: [
          Expanded(
            child: Text(
              bannerText,
              style: const TextStyle(
                color: Color(0xFFB0BAC5),
                fontSize: 11,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.2,
              ),
            ),
          ),
          if (isRevalidating)
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: Color(0xFF58A6FF),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCoinCard(CryptoCoin coin, int index) {
    final bool isUp = coin.isPriceUp;
    final Color changeColor =
        isUp ? const Color(0xFF3FB950) : const Color(0xFFF85149);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: const Color(0xFF30363D),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          // Rank
          SizedBox(
            width: 28,
            child: Text(
              '#${coin.marketCapRank}',
              style: const TextStyle(
                color: Color(0xFF484F58),
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Symbol badge
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: const Color(0xFF21262D),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF30363D)),
            ),
            child: Center(
              child: Text(
                coin.symbol.length > 3
                    ? coin.symbol.substring(0, 3)
                    : coin.symbol,
                style: const TextStyle(
                  color: Color(0xFF58A6FF),
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Name + price
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  coin.name,
                  style: const TextStyle(
                    color: Color(0xFFE6EDF3),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _formatPrice(coin.currentPrice),
                  style: const TextStyle(
                    color: Color(0xFF8B949E),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          // 24h change
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: changeColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: changeColor.withValues(alpha: 0.3),
                    width: 1,
                  ),
                ),
                child: Text(
                  '${isUp ? '+' : ''}${coin.priceChangePercentage24h.toStringAsFixed(2)}%',
                  style: TextStyle(
                    color: changeColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'H: ${_formatPrice(coin.high24h)}',
                style: const TextStyle(
                  color: Color(0xFF484F58),
                  fontSize: 10,
                ),
              ),
              Text(
                'L: ${_formatPrice(coin.low24h)}',
                style: const TextStyle(
                  color: Color(0xFF484F58),
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState(bool isOffline) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.signal_wifi_off_rounded,
              color: Color(0xFF484F58),
              size: 48,
            ),
            const SizedBox(height: 16),
            Text(
              isOffline
                  ? 'No internet connection'
                  : 'Something went wrong',
              style: const TextStyle(
                color: Color(0xFFE6EDF3),
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              isOffline
                  ? 'Turn off offline mode or check your connection'
                  : 'CoinGecko API may be rate limiting. Try again.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFF8B949E),
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorBody(String error) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          'Error: $error',
          style: const TextStyle(color: Color(0xFFF85149)),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      decoration: const BoxDecoration(
        color: Color(0xFF161B22),
        border: Border(top: BorderSide(color: Color(0xFF30363D))),
      ),
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton(
          onPressed: () async {
            await ref.read(cryptoRepositoryProvider).hardResetCoins();
            ref.read(cryptoResetCounterProvider.notifier).state++;
          },
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFFF85149),
            side: const BorderSide(color: Color(0xFF30363D)),
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          child: const Text(
            'Hard Reset Cache',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 14,
            ),
          ),
        ),
      ),
    );
  }

  String _formatPrice(double price) {
    if (price >= 1000) {
      return '\$${price.toStringAsFixed(0).replaceAllMapped(
            RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
            (m) => '${m[1]},',
          )}';
    } else if (price >= 1) {
      return '\$${price.toStringAsFixed(2)}';
    } else {
      return '\$${price.toStringAsFixed(6)}';
    }
  }

  String _formatDuration(Duration d) {
    if (d.inSeconds < 60) return '${d.inSeconds}s';
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    return '${d.inHours}h';
  }

  String _formatTime(int millis) {
    final dt = DateTime.fromMillisecondsSinceEpoch(millis);
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
  }
}