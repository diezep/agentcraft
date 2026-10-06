import type { CodexConfig } from '../../config.js';
import type { Foreman } from '../../foreman.js';
import { TeamBackend } from '../team/index.js';
import { CodexRuntime, type CodexRuntimeOptions } from './runtime.js';

export class CodexBackend extends TeamBackend {
  constructor(fm: Foreman, cfg: CodexConfig, opts: CodexRuntimeOptions = {}) {
    super(fm, cfg, new CodexRuntime(cfg, opts));
  }
}
