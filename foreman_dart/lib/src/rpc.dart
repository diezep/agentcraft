import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'process.dart';
import 'state.dart';

abstract interface class Rpc {
  set notification(void Function(String, Json) callback);
  set requestHandler(Future<Object?> Function(String, Json) callback);
  set closed(void Function(Object) callback);
  Future<Json> request(String method, Json params);
  Future<void> close();
}

class CodexRpc implements Rpc {
  CodexRpc._(this.process) {
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      try {
        _receive(jsonDecode(line) as Json);
      } on Object catch (e) {
        _fail(e);
      }
    }, onError: (Object e) => _fail(e));
    process.stderr.drain<void>();
    process.exitCode.then((code) {
      _exited = true;
      _fail(StateError('Codex exited ($code)'));
    });
    process.stdin.done.catchError((Object e) {
      _fail(e);
    });
  }
  static Future<CodexRpc> start(String command, String cwd,
      {String agent = 'foreman', List<String>? arguments}) async {
    final child = await Process.start(
        command,
        arguments ??
            [
              'app-server',
              '--listen',
              'stdio://',
              '--disable',
              'apps',
              '--disable',
              'plugins',
              '--disable',
              'hooks',
              '--disable',
              'multi_agent',
            ],
        workingDirectory: cwd,
        environment: safeEnvironment(cwd, agent),
        includeParentEnvironment: false);
    final rpc = CodexRpc._(child);
    try {
      await rpc.request('initialize', {
        'clientInfo': {'name': 'agentcraft_dart', 'version': '0.1.0'},
        'capabilities': {'experimentalApi': true}
      });
      rpc._send({'method': 'initialized', 'params': <String, dynamic>{}});
      return rpc;
    } on Object {
      await rpc.close();
      rethrow;
    }
  }

  final Process process;
  int _id = 0;
  bool _dead = false, _exited = false;
  Future<void>? _cleanup;
  final _pending = <int, Completer<Json>>{};
  @override
  void Function(String, Json) notification = (_, __) {};
  @override
  Future<Object?> Function(String, Json) requestHandler =
      (_, __) async => throw UnsupportedError('Unsupported request');
  @override
  void Function(Object) closed = (_) {};
  void _send(Json packet) {
    if (_dead) throw StateError('Codex transport closed');
    process.stdin.writeln(jsonEncode(packet));
  }

  @override
  Future<Json> request(String method, Json params) async {
    final id = ++_id;
    final result = Completer<Json>();
    _pending[id] = result;
    try {
      _send({'id': id, 'method': method, 'params': params});
      return await result.future.timeout(const Duration(seconds: 45));
    } finally {
      _pending.remove(id);
    }
  }

  void _receive(Json packet) {
    if (_dead) return;
    final method = packet['method'];
    if (method is String) {
      final params = packet['params'] as Json? ?? {};
      if (packet.containsKey('id')) {
        unawaited(() async {
          try {
            final result = await requestHandler(method, params);
            if (!_dead) _send({'id': packet['id'], 'result': result});
          } on Object catch (e) {
            if (!_dead) {
              _send({
                'id': packet['id'],
                'error': {'code': -32603, 'message': e.toString()}
              });
            }
          }
        }());
      } else {
        notification(method, params);
      }
    } else {
      final waiter = _pending.remove(packet['id']);
      if (waiter == null) return;
      if (packet['error'] != null) {
        waiter.completeError(StateError('${packet['error']}'));
      } else {
        waiter.complete(packet['result'] as Json? ?? {});
      }
    }
  }

  void _fail(Object error) {
    if (_dead) return;
    _dead = true;
    for (final pending in _pending.values) {
      pending.completeError(error);
    }
    _pending.clear();
    closed(error);
    if (!_exited) _cleanup = killOwned(process);
  }

  @override
  Future<void> close() async {
    if (!_dead) _fail(StateError('Codex transport closed'));
    await _cleanup;
    await process.exitCode;
  }
}
