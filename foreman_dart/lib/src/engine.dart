import 'dart:async';
import 'dart:convert';
import 'repository.dart';
import 'diff.dart';
import 'runtime.dart';
import 'state.dart';

const workerIds = ['juniper', 'kit', 'wren', 'rowan', 'tove'];
const mergeOptions = ['Merge', 'Request changes', 'Reject'];

class Foreman {
  Foreman(this.store, this.runtime, {this.workers = 1, this.testCommand}) {
    repos = Repositories(
        store, (repo) => emit({'type': 'repo.upsert', 'repo': repo}));
    if (store.list('agents').isEmpty) {
      final names = ['marlow', ...workerIds];
      final colors = [
        '#D97757',
        '#8FA98B',
        '#2FA3A0',
        '#C9A227',
        '#B4553A',
        '#6F8FB5'
      ];
      for (var i = 0; i < names.length; i++) {
        final id = names[i];
        store.list('agents').add({
          'id': id,
          'name': '${id[0].toUpperCase()}${id.substring(1)}',
          'role': i == 0 ? 'lead' : 'worker',
          'color': colors[i],
          'skin': id,
          'state': 'idle',
          'station': 'lounge',
          'activity': 'ready',
          'paused': false,
          'active': i <= workers
        });
      }
    }
  }
  final StateStore store;
  final AgentRuntime runtime;
  final int workers;
  final List<String>? testCommand;
  late final Repositories repos;
  final events = StreamController<Json>.broadcast(sync: true);
  final status = <String, dynamic>{
    'version': 'dart-0.1.0',
    'backend': 'codex',
    'auth': 'checking'
  };
  final _turns = <String, Turn>{};
  final _running = <String, Future<void>>{};
  final _stops = <String, Completer<void>>{};
  void stopRun(String id) {
    final stop = _stops[id];
    if (stop != null && !stop.isCompleted) stop.complete();
  }

  final _answers = <String, Completer<List<String>>>{};
  final _deciding = <String>{};
  bool _stopping = false, _scheduling = false;

  Json require(String collection, String id) =>
      store.find(collection, id) ??
      (throw StateError('Unknown $collection: $id'));
  void emit(Json message) {
    store.save();
    if (!events.isClosed) events.add({'v': 1, ...message});
  }

  void upsert(String collection, Json value) {
    if (collection == 'tasks') value['updatedAt'] = now();
    emit({
      'type': '${collection.substring(0, collection.length - 1)}.upsert',
      collection.substring(0, collection.length - 1): value
    });
  }

  void agent(String id, String state, String activity, {String? station}) {
    final value = require('agents', id);
    value.addAll({
      'state': state,
      'activity': short(activity, 80),
      'station': station ?? (id == 'marlow' ? 'meeting' : 'desk')
    });
    upsert('agents', value);
  }

  void log(String id, String kind, String message) {
    final logs = store.data['logs'] as Json;
    final tail = (logs[id] ??= <Json>[]) as List<dynamic>;
    final entry = {'ts': now(), 'kind': kind, 'text': short(message, 8000)};
    tail.add(entry);
    if (tail.length > 60) tail.removeAt(0);
    emit({
      'type': 'agent.log',
      'agentId': id,
      'entries': [entry]
    });
  }

  void feed(String kind, String message, {String? agentId}) {
    final entry = <String, dynamic>{
      'ts': now(),
      'kind': kind,
      'text': message,
      if (agentId != null) 'agentId': agentId
    };
    final feed = store.list('feed');
    feed.add(entry);
    if (feed.length > 200) feed.removeAt(0);
    emit({'type': 'feed.add', 'item': entry});
  }

  Json snapshot() => {
        'type': 'snapshot',
        'foreman': status,
        for (final key in [
          'agents',
          'tasks',
          'decisions',
          'repos',
          'goals',
          'memory',
          'feed'
        ])
          key: store.data[key],
        if (store.list('goals').isNotEmpty) 'goal': store.list('goals').last,
        'logs': [
          for (final entry in (store.data['logs'] as Json).entries)
            {'agentId': entry.key, 'entries': entry.value}
        ]
      };

