# Architecture

Shed has two halves: a **bridge** that runs next to the agents on each computer, and **clients** (the Mac and iPhone apps) that connect to one or more bridges.

```
 iPhone app ─┐                                        ┌─ pi --mode rpc            one child process per Pi session
             ├─ WebSocket ──► bridge (Rust, :7878) ───┼─ dsh --profile shed       one child process per DeepSeek Harness session
 Mac app ────┘   Tailscale (HTTPS)                    └─ Prime daemon socket ──► every Prime session, subagents included

                              every agent's models ──► Open Codex (127.0.0.1:10100)
```

## Bridge

`bridge/` is a Rust service (tokio, axum) that `setup/install.sh` registers with launchd. It binds to `127.0.0.1` only; `tailscale serve` publishes it on the tailnet over HTTPS, which iOS requires. A bearer token from `~/.agent-remote/config.json` guards every connection, since the agents can run arbitrary code.

It turns the three agents into one client protocol (`bridge/src/protocol.rs`, mirrored in `apps/Sources/ShedKit/Protocol.swift`):

- one `SessionSummary` per session: status, model, effort, context usage, cost, queue, goal, background jobs, sites, capabilities, a question waiting for an answer, parent and children;
- a normalized transcript of `user`, `text`, `thinking`, `tool`, `compaction`, `error` and `note` items, streamed as `snapshot`, `item_add` and `item_patch` messages to the clients attached to that session;
- request/reply operations (`send`, `abort`, `compact`, `set_model`, `list_dir`, `list_jobs`, …), each answered by a `reply` with the request's `id`. A failed one carries the sentence to show (`error`) and, for the failures an app does something about, a `code` (`session_ended`, `no_such_directory`). Apps from before the codes compare the sentence, so those sentences are fixed (`bridge/src/protocol.rs`). An `attach` waits on the agent apart from the connection, so a slow one holds nothing else up; its snapshot is still taken on the connection's own loop, which is what keeps it in order with the events after it.

How each agent is driven:

- **Pi**: the bridge owns Pi sessions. It spawns `pi --mode rpc` per session, keeps a registry in `~/.agent-remote/sessions.json`, and resumes them with `--session <file>` after a restart.
- **DeepSeek Harness**: the bridge runs `dsh --profile shed` per session, a dsh profile it writes on each start. `bridge/src/dsh.rs` translates `Ask` commands into calls to the profile's one plugin (`bridge/dsh/shed.mjs`) and turns dsh's forwarded events into Pi's, so the rest of the bridge runs these sessions as it runs Pi's: same registry, same resumption. dsh runs without its permission prompts, as Pi and Prime do.
- **Prime Agent**: the bridge is a client of Prime's daemon, the same supervisor its TUI uses, and starts the daemon when none is running. Prime's RPC mode can't spawn subagents and ACP can't compact, report stats or steer, so the daemon is the only interface with everything. Sessions started in Prime's own TUI therefore show up in Shed too. The protocol is undocumented upstream; [prime-daemon-protocol.md](prime-daemon-protocol.md) records what the bridge relies on.

**Open Codex** (`bridge/src/opencodex.rs`) is where every agent's models come from. The bridge writes its catalog into Pi's and Prime's configuration whenever a client asks for an agent's models (at most once a minute), makes it dsh's one provider in the `shed` profile, and reads its request history for what each session has spent and how fast it is spending.

The bridge also stops runaway generations: a reply that streams thousands of blank characters, or the same few characters over and over, is aborted and the agent is told why (`bridge/src/runaway.rs`).

## Clients

`apps/` is a Swift package. `ShedKit` holds the wire types, the WebSocket client, `SessionStore` and the SwiftUI views; `ShedMac` is the macOS executable, bundled into `Shed.app` by `apps/scripts/bundle-mac.sh`; `apps/iOS` is the iPhone app and its Live Activity widget, generated from `project.yml` with XcodeGen.

A client can hold several **computers** at once, each a bridge URL and token. `SessionStore` keeps one connection per computer and tags every session id with its computer (`<computer>:<session>`), so the rest of the app works with one session tree and each operation is routed back to the right bridge.

