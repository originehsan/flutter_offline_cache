import 'dart:async';
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

class FetchPipeline {
  final CacheStore _cacheStore;
  final DedupRegistry _dedupRegistry;
  final StateSnapshotRegistry _snapshotRegistry;
  final CacheConfig _cacheConfig;

  static const Duration _defaultNetworkTimeout = Duration(seconds: 30);

 /// Initialize from current microsecond timestamp to prevent
/// cross-session generation token conflicts.
///
/// Previous session pipelines will always have lower IDs than
/// current session pipelines because each new app session starts
/// with a counter value based on current time in microseconds.
///
/// microsecondsSinceEpoch used over milliseconds for better
/// resolution — prevents ID collision if app restarts within
/// same millisecond (common in tests and hot restart).
///
/// Safe range: microsecondsSinceEpoch fits in Dart int64 until
/// year 285,423 — no overflow concern.
int _pipelineCounter = DateTime.now().microsecondsSinceEpoch;

  FetchPipeline({
    required CacheStore cacheStore,
    required DedupRegistry dedupRegistry,
    required StateSnapshotRegistry snapshotRegistry,
    required CacheConfig cacheConfig,
  })  : _cacheStore = cacheStore,
        _dedupRegistry = dedupRegistry,
        _snapshotRegistry = snapshotRegistry,
        _cacheConfig = cacheConfig;

  /// Returns next monotonic pipeline ID.
  /// Called by coordinator before starting each pipeline.
  int nextPipelineId() => ++_pipelineCounter;

