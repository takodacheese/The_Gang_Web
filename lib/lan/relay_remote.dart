import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'game_connection.dart';
import 'relay_host.dart';

/// The website-era replacement for LanRemoteClient: joins a room through the
/// relay by code (no discovery step — the relay knows the rooms). Still a thin
/// terminal: renders whatever the host broadcasts, sends intents back.
class RelayRemoteClient implements GameConnection {
  RelayRemoteClient._(this._channel);

  final WebSocketChannel _channel;
  final _gameCtrl = StreamController<Map<String, dynamic>>.broadcast();
  final _playersCtrl = StreamController<List<Map<String, dynamic>>>.broadcast();
  Map<String, dynamic> _lastGame = const {};
  List<Map<String, dynamic>> _lastPlayers = const [];

  /// Returns null if the room doesn't exist (or the relay is unreachable).
  static Future<RelayRemoteClient?> join({
    required String roomCode,
    required String userId,
    required String displayName,
    String? relayUrl,
  }) async {
    final channel = WebSocketChannel.connect(Uri.parse(relayUrl ?? defaultRelayUrl()));
    await channel.ready;
    final client = RelayRemoteClient._(channel);

    final first = Completer<bool>(); // true = first snapshot, false = rejected
    channel.stream.listen(
      (raw) {
        final msg = jsonDecode(raw as String) as Map<String, dynamic>;
        if (msg['type'] == 'snapshot') {
          client._apply(msg);
          if (!first.isCompleted) first.complete(true);
        } else if (msg['type'] == 'error') {
          // room_not_found during the handshake, or host_left mid-game.
          if (!first.isCompleted) {
            first.complete(false);
          } else {
            client._closeStreams();
          }
        }
      },
      onDone: client._closeStreams,
      onError: (_) => client._closeStreams(),
    );

    channel.sink.add(jsonEncode({
      'op': 'join',
      'roomCode': roomCode,
      'userId': userId,
      'displayName': displayName,
    }));

    final ok = await first.future.timeout(const Duration(seconds: 5), onTimeout: () => false);
    if (!ok) {
      channel.sink.close();
      return null;
    }
    return client;
  }

  void _apply(Map<String, dynamic> msg) {
    _lastGame = Map<String, dynamic>.from(msg['game'] as Map);
    _lastPlayers = (msg['players'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    _gameCtrl.add(_lastGame);
    _playersCtrl.add(_lastPlayers);
  }

  void _closeStreams() {
    if (!_gameCtrl.isClosed) _gameCtrl.close();
    if (!_playersCtrl.isClosed) _playersCtrl.close();
  }

  void _send(Map<String, dynamic> op) => _channel.sink.add(jsonEncode(op));

  @override
  Stream<Map<String, dynamic>> get gameStream => _gameCtrl.stream;
  @override
  Stream<List<Map<String, dynamic>>> get playersStream => _playersCtrl.stream;

  @override
  Map<String, dynamic> get currentGame => _lastGame;
  @override
  List<Map<String, dynamic>> get currentPlayers => _lastPlayers;

  @override
  void takeChip(String actingUserId, int rank, String phase) =>
      _send({'op': 'takeChip', 'userId': actingUserId, 'rank': rank, 'phase': phase});

  @override
  void stealChip(String actingUserId, int rank, String phase, String victimUserId) => _send({
        'op': 'stealChip',
        'userId': actingUserId,
        'rank': rank,
        'phase': phase,
        'victimUserId': victimUserId,
      });

  @override
  void sendEmote(String userId, String text) =>
      _send({'op': 'emote', 'userId': userId, 'text': text});

  @override
  void castVote(String userId, String option) =>
      _send({'op': 'vote', 'userId': userId, 'option': option});

  @override
  void confirmVote(String userId) => _send({'op': 'voteConfirm', 'userId': userId});

  @override
  void kickPlayer(String actingUserId, String targetUserId) => _hostOnly();

  // Host-only: the UI never shows these controls to a non-host player. If one of
  // these ever fires here, that's a UI gating bug, not a legitimate no-op.
  void _hostOnly() {
    assert(false, 'host-only GameConnection method called on a remote (guest) client');
  }

  @override
  void dealInitialCards() => _hostOnly();
  @override
  void resolveRetinaGuess(String rank) => _hostOnly();
  @override
  void resolveFingerprintGuess(int categoryIndex) => _hostOnly();
  @override
  void triggerVerdict() => _hostOnly();
  @override
  void setInvestorClaims(Map<String, int> claims) => _hostOnly();
  @override
  void setMathWhizClaims(Map<String, int> claims) => _hostOnly();
  @override
  void setMastermindClaim(String playerId, String rank, int count) => _hostOnly();

  @override
  void dispose() {
    _channel.sink.close();
  }
}
