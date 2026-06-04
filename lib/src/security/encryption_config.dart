import 'package:hive_ce/hive.dart';

/// Handles creation and validation of [HiveAesCipher] for encrypted Hive boxes.
/// Validates key length and strength before creating the cipher.
/// Used by [HiveBoxManager] when opening an encrypted cache box.
class EncryptionConfig {
  EncryptionConfig._();

  /// Required key length in bytes for AES-256 encryption.
  static const int _requiredKeyLengthBytes = 32;

  /// Creates a validated [HiveAesCipher] from [encryptionKey].
  ///
  /// Throws [ArgumentError] if:
  /// - key length is not exactly 32 bytes
  /// - key consists entirely of zero bytes (weak key)
  static HiveAesCipher createValidatedHiveCipher(List<int> encryptionKey) {
    validateEncryptionKey(encryptionKey);
    return HiveAesCipher(encryptionKey);
  }

  /// Validates [encryptionKey] for use with [HiveAesCipher].
  ///
  /// Throws [ArgumentError] if key is invalid.
  static void validateEncryptionKey(List<int> encryptionKey) {
    if (encryptionKey.length != _requiredKeyLengthBytes) {
      throw ArgumentError(
        'flutter_offline_cache: Encryption key must be exactly '
        '$_requiredKeyLengthBytes bytes for AES-256. '
        'Got ${encryptionKey.length} bytes. '
        'Use SecureKeyGenerator.getOrCreateEncryptionKey() to generate a valid key.',
      );
    }

    final bool isAllZeros = encryptionKey.every((byte) => byte == 0);
    if (isAllZeros) {
      throw ArgumentError(
        'flutter_offline_cache: Encryption key consists entirely of zero bytes. '
        'This is an extremely weak key. '
        'Use SecureKeyGenerator.getOrCreateEncryptionKey() to generate a secure key.',
      );
    }
  }
}