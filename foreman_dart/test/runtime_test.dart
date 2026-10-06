import 'dart:async';
import 'package:agentcraft_dart/agentcraft_dart.dart';
import 'package:test/test.dart';

class FakeRpc implements Rpc {
  FakeRpc({this.accountType = 'chatgpt', this.approval = false});
  final String accountType;
  final bool approval;
  final calls = <(String, Json)>[];
  final responses = <Json>[];
  @override
  void Function(String, Json) notification = (_, __) {};
  @override
  Future<Object?> Function(String, Json) requestHandler = (_, __) async => null;
  @override
  void Function(Object) closed = (_) {};
  @override
  Future<void> close() async {
    closed(StateError('closed'));
  }

  @override
  Future<Json> request(String method, Json params) async {
    calls.add((method, params));
    switch (method) {
      case 'account/read':
        return {
          'account': {'type': accountType, 'planType': 'test'}
        };
      case 'config/read':
        return {
          'config': {
            'mcp_servers': {'private': <String, dynamic>{}}
          }
        };
      case 'thread/start':
      case 'thread/resume':
        return {
          'thread': {'id': 'thread-1'}
        };
      case 'turn/start':
        unawaited(() async {
          if (approval) {
            responses.add(
                await requestHandler('item/commandExecution/requestApproval', {
              'threadId': 'thread-1',
              'command': 'npm install',
              'cwd': '/tmp',
              'reason': 'Needs network'
            }) as Json);
          }
          notification('item/completed', {
            'threadId': 'thread-1',
            'item': {'type': 'agentMessage', 'text': 'Done'}
          });
          notification('turn/completed', {
            'threadId': 'thread-1',
            'turn': {'status': 'completed'}
          });
        }());
        return {};
      default:
        return {};
    }
  }
}

Turn turn({String role = 'worker', String? resume, Ask? ask}) => Turn(
    agent: 'juniper',
    cwd: '/tmp',
    role: role,
    prompt: 'Test',
    instructions: 'Test',
    tools: [],
    tool: (_, __) async => 'OK',
    ask: ask ?? (_, __, ___, ____) async => ['Deny'],
    log: (_, __) {},
    session: (_) {},
    resume: resume);
void main() {
  test('requires ChatGPT login and rejects API billing', () async {
    final rpc = FakeRpc(accountType: 'apiKey');
    final runtime = CodexRuntime(connect: (_, __) async => rpc);
    await expectLater(runtime.auth(), throwsStateError);
  });
  test('worker approvals are explicit; personal MCP servers are disabled',
      () async {
    final rpc = FakeRpc(approval: true);
    final runtime = CodexRuntime(connect: (_, __) async => rpc);
    expect(
        await runtime.run(turn(ask: (_, __, options, context) async {
          expect(options, ['Allow once', 'Deny']);
          expect(context, contains('npm install'));
          return ['Allow once'];
        })),
        'Done');
    expect(rpc.responses.single['decision'], 'accept');
    final start = rpc.calls.firstWhere((c) => c.$1 == 'thread/start').$2;
    expect(start['sandbox'], 'workspace-write');
    final config = start['config'] as Json;
    expect(config['mcp_servers.private.enabled'], isFalse);
    expect(config['sandbox_workspace_write.network_access'], isFalse);
    expect((config['shell_environment_policy.set'] as Map).keys,
        isNot(contains('OPENAI_API_KEY')));
  });
  test('lead never escalates and session resume retains read-only sandbox',
      () async {
    final rpc = FakeRpc(approval: true);
    await CodexRuntime(connect: (_, __) async => rpc)
        .run(turn(role: 'lead', resume: 'thread-1'));
    expect(rpc.responses.single['decision'], 'decline');
    final start = rpc.calls.firstWhere((c) => c.$1 == 'thread/resume').$2;
    expect(start['sandbox'], 'read-only');
    expect(start['approvalPolicy'], 'never');
    expect(start['threadId'], 'thread-1');
  });
}
