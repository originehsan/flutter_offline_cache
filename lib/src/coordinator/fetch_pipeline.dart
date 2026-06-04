import 'dart:async';
import 'dart:developer';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import '../models/cache_state.dart';
import '../models/cache_entry.dart';
import '../models/cache_metadata.dart';
import '../models/cache_config.dart';
import '../store/cache_store.dart';
import '../network/dedup_registry.dart';
import '../network/error_classifier.dart';
import '../serialization/cache_serializer.dart';
import 'state_snapshot_registry.dart';

/// Executes the stale-while-revalidate fetch pipeline for a single cache key.
/// Uses async* generator — no StreamController, no lifecycle management needed.
/// Dart handles stream cleanup automatically when subscriber cancels.
///
/// ## SWR Behavior
/// - Fresh cache: serves from cache immediately, no network call
/// - Stale cache: serves from cache immediately, revalidates in background
/// - No cache: shows loading, fetches from network
///
/// ## Generation Token
/// Each pipeline gets a monotonic ID. A newer pipeline's write supersedes
/// an older pipeline's write. This prevents race conditions where a slow
/// older pipeline overwrites fresh data written by a faster newer pipeline.
///
/// ## Cancellation Note
/// If subscriber cancels between yield points, the generator stops.
/// Background revalidation cancels with the subscriber. Document this.
class FetchPipeline {
  final CacheStore _cacheStore;
  final DedupRegistry _dedupRegistry;
  final StateSnapshotRegistry _snapshotRegistry;
  final CacheConfig _cacheConfig;

  /// Default network timeout if not specified per request.
  static const Duration _defaultNetworkTimeout = Duration(seconds: 30);

  /// Monotonic counter — incremented per pipeline execution.
  /// Clock-independent generation token for write ordering.
  static int _pipelineCounter = 0;

  FetchPipeline({
    required CacheStore cacheStore,
    required DedupRegistry dedupRegistry,
    required StateSnapshotRegistry snapshotRegistry,
    required CacheConfig cacheConfig,
  })  : _cacheStore = cacheStore,
        _dedupRegistry = dedupRegistry,
        _snapshotRegistry = snapshotRegistry,
        _cacheConfig = cacheConfig;

