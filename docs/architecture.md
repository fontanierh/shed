# Architecture

Shed has two halves: a **bridge** that runs next to the agents on each computer, and **clients** (the Mac and iPhone apps) that connect to one or more bridges.

```
 iPhone app ─┐                                        ┌─ pi --mode rpc            one child process per Pi session
             ├─ WebSocket ──► bridge (Rust, :7878) ───┤
 Mac app ────┘   Tailscale (HTTPS)                    └─ Prime daemon socket ──► every Prime session, subagents included
```

## Bridge

`bridge/` is a Rust service (tokio, axum) that `setup/install.sh` registers with launchd. It binds to `127.0.0.1` only; `tailscale serve` publishes it on the tailnet over HTTPS, which iOS requires. A bearer token from `~/.agent-remote/config.json` guards every connection, since the agents can run arbitrary code.

It turns both agents into one client protocol (`bridge/src/protocol.rs`, mirrored in `apps/Sources/ShedKit/Protocol.swift`):

- one `SessionSummary` per session: status, model, effort, context usage, cost, queue, goal, background jobs, parent and children;
- a normalized transcript of `user`, `text`, `thinking`, `tool`, `compaction`, `error` and `note` items, streamed as `snapshot`, `item_add` and `item_patch` messages to the clients attached to that session;
- request/reply operations (`send`, `abort`, `compact`, `set_model`, `list_dir`, `list_jobs`, …), each answered by a `reply` with the request's `id`.

How each agent is driven:

- **Pi**: the bridge owns Pi sessions. It spawns `pi --mode rpc` per session, keeps a registry in `~/.agent-remote/sessions.json`, and resumes them with `--session <file>` after a restart.
- **Prime Agent**: the bridge is a client of Prime's daemon, the same supervisor its TUI uses, and starts the daemon when none is running. Prime's RPC mode can't spawn subagents and ACP can't compact, report stats or steer, so the daemon is the only interface with everything. Sessions started in Prime's own TUI therefore show up in Shed too. The protocol is undocumented upstream; [prime-daemon-protocol.md](prime-daemon-protocol.md) records what the bridge relies on.

The bridge also stops runaway generations: a reply that streams thousands of blank characters, or the same few characters over and over, is aborted and the agent is told why (`bridge/src/runaway.rs`).

## Clients

`apps/` is a Swift package. `ShedKit` holds the wire types, the WebSocket client, `SessionStore` and the SwiftUI views; `ShedMac` is the macOS executable, bundled into `Shed.app` by `apps/scripts/bundle-mac.sh`; `apps/iOS` is the iPhone app and its Live Activity widget, generated from `project.yml` with XcodeGen.

A client can hold several **computers** at once, each a bridge URL and token. `SessionStore` keeps one connection per computer and tags every session id with its computer (`<computer>:<session>`), so the rest of the app works with one session tree and each operation is routed back to the right bridge.

## Features

| Feature | Pi | Prime |
|---|---|---|
| Send / steer | `prompt` when idle, `steer` while running; `follow_up` queues | `prompt` with `streamingBehavior:"steer"`, `queueIfBusy` |
| Stop | `abort` | `abort` |
| Reasoning, tool calls | RPC events, normalized | daemon `session_event`s (same shapes; no `contentIndex` on deltas) |
| Context window, cost | `get_session_stats` | roster usage + `get_session_stats` |
| Compaction | `compact`, `set_auto_compaction` | same |
| Model, effort | `set_model`, `get_available_thinking_levels`, `set_thinking_level` | same, levels from `thinkingLevelMap`; `set_thinking_level` also changes Prime's saved default |
| New session | `new_session` | same (`activeSessionId` stays) |
| Resume | `--session <file>` | sessions live in the daemon |

## Subagents

Every subagent is a session in the tree, with `kind:"subagent"`, a `parentId` and a `name`, and it can be opened like any other.

- **Prime** subagents are asynchronous agents in the daemon roster (`runtimeKind:"subagent"`). The parent keeps going, or ends its turn, while they work, and their reports arrive later as tagged notes (`[agent-message from child:NAME]`, `[child-exited: …]`, `[task from parent]`, `[bash-done …]`). An idle session isn't necessarily finished: any session can leave REPL shell jobs running that wake it later. The bridge counts them from the worker's process tree (`backgroundJobs`) and lists, tails and cancels them through the daemon, as Prime's TUI does (see [prime-daemon-protocol.md](prime-daemon-protocol.md)). Clients treat a session as *active* when it's running or has background jobs. That drives the "At work" list, the per-parent badge and the hourglass icon. Children accept messages directly.
- **Pi** subagents come from the `subagent` extension (vendored in `setup/pi`). They are synchronous: the parent's tool call waits for them. The bridge builds read-only child sessions from the tool's streamed `details.results[]`, so their transcripts show live.

## Background commands

Both agents can leave shell commands running after their turn ends. A `[bash-done]` notice wakes the agent when a command finishes. Prime does this natively (REPL `bash()`). Pi gets the same from the `background-jobs` extension in `setup/pi`, which also loads in Pi's own TUI (`/jobs`, "shells: N"). The bridge's `list_jobs`, `job_output` and `kill_job` ops serve both. The app shows a terminal button in the session header with the running count. It opens the list with live output and "Cancel command". A cancelled command exits `-15`, and the agent hears about it as it would from its own TUI.

## Setup

`setup/install.sh` provisions a Mac and can be run again at any time: Pi and Prime Agent at their latest versions, API keys from the environment, model definitions Prime's catalog lacks (`setup/prime/models.json`), Pi's subagent and background-jobs extensions (`setup/pi`), the bridge as a launchd service, the Mac app, and the `tailscale serve` publication. `setup/sync-remote.sh` keeps the bridge on another Mac in step with a checkout, and `setup/uninstall.sh` removes the service, the publication and the app.
