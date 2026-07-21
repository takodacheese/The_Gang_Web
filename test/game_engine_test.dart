// Smoke test for the LAN port: chip-turn order, claim locking and phase
// advancement used to be verified implicitly by hitting a real Supabase
// instance. This exercises the same rules against the in-memory GameEngine.
import 'package:flutter_test/flutter_test.dart';
import 'package:the_gang/lan/game_engine.dart';
import 'package:the_gang/model.dart';

void main() {
  // Board: 9s 9h 5d 6c 2h used by the mission-rule tests below.
  // 9d 5c -> full house 999 55. Kd Kc -> two pair KK 99. 6d 7c -> two pair 99 66.
  // Qd 3c -> pair of 9s, Q kicker.
  const board = ['9s', '9h', '5d', '6c', '2h'];
  PlayerModel player(String id, List<String> hand, int riverChip) =>
      PlayerModel(id: id, userId: id, displayName: id, hand: hand, claimRiver: riverChip);

  test('mission: highest red chip on the strongest hand -> success, else fail', () {
    expect(
      HeistEvaluator.checkMissionSuccess(
          [player('fullHouse', ['9d', '5c'], 2), player('twoPair', ['6d', 'Kd'], 1)], board),
      isTrue,
    );
    expect(
      HeistEvaluator.checkMissionSuccess(
          [player('fullHouse', ['9d', '5c'], 1), player('twoPair', ['6d', 'Kd'], 2)], board),
      isFalse,
    );
  });

  test('mission checks ONLY the highest red chip — other chips may be "wrong"', () {
    // strongest holds 3★; the two weaker players have swapped chips -> still success.
    expect(
      HeistEvaluator.checkMissionSuccess([
        player('strong', ['9d', '5c'], 3), // full house
        player('mid', ['6d', 'Kd'], 1), // two pair (strict order would demand 2★)
        player('weak', ['Qd', '3c'], 2), // pair (strict order would demand 1★)
      ], board),
      isTrue,
    );
  });

  test('user scenario: both two pair, higher two pair holds the top chip', () {
    // A: KK 99 beats B: 99 66.
    expect(
      HeistEvaluator.checkMissionSuccess(
          [player('A', ['Kd', 'Kc'], 2), player('B', ['6d', '7c'], 1)], board),
      isTrue,
    );
    expect(
      HeistEvaluator.checkMissionSuccess(
          [player('A', ['Kd', 'Kc'], 1), player('B', ['6d', '7c'], 2)], board),
      isFalse,
    );
  });

  test('Retina Scan is an AND condition: wrong or missing guess fails the heist', () {
    // Correct chips: full house (hand 9d 5c) holds the top chip.
    final ps = [player('fullHouse', ['9d', '5c'], 2), player('twoPair', ['6d', 'Kd'], 1)];
    // Correct guess ('9' is in the target's hand) -> success.
    expect(
      HeistEvaluator.checkMissionSuccessAdvanced(ps, board, challengeActive: 4, retinaGuessRank: '9'),
      isTrue,
    );
    // Wrong guess -> fail even though the chips were right.
    expect(
      HeistEvaluator.checkMissionSuccessAdvanced(ps, board, challengeActive: 4, retinaGuessRank: 'K'),
      isFalse,
    );
    // No guess recorded at all -> fail (the guess is mandatory).
    expect(
      HeistEvaluator.checkMissionSuccessAdvanced(ps, board, challengeActive: 4),
      isFalse,
    );
  });

  test('tie for strongest: either player may hold the top chip', () {
    // The board itself is a royal flush — everyone plays the board, all tie.
    const royalBoard = ['As', 'Ks', 'Qs', 'Js', 'Ts'];
    expect(
      HeistEvaluator.checkMissionSuccess(
          [player('A', ['2d', '3c'], 2), player('B', ['4d', '5c'], 1)], royalBoard),
      isTrue,
    );
    expect(
      HeistEvaluator.checkMissionSuccess(
          [player('A', ['2d', '3c'], 1), player('B', ['4d', '5c'], 2)], royalBoard),
      isTrue,
    );
  });

  test('deal -> take chips in turn order -> auto-advance to FLOP', () {
    final engine = GameEngine(hostUserId: 'host', advancedMode: false, roomCode: '1234');
    engine.upsertPlayer('host', 'Host');
    engine.upsertPlayer('guest', 'Guest');
    engine.dealInitialCards();

    expect(engine.game['status'], 'PRE_FLOP');
    // Guests are seated before the host, so the guest picks first.
    final firstTurn = engine.game['current_turn_user_id'];
    expect(firstTurn, 'guest');

    // Wrong-turn player is rejected.
    engine.takeChip('host', 1, 'PRE_FLOP');
    expect(engine.players.firstWhere((p) => p['user_id'] == 'host')['claim_preflop'], isNull);

    engine.takeChip('guest', 1, 'PRE_FLOP');
    expect(engine.players.firstWhere((p) => p['user_id'] == 'guest')['claim_preflop'], 1);
    expect(engine.game['current_turn_user_id'], 'host');

    // Rank already taken is rejected.
    engine.takeChip('host', 1, 'PRE_FLOP');
    expect(engine.players.firstWhere((p) => p['user_id'] == 'host')['claim_preflop'], isNull);

    engine.takeChip('host', 2, 'PRE_FLOP');
    expect(engine.players.firstWhere((p) => p['user_id'] == 'host')['claim_preflop'], 2);

    // Everyone has claimed PRE_FLOP -> auto-advance to FLOP, first picker resets.
    expect(engine.game['status'], 'FLOP');
    expect(engine.game['current_turn_user_id'], 'guest');
  });

  test('steal moves the chip and locks out the victim from re-claiming', () {
    final engine = GameEngine(hostUserId: 'host', advancedMode: false, roomCode: '5678');
    engine.upsertPlayer('host', 'Host');
    engine.upsertPlayer('guest', 'Guest');
    engine.dealInitialCards();

    engine.takeChip('guest', 1, 'PRE_FLOP');
    // It's host's turn; host steals guest's chip instead of taking a fresh one.
    engine.stealChip(actingUserId: 'host', rank: 1, phase: 'PRE_FLOP', victimUserId: 'guest');

    expect(engine.players.firstWhere((p) => p['user_id'] == 'guest')['claim_preflop'], isNull);
    expect(engine.players.firstWhere((p) => p['user_id'] == 'host')['claim_preflop'], 1);
  });

  test('steal victim does not cut back in line — waits for their seat to come around again', () {
    final engine = GameEngine(hostUserId: 'host', advancedMode: false, roomCode: '9012');
    engine.upsertPlayer('host', 'Host');
    engine.upsertPlayer('p1', 'P1');
    engine.upsertPlayer('p2', 'P2');
    engine.dealInitialCards();

    // Seat order is p1 -> p2 -> host -> wrap (host seated last).
    expect(engine.game['current_turn_user_id'], 'p1');

    engine.takeChip('p1', 1, 'PRE_FLOP');
    expect(engine.game['current_turn_user_id'], 'p2');

    // p2 steals p1's chip instead of taking a fresh one from the center.
    engine.stealChip(actingUserId: 'p2', rank: 1, phase: 'PRE_FLOP', victimUserId: 'p1');
    expect(engine.players.firstWhere((p) => p['user_id'] == 'p1')['claim_preflop'], isNull);
    // p1 just lost their chip but must NOT be given the next turn — host is next in seat order.
    expect(engine.game['current_turn_user_id'], 'host');

    engine.takeChip('host', 2, 'PRE_FLOP');
    // Full lap done (p1 -> p2 -> host); p1 is chipless again so the wrap gives them the turn.
    expect(engine.game['current_turn_user_id'], 'p1');

    engine.takeChip('p1', 3, 'PRE_FLOP');
    // Everyone holds a chip now -> auto-advance to FLOP.
    expect(engine.game['status'], 'FLOP');
  });

  test('a started game does not seat new players (reconnect still allowed)', () {
    final engine = GameEngine(hostUserId: 'h1', advancedMode: false, roomCode: '1111');
    engine.upsertPlayer('h1', 'Host');
    engine.upsertPlayer('g1', 'Guest');
    engine.dealInitialCards();
    expect(engine.game['status'], 'PRE_FLOP');

    engine.upsertPlayer('late', 'Latecomer');
    expect(engine.players.any((p) => p['user_id'] == 'late'), isFalse);

    engine.upsertPlayer('g1', 'Guest2');
    expect(engine.players.firstWhere((p) => p['user_id'] == 'g1')['display_name'], 'Guest2');
  });

  test('custom mode queues exactly the forced cards after a verdict', () {
    final engine = GameEngine(
      hostUserId: 'h1',
      advancedMode: true,
      roomCode: '2222',
      forcedChallenge: 5,
      forcedSpecialist: 7,
    );
    engine.upsertPlayer('h1', 'Host');
    engine.upsertPlayer('g1', 'Guest');
    engine.dealInitialCards();

    // Forced cards are active from the very first heist.
    expect(engine.game['challenge_active'], 5);
    expect(engine.game['specialist_active'], 7);

    // Play every street: whoever's turn it is takes the lowest free chip.
    while (engine.game['status'] != 'SHOWDOWN') {
      final phase = engine.game['status'] as String;
      final turn = engine.game['current_turn_user_id'] as String;
      final col = {
        'PRE_FLOP': 'claim_preflop',
        'FLOP': 'claim_flop',
        'TURN': 'claim_turn',
        'RIVER': 'claim_river',
      }[phase]!;
      final taken = engine.players.map((p) => p[col]).whereType<int>().toSet();
      final rank = [1, 2].firstWhere((r) => !taken.contains(r));
      engine.takeChip(turn, rank, phase);
    }

    engine.triggerVerdict();
    expect(engine.game['status'], 'VERDICT');
    // Both forced cards re-queue for the next heist regardless of outcome.
    expect(engine.game['challenge_queued'], 5);
    expect(engine.game['specialist_queued'], 7);
  });

  test('disconnect lifecycle: lobby frees the seat, mid-game marks offline, rejoin restores, kick redeals', () {
    final engine = GameEngine(hostUserId: 'h1', advancedMode: false, roomCode: '7788');
    engine.upsertPlayer('h1', 'Host');
    engine.upsertPlayer('g1', 'G1');
    engine.upsertPlayer('g2', 'G2');

    // Lobby drop: seat freed entirely.
    engine.playerDropped('g2');
    expect(engine.players.length, 2);

    engine.dealInitialCards();
    final handBefore = List<String>.from(
        engine.players.firstWhere((p) => p['user_id'] == 'g1')['hand_cards'] as List);

    // Mid-game drop: seat kept, marked offline.
    engine.playerDropped('g1');
    final g1 = engine.players.firstWhere((p) => p['user_id'] == 'g1');
    expect(g1['connected'], isFalse);
    expect(engine.players.length, 2);

    // Rejoin with the same identity: reconnected, hand untouched.
    engine.upsertPlayer('g1', 'G1');
    expect(g1['connected'], isTrue);
    expect(List<String>.from(g1['hand_cards'] as List), handBefore);

    // Kick: non-host rejected; host kick removes + redeals for the rest.
    engine.playerDropped('g1');
    engine.kickPlayer('g1', 'h1');
    expect(engine.players.length, 2); // guests cannot kick
    engine.kickPlayer('h1', 'g1');
    expect(engine.players.any((p) => p['user_id'] == 'g1'), isFalse);
    expect(engine.game['status'], 'PRE_FLOP'); // heist redealt
    expect(
        (engine.players.single['hand_cards'] as List).length, 2); // fresh hand for the remaining player
  });

  test('specialist vote: group agrees who becomes the Muscle', () {
    final engine = GameEngine(
        hostUserId: 'h1', advancedMode: true, roomCode: '4242', forcedSpecialist: 10);
    engine.upsertPlayer('h1', 'Host');
    engine.upsertPlayer('g1', 'Guest');
    engine.dealInitialCards();

    final vote = engine.game['vote'] as Map;
    expect(vote['kind'], 'choose_player');
    expect(List.from(vote['options']), containsAll(['h1', 'g1']));

    // Disagreement keeps confirm locked (confirm is a no-op).
    engine.castVote('h1', 'g1');
    engine.castVote('g1', 'h1');
    engine.confirmVote('h1');
    expect(List.from((engine.game['vote'] as Map)['confirms']), isEmpty);

    // Agreement + both confirms -> specialist applied, vote cleared.
    engine.castVote('g1', 'g1');
    engine.confirmVote('h1');
    engine.confirmVote('g1');
    expect(engine.game['vote'], isNull);
    expect((engine.game['advanced_aux'] as Map)['muscle_user_id'], 'g1');
    expect((engine.game['emotes'] as Map)['g1'], isNotNull);
  });

  test('Retina Scan: showdown auto-starts the guess vote; completion resolves', () {
    final engine = GameEngine(
        hostUserId: 'h1', advancedMode: true, roomCode: '5353', forcedChallenge: 4);
    engine.upsertPlayer('h1', 'Host');
    engine.upsertPlayer('g1', 'Guest');
    engine.dealInitialCards();

    while (engine.game['status'] != 'SHOWDOWN') {
      final phase = engine.game['status'] as String;
      final turn = engine.game['current_turn_user_id'] as String;
      final col = {
        'PRE_FLOP': 'claim_preflop',
        'FLOP': 'claim_flop',
        'TURN': 'claim_turn',
        'RIVER': 'claim_river',
      }[phase]!;
      final taken = engine.players.map((p) => p[col]).whereType<int>().toSet();
      final rank = [1, 2].firstWhere((r) => !taken.contains(r));
      engine.takeChip(turn, rank, phase);
    }

    final vote = engine.game['vote'] as Map;
    expect(vote['kind'], 'retina');
    final voters = List<String>.from(vote['voters']);
    expect(voters, hasLength(1)); // the highest-red-chip holder cannot vote

    engine.castVote(voters.first, 'A');
    engine.confirmVote(voters.first);
    // Vote completion records the guess and resolves straight to the verdict.
    expect(engine.game['status'], 'VERDICT');
    expect((engine.game['advanced_aux'] as Map)['retina_rank'], 'A');
  });

  test('7 players get 7 chip ranks in the center', () {
    final engine = GameEngine(hostUserId: 'host', advancedMode: false, roomCode: '3456');
    engine.upsertPlayer('host', 'Host');
    for (var i = 1; i <= 6; i++) {
      engine.upsertPlayer('p$i', 'P$i');
    }
    engine.dealInitialCards();

    expect(engine.players.length, 7);
    for (var rank = 1; rank <= 7; rank++) {
      final userId = engine.game['current_turn_user_id'] as String;
      engine.takeChip(userId, rank, 'PRE_FLOP');
    }
    expect(engine.game['status'], 'FLOP');
  });
}
