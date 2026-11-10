//! What Pi, Prime and DeepSeek Harness tell the bridge about a session, read into the bridge's own types.
//!
//! The agents are other programs, at versions the bridge doesn't choose. Each reader here takes what it can of a
//! message: a part that is missing, or of another type than expected, reads as absent, never as an error.

use serde_json::Value;

use crate::protocol::{ContextUsage, Goal, ModelInfo, Queue, SessionKind, SessionStatus};
use crate::session::parse_iso_ms;

fn text(value: &Value) -> Option<String> {
    value.as_str().map(str::to_string)
}

fn list(value: &Value) -> Vec<Value> {
    value.as_array().cloned().unwrap_or_default()
}

fn working(compacting: &Value, running: bool) -> SessionStatus {
    if compacting == true {
        SessionStatus::Compacting
    } else if running {
        SessionStatus::Running
    } else {
        SessionStatus::Idle
    }
}

impl ModelInfo {
    pub fn from_value(v: &Value) -> Option<ModelInfo> {
        let id = v["id"].as_str()?.to_string();
        Some(ModelInfo {
            provider: v["provider"].as_str().unwrap_or("").to_string(),
            name: v["name"].as_str().unwrap_or(&id).to_string(),
            context_window: v["contextWindow"].as_u64(),
            reasoning: v["reasoning"].as_bool().unwrap_or(false),
            id,
        })
    }
}

impl Goal {
    /// From Prime's goal state; `None` once there is no goal left to pursue (cleared or complete).
    pub fn from_value(v: &Value) -> Option<Goal> {
        let status = v["status"].as_str()?;
        if matches!(status, "idle" | "complete") {
            return None;
        }
        Some(Goal {
            objective: v["objective"].as_str()?.to_string(),
            status: status.to_string(),
            tokens_used: v["tokensUsed"].as_u64().unwrap_or(0),
            token_budget: v["tokenBudget"].as_u64(),
            time_used_seconds: v["timeUsedSeconds"].as_u64().unwrap_or(0),
            last_reason: v["lastReason"].as_str().map(str::to_string),
        })
    }
}

/// A model named as `provider/id`, which is all a subagent says of its model.
pub struct ModelRef {
    pub provider: String,
    pub id: String,
}

impl ModelRef {
    fn read(value: &Value) -> Option<ModelRef> {
        let (provider, id) = value.as_str()?.split_once('/')?;
        Some(ModelRef {
            provider: provider.into(),
            id: id.into(),
        })
    }

    pub fn info(self, context_window: Option<u64>) -> ModelInfo {
        ModelInfo {
            provider: self.provider,
            name: self.id.clone(),
            id: self.id,
            context_window,
            reasoning: true,
        }
    }
}

/// The messages waiting in a session's queue. An entry is its text, or an object holding the text under `text`,
/// `message` or `content`, the last of which may be a list of blocks.
pub fn queue_texts(entries: &Value) -> Vec<String> {
    let Some(entries) = entries.as_array() else {
        return Vec::new();
    };
    entries
        .iter()
        .filter_map(|e| match e {
            Value::String(s) => Some(s.clone()),
            _ => ["text", "message", "content"]
                .iter()
                .find_map(|k| match &e[*k] {
                    Value::String(s) => Some(s.clone()),
                    Value::Array(blocks) => blocks
                        .iter()
                        .find_map(|b| b["text"].as_str().map(str::to_string)),
                    _ => None,
                }),
        })
        .collect()
}

/// The queue in a roster row or a state: absent when the agent left `sessionActions` out, empty when it sent
/// anything else than the two lists.
fn queue(owner: &Value) -> Option<Queue> {
    let actions = owner.get("sessionActions")?;
    Some(Queue {
        steering: queue_texts(&actions["steering"]),
        follow_up: queue_texts(&actions["followUps"]),
    })
}

/// One session in Prime's roster.
pub struct PrimeRow {
    pub id: String,
    pub cwd: String,
    pub created_at: Option<u64>,
    pub kind: SessionKind,
    pub parent_id: Option<String>,
    pub name: Option<String>,
    pub running_subagents: bool,
    pub last_active_at: Option<u64>,
    pub first_message: Option<String>,
    /// Compacting, running or idle.
    pub status: SessionStatus,
    pub model: Option<ModelInfo>,
    pub thinking_level: Option<String>,
    pub cost: Option<f64>,
    pub queue: Option<Queue>,
    pub session_file: Option<String>,
    /// The conversation's id, which `new_session` replaces while `id` stays.
    pub conversation: Option<String>,
    /// What Prime's own list of sessions knows this one by, running or stopped; its `id` is only for while it runs.
    pub listed_as: Option<String>,
    pub worker_pid: Option<u32>,
    /// While the session runs tools, how many calls it has made so far.
    pub running_tools: Option<u64>,
    pub activity: String,
    pub message_count: u64,
}

