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
- request/reply operations (`send`, `abort`, `compact`, `set_model`, `list_dir`, `list_jobs`, …), each answered by a `reply` with the request's `id`. A failed one carries the sentence to show (`error`) and, for the failures an app does something about, a `code` (`session_ended`, `no_such_directory`). Apps from before the codes compare the sentence, so those sentences are fixed (`bridge/src/protocol.rs`). An `attach` waits on the agent apart from the connection, so a slow one holds nothing else up; its snapshot is still taken on the connection's own loop, which is what keeps it in order with the events after it.

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
| Compaction | `compact`, `set_auto_compaction` | a `/compact` prompt queued as a follow-up, since Prime's `compact` aborts the session first; `set_auto_compaction` |
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

Both sides' tests read the example messages in `protocol/`, so the Rust and Swift types for messages and operations can't drift apart without a test failing. Of a reply, the envelope and its error codes are covered; what each operation answers with in `data` is not.

## Adding an agent

An agent is one implementation of the `Agent` trait in `bridge/src/agent.rs`. The compiler asks for part of what a new agent needs and the rest is by hand; the two lists below say which is which. As the code stands, a new agent that speaks Pi's protocol is a day's work, and one that speaks its own is a new driver and an implementation of `Verbs`.

**What the compiler asks for.** Add a case to `AgentKind` in `bridge/src/rpc.rs` and to `AgentKind` in `apps/Sources/ShedKit/Protocol.swift`. Neither side builds until the new agent has:

- its guide text in `bridge/src/guide.rs`;
- its place in `Agents` in `agent.rs` (a field, and its line in `installed`, `of` and `get`), which needs an implementation of `Agent`;
- in that implementation, the six answers, none with a default: `sessions` (how its sessions come about: `Started`, the bridge runs a process for each, or `Kept`, the agent keeps them itself), `models` (what a session can start on), `jobs` (where background commands are found), `gateway_session`, `spend_includes_subagents`, and `verbs`;
- `verbs` is what a session's commands become in the agent's words: a message (prompt or steer), compacting, clearing a goal, stopping a tool call, stopping a looping reply, restarting a kernel, and asking for thinking levels. Each is answered, none has a default. An agent that speaks Pi's RPC returns `PiRpc`, as Pi and DeepSeek Harness do; Prime has `PrimeVerbs`. The tests' scripted agent hands back the real agent's verbs, so the pins check what each agent's commands really become;
- `Starts::start` builds what the session runs, its arguments and environment with it (Pi's guide file and jobs folder are set there), and `Keeps` has `stop` beside `session` and `create`;
- in the apps, its name (`Protocol.swift`), its colour (`Views/Theme.swift`), its glyph (`Views/Atmosphere.swift`) and the line on its card in the new-session sheet (`Views/NewSessionSheet.swift`).

The `agent-remote guide <agent>` command and the cards in the new-session sheet follow the list of agents, so they need nothing.

**What the compiler does not ask for.** Each of these is silent: leave it out and the new agent gets another agent's behaviour, or none.

- *Following a roster.* One that keeps its sessions in its own daemon, as Prime does, implements `Keeps`, and needs code that follows its roster, which is written for Prime only (`session/prime.rs`, and `create` returns Prime's roster row). A Prime session's cost also reads Prime's own record of what its subagents spent (`context.rs`).
- *The kind of session.* The session code still matches on `Backend` (a process the bridge runs, a session an agent keeps, a read-only subagent) for what follows from how a session lives: starting, resuming and closing it, saving it, whether it can be refreshed. That is by design: those are the three ways a session can exist, not three agents.
- *Background commands.* `jobs` picks one of three: the folder Pi's background-jobs extension writes (`Files`), the processes under Prime's kernel (`Kernel`), or asking the agent with the DeepSeek plugin's commands `dsh_jobs`, `dsh_job_output`, `dsh_kill_job` (`Agent`). The first two are still tied to Pi and Prime in `jobs.rs`; a new agent fits `Agent` or needs a new way there.
- *Events and wire names.* `agent_wire.rs` reads Pi's vocabulary, and jobs, questions and subagents from events named `dsh_…`. `Ask::wire` gives each question one name: Pi's, the DeepSeek plugin's or Prime's (`ask.rs`). An agent with a third vocabulary for the same question needs `wire` to take the driver. Answering a question sends `dsh_answer` whatever the agent.
- *Subagents.* `session/subagents.rs` labels the child sessions it makes as Pi's or DeepSeek's.
- *Models.* `rpc::listed_models` parses the table Pi and Prime print. With Open Codex, the catalogue is written to a hand-kept list of folders in `opencodex.rs`.
- *Time limits.* Each driver decides its own. Pi's honours `Ask::limit` (`ask.rs`), where only `compact` gets the long limit. DeepSeek's gives the long one to its slash commands by method name (`dsh.rs`). Prime's daemon gives every command the short one, 2 minutes (`prime.rs`).
- *Tests.* The scripted agent stands in for every kind, but `protocol/server_messages.json` lists the agents and fails both sides' tests until it is written again with `UPDATE_FIXTURES=1`. The commands pin runs every command against every agent there is (`session/tests.rs`), so a new agent fails it until the pin is written again with it.
- *The apps' features.* These compare with one agent and need a look each: `hasBackgroundCommands` and `controlsAutoCompaction` in `Protocol.swift`; the default models and the split of models by name in `Views/NewSessionSheet.swift`; goals and the kernel restart in `Views/SessionHeader.swift`, `Views/PhoneSessionToolbar.swift` and `Views/SessionView.swift`; the empty list in `Views/BackgroundCommands.swift`. (The cost on the lock screen goes through `spendIncludesSubagents`, which the compiler asks for.)
- *Setup.* Its install step in `setup/`.

**Order of release.** The apps go first. An app from before the new agent leaves its sessions out of the list, and a bridge from before it cannot read a `sessions.json` that holds one of its sessions and sets the whole file aside. So: ship the apps, then the bridge, and do not go back to an older bridge once a session of the new agent is saved.

## Setup

`setup/install.sh` provisions a Mac and can be run again at any time: Open Codex with your API keys and subscriptions, and Shed's fixes it hasn't released yet (`setup/opencodex`); Pi, Prime Agent and DeepSeek Harness at their latest versions; Pi's subagent and background-jobs extensions (`setup/pi`); the bridge as a launchd service; the Mac app; and the `tailscale serve` publication. With `--no-opencodex`, Pi and Prime get the keys directly, and the model definitions their catalogs lack come from `setup/pi/models.json` and `setup/prime/models.json`. `setup/sync-remote.sh` keeps the bridge on another Mac in step with a checkout, and `setup/uninstall.sh` removes the service, the publication, the routes of published sites, the sync agents and the app, and nothing of the agents or Open Codex.
