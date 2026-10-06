import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:agentcraft_dart/agentcraft_dart.dart';
import 'package:agentcraft_dart/src/launcher.dart';
import 'package:test/test.dart';
import 'server_test.dart' show Idle;

Future<ProcessResult> cli(List<String> args) => Process.run(
    Platform.resolvedExecutable, ['run', 'bin/foreman_dart.dart', ...args]);
void main() {
  test('every command exposes usable help and invalid options fail', () async {
    for (final command in [
      'serve',
      'ensure',
      'status',
      'send',
      'stop',
      'build-mod',
      'install-prism',
      'launch'
    ]) {
      final result = await cli([command, '--help']);
      expect(result.exitCode, 0, reason: '$command: ${result.stderr}');
      expect(result.stdout, contains('agentcraft $command'));
      expect(result.stdout, contains('--port'));
    }
    expect((await cli(['serve', '--port', '0'])).exitCode, 64);
    expect((await cli(['send'])).exitCode, 64);
  });
  test('CLI status, send, ensure, and stop talk to the Dart daemon', () async {
    final dir = await Directory.systemTemp.createTemp('dart-cli-');
    final fm = Foreman(StateStore(dir.path), Idle());
    final stopped = Completer<void>();
    final server = ForemanServer(fm, onStop: stopped.complete);
    final port = await server.start(0);
    addTearDown(() async {
      await server.close();
      await fm.close();
      fm.store.close();
      await dir.delete(recursive: true);
    });
    final status = await cli(['status', '--port', '$port']);
    expect(status.exitCode, 0);
    expect((jsonDecode(status.stdout as String) as Json)['type'], 'snapshot');
    await ensureForeman('/not-needed', [], port);
    final sent = await cli([
      'send',
      '--port',
      '$port',
      'user.message',
      '{"to":"marlow","text":"hello"}'
    ]);
    expect(sent.exitCode, 0);
    expect(fm.store.list('messages').single['text'], 'hello');
    expect((await cli(['stop', '--port', '$port'])).exitCode, 0);
    await stopped.future.timeout(const Duration(seconds: 3));
  });
  test('launcher shell arguments preserve apostrophes and metacharacters',
      () async {
    const value = "a'b \$HOME `whoami`";
    final result =
        await Process.run('/bin/sh', ['-c', 'printf %s ${shellQuote(value)}']);
    expect(result.stdout, value);
  });
}
