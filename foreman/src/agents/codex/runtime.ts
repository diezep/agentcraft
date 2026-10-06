import path from 'node:path';
import { z } from 'zod';
import type { CodexConfig } from '../../config.js';
import { withGitSafety, gitSafetyEnv } from '../../gitsafety.js';
import { agentGitIdentity } from '../../util/git.js';
import { classifyToolUse } from '../../policy.js';
import { truncate } from '../../util/text.js';
import type { TurnStats } from '../claude/stream.js';
import { toolActivity } from '../activity.js';
import type { AgentRuntime, RunContext } from '../team/runtime.js';
import { buildTools } from '../team/tools.js';
import { AppServerClient, type RpcClient } from './client.js';

export interface CodexRuntimeOptions {
  /** Protocol fake for tests; production always spawns the installed CLI. */
  connect?: (ctx?: RunContext) => Promise<RpcClient>;
}

export class CodexRuntime implements AgentRuntime {
  readonly name = 'codex' as const;
  constructor(private cfg: CodexConfig, private opts: CodexRuntimeOptions = {}) {}

  private async connect(ctx?: RunContext): Promise<RpcClient> {
    if (this.opts.connect) return this.opts.connect(ctx);
    const env = ctx ? withGitSafety(process.env, agentGitIdentity(ctx.agentId) as Record<string, string>, { ceiling: path.dirname(ctx.cwd) }) : { ...process.env };
    // Never let an inherited API key silently select API billing.
    delete env.OPENAI_API_KEY;
    const client = new AppServerClient(this.cfg.command, ctx?.cwd ?? process.cwd(), env, (s) => ctx?.fm.log.debug(`[${ctx.agentId} codex] ${s}`));
    if (ctx) ctx.onSpawn(client.child);
    const close = () => client.close();
    ctx?.abort.signal.addEventListener('abort', close, { once: true });
    try {
      if (ctx?.abort.signal.aborted) throw new Error('Turn stopped');
      await client.initialize();
      return client;
    } catch (e) { client.close(); throw e; }
    finally { ctx?.abort.signal.removeEventListener('abort', close); }
  }

  private async account(client: RpcClient): Promise<string> {
    const { account } = await client.request('account/read', { refreshToken: true });
    if (account?.type !== 'chatgpt') throw new Error('Codex requires a ChatGPT login for this backend. Run `codex login` and choose Sign in with ChatGPT, then restart the Foreman. API-key accounts are not used.');
    return `ChatGPT${account.planType ? ` · ${account.planType}` : ''}`;
  }

  async checkAuth(): Promise<string> {
    const client = await this.connect();
    try { return await this.account(client); }
    finally { client.close(); }
  }

