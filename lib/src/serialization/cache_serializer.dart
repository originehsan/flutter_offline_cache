import 'dart:convert';
import '../utils/size_guard.dart';
import 'map_converter.dart';
import 'json_sanitizer.dart';

/// Thrown when serialization or deserialization of cache data fails.
class CacheSerializationException implements Exception {
  /// Human-readable description of what went wrong.
  final String failureDescription;

  /// The original error that caused this exception.
  final Object? originalError;

  const CacheSerializationException({
    required this.failureDescription,
    this.originalError,
  });

  @override
  String toString() => 'CacheSerializationException: $failureDescription'
      '${originalError != null ? ' (caused by: $originalError)' : ''}';
}

/// Handles encoding and decoding of cache payloads.
/// Encodes Dio response data to JSON strings before Hive write.
/// Decodes JSON strings from Hive back to typed domain objects.
class CacheSerializer {
  CacheSerializer._();

  /// Encodes Dio response data to a JSON string for Hive storage.
  /// Handles Map, List, and raw String response types from Dio.
  /// Validates size before returning.
  ///
  /// Throws [CacheSerializationException] if encoding fails.
  static String encodeResponseToJsonString(
    dynamic dioResponseData, {
    int maxBytes = SizeGuard.defaultMaxBytes,
  }) {
    String encodedPayload;

    try {
      if (dioResponseData is String) {
        // Some Dio configs return raw JSON string directly
        encodedPayload = dioResponseData;
      } else {
        encodedPayload = jsonEncode(dioResponseData);
      }
    } catch (error) {
      throw CacheSerializationException(
        failureDescription:
            'Failed to encode Dio response data to JSON string.',
        originalError: error,
      );
    }

    final sanitizationResult = JsonSanitizer.sanitizeBeforeWrite(
      encodedPayload,
      maxBytes: maxBytes,
    );

    if (!sanitizationResult.isValidPayload) {
      throw CacheSerializationException(
        failureDescription:
            'Payload failed sanitization: ${sanitizationResult.failureReason?.name}',
      );
    }

    return encodedPayload;
  }

  /// Decodes a JSON string from Hive to a typed domain object [T].
  /// Runs map conversion to fix Hive's dynamic key types.
  /// Validates JSON before passing to developer's [fromJsonConverter].
  ///
  /// Throws [CacheSerializationException] if decoding fails.
  static T decodeJsonStringToTyped<T>({
    required String encodedPayload,
    required T Function(dynamic json) fromJsonConverter,
  }) {
    final sanitizationResult = JsonSanitizer.sanitizeAfterRead(encodedPayload);

    if (!sanitizationResult.isValidPayload) {
      throw CacheSerializationException(
        failureDescription: 'Cached payload failed sanitization on read: '
            '${sanitizationResult.failureReason?.name}',
      );
    }

    final dynamic decodedValue =
        JsonSanitizer.decodeValidatedPayload(encodedPayload);

    final dynamic convertedValue = decodedValue is Map
        ? MapConverter.tryConvertToStringKeyedMap(decodedValue) ?? decodedValue
        : decodedValue is List
            ? MapConverter.convertDynamicList(decodedValue)
            : decodedValue;
    try {
      return fromJsonConverter(convertedValue);
    } catch (error) {
      throw CacheSerializationException(
        failureDescription:
            'fromJson converter threw an exception during deserialization.',
        originalError: error,
      );
    }
  }
}
