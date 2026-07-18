import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'advanced_aux_state.dart';
import 'advanced_cards.dart';
import 'lan/game_connection.dart';
import 'model.dart';
import 'widgets/playing_card_view.dart';

/// App-wide text scale, driven by the in-game settings dialog and applied in
/// main.dart's MaterialApp builder.
/// ponytail: not persisted — resets to 1.0 on reload; add shared_preferences
/// only if players actually ask for it to stick.
final ValueNotifier<double> appTextScale = ValueNotifier<double>(1.0);

class GameTableScreen extends StatefulWidget {
  final GameConnection conn;
  final String hostUserId;
  final String playerId;
  const GameTableScreen({
    super.key,
    required this.conn,
    required this.hostUserId,
    required this.playerId,
  });

  @override
  State<GameTableScreen> createState() => _GameTableScreenState();
}

class _GameTableScreenState extends State<GameTableScreen> {
  bool get isHost => widget.playerId == widget.hostUserId;
  bool _isBusy = false;
  double _seatCardScale = 1.0; // showdown card size at seats (settings slider)

  // Chip flight animation: previous claims -> detect owner changes -> fly a
  // chip from its old spot (center pool or old owner's seat) to the new seat.
  StreamSubscription<List<Map<String, dynamic>>>? _playersSub;
  final Map<String, int?> _prevClaims = {}; // '$userId|$phase' -> rank
  bool _claimsSeeded = false;
  final List<_ChipFlight> _flights = [];
  int _flightSeq = 0;
  final Map<String, Offset> _seatChipPos = {}; // filled during _buildSeats
  final Map<int, Offset> _poolChipPos = {}; // filled during build

  // Speech bubbles: tap your own avatar -> random phrase; specialists also
  // announce info here. Per-user so several bubbles can be live at once.
  static const List<String> _emotePhrases = ['Wise choice', 'Wait...', 'Oii!', 'Thinking...'];
  StreamSubscription<Map<String, dynamic>>? _gameSub;
  final Map<String, String> _bubbleText = {}; // userId -> live bubble text
  final Map<String, int> _bubbleSeq = {};

  // Con Artist (#9) shuffle flourish, shown briefly when the heist deals.
  bool _shuffleFx = false;
  String _lastStatus = 'LOBBY';

  // Rule announcement when a heist deals with an active challenge/specialist.
  bool _showRuleCard = false;
  int? _ruleChallengeId;
  int? _ruleSpecialistId;

  @override
  void initState() {
    super.initState();
    _playersSub = widget.conn.playersStream.listen(_onPlayersForFlights);
    _gameSub = widget.conn.gameStream.listen(_onGameUpdate);
  }

  @override
  void dispose() {
    _playersSub?.cancel();
    _gameSub?.cancel();
    super.dispose();
  }

  void _onGameUpdate(Map<String, dynamic> game) {
    // Per-player speech bubbles, visible for 5 seconds each.
    final emotes = game['emotes'];
    if (emotes is Map) {
      emotes.forEach((uid, e) {
        if (e is! Map || uid is! String) return;
        final seq = (e['seq'] as num?)?.toInt() ?? 0;
        if (_bubbleSeq[uid] == seq) return;
        _bubbleSeq[uid] = seq;
        if (!mounted) return;
        setState(() => _bubbleText[uid] = e['text'] as String? ?? '');
        Timer(const Duration(seconds: 5), () {
          if (mounted && _bubbleSeq[uid] == seq) setState(() => _bubbleText.remove(uid));
        });
      });
    }

    // Con Artist shuffle flourish on the deal that mixed the pockets.
    final status = game['status'] as String? ?? 'LOBBY';
    if (status != _lastStatus) {
      final dealt = (status == 'PRE_FLOP' || status == 'FLOP') &&
          (_lastStatus == 'LOBBY' || _lastStatus == 'VERDICT' || _lastStatus == 'GAME_OVER');
      if (dealt && (game['specialist_active'] as num?)?.toInt() == 9 && mounted) {
        setState(() => _shuffleFx = true);
        Timer(const Duration(milliseconds: 1900), () {
          if (mounted) setState(() => _shuffleFx = false);
        });
      }
      // Announce the active additional rule(s) for this heist to everyone.
      if (dealt && mounted) {
        final chal = (game['challenge_active'] as num?)?.toInt();
        final spec = (game['specialist_active'] as num?)?.toInt();
        if (chal != null || spec != null) {
          setState(() {
            _ruleChallengeId = chal;
            _ruleSpecialistId = spec;
            _showRuleCard = true;
          });
          Timer(const Duration(seconds: 12), () {
            if (mounted) setState(() => _showRuleCard = false);
          });
        }
      }
      _lastStatus = status;
    }
  }

  void _onPlayersForFlights(List<Map<String, dynamic>> raw) {
    final players = raw.map((p) => PlayerModel.fromMap(p)).toList();
    final flights = <_ChipFlight>[];
    if (_claimsSeeded) {
      for (final phase in _chipPhases) {
        for (final p in players) {
          final now = p.getClaimForPhase(phase);
          if (now == null || _prevClaims['${p.userId}|$phase'] == now) continue;
          String? prevHolder;
          for (final entry in _prevClaims.entries) {
            final parts = entry.key.split('|');
            if (parts.length == 2 && parts[1] == phase && entry.value == now) {
              prevHolder = parts[0];
              break;
            }
          }
          final from = prevHolder != null ? _seatChipPos[prevHolder] : _poolChipPos[now];
          final to = _seatChipPos[p.userId];
          if (from != null && to != null) {
            flights.add(_ChipFlight(_flightSeq++, phase, now, from, to));
          }
        }
      }
    }
    _claimsSeeded = true;
    _prevClaims.clear();
    for (final p in players) {
      for (final phase in _chipPhases) {
        _prevClaims['${p.userId}|$phase'] = p.getClaimForPhase(phase);
      }
    }
    if (flights.isNotEmpty && mounted) setState(() => _flights.addAll(flights));
  }

