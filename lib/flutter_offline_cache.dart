// flutter_offline_cache
// Offline-first caching for Flutter with stale-while-revalidate pattern.
// Wraps Dio and Hive with TTL management, background revalidation,
// request deduplication, and offline fallback via reactive streams.

// Main coordinator — entry point for all cache operations
export 'src/coordinator/cache_coordinator.dart';

// Cache states — pattern match on these in your UI
export 'src/models/cache_state.dart';

// Configuration
// Configuration
export 'src/models/cache_config.dart' show CacheConfig, cacheForever;
export 'src/models/cache_policy.dart';

// Metadata — available on CacheSuccess and CacheRevalidating states
export 'src/models/cache_metadata.dart';

// Error classification — use with CacheError.errorClassification in UI
export 'src/network/error_classifier.dart';

// Abstract interfaces — inject mocks in tests
export 'src/store/cache_store.dart';
export 'src/network/connectivity_checker.dart';

// Security — generate AES encryption key for encrypted cache
export 'src/security/secure_key_generator.dart';
export 'src/security/encryption_config.dart';