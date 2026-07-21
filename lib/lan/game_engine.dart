import 'dart:math';

import '../advanced_aux_state.dart';
import '../advanced_cards.dart';
import '../model.dart';

/// All the rules that used to live in game_screen.dart as Supabase read-then-write
/// round-trips, ported to mutate an in-memory `game` map + `players` list directly.
/// Runs only on the host device; remote players send intents that arrive here.
class GameEngine {
  GameEngine({
    required String hostUserId,
    required bool advancedMode,
    required String roomCode,
    bool randomAdvanced = false,
    int? forcedChallenge,
    int? forcedSpecialist,
  }) : game = {
          'id': 'lan-room',
          'room_code': roomCode,
          'status': 'LOBBY',
          'win_score': 0,
          'lose_score': 0,
          'community_cards': <String>[],
          'host_user_id': hostUserId,
          'advanced_mode': advancedMode,
          // Draw order variants: random shuffles the stacks; forced_* pins the
          // queued card every heist (the "custom" testing mode).
          'advanced_random': randomAdvanced,
          'forced_challenge': forcedChallenge,
          'forced_specialist': forcedSpecialist,
          'current_turn_user_id': null,
          'challenge_active': null,
          'specialist_active': null,
          // Custom/testing mode: forced cards are active from the very first
          // heist (normal games only queue cards after a verdict).
          'challenge_queued': forcedChallenge,
          'specialist_queued': forcedSpecialist,
          'challenge_stack': null,
          'specialist_stack': null,
          'advanced_aux': <String, dynamic>{},
          'deck_remaining': <String>[],
          'last_heist_success': null,
        };

  final Map<String, dynamic> game;
  final List<Map<String, dynamic>> players = [];

  static const List<String> _chipPhases = ['PRE_FLOP', 'FLOP', 'TURN', 'RIVER'];

  int _starCapForPlayerCount(int playerCount) => playerCount.clamp(1, 7);

  String _claimColumnForPhase(String phase) {
    switch (phase) {
      case 'PRE_FLOP':
        return 'claim_preflop';
      case 'FLOP':
        return 'claim_flop';
      case 'TURN':
        return 'claim_turn';
      case 'RIVER':
        return 'claim_river';
      default:
        return 'claimed_chip_rank';
    }
  }

  List<Map<String, dynamic>> get playersOrdered =>
      [...players]..sort((a, b) => ((a['seat_index'] as int?) ?? 0).compareTo((b['seat_index'] as int?) ?? 0));

  Map<String, dynamic>? _playerByUserId(String userId) {
    for (final p in players) {
      if (p['user_id'] == userId) return p;
    }
    return null;
  }

  void upsertPlayer(String userId, String displayName) {
    final existing = _playerByUserId(userId);
    if (existing != null) {
      existing['display_name'] = displayName;
      existing['connected'] = true; // rejoin after a refresh/drop
      return;
    }
    // A started game is closed: new players can only be seated in the lobby.
    if (game['status'] != 'LOBBY') return;
    players.add({
      'id': userId,
      'user_id': userId,
      'display_name': displayName,
      'hand_cards': <String>[],
      'claim_preflop': null,
      'claim_flop': null,
      'claim_turn': null,
      'claim_river': null,
      'seat_index': players.length,
      'connected': true,
    });
  }

  /// Relay-reported disconnect. In the lobby the seat is simply freed; in a
  /// running game the seat is kept (they can rejoin with the same identity)
  /// and marked offline so the host can decide to kick.
  void playerDropped(String userId) {
    final p = _playerByUserId(userId);
    if (p == null) return;
    if (game['status'] == 'LOBBY') {
      players.remove(p);
      _reindexSeats();
    } else {
      p['connected'] = false;
    }
  }