impl PrimeRow {
    /// `None` for a row without an `activeSessionId`: a session nobody can address.
    pub fn read(row: &Value) -> Option<PrimeRow> {
        let conversation = text(&row["sessionId"]);
        Some(PrimeRow {
            id: text(&row["activeSessionId"])?,
            cwd: text(&row["cwd"]).unwrap_or_default(),
            created_at: row["created"].as_str().and_then(parse_iso_ms),
            kind: if row["runtimeKind"] == "subagent" {
                SessionKind::Subagent
            } else {
                SessionKind::Root
            },
            parent_id: text(&row["parentActiveSessionId"]),
            name: text(&row["sessionName"]),
            running_subagents: row["hasRunningSubagents"] == true,
            last_active_at: row["lastActivityAt"].as_str().and_then(parse_iso_ms),
            first_message: text(&row["firstMessage"]),
            status: working(
                &row["isCompacting"],
                row["isStreaming"] == true || row["activity"].as_str().is_some_and(|a| a != "idle"),
            ),
            model: ModelInfo::from_value(&row["model"]),
            thinking_level: text(&row["thinkingLevel"]),
            cost: row["usage"]["cost"].as_f64(),
            queue: queue(row),
            session_file: text(&row["sessionFile"]),
            listed_as: conversation.clone().or_else(|| text(&row["id"])),
            conversation,
            worker_pid: row["workerPid"].as_u64().map(|pid| pid as u32),
            running_tools: (row["isRunningTools"] == true)
                .then(|| row["toolUseCount"].as_u64().unwrap_or(0)),
            activity: text(&row["activity"]).unwrap_or_default(),
            message_count: row["messageCount"].as_u64().unwrap_or(0),
        })
    }
}

/// A roster row of a Prime session that stopped. It has no `activeSessionId` left, only what the session was
/// stored as.
pub struct InactiveRow {
    pub session_file: Option<String>,
    pub session_id: Option<String>,
}

impl InactiveRow {
    /// `None` when the row names neither, and so no session.
    pub fn read(row: &Value) -> Option<InactiveRow> {
        let row = InactiveRow {
            session_file: text(&row["sessionFile"]),
            session_id: text(&row["sessionId"]).or_else(|| text(&row["id"])),
        };
        (row.session_file.is_some() || row.session_id.is_some()).then_some(row)
    }
}

/// What Prime's daemon answers when the bridge attaches to a session.
pub struct Attached {
    pub messages: Vec<Value>,
    pub goal: Option<Goal>,
}

impl Attached {
    pub fn read(answer: &Value) -> Attached {
        let snapshot = &answer["snapshot"];
        Attached {
            messages: list(&snapshot["messages"]),
            goal: Goal::from_value(&snapshot["state"]["goal"]),
        }
    }
}

/// An agent's answer to `get_state`.
pub struct AgentState {
    pub model: Option<ModelInfo>,
    pub thinking_level: Option<String>,
    pub auto_compaction: Option<bool>,
    /// Compacting, running or idle.
    pub status: SessionStatus,
    pub name: Option<String>,
    pub queue: Option<Queue>,
    pub session_file: Option<String>,
}

impl AgentState {
    pub fn read(answer: &Value) -> AgentState {
        AgentState {
            model: ModelInfo::from_value(&answer["model"]),
            thinking_level: text(&answer["thinkingLevel"]),
            auto_compaction: answer["autoCompactionEnabled"].as_bool(),
            status: working(&answer["isCompacting"], answer["isStreaming"] == true),
            name: text(&answer["sessionName"]),
            queue: queue(answer),
            session_file: text(&answer["sessionFile"]),
        }
    }
}

/// An agent's answer to `get_session_stats`.
pub struct AgentStats {
    pub cost: Option<f64>,
    pub session_file: Option<String>,
    pub context: Option<ContextUsage>,
}

impl AgentStats {
    pub fn read(answer: &Value) -> AgentStats {
        let usage = &answer["contextUsage"];
        AgentStats {
            cost: answer["cost"].as_f64(),
            session_file: text(&answer["sessionFile"]),
            context: usage["contextWindow"].as_u64().map(|window| ContextUsage {
                tokens: usage["tokens"].as_u64(),
                window,
                percent: usage["percent"].as_f64(),
            }),
        }
    }
}

