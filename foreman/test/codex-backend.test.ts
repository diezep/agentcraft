import fs from 'node:fs';
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { CodexBackend } from '../src/agents/codex/index.js';
import { CodexRuntime } from '../src/agents/codex/runtime.js';
import type { RpcClient } from '../src/agents/codex/client.js';
import type { RunContext } from '../src/agents/team/runtime.js';
import { loadConfig } from '../src/config.js';
import { BackendName } from '../src/protocol.js';
import { demoRepo, makeForeman, rmrf, tempDir, until, type Harness } from './helpers.js';

class FakeClient implements RpcClient {
  onNotification: RpcClient['onNotification'] = () => {};
  onRequest: RpcClient['onRequest'] = async () => ({});
  onClose: RpcClient['onClose'] = () => {};
  calls: Array<{ method: string; params: Record<string, any> }> = [];
  closed = false;
  threadId = '';
  constructor(private script: (client: FakeClient, text: string) => Promise<void> = async () => {}, private accountType: string | null = 'chatgpt') {}
  async request(method: string, params: Record<string, any>): Promise<any> {
    this.calls.push({ method, params });
    if (method === 'account/read') return { account: this.accountType ? { type: this.accountType, planType: 'plus' } : null };
    if (method === 'config/read') return { config: { mcp_servers: { external: { enabled: true } } } };
    if (method === 'thread/start' || method === 'thread/resume') {
      this.threadId = params.threadId ?? `thread-${Math.random()}`;
      return { thread: { id: this.threadId } };
    }
    if (method === 'turn/start') {
      setTimeout(() => void this.script(this, params.input[0].text).catch((e) => this.onClose(e)), 0);
      return { turn: { id: 'turn' } };
    }
    return {};
  }
  tool(name: string, args: Record<string, unknown> = {}): Promise<any> {
    return this.onRequest('item/tool/call', { threadId: this.threadId, namespace: null, tool: name, arguments: args });
  }
  event(method: string, params: Record<string, unknown>): void { this.onNotification(method, { threadId: this.threadId, ...params }); }
  complete(status = 'completed'): void { this.event('turn/completed', { turn: { id: 'turn', status, ...(status === 'failed' ? { error: { message: 'Usage limit reached' } } : {}) } }); }
  close(): void { this.closed = true; this.onClose(new Error('closed')); }
}

const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => { for (const cleanup of cleanups.splice(0)) await cleanup(); });
function harness(args: string[] = []): Harness {
  const home = tempDir(); const h = makeForeman(home, ['--backend', 'codex', ...args]);
  cleanups.push(async () => { await h.fm.close(); rmrf(home); });
  return h;
}
function context(h: Harness, role: 'lead' | 'worker' = 'worker'): RunContext {
  return {
    fm: h.fm, cfg: h.cfg.codex, agentId: role === 'lead' ? 'marlow' : 'kit', role,
    cwd: h.home, model: 'default', prompt: 'test', systemPrompt: 'test', abort: new AbortController(),
    turn: { signal: new AbortController().signal, reason: () => undefined },
    hooks: { onReview() {}, onChangesRequested() {}, onTasksChanged() {}, onMergeRequested() {}, onWaiting() {} },
    canUseTool: async () => ({ behavior: 'deny', message: 'test' }), onSpawn() {}, onSession() {},
  };
}