  /// Host-only. Removing a player mid-heist invalidates the deal, so the
  /// current heist is aborted and redealt for the remaining players (scores
  /// and queued cards untouched — the active cards go back to "queued").
  void kickPlayer(String actingUserId, String targetUserId) {
    if (actingUserId != game['host_user_id']) return;
    if (targetUserId == game['host_user_id']) return;
    final target = _playerByUserId(targetUserId);
    if (target == null) return;
    final status = game['status'] as String?;
    final midGame = status != 'LOBBY' && status != 'GAME_OVER';
    players.remove(target);
    _reindexSeats();
    if (midGame && players.isNotEmpty) {
      game['challenge_queued'] = game['challenge_active'] ?? game['challenge_queued'];
      game['specialist_queued'] = game['specialist_active'] ?? game['specialist_queued'];
      dealInitialCards();
    }
  }

  void _reindexSeats() {
    final sorted = playersOrdered;
    for (var i = 0; i < sorted.length; i++) {
      sorted[i]['seat_index'] = i;
    }
  }

  int _emoteSeq = 0;

  /// Speech-bubble phrase shown at [userId]'s seat on every screen. Stored per
  /// user so several bubbles can be live at once (Math Whiz shows everyone's
  /// totals simultaneously). seq lets clients re-show a repeated phrase.
  void emote(String userId, String text) {
    final emotes = Map<String, dynamic>.from(game['emotes'] as Map? ?? {});
    emotes[userId] = {'text': text, 'seq': ++_emoteSeq};
    game['emotes'] = emotes;
  }

  // ---- Group vote ("circle of choice") ----
  // One vote at a time, stored in game['vote'] so every client renders the
  // same wheel. All voters must pick the SAME option, then each taps confirm.

  static const List<String> rankOptions = ['A', '2', '3', '4', '5', '6', '7', '8', '9', '10', 'J', 'Q', 'K'];
  static const Set<int> _votedSpecialists = {1, 2, 4, 5, 7, 10};

  int _voteSeq = 0;

  void _startVote(String kind, {required List<String> options, List<String>? voters, int? specialist}) {
    game['vote'] = {
      'id': ++_voteSeq,
      'kind': kind,
      'specialist': ?specialist,
      'options': options,
      'picks': <String, dynamic>{},
      'confirms': <String>[],
      'voters': voters ?? [for (final p in playersOrdered) p['user_id'] as String],
    };
  }

  void castVote(String userId, String option) {
    final vote = game['vote'];
    if (vote is! Map) return;
    if (!List<String>.from(vote['voters'] as List? ?? []).contains(userId)) return;
    if (!List<String>.from(vote['options'] as List? ?? []).contains(option)) return;
    (vote['picks'] as Map)[userId] = option;
    vote['confirms'] = <String>[]; // any change restarts the confirmation round
  }

  void confirmVote(String userId) {
    final vote = game['vote'];
    if (vote is! Map) return;
    final voters = List<String>.from(vote['voters'] as List? ?? []);
    if (!voters.contains(userId)) return;
    final picks = vote['picks'] as Map;
    if (picks.length != voters.length) return;
    final values = picks.values.toSet();
    if (values.length != 1) return; // everyone must agree first
    final confirms = List<String>.from(vote['confirms'] as List? ?? []);
    if (confirms.contains(userId)) return;
    confirms.add(userId);
    vote['confirms'] = confirms;
    if (confirms.length == voters.length) {
      _completeVote(vote['kind'] as String, values.first as String, (vote['specialist'] as num?)?.toInt());
    }
  }

  void _completeVote(String kind, String choice, int? specialist) {
    game['vote'] = null;
    switch (kind) {
      case 'retina':
        resolveRetinaGuess(choice);
        triggerVerdict();
        break;
      case 'fingerprint':
        resolveFingerprintGuess(int.tryParse(choice) ?? -1);
        triggerVerdict();
        break;
      case 'choose_player':
        if (specialist != null) _applySpecialistTo(specialist, choice);
        break;
      case 'mastermind_rank':
        final targetId = game['mastermind_target'] as String?;
        final target = targetId == null ? null : _playerByUserId(targetId);
        if (target != null) {
          final count = List<String>.from(target['hand_cards'] as List? ?? [])
              .where((c) => _rankLabelOf(c) == choice)
              .length;
          emote(targetId!, 'I have $count × $choice');
        }
        game['mastermind_target'] = null;
        break;
    }
  }

