import 'dart:async';
import 'dart:convert';
import 'dart:io';

typedef Json = Map<String, dynamic>;

/// Pure Dart protocol state, independent of Minecraft/JNI.
class WorkshopState {
  final agents = <String, Json>{};
  final tasks = <String, Json>{};
  final decisions = <String, Json>{};
  final logs = <String>[];
  bool synced = false;
  String backend = 'offline';
  String auth = 'unknown';

  Iterable<Json> get openDecisions =>
      decisions.values.where((d) => d['status'] == 'open');

  void apply(Json message) {
    if (message['v'] != 1) return;
    switch (message['type']) {
      case 'snapshot':
        for (final pair in [
          ('agents', agents),
          ('tasks', tasks),
          ('decisions', decisions),
        ]) {
          pair.$2.clear();
          for (final value in (message[pair.$1] as List<dynamic>? ?? [])) {
            final row = value as Json;
            pair.$2[row['id'] as String] = row;
          }
        }
        final foreman = message['foreman'] as Json? ?? {};
        backend = foreman['backend'] as String? ?? 'unknown';
        auth = foreman['auth'] as String? ?? 'unknown';
        synced = true;
      case 'foreman.status':
        final status = message['status'] as Json;
        backend = status['backend'] as String;
        auth = status['auth'] as String;
      case 'agent.upsert':
        final row = message['agent'] as Json;
        agents[row['id'] as String] = row;
      case 'task.upsert':
        final row = message['task'] as Json;
        tasks[row['id'] as String] = row;
      case 'decision.upsert':
        final row = message['decision'] as Json;
        decisions[row['id'] as String] = row;
      case 'agent.log':
        for (final entry in message['entries'] as List<dynamic>) {
          final row = entry as Json;
          logs.add('${message['agentId']}: ${row['text'] ?? ''}');
        }
        if (logs.length > 12) logs.removeRange(0, logs.length - 12);
    }
  }

  Json reply(String id, String text) {
    final decision = decisions[id];
    if (!synced ||
        decision == null ||
        decision['status'] != 'open' ||
        decision['kind'] != 'question' ||
        text.trim().isEmpty) {
      throw StateError('This question cannot be answered with that reply.');
    }
    return {'type': 'decision.answer', 'decisionId': id, 'text': text.trim()};
  }

  Json answer(String id, int option) {
    if (!synced) throw StateError('Foreman is disconnected.');
    final decision = decisions[id];
    if (decision == null || decision['status'] != 'open') {
      throw StateError('This request is no longer open.');
    }
    final options = decision['options'] as List<dynamic>;
    if (option < 0 || option >= options.length) {
      throw StateError('Choose one of the displayed answers.');
    }
    return {
      'type': 'decision.answer',
      'decisionId': id,
      'option': options[option]
    };
  }
}

class ForemanConnection {
  ForemanConnection(this.state, {required this.onNotice, this.port = 7878});
  final WorkshopState state;
  final void Function(String) onNotice;
  final int port;
  WebSocket? _socket;
  Timer? _retry;
  bool _running = false;
  int _generation = 0;
  int _nextId = 0;
  final _pending = <String, String>{};

  void start() {
    if (_running) return;
    _running = true;
    unawaited(_connect(++_generation));
  }

  void stop() {
    _running = false;
    _generation++;
    _retry?.cancel();
    unawaited(_socket?.close());
    _socket = null;
    state.synced = false;
    _pending.clear();
  }

  Future<void> _connect(int generation) async {
    try {
      final socket = await WebSocket.connect('ws://127.0.0.1:$port')
          .timeout(const Duration(seconds: 5));
      if (!_running || generation != _generation) {
        await socket.close();
        return;
      }
      _socket = socket;
      socket.add(jsonEncode({
        'v': 1,
        'type': 'hello',
        'protocol': 1,
        'modVersion': 'native-0.1.0',
        'client': 'redstone-dart'
      }));
      socket.listen((dynamic raw) {
        try {
          final message = jsonDecode(raw as String) as Json;
          state.apply(message);
          if (message['type'] == 'ack') {
            final label = _pending.remove(message['re']);
            if (label != null) {
              onNotice(message['ok'] == true
                  ? '$label accepted.'
                  : '$label failed: ${message['error'] ?? 'unknown error'}');
            }
          }
        } on Object catch (error) {
          onNotice('Could not read Foreman update: $error');
        }
      },
          onDone: () => _disconnected(generation),
          onError: (Object error) => _disconnected(generation),
          cancelOnError: true);
    } on Object {
      _disconnected(generation);
    }
  }

  void _disconnected(int generation) {
    if (!_running || generation != _generation) return;
    _socket = null;
    state.synced = false;
    if (_pending.isNotEmpty) {
      onNotice('Connection lost. Check status before retrying your request.');
    }
    _pending.clear(); // Never replay mutations automatically.
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 3), () => _connect(generation));
  }

  void send(Json payload, String label) {
    if (!state.synced || _socket == null) {
      throw StateError('Foreman is disconnected.');
    }
    final id = 'native-${++_nextId}';
    _pending[id] = label;
    _socket!.add(jsonEncode({'v': 1, 'id': id, ...payload}));
  }
}
