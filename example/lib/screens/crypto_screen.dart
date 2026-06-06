import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_offline_cache_example/providers/cypto_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_offline_cache/flutter_offline_cache.dart';
import '../models/crypto_coin.dart';

// Design tokens
class _C {
  // Backgrounds
  static const bg = Color(0xFFF6F8FA);
  static const surface = Color(0xFFFFFFFF);
  static const surfaceHover = Color(0xFFF3F4F6);

  // Borders
  static const border = Color(0xFFD0D7DE);

  // Text
  static const textPrimary = Color(0xFF1F2328);
  static const textSecondary = Color(0xFF636C76);
  static const textMuted = Color(0xFF8C959F);

  // State colors
  static const liveGreenBg = Color(0xFFDCFCE7);
  static const liveGreenText = Color(0xFF16A34A);
  static const liveGreenBorder = Color(0xFF86EFAC);

  static const cachedBlueBg = Color(0xFFEFF6FF);
  static const cachedBlueText = Color(0xFF1D4ED8);
  static const cachedBlueBorder = Color(0xFFBFDBFE);

  static const revalidatingBg = Color(0xFFEFF6FF);
  static const revalidatingText = Color(0xFF2563EB);

  static const staleBg = Color(0xFFFFFBEB);
  static const staleText = Color(0xFFB45309);
  static const staleBorder = Color(0xFFFDE68A);

  static const errorRedBg = Color(0xFFFEF2F2);
  static const errorRedText = Color(0xFFDC2626);
  static const errorRedBorder = Color(0xFFFECACA);

  static const errorAmberBg = Color(0xFFFFFBEB);
  static const errorAmberText = Color(0xFFD97706);

  static const errorPurpleBg = Color(0xFFF5F3FF);
  static const errorPurpleText = Color(0xFF7C3AED);

  // Price change
  static const priceUp = Color(0xFF16A34A);
  static const priceUpBg = Color(0xFFDCFCE7);
  static const priceDown = Color(0xFFDC2626);
  static const priceDownBg = Color(0xFFFEF2F2);
}

class CryptoScreen extends ConsumerStatefulWidget {
  const CryptoScreen({super.key});

  @override
  ConsumerState<CryptoScreen> createState() => _CryptoScreenState();
}