  /// The group chose [userId] to use specialist [sid]. Interactive rulebook
  /// sub-choices are simplified to random/automatic picks (ponytail: each is
  /// one line to upgrade to a follow-up vote later).
  void _applySpecialistTo(int sid, String userId) {
    final p = _playerByUserId(userId);
    if (p == null) return;
    final hand = List<String>.from(p['hand_cards'] as List? ?? []);
    switch (sid) {
      case 1: // Informant: reveal one (random) pocket card in the bubble.
        if (hand.isNotEmpty) emote(userId, 'My card: ${hand[Random.secure().nextInt(hand.length)]}');
        break;
      case 2: // Getaway Driver: current hand ranking, nothing more.
        emote(userId, 'I have: ${HeistEvaluator.getHandName(hand, _visibleBoard())}');
        break;
      case 4: // Mastermind: follow-up vote picks the value to ask about.
        game['mastermind_target'] = userId;
        _startVote('mastermind_rank', options: rankOptions);
        break;
      case 5: // Hacker: draw one, then discard a random card.
        final deck = _parseDeckRemaining(game['deck_remaining']);
        if (deck.isNotEmpty) {
          hand.add(deck.removeLast());
          hand.removeAt(Random.secure().nextInt(hand.length));
          p['hand_cards'] = hand;
          game['deck_remaining'] = deck;
          emote(userId, 'Hacked: swapped a card');
        }
        break;
      case 7: // Jack: wildcard J replaces a random original card.
        if (hand.isNotEmpty) {
          hand.removeAt(Random.secure().nextInt(hand.length));
          hand.add('Jn');
          p['hand_cards'] = hand;
          final aux = AdvancedAuxState.decode(game['advanced_aux']);
          aux['jack_holder_uid'] = userId;
          game['advanced_aux'] = aux;
          emote(userId, 'I took the Jack');
        }
        break;
      case 10: // Muscle: wins ties in the showdown.
        final aux = AdvancedAuxState.decode(game['advanced_aux']);
        aux['muscle_user_id'] = userId;
        game['advanced_aux'] = aux;
        emote(userId, 'I am the Muscle');
        break;
    }
  }

  List<String> _visibleBoard() {
    final visible = {'PRE_FLOP': 0, 'FLOP': 3, 'TURN': 4, 'RIVER': 5, 'SHOWDOWN': 5, 'VERDICT': 5}[game['status']] ?? 0;
    final community = List<String>.from(game['community_cards'] as List? ?? []);
    return community.take(visible).toList();
  }

  static String _rankLabelOf(String card) {
    final u = card.trim().toUpperCase();
    if (u.startsWith('10') || u.startsWith('T')) return '10';
    return u.isEmpty ? '' : u[0];
  }

  static int _pocketSum(List<String> hand) {
    var sum = 0;
    for (final c in hand) {
      final r = _rankLabelOf(c);
      sum += r == 'A' ? 11 : (r == 'J' || r == 'Q' || r == 'K' || r == '10') ? 10 : (int.tryParse(r) ?? 0);
    }
    return sum;
  }

  bool _everyoneClaimedForPhase(String phase) {
    if (!_chipPhases.contains(phase)) return false;
    if (players.isEmpty) return false;
    final col = _claimColumnForPhase(phase);
    return players.every((p) => p[col] != null);
  }

  Map<String, dynamic>? _holderOfRank(String phase, int rank) {
    final col = _claimColumnForPhase(phase);
    for (final p in players) {
      if (p[col] == rank) return p;
    }
    return null;
  }

  String? _chipRoundFirstTurnUserId() {
    if (players.isEmpty) return null;
    return playersOrdered.first['user_id'] as String;
  }

