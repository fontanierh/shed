//! What the session code does with each agent's events, pinned. Each test feeds events through the entry points the
//! bridge itself uses, then compares everything the apps would be sent, everything the agents were asked and the
//! files saved with a file in `pins/`. `UPDATE_FIXTURES=1 cargo test` rewrites the files: read the diff before
//! committing it, since it is the change in behaviour.

use crate::ask::Ask;
use crate::host::now_ms;
use std::sync::atomic::Ordering;
use std::time::Duration;
use strum::IntoEnumIterator;

use futures_util::future::BoxFuture;

use super::*;
use crate::agent::{Agent, Keeps, Sessions, Started, Starts};
use crate::agent_wire::{ConversationId, InactiveRow, KeptRow};
use crate::prime::DaemonEvent;
use crate::protocol::{Goal, ModelInfo};

/// What the tests answer for the agents, and what the bridge asked them.
#[derive(Default)]
pub struct Script {
    answers: std::sync::Mutex<HashMap<String, Value>>,
    /// Commands the agent refuses, and what it says.
    refusals: std::sync::Mutex<HashMap<String, String>>,
    asked: std::sync::Mutex<Vec<Value>>,
    /// Sessions started and sessions closed.
    starts: std::sync::atomic::AtomicUsize,
    closes: std::sync::atomic::AtomicUsize,
    /// The session an agent that keeps its own makes when asked, as its roster would list it.
    made: std::sync::Mutex<Option<Value>>,
    /// Held, a start waits here until the test lets it go.
    start_gate: std::sync::Mutex<Option<std::sync::mpsc::Receiver<()>>>,
    /// How long an answer takes, once it is decided.
    slow_answer: std::sync::Mutex<Duration>,
    /// Held, a close waits here until the test lets it go: an agent slow to exit.
    close_gate: std::sync::Mutex<Option<tokio::sync::oneshot::Receiver<()>>>,
}

/// Stands in for an agent of any kind: Pi and Prime answer from `ScriptedSession`, and DeepSeek runs its real `Dsh`
/// driver over in-memory pipes whose plugin half answers from `Script`.
struct Scripted {
    kind: AgentKind,
    script: Arc<Script>,
    /// The agent it stands for: its ways are that agent's, and so is a session it keeps itself (Prime's daemon,
    /// which no test has connected).
    real: Arc<dyn Agent>,
}

struct ScriptedSession {
    script: Arc<Script>,
    id: String,
    rest: Option<Arc<dyn Live>>,
    /// What it says to a command nobody answers.
    absent: &'static str,
}

/// Runs a real `Dsh` driver over in-memory pipes against a scripted `shed.mjs` peer.
fn scripted_dsh(script: Arc<Script>, opts: &SpawnOptions) -> Started {
    let (to_plugin, from_bridge) = tokio::io::duplex(64 * 1024);
    let (mut to_bridge, from_plugin) = tokio::io::duplex(64 * 1024);
    let (events_tx, events_rx) = mpsc::unbounded_channel();
    let session_id = opts.session_id.clone();
    let dsh = crate::dsh::Dsh::start(opts, to_plugin, from_plugin, events_tx, async {
        "agent exited".into()
    });
    tokio::spawn(async move {
        use tokio::io::AsyncWriteExt;
        if to_bridge
            .write_all(b"{\"event\":\"ready\"}\n")
            .await
            .is_err()
        {
            return;
        }
        let mut lines = tokio::io::BufReader::new(from_bridge);
        let mut buf = Vec::new();
        let mut current_model = json!({
            "provider": "example",
            "model": "model-1",
            "reasoningEffort": "high",
        });
        while let Some(req) = crate::requests::next_message(&mut lines, &mut buf, "test-dsh").await
        {
            let id = req["id"].clone();
            let method = req["method"].as_str().unwrap_or("");
            let params = req.get("params").cloned().unwrap_or_else(|| json!({}));
            if method == "open" {
                if let Some(m) = params.get("model").filter(|m| m.is_object()) {
                    if let Some(p) = m["provider"].as_str() {
                        current_model["provider"] = json!(p);
                    }
                    if let Some(mid) = m["model"].as_str() {
                        current_model["model"] = json!(mid);
                    }
                    if let Some(eff) = m["reasoningEffort"].as_str() {
                        current_model["reasoningEffort"] = json!(eff);
                    }
                }
                let result = script
                    .answers
                    .lock()
                    .unwrap()
                    .get("open")
                    .cloned()
                    .unwrap_or_else(|| {
                        json!({
                            "sessionId": format!("dsh-{session_id}"),
                            "status": "idle",
                            "model": current_model,
                            "contextWindow": 200_000,
                            "reasoning": { "efforts": [{ "id": "low" }, { "id": "high" }] },
                        })
                    });
                let reply = json!({ "id": id, "result": result });
                let _ = to_bridge.write_all(format!("{reply}\n").as_bytes()).await;
                continue;
            }
            if method == "models" {
                let result = script
                    .answers
                    .lock()
                    .unwrap()
                    .get("models")
                    .cloned()
                    .unwrap_or_else(|| {
                        json!({
                            "models": [{
                                "provider": "example",
                                "id": "model-1",
                                "name": "Model One",
                            }]
                        })
                    });
                let reply = json!({ "id": id, "result": result });
                let _ = to_bridge.write_all(format!("{reply}\n").as_bytes()).await;
                continue;
            }
            if method == "close" {
                script.closes.fetch_add(1, Ordering::SeqCst);
                let gate = script.close_gate.lock().unwrap().take();
                if let Some(gate) = gate {
                    let _ = gate.await;
                }
                let reply = json!({ "id": id, "result": {} });
                let _ = to_bridge.write_all(format!("{reply}\n").as_bytes()).await;
                break;
            }
            script.asked.lock().unwrap().push(json!({
                "session": session_id,
                "command": method,
                "fields": params,
            }));
            let refusal = script.refusals.lock().unwrap().get(method).cloned();
            let slow = *script.slow_answer.lock().unwrap();
            if !slow.is_zero() {
                tokio::time::sleep(slow).await;
            }
            let reply = match refusal {
                Some(error) => json!({ "id": id, "error": error }),
                None => {
                    let scripted = script.answers.lock().unwrap().get(method).cloned();
                    let result = scripted.unwrap_or_else(|| match method {
                        "prompt" => json!({ "messageId": "m1" }),
                        "command" => json!({ "kind": "success", "text": "Compacted" }),
                        "select" => {
                            if let Some(p) = params["provider"].as_str() {
                                current_model["provider"] = json!(p);
                            }
                            if let Some(m) = params["model"].as_str() {
                                current_model["model"] = json!(m);
                            }
                            if let Some(e) = params["effort"].as_str() {
                                current_model["reasoningEffort"] = json!(e);
                            }
                            json!({
                                "sessionId": format!("dsh-{session_id}"),
                                "status": "idle",
                                "model": current_model,
                                "contextWindow": 200_000,
                                "reasoning": { "efforts": [{ "id": "low" }, { "id": "high" }] },
                            })
                        }
                        "jobs" => json!({ "jobs": [] }),
                        _ => json!({}),
                    });
                    json!({ "id": id, "result": result })
                }
            };
            if to_bridge
                .write_all(format!("{reply}\n").as_bytes())
                .await
                .is_err()
            {
                break;
            }
        }
    });
    (dsh, events_rx)
}

impl Starts for Scripted {
    fn start(&self, opts: &SpawnOptions) -> Result<Started> {
        self.script.starts.fetch_add(1, Ordering::SeqCst);
        if let Some(gate) = self.script.start_gate.lock().unwrap().take() {
            gate.recv().unwrap();
        }
        if self.kind == AgentKind::Deepseek {
            return Ok(scripted_dsh(self.script.clone(), opts));
        }
        let (_events, output) = mpsc::unbounded_channel();
        Ok((self.live("started"), output))
    }
}

impl Keeps for Scripted {
    /// Counted as a close, and nothing run: no daemon is connected.
    fn stop(&self, _id: &str) -> BoxFuture<'_, Result<()>> {
        self.script.closes.fetch_add(1, Ordering::SeqCst);
        Box::pin(async { Ok(()) })
    }

    fn session(&self, id: &str) -> Arc<dyn Live> {
        let Sessions::Kept(real) = self.real.sessions() else {
            unreachable!("asked only of an agent that keeps its sessions")
        };
        Arc::new(ScriptedSession {
            script: self.script.clone(),
            id: id.to_string(),
            rest: Some(real.session(id)),
            absent: "session is not running",
        })
    }

    fn create(
        &self,
        cwd: String,
        model: Option<String>,
        thinking: Option<String>,
    ) -> BoxFuture<'_, Result<KeptRow>> {
        let made = self.script.made.lock().unwrap().clone();
        match made.as_ref().and_then(KeptRow::read) {
            Some(row) => Box::pin(async move { Ok(row) }),
            None => Box::pin(async move {
                let Sessions::Kept(real) = self.real.sessions() else {
                    unreachable!("asked only of an agent that keeps its sessions")
                };
                real.create(cwd, model, thinking).await
            }),
        }
    }
}

impl Agent for Scripted {
    /// As the agent it stands for: a stopped session of an agent the bridge starts has nobody to ask.
    fn sessions(&self) -> Sessions<'_> {
        match self.real.sessions() {
            Sessions::Started(_) => Sessions::Started(self),
            Sessions::Kept(_) => Sessions::Kept(self),
        }
    }

    fn models(&self) -> BoxFuture<'_, Result<Value>> {
        Box::pin(async { Ok(json!([])) })
    }

    fn jobs(&self) -> crate::agent::JobsFrom {
        self.real.jobs()
    }

    fn subagents(&self) -> crate::agent::SubagentsFrom {
        self.real.subagents()
    }

    fn gateway_session(
        &self,
        session_file: Option<&str>,
        conversation: Option<&ConversationId>,
    ) -> Option<String> {
        self.real.gateway_session(session_file, conversation)
    }

    fn cost(&self, session_file: Option<&str>, reported: f64, before: f64) -> f64 {
        self.real.cost(session_file, reported, before)
    }

    fn spend_includes_subagents(&self) -> bool {
        self.real.spend_includes_subagents()
    }

    /// The real agent's: what the tests pin is what its commands become.
    fn verbs(&self) -> &'static dyn crate::agent::Verbs {
        self.real.verbs()
    }
}

impl Scripted {
    fn live(&self, id: &str) -> Arc<dyn Live> {
        Arc::new(ScriptedSession {
            script: self.script.clone(),
            id: id.to_string(),
            rest: None,
            absent: "agent is not running",
        })
    }
}

impl Live for ScriptedSession {
    fn send(&self, ask: Ask) -> BoxFuture<'_, Result<Value>> {
        Box::pin(async move {
            // Recorded and answered as it goes to the agent.
            let Some((kind, fields)) = ask.wire() else {
                bail!("{} has no {ask:?} command", self.id);
            };
            let kind = kind.to_string();
            self.script
                .asked
                .lock()
                .unwrap()
                .push(json!({ "session": self.id, "command": kind, "fields": fields }));
            let refusal = self.script.refusals.lock().unwrap().get(&kind).cloned();
            let slow = *self.script.slow_answer.lock().unwrap();
            if !slow.is_zero() {
                tokio::time::sleep(slow).await;
            }
            if let Some(refusal) = refusal {
                return Err(anyhow::Error::new(crate::agent::Refused(refusal)));
            }
            let scripted = self.script.answers.lock().unwrap().get(&kind).cloned();
            match (scripted, &self.rest) {
                (Some(answer), _) => Ok(answer),
                (None, Some(rest)) => rest.send(ask).await,
                (None, None) => Err(anyhow!("{}", self.absent)),
            }
        })
    }

    fn close(&self) -> BoxFuture<'_, ()> {
        Box::pin(async {
            self.script.closes.fetch_add(1, Ordering::SeqCst);
            let gate = self.script.close_gate.lock().unwrap().take();
            if let Some(gate) = gate {
                let _ = gate.await;
            }
        })
    }
}

