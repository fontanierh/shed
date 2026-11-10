//! Normalizes Pi/Prime messages and streaming events into a flat list of transcript items.

use std::collections::HashMap;

use serde_json::Value;

use crate::protocol::{Item, ItemAppend, ItemKind, ItemSet, ToolStatus};

const MAX_FIELD: usize = 20_000;

pub enum Change {
    Add(Item),
    Patch {
        item_id: String,
        set: Option<ItemSet>,
        append: Option<ItemAppend>,
    },
}

fn clip(text: String) -> String {
    clip_to(text, MAX_FIELD)
}

pub fn clip_to(text: String, max: usize) -> String {
    if text.len() <= max {
        return text;
    }
    let mut cut = max;
    while !text.is_char_boundary(cut) {
        cut -= 1;
    }
    format!("{}\n… ({} more bytes)", &text[..cut], text.len() - cut)
}

fn text_of(content: &Value) -> String {
    match content {
        Value::String(s) => s.clone(),
        Value::Array(blocks) => blocks
            .iter()
            .filter_map(|b| match b["type"].as_str() {
                Some("text") => b["text"].as_str().map(str::to_string),
                Some("image") => Some("[image]".into()),
                _ => None,
            })
            .collect::<Vec<_>>()
            .join("\n"),
        _ => String::new(),
    }
}

fn args_of(args: &Value) -> String {
    match args {
        Value::Null => String::new(),
        Value::String(s) => s.clone(),
        // Prime's Python REPL tool carries the cell source as `code`.
        Value::Object(map) if map.len() == 1 && map.get("code").is_some_and(Value::is_string) => {
            map["code"].as_str().unwrap().to_string()
        }
        other => serde_json::to_string_pretty(other).unwrap_or_default(),
    }
}

fn result_text(result: &Value) -> String {
    match result {
        Value::Null => String::new(),
        Value::String(s) => s.clone(),
        v if v["content"].is_array() => text_of(&v["content"]),
        other => serde_json::to_string_pretty(other).unwrap_or_default(),
    }
}

fn str_field(v: &Value, key: &str) -> Option<String> {
    v[key].as_str().map(str::to_string)
}

#[derive(Default)]
pub struct Transcript {
    pub items: Vec<Item>,
    index: HashMap<String, usize>,
    tools: HashMap<String, String>, // toolCallId -> item id
    stream: HashMap<i64, String>,   // contentIndex -> item id for the streaming assistant message
    user_started: bool,
    next_id: u64,
    silent: bool,
    changes: Vec<Change>,
    /// While rebuilding from history: the timestamp of the message being added.
    clock: Option<u64>,
    /// Watches the block streaming now for a generation loop.
    runaway: crate::runaway::Runaway,
    /// Why the streaming reply was found looping, until the session takes it to stop the reply.
    looping: Option<(&'static str, crate::runaway::LoopSample)>,
    /// The block streaming now was already found looping: its stop is on its way, so it isn't reported again.
    stopped: bool,
}

impl Transcript {
    pub fn take_changes(&mut self) -> Vec<Change> {
        std::mem::take(&mut self.changes)
    }

    /// Why the reply streaming now is a generation loop, once: the session stops it.
    pub fn take_looping(&mut self) -> Option<(&'static str, crate::runaway::LoopSample)> {
        self.looping.take()
    }

    fn watch(&mut self, delta: &str) {
        if self.stopped {
            return;
        }
        if let Some(reason) = self.runaway.feed(delta) {
            self.looping = Some((reason, self.runaway.sample()));
            self.stopped = true;
        }
    }

    pub fn reset(&mut self, messages: &[Value]) {
        self.items.clear();
        self.index.clear();
        self.tools.clear();
        self.stream.clear();
        self.silent = true;
        for message in messages {
            // Epoch ms, except Prime's custom messages (bash-done, agent messages), which carry ISO 8601.
            self.clock = message["timestamp"].as_u64().or_else(|| {
                message["timestamp"]
                    .as_str()
                    .and_then(crate::session::parse_iso_ms)
            });
            self.add_message(message);
        }
        self.clock = None;
        self.silent = false;
        self.changes.clear();
    }

