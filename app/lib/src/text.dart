/// Query text, folded the way the index was folded when it was built.
///
/// `mapidx/translit.py` lowercases, decomposes and drops the combining
/// marks, so "Київ" is indexed as "киів" and й, ї and ё are not held apart
/// from и, і and е. Dart has no Unicode normaliser, and it needs none: the
/// only composed letters these names use are the handful below.
library;

const _folded = {
  'й': 'и', 'ї': 'і', 'ё': 'е', 'ў': 'у',
  'á': 'a', 'à': 'a', 'ä': 'a', 'â': 'a', 'ą': 'a',
  'é': 'e', 'è': 'e', 'ë': 'e', 'ê': 'e', 'ę': 'e',
  'í': 'i', 'ì': 'i', 'ï': 'i', 'î': 'i',
  'ó': 'o', 'ò': 'o', 'ö': 'o', 'ô': 'o',
  'ú': 'u', 'ù': 'u', 'ü': 'u', 'û': 'u',
  'ç': 'c', 'ć': 'c', 'č': 'c', 'ń': 'n', 'ñ': 'n',
  'ś': 's', 'š': 's', 'ý': 'y', 'ź': 'z', 'ż': 'z', 'ž': 'z',
};

final _word = RegExp(r'[\p{L}\p{N}_]+', unicode: true);

String normalise(String text) {
  final out = StringBuffer();
  for (final ch in text.toLowerCase().split('')) {
    out.write(_folded[ch] ?? ch);
  }
  return out.toString();
}

List<String> words(String text) =>
    _word.allMatches(normalise(text)).map((match) => match[0]!).toList();
