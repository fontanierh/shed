# Shed — design

Remote control for **Pi** (1.4.0) and **Prime Agent** (0.10.2) sessions on a Mac, from a macOS app and (later) an iOS app, over Tailscale.

## Architecture

```
 iPhone app ─┐                                     ┌─ pi --mode rpc               (one child per Pi session)
             ├─ WebSocket ─► bridge (Rust, :7878) ─┤
 Mac app ────┘   tailscale serve (HTTPS)           └─ Prime daemon socket ─► every Prime session, incl. subagents
```

- **Bridge** (`bridge/`, Rust: tokio + axum): a launchd login service bound to 127.0.0.1. `tailscale serve` publishes it on the tailnet with HTTPS (iOS needs TLS), and a bearer token (`~/.agent-remote/config.json`) guards it, because the agents can run arbitrary code. It turns both agents into one client protocol: a normalized transcript (`user`, `text`, `thinking`, `tool`, `compaction`, `error`, `note` items, sent as add/patch messages) and one `SessionSummary` per session.
- **Pi**: the bridge owns Pi sessions. It spawns `pi --mode rpc` per session, keeps a registry (`~/.agent-remote/sessions.json`), and resumes them with `--session <file>` after a restart.
- **Prime**: the bridge is a client of Prime's daemon (supervisor protocol v7, documented in `bridge/PRIME-DAEMON.md`) and starts it if needed. Prime's RPC mode can't spawn subagents, and ACP can't compact, report stats or steer, so the daemon is the only way to get everything. It also means sessions started in Prime's TUI show up in the apps.
- **Clients** (`apps/`, SwiftPM): `AgentRemoteKit` (wire types, WebSocket client, `SessionStore`, SwiftUI views) and the `AgentRemoteMac` executable, bundled as `Agent Remote.app`. The iOS app will reuse the kit.

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

- **Prime** subagents are asynchronous agents in the daemon roster (`runtimeKind:"subagent"`). The parent keeps going, or ends its turn, while they work, and their reports arrive later as tagged notes (`[agent-message from child:NAME]`, `[child-exited: …]`, `[task from parent]`, `[bash-done …]`). An idle session isn't necessarily finished: any session can leave REPL shell jobs running that wake it later. The bridge counts them from the worker's process tree (`backgroundJobs`) and lists, tails and cancels them through the daemon, as Prime's TUI does (see `bridge/PRIME-DAEMON.md`). Clients treat a session as *active* when it's running or has background jobs. That drives the "Active subagents" list, the per-parent badge, "Waiting on 2 subagents", and the hourglass icon. Children accept messages directly.
- **Pi** subagents come from the `subagent` extension (vendored in `setup/pi`). They are synchronous: the parent's tool call waits for them. The bridge builds read-only child sessions from the tool's streamed `details.results[]`, so their transcripts show live.

## Background commands

Both agents can leave shell commands running after their turn ends. A `[bash-done]` notice wakes the agent when a command finishes. Prime does this natively (REPL `bash()`). Pi gets the same from the `background-jobs` extension in `setup/pi`, which also loads in Pi's own TUI (`/jobs`, "shells: N"). The bridge's `list_jobs`, `job_output` and `kill_job` ops serve both. The app shows a terminal button in the session header with the running count. It opens the list with live output and "Cancel command". A cancelled command exits `-15`, and the agent hears about it as it would from its own TUI.

## Setup

`setup/install.sh` provisions a Mac from scratch and can be run again: the agents (latest), the OpenAI key from `OPENAI_API_KEY`, the GPT-6.1 Terra model definition for Prime, Pi's subagent and background-jobs extensions, the bridge as a launchd service, the Mac app, and `tailscale serve`. `setup/uninstall.sh` removes the service, the tailnet publication and the app.
