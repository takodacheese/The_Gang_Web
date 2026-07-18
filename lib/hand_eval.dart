/// Pure-Dart poker hand evaluator. Replaces package:poker, whose 64-bit
/// bitmask literals can't compile to JavaScript (web build).
///
/// Only what the game needs: a comparable [power] and a category [name] that
/// matches HeistEvaluator.fingerprintCategories labels.
class EvaluatedHand {
  const EvaluatedHand(this.power, this.name);

  /// Higher wins. Packs category + tiebreak ranks into a small int (< 2^24),
  /// safe for JavaScript number semantics.
  final int power;
  final String name;
}

const List<String> _categoryNames = [
  'High Card', 'Pair', 'Two Pair', 'Three of a Kind', 'Straight',
  'Flush', 'Full House', 'Four of a Kind', 'Straight Flush', 'Royal Flush',
];

const Map<String, int> _rankValues = {
  '2': 2, '3': 3, '4': 4, '5': 5, '6': 6, '7': 7, '8': 8, '9': 9,
  'T': 10, 'J': 11, 'Q': 12, 'K': 13, 'A': 14,
};

/// [cards] are normalized 2-char codes ("As", "Th"). With more than 5 cards,
/// evaluates every 5-card combination and returns the best. With fewer than 5
/// (e.g. Getaway Driver pre-flop: pocket cards only), straights/flushes are
/// impossible and it classifies on rank counts alone.
EvaluatedHand evaluateBestHand(List<String> cards) {
  if (cards.isEmpty) throw const FormatException('no cards');
  if (cards.length <= 5) return _evalFive(cards);
  EvaluatedHand? best;
  for (final combo in _combinations(cards, 5)) {
    final e = _evalFive(combo);
    if (best == null || e.power > best.power) best = e;
  }
  return best!;
}

EvaluatedHand _evalFive(List<String> cards) {
  final ranks = cards.map(_rankValue).toList()..sort((a, b) => b - a);
  final counts = <int, int>{};
  for (final r in ranks) {
    counts[r] = (counts[r] ?? 0) + 1;
  }
  // Rank groups ordered by count desc, then rank desc — this order doubles as
  // the tiebreak vector for all count-based categories.
  final groups = counts.entries.toList()
    ..sort((a, b) => a.value != b.value ? b.value - a.value : b.key - a.key);

  final isFlush = cards.length == 5 && cards.map((c) => c[1]).toSet().length == 1;
  final straightHigh = cards.length == 5 ? _straightHigh(counts.keys.toList()) : null;

  int category;
  List<int> tie;
  if (isFlush && straightHigh != null) {
    category = straightHigh == 14 ? 9 : 8;
    tie = [straightHigh];
  } else if (groups[0].value == 4) {
    category = 7;
    tie = [groups[0].key, if (groups.length > 1) groups[1].key];
  } else if (groups[0].value == 3 && groups.length > 1 && groups[1].value >= 2) {
    category = 6;
    tie = [groups[0].key, groups[1].key];
  } else if (isFlush) {
    category = 5;
    tie = ranks;
  } else if (straightHigh != null) {
    category = 4;
    tie = [straightHigh];
  } else if (groups[0].value == 3) {
    category = 3;
    tie = groups.map((g) => g.key).toList();
  } else if (groups[0].value == 2 && groups.length > 1 && groups[1].value == 2) {
    category = 2;
    tie = groups.map((g) => g.key).toList();
  } else if (groups[0].value == 2) {
    category = 1;
    tie = groups.map((g) => g.key).toList();
  } else {
    category = 0;
    tie = ranks;
  }

  // category (4 bits) + five 4-bit tiebreak ranks, most significant first.
  var power = category;
  for (var i = 0; i < 5; i++) {
    power = (power << 4) | (i < tie.length ? tie[i] & 0xF : 0);
  }
  return EvaluatedHand(power, _categoryNames[category]);
}

/// Highest card of a 5-card straight, or null. A-2-3-4-5 (wheel) counts with
/// high card 5.
int? _straightHigh(List<int> distinctRanks) {
  if (distinctRanks.length != 5) return null;
  final sorted = distinctRanks.toList()..sort((a, b) => b - a);
  if (sorted[0] - sorted[4] == 4) return sorted[0];
  if (sorted[0] == 14 && sorted[1] == 5 && sorted[4] == 2) return 5; // wheel
  return null;
}

int _rankValue(String card) {
  final value = _rankValues[card[0].toUpperCase()];
  if (value == null) throw FormatException('Invalid card: $card');
  return value;
}

Iterable<List<String>> _combinations(List<String> pool, int k) sync* {
  if (k == 0) {
    yield [];
    return;
  }
  if (pool.length < k) return;
  for (var i = 0; i <= pool.length - k; i++) {
    for (final tail in _combinations(pool.sublist(i + 1), k - 1)) {
      yield [pool[i], ...tail];
    }
  }
}
