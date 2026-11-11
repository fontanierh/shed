//! Translates DeepSeek Harness's forwarded session, stream, status and question frames into the normalized Pi event
//! shapes read by `agent_wire` and `transcript`.

use std::collections::{HashMap, VecDeque};
use std::time::Instant;

use serde_json::{json, Value};

use crate::host::now_ms;

// ---- dsh's feed as Pi events ----

/// What the feed has told about the session and its subagents.
#[derive(Default)]
pub(super) struct Feed {
    pub(super) root: String,
    pub(super) name: Option<String>,
    pub(super) model: Option<Value>,
    pub(super) reasoning: Value,
    pub(super) models: Vec<Value>,
    pub(super) window: Option<u64>,
    pub(super) tokens: Option<u64>,
    /// A turn is under way: what's sent now waits in dsh's inbox.
    pub(super) running: bool,
    /// Sent while running and not yet taken into a turn: message id, text, steering.
    pub(super) queue: VecDeque<(String, String, bool)>,
    /// Every session in the process, the root included, by dsh id.
    pub(super) sessions: HashMap<String, Conversation>,
    /// Background commands by id: running or not.
    pub(super) jobs: HashMap<String, bool>,
    /// Subagent names, from the parent's catalog.
    pub(super) labels: HashMap<String, String>,
    /// Compactions of the root that have ended.
    pub(super) compactions: u64,
    /// What the agent asks the user: its tool call's id, dsh's questions, and whether the agent carried on without
    /// the answer (it still takes it).
    pub(super) question: Option<Value>,
}

#[derive(Default)]
pub(super) struct Conversation {
    parent: Option<String>,
    /// Pi's message format: what `get_messages` returns.
    messages: Vec<Value>,
    /// Running tool calls: name and start, for the end event.
    tools: HashMap<String, (String, Instant)>,
    /// Stream blocks open in the current reply: index → kind (text, thinking, toolcall).
    blocks: HashMap<i64, &'static str>,
    status: &'static str,
    error: Option<String>,
    model: Option<String>,
    /// Its first and latest event (epoch ms).
    started: Option<u64>,
    active: Option<u64>,
}

impl Feed {
    pub(super) fn describe(&mut self, state: &Value) {
        if state["model"].is_object() {
            self.model = Some(state["model"].clone());
        }
        self.reasoning = state["reasoning"].clone();
        if let Some(window) = state["contextWindow"].as_u64() {
            self.window = Some(window);
        }
    }

    pub(super) fn root_messages(&self) -> Vec<Value> {
        self.sessions
            .get(&self.root)
            .map(|c| c.messages.clone())
            .unwrap_or_default()
    }

    pub(super) fn efforts(&self) -> Vec<String> {
        self.reasoning["efforts"]
            .as_array()
            .map(|e| {
                e.iter()
                    .filter_map(|e| e["id"].as_str().map(str::to_string))
                    .collect()
            })
            .unwrap_or_default()
    }

    pub(super) fn pi_models(&self) -> Vec<Value> {
        let reasoning = self.reasoning.is_object();
        self.models
            .iter()
            .map(|m| json!({ "provider": m["provider"], "id": m["id"], "name": m["name"], "reasoning": reasoning }))
            .collect()
    }

    pub(super) fn pi_state(&self, session: &str) -> Value {
        let model = self.model.as_ref().map(|m| {
            let id = m["model"].as_str().unwrap_or("");
            let name = self
                .models
                .iter()
                .find(|c| c["provider"] == m["provider"] && c["id"] == id)
                .and_then(|c| c["name"].as_str())
                .unwrap_or(id);
            json!({
                "provider": m["provider"],
                "id": id,
                "name": name,
                "contextWindow": self.window,
                "reasoning": self.reasoning.is_object(),
            })
        });
        let effort = self
            .model
            .as_ref()
            .and_then(|m| m["reasoningEffort"].as_str());
        let queued = |steer: bool| -> Vec<Value> {
            self.queue
                .iter()
                .filter(|q| q.2 == steer)
                .map(|q| json!({ "text": q.1 }))
                .collect()
        };
        json!({
            "model": model,
            "thinkingLevel": effort,
            "isStreaming": self.running,
            "sessionFile": session,
            "sessionId": session,
            "sessionName": self.name,
            "autoCompactionEnabled": true,
            "sessionActions": { "steering": queued(true), "followUps": queued(false) },
        })
    }

