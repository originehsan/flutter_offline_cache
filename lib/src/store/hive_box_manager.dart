import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:mutex/mutex.dart';
import '../models/cache_config.dart';
import '../security/encryption_config.dart';

/// Manages the lifecycle of the Hive box used by [HiveCacheStore].
/// Single responsibility: open and close the Hive box safely.
/// Handles race conditions via [Mutex] and encryption via [HiveAesCipher].
class HiveBoxManager {
  final CacheConfig _cacheConfig;
  final Mutex _boxOpenMutex = Mutex();

  Box<dynamic>? _openedBox;

  /// Static flag shared across all instances — prevents double Flutter init.
  /// Bug 17 fix — if developer already called Hive.initFlutter() in main.dart,
  /// we skip the call inside the package.
  static bool _isFlutterInitialized = false;

  HiveBoxManager({required CacheConfig cacheConfig})
      : _cacheConfig = cacheConfig;

  /// Whether the Hive box is currently open and ready for operations.
  bool get isBoxOpen => _openedBox != null && _openedBox!.isOpen;

  /// The currently opened Hive box.
  /// Throws [StateError] if accessed before [openCacheBox] is called.
  Box<dynamic> get openedCacheBox {
    if (_openedBox == null || !_openedBox!.isOpen) {
      throw StateError(
        'HiveBoxManager: openedCacheBox accessed before openCacheBox() '
        'was called. Call initializeStorage() on CacheCoordinator first.',
      );
    }
    return _openedBox!;
  }

  /// Opens the Hive box for cache storage.
  /// Safe to call multiple times — subsequent calls are no-ops.
  /// Uses [Mutex] to prevent race conditions on simultaneous calls.
  Future<void> openCacheBox() async {
    await _boxOpenMutex.protect(() async {
      if (isBoxOpen) return;

      // Bug 17 fix — only init Flutter if not already initialized.
      // Wraps in try/catch because Hive may already be initialized
      // by the developer's own main.dart without exposing an isInitialized flag.
      if (!_isFlutterInitialized) {
        try {
          await Hive.initFlutter();
        } catch (_) {
          // Hive already initialized — safe to continue
        }
        _isFlutterInitialized = true;
      }

      if (Hive.isBoxOpen(_cacheConfig.hiveBoxName)) {
        _openedBox = Hive.box<dynamic>(_cacheConfig.hiveBoxName);
        return;
      }

      // Bug 18 fix — catch encryption mismatch error and throw
      // meaningful StateError so developer understands what happened
      try {
        if (_cacheConfig.isEncryptionEnabled) {
          final cipher = EncryptionConfig.createValidatedHiveCipher(
            _cacheConfig.encryptionKey!,
          );
          _openedBox = await Hive.openBox<dynamic>(
            _cacheConfig.hiveBoxName,
            encryptionCipher: cipher,
          );
        } else {
          _openedBox = await Hive.openBox<dynamic>(
            _cacheConfig.hiveBoxName,
          );
        }
      } catch (error) {
        throw StateError(
          'flutter_offline_cache: Failed to open Hive box '
          '"${_cacheConfig.hiveBoxName}". '
          'If you previously opened this box without encryption and are now '
          'enabling encryption (or vice versa), delete the existing box file '
          'and clear the app cache. '
          'Original error: $error',
        );
      }
    });
  }

  /// Closes the Hive box cleanly.
  /// No-op if box is already closed.
  /// Mutex protected to prevent race with [openCacheBox].
  Future<void> closeCacheBox() async {
    await _boxOpenMutex.protect(() async {
      if (!isBoxOpen) return;
      await _openedBox!.close();
      _openedBox = null;
    });
  }
}