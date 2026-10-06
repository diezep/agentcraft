import 'dart:convert';
import 'dart:io';
import 'package:agentcraft_dart/agentcraft_dart.dart';
import 'package:test/test.dart';

class Idle implements AgentRuntime {
  @override
  Future<String> auth() async => 'ChatGPT';
  @override
  Future<String> run(Turn turn) async => '';
}

void main() {
  test(
      'server rejects browser origins, requires hello, and reports invalid intents',
      () async {
    final dir = await Directory.systemTemp.createTemp('dartcraft-server-');
    final store = StateStore(dir.path),
        fm = Foreman(StateStore('${dir.path}/other'), Idle());
    final server = ForemanServer(fm);
    final port = await server.start(0);
    addTearDown(() async {
      await server.close();
      await fm.close();
      fm.store.close();
      store.close();
      await dir.delete(recursive: true);
    });
    await expectLater(
        WebSocket.connect('ws://127.0.0.1:$port', headers: {'Origin': 'null'}),
        throwsA(isA<WebSocketException>()));
    final socket = await WebSocket.connect('ws://127.0.0.1:$port');
    socket.add(
        jsonEncode({'v': 1, 'type': 'goal.submit', 'text': 'no', 'id': 'x'}));
    final first = jsonDecode(await socket.first as String) as Json;
    expect(first['type'], 'error');
    await socket.close();
    expect((await intent(port, {'type': 'hello'}))['type'], 'snapshot');
    await expectLater(intent(port, {'type': 'unknown'}), throwsStateError);
  });
}
