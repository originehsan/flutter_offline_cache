import 'cache_metadata.dart';

/// Represents all possible states of a cache operation.
/// Use Dart 3 pattern matching to handle all states exhaustively.
///
/// ```dart
/// switch (state) {
///   case CacheInitial():  // show nothing
///   case CacheLoading():  // show full screen loader
///   case CacheSuccess():  // show data
///   case CacheRevalidating(): // show data + refresh banner
///   case CacheStale():    // show data + error toast
///   case CacheError():    // show error screen
/// }
/// ```
sealed class CacheState<T> {
  const CacheState();
}

/// Initial state before any cache operation has started.
/// Emitted when coordinator is created but no fetch has been called yet.
final class CacheInitial<T> extends CacheState<T> {
  const CacheInitial();
}

/// First load state — no cached data exists, network request in flight.
/// Show a full screen loading indicator.
final class CacheLoading<T> extends CacheState<T> {
  const CacheLoading();
}

/// Data successfully loaded from network or cache.
/// [cachedData] — the actual data to display.
/// [dataSource] — whether data came from network or local cache.
/// [entryMetadata] — timing and source information about this entry.
final class CacheSuccess<T> extends CacheState<T> {
  /// The actual data to display in the UI.
  final T cachedData;

  /// Whether this data came from local Hive cache or network.
  final CacheSource dataSource;

  /// Metadata about this cache entry — timing, TTL, fetch count.
  final CacheMetadata entryMetadata;

  const CacheSuccess({
    required this.cachedData,
    required this.dataSource,
    required this.entryMetadata,
  });

  /// Returns true if data was served from local Hive storage.
  bool get isServedFromCache => dataSource == CacheSource.localCache;

  /// Returns true if data was freshly fetched from network.
  bool get isServedFromNetwork => dataSource == CacheSource.network;
}

/// Cached data is being shown while a background refresh is running.
/// Show data normally — optionally show a small refresh indicator.
/// [cachedData] — stale but usable data currently displayed.
/// [entryMetadata] — metadata of the stale entry being revalidated.
final class CacheRevalidating<T> extends CacheState<T> {
  /// Stale but usable cached data currently shown to the user.
  final T cachedData;

  /// Metadata of the stale cache entry currently being revalidated.
  final CacheMetadata entryMetadata;

  const CacheRevalidating({
    required this.cachedData,
    required this.entryMetadata,
  });
}

/// Background refresh failed but stale cached data is still available.
/// Show cached data with an error toast — do not replace with error screen.
/// [cachedData] — old data still shown to user.
/// [refreshError] — the error that occurred during background refresh.
final class CacheStale<T> extends CacheState<T> {
  /// Old cached data still shown to the user.
  final T cachedData;

  /// Error that occurred during the background refresh attempt.
  final Object refreshError;

  /// Stack trace of the refresh error for debugging.
  final StackTrace? refreshErrorStackTrace;

  const CacheStale({
    required this.cachedData,
    required this.refreshError,
    this.refreshErrorStackTrace,
  });
}

/// Hard failure — no cached data exists and network request failed.
/// Show a full screen error with retry option.
/// [networkError] — the error that caused the failure.
/// [isOfflineFailure] — true if failure was due to no internet connection.
final class CacheError<T> extends CacheState<T> {
  /// The error that caused this failure.
  final Object networkError;

  /// Stack trace of the network error for debugging.
  final StackTrace? networkErrorStackTrace;

  /// True if failure was caused by no internet connectivity.
  /// False if failure was caused by server error (4xx, 5xx).
  final bool isOfflineFailure;

  const CacheError({
    required this.networkError,
    required this.isOfflineFailure,
    this.networkErrorStackTrace,
  });
}