  Future<void> start() async {
    for (final decision in store.list('decisions')) {
      if (decision['status'] == 'open' && decision['kind'] != 'merge') {
        decision['status'] = 'cancelled';
      }
    }
    for (final job in store.list('jobs')) {
      if (job['status'] == 'running') {
        job['status'] = 'queued';
        job['prompt'] =
            'The orchestrator restarted. Recheck current work and continue.\n${job['prompt']}';
      }
    }
    try {
      status.addAll({'auth': 'ok', 'account': await runtime.auth()});
    } on Object catch (e) {
      status.addAll({'auth': 'failed', 'message': e.toString()});
    }
    emit({'type': 'foreman.status', 'status': status});
    await schedule();
  }

  Future<void> close() async {
    _stopping = true;
    for (final id in _stops.keys.toList()) {
      stopRun(id);
    }
    for (final turn in _turns.values.toList()) {
      await turn.cancel();
    }
    for (final waiter in _answers.values) {
      if (!waiter.isCompleted) waiter.complete([]);
    }
    await Future.wait(_running.values.toList());
    store.save();
    await events.close();
  }

  Future<Json> handle(Json message) async {
    if (message['v'] != 1) throw FormatException('Protocol v=1 required');
    final type = text(message, 'type');
    switch (type) {
      case 'hello':
        if (message['protocol'] != 1) {
          throw FormatException('Protocol 1 required');
        }
        return snapshot();
      case 'repo.add':
        return {'repoId': (await repos.add(text(message, 'path')))['id']};
      case 'goal.submit':
        if (status['auth'] != 'ok') {
          throw StateError('${status['message'] ?? 'Codex is not ready'}');
        }
        final repository = message['repoId'] is String
            ? repos.repo(text(message, 'repoId'))
            : store.list('repos').lastOrNull;
        if (repository == null) throw StateError('Register a repository first');
        final goal = <String, dynamic>{
          'id': store.id('g'),
          'text': text(message, 'text'),
          'status': 'planning',
          'progress': 0,
          'repoId': repository['id'],
          'createdAt': now(),
          'updatedAt': now()
        };
        store.list('goals').add(goal);
        upsert('goals', goal);
        queue('plan', 'marlow',
            goal: goal,
            prompt:
                'Plan this goal: ${goal['text']}\nExplore the repository, write a plan to shared memory, create small tasks with acceptance criteria, then end your turn.');
        unawaited(schedule());
        return {'goalId': goal['id']};
      case 'decision.answer':
        await answer(message);
        return {};
      case 'agent.action':
        await agentAction(text(message, 'agentId'), text(message, 'action'));
        return {};
      case 'task.action':
        await taskAction(message);
        return {};
      case 'user.message':
        final to = text(message, 'to').toLowerCase();
        if (to != 'all') require('agents', to);
        send('user', to, text(message, 'text'));
        for (final a in store.list('agents').where(
            (a) => (to == 'all' || a['id'] == to) && a['active'] == true)) {
          if (a['id'] == 'marlow' && !_running.containsKey('marlow')) {
            final goal = store.list('goals').lastOrNull;
            if (goal != null) {
              queue('followup', 'marlow',
                  goal: goal, prompt: 'User message: ${message['text']}');
            }
          }
        }
        unawaited(schedule());
        return {};
      case 'diff.request':
        final repo = repos.repo(text(message, 'repoId'));
        final wt = repos.worktree(repo, text(message, 'worktree'));
        final diff = await repos.diff(wt);
        return {
          'type': 'diff',
          'requestId': text(message, 'requestId'),
          'repoId': repo['id'],
          'worktree': wt['id'],
          'base': wt['base'],
          'branch': wt['branch'],
          ...parseDiff(diff),
          'stats': {
            'files': wt['files'],
            'additions': wt['additions'],
            'deletions': wt['deletions']
          },
          'text': diff
        };
      default:
        throw FormatException('Unknown intent $type');
    }
  }

