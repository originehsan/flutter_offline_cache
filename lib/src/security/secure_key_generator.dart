import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Manages the lifecycle of the AES-256 encryption key used to secure Hive boxes.
///
/// ## Key Storage
/// The key is stored in the device's secure hardware enclave via
/// [FlutterSecureStorage] (Keystore on Android, Keychain on iOS).
///
/// ## Silent Regeneration Warning
/// If the stored key is missing or corrupted, this class will silently
/// regenerate a new 32-byte key. This makes all previously encrypted Hive
/// cache entries permanently unreadable. The cache will behave as empty
/// and refetch from the network on next access.
/// This is acceptable for cache data but must be documented so developers
/// do not misdiagnose it as a persistence bug.
///
/// ## Multiple Coordinators
/// If you use multiple [CacheCoordinator] instances with different encryption
/// keys, pass a unique [storageKeyName] to each [SecureKeyGenerator].
/// Using the same key name across coordinators will share the same AES key.
///
/// ## Testability
/// Pass a mock [FlutterSecureStorage] via constructor injection in tests.
///
/// Usage:
/// ```dart
/// final keyManager = SecureKeyGenerator();
/// final List<int> key = await keyManager.getOrCreateEncryptionKey();
/// final config = CacheConfig(encryptionKey: key);
/// ```
class SecureKeyGenerator {
  /// Creates a [SecureKeyGenerator] with optional [FlutterSecureStorage]
  /// and optional [storageKeyName].
  ///
  /// [storageKeyName] — the key name used when storing AES key in secure
  /// storage. Override this if you use multiple coordinators with different
  /// encryption keys. Never change this between app versions for the same
  /// coordinator — changing it makes all existing encrypted cache permanently
  /// unreadable.
  ///
  /// Defaults to [defaultStorageKeyName] if not provided.
  const SecureKeyGenerator({
    FlutterSecureStorage? storage,
    String? storageKeyName,
  })  : _storage = storage ?? const FlutterSecureStorage(),
        _storageKeyName = storageKeyName ?? defaultStorageKeyName;

  final FlutterSecureStorage _storage;
  final String _storageKeyName;

  /// Required key length in bytes for AES-256 encryption.
  static const int _requiredKeyLengthBytes = 32;

  /// Default storage key name for persisting the AES encryption key.
  /// Override via [storageKeyName] constructor parameter when using
  /// multiple coordinators with separate encryption keys.
  static const String defaultStorageKeyName =
      'flutter_offline_cache_aes_key';

  /// Retrieves the existing AES-256 key from secure storage.
  /// Generates and persists a new key if none exists or stored key is corrupt.
  ///
  /// Throws [StateError] if the key cannot be written to secure storage.
  Future<Uint8List> getOrCreateEncryptionKey() async {
    String? existingKeyBase64;
    try {
      existingKeyBase64 = await _storage.read(key: _storageKeyName);
    } catch (_) {
      // OS Keystore/Keychain read failed — fall through to regeneration
      existingKeyBase64 = null;
    }

    if (existingKeyBase64 != null) {
      try {
        final Uint8List decodedKey = base64Decode(existingKeyBase64);
        if (decodedKey.length == _requiredKeyLengthBytes) {
          return decodedKey;
        }
        // Wrong length — fall through to regeneration
      } catch (_) {
        // Base64 decode failed — fall through to regeneration
      }
    }

    // Generate fresh 32-byte key using OS-level entropy
    final Uint8List freshKey = _generateSecureRandomBytes(
      _requiredKeyLengthBytes,
    );

    try {
      await _storage.write(
        key: _storageKeyName,
        value: base64Encode(freshKey),
      );
    } catch (writeError) {
      throw StateError(
        'flutter_offline_cache: Failed to persist AES encryption key '
        'to secure storage. Ensure flutter_secure_storage is correctly '
        'configured for your platform. '
        'Storage key name: $_storageKeyName. '
        'Caused by: $writeError',
      );
    }

    return freshKey;
  }

  /// Generates [byteCount] cryptographically secure random bytes
  /// using OS-level entropy via [Random.secure].
  Uint8List _generateSecureRandomBytes(int byteCount) {
    final Random secureRandom = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(
        byteCount,
        (_) => secureRandom.nextInt(256),
      ),
    );
  }
}