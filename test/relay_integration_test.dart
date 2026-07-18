@Timeout(Duration(seconds: 60))
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:the_gang/lan/game_connection.dart';
import 'package:the_gang/lan/relay_host.dart';
import 'package:the_gang/lan/relay_remote.dart';

/// End-to-end over a real relay process: host a room, join it, deal, take and
/// steal chips, and check every change round-trips to the other side.
void main() {
  late String relayUrl;
  late Process relay;

  setUpAll(() async {
    // A hardcoded port collides with Windows' excluded ranges and leftover
    // listeners; ask the OS for a free one instead.
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    relayUrl = 'ws://localhost:$port/ws';

    relay = await Process.start(
      'dart',
      ['run', 'relay/relay_server.dart'],
      environment: {...Platform.environment, 'PORT': '$port'},
      runInShell: true, // Windows: resolve dart.bat from PATH
    );
    final ready = Completer<void>();
    relay.stdout.listen((chunk) {
      if (!ready.isCompleted && String.fromCharCodes(chunk).contains('listening')) ready.complete();
    });
    relay.stderr.listen((chunk) => stderr.add(chunk));
    await ready.future.timeout(const Duration(seconds: 30));
  });

  tearDownAll(() async {
    // runInShell means relay.kill() would only kill the shell wrapper and leak
    // the actual dart process (which keeps the port). Kill the whole tree.
    if (Platform.isWindows) {
      await Process.run('taskkill', ['/F', '/T', '/PID', '${relay.pid}']);
    } else {
      relay.kill();
    }
  });

  Future<List<Map<String, dynamic>>> waitPlayers(
    GameConnection conn,
    bool Function(List<Map<String, dynamic>>) pred,
  ) async {
    if (pred(conn.currentPlayers)) return conn.currentPlayers;
    return conn.playersStream.firstWhere(pred).timeout(const Duration(seconds: 10));
  }

  test('host and guest play a street over the relay', () async {
    final host = await RelayHost.start(
      hostUserId: 'h1',
      hostDisplayName: 'Hosty',
      advancedMode: false,
      relayUrl: relayUrl,
    );
    expect(host.roomCode, matches(r'^\d{4}$'));

    // Wrong code is rejected.
    final nobody = await RelayRemoteClient.join(
        roomCode: '0000', userId: 'gx', displayName: 'Nope', relayUrl: relayUrl);
    expect(nobody, isNull);

    final guest = await RelayRemoteClient.join(
        roomCode: host.roomCode, userId: 'g1', displayName: 'Guesty', relayUrl: relayUrl);
    expect(guest, isNotNull);

    // Both sides see both players.
    await waitPlayers(guest!, (ps) => ps.length == 2);
    await waitPlayers(host, (ps) => ps.length == 2);

    // Host deals; guest receives pocket cards through the relay.
    host.dealInitialCards();
    await waitPlayers(guest, (ps) => ps.every((p) => (p['hand_cards'] as List).length == 2));
    expect(guest.currentGame['status'], 'PRE_FLOP');

    // Chip actions are turn-based: whoever's turn it is takes chip 1.
    GameConnection actorOf(String userId) => userId == 'h1' ? host : guest;
    final first = guest.currentGame['current_turn_user_id'] as String;
    actorOf(first).takeChip(first, 1, 'PRE_FLOP');
    await waitPlayers(guest, (ps) => ps.any((p) => p['user_id'] == first && p['claim_preflop'] == 1));
    await waitPlayers(host, (ps) => ps.any((p) => p['user_id'] == first && p['claim_preflop'] == 1));

    // Second player steals chip 1 instead of taking chip 2.
    final second = first == 'h1' ? 'g1' : 'h1';
    actorOf(second).stealChip(second, 1, 'PRE_FLOP', first);
    await waitPlayers(guest, (ps) => ps.any((p) => p['user_id'] == second && p['claim_preflop'] == 1));
    await waitPlayers(guest, (ps) => ps.any((p) => p['user_id'] == first && p['claim_preflop'] == null));

    // Victim (now on turn again) takes chip 2 -> street complete -> FLOP.
    actorOf(first).takeChip(first, 2, 'PRE_FLOP');
    await guest.gameStream
        .firstWhere((g) => g['status'] == 'FLOP')
        .timeout(const Duration(seconds: 10));
    expect((guest.currentGame['community_cards'] as List).length, greaterThanOrEqualTo(3));

    host.dispose();
    guest.dispose();
  });
}