  static const List<String> _chipPhases = ['PRE_FLOP', 'FLOP', 'TURN', 'RIVER'];

  /// Ranks 1..N only (N = players, up to 7); higher-star chips stay "in the box" (not shown).
  int _starCapForPlayerCount(int playerCount) => playerCount.clamp(1, 7);

  Color _chipBaseColorForPhase(String phase) {
    switch (phase) {
      case 'PRE_FLOP':
        return Colors.grey.shade100;
      case 'FLOP':
        return Colors.amber.shade600;
      case 'TURN':
        return Colors.deepOrange.shade400;
      case 'RIVER':
        return Colors.red.shade600;
      default:
        return Colors.blueGrey;
    }
  }

  /// On-chip marker until final artwork (round number + color initial).
  String _chipSignForPhase(String phase) {
    switch (phase) {
      case 'PRE_FLOP':
        return 'R1·W';
      case 'FLOP':
        return 'R2·Y';
      case 'TURN':
        return 'R3·O';
      case 'RIVER':
        return 'R4·R';
      default:
        return '';
    }
  }

  bool _evaluateMissionFromSnapshot(Map<String, dynamic> gameData, List<PlayerModel> players) {
    final aux = AdvancedAuxState.decode(gameData['advanced_aux']);
    final cid = gameData['challenge_active'] as int?;
    final board = List<String>.from(gameData['community_cards'] ?? []);

    return HeistEvaluator.checkMissionSuccessAdvanced(
      players,
      board,
      challengeActive: cid,
      specialistMuscleUserId: aux['muscle_user_id']?.toString(),
      retinaGuessRank: aux['retina_rank']?.toString(),
      fingerprintCategoryIndex: aux['fingerprint_category'] is num ? (aux['fingerprint_category'] as num).toInt() : null,
      securityCamerasActive: cid == 10,
    );
  }

  // Retina/Fingerprint guesses are collected by the group vote wheel at
  // showdown (the engine starts it automatically), so resolving is only needed
  // for heists without those challenges.
  Future<void> _resolveShowdownToVerdict(Map<String, dynamic> gameData) async {
    widget.conn.triggerVerdict();
  }

  Future<void> _promptInvestorClaims(List<PlayerModel> players) async {
    final controllers = <String, TextEditingController>{
      for (final p in players) p.userId: TextEditingController(),
    };
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Investor (specialist #3)'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final p in players)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TextField(
                    controller: controllers[p.userId],
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(labelText: '${p.displayName} face cards (J/Q/K)', hintText: '0–3'),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Skip')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok != true || !mounted) {
      for (final c in controllers.values) {
        c.dispose();
      }
      return;
    }
    final claims = <String, int>{};
    for (final p in players) {
      final raw = controllers[p.userId]!.text.trim();
      claims[p.userId] = int.tryParse(raw) ?? 0;
    }
    for (final c in controllers.values) {
      c.dispose();
    }
    widget.conn.setInvestorClaims(claims);
  }

