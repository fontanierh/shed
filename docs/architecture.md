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

- one `SessionSummary` per session: status, model, effort, context usage, cost, queue, goal, background jobs, sites, a question waiting for an answer, parent and children;
- a normalized transcript of `user`, `text`, `thinking`, `tool`, `compaction`, `error` and `note` items, streamed as `snapshot`, `item_add` and `item_patch` messages to the clients attached to that session;
- request/reply operations (`send`, `abort`, `compact`, `set_model`, `list_dir`, `list_jobs`, …), each answered by a `reply` with the request's `id`.

How each agent is driven:

- **Pi**: the bridge owns Pi sessions. It spawns `pi --mode rpc` per session, keeps a registry in `~/.agent-remote/sessions.json`, and resumes them with `--session <file>` after a restart.
- **DeepSeek Harness**: the bridge runs `dsh --profile shed` per session, a dsh profile it writes on each start. The profile's one plugin (`bridge/dsh/shed.mjs`) answers the Pi commands the bridge sends and forwards dsh's events, which `bridge/src/dsh.rs` turns into Pi's, so the rest of the bridge runs these sessions as it runs Pi's: same registry, same resumption. dsh runs without its permission prompts, as Pi and Prime do.
- **Prime Agent**: the bridge is a client of Prime's daemon, the same supervisor its TUI uses, and starts the daemon when none is running. Prime's RPC mode can't spawn subagents and ACP can't compact, report stats or steer, so the daemon is the only interface with everything. Sessions started in Prime's own TUI therefore show up in Shed too. The protocol is undocumented upstream; [prime-daemon-protocol.md](prime-daemon-protocol.md) records what the bridge relies on.

**Open Codex** (`bridge/src/opencodex.rs`) is where every agent's models come from. The bridge writes its catalog into Pi's and Prime's configuration whenever a client asks for an agent's models (at most once a minute), makes it dsh's one provider in the `shed` profile, and reads its request history for what each session has spent and how fast it is spending.

The bridge also stops runaway generations: a reply that streams thousands of blank characters, or the same few characters over and over, is aborted and the agent is told why (`bridge/src/runaway.rs`).

## Clients

`apps/` is a Swift package. `ShedKit` holds the wire types, the WebSocket client, `SessionStore` and the SwiftUI views; `ShedMac` is the macOS executable, bundled into `Shed.app` by `apps/scripts/bundle-mac.sh`; `apps/iOS` is the iPhone app and its Live Activity widget, generated from `project.yml` with XcodeGen.

A client can hold several **computers** at once, each a bridge URL and token. `SessionStore` keeps one connection per computer and tags every session id with its computer (`<computer>:<session>`), so the rest of the app works with one session tree and each operation is routed back to the right bridge.

## Features

| Feature | Pi and DeepSeek Harness | Prime |
|---|---|---|
| Send / steer | `prompt` when idle, `steer` while running; `follow_up` queues | `prompt` with `streamingBehavior:"steer"`, `queueIfBusy` |
| Stop | `abort` | `abort` |
| Reasoning, tool calls | RPC events, normalized | daemon `session_event`s (same shapes; no `contentIndex` on deltas) |
| Context window, cost | `get_session_stats` | roster usage + `get_session_stats` |
| Compaction | `compact`, `set_auto_compaction` | same |
| Model, effort | `set_model`, `get_available_thinking_levels`, `set_thinking_level` | same, levels from `thinkingLevelMap`; `set_thinking_level` also changes Prime's saved default |
| New session | `new_session` | same (`activeSessionId` stays) |
| Resume | `--session <file>` | sessions live in the daemon |

DeepSeek Harness shares Pi's column because its plugin answers the same commands. A question the agent asks through `ask_user_question` shows in the apps and is answered with `answer_question`; unanswered for two minutes, the agent carries on.

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
| `rpc.rs`, `dsh.rs`, `prime.rs` | One driver per agent: a Pi process, a DeepSeek Harness process made to speak Pi's protocol, and the connection to Prime's daemon. |
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
| `store.rs` | `config.json`, read into one typed `Config` for every reader, and most of the bridge's own files under `~/.agent-remote`: the sessions, the chosen context windows, the published sites, the Prime sessions it has listed. A few are still written elsewhere: the agents' guide (`session.rs`), Open Codex's catalog for dsh (`opencodex.rs`), the marks on lost Pi jobs (`jobs.rs`) and the web log (`web.rs`). |

