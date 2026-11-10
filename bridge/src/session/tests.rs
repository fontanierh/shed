//! What the session code does with each agent's events, pinned. Each test feeds events through the entry points the
//! bridge itself uses, then compares everything the apps would be sent, everything the agents were asked and the
//! files saved with a file in `pins/`. `UPDATE_FIXTURES=1 cargo test` rewrites the files: read the diff before
//! committing it, since it is the change in behaviour.

use super::*;

/// Stands in for the agents: answers the bridge's commands from a script and keeps what it was asked.
#[derive(Default)]
pub struct Agents {
    answers: std::sync::Mutex<HashMap<String, Value>>,
    asked: std::sync::Mutex<Vec<Value>>,
}

impl Agents {
    /// The scripted answer to a command, or none to let it go to the agent, which no test has.
    pub fn answer(&self, session: &str, kind: &str, fields: &Value) -> Option<Result<Value>> {
        self.asked
            .lock()
            .unwrap()
            .push(json!({ "session": session, "command": kind, "fields": fields }));
        self.answers.lock().unwrap().get(kind).cloned().map(Ok)
    }
}

struct Rig {
    app: Arc<App>,
    hub: broadcast::Receiver<Arc<Envelope>>,
    prime: mpsc::UnboundedSender<DaemonEvent>,
    started: u64,
    /// Each session's summary as last sent, so a pin shows what changed rather than the whole summary again.
    last: HashMap<String, Value>,
    steps: Vec<Value>,
    /// Counts the changes to items instead of listing them, and pins the conversations they add up to: for a feed
    /// that streams a token at a time.
    terse: bool,
}

impl Rig {
    /// A bridge over the files in `saved`, with nothing running but the loop that takes Prime's events.
    fn new(name: &str, saved: &[(&str, &str)]) -> Rig {
        let store = Store::temporary(&format!("pin-{name}"));
        for (file, text) in saved {
            std::fs::write(store.dir().join(file), text).unwrap();
        }
        let limits = store.load_limits();
        let prime = PrimeDaemon::unconnected("test".into());
        let app = App::assemble(store, prime, limits).unwrap();
        let (tx, rx) = mpsc::unbounded_channel();
        tokio::spawn(app.clone().run_prime(rx));
        Rig {
            hub: app.hub.subscribe(),
            app,
            prime: tx,
            started: now_ms(),
            last: HashMap::new(),
            steps: Vec::new(),
            terse: false,
        }
    }

    fn script(&self, command: &str, answer: Value) {
        self.app
            .agents
            .answers
            .lock()
            .unwrap()
            .insert(command.to_string(), answer);
    }

    /// Times taken from the clock during the test read "now": they differ from run to run.
    fn steady(&self, value: &mut Value) {
        match value {
            Value::Object(fields) => {
                for (key, field) in fields.iter_mut() {
                    let clocked = matches!(key.as_str(), "at" | "createdAt" | "lastActiveAt")
                        && field.as_u64().is_some_and(|at| at >= self.started);
                    if clocked {
                        *field = json!("now");
                    } else {
                        self.steady(field);
                    }
                }
            }
            Value::Array(values) => values.iter_mut().for_each(|value| self.steady(value)),
            _ => {}
        }
    }

    /// Lets everything the step set off run to its end (saves, the delayed refresh), then records what was sent.
    async fn settle(&mut self, step: &str) {
        tokio::time::sleep(Duration::from_secs(2)).await;
        let mut sent = Vec::new();
        while let Ok(envelope) = self.hub.try_recv() {
            let mut message: Value = serde_json::from_str(&envelope.json).unwrap();
            self.steady(&mut message);
            if self.terse && message["type"] == "item_patch" {
                match sent
                    .last_mut()
                    .and_then(|last: &mut Value| last.get_mut("patches"))
                {
                    Some(count) => *count = json!(count.as_u64().unwrap() + 1),
                    None => sent.push(json!({ "patches": 1 })),
                }
                continue;
            }
            if message["type"] != "session" {
                sent.push(match envelope.session_id {
                    Some(_) => json!({ "seq": envelope.seq, "message": message }),
                    None => json!({ "message": message }),
                });
                continue;
            }
            let summary = message["session"].take();
            let id = summary["id"].as_str().unwrap().to_string();
            sent.push(match self.last.get(&id) {
                None => json!({ "session": id, "summary": summary }),
                Some(before) => json!({ "session": id, "changed": changed(before, &summary) }),
            });
            self.last.insert(id, summary);
        }
        self.steps.push(json!({ "step": step, "sent": sent }));
    }