/// The conversation in an agent's answer to `get_messages`.
pub fn messages(answer: &Value) -> Vec<Value> {
    list(&answer["messages"])
}

/// The models in an agent's answer to `get_available_models`.
pub fn models(answer: &Value) -> Vec<ModelInfo> {
    answer["models"]
        .as_array()
        .map(|models| models.iter().filter_map(ModelInfo::from_value).collect())
        .unwrap_or_default()
}

/// Pi's answer to `get_available_thinking_levels`.
pub fn thinking_levels(answer: &Value) -> Option<Vec<String>> {
    serde_json::from_value(answer["levels"].clone()).ok()
}

/// Which of `levels` a model takes, from an agent's answer to `get_available_models`: the catalog marks the levels
/// a model doesn't take with null. A model the catalog doesn't have takes them all.
pub fn model_levels(answer: &Value, model: &ModelInfo, levels: &[&str]) -> Vec<String> {
    let map = answer["models"]
        .as_array()
        .and_then(|models| {
            models
                .iter()
                .find(|m| m["id"] == model.id.as_str() && m["provider"] == model.provider.as_str())
        })
        .map(|m| &m["thinkingLevelMap"])
        .unwrap_or(&Value::Null);
    levels
        .iter()
        .filter(|level| !map.get(**level).is_some_and(Value::is_null))
        .map(|level| level.to_string())
        .collect()
}

/// The `details` of a Pi `subagent` tool call: one run per child, in the order they were asked for.
pub struct PiSubagents {
    /// Each child starts when the one before it ends.
    pub chain: bool,
    pub runs: Vec<PiSubagentRun>,
}

pub struct PiSubagentRun {
    pub agent: String,
    pub task: String,
    exit_code: i64,
    stop_reason: Option<String>,
    /// The child's conversation, without its system prompt.
    pub messages: Vec<Value>,
    pub model: Option<ModelRef>,
    pub cost: f64,
    pub context_tokens: Option<u64>,
    pub stderr: Option<String>,
}

impl PiSubagents {
    /// `None` when the details list no runs, as before the tool call has started any.
    pub fn read(details: &Value) -> Option<PiSubagents> {
        let runs = details["results"].as_array()?;
        Some(PiSubagents {
            chain: details["mode"] == "chain",
            runs: runs.iter().map(PiSubagentRun::read).collect(),
        })
    }
}

impl PiSubagentRun {
    fn read(run: &Value) -> PiSubagentRun {
        PiSubagentRun {
            agent: text(&run["agent"]).unwrap_or_else(|| "subagent".into()),
            task: text(&run["task"]).unwrap_or_default(),
            exit_code: run["exitCode"].as_i64().unwrap_or(0),
            stop_reason: text(&run["stopReason"]),
            messages: run["messages"]
                .as_array()
                .map(|messages| {
                    messages
                        .iter()
                        .filter(|m| m["role"] != "system")
                        .cloned()
                        .collect()
                })
                .unwrap_or_default(),
            model: ModelRef::read(&run["model"]),
            cost: run["usage"]["cost"].as_f64().unwrap_or(0.0),
            context_tokens: run["usage"]["contextTokens"].as_u64(),
            stderr: text(&run["stderr"]),
        }
    }

    /// A running child reports exit code 0 (or -1 as a parallel placeholder) until its process exits; it is
    /// finished once its last assistant message stopped for a reason other than calling tools.
    pub fn settled(&self) -> bool {
        self.exit_code != -1 && self.stop_reason.as_deref().is_some_and(|r| r != "toolUse")
    }

    pub fn failed(&self) -> bool {
        self.exit_code > 0 || matches!(self.stop_reason.as_deref(), Some("error" | "aborted"))
    }
}

/// One subagent of a DeepSeek Harness session, whole, as the feed gives it each time it changes.
pub struct DshSubagent {
    pub id: String,
    /// The subagent that started this one, when the session itself didn't.
    pub parent: Option<String>,
    pub messages: Vec<Value>,
    /// Running, failed or done.
    pub status: SessionStatus,
    pub last_active_at: Option<u64>,
    pub created_at: Option<u64>,
    pub title: Option<String>,
    pub error: Option<String>,
    pub model: Option<ModelRef>,
}

