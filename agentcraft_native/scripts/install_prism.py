#!/usr/bin/env python3
"""Install the local macOS development prototype into a separate Prism instance."""
from pathlib import Path
import json
import shutil
import shlex
import urllib.request

root = Path(__file__).resolve().parents[1]
prism = Path.home() / 'Library/Application Support/PrismLauncher'
instance = prism / 'instances/AgentCraft-Native-Dart-1.21.11'
game = instance / '.minecraft'
for folder in ['mods', 'natives']:
    (game / folder).mkdir(parents=True, exist_ok=True)
jar = root / 'minecraft/build/libs/agentcraft_native-1.0.0.jar'
staged_jar = game / 'mods' / (jar.name + '.tmp')
shutil.copy2(jar, staged_jar)
staged_jar.replace(game / 'mods' / jar.name)
for name in ['dart_mc_bridge.dylib', 'libdart_dll.dylib']:
    shutil.copy2(root / '.redstone/native' / name, game / 'natives' / name)
api = 'fabric-api-0.139.4+1.21.11.jar'
if not (game / 'mods' / api).exists():
    urllib.request.urlretrieve('https://maven.fabricmc.net/net/fabricmc/fabric-api/fabric-api/0.139.4+1.21.11/' + api, game / 'mods' / api)
if not (instance / 'mmc-pack.json').exists():
    (instance / 'mmc-pack.json').write_text(json.dumps({'formatVersion': 1, 'components': [
        {'uid': 'net.minecraft', 'version': '1.21.11', 'important': True},
        {'uid': 'net.fabricmc.fabric-loader', 'version': '0.19.5'},
    ]}, indent=2))
if not (instance / 'instance.cfg').exists():
    (instance / 'instance.cfg').write_text(f'''[General]
InstanceType=OneSix
name=AgentCraft Native — Dart workshop
iconKey=default
OverrideJavaLocation=true
JavaPath={prism}/java/java-runtime-epsilon/bin/java
AutomaticJava=false
IgnoreJavaCompatibility=true
OverrideMemory=true
MinMemAlloc=512
MaxMemAlloc=3072
OverrideWindow=true
MinecraftWinWidth=1280
MinecraftWinHeight=800
OverrideJavaArgs=true
JvmArgs=--enable-native-access=ALL-UNNAMED -DDART_SERVER_SCRIPT={root}/packages/server/lib/main.dart -DDART_PACKAGE_CONFIG={root}/.dart_tool/package_config.json -DMCP_MODE=true -DMCP_SERVER_PORT=8766
notes=Experimental Redstone.Dart workshop. Minecraft 1.21.11. Local Foreman port 7878. Development control port 8766.
''')
# Start/reuse the existing Codex Foreman before launching Minecraft.
node = shutil.which('node')
codex = shutil.which('codex')
if not node or not codex:
    raise SystemExit('Install Node and sign in with codex login before installing.')
hook = instance / 'start-foreman.command'
args = [node, str(root.parent / 'tools/mac.mjs'), 'launch', '--backend', 'codex',
        '--profile', 'prism-codex', '--repo', str(root.parent), '--no-game',
        '--foreman-arg', '--workers', '--foreman-arg', '1',
        '--foreman-arg', '--codex-command', '--foreman-arg', codex]
hook.write_text('#!/bin/sh\nexport PATH=' + shlex.quote(str(Path(node).parent)) + ':"$PATH"\nif ' + shlex.join([node, str(root.parent / 'tools/foremancli.mjs'), 'status']) + ' >/dev/null 2>&1; then exit 0; fi\nexec ' + shlex.join(args) + '\n')
hook.chmod(0o755)
config = instance / 'instance.cfg'
lines = config.read_text().splitlines()
for key, value in {'OverrideCommands': 'true', 'PreLaunchCommand': '"' + str(hook) + '"'}.items():
    lines = [line for line in lines if not line.startswith(key + '=')]
    lines.append(key + '=' + value)
config.write_text('\n'.join(lines) + '\n')
options = game / 'options.txt'
lines = options.read_text().splitlines() if options.exists() else []
lines = [line for line in lines if not line.startswith(('pauseOnLostFocus:', 'tutorialStep:'))]
options.write_text('\n'.join(lines + ['pauseOnLostFocus:false', 'tutorialStep:none']) + '\n')
print(instance)
