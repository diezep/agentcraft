import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'process.dart';
import 'server.dart';
import 'state.dart';

const redstoneRevision = '0892d25c5fffc8a12964d1674fecf69ca0f28fae';
String homeDirectory() =>
    Platform.environment['HOME'] ??
    Platform.environment['USERPROFILE'] ??
    (throw StateError('Home directory unavailable'));
Future<void> checked(String exe, List<String> args, String cwd) async {
  final result = await runCommand(exe, args,
      cwd: cwd, timeout: const Duration(minutes: 15));
  if (result.code != 0) throw StateError('$exe failed: ${result.output}');
}

Future<void> copyTree(Directory source, Directory target) async {
  await target.create(recursive: true);
  await for (final entry in source.list()) {
    final dest = p.join(target.path, p.basename(entry.path));
    if (entry is Directory) {
      await copyTree(entry, Directory(dest));
    } else if (entry is File) {
      await entry.copy(dest);
    }
  }
}

Future<void> download(String url, String destination) async {
  final client = HttpClient();
  try {
    final response = await (await client.getUrl(Uri.parse(url))).close();
    if (response.statusCode != 200) {
      throw HttpException('Download failed ${response.statusCode}',
          uri: Uri.parse(url));
    }
    await Directory(p.dirname(destination)).create(recursive: true);
    final temp = File('$destination.part');
    await response.pipe(temp.openWrite());
    await temp.rename(destination);
  } finally {
    client.close(force: true);
  }
}

/// Build the pinned Redstone bridge using its native and Java toolchains.
Future<void> buildMod(String root) async {
  if (!Platform.isMacOS) {
    throw UnsupportedError(
        'The native build/Prism installer currently supports macOS. The backend runs independently.');
  }
  final dep = p.join(p.dirname(root), 'redstone_dart');
  if (!Directory(dep).existsSync()) {
    await checked(
        'git',
        ['clone', 'https://github.com/Norbert515/redstone_dart.git', dep],
        root);
    await checked('git', ['checkout', redstoneRevision], dep);
  }
  final revision = await runCommand('git', ['rev-parse', 'HEAD'], cwd: dep);
  if (revision.output.trim() != redstoneRevision) {
    throw StateError('Use Redstone revision $redstoneRevision');
  }
  final mod = p.join(root, 'agentcraft_native');
  final api = File(
      p.join(dep, 'packages/minecraft_mcp/lib/src/protocol/game_server.dart'));
  var source = api
      .readAsStringSync()
      .replaceAll('InternetAddress.anyIPv4', 'InternetAddress.loopbackIPv4');
  if (!source.contains("request.headers.containsKey('origin')")) {
    source = source.replaceFirst('return (Request request) async {',
        "return (Request request) async {\nif (request.headers.containsKey('origin')) return Response.forbidden('Local development tools only');");
  }
  api.writeAsStringSync(source);
  await copyTree(Directory(p.join(dep, 'packages/java_mc_bridge/src/main')),
      Directory(p.join(mod, '.redstone/bridge')));
  await copyTree(Directory(p.join(dep, 'packages/java_mc_bridge/src/client')),
      Directory(p.join(mod, '.redstone/bridge/client')));
  await File(p.join(dep, 'LICENSE'))
      .copy(p.join(mod, '.redstone/bridge/resources/REDSTONE-LICENSE.txt'));
  final native = p.join(dep, 'packages/native_mc_bridge'),
      dll = p.join(dep, 'packages/native_mc_bridge/deps/dart_dll');
  if (!File(p.join(dll, 'lib/libdart_dll.dylib')).existsSync()) {
    final temp = await Directory.systemTemp.createTemp('agentcraft-dll-');
    try {
      final archive = p.join(temp.path, 'dll.zip');
      await download(
          'https://github.com/fuzzybinary/dart_shared_library/releases/download/0.2.0/lib-macos.zip',
          archive);
      await checked('unzip', ['-o', archive, '-d', dll], root);
      await Directory(p.join(dll, 'lib')).create(recursive: true);
      await File(p.join(dll, 'bin/libdart_dll.dylib'))
          .copy(p.join(dll, 'lib/libdart_dll.dylib'));
    } finally {
      await temp.delete(recursive: true);
    }
  }
  final jdk = Platform.environment['NATIVE_JAVA_HOME'] ??
      (await runCommand('/usr/libexec/java_home', [], cwd: root)).output.trim();
  final configured = await runCommand('cmake',
      ['-S', native, '-B', p.join(native, 'build-server'), '-DSERVER_ONLY=ON'],
      cwd: root, env: {...Platform.environment, 'JAVA_HOME': jdk});
  if (configured.code != 0) throw StateError(configured.output);
  await checked(
      'cmake', ['--build', p.join(native, 'build-server'), '-j', '4'], root);
  await Directory(p.join(mod, '.redstone/native')).create(recursive: true);
  for (final name in ['dart_mc_bridge.dylib', 'libdart_mc_bridge.dylib']) {
    await File(p.join(native, 'build-server/dart_mc_bridge.dylib'))
        .copy(p.join(mod, '.redstone/native', name));
  }
  await File(p.join(dll, 'lib/libdart_dll.dylib'))
      .copy(p.join(mod, '.redstone/native/libdart_dll.dylib'));
  await checked('dart', ['pub', 'get'], mod);
  await checked('sh', ['gradlew', 'assemble'], p.join(mod, 'minecraft'));
}

// QSettings needs a quoted INI value around the independently quoted argv.
String iniString(String value) =>
    '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"').replaceAll('\n', r'\n')}"';