  /// Pick [rank] from the center on your turn only. Returning chips is not allowed.
  void takeChip(String actingUserId, int rank, String phase) {
    if (game['current_turn_user_id'] != actingUserId) return;

    final cap = _starCapForPlayerCount(players.length);
    if (rank < 1 || rank > cap) return;
    if (_holderOfRank(phase, rank) != null) return;

    final claimCol = _claimColumnForPhase(phase);
    final me = _playerByUserId(actingUserId);
    if (me == null || me[claimCol] != null) return;

    final aux = AdvancedAuxState.decode(game['advanced_aux']);
    if (AdvancedAuxState.stealForbidden(aux, phase, rank)) return;

    me[claimCol] = rank;

    _maybeAppendStickyAfterCenterClaim(
      cid: game['challenge_active'] as int?,
      phase: phase,
      rank: rank,
      cap: cap,
    );

    _advanceChipTurnAfterAction(actingUserId, phase);
  }

  /// Steal another player's chip for this round — victim loses theirs; chips cannot
  /// be voluntarily returned.
  void stealChip({
    required String actingUserId,
    required int rank,
    required String phase,
    required String victimUserId,
  }) {
    if (game['current_turn_user_id'] != actingUserId) return;
    if (victimUserId == actingUserId) return;

    final claimCol = _claimColumnForPhase(phase);
    final holder = _playerByUserId(victimUserId);
    if (holder == null || holder[claimCol] != rank) return;

    final me = _playerByUserId(actingUserId);
    if (me == null || me[claimCol] != null) return;

    final aux = AdvancedAuxState.decode(game['advanced_aux']);
    if (AdvancedAuxState.stealForbidden(aux, phase, rank)) return;

    holder[claimCol] = null;
    me[claimCol] = rank;

    _advanceChipTurnAfterAction(actingUserId, phase);
  }

  void _maybeAppendStickyAfterCenterClaim({
    required int? cid,
    required String phase,
    required int rank,
    required int cap,
  }) {
    if (cid == null) return;
    if (game['advanced_mode'] != true) return;

    final triggersSticky = (cid == 2 && rank == 1) || (cid == 6 && rank == cap);
    if (!triggersSticky || (phase != 'PRE_FLOP' && phase != 'FLOP' && phase != 'TURN')) return;

    final aux = AdvancedAuxState.decode(game['advanced_aux']);
    final sticky = AdvancedAuxState.stickyList(aux)..add({'phase': phase, 'rank': rank});
    game['advanced_aux'] = AdvancedAuxState.withSticky(aux, sticky);
  }

  /// Fixed seat rotation (low seat -> ... -> host -> wrap). Skip anyone who already
  /// has a chip this street until someone chipless is due (next lap). Never jump to
  /// the steal victim — they wait until their seat comes again in order.
  void _advanceChipTurnAfterAction(String actingUserId, String phase) {
    if (_everyoneClaimedForPhase(phase)) {
      _advanceAfterStreetComplete(phase);
      return;
    }

    final sorted = playersOrdered;
    final actingIdx = sorted.indexWhere((p) => p['user_id'] == actingUserId);
    if (actingIdx < 0 || sorted.isEmpty) return;

    final claimCol = _claimColumnForPhase(phase);
    final n = sorted.length;
    var cursor = (actingIdx + 1) % n;
    for (var step = 0; step < n; step++) {
      final candidate = sorted[cursor];
      if (candidate[claimCol] == null) {
        game['current_turn_user_id'] = candidate['user_id'];
        return;
      }
      cursor = (cursor + 1) % n;
    }
    // Unreachable: the acting player's own claim was just set before this call, so the
    // full lap above always finds some other chipless player before running out of seats.
  }

  void _advanceAfterStreetComplete(String phase) {
    if (phase == 'RIVER') {
      game['status'] = 'SHOWDOWN';
      game['current_turn_user_id'] = null;
      _maybeStartGuessVote();
      return;
    }
    if (phase == 'FLOP') {
      _applyFlopMotionLaserRedraws();
      _advancePhaseAfterFlop();
      return;
    }
    _advancePhaseStandard(phase);
  }

