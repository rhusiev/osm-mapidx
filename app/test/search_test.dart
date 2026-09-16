/// The Dart port against the real index, checked to agree with the Python one.
///
/// Skipped where `out/lviv-search.sqlite` has not been built.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mapidx/src/ratio.dart';
import 'package:mapidx/src/search.dart';
import 'package:mapidx/src/text.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('folds the way the index was built', () {
    expect(words('Київ'), ['киів']);
    expect(words('Медовий двір'), ['медовии', 'двір']);
  });

  test('scores like difflib', () {
    expect(ratio('двир', 'двір'), closeTo(0.75, 0.001));
    expect(ratio('медовы', 'медовии'), closeTo(0.769, 0.001));
    expect(ratio('славское', 'славсько'), closeTo(0.875, 0.001));
  });

  final file = File('../out/lviv-search.sqlite');
  group('against the built index', () {
    late Database db;
    setUpAll(() => db = sqlite3.open(file.path, mode: OpenMode.readOnly));
    tearDownAll(() => db.close());

    void finds(String query, String name) {
      test(query, () {
        final hits = search(db, query, limit: 5);
        expect(hits, isNotEmpty, reason: 'no hits for "$query"');
        expect(hits.first.name, name);
      });
    }

    finds('медовий двір', 'Медовий двір');
    finds('медовы двир славско', 'Медовий двір');
    finds('medovy dvir slavsko', 'Медовий двір');
    finds('medovy dwir slavsko', 'Медовий двір');
    finds('медовый двор славское', 'Медовий двір');
    finds('ustyianovychiv medovyi', 'Медовий двір');

    test('areas outrank POIs that only share a prefix', () {
      final hits = search(db, 'Славсько', limit: 5);
      expect(hits, isNotEmpty);
      expect(hits.first.isArea, isTrue);
      expect(hits.first.name, 'Славсько');
    });

    test('exact matches outrank prefix matches in POI names', () {
      final hits = search(db, 'Славсько', limit: 30);
      final prefixOnly = hits.where((h) => h.exactCount == 0);
      expect(prefixOnly, isNotEmpty,
          reason: 'expected POIs that only mention Славсько in context');
      expect(hits.first.exactCount, greaterThan(0));
    });

    test('sorts by distance when told where it is', () {
      final hits = search(db, 'аптека', limit: 5, origin: (49.84, 24.03));
      expect(hits, isNotEmpty);
      expect(hits.first.metres, lessThan(20000));
    });
  }, skip: file.existsSync() ? false : 'no index at ${file.path}');
}