struct Rig {
    app: Arc<App>,
    agents: Arc<Script>,
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
    /// The next start waits until the returned sender is sent to.
    fn hold_starts(&self) -> std::sync::mpsc::Sender<()> {
        let (release, gate) = std::sync::mpsc::channel();
        *self.agents.start_gate.lock().unwrap() = Some(gate);
        release
    }

    /// Until an agent is being started.
    async fn a_start_waits(&self) {
        while self.agents.starts.load(Ordering::SeqCst) == 0 {
            tokio::task::yield_now().await;
        }
    }

    /// A bridge over the files in `saved`, with nothing running but the loop that takes Prime's events.
    fn new(name: &str, saved: &[(&str, &str)]) -> Rig {
        let store = Store::temporary(&format!("pin-{name}"));
        for (file, text) in saved {
            std::fs::write(store.dir().join(file), text).unwrap();
        }
        let limits = store.load_limits();
        let prime = PrimeDaemon::unconnected("test".into(), store.clone());
        let script = Arc::new(Script::default());
        let installed = Agents::installed(prime.clone(), store.clone());
        let agents = Agents::of(|kind| {
            Arc::new(Scripted {
                kind,
                script: script.clone(),
                real: installed.get(kind).clone(),
            })
        });
        let app = App::assemble(store, limits, agents).unwrap();
        let (tx, rx) = mpsc::unbounded_channel();
        tokio::spawn(app.clone().run_prime(rx));
        Rig {
            hub: app.hub.subscribe(),
            app,
            agents: script,
            prime: tx,
            started: now_ms(),
            last: HashMap::new(),
            steps: Vec::new(),
            terse: false,
        }
    }

    fn summary(&self, id: &str, agent: AgentKind, kind: SessionKind, cwd: &str) -> SessionSummary {
        new_summary(&self.app.agents, id, agent, kind, false, cwd)
    }

    fn script(&self, command: &str, answer: Value) {
        self.agents
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
        let mut asked = json!(*self.agents.asked.lock().unwrap());
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
            "{pin} no longer behaves as pinned, from {}. UPDATE_FIXTURES=1 cargo test rewrites {path}: its diff is \
             the change.",
            first_difference(&pinned, &text)
        );
    }
}

