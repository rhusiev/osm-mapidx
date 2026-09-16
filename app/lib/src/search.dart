/// The same two passes as `mapidx/search.py`, against the same file.
///
/// Each typed word is resolved against the 114k indexed words - by prefix, and
/// if that looks thin, through the trigram index over those same words - and
/// walking the postings of what it resolved to hands every place its per-word
/// scores. Only when that leaves too few hits are places read in full, best
/// agreement first, which is the case a word is misspelled past anything the
/// vocabulary could match: "двир" shares no trigram with "двір".
///
/// Nothing intersects. A word resolving to real but wrong places would
/// otherwise veto a place every other word agrees on.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import 'ratio.dart';
import 'text.dart';

const minWordScore = 0.6;
const _maxLengthGap = 3;

const _maxVocabWords = 500;
const _maxRefs = 20000;
const _maxIncomplete = 400;

/// Under this many places a prefix match is too thin to trust on its own, so
/// the word is also resolved as a possible misspelling.
const _minConfidentPlaces = 50;

/// Below this length a word has no trigram left once a letter in the middle is
/// wrong, so the trigram index has nothing to find and is not asked.
const _minFuzzyWord = 6;

const _probeTrim = 2;
const _minProbe = 3;

/// A word matched in the place's own name outranks the same word matched in
/// its context: everyone types the name, the context only narrows it.
const _contextPenalty = 0.01;

const _earthRadiusM = 6371000.0;

/// The end of the Unicode range, so `word < prefix + _lastChar` is every
/// extension of the prefix and nothing else.
const _lastChar = '￿';

class Hit {
  const Hit({
    required this.name,
    required this.address,
    required this.matched,
    required this.lon,
    required this.lat,
    required this.score,
    required this.exactCount,
    required this.isArea,
    this.metres,
  });

  /// The place's name alone, without the comma-separated context after it.
  final String name;

  /// The context inside the brackets, split on commas: village, street,
  /// hromada, raion - whatever the place has.
  final List<String> address;

  /// One entry per query word: the typed word and the score it got at this
  /// place. Words that resolved straight from the vocab score 1.0; a word that
  /// had to be judged by reading the place scores whatever `_wordScore` gave.
  final List<MatchedWord> matched;

  final double lon;
  final double lat;
  final double score;

  /// Number of query words that hit this place as the exact same indexed word
  /// in its own name. Places with non-zero counts rank above POIs whose
  /// names only start with the same prefix, and the main list shows them on
  /// their own while prefix-only matches wait behind the long press.
  final int exactCount;

  /// True for cities, towns, villages, suburbs and administrative boundaries;
  /// false for shops, hotels, bus stops and the rest. exactCount ties all
  /// "Львів" hits at 1, so the city itself only stays at the top when areas
  /// outrank POIs in the sort.
  final bool isArea;

  final double? metres;
}

class MatchedWord {
  const MatchedWord(this.word, this.score);

  final String word;
  final double score;
}

double _similarity(String word, String candidate) {
  if (candidate.startsWith(word)) return 1;
  if (candidate.contains(word)) return 0.9;
  if ((word.length - candidate.length).abs() > _maxLengthGap) return 0;
  return ratio(word, candidate);
}

double _wordScore(String word, List<String> haystack) {
  final first = word.isEmpty ? '' : word[0];
  var best = 0.0;
  for (final candidate in haystack) {
    // A word misspelled from its first letter is past saving here anyway, and
    // skipping those is what keeps this loop off the edit distance.
    if (!candidate.startsWith(first)) continue;
    final score = _similarity(word, candidate);
    if (score > best) best = score;
    if (best == 1) break;
  }
  return best;
}

class _Resolved {
  const _Resolved(this.words, this.scores, this.exacts, this.namesOnly);

  final List<String> words;
  final List<double> scores;

  /// True only when the typed word equals the indexed word - "Славсько"
  /// matching the word "Славсько", not just any word starting with "Славсько".
  /// That distinction is what lets a single-word area query rank the area
  /// itself above every POI whose name contains a longer word starting with
  /// the same prefix.
  final List<bool> exacts;

  /// The prefix matched so much of the oblast that only names are worth
  /// walking: "гро" says nothing about which громада is meant.
  final bool namesOnly;
}