  void queue(String kind, String agentId,
      {Json? task, Json? goal, required String prompt}) {
    if (store.list('jobs').any((j) =>
        j['kind'] == kind &&
        j['agent'] == agentId &&
        j['taskId'] == task?['id'] &&
        j['goalId'] == goal?['id'] &&
        ['queued', 'running'].contains(j['status']))) {
      return;
    }
    store.list('jobs').add({
      'id': store.id('job'),
      'kind': kind,
      'agent': agentId,
      if (task != null) 'taskId': task['id'],
      if (goal != null) 'goalId': goal['id'],
      'repoId': task?['repoId'] ?? goal?['repoId'],
      'prompt': prompt,
      'status': 'queued'
    });
    store.save();
  }

  Future<void> schedule() async {
    if (_stopping || _scheduling || status['auth'] != 'ok') return;
    _scheduling = true;
    try {
      final todo = store
          .list('tasks')
          .where((t) => t['status'] == 'todo')
          .toList()
        ..sort(
            (a, b) => (b['priority'] as int).compareTo(a['priority'] as int));
      for (final task in todo) {
        if ((task['deps'] as List<dynamic>)
            .any((id) => require('tasks', id as String)['status'] != 'done')) {
          continue;
        }
        final available = store.list('agents').where((a) =>
            a['role'] == 'worker' &&
            a['active'] == true &&
            a['paused'] != true &&
            !_running.containsKey(a['id']) &&
            !store.list('jobs').any((j) =>
                j['agent'] == a['id'] &&
                ['queued', 'running', 'paused'].contains(j['status'])) &&
            (task['assignee'] == null || task['assignee'] == a['id']));
        if (available.isEmpty) continue;
        final id = text(available.first, 'id');
        task['assignee'] = id;
        task['status'] = 'doing';
        queue('work', id,
            task: task,
            prompt:
                'Implement task ${task['id']}: ${task['title']}\n${task['description'] ?? ''}\nWhen finished call update_task with status review and a summary.');
        upsert('tasks', task);
      }
      for (final job in store
          .list('jobs')
          .where((j) => j['status'] == 'queued')
          .toList()) {
        final id = text(job, 'agent'),
            a = require('agents', text(job, 'agent'));
        if (_running.containsKey(id) ||
            a['paused'] == true ||
            a['active'] != true) {
          continue;
        }
        job['status'] = 'running';
        store.save();
        final future = _run(job);
        _running[id] = future;
        unawaited(future.whenComplete(() {
          _running.remove(id);
          unawaited(schedule());
        }));
      }
    } finally {
      _scheduling = false;
    }
  }