/// Where two texts part, for a failure that can be read without rewriting the pin.
fn first_difference(pinned: &str, seen: &str) -> String {
    let mut lines = pinned.lines().zip(seen.lines()).enumerate();
    match lines.find(|(_, (pinned, seen))| pinned != seen) {
        Some((at, (pinned, seen))) => format!(
            "line {}: pinned `{}`, now `{}`",
            at + 1,
            pinned.trim(),
            seen.trim()
        ),
        None => format!(
            "line {}, where one of them ends",
            pinned.lines().count().min(seen.lines().count()) + 1
        ),
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
    // Reading the conversation again asks the agent, so for this step the session has one, as a resumed one does.
    pi.state.lock().await.own = own(&rig, "pi1", Backend::Started, true);
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
    pi.state.lock().await.own = BackendState::started();

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

fn rows(rows: Vec<Value>) -> Vec<KeptRow> {
    rows.iter().filter_map(KeptRow::read).collect()
}

fn roster(all: Vec<Value>) -> DaemonEvent {
    DaemonEvent::Roster(rows(all))
}

fn roster_update(changed: Vec<Value>) -> DaemonEvent {
    DaemonEvent::RosterUpdate(rows(changed))
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
        roster(vec![
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
        roster_update(vec![prime_row(
            "p1",
            json!({ "isStreaming": true, "activity": "streaming", "messageCount": 3, "isRunningTools": true,
                "toolUseCount": 4, "sessionName": "Tests", "usage": { "cost": 0.6 },
                "sessionActions": { "steering": [], "followUps": [{ "content": "then open a pull request" }] } }),
        )]),
    );
    rig.settle("its row changes: working, named, a follow-up queued")
        .await;

    p1.state.lock().await.prime_mut().unwrap().attached = true;
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
        roster_update(vec![prime_row(
            "p1",
            json!({ "messageCount": 5, "sessionName": "Tests" }),
        )]),
    );
    rig.settle("it settles close to its window: the bridge asks it to compact, once")
        .await;
    send(
        &rig,
        roster_update(vec![prime_row(
            "p1",
            json!({ "messageCount": 6, "sessionName": "Tests" }),
        )]),
    );
    rig.settle("still close to it a moment later: not asked again")
        .await;

    rig.script("get_session_stats", stats(9_000));
    send(
        &rig,
        roster_update(vec![prime_row(
            "p1",
            json!({ "sessionId": "conversation-after-new", "messageCount": 0, "firstMessage": null }),
        )]),
    );
    rig.settle("a new conversation starts in the session: its window goes with it")
        .await;

    send(
        &rig,
        DaemonEvent::Inactive(
            InactiveRow::read(&json!({ "sessionId": "conversation-p1-sub" })).unwrap(),
        ),
    );
    rig.settle("the subagent ends").await;

    send(&rig, DaemonEvent::Disconnected("connection refused".into()));
    rig.settle("the daemon goes away").await;

    send(
        &rig,
        roster(vec![prime_row("p2", json!({ "isCompacting": true }))]),
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
    // The feed times each tool with the clock. Replayed, a tool takes no time, or a millisecond on a slow run.
    let mut recorded = crate::dsh::tests::recorded_events();
    for event in &mut recorded {
        if event["type"] == "tool_execution_end" {
            event["durationMs"] = json!(0);
        }
    }
    rig.events(&dsh, &recorded).await;
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

/// Every way one part of `base` can be wrong: missing, or of another type. Agents are other programs, and the bridge
/// must read what it can of what they send.
fn malformed(base: &Value) -> Vec<(String, String, Value)> {
    fn paths(value: &Value, at: Vec<String>, out: &mut Vec<Vec<String>>) {
        match value {
            Value::Object(fields) => {
                for (key, field) in fields {
                    let mut path = at.clone();
                    path.push(key.clone());
                    out.push(path.clone());
                    paths(field, path, out);
                }
            }
            Value::Array(values) if !values.is_empty() => {
                let mut path = at;
                path.push("0".into());
                out.push(path.clone());
                paths(&values[0], path, out);
            }
            _ => {}
        }
    }
    fn replace(value: &mut Value, path: &[String], with: Option<&Value>) {
        let (last, parents) = path.split_last().unwrap();
        let mut at = value;
        for key in parents {
            at = match at {
                Value::Array(values) => &mut values[0],
                other => &mut other[key.as_str()],
            };
        }
        match (at, with) {
            (Value::Array(values), Some(with)) => values[0] = with.clone(),
            (Value::Array(values), None) => {
                values.remove(0);
            }
            (Value::Object(fields), Some(with)) => {
                fields.insert(last.clone(), with.clone());
            }
            (Value::Object(fields), None) => {
                fields.remove(last);
            }
            _ => unreachable!(),
        }
    }
    let wrong = [
        json!(null),
        json!(true),
        json!(7),
        json!(-3),
        json!(1.5),
        json!("text"),
        json!([]),
        json!({}),
    ];
    let mut all = Vec::new();
    paths(base, Vec::new(), &mut all);
    let mut out = Vec::new();
    for path in all {
        let name = path.join(".");
        let mut without = base.clone();
        replace(&mut without, &path, None);
        out.push((name.clone(), "missing".to_string(), without));
        for value in &wrong {
            let mut changed = base.clone();
            replace(&mut changed, &path, Some(value));
            out.push((name.clone(), value.to_string(), changed));
        }
    }
    out
}

/// Where two values differ, by path; a part only one of them has reads null on the other side.
fn differences(before: &Value, after: &Value, at: &str, out: &mut serde_json::Map<String, Value>) {
    match (before, after) {
        (Value::Object(a), Value::Object(b)) => {
            let keys: std::collections::BTreeSet<&String> = a.keys().chain(b.keys()).collect();
            for key in keys {
                let path = if at.is_empty() {
                    key.clone()
                } else {
                    format!("{at}.{key}")
                };
                differences(
                    a.get(key).unwrap_or(&Value::Null),
                    b.get(key).unwrap_or(&Value::Null),
                    &path,
                    out,
                );
            }
        }
        (a, b) if a != b => {
            out.insert(at.to_string(), b.clone());
        }
        _ => {}
    }
}

/// What the bridge makes of each malformed message, as its difference from what it makes of the well-formed one.
/// Messages wrong in different ways that come out the same are listed together.
async fn leniency<F, Fut>(pin: &str, base: Value, outcome: F)
where
    F: Fn(Value) -> Fut,
    Fut: std::future::Future<Output = Value>,
{
    let expected = outcome(base.clone()).await;
    let mut by_part: std::collections::BTreeMap<String, Vec<(Value, Vec<String>)>> =
        Default::default();
    for (part, wrong, message) in malformed(&base) {
        let mut diff = serde_json::Map::new();
        differences(&expected, &outcome(message).await, "", &mut diff);
        let diff = Value::Object(diff);
        let outcomes = by_part.entry(part).or_default();
        match outcomes.iter_mut().find(|(known, _)| *known == diff) {
            Some((_, ways)) => ways.push(wrong),
            None => outcomes.push((diff, vec![wrong])),
        }
    }
    let parts: serde_json::Map<String, Value> = by_part
        .into_iter()
        .map(|(part, outcomes)| {
            let outcomes: Vec<Value> = outcomes
                .into_iter()
                .map(|(diff, ways)| json!({ "when": ways.join(" | "), "differs": diff }))
                .collect();
            (part, json!(outcomes))
        })
        .collect();
    let seen = json!({ "wellFormed": expected, "malformed": parts });
    let text = serde_json::to_string_pretty(&seen).unwrap() + "\n";
    let path = format!("{}/src/session/pins/{pin}.json", env!("CARGO_MANIFEST_DIR"));
    if std::env::var_os("UPDATE_FIXTURES").is_some() {
        std::fs::write(&path, &text).unwrap();
    }
    let pinned = std::fs::read_to_string(&path).unwrap_or_default();
    assert!(
        pinned == text,
        "{pin} no longer reads malformed messages as pinned, from {}. UPDATE_FIXTURES=1 cargo test rewrites {path}.",
        first_difference(&pinned, &text)
    );
}

/// A session's summary and the rest of what the bridge keeps from the agent's messages.
///
/// Four of these never leave the bridge: `named`, `levelsFor`, `toolCalls`, `rosterMark`. They are pinned on
/// purpose. Each is the only place a field of the agent's message shows at once (a roster row's activity and
/// message count, its running tools, the model the levels were read for); what they later cause (a refresh, a
/// stall notice, a title left alone) comes steps or minutes after. Without them a malformed value in those fields
/// reads the same as a good one in every pin. The cost is that renaming or reshaping this bookkeeping changes the
/// pins though nothing an app sees does: such a diff must touch these four keys and nothing else.
async fn kept(rig: &Rig, session: &Session) -> Value {
    let st = session.state.lock().await;
    let mut kept = json!({
        "summary": st.summary,
        "sessionFile": st.session_file,
        "named": st.named,
        "levelsFor": st.levels_for,
        "primeSession": st.prime().and_then(|prime| prime.conversation.as_ref()).map(ConversationId::as_str),
        "workerPid": st.worker_pid(),
        "toolCalls": st.prime().and_then(|prime| prime.tools).map(|(calls, _)| calls),
        "rosterMark": st.prime().map_or((String::new(), 0), |prime| prime.roster_mark.clone()),
        "items": st.transcript.items,
    });
    rig.steady(&mut kept);
    kept
}

#[tokio::test(start_paused = true)]
async fn malformed_prime_rows() {
    let rig = &Rig::new("prime-rows", &[]);
    let earlier = &prime_row(
        "p1",
        json!({ "sessionName": "earlier", "thinkingLevel": "low", "usage": { "cost": 0.25 }, "workerPid": 1,
            "isRunningTools": true, "sessionFile": "/work/sessions/earlier.jsonl",
            "model": { "provider": "example", "id": "model-1", "name": "Model One", "contextWindow": 200000 },
            "sessionActions": { "steering": ["earlier"] } }),
    );
    let base = prime_row(
        "p1",
        json!({ "runtimeKind": "subagent", "parentActiveSessionId": "p0", "sessionName": "reviewer",
            "hasRunningSubagents": true, "isStreaming": true, "isCompacting": false, "isRunningTools": true,
            "model": { "provider": "example", "id": "model-1", "name": "Model One", "reasoning": true, "contextWindow": 400000 },
            "sessionActions": { "steering": ["look at src", { "content": "then at tests" }],
                "followUps": [{ "content": [{ "type": "text", "text": "open a pull request" }] }] } }),
    );
    leniency("prime-rows-malformed", base, |row| async move {
        let mut seen = serde_json::Map::new();
        for (case, before) in [("new", None), ("known", Some(earlier))] {
            if let Some(before) = before.and_then(KeptRow::read) {
                rig.app.apply_kept_row(AgentKind::Prime, before).await;
            }
            let kept = match KeptRow::read(&row) {
                Some(row) => kept(rig, &*rig.app.apply_kept_row(AgentKind::Prime, row).await).await,
                None => json!("not listed"),
            };
            seen.insert(case.into(), kept);
            rig.app.sessions.write().await.clear();
        }
        Value::Object(seen)
    })
    .await;
}

#[tokio::test(start_paused = true)]
async fn malformed_state_and_stats() {
    let config = r#"{ "token": "t", "defaultContextWindows": { "example/model-1": 272000 } }"#;
    let rig = &Rig::new("answers", &[("config.json", config)]);
    let base = json!({
        "get_state": { "model": { "provider": "example", "id": "model-1", "name": "Model One", "reasoning": true },
            "thinkingLevel": "medium", "autoCompactionEnabled": false, "isStreaming": true, "isCompacting": false,
            "sessionName": "Tests", "sessionFile": "/work/sessions/p1.jsonl",
            "sessionActions": { "steering": ["look at src"], "followUps": [{ "content": "then open a pull request" }] } },
        "get_session_stats": { "cost": 0.75, "sessionFile": "/work/sessions/p1.jsonl",
            "contextUsage": { "tokens": 50000, "contextWindow": 400000, "percent": 12.5 } },
        "get_available_models": { "models": [
            { "provider": "example", "id": "model-1", "thinkingLevelMap": { "off": null, "max": null } } ] },
        "get_available_thinking_levels": { "levels": ["low", "high"] },
    });
    for (pin, agent, backend) in [
        ("answers-malformed-prime", AgentKind::Prime, Backend::Prime),
        ("answers-malformed-pi", AgentKind::Pi, Backend::Started),
    ] {
        leniency(pin, base.clone(), |answers| async move {
            *rig.agents.answers.lock().unwrap() =
                serde_json::from_value(answers).unwrap_or_default();
            // What an earlier refresh left, so a part the agent leaves out shows as kept.
            let mut summary = rig.summary("s1", agent, SessionKind::Root, "/work/project");
            summary.title = "Earlier".into();
            summary.thinking_level = Some("low".into());
            summary.thinking_levels = vec!["low".into()];
            summary.cost = 0.25;
            summary.queue.steering = vec!["earlier".into()];
            summary.model = Some(ModelInfo {
                provider: "example".into(),
                id: "model-0".into(),
                name: "Model Zero".into(),
                context_window: Some(200_000),
                reasoning: true,
            });
            let file = Some("/work/sessions/earlier.jsonl".into());
            let mut state = SessionState::new(
                summary,
                file,
                own(rig, "s1", backend, backend == Backend::Started),
            );
            state.levels_for = Some("example/model-0".into());
            let session = Arc::new(Session::new(
                "s1".into(),
                agent,
                "/work/project".into(),
                state,
            ));
            let mut refreshed = match rig.app.refresh(&session).await {
                Ok(()) => kept(rig, &session).await,
                Err(error) => json!({ "fails": error.to_string() }),
            };
            let asked: Vec<Value> = std::mem::take(&mut *rig.agents.asked.lock().unwrap())
                .into_iter()
                .map(|asked| asked["command"].clone())
                .collect();
            refreshed["asked"] = json!(asked);
            refreshed
        })
        .await;
    }
}

/// What a session of this backend starts with. One that is `live` has its agent: a Pi process that does nothing, or
/// Prime's daemon attached.
fn own(rig: &Rig, id: &str, backend: Backend, live: bool) -> BackendState {
    match backend {
        Backend::Started if live => {
            BackendState::Started(Process::Running(Arc::new(ScriptedSession {
                script: rig.agents.clone(),
                id: id.to_string(),
                rest: None,
                absent: "agent is not running",
            })))
        }
        Backend::Started => BackendState::started(),
        Backend::Prime => BackendState::Prime(PrimeState {
            wanted: live,
            attached: live,
            ..Default::default()
        }),
        Backend::Subagent => BackendState::subagent(),
    }
}

/// The subagent sessions of the rig, by id, then gone.
async fn subagents(rig: &Rig) -> serde_json::Map<String, Value> {
    let mut seen = serde_json::Map::new();
    let all = rig.app.sessions.read().await.clone();
    for session in all.iter().filter(|s| s.backend == Backend::Subagent) {
        seen.insert(session.id.clone(), kept(rig, session).await);
    }
    rig.app
        .sessions
        .write()
        .await
        .retain(|s| s.backend != Backend::Subagent);
    seen
}

#[tokio::test(start_paused = true)]
async fn malformed_subagents() {
    let rig = &Rig::new("subagents", &[("sessions.json", SAVED_SESSIONS)]);
    let pi = &rig.app.find("pi1").await.unwrap();
    let dsh = &rig.app.find("dsh1").await.unwrap();

    let earlier = &json!({ "mode": "single", "results": [
        { "agent": "scout", "task": "Earlier", "exitCode": 0, "model": "example/model-0",
          "usage": { "cost": 0.5, "contextTokens": 100 },
          "messages": [{ "role": "user", "content": "Earlier" }, { "role": "assistant", "content": "On it" }] },
    ] });
    let details = json!({ "mode": "chain", "results": [
        { "agent": "scout", "task": "Find the entry point", "exitCode": 0, "stopReason": "stop",
          "model": "example/model-1", "stderr": "a warning", "usage": { "cost": 0.25, "contextTokens": 1200 },
          "messages": [{ "role": "system", "content": "You are a scout" }, { "role": "user", "content": "Find the entry point" }] },
        { "agent": "reviewer", "task": "Review it", "exitCode": 1, "stopReason": "error", "stderr": "refused",
          "messages": [] },
    ] });
    leniency("pi-subagents-malformed", details, |details| async move {
        let mut seen = serde_json::Map::new();
        for (case, before) in [("new", None), ("known", Some(earlier))] {
            for details in [before, Some(&details)].into_iter().flatten() {
                let event = json!({ "type": "tool_execution_update", "toolName": "subagent",
                    "toolCallId": "call_1", "partialResult": { "details": details } });
                if let SessionEvent::PiSubagentCall(call) = SessionEvent::read(&event) {
                    rig.app.update_pi_subagents(pi, call).await;
                }
            }
            seen.insert(case.into(), Value::Object(subagents(rig).await));
        }
        Value::Object(seen)
    })
    .await;

    let earlier = &json!({ "type": "dsh_subagent", "id": "f117882d-2d43", "status": "running", "title": "Earlier",
        "model": "example/model-0", "createdAt": 1_600_000_000_000u64, "lastActiveAt": 1_600_000_005_000u64,
        "messages": [{ "role": "user", "content": "Earlier" }, { "role": "assistant", "content": "On it" }] });
    let child = json!({ "type": "dsh_subagent", "id": "f117882d-2d43", "parent": "0a1b2c3d-4e5f", "status": "error",
        "title": "Read notes.txt", "error": "the model refused\nmore", "model": "example/model-1",
        "createdAt": 1_700_000_000_000u64, "lastActiveAt": 1_700_000_005_000u64,
        "messages": [{ "role": "user", "content": "Read notes.txt" }] });
    leniency("dsh-subagents-malformed", child, |child| async move {
        let mut seen = serde_json::Map::new();
        for (case, before) in [("new", None), ("known", Some(earlier))] {
            for child in [before, Some(&child)].into_iter().flatten() {
                if let Some(child) = DshSubagent::read(child) {
                    rig.app.update_dsh_subagent(dsh, child).await;
                }
            }
            let running = dsh.state.lock().await.summary.running_subagents;
            let mut kept = subagents(rig).await;
            kept.insert("parentRunningSubagents".into(), json!(running));
            seen.insert(case.into(), Value::Object(kept));
        }
        Value::Object(seen)
    })
    .await;
}

#[tokio::test]
async fn malformed_goals() {
    let goal = json!({ "objective": "Make the tests pass", "status": "active", "tokensUsed": 1200,
        "tokenBudget": 50000, "timeUsedSeconds": 90, "lastReason": "still failing" });
    leniency("goal-malformed", goal, |goal| async move {
        json!(Goal::from_value(&goal))
    })
    .await;
}

#[tokio::test(start_paused = true)]
async fn malformed_events() {
    let rig = &Rig::new("events", &[]);
    let events = json!({
        "compaction": { "type": "compaction_end", "aborted": false, "errorMessage": null },
        "queue": { "type": "queue_update", "steering": ["look at src"], "followUp": [{ "content": "then open a pull request" }] },
        "level": { "type": "thinking_level_changed", "level": "high" },
        "name": { "type": "session_info_changed", "name": "Tests" },
        "goal": { "type": "goal_update", "goal": { "objective": "Make the tests pass", "status": "active" } },
        "jobs": { "type": "dsh_jobs", "running": 2 },
        "question": { "type": "dsh_question", "question": { "text": "Which branch?" } },
        "subagent": { "type": "dsh_subagent", "id": "f117882d-2d43", "status": "running", "title": "Read notes.txt" },
        "call": { "type": "tool_execution_update", "toolName": "subagent", "toolCallId": "call_1",
            "partialResult": { "details": { "mode": "single", "results": [{ "agent": "scout", "task": "Find it" }] } } },
        "result": { "type": "tool_execution_end", "toolName": "subagent", "toolCallId": "call_1",
            "result": { "details": { "mode": "single", "results": [{ "agent": "scout", "task": "Find it", "stopReason": "stop" }] } } },
    });
    leniency("events-malformed", events, |events| async move {
        let mut seen = serde_json::Map::new();
        for (name, event) in events.as_object().into_iter().flatten() {
            let agent = if name == "subagent" {
                AgentKind::Deepseek
            } else {
                AgentKind::Pi
            };
            // What earlier events left, so a part the agent leaves out shows as kept or dropped.
            let mut summary = rig.summary("s1", agent, SessionKind::Root, "/work/project");
            summary.title = "Earlier".into();
            summary.thinking_level = Some("low".into());
            summary.queue.steering = vec!["earlier".into()];
            summary.background_jobs = 1;
            summary.question = Some(json!({ "text": "Earlier?" }));
            let mut state = SessionState::new(summary, None, BackendState::started());
            state.named = true;
            let session = Arc::new(Session::new(
                "s1".into(),
                agent,
                "/work/project".into(),
                state,
            ));
            rig.app.sessions.write().await.push(session.clone());
            rig.app.handle_event(&session, event).await;
            let mut kept = kept(rig, &session).await;
            // The conversation is the transcript's to read, and has its own tests.
            kept.as_object_mut().unwrap().remove("items");
            // How a subagent's own parts are read is pinned on its own: here, only that it shows.
            let shown: serde_json::Map<String, Value> = subagents(rig)
                .await
                .into_iter()
                .map(|(id, subagent)| (id, subagent["summary"]["status"].clone()))
                .collect();
            kept["subagents"] = Value::Object(shown);
            rig.app.sessions.write().await.clear();
            seen.insert(name.clone(), kept);
        }
        Value::Object(seen)
    })
    .await;
}

/// What each thing a client can ask of a session asks of its agent, answers, and changes in what the bridge keeps:
/// for a Pi session, a DeepSeek Harness one, a Prime one, a stopped one and a subagent.
#[tokio::test(start_paused = true)]
async fn commands() {
    let rig = &Rig::new("commands", &[]);
    let answers = json!({
        "prompt": {}, "steer": {}, "follow_up": {}, "compact": {}, "abort": {}, "abort_and_send_queued": {},
        "set_session_name": {}, "set_auto_compaction": {}, "answer": {}, "new_session": { "cancelled": false },
        "get_state": { "model": { "provider": "example", "id": "model-1", "name": "Model One" },
            "thinkingLevel": "high", "sessionName": "From the agent", "sessionFile": "/work/sessions/s1.jsonl" },
        "get_session_stats": { "cost": 0.5, "contextUsage": { "tokens": 1000, "contextWindow": 200000, "percent": 0.5 } },
        "get_messages": { "messages": [{ "role": "user", "content": text("A new start"), "timestamp": 1_700_000_100_000u64 }] },
        "get_available_models": { "models": [] },
        "get_available_thinking_levels": { "levels": ["low", "high"] },
    });
    // Whether the agent is there to answer. A stopped session has no agent, and a subagent takes no commands.
    // Every agent there is, running, so a new one is pinned the day it is added; then the two ways a session takes
    // no commands.
    let mut kinds: Vec<(String, AgentKind, Backend, bool)> = AgentKind::iter()
        .map(|agent| {
            let backend = match rig.app.agent(agent).sessions() {
                Sessions::Started(_) => Backend::Started,
                Sessions::Kept(_) => Backend::Prime,
            };
            (
                json!(agent).as_str().unwrap().to_string(),
                agent,
                backend,
                true,
            )
        })
        .collect();
    kinds.push(("pi, stopped".into(), AgentKind::Pi, Backend::Started, false));
    kinds.push(("subagent".into(), AgentKind::Pi, Backend::Subagent, false));
    let cases = [
        "rename",
        "rename to nothing",
        "send",
        "send while it works",
        "send, and the agent is already streaming",
        "follow up",
        "abort",
        "compact",
        "compact with instructions",
        "compact with blank instructions",
        "auto compaction",
        "clear the goal",
        "restart the kernel",
        "stop the tool",
        "answer",
        "new session",
    ];
    let mut seen = serde_json::Map::new();
    for (kind, agent, backend, answering) in kinds {
        let mut of_kind = serde_json::Map::new();
        for case in cases {
            *rig.agents.answers.lock().unwrap() = match answering {
                true => serde_json::from_value(answers.clone()).unwrap(),
                false => HashMap::new(),
            };
            *rig.agents.refusals.lock().unwrap() = match case {
                "send, and the agent is already streaming" if answering => HashMap::from([(
                    "prompt".to_string(),
                    "Agent is already streaming".to_string(),
                )]),
                _ => HashMap::new(),
            };
            let mut summary = rig.summary("s1", agent, SessionKind::Root, "/work/project");
            summary.title = "Earlier".into();
            if case == "send while it works" {
                summary.status = SessionStatus::Running;
            }
            let (own_state, dsh_events) =
                if agent == AgentKind::Deepseek && backend == Backend::Started && answering {
                    let opts = SpawnOptions {
                        agent,
                        session_id: "s1".into(),
                        cwd: "/work/project".into(),
                        model: None,
                        thinking: None,
                        resume: None,
                    };
                    let (child, rx) = scripted_dsh(rig.agents.clone(), &opts);
                    (
                        BackendState::Started(Process::Running(child.clone())),
                        Some((child, rx)),
                    )
                } else {
                    (own(rig, "s1", backend, answering), None)
                };
            let state = SessionState::new(summary, None, own_state);
            let session = &Arc::new(Session::new(
                "s1".into(),
                agent,
                "/work/project".into(),
                state,
            ));
            if let Some((child, rx)) = dsh_events {
                tokio::spawn(rig.app.clone().run_pi_events(session.clone(), child, rx));
            }
            let before = kept(rig, session).await;
            let app = &rig.app;
            let answer = match case {
                "rename" => app
                    .rename_session(session, "  Plan the release ")
                    .await
                    .map(|()| Value::Null),
                "rename to nothing" => app
                    .rename_session(session, "  ")
                    .await
                    .map(|()| Value::Null),
                "compact" => app.compact(session, None).await,
                "compact with instructions" => {
                    app.compact(session, Some("keep the plan".into())).await
                }
                "compact with blank instructions" => app.compact(session, Some("  ".into())).await,
                "clear the goal" => app.clear_goal(session).await,
                "restart the kernel" => app.restart_kernel(session).await,
                "follow up" => app.follow_up(session, "After that".into()).await,
                "abort" => app.abort(session).await,
                "auto compaction" => app
                    .set_auto_compaction(session, false)
                    .await
                    .map(|()| Value::Null),
                "stop the tool" => app.stop_tool(session).await,
                "answer" => app
                    .answer_question(
                        session,
                        "q1".into(),
                        vec![json!({ "id": "mode", "selected": ["Fast"] })],
                    )
                    .await
                    .map(|()| Value::Null),
                "new session" => app.new_session(session).await,
                _ => app.send_text(session, "Carry on".into(), None).await,
            };
            // The refresh a command leaves for later.
            tokio::time::sleep(Duration::from_secs(2)).await;
            let mut changed = serde_json::Map::new();
            differences(&before, &kept(rig, session).await, "", &mut changed);
            // What a refresh reads is pinned on its own: here, only that it ran, and the name it left.
            let refreshed = changed.remove("levelsFor").is_some();
            changed.retain(|part, _| matches!(part.as_str(), "named" | "summary.title" | "items"));
            if let Some(items) = changed.get_mut("items") {
                *items = json!(items.as_array().map(Vec::len));
            }
            let asked: Vec<Value> = std::mem::take(&mut *rig.agents.asked.lock().unwrap())
                .into_iter()
                .map(|mut asked| {
                    asked.as_object_mut().unwrap().remove("session");
                    asked
                })
                .collect();
            let mut outcome = json!({ "asked": asked, "changed": changed, "refreshed": refreshed });
            match answer {
                Ok(answer) => outcome["answers"] = answer,
                Err(error) => outcome["fails"] = json!(error.to_string()),
            }
            of_kind.insert(case.into(), outcome);
        }
        seen.insert(kind, Value::Object(of_kind));
    }
    let text = serde_json::to_string_pretty(&Value::Object(seen)).unwrap() + "\n";
    let path = format!(
        "{}/src/session/pins/commands.json",
        env!("CARGO_MANIFEST_DIR")
    );
    if std::env::var_os("UPDATE_FIXTURES").is_some() {
        std::fs::write(&path, &text).unwrap();
    }
    let pinned = std::fs::read_to_string(&path).unwrap_or_default();
    let _ = std::fs::remove_dir_all(rig.app.store.dir());
    assert!(
        pinned == text,
        "commands no longer do as pinned, from {}. UPDATE_FIXTURES=1 cargo test rewrites {path}.",
        first_difference(&pinned, &text)
    );
}

/// What an agent that starts well answers while the bridge reads it for the first time.
fn starting_answers() -> HashMap<String, Value> {
    serde_json::from_value(json!({
        "get_state": { "model": { "provider": "example", "id": "model-1", "name": "Model One" },
            "thinkingLevel": "high", "sessionFile": "/work/sessions/pi1.jsonl" },
        "get_session_stats": { "cost": 0.5 },
        "get_messages": { "messages": [] },
        "get_available_models": { "models": [] },
        "get_available_thinking_levels": { "levels": ["low", "high"] },
    }))
    .unwrap()
}

/// Two resumes of one stopped session, close together, start one agent, and both are told it runs.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn two_resumes_start_one_agent() {
    let rig = Rig::new("resume-twice", &[("sessions.json", SAVED_SESSIONS)]);
    *rig.agents.answers.lock().unwrap() = starting_answers();
    let release = rig.hold_starts();
    let pi = rig.app.find("pi1").await.unwrap();
    let first = {
        let (app, pi) = (rig.app.clone(), pi.clone());
        tokio::spawn(async move { app.resume_session(&pi).await.map(|summary| summary.id) })
    };
    rig.a_start_waits().await;
    // The first is still starting its agent: the second is told the session is on its way.
    assert_eq!(rig.app.resume_session(&pi).await.unwrap().id, "pi1");
    release.send(()).unwrap();
    assert_eq!(first.await.unwrap().unwrap(), "pi1");
    assert_eq!(rig.agents.starts.load(Ordering::SeqCst), 1);
    // And once it runs, a repeated resume is still a success.
    assert_eq!(rig.app.resume_session(&pi).await.unwrap().id, "pi1");
    assert_eq!(rig.agents.starts.load(Ordering::SeqCst), 1);
    let _ = std::fs::remove_dir_all(rig.app.store.dir());
}

/// A resume whose agent starts and then cannot be read leaves no agent running, and the session can be resumed again.
#[tokio::test]
async fn a_resume_that_fails_halfway_closes_its_agent() {
    let rig = Rig::new("resume-fails", &[("sessions.json", SAVED_SESSIONS)]);
    let pi = rig.app.find("pi1").await.unwrap();
    // Nothing is scripted: the agent starts, and answers nothing.
    let failed = rig.app.resume_session(&pi).await;
    assert_eq!(failed.unwrap_err().to_string(), "agent is not running");
    assert_eq!(rig.agents.closes.load(Ordering::SeqCst), 1);
    {
        let st = pi.state.lock().await;
        assert!(st.stopped());
        assert_eq!(st.summary.status, SessionStatus::Error);
    }
    *rig.agents.answers.lock().unwrap() = starting_answers();
    assert_eq!(rig.app.resume_session(&pi).await.unwrap().id, "pi1");
    assert_eq!(rig.agents.starts.load(Ordering::SeqCst), 2);
    let _ = std::fs::remove_dir_all(rig.app.store.dir());
}

/// A new session whose agent starts and then cannot be read is closed and is not kept: the error is the answer.
#[tokio::test]
async fn a_new_session_that_fails_halfway_is_not_kept() {
    let rig = Rig::new("create-fails", &[]);
    let cwd = rig.app.store.dir().to_string_lossy().into_owned();
    let failed = rig
        .app
        .create_session(AgentKind::Pi, cwd.clone(), None, None)
        .await;
    assert_eq!(failed.unwrap_err().to_string(), "agent is not running");
    assert_eq!(rig.agents.closes.load(Ordering::SeqCst), 1);
    assert!(rig.app.sessions.read().await.is_empty());
    // One that starts well is kept and saved.
    *rig.agents.answers.lock().unwrap() = starting_answers();
    let made = rig
        .app
        .create_session(AgentKind::Pi, cwd, None, None)
        .await
        .unwrap();
    assert_eq!(rig.app.sessions.read().await.len(), 1);
    // The save runs on its own after the answer: waited for until it is there, not for a fixed time.
    let saved = || rig.saved("sessions.json").to_string().contains(&made.id);
    for _ in 0..400 {
        if saved() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    assert!(saved());
    let _ = std::fs::remove_dir_all(rig.app.store.dir());
}

/// A message sent again under the same id, as an app does when the reply to the first was lost, reaches the agent
/// once. One the agent refused can be sent again, and messages with no id, or with different ones, all go.
#[tokio::test(start_paused = true)]
async fn a_message_sent_again_under_its_id_goes_once() {
    let rig = &Rig::new("send-once", &[]);
    rig.script("prompt", json!({}));
    let summary = rig.summary("s1", AgentKind::Pi, SessionKind::Root, "/work/project");
    let state = SessionState::new(summary, None, own(rig, "s1", Backend::Started, true));
    let session = &Arc::new(Session::new(
        "s1".into(),
        AgentKind::Pi,
        "/work/project".into(),
        state,
    ));
    let app = &rig.app;
    let prompts = || rig.agents.asked.lock().unwrap().len();
    let id = |id: &str| Some(id.to_string());

    app.send_text(session, "Carry on".into(), id("a"))
        .await
        .unwrap();
    app.send_text(session, "Carry on".into(), id("a"))
        .await
        .unwrap();
    assert_eq!(prompts(), 1);

    app.send_text(session, "Carry on".into(), id("b"))
        .await
        .unwrap();
    assert_eq!(prompts(), 2);
    app.send_text(session, "Carry on".into(), None)
        .await
        .unwrap();
    app.send_text(session, "Carry on".into(), None)
        .await
        .unwrap();
    assert_eq!(prompts(), 4);

    // The agent refuses one: nothing was sent, so the same id may try again.
    rig.agents
        .refusals
        .lock()
        .unwrap()
        .insert("prompt".into(), "no model is set".into());
    assert!(app
        .send_text(session, "Carry on".into(), id("c"))
        .await
        .is_err());
    rig.agents.refusals.lock().unwrap().clear();
    app.send_text(session, "Carry on".into(), id("c"))
        .await
        .unwrap();
    assert_eq!(prompts(), 6);
    let _ = std::fs::remove_dir_all(rig.app.store.dir());
}

/// A message sent again while its first copy is still with the agent waits for that copy: if the agent then refuses
/// it, the second one goes, and the message is not lost.
/// A turn the agent begins by itself while a refresh waits on its answer is newer than that answer: the session
/// stays running, not set back to the idle the agent said before the turn began.
#[tokio::test(start_paused = true)]
async fn a_turn_begun_while_a_refresh_waits_is_not_set_back_to_idle() {
    let rig = &Rig::new("refresh-overtaken", &[]);
    rig.script("get_state", json!({ "isStreaming": false }));
    rig.script("get_session_stats", json!({}));
    let summary = rig.summary("s1", AgentKind::Pi, SessionKind::Root, "/work/project");
    let state = SessionState::new(summary, None, own(rig, "s1", Backend::Started, true));
    let session = Arc::new(Session::new(
        "s1".into(),
        AgentKind::Pi,
        "/work/project".into(),
        state,
    ));
    *rig.agents.slow_answer.lock().unwrap() = Duration::from_secs(1);
    let refresh = {
        let (app, session) = (rig.app.clone(), session.clone());
        tokio::spawn(async move { app.refresh(&session).await.map_err(|e| e.to_string()) })
    };
    tokio::time::sleep(Duration::from_millis(100)).await;
    rig.app
        .handle_event(&session, &json!({ "type": "agent_start" }))
        .await;
    assert!(refresh.await.unwrap().is_ok());
    assert_eq!(
        session.state.lock().await.summary.status,
        SessionStatus::Running
    );
}

#[tokio::test(start_paused = true)]
async fn a_message_sent_again_while_the_first_is_out_waits_for_it() {
    let rig = &Rig::new("send-again-early", &[]);
    rig.script("prompt", json!({}));
    let summary = rig.summary("s1", AgentKind::Pi, SessionKind::Root, "/work/project");
    let state = SessionState::new(summary, None, own(rig, "s1", Backend::Started, true));
    let session = Arc::new(Session::new(
        "s1".into(),
        AgentKind::Pi,
        "/work/project".into(),
        state,
    ));
    *rig.agents.slow_answer.lock().unwrap() = Duration::from_secs(1);
    rig.agents
        .refusals
        .lock()
        .unwrap()
        .insert("prompt".into(), "no model is set".into());
    let send = || {
        let (app, session) = (rig.app.clone(), session.clone());
        tokio::spawn(async move {
            app.send_text(&session, "Carry on".into(), Some("a".into()))
                .await
                .map_err(|e| e.to_string())
        })
    };
    let first = send();
    tokio::time::sleep(Duration::from_millis(100)).await;
    // The agent would take it now, but the first copy is already on its way to a refusal.
    rig.agents.refusals.lock().unwrap().clear();
    let second = send();
    assert_eq!(first.await.unwrap(), Err("no model is set".to_string()));
    assert!(second.await.unwrap().is_ok());
    let prompts = rig
        .agents
        .asked
        .lock()
        .unwrap()
        .iter()
        .filter(|asked| asked["command"] == "prompt")
        .count();
    assert_eq!(prompts, 2);
    let _ = std::fs::remove_dir_all(rig.app.store.dir());
}

/// Once the agent has made the session, creating it has succeeded: failing to read its state then is not an error to
/// answer with, since trying again would make a second one.
#[tokio::test(start_paused = true)]
async fn a_session_its_agent_made_is_answered_even_if_reading_it_fails() {
    let rig = Rig::new("create-kept", &[]);
    *rig.agents.made.lock().unwrap() = Some(prime_row("p1", json!({})));
    let made = rig
        .app
        .create_session(AgentKind::Prime, "/tmp".into(), None, None)
        .await
        .unwrap();
    assert_eq!(made.id, "p1");
    assert_eq!(rig.app.sessions.read().await.len(), 1);
    let _ = std::fs::remove_dir_all(rig.app.store.dir());
}

/// A session deleted while its agent starts leaves no agent running.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_delete_during_a_start_leaves_no_agent() {
    let rig = Rig::new("delete-starting", &[("sessions.json", SAVED_SESSIONS)]);
    *rig.agents.answers.lock().unwrap() = starting_answers();
    let release = rig.hold_starts();
    let pi = rig.app.find("pi1").await.unwrap();
    let resume = {
        let (app, pi) = (rig.app.clone(), pi.clone());
        tokio::spawn(async move { app.resume_session(&pi).await.map_err(|e| e.to_string()) })
    };
    rig.a_start_waits().await;
    rig.app.delete_session(&pi).await.unwrap();
    release.send(()).unwrap();
    assert_eq!(
        resume.await.unwrap().unwrap_err(),
        "the session was closed while it started"
    );
    assert_eq!(rig.agents.closes.load(Ordering::SeqCst), 1);
    assert!(pi.state.lock().await.stopped());
    let _ = std::fs::remove_dir_all(rig.app.store.dir());
}

/// A session closed while its agent starts ends up stopped, not failed, and can be resumed.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_close_during_a_start_stops_the_session() {
    let rig = Rig::new("close-starting", &[("sessions.json", SAVED_SESSIONS)]);
    *rig.agents.answers.lock().unwrap() = starting_answers();
    let release = rig.hold_starts();
    let pi = rig.app.find("pi1").await.unwrap();
    let resume = {
        let (app, pi) = (rig.app.clone(), pi.clone());
        tokio::spawn(async move { app.resume_session(&pi).await.map_err(|e| e.to_string()) })
    };
    rig.a_start_waits().await;
    rig.app.close_session(&pi).await.unwrap();
    release.send(()).unwrap();
    assert!(resume.await.unwrap().is_err());
    assert_eq!(rig.agents.closes.load(Ordering::SeqCst), 1);
    {
        let st = pi.state.lock().await;
        assert!(st.stopped());
        assert_eq!(st.summary.status, SessionStatus::Stopped);
        assert_eq!(st.summary.error, None);
    }
    assert_eq!(rig.app.resume_session(&pi).await.unwrap().id, "pi1");
    assert_eq!(rig.agents.starts.load(Ordering::SeqCst), 2);
    let _ = std::fs::remove_dir_all(rig.app.store.dir());
}

/// A session closed while the bridge still reads its transcript from the agent it just started ends up stopped.
#[tokio::test(start_paused = true)]
async fn a_close_while_a_start_reads_the_transcript_stops_the_session() {
    let rig = Rig::new("close-reading", &[("sessions.json", SAVED_SESSIONS)]);
    *rig.agents.answers.lock().unwrap() = starting_answers();
    *rig.agents.slow_answer.lock().unwrap() = Duration::from_secs(1);
    let pi = rig.app.find("pi1").await.unwrap();
    let resume = {
        let (app, pi) = (rig.app.clone(), pi.clone());
        tokio::spawn(async move { app.resume_session(&pi).await.map_err(|e| e.to_string()) })
    };
    tokio::time::sleep(Duration::from_millis(100)).await;
    rig.app.close_session(&pi).await.unwrap();
    assert!(resume.await.unwrap().is_err());
    let st = pi.state.lock().await;
    assert!(st.stopped());
    assert_eq!(st.summary.status, SessionStatus::Stopped);
    assert_eq!(st.summary.error, None);
    drop(st);
    let _ = std::fs::remove_dir_all(rig.app.store.dir());
}

/// Closing a running session leaves it stopped, and it can be resumed at once.
#[tokio::test]
async fn a_closed_session_is_stopped_and_resumes() {
    let rig = Rig::new("close-resume", &[("sessions.json", SAVED_SESSIONS)]);
    *rig.agents.answers.lock().unwrap() = starting_answers();
    let pi = rig.app.find("pi1").await.unwrap();
    rig.app.resume_session(&pi).await.unwrap();
    rig.app.close_session(&pi).await.unwrap();
    assert_eq!(pi.state.lock().await.summary.status, SessionStatus::Stopped);
    rig.app.resume_session(&pi).await.unwrap();
    assert_eq!(rig.agents.starts.load(Ordering::SeqCst), 2);
    let _ = std::fs::remove_dir_all(rig.app.store.dir());
}

/// A second close while the first still waits for its agent leaves the session stopping, so a resume cannot start
/// a second agent on the same session file.
#[tokio::test]
async fn a_second_close_does_not_stop_the_session_before_its_agent_is_gone() {
    let rig = Rig::new("close-twice", &[("sessions.json", SAVED_SESSIONS)]);
    *rig.agents.answers.lock().unwrap() = starting_answers();
    let pi = rig.app.find("pi1").await.unwrap();
    rig.app.resume_session(&pi).await.unwrap();
    let (release, gate) = tokio::sync::oneshot::channel();
    *rig.agents.close_gate.lock().unwrap() = Some(gate);
    let first = {
        let (app, pi) = (rig.app.clone(), pi.clone());
        tokio::spawn(async move { app.close_session(&pi).await.map_err(|e| e.to_string()) })
    };
    while rig.agents.closes.load(Ordering::SeqCst) == 0 {
        tokio::task::yield_now().await;
    }
    rig.app.close_session(&pi).await.unwrap();
    assert_eq!(rig.agents.closes.load(Ordering::SeqCst), 1);
    assert_ne!(pi.state.lock().await.summary.status, SessionStatus::Stopped);
    assert!(rig.app.resume_session(&pi).await.is_err());
    assert_eq!(rig.agents.starts.load(Ordering::SeqCst), 1);
    release.send(()).unwrap();
    first.await.unwrap().unwrap();
    assert_eq!(pi.state.lock().await.summary.status, SessionStatus::Stopped);
    let _ = std::fs::remove_dir_all(rig.app.store.dir());
}

/// A stopped session shows nothing of its last run at work: no queue, no subagents running.
#[tokio::test]
async fn a_closed_session_keeps_nothing_of_its_agent_at_work() {
    let rig = Rig::new("close-forgets", &[("sessions.json", SAVED_SESSIONS)]);
    *rig.agents.answers.lock().unwrap() = starting_answers();
    let pi = rig.app.find("pi1").await.unwrap();
    rig.app.resume_session(&pi).await.unwrap();
    let running =
        json!({ "agent": "reviewer", "task": "Review the change", "exitCode": -1, "messages": [] });
    for event in [
        json!({ "type": "queue_update", "steering": ["and then this"], "followUp": [] }),
        json!({ "type": "tool_execution_start", "toolCallId": "call_sub-agents.2", "toolName": "subagent", "args": {} }),
        json!({ "type": "tool_execution_update", "toolCallId": "call_sub-agents.2", "toolName": "subagent",
            "partialResult": { "details": subagent_results(false, running) } }),
    ] {
        rig.app.handle_event(&pi, &event).await;
    }
    let children = || async {
        let mut busy = 0;
        for s in rig.app.sessions.read().await.iter() {
            if s.id.starts_with("pi1.")
                && s.state.lock().await.summary.status == SessionStatus::Running
            {
                busy += 1;
            }
        }
        busy
    };
    {
        let st = pi.state.lock().await;
        assert!(st.summary.running_subagents);
        assert!(!st.summary.queue.steering.is_empty());
    }
    assert!(children().await > 0);
    rig.app.close_session(&pi).await.unwrap();
    {
        let st = pi.state.lock().await;
        assert!(!st.summary.running_subagents);
        assert!(st.summary.queue.steering.is_empty());
    }
    assert_eq!(children().await, 0);
    let _ = std::fs::remove_dir_all(rig.app.store.dir());
}

/// The background commands an agent reports itself end with it: a stopped DeepSeek session is not left at work.
#[tokio::test]
async fn a_closed_session_keeps_no_background_commands_its_agent_reported() {
    let rig = Rig::new("close-jobs", &[]);
    let summary = rig.summary(
        "d1",
        AgentKind::Deepseek,
        SessionKind::Root,
        "/work/project",
    );
    let state = SessionState::new(summary, None, own(&rig, "d1", Backend::Started, true));
    let dsh = rig
        .app
        .insert_once(Arc::new(Session::new(
            "d1".into(),
            AgentKind::Deepseek,
            "/work/project".into(),
            state,
        )))
        .await;
    rig.app
        .handle_event(&dsh, &json!({ "type": "dsh_jobs", "running": 1 }))
        .await;
    assert_eq!(dsh.state.lock().await.summary.background_jobs, 1);
    rig.app.close_session(&dsh).await.unwrap();
    assert_eq!(dsh.state.lock().await.summary.background_jobs, 0);
    let _ = std::fs::remove_dir_all(rig.app.store.dir());
}

/// A saved session of an agent that keeps its own is not one the bridge can start: taking it in would show a
/// session whose every command goes to whatever that agent has under the same id.
#[tokio::test]
async fn a_saved_session_of_an_agent_that_keeps_its_own_is_left_out() {
    let saved = r#"[
      { "id": "pi1", "agent": "pi", "cwd": "/work/project", "title": "project", "createdAt": 1700000000000, "sessionFile": null },
      { "id": "p1", "agent": "prime", "cwd": "/work/project", "title": "kept", "createdAt": 1700000001000, "sessionFile": null }
    ]"#;
    let rig = Rig::new("saved-kept", &[("sessions.json", saved)]);
    assert!(rig.app.find("pi1").await.is_ok());
    assert!(rig.app.find("p1").await.is_err());
    let _ = std::fs::remove_dir_all(rig.app.store.dir());
}

/// A client of the bridge with no socket: what it says goes to `server::serve`, and what it is sent is kept in
/// the order it came.
struct Client {
    says: mpsc::Sender<String>,
    hears: mpsc::UnboundedReceiver<Arc<str>>,
}

impl Client {
    /// Connected, and past the list of sessions every client is sent first.
    async fn connect(rig: &Rig) -> Client {
        let (says, incoming) = mpsc::channel(1);
        let (out, hears) = mpsc::unbounded_channel();
        tokio::spawn(crate::server::serve(rig.app.clone(), incoming, out));
        let mut client = Client { says, hears };
        assert_eq!(client.next().await["type"], "sessions");
        client
    }

    async fn say(&self, message: Value) {
        self.says.send(message.to_string()).await.unwrap();
    }

    async fn next(&mut self) -> Value {
        let text = tokio::time::timeout(Duration::from_secs(5), self.hears.recv())
            .await
            .expect("the bridge sends something")
            .unwrap();
        serde_json::from_str(&text).unwrap()
    }

    /// Everything sent up to the reply to `id`, that reply last.
    async fn until_reply(&mut self, id: &str) -> Vec<Value> {
        let mut sent = Vec::new();
        loop {
            let message = self.next().await;
            let done = message["type"] == "reply" && message["id"] == id;
            sent.push(message);
            if done {
                return sent;
            }
        }
    }
}

/// A session Prime's daemon keeps, as its roster would have brought it in, not attached.
async fn prime_session(rig: &Rig, id: &str, parent: Option<&str>) -> Arc<Session> {
    let kind = match parent {
        Some(_) => SessionKind::Subagent,
        None => SessionKind::Root,
    };
    let mut summary = rig.summary(id, AgentKind::Prime, kind, "/work/project");
    summary.parent_id = parent.map(str::to_string);
    let state = SessionState::new(summary, None, BackendState::prime());
    let session = Arc::new(Session::new(
        id.to_string(),
        AgentKind::Prime,
        "/work/project".into(),
        state,
    ));
    rig.app.sessions.write().await.push(session.clone());
    session
}

fn types(sent: &[Value]) -> Vec<&str> {
    sent.iter().map(|m| m["type"].as_str().unwrap()).collect()
}

/// An attach as an app relies on it: the session, then its transcript, then the answer, which is last. The session
/// may be sent more than once, as it changes while it attaches.
fn attached_in_order(sent: &[Value]) -> &Value {
    let types = types(sent);
    let snapshot = types
        .iter()
        .position(|t| *t == "snapshot")
        .expect("a snapshot");
    assert!(types[..snapshot].contains(&"session"), "{types:?}");
    assert_eq!(types.iter().filter(|t| **t == "snapshot").count(), 1);
    assert_eq!(sent.last().unwrap()["ok"], true);
    &sent[snapshot]
}

/// The order an app relies on: the session, its transcript, then the answer. What the session says after that
/// follows.
#[tokio::test]
async fn an_attach_sends_the_session_and_its_transcript_then_answers() {
    let rig = Rig::new("serve-attach", &[]);
    rig.script(
        "attach",
        json!({ "snapshot": { "messages": [{ "role": "user", "content": text("hello") }] } }),
    );
    prime_session(&rig, "p1", None).await;
    let mut client = Client::connect(&rig).await;
    client
        .say(json!({ "id": "a", "op": "attach", "sessionId": "p1" }))
        .await;
    let sent = client.until_reply("a").await;
    assert_eq!(attached_in_order(&sent)["items"][0]["text"], "hello");

    let said = DaemonEvent::SessionEvent {
        active_session_id: "p1".into(),
        event: json!({ "type": "message_end", "message": { "role": "user", "content": text("and again") } }),
    };
    rig.prime.send(said).ok().unwrap();
    loop {
        let message = client.next().await;
        if message["type"] == "item_add" {
            assert_eq!(message["item"]["text"], "and again");
            break;
        }
    }
    let _ = std::fs::remove_dir_all(rig.app.store.dir());
}

/// Prime's daemon may take two minutes over an attach. The client's other requests are answered meanwhile.
#[tokio::test(start_paused = true)]
async fn an_attach_that_waits_on_the_agent_does_not_hold_the_client() {
    let rig = Rig::new("serve-slow-attach", &[]);
    rig.script("attach", json!({ "snapshot": { "messages": [] } }));
    *rig.agents.slow_answer.lock().unwrap() = Duration::from_millis(500);
    prime_session(&rig, "p1", None).await;
    let mut client = Client::connect(&rig).await;
    client
        .say(json!({ "id": "a", "op": "attach", "sessionId": "p1" }))
        .await;
    client.say(json!({ "id": "b", "op": "ping" })).await;
    let first = client.next().await;
    assert_eq!(
        (first["type"].as_str(), first["id"].as_str()),
        (Some("reply"), Some("b"))
    );
    attached_in_order(&client.until_reply("a").await);
    let _ = std::fs::remove_dir_all(rig.app.store.dir());
}

/// A detach that overtakes its attach wins: the attach is answered, and no transcript is sent.
#[tokio::test(start_paused = true)]
async fn a_detach_during_an_attach_leaves_the_client_detached() {
    let rig = Rig::new("serve-detach", &[]);
    rig.script("attach", json!({ "snapshot": { "messages": [] } }));
    *rig.agents.slow_answer.lock().unwrap() = Duration::from_millis(300);
    prime_session(&rig, "p1", None).await;
    let mut client = Client::connect(&rig).await;
    client
        .say(json!({ "id": "a", "op": "attach", "sessionId": "p1" }))
        .await;
    client
        .say(json!({ "id": "d", "op": "detach", "sessionId": "p1" }))
        .await;
    assert_eq!(client.until_reply("d").await.last().unwrap()["ok"], true);
    let sent = client.until_reply("a").await;
    assert!(!types(&sent).contains(&"snapshot"), "{sent:?}");
    assert_eq!(sent.last().unwrap()["ok"], true);
    let _ = std::fs::remove_dir_all(rig.app.store.dir());
}

/// Attach, detach, attach again: the first attach, ending late, answers for itself only, and the second still
/// brings the transcript.
#[tokio::test(start_paused = true)]
async fn an_attach_called_off_and_made_again_is_not_spent_by_the_first() {
    let rig = Rig::new("serve-reattach", &[]);
    rig.script("attach", json!({ "snapshot": { "messages": [] } }));
    *rig.agents.slow_answer.lock().unwrap() = Duration::from_millis(300);
    prime_session(&rig, "p1", None).await;
    let mut client = Client::connect(&rig).await;
    for (id, op) in [("a", "attach"), ("d", "detach"), ("b", "attach")] {
        client
            .say(json!({ "id": id, "op": op, "sessionId": "p1" }))
            .await;
    }
    let first = client.until_reply("a").await;
    assert!(!types(&first).contains(&"snapshot"), "{first:?}");
    attached_in_order(&client.until_reply("b").await);
    let _ = std::fs::remove_dir_all(rig.app.store.dir());
}

/// The words are what apps from before the codes compare with, so both are answered and neither may change.
#[tokio::test]
async fn a_subagent_its_agent_let_go_of_is_answered_as_ended_and_removed() {
    let rig = Rig::new("serve-ended", &[]);
    rig.agents
        .refusals
        .lock()
        .unwrap()
        .insert("attach".into(), "no such session".into());
    prime_session(&rig, "p1", None).await;
    prime_session(&rig, "p1.child", Some("p1")).await;
    let mut client = Client::connect(&rig).await;
    client
        .say(json!({ "id": "a", "op": "attach", "sessionId": "p1.child" }))
        .await;
    let sent = client.until_reply("a").await;
    assert_eq!(
        sent.last().unwrap(),
        &json!({ "type": "reply", "id": "a", "ok": false, "error": "session ended", "code": "session_ended" })
    );
    assert!(rig.app.find("p1.child").await.is_err());

    // A root session the daemon refuses is no ended subagent: its own words, no code, and it stays.
    client
        .say(json!({ "id": "b", "op": "attach", "sessionId": "p1" }))
        .await;
    let sent = client.until_reply("b").await;
    assert_eq!(
        sent.last().unwrap(),
        &json!({ "type": "reply", "id": "b", "ok": false, "error": "no such session" })
    );
    assert!(rig.app.find("p1").await.is_ok());
    let _ = std::fs::remove_dir_all(rig.app.store.dir());
}

/// What the new-session sheet acts on: it forgets a folder that is gone. The system's words stay in the sentence
/// for apps from before the codes.
#[tokio::test]
async fn a_session_in_a_folder_that_is_gone_is_refused_with_its_code() {
    let rig = Rig::new("serve-no-folder", &[]);
    let mut client = Client::connect(&rig).await;
    let gone = rig.app.store.dir().join("gone");
    client
        .say(json!({ "id": "c", "op": "create_session", "agent": "pi", "cwd": gone }))
        .await;
    let sent = client.until_reply("c").await;
    let reply = sent.last().unwrap();
    assert_eq!(reply["code"], "no_such_directory");
    let error = reply["error"].as_str().unwrap();
    assert!(error.contains("No such file or directory"), "{error}");
    assert_eq!(rig.agents.starts.load(Ordering::SeqCst), 0);
    let _ = std::fs::remove_dir_all(rig.app.store.dir());
}

/// An app newer than the bridge asks for something the bridge has never heard of. It is told so under its id, in
/// the words the apps look for to say "update this computer's bridge".
#[tokio::test]
async fn an_operation_the_bridge_does_not_know_is_refused_under_its_id() {
    let rig = Rig::new("serve-unknown", &[]);
    let mut client = Client::connect(&rig).await;
    client
        .say(json!({ "id": "x", "op": "from_the_future" }))
        .await;
    let sent = client.until_reply("x").await;
    let reply = sent.last().unwrap();
    assert_eq!(reply["ok"], false);
    let error = reply["error"].as_str().unwrap();
    assert!(error.contains("unknown variant"), "{error}");
    let _ = std::fs::remove_dir_all(rig.app.store.dir());
}

/// Close and delete as a client asks for them, and a session that is no longer there is an error it is told.
#[tokio::test]
async fn a_client_closes_then_deletes_a_session() {
    let rig = Rig::new("serve-close-delete", &[("sessions.json", SAVED_SESSIONS)]);
    *rig.agents.answers.lock().unwrap() = starting_answers();
    let mut client = Client::connect(&rig).await;
    client
        .say(json!({ "id": "r", "op": "resume_session", "sessionId": "pi1" }))
        .await;
    assert_eq!(client.until_reply("r").await.last().unwrap()["ok"], true);

    client
        .say(json!({ "id": "c", "op": "close_session", "sessionId": "pi1" }))
        .await;
    assert_eq!(client.until_reply("c").await.last().unwrap()["ok"], true);
    assert_eq!(rig.agents.closes.load(Ordering::SeqCst), 1);
    client
        .say(json!({ "id": "l", "op": "list_sessions" }))
        .await;
    let listed = client.until_reply("l").await;
    let sessions = listed.last().unwrap()["data"].as_array().unwrap();
    let pi1 = sessions.iter().find(|s| s["id"] == "pi1").unwrap();
    assert_eq!(pi1["status"], "stopped");

    client
        .say(json!({ "id": "d", "op": "delete_session", "sessionId": "pi1" }))
        .await;
    assert_eq!(client.until_reply("d").await.last().unwrap()["ok"], true);
    assert!(rig.app.find("pi1").await.is_err());

    client
        .say(json!({ "id": "e", "op": "close_session", "sessionId": "pi1" }))
        .await;
    let sent = client.until_reply("e").await;
    let reply = sent.last().unwrap();
    assert_eq!(
        (reply["ok"].as_bool(), reply["error"].as_str()),
        (Some(false), Some("unknown session pi1"))
    );
    let _ = std::fs::remove_dir_all(rig.app.store.dir());
}

/// What an agent has no command for is refused before reaching the agent.
#[tokio::test]
async fn commands_an_agent_lacks_are_refused_without_asking_it() {
    let rig = Rig::new("serve-unsupported", &[]);
    for (id, agent, backend) in [
        ("pi1", AgentKind::Pi, Backend::Started),
        ("dsh1", AgentKind::Deepseek, Backend::Started),
        ("p1", AgentKind::Prime, Backend::Prime),
    ] {
        let summary = rig.summary(id, agent, SessionKind::Root, "/work/project");
        let state = SessionState::new(summary, None, own(&rig, id, backend, true));
        let session = Arc::new(Session::new(
            id.into(),
            agent,
            "/work/project".into(),
            state,
        ));
        rig.app.sessions.write().await.push(session);
    }
    let mut client = Client::connect(&rig).await;
    for (req, msg) in [
        (
            "q-pi",
            json!({ "id": "q-pi", "op": "answer_question", "sessionId": "pi1", "questionId": "q1", "answers": [] }),
        ),
        (
            "q-prime",
            json!({ "id": "q-prime", "op": "answer_question", "sessionId": "p1", "questionId": "q1", "answers": [] }),
        ),
        (
            "ac-dsh",
            json!({ "id": "ac-dsh", "op": "set_auto_compaction", "sessionId": "dsh1", "enabled": false }),
        ),
        (
            "ns-dsh",
            json!({ "id": "ns-dsh", "op": "new_session", "sessionId": "dsh1" }),
        ),
    ] {
        client.say(msg).await;
        let sent = client.until_reply(req).await;
        assert_eq!(sent.last().unwrap()["ok"], false, "{req}: {sent:?}");
    }
    assert!(rig.agents.asked.lock().unwrap().is_empty());
    let _ = std::fs::remove_dir_all(rig.app.store.dir());
}

/// DeepSeek Harness reports its subagents through `dsh_subagent`, so its `subagent` tool call does not also flip
/// Pi's subagent flag on the parent.
#[tokio::test]
async fn a_subagent_tool_call_on_deepseek_waits_for_its_own_subagent_events() {
    let rig = Rig::new("dsh-subagent-tool", &[]);
    let summary = rig.summary(
        "dsh1",
        AgentKind::Deepseek,
        SessionKind::Root,
        "/work/project",
    );
    let state = SessionState::new(summary, None, own(&rig, "dsh1", Backend::Started, true));
    let session = Arc::new(Session::new(
        "dsh1".into(),
        AgentKind::Deepseek,
        "/work/project".into(),
        state,
    ));
    rig.app.sessions.write().await.push(session.clone());
    rig.app
        .handle_event(
            &session,
            &json!({
                "type": "tool_execution_start",
                "toolCallId": "call_1",
                "toolName": "subagent",
                "args": { "prompt": "read the file" },
            }),
        )
        .await;
    assert!(!session.state.lock().await.summary.running_subagents);
    let _ = std::fs::remove_dir_all(rig.app.store.dir());
}

/// Clients learn what each session supports from `capabilities` on its summary rather than switching on agent names.
#[tokio::test]
async fn sessions_publish_their_capabilities_on_the_wire() {
    let rig = Rig::new("serve-capabilities", &[("sessions.json", SAVED_SESSIONS)]);
    prime_session(&rig, "p1", None).await;
    let mut client = Client::connect(&rig).await;
    client
        .say(json!({ "id": "l", "op": "list_sessions" }))
        .await;
    let listed = client.until_reply("l").await;
    let sessions = listed.last().unwrap()["data"].as_array().unwrap();
    let caps = |id: &str| sessions.iter().find(|s| s["id"] == id).unwrap()["capabilities"].clone();
    assert_eq!(
        caps("pi1"),
        json!({
            "resume": true,
            "restartKernel": false,
            "clearGoal": false,
            "newSession": true,
            "autoCompactionSwitch": true,
            "followUp": true,
            "answer": false,
            "backgroundCommands": true,
            "spendIncludesSubagents": false,
        })
    );
    assert_eq!(
        caps("dsh1"),
        json!({
            "resume": true,
            "restartKernel": false,
            "clearGoal": false,
            "newSession": false,
            "autoCompactionSwitch": false,
            "followUp": true,
            "answer": true,
            "backgroundCommands": true,
            "spendIncludesSubagents": false,
        })
    );
    assert_eq!(
        caps("p1"),
        json!({
            "resume": false,
            "restartKernel": true,
            "clearGoal": true,
            "newSession": true,
            "autoCompactionSwitch": true,
            "followUp": true,
            "answer": false,
            "backgroundCommands": true,
            "spendIncludesSubagents": true,
        })
    );
    let _ = std::fs::remove_dir_all(rig.app.store.dir());
}

/// DeepSeek sessions in the test rig run through the real `Dsh` driver over in-memory plugin pipes, not Pi's
/// `ScriptedSession`.
#[tokio::test(start_paused = true)]
async fn a_deepseek_session_runs_through_the_dsh_driver() {
    let rig = Rig::new("dsh-real-driver", &[]);
    let cwd = rig.app.store.dir().to_string_lossy().into_owned();
    let summary = rig
        .app
        .create_session(
            AgentKind::Deepseek,
            cwd,
            Some("example/model-1".into()),
            Some("medium".into()),
        )
        .await
        .unwrap();
    assert_eq!(summary.thinking_level.as_deref(), Some("high"));
    let session = rig.app.find(&summary.id).await.unwrap();
    rig.agents.asked.lock().unwrap().clear();
    rig.app.compact(&session, None).await.unwrap();
    let asked = rig.agents.asked.lock().unwrap().clone();
    assert_eq!(
        asked,
        vec![json!({
            "session": summary.id,
            "command": "command",
            "fields": { "line": "/compact" },
        })]
    );
    let _ = std::fs::remove_dir_all(rig.app.store.dir());
}

/// Pi's background-jobs records in the shared fixture are listed, tailed, marked lost when their process is gone,
/// and cancelled through `App`.
#[tokio::test]
async fn pi_jobs_are_listed_tailed_lost_and_cancelled_from_the_store() {
    use std::os::unix::process::CommandExt;

    let fixture: Value =
        serde_json::from_str(include_str!("../../../protocol/pi_job.json")).unwrap();
    let rig = Rig::new("pi-jobs", &[("sessions.json", SAVED_SESSIONS)]);
    let pi1 = rig.app.find("pi1").await.unwrap();
    let dir = crate::jobs::pi_dir(&rig.app.store, "pi1");
    std::fs::create_dir_all(&dir).unwrap();

    // 1. Finished record straight from the shared extension fixture.
    let finished = &fixture["finished"];
    let finished_id = finished["id"].as_str().unwrap();
    std::fs::write(
        dir.join(format!("{finished_id}.json")),
        serde_json::to_vec(finished).unwrap(),
    )
    .unwrap();
    std::fs::write(
        dir.join(format!("{finished_id}.log")),
        "line 1\nline 2\nall green\n",
    )
    .unwrap();

    // 2. Running record from the shared fixture, backed by a real process in its own process group so kill_job stops it.
    let mut sleeper = std::process::Command::new("/bin/sleep")
        .arg("30")
        .process_group(0)
        .spawn()
        .unwrap();
    let live_pid = sleeper.id();
    let mut live_record = fixture["running"].clone();
    live_record["id"] = json!("live1");
    live_record["pid"] = json!(live_pid);
    live_record["startedAt"] = json!("2026-11-11T10:05:00.000Z");
    std::fs::write(
        dir.join("live1.json"),
        serde_json::to_vec(&live_record).unwrap(),
    )
    .unwrap();

    // 3. Running record whose process has already exited: marked lost, and stays lost even if its pid is reused.
    let mut exited = std::process::Command::new("/usr/bin/true").spawn().unwrap();
    let gone_pid = exited.id();
    let _ = exited.wait();
    let mut lost_record = fixture["running"].clone();
    lost_record["id"] = json!("lost1");
    lost_record["pid"] = json!(gone_pid);
    lost_record["startedAt"] = json!("2026-11-11T10:02:00.000Z");
    std::fs::write(
        dir.join("lost1.json"),
        serde_json::to_vec(&lost_record).unwrap(),
    )
    .unwrap();

    let jobs = rig.app.list_jobs(&pi1).await.unwrap();
    let by_id: HashMap<&str, &crate::protocol::BackgroundJob> =
        jobs.iter().map(|j| (j.id.as_str(), j)).collect();
    assert_eq!(jobs.len(), 3);
    assert_eq!(by_id["live1"].status, crate::protocol::JobStatus::Running);
    assert_eq!(
        by_id[finished_id].status,
        crate::protocol::JobStatus::Finished
    );
    assert_eq!(by_id[finished_id].exit_code, Some(0));
    assert_eq!(by_id[finished_id].duration_ms, Some(1250));
    assert_eq!(by_id["lost1"].status, crate::protocol::JobStatus::Lost);
    assert!(dir.join("lost1.lost").exists());

    // Even if `lost1`'s pid is later reused by a live process, the `.lost` marker keeps it reported as Lost.
    lost_record["pid"] = json!(live_pid);
    std::fs::write(
        dir.join("lost1.json"),
        serde_json::to_vec(&lost_record).unwrap(),
    )
    .unwrap();
    let jobs_again = rig.app.list_jobs(&pi1).await.unwrap();
    assert_eq!(
        jobs_again.iter().find(|j| j.id == "lost1").unwrap().status,
        crate::protocol::JobStatus::Lost
    );

    let (running_count, waiting) = crate::jobs::pi_running(&rig.app.store, "pi1", None);
    assert_eq!(running_count, 1);
    assert_eq!(waiting.unwrap().command, "cargo test --locked");

    assert_eq!(
        rig.app.job_output(&pi1, finished_id, 2).await.unwrap(),
        "line 2\nall green"
    );
    assert!(rig.app.job_output(&pi1, "../etc", 10).await.is_err());

    assert!(!rig.app.kill_job(&pi1, finished_id).await.unwrap());
    assert!(rig.app.kill_job(&pi1, "live1").await.unwrap());
    let _ = sleeper.wait();

    rig.app.delete_session(&pi1).await.unwrap();
    assert!(!dir.exists());
    let _ = std::fs::remove_dir_all(rig.app.store.dir());
}

/// The `details` shape built by `setup/pi/extensions/subagent` in `protocol/pi_subagents.json` parses into read-only
/// child sessions with their model, cost, context tokens, transcript and error.
#[tokio::test]
async fn pi_subagents_fixture_from_the_extension_is_read() {
    let details: Value =
        serde_json::from_str(include_str!("../../../protocol/pi_subagents.json")).unwrap();
    let rig = Rig::new("pi-subagents-fixture", &[("sessions.json", SAVED_SESSIONS)]);
    let pi1 = rig.app.find("pi1").await.unwrap();
    pi1.state.lock().await.summary.context = Some(crate::protocol::ContextUsage {
        tokens: Some(4000),
        window: 200_000,
        percent: Some(2.0),
    });
    rig.app
        .handle_event(
            &pi1,
            &json!({
                "type": "tool_execution_end",
                "toolName": "subagent",
                "toolCallId": "call_fx",
                "result": { "details": details },
            }),
        )
        .await;

    let scout = rig.app.find("pi1.callfx.0").await.unwrap();
    let scout_st = scout.state.lock().await;
    assert_eq!(scout_st.summary.status, SessionStatus::Done);
    assert_eq!(scout_st.summary.title, "scout: Find the entry point");
    assert_eq!(scout_st.summary.cost, 0.25);
    assert_eq!(
        scout_st.summary.context.as_ref().and_then(|c| c.tokens),
        Some(1200)
    );
    assert_eq!(
        scout_st.summary.model.as_ref().map(|m| m.id.as_str()),
        Some("model-1")
    );
    assert_eq!(scout_st.transcript.items.len(), 2);
    drop(scout_st);

    let reviewer = rig.app.find("pi1.callfx.1").await.unwrap();
    let reviewer_st = reviewer.state.lock().await;
    assert_eq!(reviewer_st.summary.status, SessionStatus::Error);
    assert_eq!(
        reviewer_st.summary.error.as_deref(),
        Some("provider rate limit")
    );
    drop(reviewer_st);
    let _ = std::fs::remove_dir_all(rig.app.store.dir());
}

/// Closing or retiring a Prime subagent also removes any nested subagents it spawned, so orphaned grandchildren
/// never stay listed as running; and `parse_iso_ms` handles non-ASCII fractions, RFC 3339 offsets, and pre-1970 dates.
#[tokio::test(start_paused = true)]
async fn closing_a_prime_session_removes_its_descendant_subagents_and_parses_rfc3339() {
    assert_eq!(parse_iso_ms("2026-10-30T09:49:57.12µs"), None);
    assert_eq!(parse_iso_ms("1969-12-31T23:59:59Z"), None);
    assert_eq!(
        parse_iso_ms("2026-10-30T09:49:57.304-07:00"),
        parse_iso_ms("2026-10-30T16:49:57.304Z")
    );
    assert_eq!(
        parse_iso_ms("2026-10-30T09:49:57+00:00"),
        Some(1_793_353_797_000)
    );

    let rig = Rig::new("prime-orphan-grandchildren", &[]);
    prime_session(&rig, "root", None).await;
    prime_session(&rig, "review5", Some("root")).await;
    let grandchild = prime_session(&rig, "rust-features-review", Some("review5")).await;
    grandchild.state.lock().await.summary.status = SessionStatus::Running;

    rig.prime
        .send(DaemonEvent::SessionClosed("review5".into()))
        .ok()
        .unwrap();
    tokio::task::yield_now().await;
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert!(rig.app.find("review5").await.is_err());
    assert!(
        rig.app.find("rust-features-review").await.is_err(),
        "orphaned grandchild subagent stayed in app.sessions"
    );

    // Outer `agentId` on an inactive roster entry removes a subagent whose summary lost its sessionFile/sessionId.
    let sub2 = KeptRow::read_entry(&json!({
        "agentId": "durable-sub-2",
        "status": "active",
        "summary": { "activeSessionId": "sub2-live", "runtimeKind": "subagent", "parentActiveSessionId": "root", "cwd": "/work" }
    }))
    .unwrap();
    rig.prime
        .send(DaemonEvent::RosterUpdate(vec![sub2]))
        .ok()
        .unwrap();
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert!(rig.app.find("sub2-live").await.is_ok());
    let inactive = crate::agent_wire::InactiveRow::read(&json!({
        "agentId": "durable-sub-2",
        "status": "inactive",
        "summary": {}
    }))
    .unwrap();
    rig.prime
        .send(DaemonEvent::Inactive(inactive))
        .ok()
        .unwrap();
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert!(rig.app.find("sub2-live").await.is_err());

    // Disconnecting clears `attached` while preserving `wanted`, so attach fails while disconnected and retries if the
    // first reconnect's attach transiently fails.
    let root = rig.app.find("root").await.unwrap();
    rig.script(
        "attach",
        json!({ "messages": [{ "role": "user", "content": "hi" }] }),
    );
    rig.app.ensure_attached(&root).await.unwrap();
    assert!(root.state.lock().await.prime().unwrap().attached);

    rig.prime
        .send(DaemonEvent::Disconnected("socket reset".into()))
        .ok()
        .unwrap();
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert!(!root.state.lock().await.prime().unwrap().attached);
    assert!(root.state.lock().await.prime().unwrap().wanted);

    // First Roster reconnect: attach fails transiently (`SessionRecovering`), leaving `wanted == true && !attached`.
    rig.agents
        .refusals
        .lock()
        .unwrap()
        .insert("attach".into(), "session recovering".into());
    let root_row = || {
        KeptRow::read(&json!({ "activeSessionId": "root", "sessionId": "s-root", "cwd": "/work" }))
            .unwrap()
    };
    rig.prime
        .send(DaemonEvent::Roster(vec![root_row()]))
        .ok()
        .unwrap();
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert!(!root.state.lock().await.prime().unwrap().attached);
    assert!(root.state.lock().await.prime().unwrap().wanted);

    // Next Roster tick: attach succeeds and restores `attached == true`.
    rig.agents.refusals.lock().unwrap().remove("attach");
    rig.script(
        "attach",
        json!({ "messages": [{ "role": "user", "content": "back" }] }),
    );
    rig.prime
        .send(DaemonEvent::Roster(vec![root_row()]))
        .ok()
        .unwrap();
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert!(root.state.lock().await.prime().unwrap().attached);

    let _ = std::fs::remove_dir_all(rig.app.store.dir());
}
