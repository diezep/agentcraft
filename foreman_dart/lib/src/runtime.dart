import 'dart:async';
import 'rpc.dart';
import 'state.dart';
import 'process.dart';

typedef Connect = Future<Rpc> Function(String cwd, String agent);
typedef Ask = Future<List<String>> Function(
    String kind, String question, List<String> options, String context);

class Turn {
  Turn(
      {required this.agent,
      required this.cwd,
      required this.role,
      required this.prompt,
      required this.instructions,
      required this.tools,
      required this.tool,
      required this.ask,
      required this.log,
      required this.session,
      this.resume});
  final String agent, cwd, role, prompt, instructions;
  final List<Json> tools;
  final Future<String> Function(String, Json) tool;
  final Ask ask;
  final void Function(String kind, String value) log;
  final void Function(String id) session;
  final String? resume;
  Rpc? rpc;
  bool cancelled = false;
  Future<void> cancel() async {
    cancelled = true;
    await rpc?.close();
  }
}

abstract interface class AgentRuntime {
  Future<String> auth();
  Future<String> run(Turn turn);
}

class CodexRuntime implements AgentRuntime {
  CodexRuntime({String command = 'codex', Connect? connect, this.model})
      : connect = connect ??
            ((cwd, agent) => CodexRpc.start(command, cwd, agent: agent));
  final Connect connect;
  final String? model;
  Future<String> account(Rpc rpc) async {
    final response = await rpc.request('account/read', {'refreshToken': true});
    final account = response['account'] as Json?;
    if (account?['type'] != 'chatgpt') {
      throw StateError(
          'Run codex login and select ChatGPT. API-key accounts are not used.');
    }
    return 'ChatGPT · ${account!['planType'] ?? 'subscription'}';
  }

  @override
  Future<String> auth() async {
    final rpc = await connect('.', 'foreman');
    try {
      return await account(rpc);
    } finally {
      await rpc.close();
    }
  }