  async run(ctx: RunContext): Promise<TurnStats> {
    const client = await this.connect(ctx);
    const { fm, agentId, role, cwd, abort } = ctx;
    const stats: TurnStats = { isError: false, errors: [], numTurns: 0 };
    const definitions = buildTools(fm, agentId, role, ctx.hooks, ctx.turn);
    const tools = new Map(definitions.map((t) => [t.name, t]));
    const pendingDecisions = new Set<string>();
    const changes = new Map<string, Array<{ path: string; diff: string }>>();
    let threadId: string | undefined;
    let settled = false;
    let resolveDone!: (stats: TurnStats) => void;
    let rejectDone!: (error: Error) => void;
    const done = new Promise<TurnStats>((resolve, reject) => { resolveDone = resolve; rejectDone = reject; });
    void done.catch(() => {}); // a process may exit during setup, before completion is awaited
    const cancelDecisions = () => {
      for (const id of pendingDecisions) fm.decisions.cancel(id, 'Codex turn ended');
      pendingDecisions.clear();
    };
    const finish = (error?: Error) => {
      if (settled) return;
      settled = true; cancelDecisions();
      if (error) rejectDone(error); else resolveDone(stats);
    };
    const onAbort = () => { finish(new Error('Codex turn stopped')); client.close(); };
    abort.signal.addEventListener('abort', onAbort, { once: true });
    client.onClose = (error) => finish(error);

    const ask = async (kind: 'question' | 'permission', question: string, options: string[], context?: string): Promise<string[]> => {
      if (settled || abort.signal.aborted) return [];
      const prev = fm.agent(agentId);
      const restore = prev ? { state: prev.state, station: prev.station, activity: prev.activity } : undefined;
      const d = fm.createDecision({ agentId, kind, question, options, context, ...(prev?.taskId ? { taskId: prev.taskId } : {}) });
      pendingDecisions.add(d.id); ctx.hooks.onWaiting(agentId, true);
      fm.setAgent(agentId, { state: 'waiting_user', station: 'user', activity: kind === 'permission' ? 'asking permission' : 'waiting for your answer' });
      try {
        const result = await fm.decisions.wait(d.id);
        return result.status === 'answered' && !abort.signal.aborted ? [result.answer?.option, result.answer?.text].filter((x): x is string => !!x) : [];
      } finally {
        pendingDecisions.delete(d.id); ctx.hooks.onWaiting(agentId, false);
        if (restore && !settled && !abort.signal.aborted) fm.setAgent(agentId, restore);
      }
    };

    client.onRequest = async (method, p) => {
      if (settled || abort.signal.aborted || p.threadId !== threadId) throw new Error('Inactive Codex turn');
      if (method === 'item/tool/call') {
        const t = tools.get(p.tool);
        if (!t || p.namespace) return { success: false, contentItems: [{ type: 'inputText', text: 'Unknown AgentCraft tool' }] };
        try {
          const args = z.object(t.inputSchema).parse(p.arguments);
          const result = await t.handler(args, {} as never);
          return { success: !result.isError, contentItems: result.content.filter((c) => c.type === 'text').map((c) => ({ type: 'inputText', text: c.text })) };
        } catch (e) { return { success: false, contentItems: [{ type: 'inputText', text: (e as Error).message }] }; }
      }
      if (method === 'item/tool/requestUserInput' || method === 'tool/requestUserInput') {
        const answers: Record<string, { answers: string[] }> = {};
        for (const q of p.questions ?? []) answers[q.id] = { answers: await ask('question', q.question, (q.options ?? []).map((o: { label: string }) => o.label), q.header) };
        return { answers };
      }
      if (method === 'item/commandExecution/requestApproval' || method === 'item/fileChange/requestApproval') {
        // The lead cannot escalate out of its read-only sandbox.
        if (role === 'lead') return { decision: 'decline' };
        if (method.includes('commandExecution') && p.command) {
          const verdict = classifyToolUse('Bash', { command: p.command }, { role, cwd, readDirs: [fm.memory.dir], alwaysAllow: [], mcpServer: 'agentcraft' });
          if (verdict.action === 'deny') { fm.agentLog(agentId, 'error', `blocked: ${verdict.reason}`); return { decision: 'decline' }; }
        }
        const description = method.includes('commandExecution')
          ? `${p.command ?? 'Network access'}${p.networkApprovalContext ? `\nNetwork: ${JSON.stringify(p.networkApprovalContext)}` : ''}`
          : (changes.get(p.itemId) ?? []).map((c) => `${c.path}\n${c.diff}`).join('\n') || 'File change';
        const answer = await ask('permission', `${fm.nameOf(agentId)} requests Codex approval`, ['Allow once', 'Deny'], `${description}\n${p.reason ?? ''}\ncwd: ${p.cwd ?? cwd}${p.grantRoot ? `\nGrant root: ${p.grantRoot}` : ''}${p.additionalPermissions ? `\nAdditional permissions: ${JSON.stringify(p.additionalPermissions)}` : ''}`);
        return { decision: answer[0] === 'Allow once' ? 'accept' : 'decline' };
      }
      if (method === 'item/permissions/requestApproval') {
        if (role === 'lead') return { permissions: {}, scope: 'turn' };
        const answer = await ask('permission', `${fm.nameOf(agentId)} requests additional Codex permissions`, ['Allow for this turn', 'Deny'], `${p.reason ?? ''}\nGranted only until this turn ends:\n${JSON.stringify(p.permissions)}`);
        const granted = Object.fromEntries(Object.entries(p.permissions ?? {}).filter(([, value]) => value !== null));
        return { permissions: answer[0] === 'Allow for this turn' ? granted : {}, scope: 'turn' };
      }
      if (method === 'mcpServer/elicitation/request') return { action: 'decline', content: null };
      throw new Error(`Unsupported Codex request: ${method}`);
    };

    client.onNotification = (method, p) => {
      if (settled || abort.signal.aborted || (p.threadId && p.threadId !== threadId)) return;
      const item = p.item;
      if (method === 'item/started' && item) {
        let activity;
        if (item.type === 'commandExecution') activity = toolActivity('Bash', { command: item.command }, cwd);
        if (item.type === 'fileChange') { changes.set(item.id, item.changes ?? []); activity = toolActivity('Edit', { file_path: item.changes?.[0]?.path }, cwd); }
        if (item.type === 'dynamicToolCall') activity = toolActivity(`mcp__agentcraft__${item.tool}`, item.arguments ?? {}, cwd);
        if (activity) {
          fm.agentLog(agentId, 'tool', activity.label);
          if (fm.agent(agentId)?.state !== 'waiting_user') fm.setAgent(agentId, { state: activity.state, station: activity.station, activity: activity.activity });
        }
      }
      if (method === 'item/completed' && item) {
        if (item.type === 'agentMessage') {
          stats.resultText = item.text; stats.numTurns = (stats.numTurns ?? 0) + 1;
          if (item.text) fm.agentLog(agentId, 'text', truncate(item.text, 1200));
          const limit = role === 'lead' ? ctx.cfg.maxTurnsLead : ctx.cfg.maxTurnsWorker;
          if (stats.numTurns > limit) { finish(new Error(`Codex exceeded --max-turns (${limit} messages)`)); client.close(); }
        }
        if (item.type === 'commandExecution') fm.agentLog(agentId, item.exitCode ? 'error' : 'result', truncate(item.aggregatedOutput ?? item.status, 1200));
        if (item.type === 'fileChange') {
          for (const c of item.changes ?? []) fm.agentLog(agentId, 'diff', truncate(`${c.path}\n${c.diff}`, 2000));
          const repo = fm.agent(agentId)?.repoId;
          if (repo) fm.repos.scheduleRefresh(repo, 500);
        }
      }
      if (method === 'error' && p.error?.message) fm.agentLog(agentId, 'error', truncate(p.error.message, 800));
      if (method === 'turn/completed') {
        stats.isError = p.turn.status !== 'completed'; stats.subtype = stats.isError ? p.turn.status : 'success';
        if (p.turn.error?.message) {
          stats.errors.push(p.turn.error.message);
          if (/unauthorized|authentication|not logged in|invalid.*token|401/i.test(p.turn.error.message)) stats.authFailed = p.turn.error.message;
        }
        fm.agentLog(agentId, stats.isError ? 'error' : 'result', `Codex turn ${p.turn.status}${stats.errors.length ? `: ${stats.errors.join('; ')}` : ''}`);
        finish();
      }
    };

    try {
      if (abort.signal.aborted) throw new Error('Turn stopped');
      await this.account(client);
      const safety = { ...gitSafetyEnv(process.env, { ceiling: path.dirname(cwd) }), ...agentGitIdentity(agentId) };
      // Do not expose the player's unrelated MCP integrations to coding workers.
      const effective = await client.request('config/read', { cwd, includeLayers: false });
      const config: Record<string, unknown> = {
        model_provider: 'openai', web_search: 'disabled', 'features.multi_agent': false, 'features.apps': false, 'features.plugins': false, 'features.hooks': false,
        'shell_environment_policy.set': safety, 'sandbox_workspace_write.network_access': false,
      };
      for (const name of Object.keys(effective.config?.mcp_servers ?? {})) config[`mcp_servers.${name}.enabled`] = false;
      const params = {
        cwd, approvalPolicy: role === 'lead' ? 'never' : 'on-request', approvalsReviewer: 'user',
        sandbox: role === 'lead' ? 'read-only' : 'workspace-write',
        developerInstructions: `${ctx.systemPrompt}\nUse your native Codex tools for reading/searching/editing files. AgentCraft coordination tools are provided as dynamic tools. Do not spawn subagents.`,
        config, ...(ctx.model !== 'default' ? { model: ctx.model } : {}),
      };
      const response = ctx.resume
        ? await client.request('thread/resume', { ...params, threadId: ctx.resume })
        : await client.request('thread/start', { ...params, dynamicTools: definitions.map((t) => ({ type: 'function', name: t.name, description: t.description, inputSchema: z.toJSONSchema(z.object(t.inputSchema)), deferLoading: false })) });
      threadId = response.thread.id; stats.sessionId = threadId; ctx.onSession(threadId!);
      await client.request('turn/start', { threadId, input: [{ type: 'text', text: ctx.prompt, text_elements: [] }], effort: role === 'lead' ? ctx.cfg.leadEffort : ctx.cfg.effort });
      return await done;
    } finally {
      settled = true; cancelDecisions();
      abort.signal.removeEventListener('abort', onAbort); client.close();
    }
  }
}