_Resolved _resolve(Database db, String word) {
  final sized = db.select(
    'SELECT word, places FROM vocab WHERE word >= ? AND word < ? '
    'ORDER BY length(word) LIMIT ?',
    [word, word + _lastChar, _maxVocabWords],
  );

  final matched = <String>[];
  final scores = <double>[];
  final exacts = <bool>[];
  var places = 0;
  for (final row in sized) {
    places += row['places'] as int;
    if (places > _maxRefs) return _Resolved(matched, scores, exacts, true);
    final candidate = row['word'] as String;
    matched.add(candidate);
    scores.add(1);
    exacts.add(candidate == word);
  }

  if (places < _minConfidentPlaces && word.length >= _minFuzzyWord) {
    final probe = word.substring(0, math.max(_minProbe, word.length - _probeTrim));
    final known = matched.toSet();
    for (final row in db.select(
        'SELECT word FROM vocab_fuzzy WHERE word LIKE ?', ['%$probe%'])) {
      final candidate = row['word'] as String;
      final score = _similarity(word, candidate);
      if (score >= minWordScore && !known.contains(candidate)) {
        matched.add(candidate);
        scores.add(score);
        exacts.add(false);
      }
    }
  }
  return _Resolved(matched, scores, exacts, false);
}

List<int> _postings(Uint8List blob) {
  final refs = <int>[];
  var ref = 0, shift = 0, delta = 0;
  for (final byte in blob) {
    delta |= (byte & 0x7f) << shift;
    if (byte & 0x80 != 0) {
      shift += 7;
      continue;
    }
    ref += delta;
    refs.add(ref);
    shift = 0;
    delta = 0;
  }
  return refs;
}

/// Every place some typed word resolves to, with that word's best score, and
/// per-word per-place whether that match was an exact word in the place's own
/// name. The second return value is what ranks an area above POIs whose
/// names only start with the same prefix.
({Map<int, List<double>> scores, Map<int, List<bool>> exacts}) _tally(
    Database db, List<String> queryWords) {
  final scores = <int, List<double>>{};
  final exacts = <int, List<bool>>{};
  final byWord = db.prepare('SELECT postings FROM vocab WHERE word = ?');
  try {
    for (var index = 0; index < queryWords.length; index++) {
      final resolved = _resolve(db, queryWords[index]);
      var walked = 0;
      for (var n = 0; n < resolved.words.length; n++) {
        final blob = byWord.select([resolved.words[n]]).first['postings'] as Uint8List;
        final score = resolved.scores[n];
        final isExact = resolved.exacts[n];
        for (final ref in _postings(blob)) {
          final named = ref & 1 != 0;
          if (resolved.namesOnly && !named) continue;
          final here = named ? score : score - _contextPenalty;
          final placeScores = scores.putIfAbsent(
              ref >> 1, () => List<double>.filled(queryWords.length, 0));
          final placeExact = exacts.putIfAbsent(
              ref >> 1, () => List<bool>.filled(queryWords.length, false));
          if (here > placeScores[index]) {
            placeScores[index] = here;
            placeExact[index] = named && isExact;
          }
        }
        walked += blob.length;
        if (walked > _maxRefs) break;
      }
    }
  } finally {
    byWord.close();
  }
  return (scores: scores, exacts: exacts);
}

/// Judge the words no indexed word resolved to, by reading the places.
List<MapEntry<int, List<double>>> _complete(
    Database db,
    List<MapEntry<int, List<double>>> partial,
    List<String> queryWords,
    double threshold) {
  partial.sort((a, b) => _sum(b.value).compareTo(_sum(a.value)));
  if (partial.length > _maxIncomplete) partial.length = _maxIncomplete;
  if (partial.isEmpty) return const [];

  final marks = List.filled(partial.length, '?').join(',');
  final terms = <int, String>{};
  for (final row in db.select(
      "SELECT rowid, name_terms || ' ' || context_terms AS terms FROM places "
      'WHERE rowid IN ($marks)',
      partial.map((hit) => hit.key).toList())) {
    terms[row['rowid'] as int] = row['terms'] as String;
  }

  final filled = <MapEntry<int, List<double>>>[];
  for (final hit in partial) {
    final haystack = terms[hit.key]!.split(' ');
    final scores = hit.value;
    for (var index = 0; index < scores.length; index++) {
      if (scores[index] < threshold) {
        scores[index] = _wordScore(queryWords[index], haystack);
      }
    }
    if (scores.every((score) => score >= threshold)) filled.add(hit);
  }
  return filled;
}

