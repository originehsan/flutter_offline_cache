/// Represents a cryptocurrency from CoinGecko API.
class CryptoCoin {
  final String id;
  final String symbol;
  final String name;
  final double currentPrice;
  final double priceChangePercentage24h;
  final double marketCap;
  final double totalVolume;
  final double high24h;
  final double low24h;
  final int marketCapRank;
  final String lastUpdated;

  const CryptoCoin({
    required this.id,
    required this.symbol,
    required this.name,
    required this.currentPrice,
    required this.priceChangePercentage24h,
    required this.marketCap,
    required this.totalVolume,
    required this.high24h,
    required this.low24h,
    required this.marketCapRank,
    required this.lastUpdated,
  });

  factory CryptoCoin.fromJson(Map<String, dynamic> json) {
    return CryptoCoin(
      id: json['id'] as String? ?? '',
      symbol: (json['symbol'] as String? ?? '').toUpperCase(),
      name: json['name'] as String? ?? '',
      currentPrice: (json['current_price'] as num?)?.toDouble() ?? 0.0,
      priceChangePercentage24h:
          (json['price_change_percentage_24h'] as num?)?.toDouble() ?? 0.0,
      marketCap: (json['market_cap'] as num?)?.toDouble() ?? 0.0,
      totalVolume: (json['total_volume'] as num?)?.toDouble() ?? 0.0,
      high24h: (json['high_24h'] as num?)?.toDouble() ?? 0.0,
      low24h: (json['low_24h'] as num?)?.toDouble() ?? 0.0,
      marketCapRank: json['market_cap_rank'] as int? ?? 0,
      lastUpdated: json['last_updated'] as String? ?? '',
    );
  }

  bool get isPriceUp => priceChangePercentage24h >= 0;
}