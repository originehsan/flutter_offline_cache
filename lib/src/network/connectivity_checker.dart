/// Abstract interface for checking device network connectivity.
/// Implement this to swap connectivity logic or mock in tests.
/// Default implementation is [DefaultConnectivityChecker].
abstract class ConnectivityChecker {
  /// Returns true if the device currently has an active network interface.
  /// Returns false if no network interface is available.
  ///
  /// ⚠️ NOTE: This checks network interface presence only, NOT actual
  /// internet reachability. A device on WiFi with no WAN will return true.
  Future<bool> isDeviceOnline();

  /// Stream that emits true when device comes online
  /// and false when device goes offline.
  Stream<bool> get connectivityStatusStream;

  /// Disposes any active stream subscriptions or resources.
  /// Call this when the coordinator is disposed.
  Future<void> disposeConnectivityResources();
}