double _sum(List<double> scores) => scores.fold(0, (a, b) => a + b);

double _distanceM(double lat1, double lon1, double lat2, double lon2) {
  final meanLat = (lat1 + lat2) / 2 * math.pi / 180;
  final dx = (lon2 - lon1) * math.pi / 180 * math.cos(meanLat);
  final dy = (lat2 - lat1) * math.pi / 180;
  return math.sqrt(dx * dx + dy * dy) * _earthRadiusM;
}

List<Hit> search(Database db, String query,
    {int limit = 20,
    double threshold = minWordScore,
    (double, double)? origin}) {
  final queryWords = words(query);
  if (queryWords.isEmpty) return const [];

  final tally = _tally(db, queryWords);
  final ranked = <MapEntry<int, List<double>>>[];
  final partial = <MapEntry<int, List<double>>>[];
  for (final entry in tally.scores.entries) {
    final worst = entry.value.reduce(math.min);
    if (worst >= threshold) {
      ranked.add(entry);
    } else if (entry.value.reduce(math.max) >= threshold) {
      partial.add(entry);
    }
  }
  // Every word agreeing straight from the index is the common case and costs
  // nothing. Reading places is only worth it when that came up short.
  if (ranked.length < limit) {
    ranked.addAll(_complete(db, partial, queryWords, threshold));
  }
  if (ranked.isEmpty) return const [];

  final scored = {
    for (final place in ranked) place.key: _sum(place.value) / place.value.length,
  };
  // Distance can only reorder hits that already scored equally, so it is
  // enough to fetch a few times the asked-for number and sort those.
  final best = scored.keys.toList()
    ..sort((a, b) => scored[b]!.compareTo(scored[a]!));
  if (best.length > limit * 10) best.length = limit * 10;

  final marks = List.filled(best.length, '?').join(',');
  final rankedMap = {for (final entry in ranked) entry.key: entry.value};
  final hits = db
      .select('SELECT rowid, display_name, lon, lat, category FROM places '
          'WHERE rowid IN ($marks)', best)
      .map((row) {
        final lat = row['lat'] as double;
        final lon = row['lon'] as double;
        final place = row['rowid'] as int;
        final scores = rankedMap[place]!;
        final display = row['display_name'] as String;
        final bracket = display.indexOf(' (');
        final name = bracket < 0 ? display : display.substring(0, bracket);
        final address = bracket < 0
            ? const <String>[]
            : display
                .substring(bracket + 2, display.length - 1)
                .split(',')
                .map((part) => part.trim())
                .where((part) => part.isNotEmpty)
                .toList();
        final exacts = tally.exacts[place] ?? List<bool>.filled(queryWords.length, false);
        final category = row['category'] as String;
        return Hit(
          name: name,
          address: address,
          matched: [
            for (var i = 0; i < queryWords.length; i++)
              MatchedWord(queryWords[i], scores[i]),
          ],
          lon: lon,
          lat: lat,
          score: scored[place]!,
          exactCount: exacts.where((e) => e).length,
          isArea: category.startsWith('place=') ||
              category.startsWith('boundary=administrative'),
          metres: origin == null
              ? null
              : _distanceM(origin.$1, origin.$2, lat, lon),
        );
      })
      .toList()
    ..sort((a, b) {
      // Areas matched exactly outrank prefix-only matches in POI names, so a
      // single-word query for a town shows the town first and tucks the POIs
      // behind the long press.
      final byExact = b.exactCount.compareTo(a.exactCount);
      if (byExact != 0) return byExact;
      // exactCount ties "Львів" between the city and thousands of streets /
      // shops / bus stops that mention the name; the city stays on top only
      // if areas outrank POIs here.
      final byArea = (b.isArea ? 1 : 0).compareTo(a.isArea ? 1 : 0);
      if (byArea != 0) return byArea;
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      final byDistance = (a.metres ?? 0).compareTo(b.metres ?? 0);
      return byDistance != 0 ? byDistance : a.name.compareTo(b.name);
    });
  return hits.length > limit ? hits.sublist(0, limit) : hits;
}
