# flutter_offline_cache

[![pub package](https://img.shields.io/pub/v/flutter_offline_cache.svg)](https://pub.dev/packages/flutter_offline_cache)
[![Dart SDK: >=3.0.0](https://img.shields.io/badge/Dart%20SDK-%3E%3D3.0.0-blue.svg)](https://dart.dev)
[![Flutter SDK: >=3.10.0](https://img.shields.io/badge/Flutter%20SDK-%3E%3D3.10.0-blue.svg)](https://flutter.dev)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**Offline-first stale-while-revalidate (SWR) caching for Flutter** with automatic TTL management, request deduplication, background revalidation, and optional AES-256 encryption.

## What is Stale-While-Revalidate (SWR)?

SWR is a caching strategy where:
- **Cache fresh?** Serve instantly from local storage — zero network latency
- **Cache stale?** Serve instantly anyway, then quietly refresh in the background
- **No cache?** Load from network, show loading state, cache when done

This pattern keeps UIs responsive while keeping data fresh. Perfect for mobile where networks are unreliable.

## Why flutter_offline_cache?

| Need | Manual Approach | flutter_offline_cache |
|------|-----------------|------------------------|
| **Cache + TTL** | Hand-manage timers, detect staleness | Built-in — fires automatically |
| **Offline Fallback** | Check network state, maintain backup cache | Automatic fallback, no boilerplate |
| **Concurrent Requests** | Duplicate requests flood the server | Built-in deduplication per key |
| **Reactive UI** | StreamBuilder chaos, state machine bugs | 6 well-defined states, type-safe |
| **Background Refresh** | Manual background tasks, memory leaks | Coordinator manages lifecycle |
| **Encryption** | Integrate flutter_secure_storage manually | One-line optional encryption |

## Installation

Add to `pubspec.yaml`:

```yaml
dependencies:
  flutter_offline_cache: ^0.1.0
  dio: ^5.7.0

  # Optional — only if using Riverpod integration
  flutter_riverpod: ^2.5.1
```

The package includes Hive, RxDart, and other dependencies internally.

## Quick Start

### 1. Set Up Riverpod Provider

```dart
import 'package:flutter_offline_cache/flutter_offline_cache.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';

final dioProvider = Provider<Dio>((ref) => Dio());

final cacheCoordinatorProvider = Provider<CacheCoordinator>((ref) {
  final coordinator = CacheCoordinator(
    cacheConfig: const CacheConfig(
      defaultTtl: Duration(minutes: 5),
      enableDebugLogs: true,
    ),
  );
  ref.onDispose(coordinator.dispose);
  return coordinator;
});
```

Initialize the coordinator in your screen's `initState`:

```dart
class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool _isInitialized = false;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    final coordinator = ref.read(cacheCoordinatorProvider);
    await coordinator.initialize();
    coordinator.attachFlutterLifecycle();
    if (mounted) setState(() => _isInitialized = true);
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    // Now safe to watch providers that depend on coordinator
    return ref.watch(postsProvider).when(
      data: (cacheState) => _buildContent(cacheState),
      loading: () => const CircularProgressIndicator(),
      error: (e, st) => ErrorScreen(),
    );
  }

  Widget _buildContent(CacheState<List<Post>> state) {
    return switch (state) {
      CacheInitial() => const SizedBox.shrink(),
      CacheLoading() => const Center(child: CircularProgressIndicator()),
      CacheSuccess(:final cachedData) => PostList(posts: cachedData),
      CacheRevalidating(:final cachedData) => PostList(posts: cachedData),
      CacheStale(:final cachedData) => PostList(posts: cachedData),
      CacheError(:final isOfflineFailure) => ErrorScreen(isOffline: isOfflineFailure),
    };
  }
}
```

### 2. Create Data Provider

```dart
final postsProvider = StreamProvider<CacheState<List<Post>>>((ref) {
  final coordinator = ref.watch(cacheCoordinatorProvider);
  final dio = ref.watch(dioProvider);
  
  return coordinator.cachedFetch<List<Post>>(
    namespace: 'PostRepository',
    key: 'all_posts',
    networkFetcher: () => dio.get('/posts'),
    fromJsonConverter: (json) => (json as List)
        .map((e) => Post.fromJson(e as Map<String, dynamic>))
        .toList(),
    ttl: const Duration(minutes: 5),
  );
});
```

## Understanding Cache States

The `CacheState<T>` sealed class represents 6 distinct states. Handle all of them for a complete, robust UI.

### CacheInitial

No fetch has started yet. Cache is empty and no network request is in flight.

**When to show:** Nothing, or a placeholder.

```dart
case CacheInitial():
  return const SizedBox.shrink();
```

---

### CacheLoading

First fetch is in progress. No cache exists yet. User is waiting for initial data.

**When to show:** Full-screen loading spinner.

```dart
case CacheLoading():
  return const Center(child: CircularProgressIndicator());
```

---

### CacheSuccess

Data successfully loaded from either network or local cache, and it is **fresh** (TTL not expired).

```dart
final class CacheSuccess<T> extends CacheState<T> {
  final T cachedData;
  final CacheSource dataSource;  // network or localCache
  final CacheMetadata entryMetadata;
}
```

**When to show:** Full content, no loading indicator. User sees responsive, instant UI.

```dart
case CacheSuccess(:final cachedData):
  return PostList(posts: cachedData);
```

---

### CacheRevalidating

Stale cache is being shown **and** a fresh fetch is running silently in the background. Data will be updated automatically when fresh fetch completes.

```dart
final class CacheRevalidating<T> extends CacheState<T> {
  final T cachedData;
  final CacheMetadata entryMetadata;
}
```

**When to show:** Content normally, optionally add a subtle loading indicator to signal background work.

```dart
case CacheRevalidating(:final cachedData):
  return Stack(
    children: [
      PostList(posts: cachedData),
      Positioned(
        bottom: 16,
        right: 16,
        child: CircularProgressIndicator.adaptive(),
      ),
    ],
  );
```

---

### CacheStale

Fresh fetch failed, so stale cache is being served as fallback. This is an **error state**, but with graceful degradation.

```dart
final class CacheStale<T> extends CacheState<T> {
  final T cachedData;
  final Object refreshError;
  final StackTrace? refreshErrorStackTrace;
}
```

**When to show:** Content + error toast/snackbar. Do **NOT** replace content with an error screen — that breaks UX.

```dart
case CacheStale(:final cachedData):
  return Column(
    children: [
      PostList(posts: cachedData),
      const SnackBar(content: Text('Refresh failed, showing old data')),
    ],
  );
```

---

### CacheError

Hard failure: no cache exists and the network request failed. User sees nothing useful.

```dart
final class CacheError<T> extends CacheState<T> {
  final Object networkError;
  final ErrorClassification errorClassification;
  final StackTrace? networkErrorStackTrace;
  bool get isOfflineFailure;
  bool get isTimeoutFailure;
  bool get isRateLimited;
  bool get isServerError;
  bool get shouldShowCachedFallback;
}
```

**When to show:** Full error screen with specific message based on error type.

```dart
case CacheError(:final isOfflineFailure, :final errorClassification):
  return Center(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          isOfflineFailure ? Icons.wifi_off : Icons.error,
          size: 64,
        ),
        const SizedBox(height: 16),
        Text(
          switch (errorClassification) {
            ErrorClassification.offlineFailure => 'No internet connection',
            ErrorClassification.timeoutFailure => 'Request timed out',
            ErrorClassification.rateLimitFailure => 'Rate limited, please try again later',
            ErrorClassification.serverFailure => 'Server error, try again',
          },
        ),
        const SizedBox(height: 16),
        ElevatedButton(
          onPressed: () => coordinator.refresh(...),
          child: const Text('Retry'),
        ),
      ],
    ),
  );
```

---

## Error Classification

`ErrorClassification` helps you respond appropriately to different failure modes:

```dart
enum ErrorClassification {
  offlineFailure,    // Device has no internet (isOfflineFailure = true)
  timeoutFailure,    // Request took too long (isTimeoutFailure = true)
  rateLimitFailure,  // HTTP 429, rate limited (isRateLimited = true)
  serverFailure,     // 4xx or 5xx response (isServerError = true)
}
```

---

## CacheCoordinator API Reference

### initialize()

Must call before using any other method.

```dart
final coordinator = CacheCoordinator(
  cacheConfig: const CacheConfig(defaultTtl: Duration(minutes: 5)),
);
await coordinator.initialize();
```

### attachFlutterLifecycle()

Pause/resume TTL timers when app goes to background/foreground. Call this in `initState` or after `initialize()`.

```dart
coordinator.attachFlutterLifecycle();
```

When app resumes, remaining TTL is calculated accurately — no extra delay.

### cachedFetch<T>()

The main method. Returns a `Stream<CacheState<T>>` that emits 1+ states.

```dart
Stream<CacheState<T>> cachedFetch<T>({
  required String namespace,
  required String key,
  required Future<dynamic> Function() networkFetcher,
  required T Function(dynamic) fromJsonConverter,
  Duration? ttl,
  Duration? networkTimeout,
  bool forceRevalidate = false,
})
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `namespace` | `String` | Logical grouping, e.g. `'PostRepository'` |
| `key` | `String` | Unique cache key within namespace, e.g. `'all_posts'` |
| `networkFetcher` | `Future<Response> Function()` | Async function that calls your API (typically `dio.get()`, `dio.post()`, etc.) |
| `fromJsonConverter` | `T Function(dynamic)` | Parse API response into `T` |
| `ttl` | `Duration?` | Override `defaultTtl` for this fetch. Optional. |
| `networkTimeout` | `Duration?` | Max time to wait for network response. Optional. |
| `forceRevalidate` | `bool` | Skip cache, always fetch fresh. Defaults to `false`. |

**Returns:** A `Stream<CacheState<T>>` that emits multiple states over time.

```dart
coordinator.cachedFetch<List<Post>>(
  namespace: 'PostRepository',
  key: 'all_posts',
  networkFetcher: () => dio.get('/posts'),
  fromJsonConverter: (json) => (json as List)
      .map((e) => Post.fromJson(e))
      .toList(),
  ttl: const Duration(minutes: 5),
).listen((state) {
  print(state);  // CacheLoading, CacheSuccess, CacheRevalidating, etc.
});
```

### refresh()

Force a fresh fetch, bypassing TTL. Useful for pull-to-refresh.

```dart
await coordinator.refresh(
  namespace: 'PostRepository',
  key: 'all_posts',
);
```

### invalidate()

Delete a single cache entry and force a fresh fetch.

```dart
await coordinator.invalidate(
  namespace: 'PostRepository',
  key: 'all_posts',
);
```

### invalidateAll()

Delete all cache entries. Useful on user logout.

```dart
await coordinator.invalidateAll();
```

### dispose()

Clean up resources. Call in `dispose()` or when done with the app.

```dart
@override
void dispose() {
  coordinator.dispose();
  super.dispose();
}
```

---

## CacheConfig Reference

Configure cache behavior globally. All options are optional.

```dart
CacheConfig({
  Duration defaultTtl = Duration(minutes: 10),
  Duration minTtl = Duration(seconds: 1),
  CachePolicy defaultCachePolicy = CachePolicy.cacheFirst,
  int maxEntrySizeBytes = 524288,  // 512KB
  String hiveBoxName = '__foc_cache_v1__',
  List<int>? encryptionKey,  // AES-256, must be 32 bytes
  bool enableDebugLogs = false,
  bool pauseRevalidationWhenBackgrounded = true,
})
```

| Option | Default | Description |
|--------|---------|-------------|
| `defaultTtl` | 10 min | How long cache is fresh. Used if `cachedFetch()` doesn't specify `ttl`. |
| `minTtl` | 1 sec | Minimum allowed TTL. Prevents accidental 0 TTLs breaking the system. |
| `defaultCachePolicy` | `cacheFirst` | Reserved for future use. |
| `maxEntrySizeBytes` | 512 KB | Reject entries larger than this. Prevents huge objects from wasting storage. |
| `hiveBoxName` | `'__foc_cache_v1__'` | Name of Hive box. Change if you need multiple isolated caches. |
| `encryptionKey` | `null` | 32-byte AES-256 key. If provided, all cache entries are encrypted at rest. |
| `enableDebugLogs` | `false` | Verbose debug logs. Disable in production. |
| `pauseRevalidationWhenBackgrounded` | `true` | Pause TTL timers when app goes to background. Saves battery. |

---

## CacheMetadata

Available on `CacheSuccess` and `CacheRevalidating` states:

```dart
class CacheMetadata {
  final int cachedAtMillis;      // when data was cached
  final int ttlMillis;           // TTL in milliseconds
  final CacheSource source;      // network or localCache

  Duration get ageOfCachedData;        // how old the cached data is
  Duration get remainingValidDuration; // time until cache expires
}
```

Use this to show cache age or countdown timer in your UI:

```dart
case CacheSuccess(:final entryMetadata) => Column(
  children: [
    PostList(posts: cachedData),
    Text(
      'Cached ${entryMetadata.ageOfCachedData.inSeconds}s ago',
      style: Theme.of(context).textTheme.bodySmall,
    ),
  ],
);
```

---

## Special TTL Values

### Cache Forever — No Auto-Revalidation

```dart
import 'package:flutter_offline_cache/flutter_offline_cache.dart';

coordinator.cachedFetch(
  ttl: cacheForever,  // Const Duration that never expires
  ...
)
```

Useful for static data (app config, localization strings, etc.) that should never auto-refresh.

### Always Stale — Immediate Revalidation

```dart
coordinator.cachedFetch(
  ttl: Duration.zero,  // Expires immediately
  ...
)
```

Cache is served but revalidation starts immediately. Useful if you want SWR behavior but with more aggressive revalidation.

---

## Riverpod Integration

Use `Provider` for the coordinator and `StreamProvider` for data fetching.

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_offline_cache/flutter_offline_cache.dart';

// Coordinator provider (lazy initialization)
final cacheCoordinatorProvider = Provider<CacheCoordinator>((ref) {
  final coordinator = CacheCoordinator(
    cacheConfig: const CacheConfig(
      defaultTtl: Duration(minutes: 5),
    ),
  );
  ref.onDispose(coordinator.dispose);
  return coordinator;
});

// Data provider
final postsProvider = StreamProvider<CacheState<List<Post>>>((ref) {
  final coordinator = ref.watch(cacheCoordinatorProvider);
  final dio = ref.watch(dioProvider);
  
  return coordinator.cachedFetch<List<Post>>(
    namespace: 'PostRepository',
    key: 'all_posts',
    networkFetcher: () => dio.get('/posts'),
    fromJsonConverter: (json) => (json as List)
        .map((e) => Post.fromJson(e as Map<String, dynamic>))
        .toList(),
  );
});

// In your screen, initialize in initState:
class HomeScreen extends ConsumerStatefulWidget {
  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool _isInitialized = false;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    final coordinator = ref.read(cacheCoordinatorProvider);
    await coordinator.initialize();
    coordinator.attachFlutterLifecycle();
    if (mounted) setState(() => _isInitialized = true);
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return ref.watch(postsProvider).when(
      data: (cacheState) => switch (cacheState) {
        CacheInitial() => const SizedBox.shrink(),
        CacheLoading() => const Center(child: CircularProgressIndicator()),
        CacheSuccess(:final cachedData) => PostList(posts: cachedData),
        CacheRevalidating(:final cachedData) => PostList(posts: cachedData),
        CacheStale(:final cachedData) => PostList(posts: cachedData),
        CacheError(:final isOfflineFailure) => ErrorScreen(isOffline: isOfflineFailure),
      },
      loading: () => const CircularProgressIndicator(),
      error: (e, st) => ErrorScreen(),
    );
  }
}
```

---

## Encryption

### Automatic Encryption

Use the built-in `SecureKeyGenerator` to manage encryption keys:

```dart
import 'package:flutter_offline_cache/flutter_offline_cache.dart';

final keyGenerator = SecureKeyGenerator();
final encryptionKey = await keyGenerator.getOrCreateEncryptionKey();

final coordinator = CacheCoordinator(
  cacheConfig: CacheConfig(
    encryptionKey: encryptionKey,
  ),
);
```

All cache entries are now encrypted with AES-256 at rest in Hive.

### Custom Key Storage Name

If you have multiple coordinators or need a custom storage location:

```dart
final keyGenerator = SecureKeyGenerator(
  storageKeyName: 'my_app_cache_encryption_key',
);
final encryptionKey = await keyGenerator.getOrCreateEncryptionKey();
```

### Security Notes

- Store the encryption key in `flutter_secure_storage`, not in app code
- 32 bytes = 256 bits (AES-256)
- Key is required to decrypt cache; if key changes, old cache becomes unreadable
- Encryption happens transparently; your code doesn't need to handle it

---

## Lifecycle Management

### Pausing TTL on App Background

By default, TTL timers pause when the app goes to background (Android lifecycle `onPause`, iOS `SceneDelegate.didEnterBackground`).

```dart
coordinator.attachFlutterLifecycle();
```

When the app resumes, remaining TTL is calculated precisely — no extra delay is added.

**Why pause?** Reduces battery drain. A timer running in the background serves no purpose.

### Disposal

Always call `dispose()` when done:

```dart
@override
void dispose() {
  coordinator.dispose();
  super.dispose();
}
```

This stops all timers, closes Hive box, and cancels pending network requests.

---

## Debug Logging

Enable debug logs to see what's happening:

```dart
CacheConfig(
  enableDebugLogs: true,
)
```

**Example output:**

```
[FOC] PIPELINE #1780770593927769 STARTED
[FOC] hasCachedData: true
[FOC] isCachedDataFresh: true
[FOC] PIPELINE #1780770593927769 → YIELD CacheSuccess(localCache) — DONE
```

**Always disable in production** to reduce log spam.

---

## Request Deduplication

If multiple parts of your app call `cachedFetch()` with the same `namespace` and `key` concurrently, they share a single network request. The response is distributed to all listeners.

```dart
// Both calls fetch from the network only once
final stream1 = coordinator.cachedFetch<List<Post>>(
  namespace: 'PostRepository',
  key: 'all_posts',
  ...
);

final stream2 = coordinator.cachedFetch<List<Post>>(
  namespace: 'PostRepository',
  key: 'all_posts',
  ...
);
```

This saves bandwidth and reduces server load.

---

## Known Limitations

### 1. Concurrent Read During deleteAll

Read operations are not mutex-protected. If a read occurs while `invalidateAll()` is in progress, the reader may briefly see data that was just deleted. This is acceptable for a cache and matches typical cache semantics.

### 2. Shared CancelToken

Request deduplication uses a shared `CancelToken` per cache key. If one subscriber cancels their stream subscription, the underlying request is cancelled for **all** subscribers on that key.

### 3. Single Dio Instance

All fetchers must use the same Dio instance (or compatible instances). If you use different Dio instances with different interceptors, interceptor behavior may be inconsistent.

---

## Contributing

Contributions welcome! Please open an issue or PR on [GitHub](https://github.com/EhsanAli-dev/flutter_offline_cache).

### Running Tests

```bash
flutter test
```

### Building Documentation

```bash
dartdoc
```

---

## License

MIT License. See [LICENSE](LICENSE) file for details.

---

## Author

**Ehsan Ali** — Final-year Computer Science student at AKGEC Ghaziabad

---

## See Also

- [Dio](https://pub.dev/packages/dio) — HTTP client
- [Hive](https://pub.dev/packages/hive_flutter) — Local storage
- [RxDart](https://pub.dev/packages/rxdart) — Reactive streams
- [Riverpod](https://pub.dev/packages/riverpod) — State management (optional)