    async fn events(&mut self, session: &Arc<Session>, events: &[Value]) {
        for event in events {
            self.app.handle_event(session, event).await;
        }
    }

    fn saved(&self, file: &str) -> Value {
        std::fs::read_to_string(self.app.store.dir().join(file))
            .ok()
            .map(|text| serde_json::from_str(&text).unwrap())
            .unwrap_or(Value::Null)
    }

    /// Compares all that happened with the pin, or rewrites the pin under `UPDATE_FIXTURES`.
    async fn check(self, pin: &str) {
        let mut sessions = json!(self.app.summaries().await);
        self.steady(&mut sessions);
        let mut asked = json!(*self.app.agents.asked.lock().unwrap());
        self.steady(&mut asked);
        let mut seen = json!({
            "steps": self.steps,
            "asked": asked,
            "sessions": sessions,
            "saved": { "sessions.json": self.saved("sessions.json"), "limits.json": self.saved("limits.json") },
        });
        if self.terse {
            let mut conversations = serde_json::Map::new();
            for session in self.app.sessions.read().await.iter() {
                let mut items = json!(session.state.lock().await.transcript.items);
                self.steady(&mut items);
                conversations.insert(session.id.clone(), items);
            }
            seen["conversations"] = Value::Object(conversations);
        }
        let text = serde_json::to_string_pretty(&seen).unwrap() + "\n";
        let path = format!("{}/src/session/pins/{pin}.json", env!("CARGO_MANIFEST_DIR"));
        if std::env::var_os("UPDATE_FIXTURES").is_some() {
            std::fs::write(&path, &text).unwrap();
        }
        let pinned = std::fs::read_to_string(&path).unwrap_or_default();
        let _ = std::fs::remove_dir_all(self.app.store.dir());
        assert!(
            pinned == text,
            "{pin} no longer behaves as pinned. UPDATE_FIXTURES=1 cargo test rewrites {path}: its diff is the change."
        );
    }
}

/// The fields of a summary that differ from the one sent before; a field that went away reads null.
fn changed(before: &Value, after: &Value) -> Value {
    let (before, after) = (before.as_object().unwrap(), after.as_object().unwrap());
    let mut fields = serde_json::Map::new();
    for (key, value) in after {
        if before.get(key) != Some(value) {
            fields.insert(key.clone(), value.clone());
        }
    }
    for key in before.keys().filter(|key| !after.contains_key(*key)) {
        fields.insert(key.clone(), Value::Null);
    }
    Value::Object(fields)
}

fn text(text: &str) -> Value {
    json!([{ "type": "text", "text": text }])
}

fn update(delta: Value) -> Value {
    json!({ "type": "message_update", "message": { "role": "assistant" }, "assistantMessageEvent": delta })
}

const SAVED_SESSIONS: &str = r#"[
  {
    "id": "pi1",
    "agent": "pi",
    "cwd": "/work/project",
    "title": "project",
    "createdAt": 1700000000000,
    "sessionFile": "/work/sessions/pi1.jsonl"
  },
  {
    "id": "dsh1",
    "agent": "deepseek",
    "cwd": "/work/project",
    "title": "A named session",
    "createdAt": 1700000001000,
    "sessionFile": null
  }
]"#;

fn subagent_results(scout_done: bool, reviewer: Value) -> Value {
    let scout_messages = json!([
        { "role": "system", "content": "You are a scout." },
        { "role": "user", "content": text("Find the entry point"), "timestamp": 1_700_000_100_000u64 },
        { "role": "assistant", "content": text("It is src/main.rs."), "stopReason": "stop", "timestamp": 1_700_000_101_000u64 },
    ]);
    json!({ "mode": "parallel", "results": [
        { "agent": "scout", "task": "Find the entry point", "exitCode": if scout_done { 0 } else { -1 },
          "stopReason": if scout_done { json!("stop") } else { Value::Null },
          "messages": if scout_done { scout_messages } else { json!([]) },
          "model": "example/model-1", "usage": { "cost": 0.25, "contextTokens": 1200 } },
        reviewer,
    ] })
}

