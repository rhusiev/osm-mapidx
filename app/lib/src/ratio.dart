/// How alike two words are, on the same scale the build side uses.
///
/// This is Python's `difflib.SequenceMatcher(None, a, b).ratio()`, ported so
/// that a score here means what a score there means: twice the number of
/// characters in the matching blocks, over the two lengths together. Nothing
/// is treated as junk - the autojunk heuristic only starts at 200 characters,
/// and these are words.
library;

class _Match {
  const _Match(this.i, this.j, this.size);

  final int i;
  final int j;
  final int size;
}

double ratio(String a, String b) {
  final total = a.length + b.length;
  if (total == 0) return 1;

  final positions = <int, List<int>>{};
  for (var j = 0; j < b.length; j++) {
    (positions[b.codeUnitAt(j)] ??= <int>[]).add(j);
  }

  var matched = 0;
  final pending = <List<int>>[
    [0, a.length, 0, b.length],
  ];
  while (pending.isNotEmpty) {
    final block = pending.removeLast();
    final match = _longest(a, b, positions, block[0], block[1], block[2], block[3]);
    if (match.size == 0) continue;
    matched += match.size;
    if (block[0] < match.i && block[2] < match.j) {
      pending.add([block[0], match.i, block[2], match.j]);
    }
    final afterA = match.i + match.size;
    final afterB = match.j + match.size;
    if (afterA < block[1] && afterB < block[3]) {
      pending.add([afterA, block[1], afterB, block[3]]);
    }
  }
  return 2 * matched / total;
}

/// The longest run shared by `a[alo:ahi]` and `b[blo:bhi]`, earliest first.
_Match _longest(String a, String b, Map<int, List<int>> positions,
    int alo, int ahi, int blo, int bhi) {
  var besti = alo, bestj = blo, best = 0;
  // Run lengths ending at each position of b, one row of a at a time.
  var lengths = <int, int>{};
  for (var i = alo; i < ahi; i++) {
    final next = <int, int>{};
    for (final j in positions[a.codeUnitAt(i)] ?? const <int>[]) {
      if (j < blo) continue;
      if (j >= bhi) break;
      final run = (lengths[j - 1] ?? 0) + 1;
      next[j] = run;
      if (run > best) {
        besti = i - run + 1;
        bestj = j - run + 1;
        best = run;
      }
    }
    lengths = next;
  }
  return _Match(besti, bestj, best);
}