The rules the bridge keeps to:

- **Data from outside is read once, where it arrives.** What an agent says about a session becomes a typed value in `agent_wire.rs`, by a `read` function written by hand, and the session code works with those types only. `opencodex.rs` and `web.rs` do the same for their two services. The readers are forgiving on purpose: a field that is missing or has the wrong type reads as absent, because the agents change between releases. `config.json` is read the same way, field by field, in `store.rs`; but a file that can't be read at all, or isn't a JSON object, is not an empty one: the bridge doesn't start on it, and one that breaks while the bridge runs changes nothing until it is mended (the bridge keeps the settings it last read, and logs the failure once). Not everything follows the rule yet. The drivers (`dsh.rs`, `prime.rs`, `rpc.rs`), `transcript.rs`, `jobs.rs`, `github.rs`, `history.rs`, `cost.rs`, `store.rs`, `sites.rs` and `stall.rs` still pick fields out of JSON in their own code, and a question an agent asks is passed to the apps as it came.
- **Each kind of session keeps its own state.** `BackendState` has one case for a Pi or DeepSeek Harness process, one for a Prime session and one for a Pi subagent, and most code that does something different for each kind matches on all of them. It is not complete: about thirty yes-or-no checks are plain comparisons, and DeepSeek Harness, its subagents and Prime's subagents have no case of their own (a DeepSeek Harness session is a Pi one with a different `agent`).
- **An error is handled, logged, or dropped with a stated reason.** The linter rejects `let _ = …` and a bare `.ok();` on a result, and a result dropped on purpose carries an `#[expect]` with its reason. A send to a channel nobody listens to any more is written `offer` (`channel.rs`). The linter does not see every form: `.ok()` in the middle of a chain, `unwrap_or_default()` and `if let Ok` can still drop an error unlogged.
- **Behaviour is pinned.** `session/tests.rs` feeds each agent's events and malformed ones to the session code, with no agent running, and compares everything the apps would receive with the files in `session/pins/`. It covers what events do to a session and eight of the operations an app can ask for. Starting, stopping and attaching a session, and `server.rs`, have no test. A change that only moves code must leave those files as they are.

The apps, in `apps/Sources/ShedKit`:

| File | What it holds |
|---|---|
| `Protocol.swift`, `ClientOp.swift` | The same messages as `protocol.rs`: what a bridge sends, and every operation the app can ask for, as one typed enum. |
| `BridgeClient.swift` | The WebSocket connection to one bridge: matching replies to requests, and reconnecting. |
| `SessionStore.swift` | The app's state: the computers, their sessions, the open session's transcript. |
| `SessionStore+….swift` | What changes that state, by job: the computers and their connections, messages coming in, requests going out, the session tree. |
| `Views/` | The SwiftUI views. `SessionView.swift` is the session screen; its header, composer, model picker and cards are each in their own file. |

Both sides' tests read the example messages in `protocol/`, so the Rust and Swift types for messages and operations can't drift apart without a test failing. Replies to operations are not covered.

## Setup

`setup/install.sh` provisions a Mac and can be run again at any time: Open Codex with your API keys and subscriptions, and Shed's fixes it hasn't released yet (`setup/opencodex`); Pi, Prime Agent and DeepSeek Harness at their latest versions; Pi's subagent and background-jobs extensions (`setup/pi`); the bridge as a launchd service; the Mac app; and the `tailscale serve` publication. With `--no-opencodex`, Pi and Prime get the keys directly, and the model definitions their catalogs lack come from `setup/pi/models.json` and `setup/prime/models.json`. `setup/sync-remote.sh` keeps the bridge on another Mac in step with a checkout, and `setup/uninstall.sh` removes the service, the publication, the routes of published sites, the sync agents and the app, and nothing of the agents or Open Codex.