    /// The items for `messages`, read from history rather than streamed, with tool arguments and output clipped to `max`.
    pub fn rebuild(messages: &[Value], max: usize) -> Vec<Item> {
        let mut transcript = Transcript::default();
        transcript.reset(messages);
        let mut items = std::mem::take(&mut transcript.items);
        for item in &mut items {
            item.args = item.args.take().map(|a| clip_to(a, max));
            item.output = item.output.take().map(|o| clip_to(o, max));
        }
        items
    }

    pub fn first_user_text(&self) -> Option<&str> {
        self.items
            .iter()
            .find(|i| i.kind == ItemKind::User)
            .map(|i| i.text.as_str())
    }

    pub fn handle_event(&mut self, event: &Value) {
        let message = &event["message"];
        match event["type"].as_str().unwrap_or("") {
            "message_start" => match message["role"].as_str() {
                Some("assistant") => self.stream.clear(),
                Some("user") => {
                    self.user_started = true;
                    self.add_message(message);
                }
                _ => self.add_message(message),
            },
            "message_update" => self.handle_delta(&event["assistantMessageEvent"], message),
            "message_end" => match message["role"].as_str() {
                Some("assistant") => self.finish_assistant(message),
                Some("toolResult") => self.add_message(message),
                Some("user") if !self.user_started => self.add_message(message),
                Some("user") => self.user_started = false,
                _ => {}
            },
            "tool_execution_start" => {
                let set = ItemSet {
                    status: Some(ToolStatus::Running),
                    args: Some(args_of(&event["args"])),
                    ..Default::default()
                };
                self.upsert_tool(event, set);
            }
            "tool_execution_update" => {
                let set = ItemSet {
                    output: Some(clip(result_text(&event["partialResult"]))),
                    ..Default::default()
                };
                self.upsert_tool(event, set);
            }
            "tool_execution_end" => {
                let failed = event["isError"].as_bool().unwrap_or(false);
                let set = ItemSet {
                    status: Some(if failed {
                        ToolStatus::Error
                    } else {
                        ToolStatus::Done
                    }),
                    output: Some(clip(result_text(&event["result"]))),
                    duration_ms: event["durationMs"].as_f64().map(|d| d as u64),
                    ..Default::default()
                };
                self.upsert_tool(event, set);
            }
            "compaction_end" => {
                if event["aborted"] == true || event["errorMessage"].is_string() {
                    let reason = event["errorMessage"].as_str().unwrap_or("aborted");
                    let text = if reason.starts_with("Compaction") {
                        reason.to_string()
                    } else {
                        format!("Compaction failed: {reason}")
                    };
                    self.add(Item::new(ItemKind::Error, text));
                }
            }
            "auto_retry_start" => {
                let attempt = event["attempt"]
                    .as_u64()
                    .map(|a| a.to_string())
                    .unwrap_or("?".into());
                let reason = event["errorMessage"].as_str().unwrap_or("");
                self.add(Item::new(
                    ItemKind::Note,
                    format!("Retrying (attempt {attempt}) {reason}")
                        .trim()
                        .to_string(),
                ));
            }
            _ => {}
        }
    }

    fn add(&mut self, mut item: Item) -> String {
        self.next_id += 1;
        item.id = format!("i{}", self.next_id);
        item.at = item.at.or(self.clock).or_else(|| Some(now_ms()));
        let id = item.id.clone();
        self.index.insert(id.clone(), self.items.len());
        if !self.silent {
            self.changes.push(Change::Add(item.clone()));
        }
        self.items.push(item);
        id
    }

    fn patch(&mut self, item_id: &str, set: Option<ItemSet>, append: Option<ItemAppend>) {
        let Some(&pos) = self.index.get(item_id) else {
            return;
        };
        let item = &mut self.items[pos];
        if let Some(set) = &set {
            set.apply(item);
        }
        if let Some(append) = &append {
            if let Some(text) = &append.text {
                item.text.push_str(text);
            }
            if let Some(args) = &append.args {
                item.args.get_or_insert_with(String::new).push_str(args);
            }
        }
        if !self.silent {
            self.changes.push(Change::Patch {
                item_id: item_id.to_string(),
                set,
                append,
            });
        }
    }

