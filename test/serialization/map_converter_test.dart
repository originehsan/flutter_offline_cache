import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_offline_cache/src/serialization/map_converter.dart';

void main() {
  group('MapConverter', () {
    test('converts Map<dynamic, dynamic> to Map<String, dynamic>', () {
      final Map<dynamic, dynamic> rawMap = <dynamic, dynamic>{
        'name': 'John',
        'age': 30,
      };
      final Map<String, dynamic> result =
          MapConverter.convertToStringKeyedMap(rawMap);
      expect(result, isA<Map<String, dynamic>>());
      expect(result['name'], equals('John'));
      expect(result['age'], equals(30));
    });

    test('converts nested Map<dynamic, dynamic> recursively', () {
      final Map<dynamic, dynamic> rawMap = <dynamic, dynamic>{
        'user': <dynamic, dynamic>{
          'name': 'John',
          'age': 30,
        },
      };
      final Map<String, dynamic> result =
          MapConverter.convertToStringKeyedMap(rawMap);
      expect(result['user'], isA<Map<String, dynamic>>());
      expect((result['user'] as Map<String, dynamic>)['name'], equals('John'));
    });

    test('converts List of Maps recursively', () {
      final List<dynamic> rawList = <dynamic>[
        <dynamic, dynamic>{'id': 1, 'title': 'Movie 1'},
        <dynamic, dynamic>{'id': 2, 'title': 'Movie 2'},
      ];
      final List<dynamic> result = MapConverter.convertDynamicList(rawList);
      expect(result[0], isA<Map<String, dynamic>>());
      expect((result[0] as Map<String, dynamic>)['title'], equals('Movie 1'));
      expect(result[1], isA<Map<String, dynamic>>());
      expect((result[1] as Map<String, dynamic>)['title'], equals('Movie 2'));
    });

    test('leaves primitive values unchanged', () {
      final Map<dynamic, dynamic> rawMap = <dynamic, dynamic>{
        'count': 42,
        'active': true,
        'score': 3.14,
        'name': 'test',
      };
      final Map<String, dynamic> result =
          MapConverter.convertToStringKeyedMap(rawMap);
      expect(result['count'], equals(42));
      expect(result['active'], equals(true));
      expect(result['score'], equals(3.14));
      expect(result['name'], equals('test'));
    });

    test('tryConvertToStringKeyedMap returns null for null input', () {
      final Map<String, dynamic>? result =
          MapConverter.tryConvertToStringKeyedMap(null);
      expect(result, isNull);
    });

    test('tryConvertToStringKeyedMap returns null for non-map input', () {
      final Map<String, dynamic>? result =
          MapConverter.tryConvertToStringKeyedMap('not a map');
      expect(result, isNull);
    });

    test('tryConvertToStringKeyedMap converts valid map correctly', () {
      final Map<dynamic, dynamic> rawMap = <dynamic, dynamic>{
        'key': 'value',
      };
      final Map<String, dynamic>? result =
          MapConverter.tryConvertToStringKeyedMap(rawMap);
      expect(result, isNotNull);
      expect(result!['key'], equals('value'));
    });

    test('handles deeply nested maps and lists', () {
      final Map<dynamic, dynamic> rawMap = <dynamic, dynamic>{
        'data': <dynamic, dynamic>{
          'items': <dynamic>[
            <dynamic, dynamic>{'id': 1},
            <dynamic, dynamic>{'id': 2},
          ],
        },
      };
      final Map<String, dynamic> result =
          MapConverter.convertToStringKeyedMap(rawMap);
      final Map<String, dynamic> data =
          result['data'] as Map<String, dynamic>;
      final List<dynamic> items = data['items'] as List<dynamic>;
      expect((items[0] as Map<String, dynamic>)['id'], equals(1));
      expect((items[1] as Map<String, dynamic>)['id'], equals(2));
    });
  });
}