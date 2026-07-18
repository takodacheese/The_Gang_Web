/// Rulebook titles + stack helpers for Advanced Mode (effects phased in later).
class AdvancedCards {
  AdvancedCards._();

  static List<int> defaultOrder() => List.generate(10, (i) => i + 1);

  static List<int> parseStack(dynamic raw) {
    if (raw == null) return defaultOrder();
    if (raw is List) {
      final list = raw.map((e) => (e as num).toInt()).where((n) => n >= 1 && n <= 10).toList();
      return list.isEmpty ? defaultOrder() : list;
    }
    return defaultOrder();
  }

  /// Draw top card for the next heist; stack loses front element until card is returned after that heist.
  static int? shiftFront(List<int> stack) {
    if (stack.isEmpty) return null;
    return stack.removeAt(0);
  }

  static String challengeTitle(int id) {
    const m = {
      1: 'Quick Access',
      2: 'Noise Sensors',
      3: 'Motion Detector',
      4: 'Retina Scan',
      5: 'Hasty Getaway',
      6: 'Ventilation Shaft',
      7: 'Laser Tripwires',
      8: 'Blackout',
      9: 'Fingerprint Scan',
      10: 'Security Cameras',
    };
    return m[id] ?? 'Challenge #$id';
  }

  static String specialistTitle(int id) {
    const m = {
      1: 'Informant',
      2: 'Getaway Driver',
      3: 'Investor',
      4: 'Mastermind',
      5: 'Hacker',
      6: 'Coordinator',
      7: 'Jack',
      8: 'Math Whiz',
      9: 'Con Artist',
      10: 'Muscle',
    };
    return m[id] ?? 'Specialist #$id';
  }

  /// Condensed rulebook text (README has the full wording).
  static String challengeRule(int id) {
    const m = {
      1: 'No white chips this heist — deal pocket cards, then go straight to Round 2.',
      2: 'The 1-star chips of Rounds 1–3 turn to the dark side: once taken they cannot change owners.',
      3: 'If any flop card is J/Q/K, the holder of the white 1-star chip discards their pocket cards and draws new ones.',
      4: 'Before the showdown reveal, the others must agree on a card value the highest-red-chip player holds. Wrong guess = heist fails.',
      5: 'No orange chips — reveal the 4th community card and go straight to Round 4.',
      6: 'The highest-value chips of Rounds 1–3 turn to the dark side: once taken they cannot change owners.',
      7: 'If no flop card is J/Q/K, the holder of the highest white chip discards their pocket cards and draws new ones.',
      8: 'At the start of each new round, everyone discards their previous round\'s chips — remember who had what.',
      9: 'Before the showdown reveal, the others must agree on the highest-red-chip player\'s hand ranking. Wrong guess = heist fails.',
      10: 'Everyone plays with three pocket cards and builds the best five-card hand from all eight.',
    };
    return m[id] ?? '';
  }

  static String specialistRule(int id) {
    const m = {
      1: 'One chosen player secretly shows exactly one pocket card to one other player.',
      2: 'One chosen player announces their current hand ranking — no further details.',
      3: 'After the deal, everyone says how many face cards (J/Q/K) they hold.',
      4: 'One chosen player says how many cards of one agreed value they hold.',
      5: 'One chosen player draws a card from the deck, then discards one pocket card.',
      6: 'After the deal, everyone passes one pocket card to the player on their left.',
      7: 'One chosen player adds the wildcard Jack (counts as a J, no suit/flush) and discards a card.',
      8: 'After the deal, everyone announces the total value of their pocket cards (J/Q/K = 10, A = 11).',
      9: 'After everyone has looked at their cards, all pockets are shuffled together and redealt.',
      10: 'The chosen player wins ties — their hand beats any other hand of the same ranking.',
    };
    return m[id] ?? '';
  }
}