    /// A resumed session's history: rebuilt from its durable events, without the live events they'd make.
    pub(super) fn replay(&mut self, events: &[Value]) {
        let root = self.root.clone();
        for event in events {
            self.session_event(&root, None, event);
        }
        self.running = false;
        if let Some(c) = self.sessions.get_mut(&root) {
            c.tools.clear();
            c.blocks.clear();
        }
    }

    /// A subagent of a resumed session, from its durable events. Nothing under a resumed session is still running.
    pub(super) fn replay_subagent(&mut self, id: &str, parent: Option<String>, events: &[Value]) {
        for event in events {
            self.session_event(id, parent.clone(), event);
        }
        if let Some(c) = self.sessions.get_mut(id) {
            c.tools.clear();
            c.blocks.clear();
            c.status = if c.error.is_some() { "error" } else { "done" };
        }
    }

    /// One line from the plugin as the Pi events it makes.
    pub(super) fn receive(&mut self, line: &Value) -> Vec<Value> {
        let id = line["sessionId"].as_str().unwrap_or("").to_string();
        match line["event"].as_str().unwrap_or("") {
            "session" => {
                let parent = line["parent"].as_str().map(str::to_string);
                let mut events = self.session_event(&id, parent, &line["data"]);
                if id != self.root && self.sessions.contains_key(&id) {
                    if committed(&line["data"]) {
                        events.push(self.subagent(&id));
                    }
                    return events;
                }
                events
            }
            "stream" if id == self.root => self.stream(&line["frame"]),
            "status" if id == self.root => {
                if line["status"] == "idle" && !self.running {
                    vec![json!({ "type": "agent_settled" })]
                } else {
                    Vec::new()
                }
            }
            "status" => {
                let Some(c) = self.sessions.get_mut(&id) else {
                    return Vec::new();
                };
                c.status = if line["status"] == "running" {
                    "running"
                } else if c.status == "error" {
                    "error"
                } else {
                    "done"
                };
                vec![self.subagent(&id)]
            }
            "subagent_end" => {
                let Some(c) = self.sessions.get_mut(&id) else {
                    return Vec::new();
                };
                let reason = line["stopReason"].as_str().unwrap_or("completed");
                if reason == "completed" {
                    c.status = "done";
                } else {
                    c.status = "error";
                    c.error = Some(format!("Stopped: {reason}"));
                }
                vec![self.subagent(&id)]
            }
            // The questions dsh holds open, oldest first: Shed asks the first.
            "questions" => {
                let first = line["active"].as_array().and_then(|a| a.first()).map(|q| {
                    json!({
                        "id": q["callId"],
                        "questions": q["questions"],
                        "continued": q["state"] == "continued",
                    })
                });
                if first == self.question {
                    return Vec::new();
                }
                self.question = first;
                vec![json!({ "type": "dsh_question", "question": self.question })]
            }
            "error" if id == self.root => {
                let text = line["message"]
                    .as_str()
                    .unwrap_or("DeepSeek Harness failed");
                vec![json!({ "type": "message_end", "message": {
                    "role": "assistant", "content": [], "stopReason": "error",
                    "errorMessage": text, "timestamp": now_ms(),
                } })]
            }
            _ => Vec::new(),
        }
    }

