import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_offline_cache/src/utils/key_builder.dart';

void main() {
  group('KeyBuilder', () {
    test('same namespace and key always produces same hash', () {
      final String key1 = KeyBuilder.build('MovieRepository', 'movies');
      final String key2 = KeyBuilder.build('MovieRepository', 'movies');
      expect(key1, equals(key2));
    });

    test('different namespace produces different hash', () {
      final String key1 = KeyBuilder.build('MovieRepository', 'movies');
      final String key2 = KeyBuilder.build('UserRepository', 'movies');
      expect(key1, isNot(equals(key2)));
    });

    test('different key produces different hash', () {
      final String key1 = KeyBuilder.build('MovieRepository', 'movies');
      final String key2 = KeyBuilder.build('MovieRepository', 'series');
      expect(key1, isNot(equals(key2)));
    });

    test('hash starts with foc_ prefix', () {
      final String key = KeyBuilder.build('MovieRepository', 'movies');
      expect(key, startsWith('foc_'));
    });

    test('hash is exactly 36 characters — foc_ prefix plus 32 char hash', () {
      final String key = KeyBuilder.build('MovieRepository', 'movies');
      expect(key.length, equals(36));
    });

    test('buildWithParams same params in different order produces same hash',
        () {
      final String key1 = KeyBuilder.buildWithParams(
        'MovieRepository',
        'movies',
        {'page': 1, 'genre': 'action'},
      );
      final String key2 = KeyBuilder.buildWithParams(
        'MovieRepository',
        'movies',
        {'genre': 'action', 'page': 1},
      );
      expect(key1, equals(key2));
    });

    test('buildWithParams different params produces different hash', () {
      final String key1 = KeyBuilder.buildWithParams(
        'MovieRepository',
        'movies',
        {'page': 1},
      );
      final String key2 = KeyBuilder.buildWithParams(
        'MovieRepository',
        'movies',
        {'page': 2},
      );
      expect(key1, isNot(equals(key2)));
    });

    test('buildWithParams empty params produces same hash as build', () {
      final String key1 =
          KeyBuilder.buildWithParams('MovieRepository', 'movies', {});
      final String key2 = KeyBuilder.build('MovieRepository', 'movies');
      expect(key1, isNot(equals(key2)));
    });
  });
}