  Future<void> _run(Json job) async {
    final id = text(job, 'agent');
    final stop = Completer<void>();
    _stops[id] = stop;
    Json? task;
    try {
      task = job['taskId'] is String
          ? require('tasks', text(job, 'taskId'))
          : null;
      final repo = repos.repo(text(job, 'repoId'));
      final role = id == 'marlow' ? 'lead' : 'worker';
      final wt = role == 'worker' ? await repos.create(repo, task!, id) : null;
      final cwd = wt == null ? text(repo, 'path') : text(wt, 'path');
      if (job['status'] != 'running' || _stopping) return;
      final key = '$id:${task?['id'] ?? job['goalId']}';
      final sessions = store.data['sessions'] as Json;
      final history = store
          .list('decisions')
          .where((d) => d['taskId'] == task?['id'] && d['status'] == 'answered')
          .map((d) => '${d['question']}: ${d['answer']}')
          .join('\n');
      agent(id, 'thinking', '${job['kind']} ${task?['id'] ?? job['goalId']}');
      final a = require('agents', id);
      a.addAll({
        'repoId': repo['id'],
        if (task != null) 'taskId': task['id'],
        if (wt != null) 'worktree': wt['id']
      });
      upsert('agents', a);
      final turn = Turn(
          agent: id,
          cwd: cwd,
          role: role,
          prompt:
              '${job['prompt']}\nPrior answers: $history\nMemory: ${jsonEncode(store.list('memory').where((m) => m['scope'] == 'shared' || m['agentId'] == id).toList())}\nTask board: ${jsonEncode(store.data['tasks'])}\nUnread messages: ${inbox(id)}',
          instructions: role == 'lead'
              ? 'You are Marlow, the read-only team lead. Workers: ${store.list('agents').where((a) => a['role'] == 'worker' && a['active'] == true).map((a) => a['id']).join(', ')}. Create tasks, review changes and request a user-approved merge. Never edit files or push. Use tools for plans and coordination. End after the current job. Do not invent work for a simple greeting.'
              : 'You are $id, a worker. Only edit this worktree: $cwd. Never push, fetch, deploy, modify .git, or change branch. Run appropriate tests. Report review with update_task when done. Ask user only for decisions you cannot infer. Base branch: ${wt!['base']}.',
          resume: sessions[key] as String?,
          tools: tools(role),
          tool: (name, args) => tool(job, name, args),
          ask: (kind, question, options, context) =>
              ask(job, kind, question, options, context),
          log: (kind, value) {
            log(id, kind, value);
            if (kind == 'tool' &&
                require('agents', id)['state'] != 'waiting_user') {
              agent(id, 'running', value);
            }
          },
          session: (session) {
            sessions[key] = session;
            store.save();
          });
      _turns[id] = turn;
      final summary = await runtime.run(turn);
      if (job['status'] != 'running' || _stopping) return;
      if (job['kind'] == 'plan') {
        final goal = require('goals', text(job, 'goalId'));
        goal['status'] =
            store.list('tasks').any((t) => t['goalId'] == goal['id'])
                ? 'active'
                : 'done';
        if (goal['status'] == 'done') goal['progress'] = 1;
        upsert('goals', goal);
      }
      if (role == 'worker' && task != null) {
        if (task['status'] == 'doing') {
          task['status'] = 'blocked';
          task['blockedReason'] =
              'Worker ended without reporting completion. Retry to continue.';
          task['summary'] = summary;
          upsert('tasks', task);
        }
        if (task['status'] == 'review') {
          await repos.commit(wt!, 'agentcraft: ${task['id']} ${task['title']}');
          agent(id, 'testing', 'Testing ${task['id']}', station: 'testbench');
          final ci = await repos.test(wt, testCommand, cancel: stop.future);
          if (task['status'] != 'review' ||
              job['status'] != 'running' ||
              _stopping) {
            return;
          }
          task['ci'] = ci.code == 0
              ? 'pass'
              : ci.code == -1
                  ? 'unknown'
                  : 'fail';
          task['testOutput'] = short(ci.output, 6000);
          upsert('tasks', task);
          final diff = await repos.diff(wt);
          upsert('repos', repo);
          if (diff.isEmpty) {
            task['status'] = 'done';
            wt['status'] = 'abandoned';
            upsert('tasks', task);
            updateGoals();
          } else {
            queue('review', 'marlow',
                task: task,
                prompt:
                    'Review ${task['id']}: ${task['title']}\nSummary: ${task['summary']}\nTests: ${task['ci']}\n${task['testOutput']}\nDiff:\n${short(diff, 40000)}\nCall request_merge if acceptable; otherwise update_task doing with specific feedback.');
          }
        }
      }
      if (job['status'] != 'running' || _stopping) return;
      job['status'] = 'done';
      agent(id, 'idle', '${job['kind']} finished', station: 'lounge');
    } on Object catch (e) {
      if (_stopping) {
        job['status'] = 'queued';
      } else if (job['status'] == 'running' || job['status'] == 'done') {
        job['status'] = 'failed';
        log(id, 'error', e.toString());
        agent(id, 'error', e.toString());
        if (task != null && !['done', 'cancelled'].contains(task['status'])) {
          task['status'] = 'blocked';
          task['blockedReason'] = e.toString();
          upsert('tasks', task);
        } else if (job['goalId'] is String) {
          final goal = require('goals', text(job, 'goalId'));
          goal['status'] = 'failed';
          upsert('goals', goal);
        }
      }
    } finally {
      _turns.remove(id);
      _stops.remove(id);
      for (final decision in store.list('decisions').where((d) =>
          d['jobId'] == job['id'] &&
          d['status'] == 'open' &&
          d['kind'] != 'merge')) {
        decision['status'] = 'cancelled';
        _answers.remove(decision['id'])?.complete([]);
        upsert('decisions', decision);
      }
      store.save();
    }
  }

