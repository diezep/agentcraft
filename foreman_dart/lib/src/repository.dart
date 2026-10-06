import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'process.dart';
import 'state.dart';

class Repositories {
  Repositories(this.store, this.changed);
  final StateStore store;
  final void Function(Json) changed;
  final _merging = <String>{};
  Future<String> git(String cwd, List<String> args,
      {bool allowFailure = false}) async {
    final result = await runCommand('git', args,
        cwd: cwd, env: safeEnvironment(cwd, 'foreman'));
    if (result.code != 0 && !allowFailure) {
      throw StateError('git ${args.first}: ${result.output}');
    }
    return result.output.trim();
  }

  Json repo(String id) =>
      store.find('repos', id) ?? (throw StateError('Unknown repository $id'));
  Json worktree(Json repo, String id) =>
      rows(repo['worktrees']).firstWhere((w) => w['id'] == id,
          orElse: () => throw StateError('Unknown worktree $id'));
  Future<Json> add(String directory) async {
    final root =
        await git(p.absolute(directory), ['rev-parse', '--show-toplevel']);
    final existing = store.list('repos').where((r) => r['path'] == root);
    if (existing.isNotEmpty) return existing.first;
    final branch = await git(root, ['symbolic-ref', '--short', 'HEAD']);
    if (branch.isEmpty) {
      throw StateError('Repository needs a checked-out branch');
    }
    var id =
        p.basename(root).toLowerCase().replaceAll(RegExp('[^a-z0-9_-]'), '-');
    if (store.find('repos', id) != null) id = '$id-${store.id('repo')}';
    final value = <String, dynamic>{
      'id': id,
      'name': p.basename(root),
      'path': root,
      'branch': branch,
      'dirty': false,
      'ci': 'unknown',
      'worktrees': <Json>[]
    };
    store.list('repos').add(value);
    await refresh(value);
    return value;
  }

  Future<void> refresh(Json repo) async {
    final root = text(repo, 'path');
    repo['head'] = await git(root, ['rev-parse', '--short', 'HEAD']);
    repo['dirty'] = (await git(root, ['status', '--porcelain'])).isNotEmpty;
    changed(repo);
  }

  Future<Json> create(Json repo, Json task, String agent) async {
    if (task['worktree'] is String) {
      final existing = worktree(repo, text(task, 'worktree'));
      existing['agentId'] = agent;
      changed(repo);
      return existing;
    }
    final id = '$agent-${task['id']}';
    final directory = p.join(store.dir, 'worktrees', text(repo, 'id'), id);
    final branch = 'agentcraft-dart/$id';
    Directory(p.dirname(directory)).createSync(recursive: true);
    await git(text(repo, 'path'),
        ['worktree', 'add', '-b', branch, directory, text(repo, 'branch')]);
    final wt = <String, dynamic>{
      'id': id,
      'agentId': agent,
      'taskId': task['id'],
      'branch': branch,
      'base': repo['branch'],
      'path': directory,
      'status': 'active',
      'ahead': 0,
      'files': 0,
      'additions': 0,
      'deletions': 0
    };
    rows(repo['worktrees']).add(wt);
    task['worktree'] = id;
    task['branch'] = branch;
    changed(repo);
    return wt;
  }

  Future<void> commit(Json wt, String message) async {
    final cwd = text(wt, 'path');
    if (await git(cwd, ['symbolic-ref', '--short', 'HEAD']) != wt['branch']) {
      throw StateError('Worker left its assigned branch');
    }
    await git(cwd, ['add', '--all']);
    if ((await git(cwd, ['diff', '--cached', '--name-only'])).isNotEmpty) {
      await git(cwd, ['commit', '-m', message]);
    }
  }

  Future<String> diff(Json wt) async {
    final cwd = text(wt, 'path');
    // Include staged, unstaged, and untracked work by committing only once the worker exited.
    final base = wt['mergedBaseSha'] as String? ?? text(wt, 'base');
    final result =
        await git(cwd, ['diff', '--no-ext-diff', '--no-textconv', base, '--']);
    final nums = await git(cwd, ['diff', '--numstat', base, '--']);
    var files = 0, additions = 0, deletions = 0;
    for (final line in nums.split('\n').where((l) => l.isNotEmpty)) {
      final fields = line.split('\t');
      if (fields.length >= 3) {
        files++;
        additions += int.tryParse(fields[0]) ?? 0;
        deletions += int.tryParse(fields[1]) ?? 0;
      }
    }
    wt.addAll({'files': files, 'additions': additions, 'deletions': deletions});
    return result;
  }

  Future<CommandResult> test(Json wt, List<String>? configured,
      {Future<void>? cancel}) async {
    var cwd = text(wt, 'path');
    var argv = configured;
    if (argv == null) {
      if (!File(p.join(cwd, 'pubspec.yaml')).existsSync() &&
          File(p.join(cwd, 'foreman_dart/pubspec.yaml')).existsSync()) {
        cwd = p.join(cwd, 'foreman_dart');
      }
      if (File(p.join(cwd, 'pubspec.yaml')).existsSync()) {
        final dependencies = await runCommand('dart', ['pub', 'get'],
            cwd: cwd,
            env: safeEnvironment(cwd, text(wt, 'agentId')),
            cancel: cancel);
        if (dependencies.code != 0) return dependencies;
        argv = ['dart', 'test'];
      } else if (File(p.join(cwd, 'package.json')).existsSync()) {
        final package =
            jsonDecode(File(p.join(cwd, 'package.json')).readAsStringSync())
                as Json;
        if ((package['scripts'] as Json?)?['test'] != null) {
          final manager =
              (package['packageManager'] as String? ?? 'npm').split('@').first;
          argv = [manager, 'test'];
        }
      }
    }
    if (argv == null || argv.isEmpty) {
      return CommandResult(
          -1, 'No test command configured. Review must acknowledge this.');
    }
    return runCommand(argv.first, argv.skip(1).toList(),
        cwd: cwd,
        env: safeEnvironment(cwd, text(wt, 'agentId')),
        cancel: cancel,
        timeout: const Duration(minutes: 10));
  }

  Future<void> merge(Json repo, Json wt, String approvedHead) async {
    final id = text(repo, 'id');
    if (!_merging.add(id)) throw StateError('Another merge is in progress');
    try {
      final cwd = text(repo, 'path');
      await refresh(repo);
      if (repo['dirty'] == true) {
        throw StateError(
            'Your checkout has uncommitted changes. Commit or stash them before merging.');
      }
      if (await git(cwd, ['symbolic-ref', '--short', 'HEAD']) !=
          repo['branch']) {
        throw StateError('Base branch changed; merge refused');
      }
      if ((await git(text(wt, 'path'), ['status', '--porcelain'])).isNotEmpty ||
          await git(text(wt, 'path'), ['rev-parse', 'HEAD']) != approvedHead) {
        throw StateError(
            'Worker branch changed after review. Run review again.');
      }
      final base = await git(cwd, ['rev-parse', 'HEAD']);
      final result = await runCommand(
          'git', ['merge', '--no-ff', '--no-edit', text(wt, 'branch')],
          cwd: cwd, env: safeEnvironment(cwd, 'foreman'));
      if (result.code != 0) {
        await git(cwd, ['merge', '--abort'], allowFailure: true);
        throw StateError(
            'Merge conflict; base restored. ${short(result.output)}');
      }
      wt['status'] = 'merged';
      wt['mergedBaseSha'] = base;
      wt['mergedSha'] = await git(cwd, ['rev-parse', 'HEAD']);
      await refresh(repo);
    } finally {
      _merging.remove(id);
    }
  }
}