    /// One durable session event. For the root it makes Pi events; for a subagent it only records the conversation.
    fn session_event(&mut self, id: &str, parent: Option<String>, event: &Value) -> Vec<Value> {
        let root = id == self.root;
        let data = &event["data"];
        let kind = event["type"].as_str().unwrap_or("");
        let c = self
            .sessions
            .entry(id.to_string())
            .or_insert_with(|| Conversation {
                parent: parent.clone(),
                status: "running",
                ..Default::default()
            });
        let time = event["time"].as_u64();
        if let Some(time) = time {
            c.started.get_or_insert(time);
            c.active = Some(time);
        }
        // Messages read back keep the time they were written.
        let stamp = |mut message: Value| {
            if let Some(time) = time {
                message["timestamp"] = json!(time);
            }
            message
        };
        let mut out = Vec::new();
        match kind {
            "turn/start" if root => {
                self.running = true;
                out.push(json!({ "type": "agent_start" }));
            }
            "turn/end" if root => {
                self.running = false;
                c.tools.clear();
                c.blocks.clear();
                out.push(json!({ "type": "turn_end" }));
                out.push(json!({ "type": "agent_end" }));
            }
            "user/message" => {
                if let Some(message) = user_message(data).map(stamp) {
                    c.messages.push(message.clone());
                    // A compaction's summary shows when the session reads its history back afterwards.
                    if root && message["role"] == "user" {
                        let id = data["id"].as_str().unwrap_or("");
                        self.queue.retain(|q| q.0 != id);
                        out.push(json!({ "type": "message_start", "message": message }));
                        out.push(json!({ "type": "message_end", "message": message }));
                    }
                }
            }
            "assistant/message" => {
                let message = stamp(assistant_message(&data["message"], finish(data)));
                c.messages.push(message.clone());
                c.blocks.clear();
                if root {
                    out.push(json!({ "type": "message_end", "message": message }));
                }
            }
            "agent/request-error" => {
                let text = data["error"]["message"]
                    .as_str()
                    .or(data["message"].as_str())
                    .map(str::to_string)
                    .unwrap_or_else(|| data["error"].to_string());
                c.blocks.clear();
                if root {
                    out.push(json!({ "type": "message_end", "message": {
                        "role": "assistant", "content": [], "stopReason": "error",
                        "errorMessage": text, "timestamp": now_ms(),
                    } }));
                } else {
                    c.error = Some(text);
                }
            }
            "tool/call" => {
                let call = data["callId"].as_str().unwrap_or("").to_string();
                let name = data["name"].as_str().unwrap_or("tool").to_string();
                c.tools.insert(call.clone(), (name.clone(), Instant::now()));
                if root {
                    out.push(json!({
                        "type": "tool_execution_start",
                        "toolCallId": call,
                        "toolName": name,
                        "args": arguments(&data["arguments"]),
                    }));
                }
            }
            "tool/result" => {
                let message = &data["message"];
                let call = message["toolCallId"].as_str().unwrap_or("").to_string();
                let (name, started) = c
                    .tools
                    .remove(&call)
                    .unwrap_or_else(|| (tool_name(&c.messages, &call), Instant::now()));
                let content = tool_content(&message["content"]);
                let failed = message["isError"] == true;
                let result = json!({
                    "role": "toolResult",
                    "toolCallId": call,
                    "toolName": name,
                    "content": content,
                    "isError": failed,
                    "timestamp": event["time"],
                });
                c.messages.push(result);
                if root {
                    out.push(json!({
                        "type": "tool_execution_end",
                        "toolCallId": call,
                        "toolName": name,
                        "result": { "content": content },
                        "isError": failed,
                        "durationMs": started.elapsed().as_millis() as u64,
                    }));
                }
            }
            // The summary the compaction writes shows once the session reads its history back, at the end.
            "compaction/start" if root => {
                let reason = if data["sourceCommandId"].is_string() {
                    "manual"
                } else {
                    "threshold"
                };
                out.push(json!({ "type": "compaction_start", "reason": reason }));
            }
            "compaction/end" if root => {
                self.compactions += 1;
                out.push(match data["error"].as_str() {
                    Some(error) => json!({ "type": "compaction_end", "errorMessage": error }),
                    None => json!({ "type": "compaction_end" }),
                });
            }
            "request/context" => {
                if root {
                    self.window = data["contextWindow"].as_u64().or(self.window);
                } else if let Some(model) = data["model"].as_str() {
                    c.model = Some(format!(
                        "{}/{model}",
                        data["provider"].as_str().unwrap_or("")
                    ));
                }
            }
            "subagent/catalog" => {
                if let (Some(child), Some(label)) =
                    (data["childId"].as_str(), data["label"].as_str())
                {
                    self.labels.insert(child.to_string(), label.to_string());
                }
            }
            "job/registered" | "job/settled" => {
                if let Some(job) = data["jobId"].as_str() {
                    self.jobs.insert(job.to_string(), kind == "job/registered");
                    let running = self.jobs.values().filter(|r| **r).count();
                    out.push(json!({ "type": "dsh_jobs", "running": running }));
                }
            }
            _ => {}
        }
        out
    }

