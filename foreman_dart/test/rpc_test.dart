import 'dart:async';
import 'dart:io';
import 'package:agentcraft_dart/agentcraft_dart.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  Future<CodexRpc> start() =>
      CodexRpc.start(Platform.resolvedExecutable, Directory.current.path,
          arguments: [p.absolute('test/fixtures/rpc_child.dart')]);
  test('server requests do not block response processing', () async {
    final rpc = await start();
    final answer = Completer<Object?>();
    rpc.requestHandler = (_, __) => answer.future;
    expect((await rpc.request('server-request', {}))['ok'], isTrue);
    expect((await rpc.request('ping', {}))['ok'], isTrue);
    answer.complete({'answer': 'yes'});
    await rpc.close();
  });
  test('process exit fails pending requests', () async {
    final rpc = await start();
    await expectLater(rpc.request('crash', {}), throwsStateError);
    await rpc.close();
  });
  test('invalid JSON fails transport instead of hanging', () async {
    final rpc = await start();
    await expectLater(rpc.request('invalid', {}), throwsFormatException);
    await rpc.close();
  });
}
