#!/usr/bin/env python3
"""Prepare pinned Redstone sources and build the macOS native runtime."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import urllib.request
import zipfile

root = Path(__file__).resolve().parents[1]
dep = root.parent.parent / 'redstone_dart'
revision = '0892d25c5fffc8a12964d1674fecf69ca0f28fae'

def run(args, cwd=root, env=None):
    subprocess.run([str(x) for x in args], cwd=cwd, env=env, check=True)

if not dep.exists():
    run(['git', 'clone', 'https://github.com/Norbert515/redstone_dart.git', dep])
    run(['git', 'checkout', revision], cwd=dep)
actual = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=dep, text=True).strip()
if actual != revision:
    raise SystemExit(f'Expected Redstone {revision}, found {actual}; use a separate pinned checkout.')

# The upstream development API binds all interfaces and permits browser origins.
# Keep this local prototype's test controls restricted to local non-browser callers.
api = dep / 'packages/minecraft_mcp/lib/src/protocol/game_server.dart'
text = api.read_text().replace('InternetAddress.anyIPv4', 'InternetAddress.loopbackIPv4')
marker = '      return (Request request) async {'
if "request.headers.containsKey('origin')" not in text:
    text = text.replace(marker, marker + "\n        if (request.headers.containsKey('origin')) {\n          return Response.forbidden('Local development tools only');\n        }")
api.write_text(text)

bridge = dep / 'packages/java_mc_bridge/src'
shutil.copytree(bridge / 'main', root / '.redstone/bridge', dirs_exist_ok=True)
shutil.copytree(bridge / 'client', root / '.redstone/bridge/client', dirs_exist_ok=True)
shutil.copy2(dep / 'LICENSE', root / '.redstone/bridge/resources/REDSTONE-LICENSE.txt')
native = dep / 'packages/native_mc_bridge'
dll = native / 'deps/dart_dll'
if not (dll / 'lib/libdart_dll.dylib').exists():
    with tempfile.TemporaryDirectory() as tmp:
        archive = Path(tmp) / 'dart-dll.zip'
        urllib.request.urlretrieve('https://github.com/fuzzybinary/dart_shared_library/releases/download/0.2.0/lib-macos.zip', archive)
        with zipfile.ZipFile(archive) as package:
            package.extractall(dll)
        (dll / 'lib').mkdir(exist_ok=True)
        shutil.copy2(dll / 'bin/libdart_dll.dylib', dll / 'lib/libdart_dll.dylib')
jdk = os.environ.get('NATIVE_JAVA_HOME') or subprocess.check_output(['/usr/libexec/java_home'], text=True).strip()
env = dict(os.environ, JAVA_HOME=jdk)
run(['cmake', '-S', native, '-B', native / 'build-server', '-DSERVER_ONLY=ON'], env=env)
run(['cmake', '--build', native / 'build-server', '-j', '4'])
(root / '.redstone/native').mkdir(parents=True, exist_ok=True)
for name in ['dart_mc_bridge.dylib', 'libdart_mc_bridge.dylib']:
    shutil.copy2(native / 'build-server/dart_mc_bridge.dylib', root / '.redstone/native' / name)
shutil.copy2(dll / 'lib/libdart_dll.dylib', root / '.redstone/native/libdart_dll.dylib')
run(['dart', 'pub', 'get'])
print('Ready. Build with: cd minecraft && sh gradlew assemble')
