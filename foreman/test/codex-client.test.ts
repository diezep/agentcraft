import path from 'node:path';
import { afterEach, expect, it } from 'vitest';
import { AppServerClient } from '../src/agents/codex/client.js';
import { until } from './helpers.js';
const clients: AppServerClient[] = [];
afterEach(() => { for (const c of clients.splice(0)) c.close(); });
function client(command = process.execPath) {
  const c = new AppServerClient(command, process.cwd(), process.env, undefined, [path.resolve('test/fixtures/codex-app-server.mjs')]); clients.push(c); return c;
}
it('correlates requests and keeps reading while a server request waits', async () => {
  const c = client(); await c.initialize(); let answer!: (value: unknown) => void;
  c.onRequest = () => new Promise((resolve) => { answer = resolve; });
  const events: string[] = []; c.onNotification = (method) => events.push(method);
  await c.request('ask', {});
  await until(() => events.includes('notification'));
  expect(await c.request('ping', { n: 7 })).toEqual({ method: 'ping', params: { n: 7 } });
  answer({ success: true }); await until(() => events.includes('answered'));
});
it.each(['exit', 'invalid'])('rejects outstanding calls when the subprocess sends %s', async (method) => {
  const c = client(); await c.initialize();
  await expect(c.request(method, {})).rejects.toThrow();
  await expect(c.request('ping', {})).rejects.toThrow('closed');
});
it('explains a missing CLI without hanging', async () => {
  const c = client('/missing-agentcraft-codex');
  await expect(c.initialize()).rejects.toThrow('Install Codex CLI');
});
