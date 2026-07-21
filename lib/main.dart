import 'package:flutter/material.dart';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';
import 'advanced_cards.dart';
import 'game_screen.dart';
import 'lan/game_connection.dart';
import 'lan/relay_host.dart';
import 'lan/relay_remote.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TheGangApp());
}

class TheGangApp extends StatelessWidget {
  const TheGangApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'The Gang',
      theme: ThemeData.dark(useMaterial3: true),
      // Text-size setting from the in-game settings dialog, applied app-wide.
      builder: (context, child) => ValueListenableBuilder<double>(
        valueListenable: appTextScale,
        builder: (context, scale, _) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
      ),
      home: const EntryScreen(),
    );
  }
}

class EntryScreen extends StatefulWidget {
  const EntryScreen({super.key});

  @override
  State<EntryScreen> createState() => _EntryScreenState();
}

class _EntryScreenState extends State<EntryScreen> {
  final _nameController = TextEditingController();
  final _roomController = TextEditingController();
  bool _loading = false;
  // classic | advanced (ordered 1→10) | random | custom (forced cards, testing)
  String _mode = 'classic';
  int? _customChallenge = 1;
  int? _customSpecialist = 1;

  // Persistent identity: survives refresh/reopen so the engine recognizes a
  // returning player and lets them back into a running game.
  // (0xFFFFFFFF, not `1 << 32`: on the web shifts wrap at 32 bits -> 0.)
  String _playerId = 'guest_${Random.secure().nextInt(0xFFFFFFFF)}';
  SharedPreferences? _prefs;

  @override
  void initState() {
    super.initState();
    _restoreSession();
  }

  Future<void> _restoreSession() async {
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;
    final savedId = prefs.getString('player_id');
    if (savedId != null) {
      _playerId = savedId;
    } else {
      await prefs.setString('player_id', _playerId);
    }
    if (!mounted) return;
    setState(() {
      _nameController.text = prefs.getString('player_name') ?? '';
      _roomController.text = prefs.getString('last_room') ?? '';
    });

    // Auto-rejoin: if we were a guest in a room, walk straight back in.
    final lastRoom = prefs.getString('last_room');
    final role = prefs.getString('last_role');
    final name = _sanitizeName(_nameController.text);
    if (lastRoom == null || !_validRoom(lastRoom) || !_validName(name)) return;
    if (role != 'guest') {
      // A host's engine died with their tab; that room is gone.
      await prefs.remove('last_room');
      await prefs.remove('last_role');
      return;
    }
    await _withLoading(() async {
      final client = await RelayRemoteClient.join(
        roomCode: lastRoom,
        userId: _playerId,
        displayName: name,
      );
      final seated = client != null && client.currentPlayers.any((p) => p['user_id'] == _playerId);
      if (!seated) {
        client?.dispose();
        await prefs.remove('last_room');
        await prefs.remove('last_role');
        return;
      }
      _openRoom(conn: client, hostUserId: client.currentGame['host_user_id'] as String);
      _show('Reconnected to room $lastRoom');
    });
  }

  Future<void> _rememberRoom(String name, String roomCode, String role) async {
    final prefs = _prefs;
    if (prefs == null) return;
    await prefs.setString('player_name', name);
    await prefs.setString('last_room', roomCode);
    await prefs.setString('last_role', role);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _roomController.dispose();
    super.dispose();
  }

  String _sanitizeName(String name) => name.trim();
  String _sanitizeRoom(String room) => room.trim();

  bool _validName(String name) => name.isNotEmpty && name.length <= 8;
  bool _validRoom(String room) => RegExp(r'^\d{4}$').hasMatch(room);

  Future<void> _createRoom() async {
    final name = _sanitizeName(_nameController.text);
    if (!_validName(name)) {
      _show('Enter a name up to 8 chars.');
      return;
    }

    await _withLoading(() async {
      final host = await RelayHost.start(
        hostUserId: _playerId,
        hostDisplayName: name,
        advancedMode: _mode != 'classic',
        randomAdvanced: _mode == 'random',
        forcedChallenge: _mode == 'custom' ? _customChallenge : null,
        forcedSpecialist: _mode == 'custom' ? _customSpecialist : null,
      );
      await _rememberRoom(name, host.roomCode, 'host');
      _openRoom(conn: host, hostUserId: _playerId);
      _show('Room code: ${host.roomCode}');
    });
  }