  // --- UI COMPONENTS ---
  Widget _roundChipFace({
    required String phase,
    required int rank,
    required double radius,
    bool dimmed = false,
    bool showSign = true,
    bool locked = false,
  }) {
    // "Turn the chip to the dark side" (challenges #2 Noise Sensors / #6
    // Ventilation Shaft): the chip can no longer change owners this heist.
    final base = locked ? const Color(0xFF2B2B2B) : _chipBaseColorForPhase(phase);
    final fg = locked ? Colors.white : (phase == 'PRE_FLOP' ? Colors.black87 : Colors.black);
    final diameter = radius * 2;

    return SizedBox(
      width: diameter,
      height: diameter,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          ColorFiltered(
            colorFilter: ColorFilter.mode(dimmed ? Colors.grey.shade700 : base, BlendMode.modulate),
            child: Image.asset('assets/chips/chip_base.png', width: diameter, height: diameter),
          ),
          Transform.translate(
            offset: Offset(0, showSign && radius >= 20 ? -radius * 0.08 : 0),
            child: Text(
              '$rank★',
              style: TextStyle(
                fontSize: radius * 0.62,
                fontWeight: FontWeight.bold,
                color: dimmed ? Colors.white24 : fg,
              ),
            ),
          ),
          if (showSign && radius >= 20)
            Positioned(
              bottom: radius * 0.18,
              child: Text(
                _chipSignForPhase(phase),
                style: TextStyle(
                  fontSize: radius * 0.22,
                  fontWeight: FontWeight.w700,
                  color: dimmed ? Colors.white24 : Colors.black54,
                  height: 1,
                ),
              ),
            ),
          if (locked && !dimmed)
            Positioned(
              top: -radius * 0.1,
              right: -radius * 0.1,
              child: Icon(Icons.lock, size: radius * 0.55, color: Colors.amberAccent),
            ),
        ],
      ),
    );
  }

  /// Turn info shown top-center; the chips themselves sit in the table middle.
  Widget _chipTurnBanner(String phase, String? currentTurnUserId, List<PlayerModel> players) {
    final pickerMatch = players.where((p) => p.userId == currentTurnUserId).toList();
    final pickerName = pickerMatch.isEmpty ? '…' : pickerMatch.first.displayName;
    final isMyChipTurn = currentTurnUserId != null && currentTurnUserId == widget.playerId;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          currentTurnUserId == null && players.isEmpty
              ? 'Loading…'
              : 'Now choosing: $pickerName',
          style: TextStyle(
            color: isMyChipTurn ? Colors.amber : Colors.white70,
            fontSize: 14,
            fontWeight: FontWeight.bold,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 2),
        Text(
          isMyChipTurn
              ? 'Your turn — take a chip from the center or tap another player’s chip (no putting chips back)'
              : 'Fixed seat order (guests → host), then wrap · steal victims do not cut in line',
          style: TextStyle(
            color: isMyChipTurn ? Colors.amberAccent : Colors.white38,
            fontSize: 11,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildChipPool(String phase, String? currentTurnUserId, List<PlayerModel> players) {
    final cap = _starCapForPlayerCount(players.length);
    final takenRanks = players.map((p) => p.getClaimForPhase(phase)).whereType<int>().toSet();
    final isMyChipTurn = currentTurnUserId != null && currentTurnUserId == widget.playerId;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Center (${_chipSignForPhase(phase)}) — ranks 1–$cap only for ${players.length} players',
          style: const TextStyle(color: Colors.white38, fontSize: 11),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 15,
          runSpacing: 12,
          alignment: WrapAlignment.center,
          children: List.generate(cap, (index) {
            final rank = index + 1;
            final taken = takenRanks.contains(rank);
            final canTap = isMyChipTurn && !taken && !_isBusy;
            return GestureDetector(
              onTap: canTap
                  ? () => _runBusyAction(() async => widget.conn.takeChip(widget.playerId, rank, phase))
                  : null,
              child: Opacity(
                opacity: taken ? 0.35 : 1,
                child: _roundChipFace(phase: phase, rank: rank, radius: 30, dimmed: taken),
              ),
            );
          }),
        ),
        const SizedBox(height: 8),
        Text(
          'Anyone who already has a chip skips until their seat comes again; extra laps until everyone holds a chip.',
          style: TextStyle(color: Colors.white.withValues(alpha: 0.35), fontSize: 11),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildMyHand(List<PlayerModel> players) {
    final me = players.firstWhere((p) => p.userId == widget.playerId, orElse: () => PlayerModel(id: '', userId: '', displayName: '', hand: []));
    if (me.hand.isEmpty) return const SizedBox.shrink();

    return Positioned(
      bottom: 20, left: 20,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("YOUR HAND", style: TextStyle(color: Colors.white70, fontSize: 12)),
          const SizedBox(height: 5),
          Row(
            children: [
              for (var i = 0; i < me.hand.length; i++)
                Padding(
                  padding: const EdgeInsets.only(right: 5),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 350),
                    transitionBuilder: (child, anim) => FadeTransition(
                      opacity: anim,
                      child: SlideTransition(
                        position: Tween<Offset>(begin: const Offset(0, 0.4), end: Offset.zero).animate(anim),
                        child: child,
                      ),
                    ),
                    child: PlayingCardView(
                      key: ValueKey('$i-${me.hand[i]}'),
                      card: me.hand[i],
                      width: 165,
                      height: 230,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _playerPhaseChipSlot({
    required PlayerModel player,
    required String phaseRow,
    required String tablePhase,
    required bool verdictMode,
    required List<PlayerModel> allPlayers,
    required String? chipPickTurnUserId,
    required Map<String, dynamic> aux,
  }) {
    const phaseLabels = ['W', 'Y', 'O', 'R'];
    final idx = _chipPhases.indexOf(phaseRow);
    final label = idx >= 0 && idx < phaseLabels.length ? phaseLabels[idx] : '?';

    final activeIdx = _chipPhases.contains(tablePhase) ? _chipPhases.indexOf(tablePhase) : -1;
    final rank = player.getClaimForPhase(phaseRow);
    final locked = rank != null && AdvancedAuxState.stealForbidden(aux, phaseRow, rank);

    final isFuture = activeIdx != -1 && idx > activeIdx;
    final isInteractive = !verdictMode && tablePhase == phaseRow && activeIdx != -1;

    final pickerMatchMe = allPlayers.where((p) => p.userId == widget.playerId).toList();
    final bool iHaveChipThisRound = pickerMatchMe.isNotEmpty && pickerMatchMe.first.getClaimForPhase(tablePhase) != null;
    final bool isStealEligible =
        isInteractive &&
        rank != null &&
        !locked &&
        player.userId != widget.playerId &&
        chipPickTurnUserId == widget.playerId &&
        !iHaveChipThisRound;

    const miniR = 20.0;

    if (isFuture) {
      return Tooltip(
        message: 'Round ${idx + 1} ($label) — not started',
        child: Container(
          width: miniR * 2,
          height: miniR * 2,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white12),
            color: Colors.black26,
          ),
          child: Text(label, style: const TextStyle(color: Colors.white24, fontSize: 11, fontWeight: FontWeight.bold)),
        ),
      );
    }

    if (rank == null && !isInteractive) {
      return Tooltip(
        message: 'Round ${idx + 1} ($label)',
        child: Container(
          width: miniR * 2,
          height: miniR * 2,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white12),
          ),
          child: Text('—', style: TextStyle(color: Colors.white.withValues(alpha: 0.35))),
        ),
      );
    }

    if (rank == null && isInteractive) {
      return Tooltip(
        message: '$label: no chip yet — take one from the center',
        child: Container(
          width: miniR * 2,
          height: miniR * 2,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white24, style: BorderStyle.solid),
          ),
          child: Text(label, style: const TextStyle(color: Colors.white38, fontSize: 11, fontWeight: FontWeight.bold)),
        ),
      );
    }

    final face = _roundChipFace(phase: phaseRow, rank: rank!, radius: miniR, showSign: false, locked: locked);

    if (!isStealEligible) {
      return Tooltip(
        message: locked ? '$label·$rank★ — locked (dark side), cannot change owners' : '$label·$rank★',
        child: face,
      );
    }

    final stolenRank = rank;
    return Tooltip(
      message: '$label·$stolenRank★ — tap to steal (your turn)',
      child: GestureDetector(
        onTap: _isBusy
            ? null
            : () => _runBusyAction(
                  () async => widget.conn.stealChip(widget.playerId, stolenRank, phaseRow, player.userId),
                ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.amber.withValues(alpha: 0.7), width: 2),
          ),
          child: face,
        ),
      ),
    );
  }

  /// One Positioned seat per player around the table ellipse: avatar (glowing
  /// when it's their turn), name, pocket-card backs (faces at showdown), and
  /// their chip row underneath — tap another player's chip there to steal.
  List<Widget> _buildSeats({
    required BoxConstraints box,
    required List<PlayerModel> players,
    required List<String> board,
    required String phase,
    required String? chipPickTurnUserId,
    required Map<String, dynamic> aux,
  }) {
    if (players.isEmpty) return const [];
    final w = box.maxWidth;
    final h = box.maxHeight;
    const seatW = 230.0;
    const seatH = 260.0;

    // You always sit at the bottom; the rest keep seat order clockwise.
    final myIdx = players.indexWhere((p) => p.userId == widget.playerId);
    final rotated = myIdx <= 0 ? players : [...players.sublist(myIdx), ...players.sublist(0, myIdx)];

    final seats = <Widget>[];
    _seatChipPos.clear();
    for (var i = 0; i < rotated.length; i++) {
      final theta = pi / 2 + 2 * pi * i / rotated.length;
      final x = (w / 2 + w * 0.44 * cos(theta) - seatW / 2).clamp(8.0, w - seatW - 8);
      final y = (h / 2 + h * 0.40 * sin(theta) - seatH / 2).clamp(64.0, h - seatH - 8);
      // Approximate center of the seat's chip pill, for flight animations.
      _seatChipPos[rotated[i].userId] = Offset(x + seatW / 2, y + seatH - 45);
      seats.add(Positioned(
        left: x,
        top: y,
        width: seatW,
        child: _seatView(rotated[i], players, board, phase, chipPickTurnUserId, aux),
      ));
    }
    return seats;
  }

  Widget _seatView(
    PlayerModel player,
    List<PlayerModel> allPlayers,
    List<String> board,
    String phase,
    String? chipPickTurnUserId,
    Map<String, dynamic> aux,
  ) {
    final verdictMode = phase == 'VERDICT' || phase == 'GAME_OVER' || phase == 'SHOWDOWN';
    // Cards stay hidden through SHOWDOWN (the table-talk / Retina-Fingerprint
    // guessing phase) and only flip once the host resolves to the verdict.
    final revealHands = phase == 'VERDICT' || phase == 'GAME_OVER';
    final isTurn = _chipPhases.contains(phase) && chipPickTurnUserId == player.userId;
    final isMe = player.userId == widget.playerId;
    final title = '${player.displayName}'
        '${player.userId == widget.hostUserId ? ' (H)' : ''}'
        '${isMe ? ' — you' : ''}';

    final avatar = Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: isTurn ? Colors.amber : Colors.transparent, width: 2.5),
        boxShadow: isTurn
            ? [BoxShadow(color: Colors.amber.withValues(alpha: 0.55), blurRadius: 14, spreadRadius: 2)]
            : const [],
      ),
      child: CircleAvatar(
        radius: 30,
        backgroundColor: Colors.grey.shade300,
        child: Icon(Icons.person, size: 40, color: Colors.grey.shade700),
      ),
    );

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.black26,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Tap your own profile to say a quick phrase to the table.
        isMe
            ? Tooltip(
                message: 'Tap to speak',
                child: GestureDetector(
                  onTap: () => widget.conn.sendEmote(
                      widget.playerId, _emotePhrases[Random().nextInt(_emotePhrases.length)]),
                  child: avatar,
                ),
              )
            : avatar,
        const SizedBox(height: 4),
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: isTurn ? Colors.amber : Colors.white,
            fontWeight: isTurn ? FontWeight.bold : FontWeight.w600,
            fontSize: 16,
          ),
        ),
        const SizedBox(height: 6),
        if (revealHands && player.hand.isNotEmpty) ...[
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final c in player.hand)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: PlayingCardView(
                      card: c, width: 66 * _seatCardScale, height: 92 * _seatCardScale),
                ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            HeistEvaluator.getHandName(player.hand, board),
            style: const TextStyle(color: Colors.greenAccent, fontSize: 13, fontStyle: FontStyle.italic),
          ),
        ] else if (player.hand.isNotEmpty)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < player.hand.length; i++)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 2),
                  child: PlayingCardView(card: null, width: 48, height: 67),
                ),
            ],
          ),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.black38,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Wrap(
            spacing: 5,
            children: [
              for (final ph in _chipPhases)
                _playerPhaseChipSlot(
                  player: player,
                  phaseRow: ph,
                  tablePhase: phase,
                  verdictMode: verdictMode,
                  allPlayers: allPlayers,
                  chipPickTurnUserId: chipPickTurnUserId,
                  aux: aux,
                ),
            ],
          ),
        ),
      ],
      ),
        ),

        // Speech bubble above the avatar while this player's emote is live.
        if (_bubbleText.containsKey(player.userId))
          Positioned(
            top: -46,
            left: 50,
            child: IgnorePointer(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.black87, width: 2),
                    ),
                    child: Text(
                      _bubbleText[player.userId] ?? '',
                      style: const TextStyle(
                          color: Colors.black87, fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                  ),
                  // Little tail pointing at the avatar.
                  Padding(
                    padding: const EdgeInsets.only(left: 14),
                    child: Transform.rotate(
                      angle: pi / 4,
                      child: Container(width: 10, height: 10, color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  /// Full-screen announcement of this heist's active challenge/specialist,
  /// shown right after the deal so nobody misses the changed rules.
  Widget _buildRuleAnnouncement() {
    if (!_showRuleCard) return const SizedBox.shrink();
    final entries = <(String, String)>[
      if (_ruleChallengeId != null)
        (
          'CHALLENGE #$_ruleChallengeId — ${AdvancedCards.challengeTitle(_ruleChallengeId!)}',
          AdvancedCards.challengeRule(_ruleChallengeId!)
        ),
      if (_ruleSpecialistId != null)
        (
          'SPECIALIST #$_ruleSpecialistId — ${AdvancedCards.specialistTitle(_ruleSpecialistId!)}',
          AdvancedCards.specialistRule(_ruleSpecialistId!)
        ),
    ];
    if (entries.isEmpty) return const SizedBox.shrink();

    return Positioned.fill(
      child: Container(
        color: Colors.black54,
        alignment: Alignment.center,
        child: Container(
          width: 440,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: const Color(0xFF1C2620),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.amber, width: 2.5),
            boxShadow: [
              BoxShadow(color: Colors.amber.withValues(alpha: 0.25), blurRadius: 24, spreadRadius: 2),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('NEW RULE THIS HEIST',
                  style: TextStyle(
                      color: Colors.amberAccent,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 3,
                      fontSize: 13)),
              const SizedBox(height: 12),
              for (final (title, rule) in entries) ...[
                Text(title,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
                const SizedBox(height: 6),
                Text(rule,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70, fontSize: 13)),
                const SizedBox(height: 14),
              ],
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.amber, foregroundColor: Colors.black),
                onPressed: () => setState(() => _showRuleCard = false),
                child: const Text('Got it', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The "circle of choice": options on a ring, everyone's pick shown live
  /// (yours ringed yellow, others white with name tags). When all voters agree
  /// on the same option, the confirm button lights and counts confirmations.
  Widget _buildVoteOverlay(Map<String, dynamic> gameData, List<PlayerModel> players) {
    final vote = gameData['vote'];
    if (vote is! Map) return const SizedBox.shrink();

    final kind = vote['kind'] as String? ?? '';
    final options = List<String>.from(vote['options'] as List? ?? []);
    final voters = List<String>.from(vote['voters'] as List? ?? []);
    final picks = Map<String, dynamic>.from(vote['picks'] as Map? ?? {});
    final confirms = List<String>.from(vote['confirms'] as List? ?? []);
    if (options.isEmpty || voters.isEmpty) return const SizedBox.shrink();

    final iAmVoter = voters.contains(widget.playerId);
    final myPick = picks[widget.playerId] as String?;
    final nameOf = {for (final p in players) p.userId: p.displayName};
    final sid = (vote['specialist'] as num?)?.toInt();

    String labelFor(String opt) {
      switch (kind) {
        case 'fingerprint':
          return HeistEvaluator.fingerprintCategories[int.tryParse(opt) ?? 0];
        case 'choose_player':
          return nameOf[opt] ?? opt;
        default:
          return opt;
      }
    }

    final title = switch (kind) {
      'retina' => 'Retina Scan — agree on a card value in the target\'s hand',
      'fingerprint' => 'Fingerprint Scan — agree on the target\'s hand ranking',
      'choose_player' => 'Choose who uses ${AdvancedCards.specialistTitle(sid ?? 0)}',
      'mastermind_rank' => 'Mastermind — agree on the value to ask about',
      _ => 'Group decision',
    };

    final allAgree = picks.length == voters.length && picks.values.toSet().length == 1;
    final iConfirmed = confirms.contains(widget.playerId);
    final canConfirm = iAmVoter && allAgree && !iConfirmed && !_isBusy;
    const size = 500.0;
    const optionD = 58.0;

    return Positioned.fill(
      child: Container(
        color: Colors.black54,
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: size,
              height: size,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  // Center: what this vote is about.
                  Positioned.fill(
                    child: Center(
                      child: SizedBox(
                        width: 210,
                        child: Text(
                          title,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ),
                  for (var i = 0; i < options.length; i++)
                    () {
                      final opt = options[i];
                      final angle = -pi / 2 + 2 * pi * i / options.length;
                      final cx = size / 2 + cos(angle) * 185;
                      final cy = size / 2 + sin(angle) * 185;
                      final othersHere = [
                        for (final e in picks.entries)
                          if (e.value == opt && e.key != widget.playerId) nameOf[e.key] ?? '?',
                      ];
                      final mine = myPick == opt;
                      return Positioned(
                        left: cx - 40,
                        top: cy - optionD / 2,
                        width: 80,
                        child: GestureDetector(
                          onTap: iAmVoter && !_isBusy
                              ? () => widget.conn.castVote(widget.playerId, opt)
                              : null,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: optionD,
                                height: optionD,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: const Color(0xFF14301F),
                                  border: Border.all(
                                    color: mine
                                        ? Colors.amber
                                        : othersHere.isNotEmpty
                                            ? Colors.white
                                            : Colors.white24,
                                    width: mine ? 3.5 : othersHere.isNotEmpty ? 2.5 : 1,
                                  ),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.all(2),
                                  child: Text(
                                    labelFor(opt),
                                    maxLines: 2,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: kind == 'fingerprint' || kind == 'choose_player' ? 9 : 16,
                                    ),
                                  ),
                                ),
                              ),
                              // Name tags so everyone knows whose pick this is.
                              if (othersHere.isNotEmpty)
                                Text(
                                  othersHere.join(', '),
                                  maxLines: 2,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(color: Colors.white, fontSize: 9),
                                ),
                            ],
                          ),
                        ),
                      );
                    }(),
                ],
              ),
            ),
            const SizedBox(height: 4),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.amber,
                foregroundColor: Colors.black,
                disabledBackgroundColor: Colors.white12,
                disabledForegroundColor: Colors.white38,
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
              ),
              onPressed: canConfirm ? () => widget.conn.confirmVote(widget.playerId) : null,
              child: Text('confirm (${confirms.length}/${voters.length})',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
            if (!iAmVoter)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('You are the target — no hints!',
                    style: TextStyle(color: Colors.amberAccent, fontSize: 13)),
              )
            else if (!allAgree)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Everyone must pick the SAME option to unlock confirm',
                    style: TextStyle(color: Colors.white54, fontSize: 12)),
              ),
          ],
        ),
      ),
    );
  }

  void _showSettingsDialog() {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF23272E),
        title: const Text('Settings', style: TextStyle(color: Colors.white)),
        content: StatefulBuilder(
          builder: (context, setSt) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Text size — ${(appTextScale.value * 100).round()}%',
                  style: const TextStyle(color: Colors.white70)),
              Slider(
                value: appTextScale.value,
                min: 0.8,
                max: 1.6,
                divisions: 8,
                label: '${(appTextScale.value * 100).round()}%',
                onChanged: (v) => setSt(() => appTextScale.value = v),
              ),
              const SizedBox(height: 8),
              Text('Showdown card size — ${(_seatCardScale * 100).round()}%',
                  style: const TextStyle(color: Colors.white70)),
              Slider(
                value: _seatCardScale,
                min: 0.7,
                max: 1.8,
                divisions: 11,
                label: '${(_seatCardScale * 100).round()}%',
                onChanged: (v) {
                  setSt(() {});
                  setState(() => _seatCardScale = v);
                },
              ),
              const Text('Applies everywhere in the app immediately.',
                  style: TextStyle(color: Colors.white38, fontSize: 12)),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
        ],
      ),
    );
  }

  static const List<String> _generalRules = [
    'The Gang is co-operative poker: you all win or lose together, as a crew pulling heists.',
    'Each heist is one hand of Texas Hold\'em played over 4 rounds: pocket cards (White chips), flop (Yellow), turn (Orange), river (Red).',
    'Every round, in seat order, each player takes a star chip from the center — or steals one from another player. Your chip is your claim: how strong you think your FINAL hand will be compared to everyone else (1★ = weakest ... highest ★ = strongest).',
    'Chips are the only communication allowed. Never talk about, hint at, or reveal your cards!',
    'Showdown: hands are revealed. The heist succeeds only if the Red-round chips ranked everyone correctly — every player\'s red star must match their true hand strength order.',
    'Score: win 3 heists before losing 3 to beat the campaign.',
    'Advanced mode: after a WON heist, a challenge card makes the next heist harder; after a LOST heist, a specialist card helps you. Each card lasts one heist.',
  ];

  void _showRulesDialog() {
    Widget section(String title, String subtitle, String Function(int) name, String Function(int) rule) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(color: Colors.amberAccent, fontWeight: FontWeight.bold)),
          Text(subtitle, style: const TextStyle(color: Colors.white54, fontSize: 11)),
          const SizedBox(height: 8),
          for (var id = 1; id <= 10; id++) ...[
            Text('#$id ${name(id)}',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13)),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(rule(id), style: const TextStyle(color: Colors.white70, fontSize: 12)),
            ),
          ],
        ],
      );
    }

    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF23272E),
        title: const Text('How to play', style: TextStyle(color: Colors.white)),
        content: SizedBox(
          width: 460,
          height: 480,
          child: ListView(
            children: [
              const Text('THE GANG — GENERAL RULES',
                  style: TextStyle(color: Colors.amberAccent, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              for (final rule in _generalRules)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('•  ', style: TextStyle(color: Colors.white70)),
                      Expanded(
                        child: Text(rule, style: const TextStyle(color: Colors.white70, fontSize: 12)),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              section('CHALLENGE CARDS', 'Drawn after a WON heist — makes the next heist harder.',
                  AdvancedCards.challengeTitle, AdvancedCards.challengeRule),
              const SizedBox(height: 12),
              section('SPECIALIST CARDS', 'Drawn after a LOST heist — helps you on the next heist.',
                  AdvancedCards.specialistTitle, AdvancedCards.specialistRule),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
        ],
      ),
    );
  }

  Widget _buildHostControls(String phase, Map<String, dynamic> gameData, List<PlayerModel> players) {
    if (!isHost) return const SizedBox.shrink();

    final campaignOver = gameData['status'] == 'GAME_OVER';
    final canDealNewHand = campaignOver || phase == 'LOBBY' || phase == 'VERDICT';
    final advanced = gameData['advanced_mode'] == true;
    final sid = gameData['specialist_active'] as int?;
    final cid = gameData['challenge_active'] as int?;

    return Positioned(
      bottom: 120,
      right: 20,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // With Retina/Fingerprint the group vote resolves the showdown itself.
          if (phase == 'SHOWDOWN' && cid != 4 && cid != 9)
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.deepPurple),
              onPressed: _isBusy ? null : () => _runBusyAction(() => _resolveShowdownToVerdict(gameData)),
              child: const Text('Resolve showdown → verdict'),
            ),
          if (advanced && phase == 'PRE_FLOP' && sid == 3)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: OutlinedButton(
                onPressed: _isBusy ? null : () => _runBusyAction(() => _promptInvestorClaims(players)),
                child: const Text('Investor claims (#3)'),
              ),
            ),
          if (canDealNewHand)
            ElevatedButton(
              onPressed: _isBusy ? null : () => _runBusyAction(() async => widget.conn.dealInitialCards()),
              child: Text(campaignOver ? 'Start New Campaign' : 'Deal New Hand'),
            ),
          if (campaignOver)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Campaign finished\n(3 wins or 3 losses)',
                textAlign: TextAlign.right,
                style: TextStyle(color: Colors.red.shade200, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }

  Widget _challengeRail({required String phase, required Map<String, dynamic> gameData}) {
    final advanced = gameData['advanced_mode'] == true;
    if (!advanced || phase == 'LOBBY') return const SizedBox.shrink();

    final active = gameData['challenge_active'] as int?;
    final queued = gameData['challenge_queued'] as int?;
    final lines = <String>['CHALLENGE', '(left table)'];
    if (phase == 'GAME_OVER') {
      lines.add('—');
    } else if (active != null) {
      lines.add('#$active ${AdvancedCards.challengeTitle(active)}');
      lines.add('Active this heist');
    } else {
      lines.add('None active');
    }
    if (queued != null && phase == 'VERDICT') {
      lines.add('Next deal: #$queued');
    }

    return Container(
      width: 140,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.red.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.red.withValues(alpha: 0.35)),
      ),
      child: Text(lines.join('\n'), style: const TextStyle(color: Colors.white70, fontSize: 11, height: 1.25)),
    );
  }

  /// #3/#4/#8 are "declare a fact" specialists — normally said out loud, but
  /// players may be on separate devices/rooms over LAN and can't hear each
  /// other, so the host's recorded claim needs to actually show up here.
  String _nameForUserId(List<PlayerModel> players, String userId) {
    final match = players.where((p) => p.userId == userId).toList();
    return match.isEmpty ? '?' : match.first.displayName;
  }

  Widget _specialistRail({
    required String phase,
    required Map<String, dynamic> gameData,
    required List<PlayerModel> players,
  }) {
    final advanced = gameData['advanced_mode'] == true;
    if (!advanced || phase == 'LOBBY') return const SizedBox.shrink();

    final active = gameData['specialist_active'] as int?;
    final queued = gameData['specialist_queued'] as int?;
    final lines = <String>['SPECIALIST', '(right table)'];
    if (phase == 'GAME_OVER') {
      lines.add('—');
    } else if (active != null) {
      lines.add('#$active ${AdvancedCards.specialistTitle(active)}');
      lines.add('Active this heist');

      final aux = AdvancedAuxState.decode(gameData['advanced_aux']);
      if (active == 3 && aux['investor_claims'] is Map) {
        lines.add('—');
        (aux['investor_claims'] as Map).forEach((uid, count) => lines.add('${_nameForUserId(players, uid.toString())}: $count'));
      } else if (active == 8 && aux['math_whiz_claims'] is Map) {
        lines.add('—');
        (aux['math_whiz_claims'] as Map).forEach((uid, total) => lines.add('${_nameForUserId(players, uid.toString())}: $total'));
      } else if (active == 4 && aux['mastermind_player_id'] != null) {
        lines.add('—');
        final name = _nameForUserId(players, aux['mastermind_player_id'].toString());
        lines.add('$name: ${aux['mastermind_count']}× ${aux['mastermind_rank']}');
      }
    } else {
      lines.add('None active');
    }
    if (queued != null && phase == 'VERDICT') {
      lines.add('Next deal: #$queued');
    }

    return Container(
      width: 140,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.teal.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.teal.withValues(alpha: 0.35)),
      ),
      child: Text(lines.join('\n'), style: const TextStyle(color: Colors.white70, fontSize: 11, height: 1.25)),
    );
  }

  Future<void> _runBusyAction(Future<void> Function() action) async {
    setState(() => _isBusy = true);
    try {
      await action();
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A1A),
      body: StreamBuilder<Map<String, dynamic>>(
        stream: widget.conn.gameStream,
        initialData: widget.conn.currentGame,
        builder: (context, gameSnapshot) {
          if (!gameSnapshot.hasData) return const Center(child: CircularProgressIndicator());
          final gameData = gameSnapshot.data!;
          final phase = gameData['status'] as String? ?? 'LOBBY';
          final currentTurnUserId = gameData['current_turn_user_id'] as String?;
          final communityCards = List<String>.from(gameData['community_cards'] ?? []);
          final challActiveId = gameData['challenge_active'] as int?;

          return StreamBuilder<List<Map<String, dynamic>>>(
            stream: widget.conn.playersStream,
            initialData: widget.conn.currentPlayers,
            builder: (context, playerSnapshot) {
              final players = (playerSnapshot.data ?? []).map((p) => PlayerModel.fromMap(p)).toList();
              final vaultPreview = _evaluateMissionFromSnapshot(gameData, players);
              final aux = AdvancedAuxState.decode(gameData['advanced_aux']);

              return LayoutBuilder(builder: (context, box) {
              // Approximate center-pool chip positions (for flight animations).
              _poolChipPos.clear();
              final poolCap = _starCapForPlayerCount(players.length);
              for (var r = 1; r <= poolCap; r++) {
                _poolChipPos[r] = Offset(
                  box.maxWidth / 2 + (r - (poolCap + 1) / 2) * 75,
                  box.maxHeight / 2 + 150,
                );
              }
              return Stack(
                children: [
                  // 0. Table felt background
                  const Positioned.fill(child: _TableBackground()),

                  // 1. The Vault (Center)
                  Align(
                    alignment: Alignment.center,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text("THE VAULT", style: TextStyle(color: Colors.white, letterSpacing: 4, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 10),
                        _buildCommunityCards(communityCards, phase),
                        // Chips live in the middle of the table, under the vault.
                        if (_chipPhases.contains(phase)) ...[
                          const SizedBox(height: 14),
                          _buildChipPool(phase, currentTurnUserId, players),
                        ],
                        if (phase == 'VERDICT') ...[
                          const SizedBox(height: 20),
                          Text(
                            vaultPreview ? "MISSION SUCCESS" : "MISSION FAILED",
                            style: TextStyle(
                              color: vaultPreview ? Colors.green : Colors.red,
                              fontSize: 32,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                        if (phase == 'SHOWDOWN') ...[
                          const SizedBox(height: 16),
                          Text(
                            (challActiveId != null && (challActiveId == 4 || challActiveId == 9))
                                ? 'Table talk — agree guesses.\nHost taps Resolve after locking Retina / Fingerprint choices.'
                                : 'River settled.\nHost taps Resolve to score this heist.',
                            style: const TextStyle(color: Colors.white60, fontSize: 13),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            vaultPreview ? "(Chip ranking OK for vault)" : "(Chip ranking fails)",
                            style: TextStyle(
                              color: vaultPreview ? Colors.greenAccent : Colors.redAccent,
                              fontSize: 14,
                            ),
                          ),
                        ],
                        if (phase == 'GAME_OVER') ...[
                          const SizedBox(height: 20),
                          Text(
                            (gameData['last_heist_success'] == true) ? "LAST HEIST: SUCCESS" : "LAST HEIST: FAILED",
                            style: TextStyle(
                              color: (gameData['last_heist_success'] == true) ? Colors.greenAccent : Colors.redAccent,
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            'GAME OVER',
                            style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold, letterSpacing: 6),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Final score — WIN: ${gameData['win_score'] ?? 0} | LOSE: ${gameData['lose_score'] ?? 0}',
                            style: const TextStyle(color: Colors.white70, fontSize: 16),
                          ),
                        ]
                      ],
                    ),
                  ),

                  if (gameData['advanced_mode'] == true && phase != 'LOBBY')
                    Positioned(
                      left: 12,
                      top: 220,
                      child: _challengeRail(phase: phase, gameData: gameData),
                    ),
                  if (gameData['advanced_mode'] == true && phase != 'LOBBY')
                    Positioned(
                      right: 12,
                      top: 220,
                      child: _specialistRail(phase: phase, gameData: gameData, players: players),
                    ),

                  // 2. Player seats around the table
                  ..._buildSeats(
                    box: box,
                    players: players,
                    board: communityCards,
                    phase: phase,
                    chipPickTurnUserId: currentTurnUserId,
                    aux: aux,
                  ),

                  // 3. Score + room code (top-left)
                  Positioned(
                    top: 16, left: 20,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text("WIN: ${gameData['win_score'] ?? 0} | LOSE: ${gameData['lose_score'] ?? 0}",
                            style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 4),
                        Text('Room: ${gameData['room_code'] ?? '----'}',
                            style: const TextStyle(color: Colors.amberAccent, fontWeight: FontWeight.bold, fontSize: 15)),
                      ],
                    ),
                  ),

                  // 3a. Turn banner (top center)
                  if (_chipPhases.contains(phase))
                    Positioned(
                      top: 14, left: 160, right: 160,
                      child: _chipTurnBanner(phase, currentTurnUserId, players),
                    ),

                  // 3b. Rules + settings (top right)
                  Positioned(
                    top: 16, right: 20,
                    child: Row(
                      children: [
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white70,
                            backgroundColor: Colors.black38,
                            side: const BorderSide(color: Colors.white24),
                          ),
                          onPressed: _showRulesDialog,
                          icon: const Icon(Icons.menu_book, size: 16),
                          label: const Text('Rules'),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          style: IconButton.styleFrom(backgroundColor: Colors.black38),
                          color: Colors.white70,
                          onPressed: _showSettingsDialog,
                          icon: const Icon(Icons.settings, size: 20),
                          tooltip: 'Settings',
                        ),
                      ],
                    ),
                  ),

                  // 4. Host Controls
                  _buildHostControls(phase, gameData, players),

                  // 6. My Hand
                  _buildMyHand(players),

                  // 7. Chip flights (table -> seat, seat -> seat)
                  for (final f in _flights)
                    TweenAnimationBuilder<double>(
                      key: ValueKey('flight-${f.id}'),
                      tween: Tween(begin: 0.0, end: 1.0),
                      duration: const Duration(milliseconds: 500),
                      curve: Curves.easeInOutCubic,
                      onEnd: () {
                        if (mounted) setState(() => _flights.removeWhere((x) => x.id == f.id));
                      },
                      builder: (context, t, _) {
                        final pos = Offset.lerp(f.from, f.to, t)!;
                        final lift = sin(t * pi) * 36;
                        return Positioned(
                          left: pos.dx - 20,
                          top: pos.dy - 20 - lift,
                          child: IgnorePointer(
                            child: _roundChipFace(phase: f.phase, rank: f.rank, radius: 20, showSign: false),
                          ),
                        );
                      },
                    ),

                  // 8. Con Artist shuffle flourish
                  if (_shuffleFx)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Container(
                          color: Colors.black38,
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                TweenAnimationBuilder<double>(
                                  tween: Tween(begin: 0.0, end: 1.0),
                                  duration: const Duration(milliseconds: 1800),
                                  builder: (context, t, _) => Transform.rotate(
                                    angle: t * 4 * pi,
                                    child: Stack(
                                      alignment: Alignment.center,
                                      children: [
                                        for (var i = 0; i < 4; i++)
                                          Transform.rotate(
                                            angle: i * pi / 6 - pi / 4,
                                            child: const PlayingCardView(card: null, width: 70, height: 97),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 16),
                                const Text(
                                  'Con Artist shuffles all the pockets...',
                                  style: TextStyle(
                                      color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),

                  // 9. Group vote wheel (circle of choice)
                  _buildVoteOverlay(gameData, players),

                  // 10. Rule announcement — topmost, dismiss before voting.
                  _buildRuleAnnouncement(),
                ],
              );
              });
            },
          );
        },
      ),
    );
  }

  Widget _buildCommunityCards(List<String> cards, String phase) {
    int visible = {'PRE_FLOP': 0, 'FLOP': 3, 'TURN': 4, 'RIVER': 5, 'SHOWDOWN': 5, 'VERDICT': 5, 'GAME_OVER': 5}[phase] ?? 0;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(5, (index) {
        final isRevealed = index < visible && cards.isNotEmpty;
        final displayValue = isRevealed ? cards[index] : null;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 400),
            transitionBuilder: (child, anim) => ScaleTransition(
              scale: anim,
              child: FadeTransition(opacity: anim, child: child),
            ),
            child: PlayingCardView(
              key: ValueKey(displayValue ?? 'back-$index'),
              card: displayValue,
              width: 160,
              height: 222,
            ),
          ),
        );
      }),
    );
  }
}

/// Poker table felt, painted rather than a sourced image — no CC0-licensed
/// table/chair illustration turned up, and a gradient + rail outline reads
/// fine as a table backdrop without the licensing risk of a stock photo.
class _TableBackground extends StatelessWidget {
  const _TableBackground();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          radius: 1.1,
          colors: [Color(0xFF1F5C3D), Color(0xFF123524), Color(0xFF0B211A)],
          stops: [0.0, 0.7, 1.0],
        ),
      ),
      child: CustomPaint(painter: _TableRailPainter()),
    );
  }
}

class _ChipFlight {
  _ChipFlight(this.id, this.phase, this.rank, this.from, this.to);
  final int id;
  final String phase;
  final int rank;
  final Offset from;
  final Offset to;
}

class _TableRailPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final railRect = (Offset.zero & size).deflate(24);
    final railPaint = Paint()
      ..color = const Color(0xFF6B4226)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 18;
    canvas.drawOval(railRect, railPaint);
  }

  @override
  bool shouldRepaint(covariant _TableRailPainter oldDelegate) => false;
}