    fn set(&mut self, item_id: &str, set: ItemSet) {
        self.patch(item_id, Some(set), None);
    }

    fn upsert_tool(&mut self, event: &Value, mut set: ItemSet) {
        let call_id = str_field(event, "toolCallId").unwrap_or_default();
        if let Some(existing) = self.tools.get(&call_id).cloned() {
            // Keep the streamed arguments if execution reports none.
            if set.args.as_deref() == Some("") {
                set.args = None;
            }
            if !set.is_empty() {
                self.set(&existing, set);
            }
            return;
        }
        let mut item = Item::new(ItemKind::Tool, "");
        item.tool_name = Some(str_field(event, "toolName").unwrap_or("tool".into()));
        item.args = Some(String::new());
        item.status = Some(ToolStatus::Pending);
        set.apply(&mut item);
        let id = self.add(item);
        self.tools.insert(call_id, id);
    }

    fn handle_delta(&mut self, delta: &Value, partial: &Value) {
        // Prime's daemon omits contentIndex but sends the partial message: the delta belongs to its
        // last content block.
        let index = delta["contentIndex"]
            .as_i64()
            .or_else(|| partial["content"].as_array().map(|c| c.len() as i64 - 1))
            .unwrap_or(-1);
        let item_id = self.stream.get(&index).cloned();
        let text = || delta["delta"].as_str().unwrap_or("").to_string();
        match delta["type"].as_str().unwrap_or("") {
            kind @ ("text_start" | "thinking_start" | "toolcall_start") => {
                self.runaway.reset(match kind {
                    "text_start" => "text",
                    "thinking_start" => "thinking",
                    _ => "toolcall",
                });
                self.stopped = false;
            }
            "text_delta" | "thinking_delta" | "toolcall_delta" => {
                self.watch(delta["delta"].as_str().unwrap_or(""))
            }
            _ => {}
        }
        match delta["type"].as_str().unwrap_or("") {
            "text_start" => {
                let id = self.add(Item::new(ItemKind::Text, ""));
                self.stream.insert(index, id);
            }
            "thinking_start" => {
                let id = self.add(Item::new(ItemKind::Thinking, ""));
                self.stream.insert(index, id);
            }
            "toolcall_start" => {
                let mut item = Item::new(ItemKind::Tool, "");
                item.tool_name = str_field(delta, "toolName");
                item.args = Some(String::new());
                item.status = Some(ToolStatus::Preparing);
                let id = self.add(item);
                if let Some(call_id) = str_field(delta, "id") {
                    self.tools.insert(call_id, id.clone());
                }
                self.stream.insert(index, id);
            }
            kind @ ("text_delta" | "thinking_delta") => match item_id {
                Some(id) => self.patch(
                    &id,
                    None,
                    Some(ItemAppend {
                        text: Some(text()),
                        args: None,
                    }),
                ),
                None => {
                    let item_kind = if kind == "text_delta" {
                        ItemKind::Text
                    } else {
                        ItemKind::Thinking
                    };
                    let id = self.add(Item::new(item_kind, text()));
                    self.stream.insert(index, id);
                }
            },
            "toolcall_delta" => {
                if let Some(id) = item_id {
                    self.patch(
                        &id,
                        None,
                        Some(ItemAppend {
                            text: None,
                            args: Some(text()),
                        }),
                    );
                }
            }
            "text_end" | "thinking_end" => {
                if let (Some(id), Some(content)) = (item_id, delta["content"].as_str()) {
                    self.set(
                        &id,
                        ItemSet {
                            text: Some(content.to_string()),
                            ..Default::default()
                        },
                    );
                }
            }
            "toolcall_end" => {
                if let Some(id) = item_id {
                    let call = &delta["toolCall"];
                    // Prime only reports the call id here, not at toolcall_start.
                    let call_id = str_field(call, "id");
                    if let Some(call_id) = &call_id {
                        self.tools.insert(call_id.clone(), id.clone());
                    }
                    let set = ItemSet {
                        args: Some(args_of(&call["arguments"])),
                        status: Some(ToolStatus::Pending),
                        tool_name: str_field(call, "name"),
                        ..Default::default()
                    };
                    self.set(&id, set);
                }
            }
            _ => {}
        }
    }