  /// Executes the full SWR pipeline for [cacheKey].
  /// Yields [CacheState] transitions based on cache and network state.
  Stream<CacheState<T>> executeFetchPipeline<T>({
    required String cacheKey,
    required Duration ttl,
    required Future<Response<dynamic>> Function() networkFetcher,
    required T Function(dynamic json) fromJsonConverter,
    Duration? networkTimeout,
  }) async* {
    final Duration resolvedTimeout =
        networkTimeout ?? _defaultNetworkTimeout;

    // Monotonic generation token — captures pipeline order at start
    final int thisPipelineId = ++_pipelineCounter;

    final CacheEntry? existingEntry =
        await _cacheStore.readCacheEntry(cacheKey);

    final bool hasCachedData = existingEntry != null;
    final bool isCachedDataFresh =
        hasCachedData && existingEntry.isStillFresh;
    final bool isCachedDataStale =
        hasCachedData && existingEntry.hasExpired;

    // Bug B + C fix — fresh cache yields CacheSuccess and returns
    // No network call for fresh data — true SWR behavior
    if (isCachedDataFresh) {
      final T? cachedTypedData = _decodeEntry(
        existingEntry,
        fromJsonConverter,
        cacheKey,
      );

      if (cachedTypedData != null) {
        final CacheSuccess<T> freshState = CacheSuccess<T>(
          cachedData: cachedTypedData,
          dataSource: CacheSource.localCache,
          entryMetadata: existingEntry.entryMetadata,
        );
        await _snapshotRegistry.saveLatestState(cacheKey, freshState);
        yield freshState;
        return; // Fresh cache — no network needed
      }

      // Fresh entry exists but decode failed — corrupt entry
      // Delete it and fall through to network fetch
      await _cacheStore.deleteCacheEntry(cacheKey);
      final CacheLoading<T> loadingState = CacheLoading<T>();
      await _snapshotRegistry.saveLatestState(cacheKey, loadingState);
      yield loadingState;
    }

    // Stale cache — serve immediately then revalidate in background
    if (isCachedDataStale) {
      final T? staleTypedData = _decodeEntry(
        existingEntry,
        fromJsonConverter,
        cacheKey,
      );

      if (staleTypedData != null) {
        final CacheRevalidating<T> revalidatingState = CacheRevalidating<T>(
          cachedData: staleTypedData,
          entryMetadata: existingEntry.entryMetadata,
        );
        await _snapshotRegistry.saveLatestState(cacheKey, revalidatingState);
        yield revalidatingState;
      } else {
        // Stale entry decode failed — treat as no cache
        final CacheLoading<T> loadingState = CacheLoading<T>();
        await _snapshotRegistry.saveLatestState(cacheKey, loadingState);
        yield loadingState;
      }
    }

    // No cache at all — show loading
    if (!hasCachedData) {
      final CacheLoading<T> loadingState = CacheLoading<T>();
      await _snapshotRegistry.saveLatestState(cacheKey, loadingState);
      yield loadingState;
    }

    // Network fetch — deduplicated + timeout protected
    try {
      final dynamic networkResponseData = await _dedupRegistry
          .executeWithDeduplication(cacheKey, networkFetcher)
          .timeout(
            resolvedTimeout,
            onTimeout: () => throw TimeoutException(
              'flutter_offline_cache: Network fetch timed out after '
              '${resolvedTimeout.inSeconds}s for key: $cacheKey',
              resolvedTimeout,
            ),
          );

      final String encodedNetworkPayload =
          CacheSerializer.encodeResponseToJsonString(
        networkResponseData,
        maxBytes: _cacheConfig.maxEntrySizeBytes,
      );

      // Bug D fix — decode BEFORE writing in separate try/catch
      // If decode fails, never write bad data to Hive
      final T freshTypedData;
      try {
        freshTypedData = CacheSerializer.decodeJsonStringToTyped<T>(
          encodedPayload: encodedNetworkPayload,
          fromJsonConverter: fromJsonConverter,
        );
      } on CacheSerializationException catch (decodeError, decodeStack) {
        // Network succeeded but response unparseable
        // Never write to Hive — preserve existing good cache
        _debugLog(
          'Decode failed for key: $cacheKey — '
          'network response unparseable. Hive not written.',
        );

        final CacheEntry? entryForDecodeError =
            await _cacheStore.readCacheEntry(cacheKey);

        if (entryForDecodeError != null) {
          final T? lastGoodData = _decodeEntry(
            entryForDecodeError,
            fromJsonConverter,
            cacheKey,
          );
          if (lastGoodData != null) {
            final CacheStale<T> staleState = CacheStale<T>(
              cachedData: lastGoodData,
              refreshError: decodeError,
              refreshErrorStackTrace: decodeStack,
            );
            await _snapshotRegistry.saveLatestState(cacheKey, staleState);
            yield staleState;
            return;
          }
        }

        final CacheError<T> errorState = CacheError<T>(
          networkError: decodeError,
          isOfflineFailure: false,
          networkErrorStackTrace: decodeStack,
        );
        await _snapshotRegistry.saveLatestState(cacheKey, errorState);
        yield errorState;
        return;
      }

      // Bug A + G fix — monotonic pipeline ID comparison
      // Skip write if a newer pipeline already wrote to this key
      final CacheEntry? currentEntry =
          await _cacheStore.readCacheEntry(cacheKey);

      final bool newerPipelineAlreadyWrote = currentEntry != null &&
          currentEntry.entryMetadata.pipelineId > thisPipelineId;

      if (!newerPipelineAlreadyWrote) {
        final CacheMetadata freshEntryMetadata =
            CacheMetadata.fromNetworkResponse(
          ttl: ttl,
          pipelineId: thisPipelineId,
        );

        final CacheEntry freshCacheEntry = CacheEntry(
          encodedPayload: encodedNetworkPayload,
          entryMetadata: freshEntryMetadata,
        );

        await _cacheStore.writeCacheEntry(cacheKey, freshCacheEntry);

        // Always yield CacheSuccess regardless of write decision
        final CacheSuccess<T> networkSuccessState = CacheSuccess<T>(
          cachedData: freshTypedData,
          dataSource: CacheSource.network,
          entryMetadata: freshEntryMetadata,
        );
        await _snapshotRegistry.saveLatestState(
            cacheKey, networkSuccessState);
        yield networkSuccessState;
      } else {
        // Newer pipeline already wrote — skip write but still yield fresh data
        _debugLog(
          'Skipping write for key: $cacheKey — '
          'newer pipeline (${currentEntry.entryMetadata.pipelineId}) '
          'already wrote. This pipeline: $thisPipelineId.',
        );

        final CacheSuccess<T> networkSuccessState = CacheSuccess<T>(
          cachedData: freshTypedData,
          dataSource: CacheSource.network,
          entryMetadata: currentEntry.entryMetadata,
        );
        await _snapshotRegistry.saveLatestState(
            cacheKey, networkSuccessState);
        yield networkSuccessState;
      }
    } catch (networkError, stackTrace) {
      // Bug 4 fix — all errors after yield caught as typed states
      // Riverpod sees CacheStale/CacheError not AsyncError

      final ErrorClassification errorClassification =
          ErrorClassifier.classifyNetworkError(networkError);

      final bool isOffline =
          errorClassification == ErrorClassification.offlineFailure;

      // Bug 14 fix — re-read from store not stale existingEntry reference
      final CacheEntry? currentEntryForError =
          await _cacheStore.readCacheEntry(cacheKey);

      if (currentEntryForError != null) {
        final T? staleTypedData = _decodeEntry(
          currentEntryForError,
          fromJsonConverter,
          cacheKey,
        );

        if (staleTypedData != null) {
          final CacheStale<T> staleState = CacheStale<T>(
            cachedData: staleTypedData,
            refreshError: networkError,
            refreshErrorStackTrace: stackTrace,
          );
          await _snapshotRegistry.saveLatestState(cacheKey, staleState);
          yield staleState;
          return;
        }
      }

      final CacheError<T> errorState = CacheError<T>(
        networkError: networkError,
        isOfflineFailure: isOffline,
        networkErrorStackTrace: stackTrace,
      );
      await _snapshotRegistry.saveLatestState(cacheKey, errorState);
      yield errorState;
    }
  }

  /// Decodes a [CacheEntry] to typed [T] using [fromJsonConverter].
  /// Returns null if decoding fails — caller handles null safely.
  T? _decodeEntry<T>(
    CacheEntry entry,
    T Function(dynamic json) fromJsonConverter,
    String cacheKey,
  ) {
    try {
      return CacheSerializer.decodeJsonStringToTyped<T>(
        encodedPayload: entry.encodedPayload,
        fromJsonConverter: fromJsonConverter,
      );
    } catch (error) {
      _debugLog(
        'Failed to decode cache entry for key: $cacheKey — error: $error',
      );
      return null;
    }
  }

  void _debugLog(String message) {
    if (_cacheConfig.enableDebugLogs && kDebugMode) {
      log(message, name: 'flutter_offline_cache');
    }
  }
}