  /// Retina Scan (#4) / Fingerprint Scan (#9): at showdown, everyone EXCEPT
  /// the highest-red-chip holder votes on the guess; completion records it and
  /// resolves straight to the verdict (no host button needed).
  void _maybeStartGuessVote() {
    final cid = game['challenge_active'] as int?;
    if (cid != 4 && cid != 9) return;
    final models = playersOrdered.map(PlayerModel.fromMap).toList();
    final target = HeistEvaluator.playerWithHighestRiverChip(models);
    final voters = [
      for (final p in playersOrdered)
        if (p['user_id'] != target?.userId) p['user_id'] as String,
    ];
    if (voters.isEmpty) return;
    if (cid == 4) {
      _startVote('retina', options: rankOptions, voters: voters);
    } else {
      _startVote('fingerprint',
          options: [for (var i = 0; i < HeistEvaluator.fingerprintCategories.length; i++) '$i'],
          voters: voters);
    }
  }

  void _advancePhaseStandard(String currentPhase) {
    String enteringPhase;
    if (currentPhase == 'PRE_FLOP') {
      enteringPhase = 'FLOP';
    } else if (currentPhase == 'TURN') {
      enteringPhase = 'RIVER';
    } else {
      return;
    }
    _blackoutClearIfNeeded(enteringPhase);
    game['status'] = enteringPhase;
    game['current_turn_user_id'] = _chipRoundFirstTurnUserId();
  }

  void _advancePhaseAfterFlop() {
    final cid = game['challenge_active'] as int?;
    final enteringPhase = cid == 5 ? 'RIVER' : 'TURN';
    _blackoutClearIfNeeded(enteringPhase);
    game['status'] = enteringPhase;
    game['current_turn_user_id'] = _chipRoundFirstTurnUserId();
  }

  void _blackoutClearIfNeeded(String enteringPhase) {
    if (game['challenge_active'] != 8) return;
    String? col;
    if (enteringPhase == 'FLOP') {
      col = 'claim_preflop';
    } else if (enteringPhase == 'TURN') {
      col = 'claim_flop';
    } else if (enteringPhase == 'RIVER') {
      col = 'claim_turn';
    }
    if (col == null) return;
    for (final p in players) {
      p[col] = null;
    }
  }

  void _applyFlopMotionLaserRedraws() {
    final cid = game['challenge_active'] as int?;
    if (game['advanced_mode'] != true || (cid != 3 && cid != 7)) return;

    final board = List<String>.from(game['community_cards'] ?? []);
    if (board.length < 3) return;
    final flop = board.sublist(0, 3);

    final models = playersOrdered.map((e) => PlayerModel.fromMap(e)).toList();

    final jqk = HeistEvaluator.flopHasJQK(flop);
    PlayerModel? target;
    if (cid == 3 && jqk) {
      target = HeistEvaluator.holderOfWhiteOneStar(models);
    } else if (cid == 7 && !jqk) {
      target = HeistEvaluator.holderOfHighestWhiteChip(models);
    }
    if (target == null) return;

    var deckRemaining = _parseDeckRemaining(game['deck_remaining']);
    final holes = target.hand.length;
    if (holes == 0 || deckRemaining.length < holes) return;

    final drew = <String>[];
    for (var i = 0; i < holes; i++) {
      drew.insert(0, deckRemaining.removeLast());
    }

    final targetMap = players.firstWhere((p) => p['id'] == target!.id);
    targetMap['hand_cards'] = drew;
    game['deck_remaining'] = deckRemaining;
  }

  List<String> _parseDeckRemaining(dynamic raw) {
    if (raw is List) return raw.map((e) => e.toString()).toList();
    return [];
  }

  /// First materialization of an advanced-card stack; shuffled in random mode,
  /// rulebook order 1→10 otherwise. Persisted stacks keep their order.
  List<int> _stackFrom(dynamic raw) {
    if (raw != null) return AdvancedCards.parseStack(raw);
    final stack = AdvancedCards.defaultOrder();
    if (game['advanced_random'] == true) stack.shuffle(Random.secure());
    return stack;
  }