#[tokio::test(start_paused = true)]
async fn pi_events() {
    let mut rig = Rig::new("pi", &[("sessions.json", SAVED_SESSIONS)]);
    let pi = rig.app.find("pi1").await.unwrap();
    rig.settle("the saved sessions load, stopped").await;

    rig.events(
        &pi,
        &[
            json!({ "type": "agent_start" }),
            json!({ "type": "message_start", "message": { "role": "user", "content": text("List the files\nand count them") } }),
            json!({ "type": "message_end", "message": { "role": "user", "content": text("List the files\nand count them") } }),
            json!({ "type": "message_start", "message": { "role": "assistant", "content": [] } }),
            update(json!({ "type": "thinking_start", "contentIndex": 0 })),
            update(json!({ "type": "thinking_delta", "contentIndex": 0, "delta": "Looking." })),
            update(json!({ "type": "thinking_end", "contentIndex": 0, "content": "Looking." })),
            update(json!({ "type": "text_start", "contentIndex": 1 })),
            update(json!({ "type": "text_delta", "contentIndex": 1, "delta": "I'll list" })),
            update(json!({ "type": "text_delta", "contentIndex": 1, "delta": " the files." })),
            update(json!({ "type": "text_end", "contentIndex": 1, "content": "I'll list the files." })),
            update(json!({ "type": "toolcall_start", "contentIndex": 2, "id": "call_1", "toolName": "bash" })),
            update(json!({ "type": "toolcall_delta", "contentIndex": 2, "delta": "{\"command\":" })),
            update(json!({ "type": "toolcall_delta", "contentIndex": 2, "delta": "\"ls\"}" })),
            update(json!({ "type": "toolcall_end", "contentIndex": 2,
                "toolCall": { "id": "call_1", "name": "bash", "arguments": { "command": "ls" } } })),
            json!({ "type": "message_end", "message": { "role": "assistant", "stopReason": "toolUse", "content": [
                { "type": "thinking", "thinking": "Looking." },
                { "type": "text", "text": "I'll list the files." },
                { "type": "toolCall", "id": "call_1", "name": "bash", "arguments": { "command": "ls" } },
            ] } }),
        ],
    )
    .await;
    rig.settle("a reply streams: thinking, text, a tool call")
        .await;

    rig.events(
        &pi,
        &[
            json!({ "type": "tool_execution_start", "toolCallId": "call_1", "toolName": "bash", "args": { "command": "ls" } }),
            json!({ "type": "tool_execution_update", "toolCallId": "call_1", "toolName": "bash",
                "partialResult": { "content": text("Cargo.toml") } }),
            json!({ "type": "tool_execution_end", "toolCallId": "call_1", "toolName": "bash", "isError": false,
                "durationMs": 12.5, "result": { "content": text("Cargo.toml\nsrc") } }),
            json!({ "type": "message_end", "message": { "role": "toolResult", "toolCallId": "call_1", "toolName": "bash",
                "content": text("Cargo.toml\nsrc") } }),
            json!({ "type": "turn_end" }),
        ],
    )
    .await;
    rig.settle("the tool runs").await;

    rig.events(
        &pi,
        &[
            json!({ "type": "queue_update", "steering": ["look at src", { "content": "then at tests" }],
                "followUp": [{ "content": text("open a pull request") }] }),
            json!({ "type": "thinking_level_changed", "level": "high" }),
            json!({ "type": "session_info_changed", "name": "Listing" }),
            json!({ "type": "session_info_changed" }),
            json!({ "type": "something_the_bridge_does_not_know", "value": 1 }),
            json!({}),
        ],
    )
    .await;
    rig.settle("the queue, the thinking level and the name change; unknown events pass")
        .await;

    let waiting =
        json!({ "agent": "reviewer", "task": "Review the change", "exitCode": -1, "messages": [] });
    let failed = json!({ "agent": "reviewer", "task": "Review the change", "exitCode": 1, "stopReason": "error",
        "stderr": "the model refused\nmore detail", "messages": [
            { "role": "user", "content": text("Review the change") },
        ] });
    rig.events(
        &pi,
        &[
            json!({ "type": "tool_execution_start", "toolCallId": "call_sub-agents.2", "toolName": "subagent", "args": {} }),
            json!({ "type": "tool_execution_update", "toolCallId": "call_sub-agents.2", "toolName": "subagent",
                "partialResult": { "details": subagent_results(false, waiting.clone()) } }),
            json!({ "type": "tool_execution_update", "toolCallId": "call_sub-agents.2", "toolName": "subagent",
                "partialResult": { "details": subagent_results(true, waiting) } }),
        ],
    )
    .await;
    rig.settle("two subagents start; one finishes").await;
    rig.events(
        &pi,
        &[
            json!({ "type": "tool_execution_end", "toolCallId": "call_sub-agents.2", "toolName": "subagent",
                "result": { "content": text("done"), "details": subagent_results(true, failed.clone()) } }),
        ],
    )
    .await;
    rig.settle("the subagent call ends; the other one failed")
        .await;

    rig.events(
        &pi,
        &[
            json!({ "type": "message_start", "message": { "role": "assistant", "content": [] } }),
            update(json!({ "type": "toolcall_start", "contentIndex": 0, "id": "call_3", "toolName": "bash" })),
            json!({ "type": "message_end", "message": { "role": "assistant", "content": [], "stopReason": "error",
                "errorMessage": "tool input is invalid JSON" } }),
            json!({ "type": "auto_retry_start", "attempt": 2, "errorMessage": "tool input is invalid JSON" }),
            json!({ "type": "message_start", "message": { "role": "assistant", "content": [] } }),
            json!({ "type": "message_end", "message": { "role": "assistant", "stopReason": "length",
                "content": text("Two files") } }),
        ],
    )
    .await;
    rig.settle("a reply fails and is retried; the retry stops at the output limit")
        .await;

    rig.events(
        &pi,
        &[
            json!({ "type": "compaction_start" }),
            json!({ "type": "compaction_end", "errorMessage": "nothing to compact" }),
        ],
    )
    .await;
    rig.settle("a compaction fails").await;

    rig.script(
        "get_messages",
        json!({ "messages": [
            { "role": "compactionSummary", "summary": "Listed the files.", "tokensBefore": 52000, "timestamp": 1_700_000_200_000u64 },
            { "role": "user", "content": "Now review", "timestamp": 1_700_000_201_000u64 },
            { "role": "assistant", "timestamp": 1_700_000_202_000u64, "stopReason": "toolUse", "content": [
                { "type": "toolCall", "id": "call_sub-agents.2", "name": "subagent", "arguments": { "tasks": 2 } },
            ] },
            { "role": "toolResult", "toolCallId": "call_sub-agents.2", "toolName": "subagent", "timestamp": 1_700_000_203_500u64,
              "content": text("done"), "details": subagent_results(true, failed) },
            { "role": "bashExecution", "command": "ls", "output": "Cargo.toml", "exitCode": 0, "timestamp": 1_700_000_204_000u64 },
            { "role": "custom", "customType": "goal_context", "content": "hidden" },
            { "role": "custom", "content": "A note", "timestamp": 1_700_000_205_000u64 },
            { "role": "branchSummary", "summary": "From another branch", "timestamp": 1_700_000_206_000u64 },
        ] }),
    );
    rig.events(
        &pi,
        &[
            json!({ "type": "compaction_start" }),
            json!({ "type": "compaction_end" }),
        ],
    )
    .await;
    rig.settle("a compaction succeeds: the conversation is read again, subagents included")
        .await;

    rig.events(
        &pi,
        &[
            json!({ "type": "agent_end" }),
            json!({ "type": "agent_settled" }),
        ],
    )
    .await;
    rig.settle("the agent settles").await;

    rig.app.rename_session(&pi, "  Files  ").await.unwrap();
    rig.settle("the stopped session is renamed").await;
    assert!(rig.app.rename_session(&pi, " ").await.is_err());
    assert!(rig.app.set_context_limit(&pi, Some(8_000)).await.is_err());
    rig.app.set_context_limit(&pi, Some(64_000)).await.unwrap();
    rig.settle("it is given a context window").await;

    rig.check("pi").await;
}

