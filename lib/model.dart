import 'dart:math';

import 'hand_eval.dart';

// --- MODELS ---
class PlayerModel {
  final String id;
  final String userId;
  final String displayName;
  final List<String> hand;
  final int? claimPreflop;
  final int? claimFlop;
  final int? claimTurn;
  final int? claimRiver;
  final int? seatIndex;

  PlayerModel({
    required this.id,
    required this.userId,
    required this.displayName,
    required this.hand,
    this.claimPreflop,
    this.claimFlop,
    this.claimTurn,
    this.claimRiver,
    this.seatIndex,
  });

  factory PlayerModel.fromMap(Map<String, dynamic> map) {
    return PlayerModel(
      id: map['id'].toString(),
      userId: map['user_id'] as String,
      displayName: map['display_name'] as String? ?? 'Player',
      hand: List<String>.from(map['hand_cards'] ?? []),
      claimPreflop: map['claim_preflop'] as int?,
      claimFlop: map['claim_flop'] as int?,
      claimTurn: map['claim_turn'] as int?,
      claimRiver: map['claim_river'] as int?,
      seatIndex: map['seat_index'] as int?,
    );
  }

  int? getClaimForPhase(String phase) {
    switch (phase) {
      case 'PRE_FLOP':
        return claimPreflop;
      case 'FLOP':
        return claimFlop;
      case 'TURN':
        return claimTurn;
      case 'RIVER':
        return claimRiver;
      default:
        return null;
    }
  }

  List<int> get chipHistory {
    return [claimPreflop, claimFlop, claimTurn, claimRiver].whereType<int>().toList();
  }
}

// --- EVALUATOR LOGIC ---
class HeistEvaluator {
  static const List<String> fingerprintCategories = [
    'High Card',
    'Pair',
    'Two Pair',
    'Three of a Kind',
    'Straight',
    'Flush',
    'Full House',
    'Four of a Kind',
    'Straight Flush',
    'Royal Flush',
  ];

  static String getHandName(List<String> hand, List<String> board) {
    if (hand.isEmpty) return "No Hand";
    try {
      return evaluateBestHand([...hand, ...board].map(_normalizeCardString).toList()).name;
    } catch (e) {
      return "Invalid Hand";
    }
  }

  static bool checkMissionSuccess(List<PlayerModel> players, List<String> communityBoard) {
    return checkMissionSuccessAdvanced(
      players,
      communityBoard,
      challengeActive: null,
      specialistMuscleUserId: null,
      retinaGuessRank: null,
      fingerprintCategoryIndex: null,
      securityCamerasActive: false,
    );
  }

  static bool checkMissionSuccessAdvanced(
    List<PlayerModel> players,
    List<String> communityBoard, {
    int? challengeActive,
    String? specialistMuscleUserId,
    String? retinaGuessRank,
    int? fingerprintCategoryIndex,
    bool securityCamerasActive = false,
  }) {
    if (players.isEmpty) return false;

    // House rule: the heist succeeds iff the holder of the HIGHEST red chip
    // has the strongest hand. The other players' red chips are not checked.
    // Muscle counts as the stronger of exactly-equal hands, so doubling the
    // power and giving Muscle +1 breaks only true ties in Muscle's favor.
    int adjustedPower(PlayerModel player) {
      int power;
      try {
        power = evaluateBestHand([...player.hand, ...communityBoard].map(_normalizeCardString).toList()).power;
      } catch (_) {
        power = -999999999;
      }
      return power * 2 + (player.userId == specialistMuscleUserId ? 1 : 0);
    }

    final target = playerWithHighestRiverChip(players);
    if (target == null) return false;
    final maxPower = players.map(adjustedPower).reduce(max);
    var chipsOk = adjustedPower(target) == maxPower;

    // Retina Scan / Fingerprint Scan are AND conditions: with the challenge
    // active, a missing or wrong guess fails the heist even when the chips
    // were correct.
    if (challengeActive == 4) {
      chipsOk = chipsOk &&
          retinaGuessRank != null &&
          retinaGuessRank.isNotEmpty &&
          _retinaPasses(players, retinaGuessRank);
    }

    if (challengeActive == 9) {
      chipsOk = chipsOk &&
          fingerprintCategoryIndex != null &&
          _fingerprintPasses(players, fingerprintCategoryIndex, communityBoard);
    }

    return chipsOk;
  }