## Features

| Feature | Pi | DeepSeek Harness | Prime |
|---|---|---|---|
| Send / steer | `prompt` when idle, `steer` while running; `follow_up` queues | plugin `prompt` (`followup` / `steer`) | `prompt` with `streamingBehavior:"steer"`, `queueIfBusy`; `follow_up` queues |
| Stop | `abort` | plugin `cancel` | `abort` (`abort_and_send_queued` for stopping a tool) |
| Reasoning, tool calls | RPC events, normalized | plugin events, normalized by `dsh.rs` | daemon `session_event`s (same shapes; no `contentIndex` on deltas) |
| Context window, cost | `get_session_stats` | `Feed` state from plugin events | roster usage + `get_session_stats` + `cost.rs` |
| Compaction | `compact`, `set_auto_compaction` | plugin `/compact` command (auto-compacts on its own) | a `/compact` prompt queued as a follow-up, since Prime's `compact` aborts the session first; `set_auto_compaction` |
| Model, effort | `set_model`, `get_available_thinking_levels`, `set_thinking_level` | plugin `select`, efforts from `describe` | same, levels from `thinkingLevelMap`; `set_thinking_level` also changes Prime's saved default |
| New session | `new_session` | started from the app instead | `new_session` (`activeSessionId` stays) |
| Questions | — | `dsh_question` + `answer_question` (2-minute timed mode) | — |
| Resume | `--session <file>` | plugin `open` with `resume: true` | sessions live in the daemon |

## Subagents

Every subagent is a session in the tree, with `kind:"subagent"`, a `parentId` and a `name`, and it can be opened like any other.

- **Prime** subagents are asynchronous agents in the daemon roster (`runtimeKind:"subagent"`). The parent keeps going, or ends its turn, while they work, and their reports arrive later as tagged notes (`[agent-message from child:NAME]`, `[child-exited: …]`, `[task from parent]`, `[bash-done …]`). An idle session isn't necessarily finished: any session can leave REPL shell jobs running that wake it later. The bridge counts them from the worker's process tree (`backgroundJobs`) and lists, tails and cancels them through the daemon, as Prime's TUI does (see [prime-daemon-protocol.md](prime-daemon-protocol.md)). Clients treat a session as *active* when it's running or has background jobs. That drives the "At work" list, the per-parent badge and the hourglass icon. Children accept messages directly.
- **DeepSeek Harness** subagents are dsh's own. The plugin forwards each child's transcript and state (`dsh_subagent`), and the bridge mirrors it as a read-only session.
- **Pi** subagents come from the `subagent` extension (vendored in `setup/pi`). They are synchronous: the parent's tool call waits for them. The bridge builds read-only child sessions from the tool's streamed `details.results[]`, so their transcripts show live.

## Background commands

Every agent can leave shell commands running after its turn ends. A `[bash-done]` notice wakes the agent when a command finishes. Prime does this natively (REPL `bash()`). Pi gets the same from the `background-jobs` extension in `setup/pi`, which also loads in Pi's own TUI (`/jobs`, "shells: N"). DeepSeek Harness reports its own through the plugin (`dsh_jobs`). The bridge's `list_jobs`, `job_output` and `kill_job` ops serve all three. The app shows a terminal button in the session header with the running count. It opens the list with live output and "Cancel command". A cancelled command exits `-15`, and the agent hears about it as it would from its own TUI.

## Sites

A session's web servers are found from the outside: the bridge reads the listening sockets of the processes in each session's tree (`lsof -nP -iTCP -sTCP:LISTEN`), so any server counts, whatever the agent started it with. Each site is a `Site` on its `SessionSummary` (`port`, `title`, `command`, `url`, `published`, `exposed`), published on its own `tailscale serve` HTTPS port unless `sites.publish` is false (a spare port from 8100 to 8199 when its own is taken on the tailnet; a route made by hand to the same server is used as it is), and taken down when its process ends. A site that isn't published carries a `reason`. A detached server (reparented to launchd) stays with the session it was first seen under, or goes to the session working in its folder. The bridge only removes routes it recorded in `sites.json`: the serve configuration is shared with whatever else the machine publishes.

