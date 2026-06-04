import 'dart:convert';

/// Guards against oversized payloads being written to Hive.
/// Hive loads the entire box into memory — large entries cause OOM
/// on low-end devices.
class SizeGuard {
  SizeGuard._();

  /// Default max entry size: 512KB.
  static const int defaultMaxBytes = 524288;

  /// Returns true if [value] is within [maxBytes].
  /// Measures actual UTF8 byte length, not character count.
  static bool isAllowed(String value, {int maxBytes = defaultMaxBytes}) {
    final byteLength = utf8.encode(value).length;
    return byteLength <= maxBytes;
  }

  /// Returns the byte size of [value].
  static int byteSize(String value) => utf8.encode(value).length;

  /// Returns true if [value] exceeds [maxBytes].
  static bool isExceeded(String value, {int maxBytes = defaultMaxBytes}) {
    return !isAllowed(value, maxBytes: maxBytes);
  }
}