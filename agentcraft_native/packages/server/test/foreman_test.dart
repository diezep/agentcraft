import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:agentcraft_native_server/foreman.dart';
import 'package:test/test.dart';

Json snapshot({List<Json> decisions = const []}) => {
      'v': 1,
      'type': 'snapshot',
      'foreman': {'backend': 'codex', 'auth': 'ok'},
      'agents': [
        {'id': 'marlow', 'name': 'Marlow'}
      ],
      'tasks': <Json>[],
      'decisions': decisions,
    };

void main() {
  test('free text only answers an open question, never a permission', () {
    final state = WorkshopState();
    state.apply(snapshot(decisions: [
      {
        'id': 'question',
        'status': 'open',
        'kind': 'question',
        'options': <String>[]
      },
      {
        'id': 'permission',
        'status': 'open',
        'kind': 'permission',
        'options': ['Allow', 'Deny']
      },
    ]));
    expect(state.reply('question', '  Use Dart  ')['text'], 'Use Dart');
    expect(() => state.reply('permission', 'yes'), throwsStateError);
    expect(() => state.reply('question', '  '), throwsStateError);
    state.synced = false;
    expect(() => state.reply('question', 'yes'), throwsStateError);
  });

  test('snapshot replaces stale state and closed decisions cannot be answered',
      () {
    final state = WorkshopState();
    state.apply(snapshot(decisions: [
      {
        'id': 'd1',
        'status': 'open',
        'options': ['Allow once', 'Deny']
      },
    ]));
    expect(state.answer('d1', 1)['option'], 'Deny');
    expect(() => state.answer('d1', 2), throwsStateError);
    state.apply({
      'v': 1,
      'type': 'decision.upsert',
      'decision': {
        'id': 'd1',
        'status': 'answered',
        'options': ['Allow once', 'Deny'],
      }
    });
    expect(() => state.answer('d1', 0), throwsStateError);
    state.apply(snapshot());
    expect(state.decisions, isEmpty);
    state.synced = false;
    expect(() => state.answer('d1', 0), throwsStateError);
  });

  test('WebSocket handshake, explicit mutation and acknowledgement', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final received = <Json>[];
    final ready = Completer<void>();
    WebSocket? peer;
    server.listen((request) async {
      peer = await WebSocketTransformer.upgrade(request);
      peer!.listen((dynamic raw) {
        final message = jsonDecode(raw as String) as Json;
        received.add(message);
        if (message['type'] == 'hello') {
          peer!.add(jsonEncode(snapshot()));
          ready.complete();
        } else {
          peer!.add(jsonEncode(
              {'v': 1, 'type': 'ack', 're': message['id'], 'ok': true}));
        }
      });
    });
    final notices = <String>[];
    final state = WorkshopState();
    final connection =
        ForemanConnection(state, onNotice: notices.add, port: server.port);
    addTearDown(() async {
      connection.stop();
      await peer?.close();
      await server.close(force: true);
    });
    connection.start();
    await ready.future.timeout(const Duration(seconds: 3));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(state.synced, isTrue);
    expect(received.single['protocol'], 1);
    connection.send({
      'type': 'goal.submit',
      'text': 'Inspect README',
      'repoId': 'agentcraft'
    }, 'Work order');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(notices, contains('Work order accepted.'));
    expect(received.last['repoId'], 'agentcraft');
    await peer!.close();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(state.synced, isFalse);
    expect(
        () =>
            connection.send({'type': 'goal.submit', 'text': 'x'}, 'Work order'),
        throwsStateError);
  });
}