    /// One live stream frame of the root's reply as Pi's `message_start` and `message_update` events.
    fn stream(&mut self, frame: &Value) -> Vec<Value> {
        let root = self.root.clone();
        let c = self.sessions.entry(root).or_default();
        let update = |kind: &str, index: i64, extra: Value| {
            let mut delta = json!({ "type": kind, "contentIndex": index });
            if let (Some(delta), Some(extra)) = (delta.as_object_mut(), extra.as_object()) {
                delta.extend(extra.clone());
            }
            json!({ "type": "message_update", "message": { "role": "assistant" }, "assistantMessageEvent": delta })
        };
        match frame["type"].as_str().unwrap_or("") {
            "start" => {
                c.blocks.clear();
                vec![
                    json!({ "type": "message_start", "message": { "role": "assistant", "content": [] } }),
                ]
            }
            "chunk" => {
                let chunk = &frame["chunk"];
                let index = chunk["index"].as_i64().unwrap_or(0);
                match chunk["type"].as_str().unwrap_or("") {
                    "block-start" => {
                        let kind = match chunk["blockType"].as_str() {
                            Some("reasoning") => "thinking",
                            Some("text") => "text",
                            // A tool call starts with its first delta, which names it.
                            _ => return Vec::new(),
                        };
                        c.blocks.insert(index, kind);
                        vec![update(&format!("{kind}_start"), index, json!({}))]
                    }
                    kind @ ("text-delta" | "reasoning-delta") => {
                        let block = if kind == "text-delta" {
                            "text"
                        } else {
                            "thinking"
                        };
                        let mut out = Vec::new();
                        if c.blocks.insert(index, block).is_none() {
                            out.push(update(&format!("{block}_start"), index, json!({})));
                        }
                        out.push(update(
                            &format!("{block}_delta"),
                            index,
                            json!({ "delta": chunk["text"] }),
                        ));
                        out
                    }
                    "tool-call-delta" => {
                        let mut out = Vec::new();
                        if c.blocks.insert(index, "toolcall").is_none() {
                            out.push(update(
                                "toolcall_start",
                                index,
                                json!({ "id": chunk["id"], "toolName": chunk["name"] }),
                            ));
                        }
                        if let Some(delta) =
                            chunk["argumentsDelta"].as_str().filter(|d| !d.is_empty())
                        {
                            out.push(update("toolcall_delta", index, json!({ "delta": delta })));
                        }
                        out
                    }
                    "block-end" => match c.blocks.get(&index) {
                        Some(kind) => vec![update(&format!("{kind}_end"), index, json!({}))],
                        None => Vec::new(),
                    },
                    "usage" => {
                        let usage = &chunk["usage"];
                        self.tokens = usage["totalTokens"].as_u64().or(self.tokens);
                        Vec::new()
                    }
                    _ => Vec::new(),
                }
            }
            _ => Vec::new(),
        }
    }

    /// A subagent's state and transcript, for the bridge to mirror as a read-only session.
    pub(super) fn subagent(&self, id: &str) -> Value {
        let c = &self.sessions[id];
        let parent = c.parent.clone().unwrap_or_else(|| self.root.clone());
        let title = self.labels.get(id).cloned().unwrap_or_else(|| {
            c.messages
                .iter()
                .find(|m| m["role"] == "user")
                .and_then(|m| m["content"][0]["text"].as_str())
                .unwrap_or("subagent")
                .to_string()
        });
        json!({
            "type": "dsh_subagent",
            "id": id,
            "parent": if parent == self.root { Value::Null } else { json!(parent) },
            "title": title,
            "status": c.status,
            "error": c.error,
            "model": c.model,
            "createdAt": c.started,
            "lastActiveAt": c.active,
            "messages": c.messages,
        })
    }
}

/// A durable event that changes what a subagent's transcript or state shows.
fn committed(event: &Value) -> bool {
    matches!(
        event["type"].as_str(),
        Some(
            "user/message"
                | "assistant/message"
                | "tool/call"
                | "tool/result"
                | "turn/end"
                | "agent/request-error"
        )
    )
}