impl DshSubagent {
    /// `None` for a subagent without an id.
    pub fn read(child: &Value) -> Option<DshSubagent> {
        Some(DshSubagent {
            id: text(&child["id"])?,
            parent: text(&child["parent"]),
            messages: list(&child["messages"]),
            status: match child["status"].as_str() {
                Some("running") => SessionStatus::Running,
                Some("error") => SessionStatus::Error,
                _ => SessionStatus::Done,
            },
            last_active_at: child["lastActiveAt"].as_u64(),
            created_at: child["createdAt"].as_u64(),
            title: text(&child["title"]),
            error: text(&child["error"]),
            model: ModelRef::read(&child["model"]),
        })
    }
}

/// What an event from an agent says about its session. The conversation the same events carry is `Transcript`'s to
/// read.
pub enum SessionEvent {
    AgentStarted,
    AgentSettled,
    TurnEnded,
    CompactionStarted,
    CompactionEnded {
        /// It went through, and the conversation is now the shorter one.
        compacted: bool,
    },
    Queue(Queue),
    ThinkingLevel(Option<String>),
    /// The session's name, or that it has none any more.
    Named(Option<String>),
    ActionsChanged,
    Goal(Option<Goal>),
    /// DeepSeek Harness: how many background commands are running.
    Jobs(u32),
    /// DeepSeek Harness: the question the session waits on an answer to, if any.
    Question(Option<Value>),
    DshSubagent(DshSubagent),
    PiSubagentCall(PiSubagentCall),
    Other,
}

/// A `subagent` tool call of a Pi session, while it runs or once it has finished.
pub struct PiSubagentCall {
    pub call_id: String,
    pub finished: bool,
    pub children: Option<PiSubagents>,
}

impl PiSubagentCall {
    fn read(call: &Value, finished: bool, details: &Value) -> PiSubagentCall {
        PiSubagentCall {
            call_id: text(&call["toolCallId"]).unwrap_or_else(|| "call".into()),
            finished,
            children: PiSubagents::read(details),
        }
    }

    /// The finished `subagent` tool calls of a conversation.
    pub fn finished_in(messages: &[Value]) -> impl Iterator<Item = PiSubagentCall> + '_ {
        messages
            .iter()
            .filter(|m| m["role"] == "toolResult" && m["toolName"] == "subagent")
            .map(|m| PiSubagentCall::read(m, true, &m["details"]))
    }
}

impl SessionEvent {
    pub fn read(event: &Value) -> SessionEvent {
        let kind = event["type"].as_str().unwrap_or("");
        match kind {
            "agent_start" => SessionEvent::AgentStarted,
            "agent_settled" => SessionEvent::AgentSettled,
            "agent_end" | "turn_end" => SessionEvent::TurnEnded,
            "compaction_start" => SessionEvent::CompactionStarted,
            "compaction_end" => SessionEvent::CompactionEnded {
                compacted: event["aborted"] != true && !event["errorMessage"].is_string(),
            },
            "queue_update" => SessionEvent::Queue(Queue {
                steering: queue_texts(&event["steering"]),
                follow_up: queue_texts(&event["followUp"]),
            }),
            "thinking_level_changed" => SessionEvent::ThinkingLevel(text(&event["level"])),
            "session_info_changed" => SessionEvent::Named(text(&event["name"])),
            "session_action_update" => SessionEvent::ActionsChanged,
            "goal_update" => SessionEvent::Goal(Goal::from_value(&event["goal"])),
            "dsh_jobs" => SessionEvent::Jobs(event["running"].as_u64().unwrap_or(0) as u32),
            "dsh_question" => {
                SessionEvent::Question(Some(event["question"].clone()).filter(Value::is_object))
            }
            "dsh_subagent" => {
                DshSubagent::read(event).map_or(SessionEvent::Other, SessionEvent::DshSubagent)
            }
            "tool_execution_start" | "tool_execution_update" | "tool_execution_end"
                if event["toolName"] == "subagent" =>
            {
                let finished = kind == "tool_execution_end";
                let result = if finished {
                    &event["result"]
                } else {
                    &event["partialResult"]
                };
                SessionEvent::PiSubagentCall(PiSubagentCall::read(
                    event,
                    finished,
                    &result["details"],
                ))
            }
            _ => SessionEvent::Other,
        }
    }
}

/// The summary a conversation starts with once the agent has compacted it.
pub fn compaction_summary(messages: &[Value]) -> Option<&str> {
    messages
        .first()
        .filter(|m| m["role"] == "compactionSummary")
        .and_then(|m| m["summary"].as_str())
}