  void send(String from, String to, String value) {
    store.list('messages').add({
      'id': store.id('msg'),
      'from': from,
      'to': to,
      'text': value,
      'readBy': <String>[]
    });
    feed('message', value, agentId: from);
    emit({
      'type': 'agent.say',
      'agentId': from,
      'to': to,
      'text': value,
      'ts': now()
    });
  }

  String inbox(String id) {
    final messages = store
        .list('messages')
        .where((m) =>
            m['from'] != id &&
            (m['to'] == id || m['to'] == 'all') &&
            !(m['readBy'] as List<dynamic>).contains(id))
        .toList();
    for (final message in messages) {
      (message['readBy'] as List<dynamic>).add(id);
    }
    store.save();
    return messages.map((m) => '${m['from']}: ${m['text']}').join('\n');
  }

  Json decision(Json job, String kind, String question, List<String> options,
      String context,
      {Json extra = const {}, bool publish = true}) {
    final d = <String, dynamic>{
      'id': store.id('d'),
      'agentId': job['agent'],
      'jobId': job['id'],
      'kind': kind,
      'question': question,
      'options': options,
      'context': context,
      'status': 'open',
      'createdAt': now(),
      if (job['taskId'] != null) 'taskId': job['taskId'],
      'repoId': job['repoId'],
      ...extra
    };
    store.list('decisions').add(d);
    if (publish) upsert('decisions', d);
    return d;
  }

  Future<List<String>> ask(Json job, String kind, String question,
      List<String> options, String context) async {
    if (job['status'] != 'running') throw StateError('Turn stopped');
    final d = decision(job, kind, question, options, context, publish: false);
    final result = Completer<List<String>>();
    _answers[text(d, 'id')] = result;
    upsert('decisions', d);
    agent(text(job, 'agent'), 'waiting_user', question, station: 'user');
    try {
      return await result.future;
    } finally {
      _answers.remove(d['id']);
      if (job['status'] == 'running') {
        agent(text(job, 'agent'), 'thinking', 'Continuing');
      }
    }
  }

  Future<void> answer(Json message) async {
    final id = text(message, 'decisionId'),
        d = require('decisions', text(message, 'decisionId'));
    if (d['status'] != 'open' || !_deciding.add(id)) {
      throw StateError('Request no longer open');
    }
    try {
      final options = (d['options'] as List<dynamic>).cast<String>();
      var option = message['option'];
      if (option is int && option >= 0 && option < options.length) {
        option = options[option];
      }
      if (option != null && (option is! String || !options.contains(option))) {
        throw FormatException('Invalid option');
      }
      final reply = message['text'] as String?;
      if (d['kind'] != 'question' && option == null) {
        throw FormatException('Choose an explicit option');
      }
      if (option == null && (reply == null || reply.trim().isEmpty)) {
        throw FormatException('Answer required');
      }
      if (d['kind'] == 'merge') {
        final task = require('tasks', text(d, 'taskId'));
        if (task['status'] != 'review') {
          throw StateError('Task is no longer in review');
        }
        if (option == 'Merge') {
          final repo = repos.repo(text(task, 'repoId')),
              wt = repos.worktree(
                  repos.repo(text(task, 'repoId')), text(task, 'worktree'));
          if (_running.containsKey(task['assignee'])) {
            throw StateError('Worker still running');
          }
          await repos.merge(repo, wt, text(d, 'head'));
          task['status'] = 'done';
        } else if (option == 'Request changes') {
          task['status'] = 'todo';
          task['summary'] = reply ?? 'User requested changes';
        } else {
          task['status'] = 'cancelled';
        }
        upsert('tasks', task);
        updateGoals();
      }
      d['status'] = 'answered';
      d['answer'] = {
        'ts': now(),
        if (option != null) 'option': option,
        if (reply != null) 'text': reply
      };
      upsert('decisions', d);
      _answers
          .remove(id)
          ?.complete([if (option is String) option, if (reply != null) reply]);
      unawaited(schedule());
    } finally {
      _deciding.remove(id);
    }
  }