class _CryptoScreenState extends ConsumerState<CryptoScreen>
    with TickerProviderStateMixin {
  bool _isOfflineSimulated = false;
  bool _isInitialized = false;
  Timer? _tickTimer;

  // Tracks previous prices to detect changes after revalidation
  final Map<String, double> _previousPrices = {};

  // Tracks which coins just had a price change — for flash animation
  final Map<String, bool> _priceWentUp = {};
  final Map<String, AnimationController> _flashControllers = {};
  final Map<String, Animation<double>> _flashAnimations = {};

  // Tracks "UPDATED" badge visibility per coin
  final Map<String, bool> _showUpdatedBadge = {};
  final Map<String, Timer> _badgeTimers = {};

  @override
  void initState() {
    super.initState();
    _initialize();
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    for (final controller in _flashControllers.values) {
      controller.dispose();
    }
    for (final timer in _badgeTimers.values) {
      timer.cancel();
    }
    super.dispose();
  }

  Future<void> _initialize() async {
  final coordinator = ref.read(cacheCoordinatorProvider);
  await coordinator.initialize();
  coordinator.attachFlutterLifecycle();
  if (mounted) setState(() => _isInitialized = true);
}

  /// Called when new coin data arrives after revalidation.
  /// Detects price changes and triggers flash animations.
  void _detectAndAnimatePriceChanges(List<CryptoCoin> coins) {
    for (final coin in coins) {
      final double? previousPrice = _previousPrices[coin.id];
      if (previousPrice != null && previousPrice != coin.currentPrice) {
        final bool wentUp = coin.currentPrice > previousPrice;
        _priceWentUp[coin.id] = wentUp;
        _triggerFlashAnimation(coin.id, wentUp);
        _showUpdatedBadgeForCoin(coin.id);
      }
      _previousPrices[coin.id] = coin.currentPrice;
    }
  }

  void _triggerFlashAnimation(String coinId, bool wentUp) {
    if (!_flashControllers.containsKey(coinId)) {
      final controller = AnimationController(
        duration: const Duration(milliseconds: 800),
        vsync: this,
      );
      _flashControllers[coinId] = controller;
      _flashAnimations[coinId] = Tween<double>(begin: 0.0, end: 1.0).animate(
        CurvedAnimation(parent: controller, curve: Curves.easeOut),
      );
    }
    _flashControllers[coinId]!.forward(from: 0.0);
  }

  void _showUpdatedBadgeForCoin(String coinId) {
    _badgeTimers[coinId]?.cancel();
    setState(() => _showUpdatedBadge[coinId] = true);
    _badgeTimers[coinId] = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _showUpdatedBadge[coinId] = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) {
      return const Scaffold(
        backgroundColor: _C.bg,
        body: Center(
          child: CircularProgressIndicator(color: _C.cachedBlueText),
        ),
      );
    }

    final coinsAsync = ref.watch(topCoinsProvider);

    return Scaffold(
      backgroundColor: _C.bg,
      appBar: _buildAppBar(),
      body: coinsAsync.when(
        data: (cacheState) => _buildBody(cacheState),
        loading: () => const Center(
          child: CircularProgressIndicator(color: _C.cachedBlueText),
        ),
        error: (e, _) => _buildErrorBody(e.toString()),
      ),
      bottomNavigationBar: _buildBottomBar(),
    );
  }

  AppBar _buildAppBar() {
    return AppBar(
      backgroundColor: _C.surface,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(1),
        child: Container(height: 1, color: _C.border),
      ),
      title: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'flutter_offline_cache',
            style: TextStyle(
              color: _C.cachedBlueText,
              fontSize: 14,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
            ),
          ),
          Text(
            'Top 10 Coins — CoinGecko · TTL 30s',
            style: TextStyle(
              color: _C.textMuted,
              fontSize: 11,
            ),
          ),
        ],
      ),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: Row(
            children: [
              Text(
                _isOfflineSimulated ? 'Offline' : 'Online',
                style: TextStyle(
                  color: _isOfflineSimulated
                      ? _C.errorRedText
                      : _C.liveGreenText,
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
                activeColor: _C.errorRedText,
                inactiveThumbColor: _C.liveGreenText,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
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
          child: CircularProgressIndicator(color: _C.cachedBlueText),
        ),
      CacheLoading() => _buildLoadingBody(),
      CacheSuccess(:final cachedData, :final dataSource, :final entryMetadata) =>
        _buildDataBody(
          coins: cachedData,
          metadata: entryMetadata,
          stateLabel: dataSource == CacheSource.network ? 'LIVE' : 'CACHED',
          labelBg: dataSource == CacheSource.network
              ? _C.liveGreenBg
              : _C.cachedBlueBg,
          labelText: dataSource == CacheSource.network
              ? _C.liveGreenText
              : _C.cachedBlueText,
          labelBorder: dataSource == CacheSource.network
              ? _C.liveGreenBorder
              : _C.cachedBlueBorder,
          bannerBg: dataSource == CacheSource.network
              ? _C.liveGreenBg
              : _C.cachedBlueBg,
          bannerText: dataSource == CacheSource.network
              ? 'Fresh data fetched at ${_formatTime(entryMetadata.cachedAtMillis)}'
              : 'Served instantly from Hive — no network call',
          bannerTextColor: dataSource == CacheSource.network
              ? _C.liveGreenText
              : _C.cachedBlueText,
          showSpinner: false,
          onNewData: () => _detectAndAnimatePriceChanges(cachedData),
        ),
      CacheRevalidating(:final cachedData, :final entryMetadata) =>
        _buildDataBody(
          coins: cachedData,
          metadata: entryMetadata,
          stateLabel: 'REVALIDATING',
          labelBg: _C.revalidatingBg,
          labelText: _C.revalidatingText,
          labelBorder: _C.cachedBlueBorder,
          bannerBg: _C.revalidatingBg,
          bannerText:
              'Fetching latest prices in background — data still usable',
          bannerTextColor: _C.revalidatingText,
          showSpinner: true,
          onNewData: null,
        ),
      CacheStale(:final cachedData, :final refreshError) => _buildDataBody(
          coins: cachedData,
          metadata: null,
          stateLabel: 'STALE',
          labelBg: _C.staleBg,
          labelText: _C.staleText,
          labelBorder: _C.staleBorder,
          bannerBg: _C.staleBg,
          bannerText:
              'Refresh failed — ${_errorMessage(refreshError)} — showing last known data',
          bannerTextColor: _C.staleText,
          showSpinner: false,
          onNewData: null,
        ),
      CacheError(:final errorClassification) =>
        _buildErrorState(errorClassification),
    };
  }

  Widget _buildLoadingBody() {
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: const BoxDecoration(
            color: _C.surface,
            border: Border(bottom: BorderSide(color: _C.border)),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: _C.surfaceHover,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: _C.border),
                ),
                child: const Text(
                  'LOADING',
                  style: TextStyle(
                    color: _C.textSecondary,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              const Text(
                'First fetch — no cached data available',
                style: TextStyle(color: _C.textSecondary, fontSize: 11),
              ),
              const Spacer(),
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: _C.cachedBlueText,
                ),
              ),
            ],
          ),
        ),
        const Expanded(
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CircularProgressIndicator(color: _C.cachedBlueText),
                SizedBox(height: 16),
                Text(
                  'Fetching live prices...',
                  style: TextStyle(
                    color: _C.textSecondary,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDataBody({
    required List<CryptoCoin> coins,
    required CacheMetadata? metadata,
    required String stateLabel,
    required Color labelBg,
    required Color labelText,
    required Color labelBorder,
    required Color bannerBg,
    required String bannerText,
    required Color bannerTextColor,
    required bool showSpinner,
    required VoidCallback? onNewData,
  }) {
    // Detect price changes when new live data arrives
    if (onNewData != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => onNewData());
    }

    return Column(
      children: [
        // State banner
        AnimatedContainer(
          duration: const Duration(milliseconds: 400),
          color: bannerBg,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                child: Row(
                  children: [
                    // State label badge
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: labelBg,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: labelBorder),
                      ),
                      child: Text(
                        stateLabel,
                        style: TextStyle(
                          color: labelText,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        bannerText,
                        style: TextStyle(
                          color: bannerTextColor,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    if (showSpinner)
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: _C.revalidatingText,
                        ),
                      ),
                  ],
                ),
              ),

              // TTL progress bar + metadata
              if (metadata != null) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: _buildTtlProgressBar(metadata),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
                  child: Row(
                    children: [
                      _buildMetaChip(
                        label: 'Age',
                        value:
                            '${metadata.ageOfCachedData.inSeconds}s',
                        textColor: _C.textSecondary,
                        borderColor: _C.border,
                      ),
                      const SizedBox(width: 6),
                      _buildMetaChip(
                        label: 'Refreshes in',
                        value: metadata.remainingValidDuration ==
                                Duration.zero
                            ? 'now'
                            : '${metadata.remainingValidDuration.inSeconds}s',
                        textColor:
                            metadata.remainingValidDuration.inSeconds <= 5
                                ? _C.staleText
                                : _C.textSecondary,
                        borderColor:
                            metadata.remainingValidDuration.inSeconds <= 5
                                ? _C.staleBorder
                                : _C.border,
                      ),
                      const SizedBox(width: 6),
                      _buildMetaChip(
                        label: 'Source',
                        value: metadata.source == CacheSource.network
                            ? 'network'
                            : 'cache',
                        textColor: metadata.source == CacheSource.network
                            ? _C.liveGreenText
                            : _C.cachedBlueText,
                        borderColor:
                            metadata.source == CacheSource.network
                                ? _C.liveGreenBorder
                                : _C.cachedBlueBorder,
                      ),
                    ],
                  ),
                ),
              ] else
                const SizedBox(height: 10),

              // Bottom border
              Container(height: 1, color: _C.border),
            ],
          ),
        ),

        // Coin list
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            itemCount: coins.length,
            itemBuilder: (context, index) =>
                _buildCoinCard(coins[index]),
          ),
        ),
      ],
    );
  }

  Widget _buildTtlProgressBar(CacheMetadata metadata) {
    final int ttlMs = metadata.ttlMillis;
    final int ageMs = metadata.ageOfCachedData.inMilliseconds;
    final double progress = (ageMs / ttlMs).clamp(0.0, 1.0);
    final bool isExpiringSoon =
        metadata.remainingValidDuration.inSeconds <= 5;

    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: LinearProgressIndicator(
        value: progress,
        backgroundColor: _C.border,
        valueColor: AlwaysStoppedAnimation<Color>(
          isExpiringSoon ? _C.staleText : _C.cachedBlueText,
        ),
        minHeight: 3,
      ),
    );
  }

  Widget _buildMetaChip({
    required String label,
    required String value,
    required Color textColor,
    required Color borderColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: _C.surface,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: borderColor),
      ),
      child: RichText(
        text: TextSpan(
          children: [
            TextSpan(
              text: '$label: ',
              style: const TextStyle(
                color: _C.textMuted,
                fontSize: 10,
              ),
            ),
            TextSpan(
              text: value,
              style: TextStyle(
                color: textColor,
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCoinCard(CryptoCoin coin) {
    final bool isUp = coin.isPriceUp;
    final Color changeColor = isUp ? _C.priceUp : _C.priceDown;
    final Color changeBg = isUp ? _C.priceUpBg : _C.priceDownBg;

    // Flash animation — triggers when price changes after revalidation
    final AnimationController? flashController =
        _flashControllers[coin.id];
    final Animation<double>? flashAnimation =
        _flashAnimations[coin.id];
    final bool priceWentUp = _priceWentUp[coin.id] ?? true;
    final bool showBadge = _showUpdatedBadge[coin.id] ?? false;

    Widget card = Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: _C.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _C.border),
        boxShadow: const [
          BoxShadow(
            color: Color(0x08000000),
            blurRadius: 4,
            offset: Offset(0, 1),
          ),
        ],
      ),
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 12,
            ),
            child: Row(
              children: [
                // Rank
                SizedBox(
                  width: 28,
                  child: Text(
                    '#${coin.marketCapRank}',
                    style: const TextStyle(
                      color: _C.textMuted,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Symbol badge
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: _C.cachedBlueBg,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: _C.cachedBlueBorder),
                  ),
                  child: Center(
                    child: Text(
                      coin.symbol.length > 3
                          ? coin.symbol.substring(0, 3)
                          : coin.symbol,
                      style: const TextStyle(
                        color: _C.cachedBlueText,
                        fontSize: 9,
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
                          color: _C.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      // Animated price text
                      flashController != null &&
                              flashAnimation != null
                          ? AnimatedBuilder(
                              animation: flashAnimation,
                              builder: (context, child) {
                                final Color flashColor = priceWentUp
                                    ? _C.priceUp
                                    : _C.priceDown;
                                final Color normalColor =
                                    _C.textSecondary;
                                final Color interpolated =
                                    Color.lerp(
                                  flashColor,
                                  normalColor,
                                  flashAnimation.value,
                                )!;
                                return Text(
                                  _formatPrice(coin.currentPrice),
                                  style: TextStyle(
                                    color: interpolated,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                );
                              },
                            )
                          : Text(
                              _formatPrice(coin.currentPrice),
                              style: const TextStyle(
                                color: _C.textSecondary,
                                fontSize: 12,
                              ),
                            ),
                    ],
                  ),
                ),
                // 24h change + high/low
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: changeBg,
                        borderRadius: BorderRadius.circular(5),
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
                        color: _C.textMuted,
                        fontSize: 10,
                      ),
                    ),
                    Text(
                      'L: ${_formatPrice(coin.low24h)}',
                      style: const TextStyle(
                        color: _C.textMuted,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // UPDATED badge — appears briefly when price changes
          if (showBadge)
            Positioned(
              top: 6,
              right: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: priceWentUp ? _C.liveGreenBg : _C.errorRedBg,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: priceWentUp
                        ? _C.liveGreenBorder
                        : _C.errorRedBorder,
                  ),
                ),
                child: Text(
                  priceWentUp ? 'UP' : 'DOWN',
                  style: TextStyle(
                    color: priceWentUp ? _C.liveGreenText : _C.errorRedText,
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    // Flash border animation — card border flashes on price change
    if (flashController != null && flashAnimation != null) {
      card = AnimatedBuilder(
        animation: flashAnimation,
        builder: (context, child) {
          final Color flashColor =
              priceWentUp ? _C.priceUp : _C.priceDown;
          final Color borderColor = Color.lerp(
            flashColor,
            _C.border,
            flashAnimation.value,
          )!;
          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              color: _C.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: borderColor, width: 1.5),
              boxShadow: [
                BoxShadow(
                  color: flashColor
                      .withValues(alpha: (1 - flashAnimation.value) * 0.15),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 28,
                        child: Text(
                          '#${coin.marketCapRank}',
                          style: const TextStyle(
                            color: _C.textMuted,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: _C.cachedBlueBg,
                          borderRadius: BorderRadius.circular(8),
                          border:
                              Border.all(color: _C.cachedBlueBorder),
                        ),
                        child: Center(
                          child: Text(
                            coin.symbol.length > 3
                                ? coin.symbol.substring(0, 3)
                                : coin.symbol,
                            style: const TextStyle(
                              color: _C.cachedBlueText,
                              fontSize: 9,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              coin.name,
                              style: const TextStyle(
                                color: _C.textPrimary,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            AnimatedBuilder(
                              animation: flashAnimation,
                              builder: (context, child) {
                                final Color flashC = priceWentUp
                                    ? _C.priceUp
                                    : _C.priceDown;
                                final Color interpolated = Color.lerp(
                                  flashC,
                                  _C.textSecondary,
                                  flashAnimation.value,
                                )!;
                                return Text(
                                  _formatPrice(coin.currentPrice),
                                  style: TextStyle(
                                    color: interpolated,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: (isUp ? _C.priceUp : _C.priceDown)
                                  .withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(5),
                              border: Border.all(
                                color: (isUp ? _C.priceUp : _C.priceDown)
                                    .withValues(alpha: 0.3),
                              ),
                            ),
                            child: Text(
                              '${isUp ? '+' : ''}${coin.priceChangePercentage24h.toStringAsFixed(2)}%',
                              style: TextStyle(
                                color: isUp ? _C.priceUp : _C.priceDown,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'H: ${_formatPrice(coin.high24h)}',
                            style: const TextStyle(
                              color: _C.textMuted,
                              fontSize: 10,
                            ),
                          ),
                          Text(
                            'L: ${_formatPrice(coin.low24h)}',
                            style: const TextStyle(
                              color: _C.textMuted,
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (showBadge)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: priceWentUp
                            ? _C.liveGreenBg
                            : _C.errorRedBg,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: priceWentUp
                              ? _C.liveGreenBorder
                              : _C.errorRedBorder,
                        ),
                      ),
                      child: Text(
                        priceWentUp ? 'UP' : 'DOWN',
                        style: TextStyle(
                          color: priceWentUp
                              ? _C.liveGreenText
                              : _C.errorRedText,
                          fontSize: 9,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      );
    }

    return card;
  }

  Widget _buildErrorState(ErrorClassification classification) {
    final String label;
    final String title;
    final String subtitle;
    final Color bg;
    final Color textColor;
    final Color borderColor;

    switch (classification) {
      case ErrorClassification.offlineFailure:
        label = 'OFFLINE';
        title = 'No internet connection';
        subtitle = 'Turn off offline mode or check your connection';
        bg = _C.errorRedBg;
        textColor = _C.errorRedText;
        borderColor = _C.errorRedBorder;
      case ErrorClassification.timeoutFailure:
        label = 'TIMEOUT';
        title = 'Request timed out';
        subtitle = 'Server is slow or unreachable. Try again.';
        bg = _C.errorAmberBg;
        textColor = _C.errorAmberText;
        borderColor = _C.staleBorder;
      case ErrorClassification.rateLimitFailure:
        label = 'RATE LIMITED';
        title = 'Rate limited by CoinGecko';
        subtitle = 'Too many requests. Wait a moment then try again.';
        bg = _C.errorPurpleBg;
        textColor = _C.errorPurpleText;
        borderColor = const Color(0xFFDDD6FE);
      case ErrorClassification.serverFailure:
        label = 'SERVER ERROR';
        title = 'Something went wrong';
        subtitle = 'CoinGecko API returned an error. Try again.';
        bg = _C.errorRedBg;
        textColor = _C.errorRedText;
        borderColor = _C.errorRedBorder;
    }

    return Container(
      color: bg,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: _C.surface,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: borderColor),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    color: textColor,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                title,
                style: const TextStyle(
                  color: _C.textPrimary,
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
                  color: _C.textSecondary,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 24),
              OutlinedButton(
                onPressed: () async {
                  await ref
                      .read(cryptoRepositoryProvider)
                      .hardResetCoins();
                },
                style: OutlinedButton.styleFrom(
                  foregroundColor: textColor,
                  side: BorderSide(color: borderColor),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: const Text(
                  'Retry',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
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
          style: const TextStyle(color: _C.errorRedText),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      decoration: const BoxDecoration(
        color: _C.surface,
        border: Border(top: BorderSide(color: _C.border)),
      ),
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton(
          onPressed: () async {
            await ref.read(cryptoRepositoryProvider).hardResetCoins();
          },
          style: OutlinedButton.styleFrom(
            foregroundColor: _C.errorRedText,
            side: const BorderSide(color: _C.border),
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
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

  String _errorMessage(Object error) {
    if (error is DioException) {
      return error.message ?? 'Network error';
    }
    return error.toString().replaceAll('Exception: ', '');
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