String shellQuote(String value) => "'${value.replaceAll("'", "'\\''")}'";
Future<String> installPrism(
    String root, String executable, String codex, int port, String profile,
    {String? prismDirectory,
    Future<void> Function(String, String) fetch = download}) async {
  if (!Platform.isMacOS) {
    throw UnsupportedError('Prism installation currently supports macOS');
  }
  final prism = prismDirectory ??
      p.join(homeDirectory(), 'Library/Application Support/PrismLauncher');
  final destination = p.join(prism, 'instances/AgentCraft-Dart-1.21.11');
  final fresh = !Directory(destination).existsSync();
  // Publish a complete instance atomically: Prism caches a folder as soon as it appears.
  final instance =
      fresh ? p.join(prism, '.agentcraft-install-${now()}') : destination;
  final game = p.join(instance, '.minecraft'),
      mod = p.join(root, 'agentcraft_native');
  for (final folder in ['mods', 'natives', 'config']) {
    await Directory(p.join(game, folder)).create(recursive: true);
  }
  final copies = {
    'minecraft/build/libs/agentcraft_native-1.0.0.jar':
        'mods/agentcraft_native-1.0.0.jar',
    '.redstone/native/dart_mc_bridge.dylib': 'natives/dart_mc_bridge.dylib',
    '.redstone/native/libdart_dll.dylib': 'natives/libdart_dll.dylib',
  };
  for (final entry in copies.entries) {
    final dest = p.join(game, entry.value);
    final temp = await File(p.join(mod, entry.key)).copy('$dest.part');
    await temp.rename(dest);
  }
  final api = p.join(game, 'mods/fabric-api-0.139.4+1.21.11.jar');
  if (!File(api).existsSync()) {
    await fetch(
        'https://maven.fabricmc.net/net/fabricmc/fabric-api/fabric-api/0.139.4+1.21.11/fabric-api-0.139.4+1.21.11.jar',
        api);
  }
  final pack = File(p.join(instance, 'mmc-pack.json'));
  if (!pack.existsSync()) {
    pack.writeAsStringSync(jsonEncode({
      'formatVersion': 1,
      'components': [
        {'uid': 'net.minecraft', 'version': '1.21.11', 'important': true},
        {'uid': 'net.fabricmc.fabric-loader', 'version': '0.19.5'}
      ]
    }));
  }
  File(p.join(game, 'config/agentcraft_native.json'))
      .writeAsStringSync(jsonEncode({'port': port}));
  final hook = File(p.join(instance, 'start-foreman.command'));
  final dartPath = await runCommand('which', ['dart'], cwd: root);
  if (dartPath.code != 0) throw StateError('Dart SDK not found');
  final launchPath =
      '${p.dirname(codex)}:${p.dirname(dartPath.output.trim())}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin';
  hook.writeAsStringSync(
      '#!/bin/sh\nexport PATH=${shellQuote(launchPath)}\nexec ${[
    executable,
    'ensure',
    '--profile',
    profile,
    '--port',
    '$port',
    '--repo',
    root,
    '--codex',
    codex
  ].map(shellQuote).join(' ')}\n');
  await checked('chmod', ['+x', hook.path], root);
  final config = File(p.join(instance, 'instance.cfg'));
  final args = [
    '--enable-native-access=ALL-UNNAMED',
    '-DDART_SERVER_SCRIPT=${p.join(mod, 'packages/server/lib/main.dart')}',
    '-DDART_PACKAGE_CONFIG=${p.join(mod, '.dart_tool/package_config.json')}',
    '-DMCP_MODE=true',
    '-DMCP_SERVER_PORT=8767'
  ];
  if (!config.existsSync()) {
    config.writeAsStringSync(
        '[General]\nConfigVersion=1.3\nInstanceType=OneSix\nname=AgentCraft — Dart edition\niconKey=default\n'
        'OverrideJavaLocation=true\nAutomaticJava=false\nIgnoreJavaCompatibility=true\nJavaPath=$prism/java/java-runtime-epsilon/bin/java\n'
        'OverrideMemory=true\nMinMemAlloc=512\nMaxMemAlloc=3072\nOverrideWindow=true\nMinecraftWinWidth=1280\nMinecraftWinHeight=800\n'
        'OverrideJavaArgs=true\nOverrideCommands=true\n');
  }
  final lines = config
      .readAsLinesSync()
      .where((line) =>
          !line.startsWith('JvmArgs=') && !line.startsWith('PreLaunchCommand='))
      .toList();
  lines.add(
      'JvmArgs=${iniString(args.map((s) => s.contains(' ') ? '"$s"' : s).join(' '))}');
  lines.add(
      'PreLaunchCommand=${iniString('sh "${p.join(destination, 'start-foreman.command')}"')}');
  config.writeAsStringSync('${lines.join('\n')}\n');
  final options = File(p.join(game, 'options.txt'));
  if (!options.existsSync()) {
    options.writeAsStringSync('pauseOnLostFocus:false\ntutorialStep:none\n');
  }
  if (fresh) {
    await Directory(p.dirname(destination)).create(recursive: true);
    await Directory(instance).rename(destination);
  }
  return destination;
}

Future<void> ensureForeman(
    String executable, List<String> args, int port) async {
  try {
    final status = await intent(port, {'type': 'hello'});
    if (!(status['foreman'] as Json)['version']
        .toString()
        .startsWith('dart-')) {
      throw StateError('Port $port belongs to another backend');
    }
    return;
  } on SocketException {/* launch below */} on TimeoutException {
    /* launch below */
  }
  await Process.start(executable, ['serve', ...args],
      mode: ProcessStartMode.detached);
  for (var i = 0; i < 100; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    try {
      await intent(port, {'type': 'hello'});
      return;
    } on SocketException {/* startup */} on TimeoutException {/* startup */}
  }
  throw StateError(
      'Dart Foreman did not start; run serve in a terminal for diagnostics.');
}