  @override
  Future<String> run(Turn turn) async {
    final rpc = await connect(turn.cwd, turn.agent);
    turn.rpc = rpc;
    final done = Completer<String>();
    // Observe setup-time transport failures even before awaiting the result below.
    unawaited(
        done.future.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    String? thread;
    var result = '';
    final changes = <String, Object?>{};
    rpc.closed = (error) {
      if (!done.isCompleted) done.completeError(error);
    };
    rpc.notification = (method, params) {
      if (turn.cancelled ||
          done.isCompleted ||
          (params['threadId'] != null && params['threadId'] != thread)) {
        return;
      }
      final item = params['item'] as Json?;
      if (method == 'item/started' && item != null) {
        if (item['type'] == 'commandExecution') {
          turn.log('tool', '${item['command']}');
        }
        if (item['type'] == 'fileChange') {
          changes['${item['id']}'] = item['changes'];
          turn.log('tool', 'Editing files');
        }
      }
      if (method == 'item/completed' && item != null) {
        switch (item['type']) {
          case 'agentMessage':
            result = item['text'] as String? ?? '';
            turn.log('text', result);
          case 'commandExecution':
            turn.log(item['exitCode'] == 0 ? 'result' : 'error',
                '${item['aggregatedOutput'] ?? item['status']}');
          case 'fileChange':
            turn.log('diff', '${item['changes']}');
        }
      }
      if (method == 'turn/completed') {
        final value = params['turn'] as Json;
        if (value['status'] == 'completed') {
          done.complete(result);
        } else {
          done.completeError(
              StateError('Codex ${value['status']}: ${value['error']}'));
        }
      }
    };
    rpc.requestHandler = (method, params) async {
      if (turn.cancelled || done.isCompleted || params['threadId'] != thread) {
        throw StateError('Inactive turn');
      }
      if (method == 'item/tool/call') {
        try {
          if (params['namespace'] != null) {
            throw StateError('Unknown tool namespace');
          }
          final result = await turn.tool(
              text(params, 'tool'), params['arguments'] as Json);
          return {
            'success': true,
            'contentItems': [
              {'type': 'inputText', 'text': result}
            ]
          };
        } on Object catch (e) {
          return {
            'success': false,
            'contentItems': [
              {'type': 'inputText', 'text': e.toString()}
            ]
          };
        }
      }
      if (method == 'item/tool/requestUserInput' ||
          method == 'tool/requestUserInput') {
        final answers = <String, dynamic>{};
        for (final question in rows(params['questions'])) {
          answers[text(question, 'id')] = {
            'answers': await turn.ask(
                'question',
                text(question, 'question'),
                rows(question['options']).map((o) => text(o, 'label')).toList(),
                '${question['header'] ?? ''}')
          };
        }
        return {'answers': answers};
      }
      if (method == 'item/commandExecution/requestApproval' ||
          method == 'item/fileChange/requestApproval') {
        if (turn.role == 'lead') return {'decision': 'decline'};
        final command = params['command'] as String? ?? '';
        if (RegExp(
                r'\bgit\s+(push|send-pack)|GIT_(ALLOW_PROTOCOL|CONFIG|DIR|WORK_TREE)|--git-dir|--work-tree',
                caseSensitive: false)
            .hasMatch(command)) {
          return {'decision': 'decline'};
        }
        final answer = await turn.ask(
            'permission',
            '${turn.agent} requests approval',
            ['Allow once', 'Deny'],
            '$command\n${changes[params['itemId']] ?? ''}\n${params['reason'] ?? ''}\n'
                'cwd: ${params['cwd'] ?? turn.cwd}\n${params['additionalPermissions'] ?? ''}\n${params['networkApprovalContext'] ?? ''}');
        return {
          'decision': answer.firstOrNull == 'Allow once' ? 'accept' : 'decline'
        };
      }
      if (method == 'item/permissions/requestApproval') {
        if (turn.role == 'lead') {
          return {'permissions': <String, dynamic>{}, 'scope': 'turn'};
        }
        final answer = await turn.ask(
            'permission',
            'Additional permissions for ${turn.agent}',
            ['Allow for this turn', 'Deny'],
            '${params['reason']}\n${params['permissions']}');
        final granted =
            Map<String, dynamic>.from(params['permissions'] as Json? ?? {})
              ..removeWhere((key, value) => value == null);
        return {
          'permissions': answer.firstOrNull == 'Allow for this turn'
              ? granted
              : <String, dynamic>{},
          'scope': 'turn'
        };
      }
      if (method == 'mcpServer/elicitation/request') {
        return {'action': 'decline', 'content': null};
      }
      throw UnsupportedError('Unsupported Codex request $method');
    };
    try {
      if (turn.cancelled) throw StateError('Turn cancelled');
      await account(rpc);
      final effective = await rpc
          .request('config/read', {'cwd': turn.cwd, 'includeLayers': false});
      final config = <String, dynamic>{
        'model_provider': 'openai',
        'web_search': 'disabled',
        'features.multi_agent': false,
        'features.apps': false,
        'features.plugins': false,
        'features.hooks': false,
        'sandbox_workspace_write.network_access': false,
        'shell_environment_policy.set': Map<String, String>.fromEntries(
            safeEnvironment(turn.cwd, turn.agent).entries.where(
                (e) => e.key.startsWith('GIT_') || e.key == 'GCM_INTERACTIVE'))
      };
      final servers =
          (effective['config'] as Json?)?['mcp_servers'] as Json? ?? {};
      for (final name in servers.keys) {
        config['mcp_servers.$name.enabled'] = false;
      }
      final params = <String, dynamic>{
        'cwd': turn.cwd,
        'approvalPolicy': turn.role == 'lead' ? 'never' : 'on-request',
        'approvalsReviewer': 'user',
        'sandbox': turn.role == 'lead' ? 'read-only' : 'workspace-write',
        'config': config,
        'developerInstructions':
            '${turn.instructions}\nUse native tools for files and the provided coordination tools. Do not spawn subagents.',
        if (model != null) 'model': model
      };
      final started = await rpc
          .request(turn.resume == null ? 'thread/start' : 'thread/resume', {
        ...params,
        if (turn.resume != null) 'threadId': turn.resume,
        if (turn.resume == null) 'dynamicTools': turn.tools,
      });
      thread = (started['thread'] as Json)['id'] as String;
      turn.session(thread);
      await rpc.request('turn/start', {
        'threadId': thread,
        'input': [
          {'type': 'text', 'text': turn.prompt, 'text_elements': <Object>[]}
        ],
        'effort': 'medium'
      });
      return await done.future.timeout(const Duration(minutes: 45));
    } finally {
      await rpc.close();
      turn.rpc = null;
    }
  }
}
