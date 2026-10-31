# Prime Agent daemon protocol (as observed)

Prime Agent 0.10.2 (Rust build) only supports subagents (`rlm.spawn`) in **daemon-backed** sessions. `prime-agent --mode rpc` runs in-process and fails with `rlm.spawn requires a daemon-backed session`. So the bridge talks to Prime's supervisor socket, the same way Prime's own TUI does.

None of this is documented by Prime Intellect. It was captured on 2026-10-30 by proxying the socket while the TUI ran. **Re-verify on every Prime release.** The bridge refuses to talk to a daemon whose `protocol.version` is not 7.

## Socket

- Path: `$(getconf DARWIN_USER_TEMP_DIR)prime-agent-rust-<uid>/daemon.sock` (`prime-agent-<uid>` on older builds), or `$PRIME_AGENT_DAEMON_SOCKET`.
- Start the daemon with `prime-agent --mode daemon`. If one is already running, it exits with `Daemon socket already in use`. Once started it detaches into its own process group, so it outlives whatever started it.
- Framing: JSON, one object per line (LF).

## Handshake

The server speaks first:

```json
{"type":"daemon_hello","protocol":{"name":"prime-agent.daemon","version":7},"schemaRevision":30,"appVersion":"0.10.2","clientId":"…","serverCapabilities":["attach_snapshot","event_sequence","authoritative_child_roster","agent_roster", "…"]}
```

## Commands

```json
{"type":"command","id":"<id>","protocol":{"name":"prime-agent.daemon","version":7},"clientId":"<stable client id>","command":{"type":"<rpc command>","id":"<id>","activeSessionId":"<session>", "…rpc fields"}}
```

Responses: `{"id":"<id>","type":"response","command":"<type>","success":true,"data":…}` or `success:false, error`.

Session commands are Prime's RPC commands with an `activeSessionId` added. Verified: `get_state`, `get_session_stats`, `get_messages`, `get_available_models`, `set_thinking_level`, `prompt`, `steer`, `clear_queue`, `compact`, `new_session`, `attach`, `detach`. `get_available_thinking_levels` is unknown, so use `thinkingLevelMap` from `get_available_models`. Stats, state and prompt work without attaching.

Supervisor commands:

| Command | Fields | Notes |
|---|---|---|
| `list` | `all` (bool) | Session summaries |
| `roster_subscribe` | — | Returns `{roster:[{agentId, summary}]}` and then pushes `roster_update` |
| `create` | `config:{cwd, executionMode:"interactive", sessionDir, model:"provider/id", thinking}`, `launchEnv:{…}` | Returns a summary with `activeSessionId`. `thinking` here doesn't change the saved default. The TUI sends its whole environment as `launchEnv`; the bridge sends a curated one. |
| `attach` | `activeSessionId`, `capabilities:["attach_snapshot","event_sequence"]` | `data.snapshot = {summary, state, messages, lastEventSequence, lastEventCursor, children}` |
| `get_direct_worker_transport` | `activeSessionId` | Optional fast path straight to the worker socket. The bridge doesn't use it; everything also routes through the supervisor. |

The TUI's `prompt` is `{"type":"prompt","message":…,"streamingBehavior":"steer","queueIfBusy":true}`, which steers when the agent is busy.

`set_thinking_level` changes Prime's saved `defaultThinkingLevel` (the TUI does the same).

## Pushed messages

- `session_event`: `{activeSessionId, event:<RPC event>, meta:{sequence, cursor:{generation, sequence}}}`. The events are the same shapes as RPC mode. Only sent for attached sessions.
- `roster_update`: `{changed:[{agentId, summary, status, workerId}]}`. Sent for every session, subagents included. When a session stops, its last row has `status:"inactive"` and a summary **without** `activeSessionId` (`id` is the `sessionId`); match it by `sessionFile`.
- `session_closed`, `heartbeats_changed`.

## Session summary fields used by the bridge

`activeSessionId` (stable across `new_session`), `sessionId` (changes on `new_session`), `sessionFile`, `sessionName`, `cwd`, `runtimeKind` (`top-level` | `subagent`), `rlmDepth`, `parentActiveSessionId`, `rlmChildId`, `activity` (`idle`/`working`/…), `isStreaming`, `isCompacting`, `hasRunningSubagents`, `thinkingLevel`, `model {provider,id,name,reasoning}`, `usage {inputTokens,outputTokens,cost}`, `firstMessage`, `lifecycle` (`draft`/`live`), `created`, `modified`.

## Asynchronous subagents and background jobs

Prime subagents are asynchronous. `rlm.spawn(...)` returns right away, the parent can end its turn (`activity:"idle"`), and each child's report arrives later as a steer that wakes the parent. In the parent transcript these arrive as tagged custom messages, which the bridge turns into notes:

- `[task from parent] …` is the first message in a child.
- `[agent-message from child:NAME] …` is a child's report.
- `[child-exited: no-reply child:NAME] …` means the child ended a turn without reporting. It is **not** finished: it can wake up again.
- `[bash-done pid:N exit:N] …` means a background job finished, and it wakes the session that started it.

Any session can also start a shell job from its REPL (`h = bash("…")` returns a handle) and end its turn. The session state doesn't show these jobs: `isBashRunning`, `isRunningTools` and `unfinishedActionCount` all stay false, and `hasRunningSubagents` turns false as soon as the children go idle. Neither the attach snapshot's `state` nor the roster carries job bookkeeping.

The daemon lists them on request, with the `kernel_bash_activity` capability. Prime's TUI uses these commands for its "shells: N" footer and background commands view:

| Command | Fields | Data |
|---|---|---|
| `list_kernel_bash` | | `{activities:[{id, command, pid, startedAt (ISO), durationMs, status: running\|finished, exitCode, persistent}]}`, the latest 64 finished ones included. Ids don't survive a kernel restart. |
| `tail_kernel_bash` | `activityId`, `lines` (1–200) | `{id, tail}`, at most 16 KiB |
| `kill_kernel_bash` | `activityId` | `{id, killed}`. The job exits `-15` and its `[bash-done pid:N exit:-15]` notice still wakes the agent. |
| `list_persistent_shells`, `tail_persistent_shell`, `kill_persistent_shell` | `shellId` | the same for persistent shells |

The notice is `[bash-done pid:N exit:N]\n\nCommand: "…"`, and the TUI labels it "Background command finished".

The bridge proxies these as `list_jobs`, `job_output` and `kill_job`. Persistent shells get ids prefixed `shell:`. Polling `list_kernel_bash` could wake a passivated worker, so the running count published as `backgroundJobs` comes from a heuristic instead. Every 2 seconds the bridge runs `ps` and, for each Prime session's `workerPid` (from the roster row), counts the processes directly under the worker's REPL kernel (`python -m rlm.repl`). An idle worker shows only the kernel, with nothing under it. Each REPL job adds a `/bin/bash -c …` process under the kernel. Clients treat a session as active when it is running **or** has background jobs.

Pi has no background commands of its own. The `background-jobs` extension (`setup/pi/extensions`) adds them on the same model: `bash_background`, `job_output`, `job_kill` and `jobs` tools, a `[bash-done id:… pid:N exit:N]` notice that wakes the agent, "shells: N" in Pi's footer, and `/jobs` in Pi's TUI. It keeps a JSON record and a log per job in `$AGENT_REMOTE_JOBS_DIR`. The bridge sets that to `~/.agent-remote/jobs/<session>` for each Pi session it starts, and reads it to serve the same three ops.