/// A user-side message as Pi's, or none for dsh's own context (the runtime snapshot it gives the model each turn).
fn user_message(data: &Value) -> Option<Value> {
    let source = data["source"]["kind"].as_str().unwrap_or("user");
    if matches!(source, "runtime-context" | "system") {
        return None;
    }
    let content: Vec<Value> = data["content"]
        .as_array()?
        .iter()
        .filter_map(|block| match block["type"].as_str() {
            Some("text") => Some(json!({ "type": "text", "text": block["text"] })),
            Some("image") => Some(json!({ "type": "text", "text": "[image]" })),
            _ => None,
        })
        .collect();
    if content.is_empty() {
        return None;
    }
    // Compaction's summary of what it condensed: the transcript shows it as a compaction.
    if source == "compact-checkpoint" {
        let text: Vec<&str> = content.iter().filter_map(|b| b["text"].as_str()).collect();
        return Some(
            json!({ "role": "compactionSummary", "summary": text.join("\n"), "timestamp": now_ms() }),
        );
    }
    // A late answer to a question the agent stopped waiting on: what the user answered, as they'd have typed it.
    if source == "user-question-reply" {
        if let Some(text) = content[0]["text"].as_str().and_then(question_reply) {
            return Some(
                json!({ "role": "user", "content": [{ "type": "text", "text": text }], "timestamp": now_ms() }),
            );
        }
    }
    // What another agent sent, or a subagent's closing notice, reads as one message rather than separate lines.
    let content = if source == "user" {
        content
    } else {
        let text: Vec<&str> = content.iter().filter_map(|b| b["text"].as_str()).collect();
        vec![json!({ "type": "text", "text": text.join("\n") })]
    };
    Some(json!({ "role": "user", "content": content, "timestamp": now_ms() }))
}

/// The answers in dsh's reply to a pending question, one line each: "Which pet? A hamster", or "Skipped".
fn question_reply(text: &str) -> Option<String> {
    let reply: Value = serde_json::from_str(text).ok()?;
    let questions = reply["questions"].as_array()?;
    let lines: Vec<String> = reply["answers"]
        .as_array()?
        .iter()
        .map(|answer| {
            let mut picked: Vec<String> = answer["selected"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|l| l.as_str().map(str::to_string))
                .collect();
            picked.extend(answer["custom"].as_str().map(str::to_string));
            let said = if picked.is_empty() {
                "Skipped".to_string()
            } else {
                picked.join(", ")
            };
            match questions
                .iter()
                .find(|q| q["id"] == answer["id"])
                .and_then(|q| q["question"].as_str())
            {
                Some(question) if questions.len() > 1 => format!("{question} {said}"),
                _ => said,
            }
        })
        .collect();
    Some(lines.join("\n"))
}

/// How the model ended the reply, from the finish chunk its stream closes with: "stop", "tool-calls", "max-tokens".
fn finish(data: &Value) -> Option<&str> {
    data["stream"].as_array()?.iter().rev().find_map(|frame| {
        (frame["chunk"]["type"] == "finish")
            .then(|| frame["chunk"]["reason"]["kind"].as_str())
            .flatten()
    })
}

/// dsh's assistant message as Pi's. Blocks keep their order, empty reasoning included, so they line up with the
/// stream's block indices. A reply cut off at the output limit says so, as Pi's "length".
fn assistant_message(message: &Value, finish: Option<&str>) -> Value {
    let blocks = message["content"].as_array().cloned().unwrap_or_default();
    let mut tool_use = false;
    let content: Vec<Value> = blocks
        .iter()
        .map(|block| match block["type"].as_str() {
            Some("reasoning") => json!({ "type": "thinking", "thinking": block["text"] }),
            Some("text") => json!({ "type": "text", "text": block["text"] }),
            Some("tool-call") => {
                tool_use = true;
                json!({
                    "type": "toolCall",
                    "id": block["id"],
                    "name": block["name"],
                    "arguments": arguments(&block["arguments"]),
                })
            }
            _ => json!({ "type": "text", "text": "" }),
        })
        .collect();
    let stop = if message["interrupted"] == true {
        "aborted"
    } else if finish == Some("max-tokens") {
        "length"
    } else if tool_use {
        "toolUse"
    } else {
        "stop"
    };
    json!({ "role": "assistant", "content": content, "stopReason": stop, "timestamp": now_ms() })
}