  void dealInitialCards() {
    if (game['status'] == 'GAME_OVER') {
      // Campaign finished (3 wins or 3 losses): dealing again starts a fresh
      // campaign with the same table — scores reset, advanced cards back in
      // the box, first heist is vanilla again.
      game['win_score'] = 0;
      game['lose_score'] = 0;
      game['last_heist_success'] = null;
      game['challenge_active'] = null;
      game['specialist_active'] = null;
      game['challenge_queued'] = (game['forced_challenge'] as num?)?.toInt();
      game['specialist_queued'] = (game['forced_specialist'] as num?)?.toInt();
      game['challenge_stack'] = null;
      game['specialist_stack'] = null;
    }

    final deck = _buildDeck()..shuffle(Random.secure());

    final hostUserId = game['host_user_id'] as String;
    final otherPlayers = players.where((p) => p['user_id'] != hostUserId).toList();
    final hostPlayer = players.firstWhere((p) => p['user_id'] == hostUserId);
    final sortedList = [...otherPlayers, hostPlayer];

    final queuedChallenge = game['challenge_queued'] as int?;
    final queuedSpecialist = game['specialist_queued'] as int?;
    final cidForHand = queuedChallenge;

    final holeCount = cidForHand == 10 ? 3 : 2;

    final pockets = <List<String>>[];
    for (var i = 0; i < sortedList.length; i++) {
      pockets.add(List.generate(holeCount, (_) => deck.removeLast()));
    }

    void passCoordinatorLeft() {
      final n = pockets.length;
      final outgoingFirst = [for (final h in pockets) h.first];
      for (var i = 0; i < n; i++) {
        pockets[i][0] = outgoingFirst[(i - 1 + n) % n];
      }
    }

    void conArtistShuffle() {
      final flat = pockets.expand((e) => e).toList()..shuffle(Random.secure());
      var idx = 0;
      for (var i = 0; i < pockets.length; i++) {
        final sz = pockets[i].length;
        pockets[i] = flat.sublist(idx, idx + sz);
        idx += sz;
      }
    }

    if (queuedSpecialist == 6) passCoordinatorLeft();
    if (queuedSpecialist == 9) conArtistShuffle();

    // Specialists 1/2/4/5/7/10 are applied AFTER the deal, to whichever player
    // the group votes for (see _startVote below) — not auto to the first seat.
    final auxNew = <String, dynamic>{'sticky_steals': <dynamic>[]};

    final communityCards = List.generate(5, (_) => deck.removeLast());

    final initialStatus = cidForHand == 1 ? 'FLOP' : 'PRE_FLOP';
    final firstPickerUserId = sortedList.first['user_id'] as String;

    for (var i = 0; i < sortedList.length; i++) {
      final p = sortedList[i];
      p['hand_cards'] = pockets[i];
      p['claim_preflop'] = null;
      p['claim_flop'] = null;
      p['claim_turn'] = null;
      p['claim_river'] = null;
      p['seat_index'] = i;
    }

    game['community_cards'] = communityCards;
    game['deck_remaining'] = deck;
    game['status'] = initialStatus;
    game['current_turn_user_id'] = firstPickerUserId;
    game['challenge_active'] = queuedChallenge;
    game['specialist_active'] = queuedSpecialist;
    game['challenge_queued'] = null;
    game['specialist_queued'] = null;
    game['advanced_aux'] = auxNew;
    game['vote'] = null;
    game['mastermind_target'] = null;

    // Math Whiz announces everyone's pocket total automatically.
    if (queuedSpecialist == 8) {
      for (final p in sortedList) {
        emote(p['user_id'] as String, 'My total: ${_pocketSum(List<String>.from(p['hand_cards'] as List))}');
      }
    }

    // Group decides who uses the specialist via the circle of choice.
    if (queuedSpecialist != null && _votedSpecialists.contains(queuedSpecialist)) {
      _startVote('choose_player',
          specialist: queuedSpecialist,
          options: [for (final p in sortedList) p['user_id'] as String]);
    }
  }

  List<String> _buildDeck() {
    const ranks = ['A', 'K', 'Q', 'J', 'T', '9', '8', '7', '6', '5', '4', '3', '2'];
    const suits = ['s', 'h', 'd', 'c'];
    final deck = <String>[];
    for (final rank in ranks) {
      for (final suit in suits) {
        deck.add('$rank$suit');
      }
    }
    return deck;
  }

