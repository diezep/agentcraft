#!/usr/bin/env python3
"""Read-only in-game smoke checks against Redstone's local development API."""
import json
import urllib.request

base = 'http://127.0.0.1:8766'
def call(path, payload=None):
    request = urllib.request.Request(base + path,
        data=None if payload is None else json.dumps(payload).encode(),
        headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(request, timeout=15) as response:
        return json.load(response)

assert call('/health')['gameReady']
assert call('/block?x=0&y=200&z=0')['blockId'] == 'minecraft:lectern'
assert call('/block?x=-4&y=201&z=-2')['blockId'] == 'minecraft:redstone_lamp'
assert call('/block?x=4&y=201&z=-2')['blockId'] == 'minecraft:redstone_lamp'
entities = call('/entities?centerX=0&centerY=200&centerZ=0&radius=10')['entities']
assert any(e['type'] == 'minecraft:villager' for e in entities)
call('/command', {'command': 'execute as @p run craftstatus'})
print(json.dumps(call('/screenshot', {'name': 'agentcraft-native-smoke'}), indent=2))
print('Native workshop smoke checks passed. No work order or approval was submitted.')