  static PlayerModel? playerWithHighestRiverChip(List<PlayerModel> players) {
    PlayerModel? best;
    int? hi;
    for (final p in players) {
      final c = p.claimRiver;
      if (c == null) continue;
      if (hi == null || c > hi) {
        hi = c;
        best = p;
      }
    }
    return best;
  }

  static bool _retinaPasses(List<PlayerModel> players, String guessedRank) {
    final target = playerWithHighestRiverChip(players);
    if (target == null) return false;
    final canon = _canonRankGuess(guessedRank);
    if (canon.isEmpty) return false;
    for (final card in target.hand) {
      if (_rankOfCard(card) == canon) return true;
    }
    return false;
  }

  static bool _fingerprintPasses(
    List<PlayerModel> players,
    int categoryIndex,
    List<String> board,
  ) {
    final target = playerWithHighestRiverChip(players);
    if (target == null || categoryIndex < 0 || categoryIndex >= fingerprintCategories.length) return false;
    final expectedLabel = fingerprintCategories[categoryIndex].toLowerCase();
    try {
      final madeName =
          evaluateBestHand([...target.hand, ...board].map(_normalizeCardString).toList()).name.toLowerCase();
      return madeName.contains(expectedLabel) || _categoryAliasMatch(madeName, expectedLabel);
    } catch (_) {
      return false;
    }
  }

  static bool _categoryAliasMatch(String madeLower, String expectedLower) {
    if (expectedLower.contains('high card')) return madeLower.contains('high card');
    if (expectedLower.contains('royal')) return madeLower.contains('royal');
    if (expectedLower.contains('straight flush')) {
      return madeLower.contains('straight flush') || madeLower.contains('royal flush');
    }
    return madeLower.contains(expectedLower);
  }

  static String _canonRankGuess(String g) {
    final u = g.trim().toUpperCase();
    if (u == '10') return 'T';
    if (u.length == 1 && const {'A', 'K', 'Q', 'J', 'T', '9', '8', '7', '6', '5', '4', '3', '2'}.contains(u)) {
      return u;
    }
    return '';
  }

  static String _rankOfCard(String raw) {
    final s = raw.trim().toUpperCase();
    if (s.startsWith('10')) return 'T';
    return s.isNotEmpty ? s[0] : '';
  }

  static bool flopHasJQK(List<String> board3) {
    for (final c in board3) {
      final r = _rankOfCard(c);
      if (r == 'J' || r == 'Q' || r == 'K') return true;
    }
    return false;
  }

  static PlayerModel? holderOfWhiteOneStar(List<PlayerModel> players) {
    for (final p in players) {
      if (p.claimPreflop == 1) return p;
    }
    return null;
  }

  static PlayerModel? holderOfHighestWhiteChip(List<PlayerModel> players) {
    PlayerModel? best;
    int? hi;
    for (final p in players) {
      final c = p.claimPreflop;
      if (c == null) continue;
      if (hi == null || c > hi) {
        hi = c;
        best = p;
      }
    }
    return best;
  }

  static String _normalizeCardString(String raw) {
    final u = raw.trim().toUpperCase();
    if (u == 'JN') {
      return 'Js';
    }
    final card = u;
    if (card.length < 2) throw FormatException('Invalid card: $raw');

    final first = card[0];
    final second = card[1];
    const validRanks = {'A', 'K', 'Q', 'J', 'T', '9', '8', '7', '6', '5', '4', '3', '2'};
    const validSuits = {'S', 'H', 'D', 'C'};

    if (validRanks.contains(first) && validSuits.contains(second)) {
      return '${first}${second.toLowerCase()}';
    }
    if (validSuits.contains(first) && validRanks.contains(second)) {
      return '${second}${first.toLowerCase()}';
    }
    throw FormatException('Invalid card: $raw');
  }
}

