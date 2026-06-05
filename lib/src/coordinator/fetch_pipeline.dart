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

class FetchPipeline {
  final CacheStore _cacheStore;
  final DedupRegistry _dedupRegistry;
  final StateSnapshotRegistry _snapshotRegistry;
  final CacheConfig _cacheConfig;

  static const Duration _defaultNetworkTimeout = Duration(seconds: 30);
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

  Stream<CacheState<T>> executeFetchPipeline<T>({
    required String cacheKey,
    required Duration ttl,
    required Future<Response<dynamic>> Function() networkFetcher,
    required T Function(dynamic json) fromJsonConverter,
    Duration? networkTimeout,
    bool forceRevalidate = false,
  }) async* {
    final Duration resolvedTimeout =
        networkTimeout ?? _defaultNetworkTimeout;
    final int thisPipelineId = ++_pipelineCounter;

    _debugLog(
      '┌─────────────────────────────────────\n'
      '│ PIPELINE #$thisPipelineId STARTED\n'
      '│ key: $cacheKey\n'
      '│ ttl: ${ttl.inSeconds}s\n'
      '│ forceRevalidate: $forceRevalidate\n'
      '└─────────────────────────────────────',
    );

    final CacheEntry? existingEntry =
        await _cacheStore.readCacheEntry(cacheKey);

    final bool hasCachedData = existingEntry != null;
    final bool isCachedDataFresh =
        hasCachedData && existingEntry.isStillFresh && !forceRevalidate;
    final bool isCachedDataStale =
        hasCachedData && (existingEntry.hasExpired || forceRevalidate);

    _debugLog(
      '│ PIPELINE #$thisPipelineId CACHE CHECK\n'
      '│ hasCachedData: $hasCachedData\n'
      '│ isCachedDataFresh: $isCachedDataFresh\n'
      '│ isCachedDataStale: $isCachedDataStale\n'
      '│ cacheExpired: ${existingEntry?.hasExpired}\n'
      '│ forceRevalidate: $forceRevalidate',
    );

    // FRESH CACHE — serve and return, no network
    if (isCachedDataFresh) {
      final T? cachedTypedData = _decodeEntry(
          existingEntry, fromJsonConverter, cacheKey, thisPipelineId);

      if (cachedTypedData != null) {
        _debugLog(
            '✅ PIPELINE #$thisPipelineId → YIELD CacheSuccess(localCache) — DONE');
        final CacheSuccess<T> freshState = CacheSuccess<T>(
          cachedData: cachedTypedData,
          dataSource: CacheSource.localCache,
          entryMetadata: existingEntry.entryMetadata,
        );
        await _snapshotRegistry.saveLatestState(cacheKey, freshState);
        yield freshState;
        return;
      }

      _debugLog(
          '⚠️  PIPELINE #$thisPipelineId — fresh cache decode failed, deleting');
      await _cacheStore.deleteCacheEntry(cacheKey);
      final CacheLoading<T> loadingState = CacheLoading<T>();
      await _snapshotRegistry.saveLatestState(cacheKey, loadingState);
      _debugLog(
          '⏳ PIPELINE #$thisPipelineId → YIELD CacheLoading (fresh decode failed)');
      yield loadingState;
    }

    // STALE CACHE — serve immediately then hit network
    if (isCachedDataStale) {
      final T? staleTypedData = _decodeEntry(
          existingEntry, fromJsonConverter, cacheKey, thisPipelineId);

      if (staleTypedData != null) {
        _debugLog(
            '🔄 PIPELINE #$thisPipelineId → YIELD CacheRevalidating');
        final CacheRevalidating<T> revalidatingState = CacheRevalidating<T>(
          cachedData: staleTypedData,
          entryMetadata: existingEntry.entryMetadata,
        );
        await _snapshotRegistry.saveLatestState(cacheKey, revalidatingState);
        yield revalidatingState;
      } else {
        _debugLog(
            '⚠️  PIPELINE #$thisPipelineId — stale decode failed');
        final CacheLoading<T> loadingState = CacheLoading<T>();
        await _snapshotRegistry.saveLatestState(cacheKey, loadingState);
        _debugLog(
            '⏳ PIPELINE #$thisPipelineId → YIELD CacheLoading (stale decode failed)');
        yield loadingState;
      }
    }

    // NO CACHE — show loading
    if (!hasCachedData) {
      _debugLog('⏳ PIPELINE #$thisPipelineId → YIELD CacheLoading (no cache)');
      final CacheLoading<T> loadingState = CacheLoading<T>();
      await _snapshotRegistry.saveLatestState(cacheKey, loadingState);
      yield loadingState;
    }

    // NETWORK FETCH
    _debugLog('🌐 PIPELINE #$thisPipelineId — starting network fetch...');

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

      _debugLog('✅ PIPELINE #$thisPipelineId — network fetch SUCCESS');

      final String encodedNetworkPayload =
          CacheSerializer.encodeResponseToJsonString(
        networkResponseData,
        maxBytes: _cacheConfig.maxEntrySizeBytes,
      );

      final T freshTypedData;
      try {
        freshTypedData = CacheSerializer.decodeJsonStringToTyped<T>(
          encodedPayload: encodedNetworkPayload,
          fromJsonConverter: fromJsonConverter,
        );
        _debugLog(
            '✅ PIPELINE #$thisPipelineId — network response decoded successfully');
      } on CacheSerializationException catch (decodeError, decodeStack) {
        _debugLog(
            '❌ PIPELINE #$thisPipelineId — decode FAILED: $decodeError');

        final CacheEntry? entryForDecodeError =
            await _cacheStore.readCacheEntry(cacheKey);

        if (entryForDecodeError != null) {
          final T? lastGoodData = _decodeEntry(
              entryForDecodeError, fromJsonConverter, cacheKey, thisPipelineId);
          if (lastGoodData != null) {
            _debugLog(
                '⚠️  PIPELINE #$thisPipelineId → YIELD CacheStale (decode failed, has cache)');
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
            '❌ PIPELINE #$thisPipelineId → YIELD CacheError (decode failed, no cache)');
        final CacheError<T> errorState = CacheError<T>(
          networkError: decodeError,
          isOfflineFailure: false,
          networkErrorStackTrace: decodeStack,
        );
        await _snapshotRegistry.saveLatestState(cacheKey, errorState);
        yield errorState;
        return;
      }

      final CacheEntry? currentEntry =
          await _cacheStore.readCacheEntry(cacheKey);

      final bool newerPipelineAlreadyWrote = currentEntry != null &&
          currentEntry.entryMetadata.pipelineId > thisPipelineId;

      if (!newerPipelineAlreadyWrote) {
        _debugLog('💾 PIPELINE #$thisPipelineId — writing to Hive');

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

        _debugLog(
            '✅ PIPELINE #$thisPipelineId → YIELD CacheSuccess(network)');
        final CacheSuccess<T> networkSuccessState = CacheSuccess<T>(
          cachedData: freshTypedData,
          dataSource: CacheSource.network,
          entryMetadata: freshEntryMetadata,
        );
        await _snapshotRegistry.saveLatestState(cacheKey, networkSuccessState);
        yield networkSuccessState;
      } else {
        _debugLog(
          '⏭️  PIPELINE #$thisPipelineId — skip write, newer pipeline '
          '${currentEntry.entryMetadata.pipelineId} already wrote\n'
          '✅ PIPELINE #$thisPipelineId → YIELD CacheSuccess(network) anyway',
        );
        final CacheSuccess<T> networkSuccessState = CacheSuccess<T>(
          cachedData: freshTypedData,
          dataSource: CacheSource.network,
          entryMetadata: currentEntry.entryMetadata,
        );
        await _snapshotRegistry.saveLatestState(cacheKey, networkSuccessState);
        yield networkSuccessState;
      }
    } catch (networkError, stackTrace) {
      _debugLog(
        '❌ PIPELINE #$thisPipelineId — network FAILED\n'
        '   error: $networkError',
      );

      final ErrorClassification errorClassification =
          ErrorClassifier.classifyNetworkError(networkError);
      final bool isOffline =
          errorClassification == ErrorClassification.offlineFailure;

      _debugLog(
        '   classification: ${errorClassification.name}\n'
        '   isOffline: $isOffline',
      );

      final CacheEntry? currentEntryForError =
          await _cacheStore.readCacheEntry(cacheKey);

      _debugLog(
          '   hasCacheForError: ${currentEntryForError != null}');

      if (currentEntryForError != null) {
        final T? staleTypedData = _decodeEntry(
            currentEntryForError, fromJsonConverter, cacheKey, thisPipelineId);

        if (staleTypedData != null) {
          _debugLog(
              '⚠️  PIPELINE #$thisPipelineId → YIELD CacheStale (has cache)');
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
          '❌ PIPELINE #$thisPipelineId → YIELD CacheError(isOffline: $isOffline)');
      final CacheError<T> errorState = CacheError<T>(
        networkError: networkError,
        isOfflineFailure: isOffline,
        networkErrorStackTrace: stackTrace,
      );
      await _snapshotRegistry.saveLatestState(cacheKey, errorState);
      yield errorState;
    }

    _debugLog('🏁 PIPELINE #$thisPipelineId COMPLETED');
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
      log(message, name: 'FOC');
    }
  }
}