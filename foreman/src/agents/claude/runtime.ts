import { spawn } from 'node:child_process';
import { query, type Options } from '@anthropic-ai/claude-agent-sdk';
import type { ClaudeConfig } from '../../config.js';
import type { AgentRuntime, RunContext } from '../team/runtime.js';
import { agentEnv } from '../team/index.js';
import { detectApiAuth, NO_API_AUTH_MESSAGE, withAuthMode } from './auth.js';
import { StreamMapper, type TurnStats } from './stream.js';
import { buildMcpServer, MCP_SERVER } from '../team/tools.js';

export interface ClaudeBackendOptions {
  queryFn?: typeof query;
  skipAuthCheck?: boolean;
}

export class ClaudeRuntime implements AgentRuntime {
  readonly name = 'claude' as const;
  private queryFn: typeof query;
  constructor(private cfg: ClaudeConfig, private opts: ClaudeBackendOptions = {}) {
    this.queryFn = opts.queryFn ?? query;
  }
  async checkAuth(): Promise<string> {
    if (this.opts.skipAuthCheck) return 'test';
    const api = detectApiAuth(process.env);
    if (!this.cfg.useClaudeLogin && !api.ok) throw new Error(NO_API_AUTH_MESSAGE);
    async function* never(): AsyncGenerator<never> { await new Promise(() => undefined); }
    const q = this.queryFn({ prompt: never(), options: { settingSources: [], persistSession: false, permissionMode: 'default', env: withAuthMode(agentEnv(), this.cfg.useClaudeLogin) } });
    let timer: NodeJS.Timeout | undefined;
    try {
      const info = await Promise.race([q.accountInfo(), new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new Error('timed out after 45s')), 45_000); })]);
      const ok = !!(info.email || info.organization || (info.apiKeySource && info.apiKeySource !== 'none') || (info.tokenSource && info.tokenSource !== 'none') || (info.apiProvider && info.apiProvider !== 'firstParty'));
      if (!ok) throw new Error('not logged in');
      return this.cfg.useClaudeLogin
        ? [info.organization, info.subscriptionType].filter(Boolean).join(' · ') || info.apiProvider || 'ok'
        : [api.ok ? api.source : 'API', info.organization].filter(Boolean).join(' · ');
    } catch (e) {
      throw new Error(`Claude ${this.cfg.useClaudeLogin ? 'login' : 'API'} check failed: ${(e as Error).message}. ${this.cfg.useClaudeLogin ? 'Run `claude` and /login' : 'Check ANTHROPIC_API_KEY (or your cloud provider settings)'}, then restart the Foreman. The sim backend still works.`);
    } finally {
      clearTimeout(timer);
      q.close();
    }
  }
  async run(ctx: RunContext): Promise<TurnStats> {
    const { fm, agentId, cwd, role, model, resume, abort, turn } = ctx;
    const options: Options = {
      cwd,
      model,
      effort: role === 'lead' ? ctx.cfg.leadEffort : ctx.cfg.effort,
      maxTurns: role === 'lead' ? ctx.cfg.maxTurnsLead : ctx.cfg.maxTurnsWorker,
      settingSources: [],
      permissionMode: 'default',
      canUseTool: ctx.canUseTool,
      tools: role === 'lead' ? ['Read', 'Grep', 'Glob'] : ['Read', 'Grep', 'Glob', 'Edit', 'Write', 'Bash', 'TodoWrite'],
      // no allowedTools: every tool call (incl. our MCP tools) goes through canUseTool/policy
      disallowedTools: ['Bash(git push:*)', 'Task', 'Agent', 'WebSearch', 'WebFetch'],
      mcpServers: { [MCP_SERVER]: buildMcpServer(fm, agentId, role, ctx.hooks, turn) },
      systemPrompt: { type: 'preset', preset: 'claude_code', append: ctx.systemPrompt },
      abortController: abort,
      env: withAuthMode(agentEnv(process.env, { agentId, cwd }), this.cfg.useClaudeLogin),
      // we spawn the CLI ourselves (same as the SDK's local spawn) so its pid is known: a stopped
      // turn's whole process tree can then be ended before its worktree is handed on
      spawnClaudeCodeProcess: (o) => {
        const child = spawn(o.command, o.args, { cwd: o.cwd, env: o.env as NodeJS.ProcessEnv, stdio: ['pipe', 'pipe', 'pipe'], signal: o.signal, windowsHide: true });
        child.stderr?.setEncoding('utf8');
        child.stderr?.on('data', (s: string) => fm.log.debug(`[${agentId} stderr] ${s.trim().slice(0, 300)}`));
        child.on('error', (e) => fm.log.debug(`[${agentId}] CLI process error: ${e.message}`));
        ctx.onSpawn(child);
        return child;
      },
      ...(resume ? { resume } : {}),
      ...(ctx.cfg.maxBudgetUsdPerTurn ? { maxBudgetUsd: ctx.cfg.maxBudgetUsdPerTurn } : {}),
    };
    const mapper = new StreamMapper(fm, agentId, cwd, role);
    const q = this.queryFn({ prompt: ctx.prompt, options });
    const close = () => q.close();
    if (abort.signal.aborted) close();
    else abort.signal.addEventListener('abort', close, { once: true });
    try {
      for await (const msg of q) {
        if (abort.signal.aborted) break;
        mapper.handle(msg);
        if (mapper.stats.sessionId) ctx.onSession(mapper.stats.sessionId);
      }
      return mapper.stats;
    } finally {
      abort.signal.removeEventListener('abort', close);
      q.close();
    }
  }
}
