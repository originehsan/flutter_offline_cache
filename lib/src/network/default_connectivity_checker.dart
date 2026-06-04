import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:rxdart/rxdart.dart';
import 'connectivity_checker.dart';

/// Default implementation of [ConnectivityChecker] using connectivity_plus.
///
/// ⚠️ IMPORTANT: This checks if a network interface exists (WiFi, mobile data),
/// NOT if the internet is actually reachable. A device on WiFi with no internet
/// (captive portal, router with no WAN) will still return true.
///
/// ## Async Init Gap
/// The real connectivity state is determined asynchronously after construction.
/// Until the first check completes, [isDeviceOnline] returns the seeded value
/// of `true`. If you construct this and immediately call [isDeviceOnline] in
/// a test, you will get `true` regardless of actual state. The real state
/// arrives within one event loop cycle.
///
/// ## Single Source of Truth
/// Use [isDeviceOnline] for point-in-time checks before network calls.
/// The [connectivityStatusStream] is available for future auto-retry features.
/// Do not mix both in the same decision — they can briefly disagree.
///
/// ## Testability
/// Inject [Connectivity] via constructor to mock in tests.
class DefaultConnectivityChecker implements ConnectivityChecker {
  final Connectivity _connectivity;

  /// Seeded with true — assume online until real check completes.
  /// Consistent with empty-list fallback which also returns true.
  final BehaviorSubject<bool> _connectivityStatusSubject =
      BehaviorSubject<bool>.seeded(true);

  StreamSubscription<List<ConnectivityResult>>?
      _connectivityStreamSubscription;

  /// Disposed flag — prevents late listener attachment after dispose.
  bool _isDisposed = false;

  DefaultConnectivityChecker({
    Connectivity? connectivity,
  }) : _connectivity = connectivity ?? Connectivity() {
    _initializeWithRealConnectivityState();
  }

  /// Checks real connectivity at construction and starts change listener.
  /// Exits early if disposed before async check completes.
  Future<void> _initializeWithRealConnectivityState() async {
    try {
      final List<ConnectivityResult> initialResults =
          await _connectivity.checkConnectivity();

      // Exit if disposed before check completed
      if (_isDisposed) return;

      if (!_connectivityStatusSubject.isClosed) {
        _connectivityStatusSubject.add(_isOnlineFromResults(initialResults));
      }
    } catch (_) {
      // Check failed — keep seeded true value
    }

    // Exit if disposed before listener attachment
    if (_isDisposed) return;

    _connectivityStreamSubscription =
        _connectivity.onConnectivityChanged.listen(
      (List<ConnectivityResult> results) {
        if (!_connectivityStatusSubject.isClosed) {
          _connectivityStatusSubject.add(_isOnlineFromResults(results));
        }
      },
    );
  }

  @override
  Future<bool> isDeviceOnline() async {
    try {
      final List<ConnectivityResult> results =
          await _connectivity.checkConnectivity();
      return _isOnlineFromResults(results);
    } catch (_) {
      // Check failed — assume online, let network call fail naturally
      return true;
    }
  }

  @override
  Stream<bool> get connectivityStatusStream =>
      _connectivityStatusSubject.stream;

  @override
  Future<void> disposeConnectivityResources() async {
    _isDisposed = true;
    await _connectivityStreamSubscription?.cancel();
    _connectivityStreamSubscription = null;
    if (!_connectivityStatusSubject.isClosed) {
      await _connectivityStatusSubject.close();
    }
  }

  /// Returns true if any result indicates an active network interface.
  /// Returns true on empty list — consistent with seeded true philosophy.
  /// Assumes online when state is indeterminate; let network call fail naturally.
  bool _isOnlineFromResults(List<ConnectivityResult> results) {
    if (results.isEmpty) return true;
    return results.any(
      (result) => result != ConnectivityResult.none,
    );
  }
}