fn prime_row(id: &str, more: Value) -> Value {
    let mut row = json!({
        "activeSessionId": id,
        "sessionId": format!("conversation-{id}"),
        "cwd": "/work/project",
        "created": "2023-11-14T22:13:20.000Z",
        "lastActivityAt": "2023-11-14T22:14:00.000Z",
        "firstMessage": "Make the tests pass\nall of them",
        "activity": "idle",
        "messageCount": 2,
        "model": { "provider": "example", "id": "model-1", "name": "Model One", "reasoning": true },
        "thinkingLevel": "medium",
        "usage": { "cost": 0.5 },
        "sessionFile": format!("/work/sessions/{id}.jsonl"),
        "workerPid": 4242,
        "toolUseCount": 3,
    });
    row.as_object_mut()
        .unwrap()
        .extend(more.as_object().unwrap().clone());
    row
}

fn stats(tokens: u64) -> Value {
    json!({ "cost": 0.75, "contextUsage": { "tokens": tokens, "contextWindow": 400_000, "percent": tokens as f64 / 4000.0 } })
}

#[tokio::test(start_paused = true)]
async fn prime_events() {
    let config =
        r#"{ "token": "test-token", "defaultContextWindows": { "example/model-1": 272000 } }"#;
    let limits = r#"{ "p1": 100000 }"#;
    let mut rig = Rig::new("prime", &[("config.json", config), ("limits.json", limits)]);
    rig.script(
        "get_state",
        json!({ "model": { "provider": "example", "id": "model-1", "name": "Model One", "reasoning": true },
            "thinkingLevel": "medium", "autoCompactionEnabled": true, "isStreaming": false,
            "sessionActions": { "steering": ["look at src"], "followUps": [] } }),
    );
    rig.script("get_session_stats", stats(50_000));
    rig.script(
        "get_available_models",
        json!({ "models": [
            { "provider": "example", "id": "model-1", "thinkingLevelMap": { "off": null, "minimal": null, "max": null } },
        ] }),
    );
    let send = |rig: &Rig, event| rig.prime.send(event).ok().unwrap();

    let subagent = prime_row(
        "p1-sub",
        json!({ "runtimeKind": "subagent", "parentActiveSessionId": "p1", "sessionName": "reviewer",
            "isStreaming": true, "activity": "streaming" }),
    );
    send(
        &rig,
        DaemonEvent::Roster(vec![
            prime_row("p1", json!({ "hasRunningSubagents": true })),
            subagent.clone(),
            json!({ "cwd": "/a/row/without/an/id" }),
        ]),
    );
    rig.settle(
        "the daemon lists a session and its subagent; a window saved under the old id moves",
    )
    .await;

    let p1 = rig.app.find("p1").await.unwrap();
    rig.app.set_context_limit(&p1, Some(64_000)).await.unwrap();
    rig.settle("the session is given a smaller context window")
        .await;

    send(
        &rig,
        DaemonEvent::RosterUpdate(vec![prime_row(
            "p1",
            json!({ "isStreaming": true, "activity": "streaming", "messageCount": 3, "isRunningTools": true,
                "toolUseCount": 4, "sessionName": "Tests", "usage": { "cost": 0.6 },
                "sessionActions": { "steering": [], "followUps": [{ "content": "then open a pull request" }] } }),
        )]),
    );
    rig.settle("its row changes: working, named, a follow-up queued")
        .await;

    p1.state.lock().await.attached = true;
    let event = |event: Value| DaemonEvent::SessionEvent {
        active_session_id: "p1".into(),
        event,
    };
    let partial = |blocks: Value| json!({ "role": "assistant", "content": blocks });
    for message in [
        json!({ "type": "agent_start" }),
        json!({ "type": "message_start", "message": { "role": "assistant", "content": [] } }),
        // Prime leaves out contentIndex and gives the call id only when the call ends.
        json!({ "type": "message_update", "message": partial(json!([{ "type": "text" }])),
            "assistantMessageEvent": { "type": "text_start" } }),
        json!({ "type": "message_update", "message": partial(json!([{ "type": "text" }])),
            "assistantMessageEvent": { "type": "text_delta", "delta": "Running them." } }),
        json!({ "type": "message_update", "message": partial(json!([{ "type": "text" }, { "type": "toolCall" }])),
            "assistantMessageEvent": { "type": "toolcall_start", "toolName": "repl" } }),
        json!({ "type": "message_update", "message": partial(json!([{ "type": "text" }, { "type": "toolCall" }])),
            "assistantMessageEvent": { "type": "toolcall_end",
                "toolCall": { "id": "call_9", "name": "repl", "arguments": { "code": "bash('cargo test')" } } } }),
        json!({ "type": "tool_execution_start", "toolCallId": "call_9", "toolName": "repl", "args": {} }),
        json!({ "type": "tool_execution_end", "toolCallId": "call_9", "toolName": "repl", "isError": true,
            "result": "2 tests failed" }),
        json!({ "type": "goal_update", "goal": { "objective": "Make the tests pass", "status": "active",
            "tokensUsed": 12000, "tokenBudget": 100000, "timeUsedSeconds": 90 } }),
        json!({ "type": "goal_update", "goal": { "objective": "Make the tests pass", "status": "complete" } }),
        json!({ "type": "session_action_update" }),
        json!({ "type": "agent_settled" }),
    ] {
        send(&rig, event(message));
    }
    send(
        &rig,
        DaemonEvent::SessionEvent {
            active_session_id: "nobody".into(),
            event: json!({ "type": "agent_start" }),
        },
    );
    rig.settle("its events arrive: a reply, a tool call, a goal")
        .await;

    rig.script("get_session_stats", stats(60_000));
    send(
        &rig,
        DaemonEvent::RosterUpdate(vec![prime_row(
            "p1",
            json!({ "messageCount": 5, "sessionName": "Tests" }),
        )]),
    );
    rig.settle("it settles close to its window: the bridge asks it to compact, once")
        .await;
    send(
        &rig,
        DaemonEvent::RosterUpdate(vec![prime_row(
            "p1",
            json!({ "messageCount": 6, "sessionName": "Tests" }),
        )]),
    );
    rig.settle("still close to it a moment later: not asked again")
        .await;

    rig.script("get_session_stats", stats(9_000));
    send(
        &rig,
        DaemonEvent::RosterUpdate(vec![prime_row(
            "p1",
            json!({ "sessionId": "conversation-after-new", "messageCount": 0, "firstMessage": null }),
        )]),
    );
    rig.settle("a new conversation starts in the session: its window goes with it")
        .await;

    send(
        &rig,
        DaemonEvent::Inactive {
            session_file: None,
            session_id: Some("conversation-p1-sub".into()),
        },
    );
    rig.settle("the subagent ends").await;

    send(&rig, DaemonEvent::Disconnected("connection refused".into()));
    rig.settle("the daemon goes away").await;

    send(
        &rig,
        DaemonEvent::Roster(vec![prime_row("p2", json!({ "isCompacting": true }))]),
    );
    rig.settle("it comes back with another session only").await;

    send(&rig, DaemonEvent::SessionClosed("p2".into()));
    rig.settle("that session closes").await;

    rig.check("prime").await;
}

#[tokio::test(start_paused = true)]
async fn deepseek_events() {
    let mut rig = Rig::new("deepseek", &[("sessions.json", SAVED_SESSIONS)]);
    rig.terse = true;
    let dsh = rig.app.find("dsh1").await.unwrap();
    rig.events(&dsh, &crate::dsh::tests::recorded_events())
        .await;
    rig.settle("the recorded feed: a background job, a subagent, an answer")
        .await;

    rig.events(
        &dsh,
        &[
            json!({ "type": "dsh_question", "question": { "id": "q1", "continued": false,
                "questions": [{ "id": "mode", "question": "Which mode?", "options": [{ "label": "Fast" }] }] } }),
            json!({ "type": "dsh_jobs", "running": 2 }),
        ],
    )
    .await;
    rig.settle("it asks a question with two commands in the background")
        .await;
    rig.events(
        &dsh,
        &[
            json!({ "type": "dsh_question", "question": null }),
            json!({ "type": "dsh_jobs" }),
        ],
    )
    .await;
    rig.settle("the question is answered and the commands end")
        .await;

    rig.check("deepseek").await;
}
