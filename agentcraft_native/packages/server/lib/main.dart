import 'dart:convert';
// Redstone exposes custom Java calls through its internal JNI bridge.
// ignore: implementation_imports
import 'package:dart_mod_common/src/jni/jni_internal.dart';
import 'dart:io';

import 'package:dart_mod_server/dart_mod_server.dart';
import 'foreman.dart';
import 'package:minecraft_mcp/runtime.dart';

int foremanPort() {
  final environment =
      int.tryParse(Platform.environment['AGENTCRAFT_PORT'] ?? '');
  if (environment != null) return environment;
  final config = File('config/agentcraft_native.json');
  if (!config.existsSync()) return 7878;
  final data = jsonDecode(config.readAsStringSync()) as Map<String, dynamic>;
  final port = data['port'];
  if (port is! int || port < 1 || port > 65535) {
    throw const FormatException('Invalid Foreman port');
  }
  return port;
}

final state = WorkshopState();
final notices = <String>[];
final connection =
    ForemanConnection(state, onNotice: notices.add, port: foremanPort());
final decisionTokens = <int, String>{};
int nextToken = 1;
bool workshop = false;
String lastBook = '';
String lastLamp = '';
int lastOpenCount = 0;

void main() {
  Bridge.run(() {
    initializeMcpRuntime();
    Commands.register('craftworkshop',
        permission: 2,
        description: 'Build the AgentCraft workshop at 0, 200, 0',
        execute: (c) {
      buildWorkshop();
      c.source.teleportToDimension(
          'minecraft:overworld', const Vec3(0.5, 200, 4.5),
          yaw: 180);
      c.source.sendMessage(
          'Welcome to the workshop. Right-click Marlow, or read the lectern.');
      return 1;
    });
    Commands.register('craftstatus', execute: (c) {
      showStatus(c.source);
      return 1;
    });
    Commands.register('craftgoal', permission: 2, arguments: [
      const CommandArgument('work', ArgumentType.greedyString),
    ], execute: (c) {
      try {
        final text = c.requireArgument<String>('work').trim();
        if (text.isEmpty) throw StateError('Write a work order first.');
        connection.send(
            {'type': 'goal.submit', 'text': text, 'repoId': 'agentcraft'},
            'Work order');
        c.source.sendMessage(
            'Work order sent. Waiting for the foreman to accept it.');
      } on StateError catch (e) {
        c.source.sendMessage(e.message.toString());
      }
      return 1;
    });
    Commands.register('craftdecisions', permission: 2, execute: (c) {
      showDecisions(c.source);
      return 1;
    });
    Commands.register('craftanswer', permission: 2, arguments: [
      const CommandArgument('request', ArgumentType.integer),
      const CommandArgument('option', ArgumentType.integer),
    ], execute: (c) {
      try {
        final token = c.requireArgument<int>('request');
        final id = decisionTokens[token];
        if (id == null) {
          throw StateError('Open the current requests with /craftdecisions.');
        }
        connection.send(
            state.answer(id, c.requireArgument<int>('option')), 'Answer');
        c.source.sendMessage('Answer sent. Waiting for confirmation.');
      } on StateError catch (e) {
        c.source.sendMessage(e.message.toString());
      }
      return 1;
    });
    Commands.register('craftreply', permission: 2, arguments: [
      const CommandArgument('request', ArgumentType.integer),
      const CommandArgument('reply', ArgumentType.greedyString),
    ], execute: (c) {
      try {
        final id = decisionTokens[c.requireArgument<int>('request')];
        if (id == null) throw StateError('Open /craftdecisions first.');
        connection.send(
            state.reply(id, c.requireArgument<String>('reply')), 'Reply');
        c.source.sendMessage('Reply sent. Waiting for confirmation.');
      } on StateError catch (e) {
        c.source.sendMessage(e.message.toString());
      }
      return 1;
    });
    Commands.register('craftagent', permission: 2, arguments: [
      const CommandArgument('agent', ArgumentType.string),
      const CommandArgument('action', ArgumentType.string),
    ], execute: (c) {
      try {
        connection.send({
          'type': 'agent.action',
          'agentId': c.requireArgument<String>('agent'),
          'action': c.requireArgument<String>('action')
        }, 'Agent control');
      } on StateError catch (e) {
        c.source.sendMessage(e.message.toString());
      }
      return 1;
    });
    Commands.register('crafttask', permission: 2, arguments: [
      const CommandArgument('task', ArgumentType.string),
      const CommandArgument('action', ArgumentType.string),
    ], execute: (c) {
      try {
        connection.send({
          'type': 'task.action',
          'taskId': c.requireArgument<String>('task'),
          'action': c.requireArgument<String>('action')
        }, 'Task control');
      } on StateError catch (e) {
        c.source.sendMessage(e.message.toString());
      }
      return 1;
    });
    Commands.register('craftmessage', permission: 2, arguments: [
      const CommandArgument('agent', ArgumentType.string),
      const CommandArgument('message', ArgumentType.greedyString),
    ], execute: (c) {
      try {
        connection.send({
          'type': 'user.message',
          'to': c.requireArgument<String>('agent'),
          'text': c.requireArgument<String>('message')
        }, 'Message');
      } on StateError catch (e) {
        c.source.sendMessage(e.message.toString());
      }
      return 1;
    });
    Events.onServerStarted(() {
      workshop = false;
      lastBook = '';
      lastLamp = '';
      connection.start();
    });
    Events.onServerStopping(() {
      connection.stop();
      workshop = false;
      decisionTokens.clear();
    });
    Events.onPlayerJoin((p) {
      p.sendMessage(
          'AgentCraft: /craftworkshop builds your workshop. /craftstatus checks the foreman.');
    });
    Events.onItemUseOnEntity = (player, item, hand, target) {
      if (target.hasTag('agentcraft_native')) {
        if (hand == Hand.mainHand) {
          showStatus(player);
          GenericJniBridge.callStaticVoidMethod(
              'dev/diezep/agentcraft_native/WorkshopClient',
              'openChat',
              '(I)V',
              [player.id]);
        }
        return EventResult.cancel;
      }
      return EventResult.allow;
    };
    Events.addTickListener((tick) {
      if (tick % 40 != 0) return;
      for (final notice in notices.toList()) {
        for (final player in Players.getAllPlayers()) {
          player.sendMessage('[Foreman] $notice');
        }
      }
      notices.clear();
      // Only update our explicitly placed lectern; never create/overwrite a world on join.
      if (!workshop) {
        workshop = Entities.getEntitiesInRadius(
                    World.overworld, const Vec3(0, 200, 0), 8)
                .any((e) => e.hasTag('agentcraft_native')) &&
            World.overworld.getBlock(const BlockPos(0, 200, 0)).id ==
                'minecraft:lectern';
      }
      if (workshop) updateWorkshop();
    });
  });
}