/// Tool arguments arrive as the model wrote them, a JSON string.
fn arguments(raw: &Value) -> Value {
    match raw.as_str() {
        Some(text) => serde_json::from_str(text).unwrap_or_else(|_| json!({ "raw": text })),
        None => raw.clone(),
    }
}

fn tool_content(content: &Value) -> Vec<Value> {
    content
        .as_array()
        .map(|blocks| {
            blocks
                .iter()
                .map(|block| match block["type"].as_str() {
                    Some("text") => json!({ "type": "text", "text": block["text"] }),
                    _ => json!({ "type": "text", "text": "[image]" }),
                })
                .collect()
        })
        .unwrap_or_default()
}

/// A tool call's name from the assistant message that made it.
fn tool_name(messages: &[Value], call: &str) -> String {
    messages
        .iter()
        .rev()
        .filter_map(|m| m["content"].as_array())
        .flatten()
        .find(|b| b["type"] == "toolCall" && b["id"] == call)
        .and_then(|b| b["name"].as_str())
        .unwrap_or("tool")
        .to_string()
}

/// DeepSeek's reasoning efforts are off, low, high and max: the app's other levels go to the nearest.
pub(super) fn effort(level: &str) -> &str {
    match level {
        "minimal" => "low",
        "medium" => "high",
        "xhigh" => "max",
        other => other,
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::protocol::ItemKind;

    /// What the plugin sent in a real session asked to start a background job, have a subagent read a file, then
    /// answer with both. Trimmed of dsh's bookkeeping events (system prompt, request headers, log delivery, inbox
    /// splices).
    const FEED: &str = include_str!("../dsh_feed.jsonl");

    pub(super) fn replay() -> (Feed, Vec<Value>) {
        let lines: Vec<Value> = FEED
            .lines()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect();
        let mut feed = Feed {
            root: lines
                .iter()
                .find(|l| l["event"] == "session" && l["parent"].is_null())
                .and_then(|l| l["sessionId"].as_str())
                .unwrap()
                .to_string(),
            ..Default::default()
        };
        let events = lines.iter().flat_map(|l| feed.receive(l)).collect();
        (feed, events)
    }

    /// The events the recorded feed turns into, for the tests of what the bridge does with them.
    pub(crate) fn recorded_events() -> Vec<Value> {
        replay().1
    }

    fn kinds(events: &[Value]) -> Vec<&str> {
        events.iter().map(|e| e["type"].as_str().unwrap()).collect()
    }

    #[test]
    fn a_turn_starts_streams_and_settles() {
        let (feed, events) = replay();
        let kinds = kinds(&events);
        assert_eq!(kinds.first(), Some(&"agent_start"));
        assert_eq!(
            &kinds[kinds.len() - 3..],
            ["turn_end", "agent_end", "agent_settled"]
        );
        assert!(!feed.running);
        assert_eq!(feed.window, Some(1_000_000));
        assert!(feed.tokens.is_some_and(|t| t > 0));
        // The reply arrives as it's written, not only once it's done.
        let deltas = kinds.iter().filter(|k| **k == "message_update").count();
        assert!(deltas > 100, "{deltas} updates");
    }

    #[test]
    fn streamed_text_adds_up_to_the_committed_reply() {
        let (_, events) = replay();
        let mut streamed = String::new();
        let mut last = None;
        for event in &events {
            match event["type"].as_str() {
                Some("message_start") if event["message"]["role"] == "assistant" => {
                    streamed.clear()
                }
                Some("message_update")
                    if event["assistantMessageEvent"]["type"] == "text_delta" =>
                {
                    streamed += event["assistantMessageEvent"]["delta"].as_str().unwrap();
                }
                Some("message_end") if event["message"]["role"] == "assistant" => {
                    let text: String = event["message"]["content"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .filter_map(|b| b["text"].as_str())
                        .collect();
                    assert_eq!(streamed, text);
                    last = Some(text);
                }
                _ => {}
            }
        }
        assert!(last.unwrap().contains("3.14159"));
    }

    #[test]
    fn the_live_transcript_matches_the_one_read_back() {
        let (feed, events) = replay();
        let mut live = crate::transcript::Transcript::default();
        for event in &events {
            live.handle_event(event);
        }
        let read_back = crate::transcript::Transcript::rebuild(&feed.root_messages(), usize::MAX);
        let shape = |items: &[crate::protocol::Item]| -> Vec<(ItemKind, String, Option<String>)> {
            items
                .iter()
                .filter(|i| !(i.kind == ItemKind::Thinking && i.text.is_empty()))
                .map(|i| (i.kind, i.text.clone(), i.tool_name.clone()))
                .collect()
        };
        assert_eq!(shape(&live.items), shape(&read_back));
        let tools: Vec<_> = read_back
            .iter()
            .filter_map(|i| i.tool_name.as_deref())
            .collect();
        assert_eq!(tools, ["bash", "subagent", "job_output"]);
        // The user's prompt shows; dsh's runtime context doesn't.
        let users: Vec<_> = read_back
            .iter()
            .filter(|i| i.kind == ItemKind::User)
            .collect();
        assert!(users[0].text.starts_with("Do three things"));
        assert!(!read_back.iter().any(|i| i.text.contains("runtime context")));
    }

    #[test]
    fn background_jobs_are_counted() {
        let (_, events) = replay();
        let counts: Vec<_> = events
            .iter()
            .filter(|e| e["type"] == "dsh_jobs")
            .map(|e| e["running"].as_u64().unwrap())
            .collect();
        assert_eq!(counts, [1, 0]);
    }

    #[test]
    fn a_subagent_gets_its_own_transcript() {
        let (feed, events) = replay();
        let updates: Vec<_> = events
            .iter()
            .filter(|e| e["type"] == "dsh_subagent")
            .collect();
        let last = updates.last().unwrap();
        assert_eq!(last["status"], "done");
        assert_eq!(last["parent"], Value::Null);
        assert_eq!(last["title"], "Read notes.txt for pi");
        let items =
            crate::transcript::Transcript::rebuild(last["messages"].as_array().unwrap(), 1000);
        assert!(items.iter().any(|i| i.tool_name.as_deref() == Some("read")));
        assert!(items
            .iter()
            .any(|i| i.kind == ItemKind::Text && i.text.contains("3.14159")));
        // Running while it worked.
        assert!(updates.iter().any(|u| u["status"] == "running"));
        assert_eq!(feed.sessions.len(), 2);
    }

    #[test]
    fn a_resumed_session_reads_back_without_replaying_events() {
        let (feed, _) = replay();
        let root = feed.root.clone();
        let history: Vec<Value> = FEED
            .lines()
            .map(|l| serde_json::from_str::<Value>(l).unwrap())
            .filter(|l| l["event"] == "session" && l["sessionId"] == root.as_str())
            .map(|l| l["data"].clone())
            .collect();
        let mut resumed = Feed {
            root,
            ..Default::default()
        };
        resumed.replay(&history);
        assert!(!resumed.running);
        assert_eq!(resumed.root_messages().len(), feed.root_messages().len());
    }

    #[test]
    fn a_resumed_sessions_subagent_reads_back_as_it_ran() {
        let (feed, events) = replay();
        let live = events
            .iter()
            .rfind(|e| e["type"] == "dsh_subagent")
            .unwrap()
            .clone();
        let lines: Vec<Value> = FEED
            .lines()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect();
        let history = |id: &str| -> Vec<Value> {
            lines
                .iter()
                .filter(|l| l["event"] == "session" && l["sessionId"] == id)
                .map(|l| l["data"].clone())
                .collect()
        };
        let child = live["id"].as_str().unwrap();
        let mut resumed = Feed {
            root: feed.root.clone(),
            ..Default::default()
        };
        resumed.replay(&history(&feed.root));
        resumed.replay_subagent(child, None, &history(child));
        let read_back = resumed.subagent(child);
        for field in ["title", "status", "parent", "messages"] {
            assert_eq!(read_back[field], live[field], "{field}");
        }
        assert!(read_back["createdAt"].as_u64() < read_back["lastActiveAt"].as_u64());
    }

    #[test]
    fn a_question_shows_until_answered() {
        let mut feed = Feed {
            root: "root".into(),
            ..Default::default()
        };
        let question = json!({ "callId": "call_1", "state": "open",
            "questions": [{ "id": "mode", "question": "Which mode?", "options": [{ "label": "Fast" }] }] });
        let events = feed.receive(&json!({ "event": "questions", "active": [question] }));
        assert_eq!(events[0]["type"], "dsh_question");
        assert_eq!(events[0]["question"]["id"], "call_1");
        assert_eq!(events[0]["question"]["continued"], false);
        assert_eq!(
            events[0]["question"]["questions"][0]["options"][0]["label"],
            "Fast"
        );
        // Unchanged: nothing to tell.
        assert!(feed
            .receive(&json!({ "event": "questions", "active": [question] }))
            .is_empty());
        // The agent carried on without the answer; it can still be given.
        let mut continued = question.clone();
        continued["state"] = json!("continued");
        let events = feed.receive(&json!({ "event": "questions", "active": [continued] }));
        assert_eq!(events[0]["question"]["continued"], true);
        let events = feed.receive(&json!({ "event": "questions", "active": [] }));
        assert_eq!(events[0]["question"], Value::Null);
    }

    #[test]
    fn a_late_answer_reads_as_what_the_user_said() {
        let reply = json!({ "kind": "answer_to_pending_question", "callId": "c",
            "questions": [{ "id": "pet", "question": "Which pet?" }, { "id": "size", "question": "Sizes?" }],
            "answers": [{ "id": "pet", "selected": [], "custom": "A hamster" }, { "id": "size", "selected": [] }] });
        let message = user_message(&json!({ "source": { "kind": "user-question-reply" },
            "content": [{ "type": "text", "text": reply.to_string() }] }))
        .unwrap();
        assert_eq!(
            message["content"][0]["text"],
            "Which pet? A hamster\nSizes? Skipped"
        );
    }

    #[test]
    fn a_compaction_shows_while_it_runs() {
        let mut feed = Feed {
            root: "root".into(),
            ..Default::default()
        };
        let event = |kind: &str, data: Value| json!({ "event": "session", "sessionId": "root", "data": { "type": kind, "data": data } });
        let started = feed.receive(&event(
            "compaction/start",
            json!({ "compactionId": "c1", "turn": null }),
        ));
        assert_eq!(
            started[0],
            json!({ "type": "compaction_start", "reason": "threshold" })
        );
        let ended = feed.receive(&event(
            "compaction/end",
            json!({ "compactionId": "c1", "turn": null, "error": "summary failed" }),
        ));
        assert_eq!(ended[0]["type"], "compaction_end");
        assert_eq!(ended[0]["errorMessage"], "summary failed");
        assert_eq!(feed.compactions, 1);
    }

    #[test]
    fn a_compaction_summary_reads_as_a_compaction() {
        let data = json!({
            "content": [{ "type": "text", "text": "This is an automatically generated checkpoint." }],
            "source": { "kind": "compact-checkpoint" },
        });
        let message = user_message(&data).unwrap();
        let items = crate::transcript::Transcript::rebuild(&[message], 100);
        assert_eq!(items[0].kind, ItemKind::Compaction);
    }

    #[test]
    fn a_reply_cut_at_the_output_limit_says_so() {
        let data = json!({
            "message": { "role": "assistant", "content": [{ "type": "reasoning", "text": "Let me plan the dome" }] },
            "stream": [
                { "type": "chunk", "chunk": { "type": "block-start", "index": 0 } },
                { "type": "chunk", "chunk": { "type": "finish", "reason": { "kind": "max-tokens" } } },
            ],
        });
        let message = assistant_message(&data["message"], finish(&data));
        assert_eq!(message["stopReason"], "length");
        let items = crate::transcript::Transcript::rebuild(&[message], 100);
        assert_eq!(
            items.last().unwrap().text,
            "Stopped at the model's output limit"
        );
        assert_eq!(finish(&json!({})), None);
    }

    #[test]
    fn tool_arguments_are_parsed() {
        assert_eq!(arguments(&json!(r#"{"a": 1}"#)), json!({ "a": 1 }));
        assert_eq!(arguments(&json!("not json")), json!({ "raw": "not json" }));
    }
}
