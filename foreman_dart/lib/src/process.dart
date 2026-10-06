import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

Map<String, String> safeEnvironment(String cwd, String agent) {
  final env = Map<String, String>.from(Platform.environment);
  env.remove('OPENAI_API_KEY');
  for (final key in env.keys.toList()) {
    if (key.startsWith('GIT_')) env.remove(key);
  }
  final settings = {
    'protocol.allow': 'never',
    'url.agentcraft-blocked:///.pushInsteadOf': '',
    'commit.gpgsign': 'false',
    'tag.gpgsign': 'false',
    'gpg.program': 'agentcraft-signing-disabled',
    'gpg.ssh.program': 'agentcraft-signing-disabled',
  };
  var i = 0;
  for (final entry in settings.entries) {
    env['GIT_CONFIG_KEY_$i'] = entry.key;
    env['GIT_CONFIG_VALUE_${i++}'] = entry.value;
  }
  env.addAll({
    'GIT_CONFIG_COUNT': '$i',
    'GIT_ALLOW_PROTOCOL': 'agentcraft-none',
    'GIT_TERMINAL_PROMPT': '0',
    'GCM_INTERACTIVE': 'never',
    'GIT_CEILING_DIRECTORIES': p.dirname(cwd),
    'GIT_AUTHOR_NAME': 'AgentCraft $agent',
    'GIT_COMMITTER_NAME': 'AgentCraft $agent',
    'GIT_AUTHOR_EMAIL': '$agent@agentcraft.local',
    'GIT_COMMITTER_EMAIL': '$agent@agentcraft.local'
  });
  return env;
}

/// Track descendants before killing the parent; only processes owned by this run.
Future<void> killOwned(Process process) async {
  if (Platform.isWindows) {
    await Process.run('taskkill', ['/PID', '${process.pid}', '/T', '/F']);
    return;
  }
  final table = await Process.run('ps', ['-A', '-o', 'pid=,ppid=']);
  final parents = <int, List<int>>{};
  if (table.exitCode == 0) {
    for (final line in (table.stdout as String).split('\n')) {
      final fields = line.trim().split(RegExp(r'\s+'));
      if (fields.length != 2) continue;
      final pid = int.tryParse(fields[0]), parent = int.tryParse(fields[1]);
      if (pid != null && parent != null) (parents[parent] ??= []).add(pid);
    }
  }
  final owned = <int>[];
  void collect(int pid) {
    for (final child in parents[pid] ?? <int>[]) {
      collect(child);
      owned.add(child);
    }
  }

  collect(process.pid);
  // Stop the root first so it cannot spawn new descendants while we reap.
  Process.killPid(process.pid, ProcessSignal.sigstop);
  for (final pid in owned) {
    Process.killPid(pid, ProcessSignal.sigkill);
  }
  process.kill(ProcessSignal.sigkill);
  await process.exitCode;
}

class CommandResult {
  CommandResult(this.code, this.output);
  final int code;
  final String output;
}

Future<CommandResult> runCommand(
  String executable,
  List<String> arguments, {
  required String cwd,
  Map<String, String>? env,
  Duration timeout = const Duration(minutes: 5),
  Future<void>? cancel,
}) async {
  final child = await Process.start(executable, arguments,
      workingDirectory: cwd,
      environment: env,
      includeParentEnvironment: env == null);
  final chunks = <String>[];
  var size = 0;
  void append(String s) {
    chunks.add(s);
    size += s.length;
    while (size > 100000 && chunks.length > 1) {
      size -= chunks.removeAt(0).length;
    }
  }

  final out = child.stdout.transform(utf8.decoder).listen(append);
  final err = child.stderr.transform(utf8.decoder).listen(append);
  final outDone = out.asFuture<void>(), errDone = err.asFuture<void>();
  int code;
  try {
    code = await Future.any<int>([
      child.exitCode,
      if (cancel != null) cancel.then((_) => 130),
    ]).timeout(timeout);
    if (code == 130) await killOwned(child);
  } on TimeoutException {
    await killOwned(child);
    code = 124;
    append('\nCommand timed out.');
  }
  await outDone;
  await errDone;
  return CommandResult(code, chunks.join());
}