void command(String text) => GenericJniBridge.callStaticVoidMethod(
    'dev/diezep/agentcraft_native/WorkshopCommands',
    'execute',
    '(Ljava/lang/String;)V',
    [text]);

void tell(Player player, List<Json> parts) {
  // Player names and text are encoded, never interpolated as command syntax.
  command('tellraw ${jsonEncode(player.name)} ${jsonEncode(parts)}');
}

void showStatus(Player player) {
  tell(player, [
    {'text': '\nMarlow · Workshop foreman\n', 'color': 'gold'},
    {
      'text': state.synced
          ? '${state.backend} · ${state.auth}\n'
          : 'Foreman disconnected\n',
      'color': state.synced ? 'green' : 'red'
    },
    for (final agent in state.agents.values.where((a) => a['active'] != false))
      {'text': '${agent['name']}: ${agent['activity']}\n', 'color': 'gray'},
    {
      'text': '\n[ Write a work order ] ',
      'color': 'yellow',
      'click_event': {'action': 'suggest_command', 'command': '/craftgoal '}
    },
    {
      'text': '[ Requests (${state.openDecisions.length}) ]',
      'color': 'aqua',
      'click_event': {'action': 'run_command', 'command': '/craftdecisions'}
    },
  ]);
}

void showDecisions(Player player) {
  if (!state.synced) {
    player.sendMessage(
        'Foreman disconnected. Requests cannot be answered while offline.');
    return;
  }
  if (state.openDecisions.isEmpty) {
    player.sendMessage('No requests waiting for you.');
  }
  for (final decision in state.openDecisions) {
    final id = decision['id'] as String;
    final token = nextToken++;
    decisionTokens[token] = id;
    // Keep the complete context visible before the player chooses an answer.
    player.sendMessage('\n${decision['kind']}: ${decision['question']}');
    final context = decision['context'] as String?;
    if (context != null && context.isNotEmpty) player.sendMessage(context);
    final options = decision['options'] as List<dynamic>;
    tell(player, [
      if (decision['kind'] == 'question')
        {
          'text': '[ Write a reply ] ',
          'color': 'aqua',
          'click_event': {
            'action': 'suggest_command',
            'command': '/craftreply $token ',
          }
        },
      for (var i = 0; i < options.length; i++)
        {
          'text': '[ ${options[i]} ] ',
          'color': 'yellow',
          'click_event': {
            'action': 'run_command',
            'command': '/craftanswer $token $i',
          }
        },
    ]);
  }
}

