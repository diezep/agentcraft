# AgentCraft — Dart edition

Our Dart application on Redstone: a Dart Foreman, Codex app-server client,
repository/worktree manager, scheduler, persistence, launcher, and Minecraft game
logic. This edition does not start the legacy TypeScript Foreman. It keeps
Redstone's Java/JNI/native bridge and the installed Codex CLI.

The Minecraft experience uses vanilla villagers, a lectern journal, chat, lamps,
and a bell. No browser dashboard or Flutter overlay is required.

## Start playing

Launch **AgentCraft — Dart edition** in Prism Launcher. The prelaunch hook starts
our compiled Dart backend automatically. In the dedicated test world:

- `/craftworkshop` builds the workshop at **0, 200, 0** and teleports you there.
- Right-click Marlow to see status and clickable work-order/request links.
- Right-click the lectern for the team, task board, and recent logs.
- `/craftgoal <work order>` assigns work on the AgentCraft fork.
- `/craftdecisions` displays questions and merge requests; choose an explicit
  answer or use the provided free-text reply link.
- `/craftagent juniper pause|resume|stop|spawn` controls a worker. Stop takes them
  off shift; spawn brings them back with their saved work.
- `/crafttask t1 retry|cancel|prioritize` controls a task.
- `/craftmessage marlow <message>` sends a message; `all` addresses the team.

Use an individual action from the alternatives above. Commands that change work
require Minecraft permission level 2. Workshop placement changes blocks in its
fixed area, so use the dedicated development world.

This install uses **Minecraft 1.21.11**, the version targeted by the pinned
Redstone bridge. The existing Minecraft 26.3 and earlier Dart-workshop instances
are separate. This is not a port of the bridge to 26.3.

## Build and install on macOS

Requirements: Dart SDK, Git, CMake, a full JDK with JNI headers, Prism Launcher
with its managed Java 25 runtime, and Codex CLI signed in using **ChatGPT**.
API-key accounts are rejected; usage remains subject to your Codex plan limits.

From `foreman_dart/`:

```sh
dart pub get
dart analyze
dart test
mkdir -p build
dart compile exe bin/foreman_dart.dart -o build/agentcraft
./build/agentcraft build-mod --root ..
./build/agentcraft install-prism --root ..
./build/agentcraft launch
```

Set `JAVA_HOME` to the Java runtime for Gradle and `NATIVE_JAVA_HOME` to a full JDK
for CMake when they differ. `build-mod` prepares the sibling `redstone_dart` at
revision `0892d25c5fffc8a12964d1674fecf69ca0f28fae`, builds the native bridge,
and packages the Java glue. Installation preserves an existing world's files.
Keep this source checkout and the compiled executable available: this is a
source-based development install, not a standalone distributable mod jar.

The build, install, ensure, and launch commands are Dart implementations. Legacy
Python prototype scripts remain only for the older instance.

## Backend and CLI

Defaults: WebSocket `127.0.0.1:7877`, profile `~/.agentcraft/dart-native`, one active
worker plus Marlow. The development game API uses loopback port **8767** and
opens Redstone's `dart_visual_test` world. Neither service accepts browser Origin
headers. The game reads the backend port from `config/agentcraft_native.json`.

```sh
./build/agentcraft serve --repo .. --workers 2
./build/agentcraft status
./build/agentcraft send goal.submit '{"repoId":"agentcraft","text":"Your task"}'
./build/agentcraft send task.action '{"taskId":"t1","action":"reassign","arg":"kit"}'
./build/agentcraft send decision.answer '{"decisionId":"d1","option":"Merge"}'
./build/agentcraft stop
```

Don't run a second daemon with the same profile. `ensure` starts a detached
compiled daemon only when absent. For startup diagnostics use `serve` directly.
Use `--help` or `<command> --help` for options. Add the absolute `build` directory
to PATH if you want to invoke `agentcraft` without `./build/`.

Marlow plans and reviews read-only. Workers edit isolated Git worktrees, report
completion, then the host commits and runs tests before review. Merge requests
capture the reviewed commit and remain open until answered. Dirty base checkouts,
changed reviewed commits, and changed base branches refuse merging; conflicts
abort back to the pre-merge base. Nothing automatically pushes to GitHub.

Dart packages run `dart pub get` and `dart test`; this repository selects its
`foreman_dart` package. A root Node package with a test script uses its declared
package manager. Override with `--test-command '["executable","argument"]'`.
No discovered test command is reported as unknown, never as a passing test.

State is saved atomically with a profile lock. Interrupted jobs resume with the
same worktree and Codex thread; process-bound questions are cancelled on restart
and must be asked again. Merge decisions survive restart. Pause/cancel stops owned
Codex/test processes. Reconnects fetch current state without replaying commands.
Personal Codex MCP servers, apps, plugins, hooks and multi-agent tools are disabled
for these sessions; the orchestrator owns coordination and approvals.

## Verification and current boundaries

Automated tests cover the coding/review/merge lifecycle, persistence/recovery,
CI cancellation, dirty/changed-head merge refusal, RPC failures and approval
routing, structured diffs, CLI commands, and WebSocket access checks. A real
ChatGPT-authenticated Codex smoke test completed planning, an exact file edit,
review and approved merge in a temporary repository.

This first Dart edition intentionally keeps one stationary villager representing
the team. Individual worker NPCs, walking/building animations, an in-game full
diff viewer and newer Minecraft bridge versions remain future work. Structured
diffs are available through the backend protocol. Other model providers and
legacy profile migration are not implemented. Existing legacy sessions stay in
their original profiles.
