import 'dart:async';
import 'dart:io';
import 'package:agentcraft_dart/agentcraft_dart.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Future<void> git(String cwd, List<String> args) async {
  final result = await Process.run('git', args, workingDirectory: cwd);
  if (result.exitCode != 0) throw StateError('${result.stderr}');
}

Future<void> until(bool Function() check) async {
  final end = DateTime.now().add(const Duration(seconds: 15));
  while (!check()) {
    if (DateTime.now().isAfter(end)) fail('Timed out waiting for workflow');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

class CodingFake implements AgentRuntime {
  @override
  Future<String> auth() async => 'ChatGPT · test';
  @override
  Future<String> run(Turn turn) async {
    turn.session('test-${turn.agent}');
    if (turn.prompt.startsWith('Plan')) {
      await turn.tool('write_memory',
          {'title': 'Plan: README', 'body': 'Add a result file.'});
      await turn.tool('create_task', {
        'title': 'Write result',
        'description': 'Create result.txt',
        'assignee': 'juniper'
      });
    } else if (turn.role == 'worker') {
      File(p.join(turn.cwd, 'result.txt'))
          .writeAsStringSync('Dart owns this workflow.\n');
      await turn.tool('update_task', {
        'task_id': 't1',
        'status': 'review',
        'summary': 'Created result.txt'
      });
    } else {
      await turn.tool('request_merge',
          {'task_id': 't1', 'summary': 'Reviewed the result.'});
    }
    return 'Done';
  }
}

void main() {
  late Directory temp;
  late String repo;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('dartcraft-test-');
    repo = p.join(temp.path, 'repo');
    Directory(repo).createSync();
    await git(repo, ['init', '-b', 'main']);
    await git(repo, ['config', 'user.name', 'Test']);
    await git(repo, ['config', 'user.email', 'test@example.invalid']);
    File(p.join(repo, 'README.md')).writeAsStringSync('Test repository.\n');
    await git(repo, ['add', '.']);
    await git(repo, ['commit', '-m', 'initial']);
  });
  tearDown(() => temp.delete(recursive: true));
  test(
      'plan → isolated worker → tests → review → explicit merge survives reload',
      () async {
    final store = StateStore(p.join(temp.path, 'profile'));
    final fm = Foreman(store, CodingFake(),
        testCommand: [Platform.resolvedExecutable, '--version']);
    await fm.repos.add(repo);
    await fm.start();
    await fm.handle({'v': 1, 'type': 'goal.submit', 'text': 'Create a result'});
    await until(() => store.list('decisions').any((d) => d['kind'] == 'merge'));
    final decision =
        store.list('decisions').firstWhere((d) => d['kind'] == 'merge');
    expect(File(p.join(repo, 'result.txt')).existsSync(), isFalse);
    expect(store.list('tasks').single['ci'], 'pass');
    await until(() => store.list('jobs').every((j) => j['status'] == 'done'));
    await fm.handle({
      'v': 1,
      'type': 'decision.answer',
      'decisionId': decision['id'],
      'option': 'Merge'
    });
    expect(File(p.join(repo, 'result.txt')).readAsStringSync(),
        'Dart owns this workflow.\n');
    expect(store.list('tasks').single['status'], 'done');
    expect(store.list('goals').single['progress'], 1);
    await fm.close();
    store.close();
    final reopened = StateStore(p.join(temp.path, 'profile'));
    expect(reopened.list('decisions').single['status'], 'answered');
    reopened.close();
  });
  test('dirty checkout refuses merge and leaves the decision open', () async {
    final store = StateStore(p.join(temp.path, 'profile'));
    final fm = Foreman(store, CodingFake(),
        testCommand: [Platform.resolvedExecutable, '--version']);
    await fm.repos.add(repo);
    await fm.start();
    await fm.handle({'v': 1, 'type': 'goal.submit', 'text': 'Create a result'});
    await until(() => store.list('decisions').any((d) => d['kind'] == 'merge'));
    await until(() => store.list('jobs').every((j) => j['status'] == 'done'));
    File(p.join(repo, 'README.md')).writeAsStringSync('Uncommitted user work');
    final d = store.list('decisions').single;
    await expectLater(
        fm.handle({
          'v': 1,
          'type': 'decision.answer',
          'decisionId': d['id'],
          'option': 'Merge'
        }),
        throwsStateError);
    expect(d['status'], 'open');
    expect(File(p.join(repo, 'result.txt')).existsSync(), isFalse);
    await fm.close();
    store.close();
  });
  test('changed reviewed head refuses merge', () async {
    final store = StateStore(p.join(temp.path, 'profile'));
    final fm = Foreman(store, CodingFake(),
        testCommand: [Platform.resolvedExecutable, '--version']);
    addTearDown(() async {
      await fm.close();
      store.close();
    });
    await fm.repos.add(repo);
    await fm.start();
    await fm.handle({'v': 1, 'type': 'goal.submit', 'text': 'Create a result'});
    await until(() =>
        store.list('decisions').isNotEmpty &&
        store.list('jobs').every((j) => j['status'] == 'done'));
    final wt = fm.repos.worktree(store.list('repos').single, 'juniper-t1');
    File(p.join(wt['path'] as String, 'later.txt'))
        .writeAsStringSync('unreviewed');
    await fm.repos.commit(wt, 'later edit');
    await expectLater(
        fm.handle({
          'v': 1,
          'type': 'decision.answer',
          'decisionId': 'd1',
          'option': 'Merge'
        }),
        throwsStateError);
    expect(store.list('decisions').single['status'], 'open');
    expect(File(p.join(repo, 'result.txt')).existsSync(), isFalse);
  });

  test('pause during CI stops command and does not schedule review', () async {
    final script = File(p.join(temp.path, 'slow.dart'))
      ..writeAsStringSync(
          "import 'dart:async'; Future<void> main() async { await Future<void>.delayed(Duration(minutes: 3)); }");
    final store = StateStore(p.join(temp.path, 'profile'));
    final fm = Foreman(store, CodingFake(),
        testCommand: [Platform.resolvedExecutable, script.path]);
    addTearDown(() async {
      await fm.close();
      store.close();
    });
    await fm.repos.add(repo);
    await fm.start();
    await fm.handle({'v': 1, 'type': 'goal.submit', 'text': 'Create a result'});
    await until(() => store.find('agents', 'juniper')?['state'] == 'testing');
    await fm
        .agentAction('juniper', 'pause')
        .timeout(const Duration(seconds: 5));
    expect(store.list('jobs').last['status'], 'paused');
    expect(store.list('decisions'), isEmpty);
    expect(store.find('agents', 'juniper')!['paused'], isTrue);
  });

  test('restart resumes interrupted worker in its original worktree and thread',
      () async {
    final profile = p.join(temp.path, 'profile');
    final store = StateStore(profile);
    final seed = Foreman(store, CodingFake());
    final r = await seed.repos.add(repo);
    final task = <String, dynamic>{
      'id': 't1',
      'title': 'resume',
      'status': 'doing',
      'repoId': r['id'],
      'assignee': 'juniper',
      'deps': <String>[],
      'priority': 0
    };
    store.list('tasks').add(task);
    final wt = await seed.repos.create(r, task, 'juniper');
    File(p.join(wt['path'] as String, 'unfinished.txt'))
        .writeAsStringSync('preserve');
    store.list('jobs').add({
      'id': 'job1',
      'kind': 'work',
      'agent': 'juniper',
      'taskId': 't1',
      'repoId': r['id'],
      'prompt': 'Resume',
      'status': 'running'
    });
    (store.data['sessions'] as Json)['juniper:t1'] = 'prior-thread';
    store.save();
    await seed.close();
    store.close();
    final runtime = RecoveryFake();
    final reopened = StateStore(profile);
    final recovered = Foreman(reopened, runtime);
    addTearDown(() async {
      await recovered.close();
      reopened.close();
    });
    await recovered.start();
    await until(() => runtime.seen != null);
    expect(runtime.seen!.resume, 'prior-thread');
    expect(runtime.seen!.cwd, wt['path']);
    expect(File(p.join(runtime.seen!.cwd, 'unfinished.txt')).readAsStringSync(),
        'preserve');
    await until(() => reopened.list('jobs').single['status'] == 'done');
  });
}

class RecoveryFake implements AgentRuntime {
  Turn? seen;
  @override
  Future<String> auth() async => 'ChatGPT';
  @override
  Future<String> run(Turn turn) async {
    seen = turn;
    return 'Paused for review';
  }
}