    /// message_end is authoritative: fill in any block that didn't stream (non-streaming providers).
    fn finish_assistant(&mut self, message: &Value) {
        let empty = Vec::new();
        let content = message["content"].as_array().unwrap_or(&empty);
        for (index, block) in content.iter().enumerate() {
            let item_id = self.stream.get(&(index as i64)).cloned();
            match block["type"].as_str().unwrap_or("") {
                "text" => {
                    let text = block["text"].as_str().unwrap_or("").to_string();
                    match item_id {
                        Some(id) => self.set(
                            &id,
                            ItemSet {
                                text: Some(text),
                                ..Default::default()
                            },
                        ),
                        None if !text.is_empty() => {
                            self.add(Item::new(ItemKind::Text, text));
                        }
                        None => {}
                    }
                }
                "thinking" => {
                    let mut text = block["thinking"].as_str().unwrap_or("").to_string();
                    if text.is_empty() && block["redacted"] == true {
                        text = "(redacted reasoning)".into();
                    }
                    match item_id {
                        Some(id) => self.set(
                            &id,
                            ItemSet {
                                text: Some(text),
                                ..Default::default()
                            },
                        ),
                        None if !text.is_empty() => {
                            self.add(Item::new(ItemKind::Thinking, text));
                        }
                        None => {}
                    }
                }
                "toolCall" => {
                    let call_id = str_field(block, "id").unwrap_or_default();
                    let set = ItemSet {
                        args: Some(args_of(&block["arguments"])),
                        tool_name: str_field(block, "name"),
                        ..Default::default()
                    };
                    match item_id.or_else(|| self.tools.get(&call_id).cloned()) {
                        Some(id) => {
                            self.tools.insert(call_id, id.clone());
                            self.set(&id, set)
                        }
                        None => {
                            let event = serde_json::json!({ "toolCallId": call_id, "toolName": block["name"] });
                            self.upsert_tool(&event, set);
                        }
                    }
                }
                _ => {}
            }
        }
        // A reply that failed, was stopped or ran out of output tokens runs none of its tool calls: one it was still
        // writing (DeepSeek's arguments that weren't JSON) would otherwise wait for good.
        if matches!(
            message["stopReason"].as_str(),
            Some("error" | "aborted" | "length")
        ) {
            let calls = content
                .iter()
                .filter_map(|block| str_field(block, "id"))
                .filter_map(|call| self.tools.get(&call).cloned());
            let ids: Vec<String> = self.stream.values().cloned().chain(calls).collect();
            for id in ids {
                let waiting = self.index.get(&id).is_some_and(|&pos| {
                    matches!(
                        self.items[pos].status,
                        Some(ToolStatus::Preparing | ToolStatus::Pending)
                    )
                });
                if waiting {
                    let set = ItemSet {
                        status: Some(ToolStatus::Error),
                        output: Some("Never ran: the reply ended before it.".into()),
                        ..Default::default()
                    };
                    self.set(&id, set);
                }
            }
        }
        self.stream.clear();
        match message["stopReason"].as_str() {
            Some("error") => {
                if let Some(error) = message["errorMessage"].as_str() {
                    self.add(Item::new(ItemKind::Error, error));
                }
            }
            Some("aborted") => {
                self.add(Item::new(ItemKind::Note, "Aborted"));
            }
            // The model ran out of output tokens mid-reply: without this the cut reads as a finished answer.
            Some("length") => {
                self.add(Item::new(
                    ItemKind::Note,
                    "Stopped at the model's output limit",
                ));
            }
            _ => {}
        }
    }