  Future<void> _joinRoom() async {
    final name = _sanitizeName(_nameController.text);
    final roomCode = _sanitizeRoom(_roomController.text);
    if (!_validName(name)) {
      _show('Enter a name up to 8 chars.');
      return;
    }
    if (!_validRoom(roomCode)) {
      _show('Room ID must be 4 digits.');
      return;
    }

    await _withLoading(() async {
      final client = await RelayRemoteClient.join(
        roomCode: roomCode,
        userId: _playerId,
        displayName: name,
      );
      if (client == null) {
        _show('Room not found. Double-check the code with your host.');
        return;
      }
      // The engine only seats new players in the lobby; if we're not in the
      // player list, the game already started and this room is closed.
      final seated = client.currentPlayers.any((p) => p['user_id'] == _playerId);
      if (!seated) {
        client.dispose();
        _show('That game has already started — ask the host for a new room.');
        return;
      }
      await _rememberRoom(name, roomCode, 'guest');
      _openRoom(conn: client, hostUserId: client.currentGame['host_user_id'] as String);
    });
  }

  void _openRoom({required GameConnection conn, required String hostUserId}) {
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GameTableScreen(
          conn: conn,
          hostUserId: hostUserId,
          playerId: _playerId,
        ),
      ),
    );
  }

  Future<void> _withLoading(Future<void> Function() work) async {
    setState(() => _loading = true);
    try {
      await work();
    } catch (error) {
      _show(error.toString());
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  void _show(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('The Gang')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Share the 4-digit room code — friends join from anywhere.',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _nameController,
                  maxLength: 8,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    hintText: 'Max 8 chars',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _roomController,
                  keyboardType: TextInputType.number,
                  maxLength: 4,
                  decoration: const InputDecoration(
                    labelText: 'Room ID',
                    hintText: '4 digits',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _loading ? null : _joinRoom,
                    child: const Text('Join Room'),
                  ),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: _mode,
                  decoration: const InputDecoration(labelText: 'Game mode (host)', border: OutlineInputBorder()),
                  items: const [
                    DropdownMenuItem(value: 'classic', child: Text('Classic — no advanced cards')),
                    DropdownMenuItem(value: 'advanced', child: Text('Advanced — cards in order 1→10')),
                    DropdownMenuItem(value: 'random', child: Text('Advanced — cards in random order')),
                    DropdownMenuItem(value: 'custom', child: Text('Custom — pick the cards (testing)')),
                  ],
                  onChanged: _loading ? null : (v) => setState(() => _mode = v ?? 'classic'),
                ),
                if (_mode == 'custom') ...[
                  const SizedBox(height: 8),
                  DropdownButtonFormField<int?>(
                    initialValue: _customChallenge,
                    decoration: const InputDecoration(
                        labelText: 'Challenge after every WIN', border: OutlineInputBorder()),
                    items: [
                      const DropdownMenuItem(value: null, child: Text('None')),
                      for (var id = 1; id <= 10; id++)
                        DropdownMenuItem(value: id, child: Text('#$id ${AdvancedCards.challengeTitle(id)}')),
                    ],
                    onChanged: _loading ? null : (v) => setState(() => _customChallenge = v),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<int?>(
                    initialValue: _customSpecialist,
                    decoration: const InputDecoration(
                        labelText: 'Specialist after every LOSS', border: OutlineInputBorder()),
                    items: [
                      const DropdownMenuItem(value: null, child: Text('None')),
                      for (var id = 1; id <= 10; id++)
                        DropdownMenuItem(value: id, child: Text('#$id ${AdvancedCards.specialistTitle(id)}')),
                    ],
                    onChanged: _loading ? null : (v) => setState(() => _customSpecialist = v),
                  ),
                ],
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: _loading ? null : _createRoom,
                    child: const Text('Create Room (Host)'),
                  ),
                ),
                if (_loading) ...[
                  const SizedBox(height: 12),
                  const CircularProgressIndicator(),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
