import 'package:flutter_test/flutter_test.dart';
import 'package:the_gang/hand_eval.dart';

void main() {
  int power(List<String> cards) => evaluateBestHand(cards).power;
  String name(List<String> cards) => evaluateBestHand(cards).name;

  test('categories are named and ordered correctly', () {
    expect(name(['As', 'Ks', 'Qs', 'Js', 'Ts']), 'Royal Flush');
    expect(name(['9s', 'Ks', 'Qs', 'Js', 'Ts']), 'Straight Flush');
    expect(name(['9s', '9h', '9d', '9c', 'Ts']), 'Four of a Kind');
    expect(name(['9s', '9h', '9d', 'Tc', 'Ts']), 'Full House');
    expect(name(['2s', '5s', '9s', 'Js', 'Ts']), 'Flush');
    expect(name(['8d', '9h', 'Qs', 'Jc', 'Ts']), 'Straight');
    expect(name(['9s', '9h', '9d', 'Jc', 'Ts']), 'Three of a Kind');
    expect(name(['9s', '9h', 'Jd', 'Jc', 'Ts']), 'Two Pair');
    expect(name(['9s', '9h', '2d', 'Jc', 'Ts']), 'Pair');
    expect(name(['3s', '9h', '2d', 'Jc', 'Ts']), 'High Card');

    final ordered = [
      ['3s', '9h', '2d', 'Jc', 'Ts'], // high card
      ['9s', '9h', '2d', 'Jc', 'Ts'], // pair
      ['9s', '9h', 'Jd', 'Jc', 'Ts'], // two pair
      ['9s', '9h', '9d', 'Jc', 'Ts'], // trips
      ['8d', '9h', 'Qs', 'Jc', 'Ts'], // straight
      ['2s', '5s', '9s', 'Js', 'Ts'], // flush
      ['9s', '9h', '9d', 'Tc', 'Ts'], // full house
      ['9s', '9h', '9d', '9c', 'Ts'], // quads
      ['9s', 'Ks', 'Qs', 'Js', 'Ts'], // straight flush
      ['As', 'Ks', 'Qs', 'Js', 'Ts'], // royal flush
    ];
    for (var i = 1; i < ordered.length; i++) {
      expect(power(ordered[i]) > power(ordered[i - 1]), isTrue,
          reason: '${name(ordered[i])} must beat ${name(ordered[i - 1])}');
    }
  });

  test('tiebreaks: higher pair and kicker win', () {
    expect(power(['Ks', 'Kh', '2d', '3c', '4s']) > power(['Qs', 'Qh', 'Ad', 'Kc', 'Js']), isTrue);
    expect(power(['Ks', 'Kh', 'Ad', '3c', '4s']) > power(['Kd', 'Kc', 'Qd', 'Jc', '9s']), isTrue);
  });

  test('wheel straight (A-5) beats nothing above it and loses to 6-high', () {
    expect(name(['As', '2h', '3d', '4c', '5s']), 'Straight');
    expect(power(['2h', '3d', '4c', '5s', '6d']) > power(['As', '2h', '3d', '4c', '5s']), isTrue);
  });

  test('7-card evaluation picks the best five', () {
    // Pocket pair + board makes a full house despite junk cards present.
    expect(name(['9s', '9h', '9d', 'Tc', 'Ts', '2h', '3d']), 'Full House');
    // Board flush is found among 7 cards.
    expect(name(['2s', '5s', 'Ah', '9s', 'Js', 'Ts', 'Kd']), 'Flush');
  });

  test('fewer than 5 cards classifies on counts (pre-flop Getaway Driver)', () {
    expect(name(['9s', '9h']), 'Pair');
    expect(name(['9s', 'Kh']), 'High Card');
  });

  test('two pair tiebreaks: top pair, then low pair, then kicker', () {
    // Higher top pair beats better everything-else.
    expect(power(['Ks', 'Kh', '9d', '9c', '2s']) > power(['Qs', 'Qh', 'Jd', 'Jc', 'As']), isTrue);
    // Same top pair: higher second pair wins.
    expect(power(['Ks', 'Kh', '9d', '9c', '2s']) > power(['Kd', 'Kc', '8d', '8c', 'As']), isTrue);
    // Same pairs: kicker decides.
    expect(power(['Ks', 'Kh', '9d', '9c', 'Qs']) > power(['Kd', 'Kc', '9h', '9s', 'Js']), isTrue);
    // Identical two pair + kicker = exact tie.
    expect(power(['Ks', 'Kh', '9d', '9c', 'Qs']), power(['Kd', 'Kc', '9h', '9s', 'Qd']));
  });

  test('7 cards with three pairs: best five keeps the two highest pairs', () {
    final best = evaluateBestHand(['As', 'Ah', 'Ks', 'Kh', '9s', '9h', '2d']);
    expect(best.name, 'Two Pair');
    // AAKK+9 must beat AA99+K.
    expect(best.power > power(['Ad', 'Ac', '9d', '9c', 'Kd']), isTrue);
  });

  test('shared board: higher two pair wins the 7-card comparison', () {
    // Board 9s 9h 5d 6c 2h — KK -> KK99 beats 67 -> 99 66.
    const board = ['9s', '9h', '5d', '6c', '2h'];
    expect(power(['Kd', 'Kc', ...board]) > power(['6d', '7c', ...board]), isTrue);
    // And the full house from 9d 5c beats both.
    expect(power(['9d', '5c', ...board]) > power(['Kd', 'Kc', ...board]), isTrue);
  });

  test('straight tiebreak: higher top card wins', () {
    expect(power(['9d', 'Th', 'Js', 'Qc', 'Ks']) > power(['8d', '9h', 'Ts', 'Jc', 'Qs']), isTrue);
  });
}
