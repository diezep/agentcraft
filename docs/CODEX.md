# Codex backend

AgentCraft can run its lead and workers through the local Codex CLI's app-server, using **Sign in with ChatGPT**. All agents share the account's Codex allowance. This backend rejects API-key accounts and removes `OPENAI_API_KEY` from its child environment; it does not fall back to API billing.

## Setup

Install Node 22+, Git, and the Codex CLI. This integration was verified with **Codex CLI 0.160.1** and its experimental dynamic-tool API; upgrade the CLI if thread creation reports unsupported fields or tool schemas.

```sh
npm install -g @openai/codex
codex login
```

Choose **Sign in with ChatGPT**, then:

```sh
cd foreman
npm ci
npm start -- --backend codex --repo /absolute/path/to/repo --workers 1
```

For the macOS development client (requires Java 25):

```sh
node tools/mac.mjs launch --backend codex --repo /absolute/path/to/repo \
  --foreman-arg --workers --foreman-arg 1
```

Windows:

```powershell
tools\launch.ps1 -Backend codex -Repo C:\path\to\repo -ForemanArgs '--workers','1'
```

The default profile is `~/.agentcraft/codex`. `--profile` can select a separate workspace. The default model is the model configured in your Codex CLI; use `--model`, `--lead-model`, or `--worker-model` to override it with a model available to your account. Use `--codex-command /absolute/path/to/codex` (or `AGENTCRAFT_CODEX_COMMAND`) if the executable is not on PATH.

You can configure persistent defaults in `~/.agentcraft/config.json`:

```json
{
  "backend": "codex",
  "codex": {
    "workers": ["juniper"],
    "maxConcurrent": 1,
    "effort": "medium",
    "leadEffort": "medium"
  }
}
```

## Behavior and boundaries

- The existing team scheduler manages task dependencies, isolated worktrees, CI, reviews, conflict resolution, stopped workers, and restart recovery for both real backends.
- Each job starts a local app-server over stdio. Its thread ID is persisted and resumed for follow-ups and interrupted work. Login credentials remain managed by Codex; AgentCraft does not read or copy token files.
- The lead uses Codex's read-only sandbox and cannot approve escalation. Workers use its workspace-write sandbox, with network access disabled by default. Codex's command, file-change, and permission escalation requests appear at the podium; command/file approvals apply once, while explicit extra-permission grants last only until the current turn ends. These follow **Codex's sandbox approval boundaries**, rather than Claude's per-tool command classifier.
- AgentCraft's git transport/signing guards and agent identities are inherited by Codex's shell tools. These environment guards prevent accidental pushes; they are not a security boundary against deliberately hostile code.
- Personal MCP servers, app integrations, plugins, hooks, web search, and built-in subagents are disabled for these threads. Coordination is through the role-scoped AgentCraft dynamic tools.
- Pause/stop cancels active requests and terminates the app-server. The shared scheduler handles process-tree cleanup before handing a worktree to another worker. Merges remain explicit player decisions.
- `--effort` supports `low`, `medium`, `high`, and `xhigh`. The shared 45-minute job timeout applies. `--max-turns` limits completed assistant messages for Codex, which is not identical to Claude's SDK turn counter.
- `--max-budget` is unsupported. Codex does not report a comparable dollar cost, so AgentCraft does not invent one. Usage-limit errors are shown in the monitor; no paid API fallback occurs.

## Prism Launcher (Minecraft 26.3)

1. Create a **separate Minecraft 26.3** instance with **Fabric Loader 0.19.5+** and **Java 25**.
2. Build the mod from the repository's `mod` directory:
   ```sh
   JAVA_HOME=/path/to/java25 sh ./gradlew build
   ```
   On Windows use `gradlew.bat build`.
3. Put `mod/build/libs/agentcraft-0.1.0.jar` and Fabric API for **26.3** into that instance's `mods` folder. The build already bundles the WebSocket dependency.
4. Start the Foreman with the command above, then launch the instance in Prism. The mod connects to `127.0.0.1:7878` and creates/loads the AgentCraft HQ world.
5. Press the backtick key to enter a goal. Press **J** for pending questions, approvals, and merges.

For normal audio/focus, add these instance JVM arguments:

```text
--enable-native-access=ALL-UNNAMED -Dagentcraft.mute=0 -Dagentcraft.focus=1
```

Prism's instance-specific **Pre-launch command** can start the Foreman automatically. On macOS, run `node /absolute/path/to/agentcraft/tools/mac.mjs launch --backend codex --no-game --repo /absolute/path/to/repo` from a shell script that adds your Node/Codex installation directory to PATH. The Foreman keeps working after Minecraft closes; stop it explicitly with `node tools/mac.mjs stop --foreman --profile codex` (use your selected profile name).

## Verification

`cd foreman && npm run check` runs type checking, protocol-fake Codex tests, the existing orchestration tests, and protocol-document validation. The Codex tests cover ChatGPT authentication, API-key rejection, role-scoped tools, in-game approvals, cancellation, thread resume, subprocess failures, and plan → worktree → CI → review → player-approved merge without model calls.

Official references: [Codex App Server](https://learn.chatgpt.com/docs/app-server), [authentication](https://learn.chatgpt.com/docs/auth).
