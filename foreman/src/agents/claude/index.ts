import type { ClaudeConfig } from '../../config.js';
import type { Foreman } from '../../foreman.js';
import { TeamBackend } from '../team/index.js';
import { ClaudeRuntime, type ClaudeBackendOptions } from './runtime.js';
export { agentEnv } from '../team/index.js';
export type { ClaudeBackendOptions } from './runtime.js';

export class ClaudeBackend extends TeamBackend {
  constructor(fm: Foreman, cfg: ClaudeConfig, opts: ClaudeBackendOptions = {}) {
    super(fm, cfg, new ClaudeRuntime(cfg, opts));
  }
}