## Where things are

The bridge, in `bridge/src`:

| File | What it holds |
|---|---|
| `main.rs` | Starts the bridge, and the `agent-remote web` command the agents call. |
| `protocol.rs` | The messages the apps and the bridge exchange. |
| `server.rs` | The WebSocket endpoint: one connection per app, and the sessions it is attached to. |
| `agent.rs` | What the bridge asks of an agent: the `Agent` trait (start a session, list models), the `Live` trait (a running session: send a command, close) and the list of agents the bridge has. The tests run the session code against a scripted agent that implements the same two traits. |
| `ask.rs` | Every question the bridge asks an agent, as one enum: its wire name and fields for each driver, and its time limit. |
| `rpc.rs`, `dsh.rs`, `prime.rs` | One driver per agent: a Pi process, a DeepSeek Harness process made to speak Pi's protocol, and the connection to Prime's daemon. |
| `requests.rs` | Matching an agent's answers to what it was asked, with a time limit on every request. The three drivers use it. |
| `agent_wire.rs` | Everything an agent tells the bridge about a session, read into the bridge's own types. |
| `transcript.rs` | Turns an agent's messages and streaming events into the flat list of transcript items. |
| `session.rs` | The sessions themselves: the list, starting and stopping, and what each agent event does to a session. |
| `session/commands.rs` | What an app can ask of a session: send, stop, compact, rename, and so on. |
| `session/context.rs` | Refreshing a session's state from its agent, and its context window. |
| `session/prime.rs` | Mirroring Prime's sessions from its daemon. |
| `session/subagents.rs` | Pi's and DeepSeek Harness's subagents, shown as read-only sessions. |
| `session/watchers.rs` | What the bridge checks on its own: spending, background jobs, stuck commands. |
| `opencodex.rs`, `web.rs` | Open Codex's catalog and history, and the web provider. Each reads the other side's JSON into types in its own file. |
| `jobs.rs`, `sites.rs`, `stall.rs`, `runaway.rs`, `cost.rs`, `history.rs` | One feature each: background commands, sites, stuck commands, runaway replies, a Prime session's real cost, a Prime session's history before its last compaction. |
| `guide.rs` | What each agent is told about Shed in its system prompt. |
| `files.rs`, `git.rs`, `github.rs`, `media.rs` | What the apps ask about the machine: folders to pick from, a folder's branch, the user's GitHub, and the files an agent shows. |
| `channel.rs` | `offer`: a send that may find nobody listening. |
| `host.rs` | The home folder and the clock, asked in one place. |
| `store.rs` | `config.json`, read into one typed `Config` for every reader, and most of the bridge's own files under `~/.agent-remote`: the sessions, the chosen context windows, the published sites, the Prime sessions it has listed. Some are still written elsewhere, among them the guide file Pi's subagents read (`agent.rs`, in Pi's `start`), the log of loops (`session.rs`), Open Codex's catalog for dsh (`opencodex.rs`), the marks on lost Pi jobs (`jobs.rs`), and the web log and the Python module (`web.rs`). |

The rules the bridge keeps to:

- **Data from outside is read once, where it arrives.** What an agent says about a session becomes a typed value in `agent_wire.rs`, by a `read` function written by hand, and the session code works with those types only. `opencodex.rs` and `web.rs` do the same for their two services. The readers are forgiving on purpose: a field that is missing or has the wrong type reads as absent, because the agents change between releases. `config.json` is the exception, read strictly in `store.rs`: a setting left out takes its default, but a setting of the wrong type, or a file that can't be read or isn't a JSON object, is a mistake and not an empty file: the bridge doesn't start on it and names the setting, and one that breaks while the bridge runs changes nothing until it is mended (the bridge keeps the settings it last read, and logs the failure once). Not everything follows the rule yet. The drivers (`dsh.rs`, `prime.rs`, `rpc.rs`), `transcript.rs`, `jobs.rs`, `github.rs`, `history.rs`, `cost.rs`, `store.rs`, `sites.rs` and `stall.rs` still pick fields out of JSON in their own code, and a question an agent asks is passed to the apps as it came.
- **Each kind of session keeps its own state.** `BackendState` has one case for a session the bridge starts (a Pi or DeepSeek Harness process), one for a Prime session and one for a subagent, and most code that does something different for each kind matches on all of them. What differs between agents is not decided there: it is asked of the agent (`Agent::verbs`, `jobs`, `sessions`). Some checks on the kind are still plain comparisons, and DeepSeek Harness, its subagents and Prime's subagents have no case of their own (a DeepSeek Harness session is a started one with a different `agent`).
- **An error is handled, logged, or dropped with a stated reason.** In the shipped code the linter rejects `let _ = …` and a bare `.ok();` on a result (test builds allow them, `main.rs`), and a result dropped on purpose carries an `#[expect]` with its reason. A send to a channel nobody listens to any more is written `offer` (`channel.rs`). The three drivers read their agent's lines through one function (`requests::next_message`) that logs a failed read and a line that is not JSON. The linter does not see every form: `.ok()` in the middle of a chain, `unwrap_or_default()` and `if let Ok` can still drop an error unlogged.
- **Behaviour is pinned.** `session/tests.rs` feeds each agent's events and malformed ones to the session code, with no agent running, and compares everything the apps would receive with the files in `session/pins/`. It covers what events do to a session and eight of the operations an app can ask for. Resuming and creating a session and sending a message have tests of their own against a scripted agent, and attaching, detaching, closing and deleting a session are driven through `server::serve` as an app drives them. A change that only moves code must leave those files as they are.

Known limits:

- **A transcript reloaded while its agent streams.** After a compaction, a new conversation or a resume, the bridge asks the agent for its whole list of messages and replaces the transcript with it. The agent's events keep arriving meanwhile, on another path, and the bridge cannot tell whether an event came before or after the answer was written. A reply or a tool call that ends after the reload comes out whole (`transcript.rs`, the `reload` tests). A complete message that lands in that moment can be missing, or shown twice, until the next reload. Closing it needs the position of the answer among the events from each of the three drivers.
- **The token.** The apps keep the bridge's token in their preferences, not in the keychain. They send it in a header; the bridge also takes it in the address (`?token=`), which apps built before that change still use.

The apps, in `apps/Sources/ShedKit`:

| File | What it holds |
|---|---|
| `Protocol.swift`, `ClientOp.swift` | The same messages as `protocol.rs`: what a bridge sends, and every operation the app can ask for, as one typed enum. |
| `BridgeClient.swift` | The WebSocket connection to one bridge: matching replies to requests, and reconnecting. |
| `SessionStore.swift` | The app's state: the computers, their sessions, the open session's transcript. |
| `SessionStore+….swift` | What changes that state, by job: the computers and their connections, messages coming in, requests going out, the session tree. |
| `Views/` | The SwiftUI views. `SessionView.swift` is the session screen; its header, composer, model picker and cards are each in their own file. |

Both sides' tests read the example messages in `protocol/`, so the Rust and Swift types for messages and operations can't drift apart without a test failing (`pi_job.json` and `pi_subagents.json` do the same between Pi's TypeScript extensions and the bridge). Of a reply, the envelope and its error codes are covered; what each operation answers with in `data` is not.

## Adding an agent

An agent is one implementation of `Agent` (`bridge/src/agent.rs`), plus a `Live` driver if it speaks its own protocol. Every session command, time limit (`Ask::limit`) and client capability (`SessionSummary.capabilities`) flows from `Agent` and `Verbs`, so neither `server.rs` nor the apps' views branch on agent names for features.

**What the compiler asks for.** Add a case to `AgentKind` in `bridge/src/rpc.rs` and to `AgentKind` in `apps/Sources/ShedKit/Protocol.swift`. Neither side builds until the new agent has:

- its guide text in `bridge/src/guide.rs`;
- its place in `Agents` in `agent.rs` (a field, and its line in `installed`, `of` and `get`), which needs an implementation of `Agent`;
- in that implementation, the eight answers, none with a default: `sessions` (`Started`, the bridge runs a process per session, or `Kept`, the agent keeps them itself), `models`, `jobs` (`JobsFrom`), `subagents` (`SubagentsFrom`), `gateway_session`, `cost`, `spend_includes_subagents`, and `verbs`;
- `verbs` (`Verbs`), with no defaults: `message`, `follow_up`, `abort`, `compact`, `auto_compaction`, `new_session`, `clear_goal`, `stop_tool`, `interrupt`, `restart_kernel`, `answer` and `thinking_levels` (`None` where the agent lacks a command). An agent that speaks Pi's RPC can reuse `PiRpc`; DeepSeek Harness uses `DshVerbs` and Prime uses `PrimeVerbs`. If the agent speaks its own protocol, its `Live::send(Ask)` matches on `Ask` directly (as `Dsh::send` does) and passes `ask.limit()` to its request matcher;
- `Starts::start` for a started agent, or `Keeps` (`session`, `stop`, `create`) for a kept one;
- in the apps, its name (`Protocol.swift`), its legacy fallback line in `SessionCapabilities.legacy` (`Protocol.swift`, used only when talking to a bridge older than `capabilities`), its colour (`Views/Theme.swift`), its glyph (`Views/Atmosphere.swift`) and its card title and description (`Views/NewSessionSheet.swift`).

The `agent-remote guide <agent>` command, the cards in the new-session sheet, and every session action in the apps (kernel restart, goals, new session, auto-compaction switch, follow-up queue, questions, background commands, subagent spend) follow automatically from `Agent`, `Verbs` and `SessionSummary.capabilities`.

**What the compiler does not ask for.**

- *Following a roster.* An agent that keeps its sessions in its own daemon (`Keeps`) needs roster-following code alongside `session/prime.rs` (`Keeps::create` currently returns `PrimeRow`, and `Backend::Prime` holds `PrimeState`).
- *The kind of session.* The session code matches on `Backend` (`Started`, `Prime`, `Subagent`) for what follows from how a session lives: starting, resuming and closing it, saving it, whether it can be refreshed. That is by design: those are the three ways a session can exist, not three agents.
- *Events.* `agent_wire.rs` reads Pi's event vocabulary plus `dsh_jobs`, `dsh_question` and `dsh_subagent`. A driver for a new protocol either normalizes its stream into those events (as `dsh.rs` does) or extends `agent_wire.rs`.
- *Background commands.* `JobsFrom::Agent` asks the driver with `Ask::Jobs`, `Ask::JobOutput` and `Ask::KillJob`, which fits any driver that lists its own jobs; `Files` and `Kernel` are Pi's job folder and Prime's REPL kernel tree (`jobs.rs`).
- *Open Codex catalog sync.* If Open Codex should write its model catalog into a configuration file the new agent reads, add that path in `opencodex.rs`.
- *Fixtures and setup.* Run `UPDATE_FIXTURES=1 cargo test` so `protocol/server_messages.json` and `bridge/src/session/pins/commands.json` include the new `AgentKind`, and add its install step in `setup/`.

**Order of release.** Either side can ship first without losing data: an older app skips sessions whose `agent` it does not recognize (`Readable` in `Protocol.swift`), and an older bridge keeps unknown-agent entries in `sessions.json` as raw JSON and writes them back on save (`store.rs`). Ship the apps before creating sessions of the new agent if those sessions should be visible on every device right away.

## Setup

`setup/install.sh` provisions a Mac and can be run again at any time: Open Codex with your API keys and subscriptions, and Shed's fixes it hasn't released yet (`setup/opencodex`); Pi, Prime Agent and DeepSeek Harness at their latest versions; Pi's subagent and background-jobs extensions (`setup/pi`); the bridge as a launchd service; the Mac app; and the `tailscale serve` publication. With `--no-opencodex`, Pi and Prime get the keys directly, and the model definitions their catalogs lack come from `setup/pi/models.json` and `setup/prime/models.json`. `setup/sync-remote.sh` keeps the bridge on another Mac in step with a checkout, and `setup/uninstall.sh` removes the service, the publication, the routes of published sites, the sync agents and the app, and nothing of the agents or Open Codex.