describe('Codex backend', () => {
  it.each(['apiKey', null])('rejects %s authentication instead of silently billing the API', async (type) => {
    const h = harness(); const client = new FakeClient(undefined, type);
    await expect(new CodexRuntime(h.cfg.codex, { connect: async () => client }).checkAuth()).rejects.toThrow('ChatGPT login');
    expect(client.closed).toBe(true);
  });
  it('accepts ChatGPT authentication and closes the probe', async () => {
    const h = harness(); const c = new FakeClient();
    expect(await new CodexRuntime(h.cfg.codex, { connect: async () => c }).checkAuth()).toBe('ChatGPT · plus');
    expect(c.closed).toBe(true);
  });
  it('advertises role-scoped validated tools and a read-only lead', async () => {
    const h = harness(); let invalid: any;
    const c = new FakeClient(async (c) => {
      invalid = await c.tool('create_task', { title: 4 });
      expect(await c.onRequest('item/commandExecution/requestApproval', { threadId: c.threadId, command: 'touch outside' })).toEqual({ decision: 'decline' });
      c.complete();
    });
    await new CodexRuntime(h.cfg.codex, { connect: async () => c }).run(context(h, 'lead'));
    expect(invalid.success).toBe(false); expect(h.fm.tasks.list()).toHaveLength(0);
    const p = c.calls.find((x) => x.method === 'thread/start')!.params;
    expect(p.sandbox).toBe('read-only'); expect(p.approvalPolicy).toBe('never');
    expect(p.model).toBeUndefined();
    expect(p.dynamicTools.find((t: any) => t.name === 'create_task').inputSchema.type).toBe('object');
  });
  it('waits for in-game command approval before allowing escalation', async () => {
    const h = harness(); const ctx = context(h); let answer: any;
    const c = new FakeClient(async (c) => { answer = await c.onRequest('item/commandExecution/requestApproval', { threadId: c.threadId, command: 'npm install', reason: 'Network needed' }); c.complete(); });
    const run = new CodexRuntime(h.cfg.codex, { connect: async () => c }).run(ctx);
    await until(() => h.fm.decisions.open().length === 1);
    expect(answer).toBeUndefined();
    const d = h.fm.decisions.open()[0]!; expect(d.context).toContain('npm install');
    await h.fm.answerDecision(d.id, 'Allow once'); await run;
    expect(answer).toEqual({ decision: 'accept' });
    const p = c.calls.find((x) => x.method === 'thread/start')!.params;
    expect(p.sandbox).toBe('workspace-write');
    expect(p.config['shell_environment_policy.set'].GIT_ALLOW_PROTOCOL).toBe('agentcraft-none');
    expect(p.dynamicTools.some((t: any) => t.name === 'create_task')).toBe(false);
  });
  it('aborts a waiting request, closes transport and rejects late tools', async () => {
    const h = harness(); const ctx = context(h); let pending!: Promise<unknown>;
    const c = new FakeClient(async (c) => { pending = c.onRequest('item/fileChange/requestApproval', { threadId: c.threadId, itemId: 'edit' }); await pending; });
    const run = new CodexRuntime(h.cfg.codex, { connect: async () => c }).run(ctx);
    const rejected = expect(run).rejects.toThrow('stopped');
    await until(() => h.fm.decisions.open().length === 1);
    ctx.abort.abort(); await rejected;
    expect(c.closed).toBe(true); expect(h.fm.decisions.open()).toHaveLength(0);
    expect(await pending).toEqual({ decision: 'decline' });
    await expect(c.tool('write_memory', { title: 'late', body: 'late' })).rejects.toThrow('Inactive');
  });
  it('routes native questions and grants only the requested permissions for one turn', async () => {
    const h = harness(); const ctx = context(h); let input: any; let grant: any;
    const c = new FakeClient(async (c) => {
      input = await c.onRequest('item/tool/requestUserInput', { threadId: c.threadId, questions: [{ id: 'choice', question: 'Which format?', options: [{ label: 'JSON' }] }] });
      grant = await c.onRequest('item/permissions/requestApproval', { threadId: c.threadId, permissions: { network: { enabled: true }, fileSystem: null } });
      expect(await c.onRequest('item/commandExecution/requestApproval', { threadId: c.threadId, command: 'git push origin main' })).toEqual({ decision: 'decline' });
      c.complete();
    });
    const run = new CodexRuntime(h.cfg.codex, { connect: async () => c }).run(ctx);
    await until(() => h.fm.decisions.open().some((d) => d.kind === 'question'));
    await h.fm.answerDecision(h.fm.decisions.open()[0]!.id, 'JSON');
    await until(() => h.fm.decisions.open().some((d) => d.kind === 'permission'));
    await h.fm.answerDecision(h.fm.decisions.open()[0]!.id, 'Allow for this turn');
    await run;
    expect(input).toEqual({ answers: { choice: { answers: ['JSON'] } } });
    expect(grant).toEqual({ permissions: { network: { enabled: true } }, scope: 'turn' });
    const p = c.calls.find((x) => x.method === 'thread/start')!.params;
    expect(p.config['mcp_servers.external.enabled']).toBe(false);
    expect(p.config['features.hooks']).toBe(false);
  });
  it('resumes saved threads and propagates failed turns without invented dollar costs', async () => {
    const h = harness(); const ctx = context(h); ctx.resume = 'saved-thread';
    const c = new FakeClient(async (c) => c.complete('failed'));
    const result = await new CodexRuntime(h.cfg.codex, { connect: async () => c }).run(ctx);
    expect(c.calls.some((x) => x.method === 'thread/start')).toBe(false);
    expect(result).toMatchObject({ sessionId: 'saved-thread', isError: true, errors: ['Usage limit reached'] });
    expect(result.costUsd).toBeUndefined();
  });
  it('plans, edits an isolated worktree, runs CI, reviews and merges only on approval', async () => {
    const repo = await demoRepo(); cleanups.push(async () => rmrf(path.dirname(repo)));
    const h = harness(['--repo', repo, '--workers', 'kit']);
    const clients: FakeClient[] = [];
    const backend = new CodexBackend(h.fm, h.cfg.codex, { connect: async (ctx) => {
      const c = new FakeClient(async (c, text) => {
        if (text.startsWith('New goal')) {
          await c.tool('write_memory', { title: 'Plan: docs', body: 'Update README' });
          await c.tool('create_task', { title: 'Docs', description: 'Add a note', assignee: 'kit' });
        } else if (ctx?.role === 'worker') {
          fs.appendFileSync(path.join(ctx.cwd, 'README.md'), '\nCodex backend test.\n');
          c.event('item/completed', { item: { type: 'fileChange', id: 'edit', changes: [{ path: 'README.md', diff: '+ Codex backend test.' }] } });
          const denied = await c.tool('create_task', { title: 'Forbidden', description: 'worker cannot schedule' });
          expect(denied.success).toBe(false);
          await c.tool('update_task', { task_id: 't1', status: 'review', summary: 'Added docs' });
        } else if (text.startsWith('Review request')) {
          await c.tool('request_merge', { task_id: 't1', summary: 'Reviewed' });
        }
        c.complete();
      }); clients.push(c); return c;
    } });
    await h.fm.start(backend); const goal = await h.fm.submitGoal('Update docs');
    await until(() => h.fm.decisions.open().some((d) => d.kind === 'merge'), 60_000);
    expect(fs.readFileSync(path.join(repo, 'README.md'), 'utf8')).not.toContain('Codex backend test.');
    expect(h.fm.tasks.get('t1')!.ci).toBe('pass');
    const merge = h.fm.decisions.open().find((d) => d.kind === 'merge')!;
    await h.fm.answerDecision(merge.id, 'Merge');
    expect(h.fm.goal(goal.id)!.status).toBe('done');
    expect(fs.readFileSync(path.join(repo, 'README.md'), 'utf8')).toContain('Codex backend test.');
    expect(h.fm.store.data.sessions['kit:t1']!.sessionId).toMatch(/^thread-/);
    expect(h.fm.store.data.backend.codex).toBeDefined(); expect(h.fm.store.data.backend.claude).toBeUndefined();
    expect(clients.some((c) => c.calls.some((x) => x.method === 'thread/resume'))).toBe(true);
  }, 90_000);
});

describe('Codex configuration', () => {
  it('has its own profile and defaults, with model overrides', () => {
    const home = tempDir(); cleanups.push(async () => rmrf(home));
    const cfg = loadConfig(['--home', home, '--backend', 'codex', '--model', 'test-model', '--codex-command', '/custom/codex'], {});
    expect(cfg.codex).toMatchObject({ leadModel: 'test-model', workerModel: 'test-model', command: '/custom/codex' });
    expect(cfg.profile).toBe('codex'); expect(BackendName.parse('codex')).toBe('codex');
    expect(() => loadConfig(['--home', home, '--backend', 'codex', '--max-budget', '5'], {})).toThrow('--max-budget');
    expect(() => loadConfig(['--home', home, '--backend', 'codex', '--effort', 'max'], {})).toThrow('effort');
  });
});