void buildWorkshop() {
  // An elevated platform keeps existing terrain intact. "keep" preserves existing blocks.
  command(
      'execute in minecraft:overworld run fill -6 199 -4 6 199 6 minecraft:stone_bricks keep');
  command(
      'execute in minecraft:overworld run fill -5 199 -3 5 199 5 minecraft:spruce_planks replace minecraft:stone_bricks');
  for (final x in [-6, 6]) {
    for (final z in [-4, 6]) {
      command('setblock $x 200 $z minecraft:oak_log keep');
      command('fill $x 201 $z $x 204 $z minecraft:oak_log keep');
    }
    command('fill $x 200 -3 $x 200 5 minecraft:oak_fence keep');
  }
  command('fill -6 205 -4 6 205 6 minecraft:spruce_slab[type=bottom] keep');
  for (final x in [-4, 4]) {
    command('setblock $x 204 1 minecraft:lantern[hanging=true] keep');
    command('setblock $x 200 -2 minecraft:barrel[facing=up] keep');
    command('setblock $x 201 -2 minecraft:redstone_lamp keep');
  }
  command('fill -3 200 -3 3 201 -3 minecraft:bookshelf keep');
  command(
      'setblock 0 200 0 minecraft:lectern[facing=south,has_book=true] keep');
  command('setblock -2 200 0 minecraft:cartography_table keep');
  command('setblock 2 200 0 minecraft:crafting_table keep');
  command('setblock 0 200 3 minecraft:yellow_carpet keep');
  command(
      'execute unless entity @e[tag=agentcraft_native] run summon minecraft:villager 0.5 200 -1.5 '
      '{Tags:["agentcraft_native"],CustomName:{text:"Marlow",color:"gold"},CustomNameVisible:1b,'
      'PersistenceRequired:1b,Invulnerable:1b,NoAI:1b,VillagerData:{type:"minecraft:plains",profession:"minecraft:librarian",level:3}}');
  workshop = true;
  lastBook = '';
  lastLamp = '';
  updateWorkshop();
}

void updateWorkshop() {
  final waiting = state.synced && state.openDecisions.isNotEmpty;
  final working = state.synced &&
      state.agents.values.any((a) =>
          a['active'] != false &&
          !['idle', 'done', 'error'].contains(a['state']));
  final lamps = '${state.synced}:$waiting:$working';
  if (lamps != lastLamp) {
    command(
        'setblock -4 200 -2 minecraft:${working ? 'redstone_block' : 'barrel'}');
    command(
        'setblock 4 200 -2 minecraft:${waiting ? 'redstone_block' : 'barrel'}');
    lastLamp = lamps;
  }
  final count = state.openDecisions.length;
  if (waiting && count > lastOpenCount) {
    command(
        'playsound minecraft:block.note_block.bell master @a 0 200 0 0.5 1');
    for (final p in Players.getAllPlayers()) {
      p.sendActionBar('Marlow needs your answer · /craftdecisions');
    }
  }
  lastOpenCount = count;
  final pages = <String>[
    'WORK ORDERS\n\n${state.synced ? '${state.backend} connected' : 'Foreman offline'}\n\n'
        'Right-click Marlow to write a work order or answer a request.\n\n'
        'Left lamp: working\nRight lamp: needs you',
    ...state.agents.values.where((a) => a['active'] != false).map((a) =>
        '${a['name']}\n${a['role']} · ${a['state']}\n\n${a['activity']}'),
    ...state.tasks.values
        .where((t) => t['status'] != 'cancelled')
        .take(12)
        .map((t) => '${t['status']}\n\n${t['title']}'),
    ...state.logs.reversed.take(4).map((line) => 'RECENT WORK\n\n$line'),
  ];
  final book = jsonEncode({
    'Book': {
      'id': 'minecraft:written_book',
      'count': 1,
      'components': {
        'minecraft:written_book_content': {
          'title': 'Work orders',
          'author': 'Marlow',
          'pages': [
            for (final page in pages)
              {
                'raw': {
                  'text':
                      page.length > 220 ? '${page.substring(0, 217)}...' : page
                }
              }
          ],
        }
      }
    }
  });
  if (book != lastBook) {
    command('data merge block 0 200 0 $book');
    lastBook = book;
  }
}
