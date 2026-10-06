import type { ChildProcess } from 'node:child_process';
import type { CanUseTool } from '@anthropic-ai/claude-agent-sdk';
import type { TeamConfig } from '../../config.js';
import type { Foreman } from '../../foreman.js';
import type { TurnStats } from '../claude/stream.js';
import type { ToolHooks, TurnHandle } from './tools.js';

export interface RunContext {
  fm: Foreman;
  cfg: TeamConfig;
  agentId: string;
  role: 'lead' | 'worker';
  cwd: string;
  model: string;
  prompt: string;
  systemPrompt: string;
  resume?: string;
  abort: AbortController;
  turn: TurnHandle;
  hooks: ToolHooks;
  canUseTool: CanUseTool;
  onSpawn(child: ChildProcess): void;
  onSession(id: string): void;
}

export interface AgentRuntime {
  readonly name: 'claude' | 'codex';
  checkAuth(): Promise<string>;
  run(ctx: RunContext): Promise<TurnStats>;
}
