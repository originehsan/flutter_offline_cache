import 'dart:convert';
import 'package:crypto/crypto.dart';

/// Builds and sanitizes cache keys.
/// Namespaces keys to avoid collisions between repositories.
class KeyBuilder {
  KeyBuilder._();

  /// Builds a namespaced cache key from [namespace] and [key].
  /// Example: ('MovieRepository', 'movies') → 'foc_a3f2b1...'
  static String build(String namespace, String key) {
    assert(namespace.isNotEmpty, 'namespace must not be empty');
    assert(key.isNotEmpty, 'key must not be empty');
    return _hash('${namespace}_$key');
  }

  /// Builds a key with query parameters included.
  /// Params are sorted before hashing so order does not matter.
  static String buildWithParams(
    String namespace,
    String key,
    Map<String, dynamic> params,
  ) {
    assert(namespace.isNotEmpty, 'namespace must not be empty');
    assert(key.isNotEmpty, 'key must not be empty');

    final sortedParams = Map.fromEntries(
      params.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );

    String encodedParams;
    try {
      encodedParams = jsonEncode(sortedParams);
    } catch (_) {
      encodedParams = sortedParams.entries
          .map((e) => '${e.key}=${e.value}')
          .join('&');
    }

    return _hash('${namespace}_${key}_$encodedParams');
  }

  /// Returns first 32 chars of SHA256 hash prefixed with 'foc_'.
  /// 'foc' = flutter_offline_cache — prevents Hive key collisions.
  static String _hash(String raw) {
    final bytes = utf8.encode(raw);
    final digest = sha256.convert(bytes).toString();
    return 'foc_${digest.substring(0, 32)}';
  }
}