  void resolveRetinaGuess(String guess) {
    final aux = AdvancedAuxState.decode(game['advanced_aux']);
    aux['retina_rank'] = guess;
    game['advanced_aux'] = aux;
  }

  void resolveFingerprintGuess(int categoryIndex) {
    final aux = AdvancedAuxState.decode(game['advanced_aux']);
    aux['fingerprint_category'] = categoryIndex;
    game['advanced_aux'] = aux;
  }

  void setInvestorClaims(Map<String, int> claims) {
    final aux = AdvancedAuxState.decode(game['advanced_aux']);
    aux['investor_claims'] = claims;
    game['advanced_aux'] = aux;
  }

  void setMathWhizClaims(Map<String, int> claims) {
    final aux = AdvancedAuxState.decode(game['advanced_aux']);
    aux['math_whiz_claims'] = claims;
    game['advanced_aux'] = aux;
  }

  void setMastermindClaim(String playerId, String rank, int count) {
    final aux = AdvancedAuxState.decode(game['advanced_aux']);
    aux['mastermind_player_id'] = playerId;
    aux['mastermind_rank'] = rank;
    aux['mastermind_count'] = count;
    game['advanced_aux'] = aux;
  }

  void triggerVerdict() {
    final playerModels = players.map((p) => PlayerModel.fromMap(p)).toList();
    final board = List<String>.from(game['community_cards'] ?? []);
    final aux = AdvancedAuxState.decode(game['advanced_aux']);
    final cid = game['challenge_active'] as int?;

    final success = HeistEvaluator.checkMissionSuccessAdvanced(
      playerModels,
      board,
      challengeActive: cid,
      specialistMuscleUserId: aux['muscle_user_id']?.toString(),
      retinaGuessRank: aux['retina_rank']?.toString(),
      fingerprintCategoryIndex: aux['fingerprint_category'] is num ? (aux['fingerprint_category'] as num).toInt() : null,
      securityCamerasActive: cid == 10,
    );

    final advanced = game['advanced_mode'] == true;
    var winScore = (game['win_score'] as num?)?.toInt() ?? 0;
    var loseScore = (game['lose_score'] as num?)?.toInt() ?? 0;
    if (success) {
      winScore++;
    } else {
      loseScore++;
    }

    final challengeStack = _stackFrom(game['challenge_stack']);
    final specialistStack = _stackFrom(game['specialist_stack']);

    final tableChallenge = game['challenge_active'] as int?;
    final tableSpecialist = game['specialist_active'] as int?;
    if (tableChallenge != null) challengeStack.add(tableChallenge);
    if (tableSpecialist != null) specialistStack.add(tableSpecialist);

    final campaignOver = winScore >= 3 || loseScore >= 3;

    game['win_score'] = winScore;
    game['lose_score'] = loseScore;
    game['challenge_active'] = null;
    game['specialist_active'] = null;
    game['last_heist_success'] = success;
    game['challenge_stack'] = challengeStack;
    game['specialist_stack'] = specialistStack;
    game['current_turn_user_id'] = null;

    if (campaignOver) {
      game['status'] = 'GAME_OVER';
      game['challenge_queued'] = null;
      game['specialist_queued'] = null;
      return;
    }

    game['status'] = 'VERDICT';
    if (advanced) {
      final forcedChallenge = (game['forced_challenge'] as num?)?.toInt();
      final forcedSpecialist = (game['forced_specialist'] as num?)?.toInt();
      if (forcedChallenge != null || forcedSpecialist != null) {
        // Custom/testing mode: the chosen cards trigger every heist,
        // regardless of the outcome.
        game['challenge_queued'] = forcedChallenge;
        game['specialist_queued'] = forcedSpecialist;
      } else if (success) {
        game['challenge_queued'] = AdvancedCards.shiftFront(challengeStack);
        game['specialist_queued'] = null;
      } else {
        game['specialist_queued'] = AdvancedCards.shiftFront(specialistStack);
        game['challenge_queued'] = null;
      }
      game['challenge_stack'] = challengeStack;
      game['specialist_stack'] = specialistStack;
    } else {
      game['challenge_queued'] = null;
      game['specialist_queued'] = null;
    }
  }
}
