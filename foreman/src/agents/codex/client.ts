// Bidirectional app-server JSONL transport. Credentials stay with the installed Codex CLI.
import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { createInterface } from 'node:readline';
import { killTree } from '../../util/proc.js';

type Packet = { id?: number | string; method?: string; params?: Record<string, any>; result?: any; error?: { message: string; code?: number } };
export interface RpcClient {
  request(method: string, params: Record<string, unknown>): Promise<any>;
  onNotification: (method: string, params: Record<string, any>) => void;
  onRequest: (method: string, params: Record<string, any>) => Promise<unknown>;
  onClose: (error: Error) => void;
  close(): void;
}

export class AppServerClient implements RpcClient {
  readonly child: ChildProcessWithoutNullStreams;
  onNotification: RpcClient['onNotification'] = () => {};
  onRequest: RpcClient['onRequest'] = async () => { throw new Error('Unsupported server request'); };
  onClose: RpcClient['onClose'] = () => {};
  private nextId = 0;
  private closed = false;
  private pending = new Map<number, { resolve(value: unknown): void; reject(error: Error): void; timer: NodeJS.Timeout }>();

  constructor(command: string, cwd: string, env: NodeJS.ProcessEnv, onStderr: (text: string) => void = () => {}, args = ['app-server', '--listen', 'stdio://', '--disable', 'apps', '--disable', 'plugins', '--disable', 'hooks', '--disable', 'multi_agent']) {
    this.child = spawn(command, args, { cwd, env, stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true });
    const lines = createInterface({ input: this.child.stdout });
    lines.on('line', (line) => {
      try { this.receive(JSON.parse(line) as Packet); }
      catch (e) { this.fail(new Error(`Invalid Codex app-server message: ${(e as Error).message}`)); }
    });
    this.child.stderr.setEncoding('utf8');
    this.child.stderr.on('data', (s: string) => onStderr(s.slice(0, 500)));
    this.child.on('error', (e) => this.fail(new Error(`Cannot start Codex (${command}): ${e.message}. Install Codex CLI and run codex login.`)));
    this.child.stdin.on('error', (e) => this.fail(e));
    this.child.on('exit', (code, signal) => { lines.close(); this.fail(new Error(`Codex app-server exited (${signal ?? code})`)); });
  }
  private send(packet: Packet): void {
    if (this.closed) throw new Error('Codex app-server is closed');
    this.child.stdin.write(`${JSON.stringify(packet)}\n`);
  }
  request(method: string, params: Record<string, unknown>): Promise<any> {
    if (this.closed) return Promise.reject(new Error('Codex app-server is closed'));
    const id = ++this.nextId;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.pending.delete(id); reject(new Error(`Codex ${method} timed out after 45s`)); }, 45_000);
      this.pending.set(id, { resolve, reject, timer });
      this.send({ id, method, params });
    });
  }
  async initialize(): Promise<void> {
    await this.request('initialize', { clientInfo: { name: 'agentcraft', title: 'AgentCraft', version: '0.1.0' }, capabilities: { experimentalApi: true } });
    this.send({ method: 'initialized', params: {} });
  }
  private receive(msg: Packet): void {
    if (this.closed) return;
    if (msg.method && msg.id !== undefined) {
      // User answers may take minutes; never block the transport's reader.
      void this.onRequest(msg.method, msg.params ?? {}).then(
        (result) => { if (!this.closed) this.send({ id: msg.id, result }); },
        (e) => { if (!this.closed) this.send({ id: msg.id, error: { code: -32603, message: (e as Error).message } }); },
      );
    } else if (msg.method) this.onNotification(msg.method, msg.params ?? {});
    else if (typeof msg.id === 'number') {
      const p = this.pending.get(msg.id);
      if (!p) return;
      clearTimeout(p.timer); this.pending.delete(msg.id);
      if (msg.error) p.reject(new Error(msg.error.message)); else p.resolve(msg.result);
    }
  }
  private fail(error: Error): void {
    if (this.closed) return;
    this.closed = true;
    for (const p of this.pending.values()) { clearTimeout(p.timer); p.reject(error); }
    this.pending.clear();
    this.onClose(error);
    if (this.child.exitCode === null && this.child.signalCode === null) killTree(this.child);
  }
  close(): void { this.fail(new Error('Codex app-server closed')); }
}