  Future<void> agentAction(String id, String action) async {
    final a = require('agents', id);
    if (!['pause', 'resume', 'stop', 'spawn'].contains(action)) {
      throw FormatException('Unknown agent action');
    }
    if (action == 'pause' || action == 'stop') {
      a['paused'] = action == 'pause';
      if (action == 'stop') a['active'] = false;
      for (final job in store.list('jobs').where((j) =>
          j['agent'] == id && ['queued', 'running'].contains(j['status']))) {
        job['status'] = 'paused';
      }
      stopRun(id);
      await _turns[id]?.cancel();
      await _running[id];
      agent(id, 'idle', action == 'stop' ? 'Off shift' : 'Paused',
          station: 'lounge');
    } else {
      a['paused'] = false;
      a['active'] = true;
      for (final job in store
          .list('jobs')
          .where((j) => j['agent'] == id && j['status'] == 'paused')) {
        job['status'] = 'queued';
      }
      agent(id, 'idle', 'Ready');
      unawaited(schedule());
    }
  }

  Future<void> taskAction(Json message) async {
    final t = require('tasks', text(message, 'taskId')),
        action = text(message, 'action');
    if (store
        .list('decisions')
        .any((d) => d['taskId'] == t['id'] && _deciding.contains(d['id']))) {
      throw StateError('A decision for this task is being applied');
    }
    if (['done', 'cancelled'].contains(t['status'])) {
      throw StateError('Task is terminal');
    }
    if (!['cancel', 'retry', 'reassign', 'prioritize'].contains(action)) {
      throw FormatException('Unknown task action');
    }
    if (action == 'prioritize') {
      t['priority'] = (t['priority'] as int) + 1;
    } else {
      if (action == 'reassign') {
        final a = require('agents', text(message, 'arg'));
        if (a['role'] != 'worker') throw StateError('Choose a worker');
      }
      for (final job in store.list('jobs').where((j) =>
          j['taskId'] == t['id'] &&
          ['queued', 'running', 'paused'].contains(j['status']))) {
        job['status'] = 'cancelled';
        stopRun(text(job, 'agent'));
        await _turns[job['agent']]?.cancel();
        await _running[job['agent']];
      }
      for (final d in store
          .list('decisions')
          .where((d) => d['taskId'] == t['id'] && d['status'] == 'open')) {
        d['status'] = 'cancelled';
        _answers.remove(d['id'])?.complete([]);
        upsert('decisions', d);
      }
      t['status'] = action == 'cancel' ? 'cancelled' : 'todo';
      if (action == 'reassign') t['assignee'] = message['arg'];
    }
    upsert('tasks', t);
    updateGoals();
    unawaited(schedule());
  }

  void updateGoals() {
    for (final goal in store.list('goals')) {
      final tasks =
          store.list('tasks').where((t) => t['goalId'] == goal['id']).toList();
      if (tasks.isEmpty) continue;
      final done = tasks
          .where((t) => ['done', 'cancelled'].contains(t['status']))
          .length;
      goal['progress'] = done / tasks.length;
      goal['status'] = done == tasks.length ? 'done' : 'active';
      upsert('goals', goal);
    }
  }

