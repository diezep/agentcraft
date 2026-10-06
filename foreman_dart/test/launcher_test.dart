import 'dart:convert';
import 'dart:io';
import 'package:agentcraft_dart/src/launcher.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test(
      'Prism installer publishes complete instance and preserves worlds on reinstall',
      () async {
    final temp = await Directory.systemTemp.createTemp('dart-prism-');
    addTearDown(() => temp.delete(recursive: true));
    final root = p.join(temp.path, 'source');
    for (final name in [
      'minecraft/build/libs/agentcraft_native-1.0.0.jar',
      '.redstone/native/dart_mc_bridge.dylib',
      '.redstone/native/libdart_dll.dylib'
    ]) {
      final file = File(p.join(root, 'agentcraft_native', name));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('fixture');
    }
    final prism = p.join(temp.path, 'Prism with spaces');
    Future<void> fetch(String url, String dest) async {
      expect(url, startsWith('https://maven.fabricmc.net/'));
      expect(
          Directory(p.join(prism, 'instances/AgentCraft-Dart-1.21.11'))
              .existsSync(),
          isFalse);
      File(dest).writeAsStringSync('fake api');
    }

    final instance = await installPrism(
        root, '/path/app', '/path/codex', 9999, '/profile',
        prismDirectory: prism, fetch: fetch);
    final config = File(p.join(instance, 'instance.cfg')).readAsLinesSync();
    expect(config, contains('ConfigVersion=1.3'));
    final jvm = jsonDecode(
            config.firstWhere((l) => l.startsWith('JvmArgs=')).substring(8))
        as String;
    expect(jvm, contains('-DMCP_SERVER_PORT=8767'));
    expect(
        jvm,
        contains(
            '-DDART_SERVER_SCRIPT=$root/agentcraft_native/packages/server/lib/main.dart'));
    final hook = jsonDecode(config
        .firstWhere((l) => l.startsWith('PreLaunchCommand='))
        .substring(17)) as String;
    expect(hook, 'sh "$instance/start-foreman.command"');
    final world = File(p.join(instance, '.minecraft/saves/world/level.dat'));
    world.parent.createSync(recursive: true);
    world.writeAsStringSync('keep world');
    await installPrism(root, '/path/app', '/path/codex', 9998, '/profile',
        prismDirectory: prism, fetch: fetch);
    expect(world.readAsStringSync(), 'keep world');
    expect(
        jsonDecode(
            File(p.join(instance, '.minecraft/config/agentcraft_native.json'))
                .readAsStringSync()),
        {'port': 9998});
  }, skip: !Platform.isMacOS);
}
