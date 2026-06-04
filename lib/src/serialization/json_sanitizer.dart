import 'dart:convert';
import '../utils/size_guard.dart';

/// Reasons why a JSON payload failed sanitization.
enum SanitizationFailureReason {
  /// Payload string is null or empty.
  emptyPayload,

  /// Payload is not valid JSON — jsonDecode threw.
  invalidJson,

  /// Payload decoded to a primitive (String, int, bool) instead of Map or List.
  /// Only Map and List responses are cacheable.
  unsupportedJsonType,

  /// Payload exceeds the configured max entry size in bytes.
  payloadTooLarge,
}

/// Result of a sanitization check.
/// Result of a sanitization check.
class SanitizationResult {
  /// Whether the payload passed all sanitization checks.
  final bool isValidPayload;

  /// Reason for failure if [isValidPayload] is false.
  /// Null if [isValidPayload] is true.
  final SanitizationFailureReason? failureReason;

  /// Creates a passing sanitization result.
  const SanitizationResult.passed()
      : isValidPayload = true,
        failureReason = null;

  /// Creates a failing sanitization result with a reason.
  const SanitizationResult.failed(SanitizationFailureReason reason)
      : isValidPayload = false,
        failureReason = reason;
}

/// Validates JSON payloads before writing to Hive and after reading from Hive.
/// Prevents corrupt, oversized, or invalid data from entering the cache.
class JsonSanitizer {
  JsonSanitizer._();

  /// Validates a JSON string before writing to Hive.
  /// Checks: not empty, valid JSON, Map or List type, within size limit.
  static SanitizationResult sanitizeBeforeWrite(
    String encodedPayload, {
    int maxBytes = SizeGuard.defaultMaxBytes,
  }) {
    if (encodedPayload.isEmpty) {
      return const SanitizationResult.failed(
        SanitizationFailureReason.emptyPayload,
      );
    }

    if (SizeGuard.isExceeded(encodedPayload, maxBytes: maxBytes)) {
      return const SanitizationResult.failed(
        SanitizationFailureReason.payloadTooLarge,
      );
    }

    dynamic decodedValue;
    try {
      decodedValue = jsonDecode(encodedPayload);
    } catch (_) {
      return const SanitizationResult.failed(
        SanitizationFailureReason.invalidJson,
      );
    }

    if (decodedValue is! Map && decodedValue is! List) {
      return const SanitizationResult.failed(
        SanitizationFailureReason.unsupportedJsonType,
      );
    }

    return const SanitizationResult.passed();
  }

  /// Validates a JSON string read from Hive before passing to [fromJson].
  /// Less strict than [sanitizeBeforeWrite] — only checks valid JSON and type.
  static SanitizationResult sanitizeAfterRead(String encodedPayload) {
    if (encodedPayload.isEmpty) {
      return const SanitizationResult.failed(
        SanitizationFailureReason.emptyPayload,
      );
    }

    dynamic decodedValue;
    try {
      decodedValue = jsonDecode(encodedPayload);
    } catch (_) {
      return const SanitizationResult.failed(
        SanitizationFailureReason.invalidJson,
      );
    }

    if (decodedValue is! Map && decodedValue is! List) {
      return const SanitizationResult.failed(
        SanitizationFailureReason.unsupportedJsonType,
      );
    }

    return const SanitizationResult.passed();
  }

  /// Decodes a validated JSON string to its dynamic value.
  /// Call [sanitizeAfterRead] before calling this.
  static dynamic decodeValidatedPayload(String encodedPayload) {
    return jsonDecode(encodedPayload);
  }
}