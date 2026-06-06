import 'dart:async';
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

  /// Timer that fires every second to update the cache age countdown.
  /// Makes SWR behavior visually obvious — user watches countdown to revalidation.
  Timer? _bannerRefreshTimer;

  @override
  void initState() {
    super.initState();
    _initialize();
    _startBannerRefreshTimer();
  }

  @override
  void dispose() {
    _bannerRefreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _initialize() async {
    final coordinator = ref.read(cacheCoordinatorProvider);
    await coordinator.initialize();
    if (mounted) setState(() => _isInitialized = true);
  }

  /// Rebuilds banner every second so cache age and countdown update live.
  void _startBannerRefreshTimer() {
    _bannerRefreshTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        if (mounted) setState(() {});
      },
    );
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
        children: const [
          Text(
            'flutter_offline_cache',
            style: TextStyle(
              color: Color(0xFF58A6FF),
              fontSize: 14,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
            ),
          ),
          Text(
            'Top 10 Coins — CoinGecko · TTL 30s',
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
      CacheLoading() => _buildLoadingState(),
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
      CacheStale(:final cachedData, :final refreshError) => _buildCoinList(
          coins: cachedData,
          dataSource: CacheSource.localCache,
          metadata: null,
          isRevalidating: false,
          isStale: true,
          staleError: refreshError,
        ),
      CacheError(:final errorClassification) =>
        _buildErrorState(errorClassification),
    };
  }

  Widget _buildLoadingState() {
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          color: const Color(0xFF0D1A2D),
          child: const Text(
            'Fetching live prices for the first time...',
            style: TextStyle(
              color: Color(0xFFB0BAC5),
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        const Expanded(
          child: Center(
            child: CircularProgressIndicator(color: Color(0xFF58A6FF)),
          ),
        ),
      ],
    );
  }

  Widget _buildCoinList({
    required List<CryptoCoin> coins,
    required CacheSource dataSource,
    required CacheMetadata? metadata,
    required bool isRevalidating,
    bool isStale = false,
    Object? staleError,
  }) {
    return Column(
      children: [
        _buildStatusBanner(
          dataSource: dataSource,
          metadata: metadata,
          isRevalidating: isRevalidating,
          isStale: isStale,
          staleError: staleError,
        ),
        if (metadata != null) _buildMetadataRow(metadata),
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

  /// Status banner — changes color and text based on cache state.
  Widget _buildStatusBanner({
    required CacheSource dataSource,
    required CacheMetadata? metadata,
    required bool isRevalidating,
    bool isStale = false,
    Object? staleError,
  }) {
    Color bannerColor;
    String bannerText;
    Color textColor;

    if (isStale) {
      bannerColor = const Color(0xFF3D2000);
      textColor = const Color(0xFFE3A000);
      final errorMsg = staleError is Exception
          ? staleError.toString().replaceAll('Exception: ', '')
          : 'Network error';
      bannerColor = const Color(0xFF3D2000);
      bannerText = 'Could not refresh — $errorMsg — showing cached data';
    } else if (isRevalidating) {
      bannerColor = const Color(0xFF0D2137);
      textColor = const Color(0xFF58A6FF);
      bannerText = 'Fetching latest prices in background...';
    } else if (dataSource == CacheSource.localCache) {
      bannerColor = const Color(0xFF1A1033);
      textColor = const Color(0xFFB0BAC5);
      bannerText = 'Serving from cache';
    } else {
      bannerColor = const Color(0xFF0D2119);
      textColor = const Color(0xFF3FB950);
      bannerText = metadata != null
          ? 'Live data fetched at ${_formatTime(metadata.cachedAtMillis)}'
          : 'Live data from network';
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: bannerColor,
      child: Row(
        children: [
          Expanded(
            child: Text(
              bannerText,
              style: TextStyle(
                color: textColor,
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

  /// Metadata row — shows live countdown to next revalidation.
  /// Updates every second via _bannerRefreshTimer.
  /// This makes SWR behavior visually obvious to recruiters.
  Widget _buildMetadataRow(CacheMetadata metadata) {
    final Duration age = metadata.ageOfCachedData;
    final Duration remaining = metadata.remainingValidDuration;
    final bool isExpiringSoon = remaining.inSeconds <= 5;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      color: const Color(0xFF0D1117),
      child: Row(
        children: [
          // Cache age
          _buildMetaChip(
            label: 'Cached',
            value: '${age.inSeconds}s ago',
            color: const Color(0xFF484F58),
          ),
          const SizedBox(width: 8),
          // Time until revalidation
          _buildMetaChip(
            label: 'Refreshes in',
            value: remaining == Duration.zero
                ? 'now'
                : '${remaining.inSeconds}s',
            color: isExpiringSoon
                ? const Color(0xFFE3A000)
                : const Color(0xFF484F58),
          ),
          const SizedBox(width: 8),
          // Source
          _buildMetaChip(
            label: 'Source',
            value: metadata.source == CacheSource.network
                ? 'network'
                : 'cache',
            color: metadata.source == CacheSource.network
                ? const Color(0xFF3FB950)
                : const Color(0xFF58A6FF),
          ),
        ],
      ),
    );
  }

  Widget _buildMetaChip({
    required String label,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: RichText(
        text: TextSpan(
          children: [
            TextSpan(
              text: '$label: ',
              style: const TextStyle(
                color: Color(0xFF484F58),
                fontSize: 10,
              ),
            ),
            TextSpan(
              text: value,
              style: TextStyle(
                color: color,
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
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
        border: Border.all(color: const Color(0xFF30363D)),
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

  Widget _buildErrorState(ErrorClassification classification) {
    final bool isOffline =
        classification == ErrorClassification.offlineFailure;
    final bool isTimeout =
        classification == ErrorClassification.timeoutFailure;
    final bool isRateLimit =
        classification == ErrorClassification.rateLimitFailure;

    final String title;
    final String subtitle;

    if (isOffline) {
      title = 'No internet connection';
      subtitle = 'Turn off offline mode or check your connection';
    } else if (isTimeout) {
      title = 'Request timed out';
      subtitle = 'Server is slow or unreachable. Try again.';
    } else if (isRateLimit) {
      title = 'Rate limited by CoinGecko';
      subtitle =
          'Too many requests. Wait a moment then try again.';
    } else {
      title = 'Something went wrong';
      subtitle = 'CoinGecko API returned an error. Try again.';
    }

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
              title,
              style: const TextStyle(
                color: Color(0xFFE6EDF3),
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFF8B949E),
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 24),
            OutlinedButton(
              onPressed: () async {
                await ref
                    .read(cryptoRepositoryProvider)
                    .hardResetCoins();
                ref.read(cryptoResetCounterProvider.notifier).state++;
              },
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF58A6FF),
                side: const BorderSide(color: Color(0xFF30363D)),
              ),
              child: const Text('Retry'),
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
  String _formatTime(int millis) {
    final dt = DateTime.fromMillisecondsSinceEpoch(millis);
    return '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}:'
        '${dt.second.toString().padLeft(2, '0')}';
  }
}