  List<Json> tools(String role) {
    Json str([List<String>? values]) =>
        {'type': 'string', if (values != null) 'enum': values};
    Json strings() => {'type': 'array', 'items': str()};
    Json definition(String name, String description, Json properties,
            List<String> required) =>
        {
          'type': 'function',
          'name': name,
          'description': description,
          'deferLoading': false,
          'inputSchema': {
            'type': 'object',
            'properties': properties,
            'required': required,
            'additionalProperties': false
          }
        };
    return [
      definition('report_status', 'Report a short progress update.',
          {'activity': str()}, ['activity']),
      definition('list_tasks', 'Read the current task board.', {}, []),
      definition(
          'send_message',
          'Send a short message to user, all, marlow or a worker.',
          {'to': str(), 'text': str()},
          ['to', 'text']),
      definition(
          'ask_user',
          'Ask a question and wait for an answer.',
          {'question': str(), 'options': strings(), 'context': str()},
          ['question']),
      definition('write_memory', 'Save a plan or reusable knowledge.', {
        'title': str(),
        'body': str(),
        'scope': str(['shared', 'private'])
      }, [
        'title',
        'body'
      ]),
      definition('read_memory', 'Read saved team knowledge.', {}, []),
      definition('update_task',
          'Report review, blocked, or request changes (lead only).', {
        'task_id': str(),
        'status': str(['review', 'blocked', 'doing']),
        'summary': str(),
        'blocked_reason': str()
      }, [
        'task_id',
        'status'
      ]),
      if (role == 'lead') ...[
        definition(
            'create_task',
            'Create a small task with acceptance criteria and optional dependencies.',
            {
              'title': str(),
              'description': str(),
              'assignee': str(workerIds),
              'deps': strings()
            },
            [
              'title',
              'description'
            ]),
        definition(
            'request_merge',
            'Ask the user to approve a reviewed branch. Never merge automatically.',
            {'task_id': str(), 'summary': str()},
            ['task_id', 'summary']),
      ],
    ];
  }