    fn add_message(&mut self, message: &Value) {
        match message["role"].as_str().unwrap_or("") {
            "user" => {
                self.add(Item::new(ItemKind::User, text_of(&message["content"])));
            }
            "assistant" => {
                self.stream.clear();
                self.finish_assistant(message);
            }
            "toolResult" => {
                let failed = message["isError"].as_bool().unwrap_or(false);
                // Rebuilt from history, a tool has no execution events: it took until its result.
                let started = str_field(message, "toolCallId")
                    .and_then(|call| self.tools.get(&call))
                    .and_then(|id| self.index.get(id))
                    .and_then(|&i| self.items[i].at);
                let set = ItemSet {
                    status: Some(if failed {
                        ToolStatus::Error
                    } else {
                        ToolStatus::Done
                    }),
                    output: Some(clip(text_of(&message["content"]))),
                    duration_ms: self
                        .clock
                        .zip(started)
                        .map(|(end, start)| end.saturating_sub(start)),
                    ..Default::default()
                };
                self.upsert_tool(message, set);
            }
            "bashExecution" => {
                let mut item = Item::new(ItemKind::Tool, "");
                item.tool_name = Some("user bash".into());
                item.args = str_field(message, "command");
                item.output = Some(clip(str_field(message, "output").unwrap_or_default()));
                item.status = Some(if message["exitCode"] == 0 {
                    ToolStatus::Done
                } else {
                    ToolStatus::Error
                });
                self.add(item);
            }
            "compactionSummary" => {
                let mut item = Item::new(
                    ItemKind::Compaction,
                    str_field(message, "summary").unwrap_or_default(),
                );
                item.output = message["tokensBefore"].as_u64().map(|t| t.to_string());
                self.add(item);
            }
            "branchSummary" => {
                self.add(Item::new(
                    ItemKind::Note,
                    str_field(message, "summary").unwrap_or("Branch summary".into()),
                ));
            }
            // The goal's continuation prompt is for the model; the app shows the goal itself.
            "custom" if message["customType"] == "goal_context" => {}
            "custom" if message["display"] != false => {
                self.add(Item::new(ItemKind::Note, text_of(&message["content"])));
            }
            _ => {}
        }
    }
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn delta(kind: &str, text: &str) -> Value {
        json!({ "type": "message_update", "message": { "role": "assistant", "content": [{ "type": "toolCall" }] },
                "assistantMessageEvent": { "type": kind, "delta": text } })
    }

    #[test]
    fn flags_a_tool_call_streaming_only_whitespace_once() {
        // What a looping model once streamed for a quarter of an hour.
        let mut transcript = Transcript::default();
        transcript.handle_event(&delta("toolcall_start", ""));
        transcript.handle_event(&delta("toolcall_delta", "{\"code\":\""));
        let mut flagged = 0;
        for _ in 0..1_000 {
            transcript.handle_event(&delta("toolcall_delta", " \t\t\t\t\t\t\t\t\n      "));
            flagged += transcript.take_looping().is_some() as usize;
        }
        assert_eq!(flagged, 1);
    }

    #[test]
    fn a_tool_call_cut_off_by_a_failed_reply_never_runs() {
        let mut transcript = Transcript::default();
        let start = |id: &str, index: i64| {
            json!({ "type": "message_update", "message": { "role": "assistant" },
            "assistantMessageEvent": { "type": "toolcall_start", "contentIndex": index, "id": id, "toolName": "bash" } })
        };
        transcript.handle_event(
            &json!({ "type": "message_start", "message": { "role": "assistant", "content": [] } }),
        );
        transcript.handle_event(&start("call_1", 0));
        transcript.handle_event(
            &json!({ "type": "message_end", "message": { "role": "assistant", "content": [],
            "stopReason": "error", "errorMessage": "tool input is invalid JSON" } }),
        );
        let tool = transcript
            .items
            .iter()
            .find(|i| i.kind == ItemKind::Tool)
            .unwrap();
        assert_eq!(tool.status, Some(ToolStatus::Error));
        // A reply that ends well leaves its calls to run.
        transcript.handle_event(
            &json!({ "type": "message_start", "message": { "role": "assistant", "content": [] } }),
        );
        transcript.handle_event(&start("call_2", 0));
        transcript.handle_event(&json!({ "type": "message_end", "message": { "role": "assistant",
            "content": [{ "type": "toolCall", "id": "call_2", "name": "bash", "arguments": {} }], "stopReason": "toolUse" } }));
        let tool = transcript
            .items
            .iter()
            .rfind(|i| i.kind == ItemKind::Tool)
            .unwrap();
        assert_eq!(tool.status, Some(ToolStatus::Preparing));
    }
}
