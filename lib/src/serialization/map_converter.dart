/// Converts Hive's [Map<dynamic, dynamic>] output to [Map<String, dynamic>].
/// Hive does not preserve key types on read — all keys come back as [dynamic].
/// Every [fromJson] method in Flutter expects [Map<String, dynamic>].
/// This converter handles nested maps and lists recursively.
class MapConverter {
  MapConverter._();

  /// Converts a [Map<dynamic, dynamic>] to [Map<String, dynamic>].
  /// Recursively converts all nested maps and lists.
  static Map<String, dynamic> convertToStringKeyedMap(Map<dynamic, dynamic> rawMap) {
    return rawMap.map((key, value) {
      return MapEntry(
        key.toString(),
        _convertValue(value),
      );
    });
  }

  /// Converts a dynamic value read from Hive to its correct typed form.
  /// Handles nested maps, lists of maps, and primitive values.
  static dynamic _convertValue(dynamic value) {
    if (value is Map<dynamic, dynamic>) {
      return convertToStringKeyedMap(value);
    }

    if (value is Map<String, dynamic>) {
      return _convertStringKeyedMapValues(value);
    }

    if (value is List) {
      return convertDynamicList(value);
    }

    return value;
  }

  /// Converts a [List<dynamic>] read from Hive.
  /// Each element that is a map is recursively converted.
  static List<dynamic> convertDynamicList(List<dynamic> rawList) {
    return rawList.map(_convertValue).toList();
  }

  /// Ensures values inside an already-string-keyed map are also converted.
  /// Handles cases where outer keys are String but inner values are still dynamic maps.
  static Map<String, dynamic> _convertStringKeyedMapValues(
    Map<String, dynamic> map,
  ) {
    return map.map((key, value) => MapEntry(key, _convertValue(value)));
  }

  /// Safely converts any dynamic value from Hive to [Map<String, dynamic>].
  /// Returns null if conversion is not possible.
  static Map<String, dynamic>? tryConvertToStringKeyedMap(dynamic rawValue) {
    if (rawValue == null) return null;
    if (rawValue is Map<String, dynamic>) {
      return _convertStringKeyedMapValues(rawValue);
    }
    if (rawValue is Map<dynamic, dynamic>) {
      return convertToStringKeyedMap(rawValue);
    }
    return null;
  }
}