  Stream<CacheState<T>> executeFetchPipeline<T>({
    required String cacheKey,
    required Duration ttl,
    required Future<Response<dynamic>> Function() networkFetcher,
    required T Function(dynamic json) fromJsonConverter,
    required int pipelineId,
    Duration? networkTimeout,
    bool forceRevalidate = false,
  }) async* {
    final Duration resolvedTimeout =
        networkTimeout ?? _defaultNetworkTimeout;

    _debugLog(
      '┌─────────────────────────────────────\n'
      '│ PIPELINE #$pipelineId STARTED\n'
      '│ key: $cacheKey\n'
      '│ ttl: ${ttl.inSeconds}s\n'
      '│ forceRevalidate: $forceRevalidate\n'
      '└─────────────────────────────────────',
    );

    final CacheEntry? existingEntry =
        await _cacheStore.readCacheEntry(cacheKey);

    final bool hasCachedData = existingEntry != null;

    // Bug 9 fix — use else if chain instead of three separate if blocks.
    // Mutually exclusive states must not be evaluated independently.
    final bool isCachedDataFresh =
        hasCachedData && existingEntry.isStillFresh && !forceRevalidate;
    final bool isCachedDataStale =
        hasCachedData && (existingEntry.hasExpired || forceRevalidate);

    _debugLog(
      '│ PIPELINE #$pipelineId CACHE CHECK\n'
      '│ hasCachedData: $hasCachedData\n'
      '│ isCachedDataFresh: $isCachedDataFresh\n'
      '│ isCachedDataStale: $isCachedDataStale\n'
      '│ cacheExpired: ${existingEntry?.hasExpired}\n'
      '│ forceRevalidate: $forceRevalidate',
    );

    // Bug 9 fix — else if chain guarantees only one branch executes
    if (isCachedDataFresh) {
      // FRESH CACHE — serve immediately and return, no network call
      final T? cachedTypedData = _decodeEntry(
        existingEntry,
        fromJsonConverter,
        cacheKey,
        pipelineId,
      );

      if (cachedTypedData != null) {
        _debugLog(
            '✅ PIPELINE #$pipelineId → YIELD CacheSuccess(localCache) — DONE');
        final CacheSuccess<T> freshState = CacheSuccess<T>(
          cachedData: cachedTypedData,
          dataSource: CacheSource.localCache,
          entryMetadata: existingEntry.entryMetadata,
        );
        await _snapshotRegistry.saveLatestState(cacheKey, freshState);
        yield freshState;
        return;
      }

      // Fresh entry decode failed — corrupt entry, delete and fall through
      _debugLog(
          '⚠️  PIPELINE #$pipelineId — fresh cache decode failed, deleting');
      await _cacheStore.deleteCacheEntry(cacheKey);
      final CacheLoading<T> loadingState = CacheLoading<T>();
      await _snapshotRegistry.saveLatestState(cacheKey, loadingState);
      _debugLog(
          '⏳ PIPELINE #$pipelineId → YIELD CacheLoading (fresh decode failed)');
      yield loadingState;
    } else if (isCachedDataStale) {
      // STALE CACHE — serve immediately then continue to network
      final T? staleTypedData = _decodeEntry(
        existingEntry,
        fromJsonConverter,
        cacheKey,
        pipelineId,
      );

      if (staleTypedData != null) {
        _debugLog('🔄 PIPELINE #$pipelineId → YIELD CacheRevalidating');
        final CacheRevalidating<T> revalidatingState = CacheRevalidating<T>(
          cachedData: staleTypedData,
          entryMetadata: existingEntry.entryMetadata,
        );
        await _snapshotRegistry.saveLatestState(cacheKey, revalidatingState);
        yield revalidatingState;
      } else {
        // Stale entry decode failed — treat as no cache
        _debugLog('⚠️  PIPELINE #$pipelineId — stale decode failed');
        final CacheLoading<T> loadingState = CacheLoading<T>();
        await _snapshotRegistry.saveLatestState(cacheKey, loadingState);
        _debugLog(
            '⏳ PIPELINE #$pipelineId → YIELD CacheLoading (stale decode failed)');
        yield loadingState;
      }
    } else {
      // NO CACHE — show loading
      _debugLog('⏳ PIPELINE #$pipelineId → YIELD CacheLoading (no cache)');
      final CacheLoading<T> loadingState = CacheLoading<T>();
      await _snapshotRegistry.saveLatestState(cacheKey, loadingState);
      yield loadingState;
    }

    // NETWORK FETCH — runs for stale and no-cache paths
    _debugLog('🌐 PIPELINE #$pipelineId — starting network fetch...');

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

      _debugLog('✅ PIPELINE #$pipelineId — network fetch SUCCESS');

      final String encodedNetworkPayload =
          CacheSerializer.encodeResponseToJsonString(
        networkResponseData,
        maxBytes: _cacheConfig.maxEntrySizeBytes,
      );

      // Decode BEFORE writing — never overwrite good cache with bad data
      final T freshTypedData;
      try {
        freshTypedData = CacheSerializer.decodeJsonStringToTyped<T>(
          encodedPayload: encodedNetworkPayload,
          fromJsonConverter: fromJsonConverter,
        );
        _debugLog(
            '✅ PIPELINE #$pipelineId — network response decoded successfully');
      } on CacheSerializationException catch (decodeError, decodeStack) {
        _debugLog('❌ PIPELINE #$pipelineId — decode FAILED: $decodeError');

        // Never write bad data — serve last good cache as stale
        final CacheEntry? entryForDecodeError =
            await _cacheStore.readCacheEntry(cacheKey);

        if (entryForDecodeError != null) {
          final T? lastGoodData = _decodeEntry(
            entryForDecodeError,
            fromJsonConverter,
            cacheKey,
            pipelineId,
          );
          if (lastGoodData != null) {
            _debugLog(
                '⚠️  PIPELINE #$pipelineId → YIELD CacheStale (decode failed, has cache)');
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

        _debugLog(
            '❌ PIPELINE #$pipelineId → YIELD CacheError (decode failed, no cache)');
        final CacheError<T> errorState = CacheError<T>(
          networkError: decodeError,
          errorClassification: ErrorClassification.serverFailure,
          networkErrorStackTrace: decodeStack,
        );
        await _snapshotRegistry.saveLatestState(cacheKey, errorState);
        yield errorState;
        return;
      }

      // Generation token check — skip write if newer pipeline already wrote
      final CacheEntry? currentEntry =
          await _cacheStore.readCacheEntry(cacheKey);

      final bool newerPipelineAlreadyWrote = currentEntry != null &&
          currentEntry.entryMetadata.pipelineId > pipelineId;

      if (!newerPipelineAlreadyWrote) {
        _debugLog('💾 PIPELINE #$pipelineId — writing to Hive');

        final CacheMetadata freshEntryMetadata =
            CacheMetadata.fromNetworkResponse(
          ttl: ttl,
          pipelineId: pipelineId,
        );

        final CacheEntry freshCacheEntry = CacheEntry(
          encodedPayload: encodedNetworkPayload,
          entryMetadata: freshEntryMetadata,
        );

        await _cacheStore.writeCacheEntry(cacheKey, freshCacheEntry);

        _debugLog(
            '✅ PIPELINE #$pipelineId → YIELD CacheSuccess(network)');
        final CacheSuccess<T> networkSuccessState = CacheSuccess<T>(
          cachedData: freshTypedData,
          dataSource: CacheSource.network,
          entryMetadata: freshEntryMetadata,
        );
        await _snapshotRegistry.saveLatestState(
            cacheKey, networkSuccessState);
        yield networkSuccessState;
      } else {
        _debugLog(
          '⏭️  PIPELINE #$pipelineId — skip write, newer pipeline '
          '${currentEntry.entryMetadata.pipelineId} already wrote\n'
          '✅ PIPELINE #$pipelineId → YIELD CacheSuccess(network) anyway',
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
    } on TimeoutException catch (timeoutError, stackTrace) {
      // Bug 5 fix — TimeoutException caught separately from DioException
      // Classified as timeoutFailure not offlineFailure
      _debugLog(
        '⏱️  PIPELINE #$pipelineId — TIMEOUT\n'
        '   error: $timeoutError',
      );
       yield* _handleNetworkError<T>(
        cacheKey: cacheKey,
        networkError: timeoutError,
        stackTrace: stackTrace,
        pipelineId: pipelineId,
        fromJsonConverter: fromJsonConverter,
      );
    } catch (networkError, stackTrace) {
      _debugLog(
        '❌ PIPELINE #$pipelineId — network FAILED\n'
        '   error: $networkError',
      );

      final ErrorClassification errorClassification =
          ErrorClassifier.classifyNetworkError(networkError);

      _debugLog(
        '   classification: ${errorClassification.name}',
      );

      final CacheEntry? currentEntryForError =
          await _cacheStore.readCacheEntry(cacheKey);

      _debugLog(
          '   hasCacheForError: ${currentEntryForError != null}');

      if (currentEntryForError != null) {
        final T? staleTypedData = _decodeEntry(
          currentEntryForError,
          fromJsonConverter,
          cacheKey,
          pipelineId,
        );

        if (staleTypedData != null) {
          _debugLog(
              '⚠️  PIPELINE #$pipelineId → YIELD CacheStale (has cache)');
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

      _debugLog(
          '❌ PIPELINE #$pipelineId → YIELD CacheError(${errorClassification.name})');
      final CacheError<T> errorState = CacheError<T>(
        networkError: networkError,
        errorClassification: errorClassification,
        networkErrorStackTrace: stackTrace,
      );
      await _snapshotRegistry.saveLatestState(cacheKey, errorState);
      yield errorState;
    }

    _debugLog('🏁 PIPELINE #$pipelineId COMPLETED');
  }

  /// Handles network errors by serving cached data as stale
  /// or emitting CacheError if no cache exists.
  /// Extracted to avoid code duplication between TimeoutException
  /// and general catch blocks.
  Stream<CacheState<T>> _handleNetworkError<T>({
    required String cacheKey,
    required Object networkError,
    required StackTrace stackTrace,
    required int pipelineId,
    required T Function(dynamic json) fromJsonConverter,
  }) async* {
    final ErrorClassification errorClassification =
        ErrorClassifier.classifyNetworkError(networkError);

    final CacheEntry? currentEntryForError =
        await _cacheStore.readCacheEntry(cacheKey);

    if (currentEntryForError != null) {
      final T? staleTypedData = _decodeEntry(
        currentEntryForError,
        fromJsonConverter,
        cacheKey,
        pipelineId,
      );

      if (staleTypedData != null) {
        _debugLog(
            '⚠️  PIPELINE #$pipelineId → YIELD CacheStale (has cache)');
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

    _debugLog(
        '❌ PIPELINE #$pipelineId → YIELD CacheError(${errorClassification.name})');
    final CacheError<T> errorState = CacheError<T>(
      networkError: networkError,
      errorClassification: errorClassification,
      networkErrorStackTrace: stackTrace,
    );
    await _snapshotRegistry.saveLatestState(cacheKey, errorState);
    yield errorState;
  }

  T? _decodeEntry<T>(
    CacheEntry entry,
    T Function(dynamic json) fromJsonConverter,
    String cacheKey,
    int pipelineId,
  ) {
    try {
      return CacheSerializer.decodeJsonStringToTyped<T>(
        encodedPayload: entry.encodedPayload,
        fromJsonConverter: fromJsonConverter,
      );
    } catch (error) {
      _debugLog(
          '❌ PIPELINE #$pipelineId _decodeEntry FAILED for: $cacheKey — $error');
      return null;
    }
  }

  void _debugLog(String message) {
    if (_cacheConfig.enableDebugLogs && kDebugMode) {
      debugPrint('[FOC] $message');
    }
  }
}