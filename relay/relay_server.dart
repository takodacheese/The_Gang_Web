import 'dart:convert';
import 'dart:io';

/// The Gang relay — the whole backend for the website version.
///
/// Dumb pipe, no game logic: the host player's browser runs GameEngine and
/// stays authoritative (same as the old LAN mode); this just introduces
/// browsers to each other because browsers can't listen for connections.
///
///   host  --ws-->  {"op":"host","roomCode":"1234"}   registers a room
///   guest --ws-->  {"op":"join","roomCode":"1234",...} forwarded to the host
///   guest ops (takeChip/stealChip) -> host; host messages -> all guests
///
/// Also serves the Flutter web build as static files, so one process is the
/// entire deployment:  dart run relay/relay_server.dart [webRoot]
///
/// ponytail: rooms live in memory — a relay restart drops running games.
/// Fine for friends-scale; add persistence only if that ever actually hurts.
final Map<String, _Room> _rooms = {};

class _Room {
  _Room(this.host);
  final WebSocket host;
  final Set<WebSocket> guests = {};
}

Future<void> main(List<String> args) async {
  final port = int.tryParse(Platform.environment['PORT'] ?? '') ?? 8080;
  final webRoot = args.isNotEmpty ? args[0] : 'build/web';
  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  // Gzip responses (2.7MB main.dart.js + 7.2MB canvaskit shrink ~4x) — without
  // this, first load on a small cloud instance feels like loading forever.
  server.autoCompress = true;
  print('The Gang relay listening on http://localhost:$port (web root: $webRoot)');

  await for (final request in server) {
    if (request.uri.path == '/ws' && WebSocketTransformer.isUpgradeRequest(request)) {
      WebSocketTransformer.upgrade(request).then(_handleSocket);
    } else {
      _serveStatic(request, webRoot);
    }
  }
}

void _handleSocket(WebSocket socket) {
  String? code; // room this socket ended up in
  var isHost = false;
  String? guestUserId; // from the join op, so drops can be reported to the host

  socket.listen(
    (raw) {
      Map<String, dynamic> msg;
      try {
        msg = jsonDecode(raw as String) as Map<String, dynamic>;
      } catch (_) {
        return;
      }

      if (code == null) {
        // First message picks the role.
        final wanted = msg['roomCode'] as String?;
        if (msg['op'] == 'host' && wanted != null && !_rooms.containsKey(wanted)) {
          _rooms[wanted] = _Room(socket);
          code = wanted;
          isHost = true;
          socket.add(jsonEncode({'type': 'hosted'}));
        } else if (msg['op'] == 'join' && wanted != null && _rooms.containsKey(wanted)) {
          code = wanted;
          guestUserId = msg['userId'] as String?;
          _rooms[wanted]!.guests.add(socket);
          _rooms[wanted]!.host.add(raw); // the join op doubles as the seat request
        } else {
          socket.add(jsonEncode({
            'type': 'error',
            'message': msg['op'] == 'host' ? 'code_taken' : 'room_not_found',
          }));
        }
        return;
      }

      final room = _rooms[code];
      if (room == null) return;
      if (isHost) {
        for (final guest in room.guests) {
          guest.add(raw); // snapshots fan out to everyone
        }
      } else {
        room.host.add(raw); // guest intents go to the host only
      }
    },
    onDone: () => _leave(code, isHost, socket, guestUserId),
    onError: (_) => _leave(code, isHost, socket, guestUserId),
  );
}

void _leave(String? code, bool isHost, WebSocket socket, String? guestUserId) {
  final room = code == null ? null : _rooms[code];
  if (room == null) return;
  if (isHost) {
    _rooms.remove(code);
    for (final guest in room.guests) {
      guest.add(jsonEncode({'type': 'error', 'message': 'host_left'}));
      guest.close();
    }
  } else {
    room.guests.remove(socket);
    // Tell the host so the engine can mark the seat as disconnected.
    if (guestUserId != null) {
      room.host.add(jsonEncode({'op': 'playerDropped', 'userId': guestUserId}));
    }
  }
}

Future<void> _serveStatic(HttpRequest request, String webRoot) async {
  final response = request.response;
  var path = request.uri.path == '/' ? '/index.html' : Uri.decodeComponent(request.uri.path);
  if (path.contains('..')) {
    response.statusCode = HttpStatus.forbidden;
    await response.close();
    return;
  }
  var file = File('$webRoot$path');
  if (!await file.exists()) {
    file = File('$webRoot/index.html'); // SPA fallback
    path = '/index.html';
  }
  if (!await file.exists()) {
    response.statusCode = HttpStatus.notFound;
    response.write('Not found — build the site first: flutter build web');
    await response.close();
    return;
  }
  response.headers.contentType = _contentTypeFor(path);
  await response.addStream(file.openRead());
  await response.close();
}

ContentType _contentTypeFor(String path) {
  final ext = path.split('.').last.toLowerCase();
  switch (ext) {
    case 'html':
      return ContentType.html;
    case 'js':
    case 'mjs':
      return ContentType('text', 'javascript', charset: 'utf-8');
    case 'css':
      return ContentType('text', 'css', charset: 'utf-8');
    case 'json':
      return ContentType.json;
    case 'png':
      return ContentType('image', 'png');
    case 'ico':
      return ContentType('image', 'x-icon');
    case 'svg':
      return ContentType('image', 'svg+xml');
    case 'wasm':
      return ContentType('application', 'wasm');
    case 'otf':
    case 'ttf':
      return ContentType('font', ext);
    default:
      return ContentType.binary;
  }
}
