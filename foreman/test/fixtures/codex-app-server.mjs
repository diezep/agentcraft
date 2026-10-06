#!/usr/bin/env node
import { createInterface } from 'node:readline';
const send = (packet) => process.stdout.write(JSON.stringify(packet) + '\n');
createInterface({ input: process.stdin }).on('line', (line) => {
  const m = JSON.parse(line);
  if (m.method === 'exit') return process.exit(7);
  if (m.method === 'invalid') return process.stdout.write('not json\n');
  if (m.method === 'ask') {
    send({ id: 'server-request', method: 'item/tool/call', params: { tool: 'test' } });
    send({ method: 'notification', params: { waiting: true } });
  }
  if (m.id === 'server-request') send({ method: 'answered', params: m.result ?? m.error });
  else if (m.id !== undefined) send({ id: m.id, result: { method: m.method, params: m.params } });
});
