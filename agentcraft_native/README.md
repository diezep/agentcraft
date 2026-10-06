# AgentCraft Native (Redstone.Dart prototype)

A small single-player Minecraft-native frontend for the existing AgentCraft Foreman/Codex backend.
The mod logic is Dart; Minecraft renders the actual villager, lectern book, chat,
blocks and redstone lamps. There is no Flutter screen or separate dashboard.

## Play

Launch **AgentCraft Native — Dart workshop** in Prism Launcher. This prototype
uses **Minecraft 1.21.11**, Fabric Loader 0.19.5 and Fabric API 0.139.4. Redstone's
Java bridge currently targets that version; the existing 26.3 AgentCraft instance
is separate.

- `/craftworkshop` builds an elevated workshop at **0, 200, 0** and teleports you there.
  Use the dedicated prototype world: this command places blocks in that fixed area.
- Right-click **Marlow** for the live team status and clickable work-order controls.
  This opens vanilla chat so you can click the links immediately.
- Right-click the **lectern** to read the live journal. Pages show agents, tasks and recent logs.
- The **left redstone lamp** indicates work in progress; the **right lamp** and a
  bell indicate a request waiting for you.
- `/craftgoal <work order>` submits to the **agentcraft** repository in Foreman.
- `/craftdecisions` shows complete request context and explicit answer choices.
  Questions also provide a free-text reply link. Stale/offline requests are rejected.

The Foreman remains at `ws://127.0.0.1:7878`, using the existing ChatGPT-authenticated
Codex backend. The Dart mod never reads your OpenAI credentials. Network reconnects
refresh the snapshot and never automatically replay work orders or approvals.
Commands that change repository work require Minecraft permission level 2.

## Build on macOS (development install)

Prerequisites: Dart, CMake, a full JDK 21+ (headers needed for JNI), Git, Python 3,
and Prism Launcher. This is a local source-based development install, not a
standalone distributable jar. Keep the checkout paths available after installation.

From this directory:

```sh
python3 scripts/setup.py
dart analyze packages
dart test packages/server/test
cd minecraft
sh gradlew assemble
cd ..
python3 scripts/install_prism.py
```

`setup.py` clones a sibling `redstone_dart` checkout pinned to
`0892d25c5fffc8a12964d1674fecf69ca0f28fae`, copies the Java bridge, obtains
upstream dart_dll 0.2.0, and builds Redstone's server-only native library.
Set `NATIVE_JAVA_HOME` to select the full JDK for CMake. Set `JAVA_HOME` for Gradle.
The installer currently uses Prism's managed Java 25 at `java-runtime-epsilon`.

The setup applies one local upstream patch: the optional Redstone development
control API binds only to loopback and rejects browser Origin headers. The
prototype instance enables it on **8766** for visual verification and automatically
opens Redstone's dedicated `dart_visual_test` world. Do not install alongside a
second Redstone mod jar: the upstream framework packages shared bridge classes.

## Verification and limitations

`python3 scripts/smoke.py` checks a running instance's native blocks and villager,
requests status without submitting model work, and saves a screenshot.

The first slice has one stationary villager representing the team, a live journal,
work-order submission, and explicit approval/reply controls. Worker movement,
individual NPCs, a full diff viewer and a Minecraft 26.3 bridge port remain future
work. Foreman's tests continue to cover the full coding/CI/merge lifecycle.

Redstone.Dart is experimental. Its current bridge logs an unrelated recipe-map
warning on this Minecraft version; this prototype adds no custom recipes.
See [Redstone.Dart](https://github.com/Norbert515/redstone_dart) (MIT license,
included in the generated mod jar).
