import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'engine.dart';
import 'state.dart';

class ForemanServer {
  ForemanServer(this.foreman, {this.onStop});
  final void Function()? onStop;
  final Foreman foreman;
  HttpServer? _server;
  StreamSubscription<Json>? _subscription;
  final _clients = <WebSocket>{};
  final _ready = <WebSocket>{};
  Future<int> start(int port) async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _subscription = foreman.events.stream.listen((message) {
      for (final client in _ready.toList()) {
        _send(client, message);
      }
    });
    _server!.listen((request) async {
      final host = request.headers.value('host') ?? '';
      if (request.headers.value('origin') != null ||
          !RegExp(r'^(127\.0\.0\.1|localhost)(:\d+)?$').hasMatch(host)) {
        request.response.statusCode = 403;
        await request.response.close();
        return;
      }
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = 400;
        await request.response.close();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      socket.pingInterval = const Duration(seconds: 20);
      _clients.add(socket);
      // Serialize intents from each client; a held model approval never blocks this queue.
      var pending = Future<void>.value();
      socket.listen((dynamic raw) {
        pending = pending.then((_) async {
          String? id;
          try {
            if (raw is! String || raw.length > 1024 * 1024) {
              throw FormatException('Invalid frame');
            }
            final message = jsonDecode(raw) as Json;
            id = message['id'] as String?;
            if (!_ready.contains(socket) && message['type'] != 'hello') {
              throw StateError('Send hello first');
            }
            if (message['v'] != 1) throw FormatException('Protocol 1 required');
            if (message['type'] == 'daemon.stop' && onStop != null) {
              _send(socket, {
                'type': 'ack',
                're': id,
                'ok': true,
                'result': <String, dynamic>{}
              });
              Timer(const Duration(milliseconds: 100), onStop!);
              return;
            }
            final result = await foreman.handle(message);
            if (result['type'] is String) _send(socket, result);
            if (message['type'] == 'hello') _ready.add(socket);
            if (id != null) {
              _send(socket,
                  {'type': 'ack', 're': id, 'ok': true, 'result': result});
            }
          } on Object catch (e) {
            _send(socket, {
              'type': 'error',
              'message': e.toString(),
              if (id != null) 're': id
            });
            if (id != null) {
              _send(socket, {
                'type': 'ack',
                're': id,
                'ok': false,
                'error': e.toString()
              });
            }
          }
        });
      }, onDone: () {
        _clients.remove(socket);
        _ready.remove(socket);
      }, onError: (Object _) {
        _clients.remove(socket);
        _ready.remove(socket);
      });
    });
    return _server!.port;
  }

  void _send(WebSocket socket, Json message) {
    if (socket.readyState == WebSocket.open) {
      socket.add(jsonEncode({'v': 1, ...message}));
    }
  }

  Future<void> close() async {
    await _subscription?.cancel();
    for (final socket in _clients.toList()) {
      await socket.close();
    }
    await _server?.close(force: true);
  }
}

Future<Json> intent(int port, Json message) async {
  final socket = await WebSocket.connect('ws://127.0.0.1:$port')
      .timeout(const Duration(seconds: 3));
  final result = Completer<Json>();
  socket.listen((dynamic raw) {
    final msg = jsonDecode(raw as String) as Json;
    if (message['type'] == 'hello' && msg['type'] == 'snapshot') {
      result.complete(msg);
    }
    if (msg['type'] == 'snapshot' && message['type'] != 'hello') {
      socket.add(jsonEncode({'v': 1, ...message, 'id': 'cli'}));
    }
    if (msg['type'] == 'ack' && msg['re'] == 'cli' && !result.isCompleted) {
      if (msg['ok'] == true) {
        result.complete(msg['result'] as Json);
      } else {
        result.completeError(StateError('${msg['error']}'));
      }
    }
  }, onError: (Object e) {
    if (!result.isCompleted) result.completeError(e);
  }, onDone: () {
    if (!result.isCompleted) {
      result.completeError(StateError('Foreman disconnected'));
    }
  });
  socket.add(jsonEncode({
    'v': 1,
    'type': 'hello',
    'protocol': 1,
    'modVersion': 'dart-cli',
    'client': 'cli'
  }));
  try {
    return await result.future.timeout(const Duration(seconds: 30));
  } finally {
    await socket.close();
  }
}
