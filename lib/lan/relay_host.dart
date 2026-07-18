import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'game_connection.dart';
import 'game_engine.dart';

/// Where to reach the relay (relay/relay_server.dart). On the web the relay is
/// whatever origin served the site itself, so this is zero-config; native/dev
/// runs fall back to localhost.
String defaultRelayUrl() {
  if (kIsWeb) {
    final base = Uri.base;
    final scheme = base.scheme == 'https' ? 'wss' : 'ws';
    return '$scheme://${base.host}:${base.port}/ws';
  }
  return 'ws://localhost:8080/ws';
}

/// The website-era replacement for LanHost: still the sole authority over game
/// state (GameEngine runs right here in the host player's browser tab), but
/// guests reach it through the relay instead of a LAN socket, because browsers
/// can't listen for connections.
class RelayHost implements GameConnection {
  RelayHost._(this._channel);

  final WebSocketChannel _channel;

  GameEngine? _engine;
  Completer<bool>? _handshake;

  final _gameCtrl = StreamController<Map<String, dynamic>>.broadcast();
  final _playersCtrl = StreamController<List<Map<String, dynamic>>>.broadcast();

  String get roomCode => _engine!.game['room_code'] as String;

  static Future<RelayHost> start({
    required String hostUserId,
    required String hostDisplayName,
    required bool advancedMode,
    bool randomAdvanced = false,
    int? forcedChallenge,
    int? forcedSpecialist,
    String? relayUrl,
  }) async {
    final channel = WebSocketChannel.connect(Uri.parse(relayUrl ?? defaultRelayUrl()));
    await channel.ready;
    final host = RelayHost._(channel);
    channel.stream.listen(
      host._onMessage,
      onDone: host._closeStreams,
      onError: (_) => host._closeStreams(),
    );

    // Register a room code; regenerate on the rare collision with a live room.
    for (var attempt = 0; attempt < 10; attempt++) {
      final code = (Random.secure().nextInt(9000) + 1000).toString();
      host._handshake = Completer<bool>();
      channel.sink.add(jsonEncode({'op': 'host', 'roomCode': code}));
      final accepted =
          await host._handshake!.future.timeout(const Duration(seconds: 5), onTimeout: () => false);
      if (accepted) {
        final engine = GameEngine(
          hostUserId: hostUserId,
          advancedMode: advancedMode,
          roomCode: code,
          randomAdvanced: randomAdvanced,
          forcedChallenge: forcedChallenge,
          forcedSpecialist: forcedSpecialist,
        );
        engine.upsertPlayer(hostUserId, hostDisplayName);
        host._engine = engine;
        host._publish();
        return host;
      }
    }
    channel.sink.close();
    throw Exception('Relay did not accept a room. Is the relay running?');
  }

  void _onMessage(dynamic raw) {
    final msg = jsonDecode(raw as String) as Map<String, dynamic>;
    switch (msg['type']) {
      case 'hosted':
        if (_handshake?.isCompleted == false) _handshake!.complete(true);
        return;
      case 'error':
        if (_handshake?.isCompleted == false) _handshake!.complete(false);
        return;
    }

    final engine = _engine;
    if (engine == null) return;
    switch (msg['op']) {
      case 'join':
        engine.upsertPlayer(msg['userId'] as String, msg['displayName'] as String);
        break;
      case 'takeChip':
        engine.takeChip(msg['userId'] as String, msg['rank'] as int, msg['phase'] as String);
        break;
      case 'stealChip':
        engine.stealChip(
          actingUserId: msg['userId'] as String,
          rank: msg['rank'] as int,
          phase: msg['phase'] as String,
          victimUserId: msg['victimUserId'] as String,
        );
        break;
      case 'emote':
        engine.emote(msg['userId'] as String, msg['text'] as String);
        break;
      case 'vote':
        engine.castVote(msg['userId'] as String, msg['option'] as String);
        break;
      case 'voteConfirm':
        engine.confirmVote(msg['userId'] as String);
        break;
      default:
        return;
    }
    _publish();
  }

  void _publish() {
    final engine = _engine!;
    _gameCtrl.add(Map<String, dynamic>.from(engine.game));
    _playersCtrl.add(engine.playersOrdered);
    _channel.sink.add(jsonEncode({
      'type': 'snapshot',
      'game': engine.game,
      'players': engine.playersOrdered,
    }));
  }

  void _closeStreams() {
    if (_handshake?.isCompleted == false) _handshake!.complete(false);
    if (!_gameCtrl.isClosed) _gameCtrl.close();
    if (!_playersCtrl.isClosed) _playersCtrl.close();
  }

  @override
  Stream<Map<String, dynamic>> get gameStream => _gameCtrl.stream;
  @override
  Stream<List<Map<String, dynamic>>> get playersStream => _playersCtrl.stream;

  @override
  Map<String, dynamic> get currentGame => Map<String, dynamic>.from(_engine!.game);
  @override
  List<Map<String, dynamic>> get currentPlayers => _engine!.playersOrdered;

  @override
  void takeChip(String actingUserId, int rank, String phase) {
    _engine!.takeChip(actingUserId, rank, phase);
    _publish();
  }

  @override
  void stealChip(String actingUserId, int rank, String phase, String victimUserId) {
    _engine!.stealChip(actingUserId: actingUserId, rank: rank, phase: phase, victimUserId: victimUserId);
    _publish();
  }

  @override
  void sendEmote(String userId, String text) {
    _engine!.emote(userId, text);
    _publish();
  }

  @override
  void castVote(String userId, String option) {
    _engine!.castVote(userId, option);
    _publish();
  }

  @override
  void confirmVote(String userId) {
    _engine!.confirmVote(userId);
    _publish();
  }

  @override
  void dealInitialCards() {
    _engine!.dealInitialCards();
    _publish();
  }

  @override
  void resolveRetinaGuess(String rank) {
    _engine!.resolveRetinaGuess(rank);
    _publish();
  }

  @override
  void resolveFingerprintGuess(int categoryIndex) {
    _engine!.resolveFingerprintGuess(categoryIndex);
    _publish();
  }

  @override
  void triggerVerdict() {
    _engine!.triggerVerdict();
    _publish();
  }

  @override
  void setInvestorClaims(Map<String, int> claims) {
    _engine!.setInvestorClaims(claims);
    _publish();
  }

  @override
  void setMathWhizClaims(Map<String, int> claims) {
    _engine!.setMathWhizClaims(claims);
    _publish();
  }

  @override
  void setMastermindClaim(String playerId, String rank, int count) {
    _engine!.setMastermindClaim(playerId, rank, count);
    _publish();
  }

  @override
  void dispose() {
    _channel.sink.close();
    _closeStreams();
  }
}
