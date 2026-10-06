import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:args/args.dart';
import 'package:io/io.dart';
import 'package:path/path.dart' as p;
import 'package:stack_trace/stack_trace.dart';
import 'package:agentcraft_dart/agentcraft_dart.dart';
import 'package:agentcraft_dart/src/launcher.dart';

Future<void> main(List<String> argv) async {
  try {
    await execute(argv);
  } on FormatException catch (e) {
    stderr.writeln('Usage error: ${e.message}');
    exitCode = ExitCode.usage.code;
  } on Object catch (e, stack) {
    stderr.writeln('$e\n${Trace.from(stack).terse}');
    exitCode = ExitCode.software.code;
  }
}

ArgParser options() => ArgParser()
  ..addFlag('help', abbr: 'h', negatable: false)
  ..addOption('port', defaultsTo: '7877', help: 'Loopback WebSocket port.')
  ..addOption('profile',
      defaultsTo: p.join(homeDirectory(), '.agentcraft/dart-native'),
      help: 'Dart profile directory (separate from legacy Foreman).')
  ..addMultiOption('repo', help: 'Local Git repository to register.')
  ..addOption('codex',
      defaultsTo: 'codex', help: 'Installed ChatGPT-authenticated Codex CLI.')
  ..addOption('model',
      help: 'Optional Codex model override; otherwise use account default.')
  ..addOption('workers', defaultsTo: '1', help: 'Active workers, from 1 to 5.')
  ..addOption('test-command',
      help: 'CI argument array as JSON, e.g. ["dart","test"]. No shell.')
  ..addOption('root',
      defaultsTo: p.absolute('..'),
      help: 'AgentCraft source checkout, for build/install.')
  ..addOption('binary', help: 'Compiled Dart executable, for Prism prelaunch.');
Future<void> execute(List<String> argv) async {
  final parser = ArgParser()..addFlag('help', abbr: 'h', negatable: false);
  for (final name in [
    'serve',
    'ensure',
    'status',
    'send',
    'stop',
    'build-mod',
    'install-prism',
    'launch'
  ]) {
    parser.addCommand(name, options());
  }
  final parsed = parser.parse(argv);
  if (parsed['help'] == true || parsed.command == null) {
    stdout.writeln('AgentCraft Dart\n\nUsage: agentcraft <command> [options]\n'
        'Commands: serve, ensure, status, send <type> <JSON>, stop, build-mod, install-prism, launch\n'
        'Use <command> --help for options. During development: dart run bin/foreman_dart.dart <command>.');
    return;
  }
  final args = parsed.command!, name = args.name!;
  if (args['help'] == true) {
    stdout.writeln('agentcraft $name\n${parser.commands[name]!.usage}');
    return;
  }
  final port = int.tryParse(args['port'] as String),
      workers = int.tryParse(args['workers'] as String);
  if (port == null ||
      port < 1 ||
      port > 65535 ||
      workers == null ||
      workers < 1 ||
      workers > 5) {
    throw FormatException('Invalid port or worker count');
  }
  final profile = p.absolute(args['profile'] as String),
      root = p.absolute(args['root'] as String);
  final codex = args['codex'] as String;
  switch (name) {
    case 'serve':
      final tests = args['test-command'] == null
          ? null
          : (jsonDecode(args['test-command'] as String) as List<dynamic>)
              .cast<String>();
      final store = StateStore(profile);
      final foreman = Foreman(
          store, CodexRuntime(command: codex, model: args['model'] as String?),
          workers: workers, testCommand: tests);
      final done = Completer<void>();
      final server = ForemanServer(foreman, onStop: () {
        if (!done.isCompleted) done.complete();
      });
      final subscriptions = <StreamSubscription<ProcessSignal>>[];
      try {
        for (final repo in args['repo'] as List<String>) {
          await foreman.repos.add(repo);
        }
        await server.start(port);
        File(p.join(profile, 'foreman.json')).writeAsStringSync(jsonEncode({
          'pid': pid,
          'port': port,
          'backend': 'dart-codex',
          'profile': profile
        }));
        stdout.writeln('AgentCraft Dart listening on ws://127.0.0.1:$port');
        for (final signal in [
          ProcessSignal.sigint,
          if (!Platform.isWindows) ProcessSignal.sigterm
        ]) {
          subscriptions.add(signal.watch().listen((_) {
            if (!done.isCompleted) done.complete();
          }));
        }
        await foreman.start();
        await done.future;
      } finally {
        for (final sub in subscriptions) {
          await sub.cancel();
        }
        await server.close();
        await foreman.close();
        store.close();
      }
    case 'status':
      stdout.writeln(const JsonEncoder.withIndent('  ')
          .convert(await intent(port, {'type': 'hello'})));
    case 'send':
      if (args.rest.length != 2) {
        throw FormatException('send requires <type> <JSON object>');
      }
      final payload = jsonDecode(args.rest[1]) as Json;
      stdout.writeln(
          jsonEncode(await intent(port, {...payload, 'type': args.rest[0]})));
    case 'stop':
      stdout.writeln(jsonEncode(await intent(port, {'type': 'daemon.stop'})));
    case 'ensure':
      if (Platform.script.path.endsWith('.dart')) {
        throw StateError('Compile with dart compile exe before using ensure');
      }
      final forward = argv.skip(1).toList();
      await ensureForeman(Platform.resolvedExecutable, forward, port);
      stdout.writeln('Dart Foreman ready on :$port');
    case 'build-mod':
      await buildMod(root);
      stdout.writeln('Redstone mod built.');
    case 'install-prism':
      final executable = p.absolute(args['binary'] as String? ??
          p.join(root, 'foreman_dart/build/agentcraft'));
      if (!File(executable).existsSync()) {
        throw StateError(
            'Compile the backend first: dart compile exe bin/foreman_dart.dart -o build/agentcraft');
      }
      // Resolve Codex now; Prism starts with a minimal PATH.
      final found = await Process.run('which', [codex]);
      if (found.exitCode != 0) throw StateError('Codex CLI not found');
      stdout.writeln(await installPrism(
          root, executable, (found.stdout as String).trim(), port, profile));
    case 'launch':
      await Process.start(
          '/Applications/Prism Launcher.app/Contents/MacOS/prismlauncher',
          ['--launch', 'AgentCraft-Dart-1.21.11', '--show-window'],
          mode: ProcessStartMode.detached);
  }
}