  Future<String> tool(Json job, String name, Json args) async {
    if (_stopping || job['status'] != 'running') {
      throw StateError('Turn stopped');
    }
    final id = text(job, 'agent'), lead = id == 'marlow';
    if (!tools(lead ? 'lead' : 'worker').any((t) => t['name'] == name)) {
      throw StateError('Tool not available to this role');
    }
    String result;
    switch (name) {
      case 'report_status':
        agent(id, 'thinking', text(args, 'activity'));
        result = 'Status updated';
      case 'list_tasks':
        result = jsonEncode(store.data['tasks']);
      case 'send_message':
        final to = text(args, 'to').toLowerCase();
        if (!['user', 'all'].contains(to)) require('agents', to);
        if (to == id) throw StateError('Cannot message yourself');
        send(id, to, text(args, 'text'));
        result = 'Sent';
      case 'ask_user':
        final answer = await ask(
            job,
            'question',
            text(args, 'question'),
            (args['options'] as List<dynamic>? ?? []).cast<String>(),
            args['context'] as String? ?? '');
        result = answer.isEmpty ? 'Question cancelled' : answer.join('\n');
      case 'write_memory':
        final scope = args['scope'] as String? ?? 'shared';
        if (!['shared', 'private'].contains(scope)) {
          throw FormatException('Unknown memory scope');
        }
        final entry = <String, dynamic>{
          'id': store.id('memory'),
          'scope': scope,
          'agentId': id,
          'title': text(args, 'title'),
          'body': text(args, 'body'),
          'tags': <String>[],
          'updated': now()
        };
        store.list('memory').add(entry);
        emit({'type': 'memory.upsert', 'entry': entry});
        result = 'Saved ${entry['id']}';
      case 'read_memory':
        result = jsonEncode(store
            .list('memory')
            .where((m) => m['scope'] == 'shared' || m['agentId'] == id)
            .toList());
      case 'create_task':
        final assignee = args['assignee'] as String?;
        if (assignee != null &&
            (!workerIds.contains(assignee) ||
                require('agents', assignee)['active'] != true)) {
          throw StateError('Worker is not on the team');
        }
        final deps = (args['deps'] as List<dynamic>? ?? []).cast<String>();
        for (final dep in deps) {
          if (require('tasks', dep)['goalId'] != job['goalId']) {
            throw StateError('Dependency belongs to another goal');
          }
        }
        final task = <String, dynamic>{
          'id': store.id('t'),
          'title': text(args, 'title'),
          'description': text(args, 'description'),
          'status': 'todo',
          'deps': deps,
          'priority': 0,
          'ci': 'unknown',
          'createdBy': id,
          'createdAt': now(),
          'updatedAt': now(),
          'repoId': job['repoId'],
          if (job['goalId'] != null) 'goalId': job['goalId'],
          if (assignee != null) 'assignee': assignee
        };
        store.list('tasks').add(task);
        upsert('tasks', task);
        result = 'Created ${task['id']}';
      case 'update_task':
        final task = require('tasks', text(args, 'task_id'));
        if (!lead && (task['assignee'] != id || task['id'] != job['taskId'])) {
          throw StateError('You may only update your own assigned task');
        }
        final next = text(args, 'status');
        if (!['review', 'blocked', 'doing'].contains(next) ||
            (!lead && next == 'doing')) {
          throw FormatException('Invalid transition');
        }
        if (['done', 'cancelled'].contains(task['status'])) {
          throw StateError('Task is terminal');
        }
        if (lead && next == 'doing') {
          if (task['status'] != 'review') {
            throw StateError('Only reviewed tasks can be returned');
          }
          task['status'] = 'todo';
          task['description'] =
              '${task['description']}\nReview feedback: ${text(args, 'summary')}';
          for (final d in store.list('decisions').where((d) =>
              d['taskId'] == task['id'] &&
              d['status'] == 'open' &&
              d['kind'] == 'merge')) {
            d['status'] = 'cancelled';
            upsert('decisions', d);
          }
        } else {
          task['status'] = next;
        }
        if (args['summary'] is String) task['summary'] = args['summary'];
        if (args['blocked_reason'] is String) {
          task['blockedReason'] = args['blocked_reason'];
        }
        upsert('tasks', task);
        result = 'Task updated';
      case 'request_merge':
        final task = require('tasks', text(args, 'task_id'));
        if (task['status'] != 'review' ||
            _running.containsKey(task['assignee'])) {
          throw StateError('Task must finish work and tests before review');
        }
        final existing = store.list('decisions').where((d) =>
            d['taskId'] == task['id'] &&
            d['kind'] == 'merge' &&
            d['status'] == 'open');
        if (existing.isNotEmpty) return 'Already awaiting user approval';
        final repo = repos.repo(text(task, 'repoId')),
            wt = repos.worktree(
                repos.repo(text(task, 'repoId')), text(task, 'worktree'));
        final diff = await repos.diff(wt);
        final head = await repos.git(text(wt, 'path'), ['rev-parse', 'HEAD']);
        final d = decision(
            {...job, 'taskId': task['id']},
            'merge',
            'Merge ${task['id']}: ${task['title']}?',
            mergeOptions,
            '${text(args, 'summary')}\nTests: ${task['ci']}\n${task['testOutput'] ?? ''}\n${short(diff, 20000)}',
            extra: {'worktree': wt['id'], 'head': head, 'repoId': repo['id']});
        result = 'Merge request ${d['id']} sent to the user';
      default:
        throw UnsupportedError(name);
    }
    final messages = inbox(id);
    return '$result${messages.isEmpty ? '' : '\nUnread messages:\n$messages'}';
  }
}
