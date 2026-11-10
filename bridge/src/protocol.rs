//! Wire types shared with the Swift clients (apps/Sources/ShedKit/Protocol.swift).

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::rpc::AgentKind;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ItemKind {
    User,
    Text,
    Thinking,
    Tool,
    Compaction,
    Error,
    Note,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ToolStatus {
    Preparing,
    Pending,
    Running,
    Done,
    Error,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Item {
    pub id: String,
    pub kind: ItemKind,
    pub text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_call_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub args: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub output: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<ToolStatus>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<u64>,
    /// When the item started (ms since the epoch): the message timestamp, or arrival time for live events.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub at: Option<u64>,
}

impl Item {
    pub fn new(kind: ItemKind, text: impl Into<String>) -> Item {
        Item {
            id: String::new(),
            kind,
            text: text.into(),
            tool_call_id: None,
            tool_name: None,
            args: None,
            output: None,
            status: None,
            duration_ms: None,
            at: None,
        }
    }
}

/// Fields to overwrite on an existing item.
#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ItemSet {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_call_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub args: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub output: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<ToolStatus>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<u64>,
}

impl ItemSet {
    pub fn is_empty(&self) -> bool {
        self.text.is_none()
            && self.tool_call_id.is_none()
            && self.tool_name.is_none()
            && self.args.is_none()
            && self.output.is_none()
            && self.status.is_none()
            && self.duration_ms.is_none()
    }

    pub fn apply(&self, item: &mut Item) {
        if let Some(v) = &self.text {
            item.text = v.clone();
        }
        if let Some(v) = &self.tool_call_id {
            item.tool_call_id = Some(v.clone());
        }
        if let Some(v) = &self.tool_name {
            item.tool_name = Some(v.clone());
        }
        if let Some(v) = &self.args {
            item.args = Some(v.clone());
        }
        if let Some(v) = &self.output {
            item.output = Some(v.clone());
        }
        if let Some(v) = self.status {
            item.status = Some(v);
        }
        if let Some(v) = self.duration_ms {
            item.duration_ms = Some(v);
        }
    }
}

/// Text to append to an existing item while it streams.
#[derive(Debug, Clone, Default, Serialize)]
pub struct ItemAppend {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub args: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SessionStatus {
    Starting,
    Idle,
    Running,
    Compacting,
    /// A subagent that finished its task.
    Done,
    Stopped,
    Error,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SessionKind {
    Root,
    Subagent,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelInfo {
    pub provider: String,
    pub id: String,
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub context_window: Option<u64>,
    pub reasoning: bool,
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

#[derive(Debug, Clone, Serialize)]
pub struct ContextUsage {
    pub tokens: Option<u64>,
    pub window: u64,
    pub percent: Option<f64>,
}

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Queue {
    pub steering: Vec<String>,
    pub follow_up: Vec<String>,
}

/// A Prime thread goal still in force (active, paused, or out of budget): the agent keeps resuming work on it until
/// it is complete or cleared.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Goal {
    pub objective: String,
    /// `active`, `paused` or `budget_limited`.
    pub status: String,
    pub tokens_used: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub token_budget: Option<u64>,
    pub time_used_seconds: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_reason: Option<String>,
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

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionSummary {
    pub id: String,
    pub agent: AgentKind,
    pub kind: SessionKind,
    /// The session that spawned this subagent.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent_id: Option<String>,
    /// Subagent name (Prime `sessionName`, Pi agent name).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    pub depth: u32,
    pub running_subagents: bool,
    /// Pi subagents are views of a tool call and accept no commands.
    pub read_only: bool,
    pub cwd: String,
    pub title: String,
    pub status: SessionStatus,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    pub created_at: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<ModelInfo>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub thinking_level: Option<String>,
    pub thinking_levels: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub context: Option<ContextUsage>,
    pub cost: f64,
    pub queue: Queue,
    pub auto_compaction: bool,
    /// A context window chosen for this session, below the model's: `context` reports against it, and the bridge
    /// compacts the session when it nears it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub context_limit: Option<u64>,
    /// The window a session keeps to until it picks its own, when the model's full window costs more past it
    /// (GPT-6.1 Terra: 272k of 1M).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub standard_window: Option<u64>,
    /// Background commands still running (Prime's REPL `bash()`, Pi's background-jobs extension). They outlive the
    /// agent's turn and wake it when they finish, so an idle session with jobs is still at work.
    pub background_jobs: u32,
    /// The longest-running of them, which is usually what the session is waiting for.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub waiting_on: Option<WaitingOn>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stuck: Option<Stuck>,
    /// When a subagent last did anything or was sent anything (epoch ms). One left idle long enough is taken to be
    /// gone: Prime keeps finished subagents alive until it retires them.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_active_at: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub goal: Option<Goal>,
    /// What the agent asks the user (DeepSeek's ask_user_question and plan review): `{id, continued, questions:
    /// [{id, question, header?, detail?, options?: [{label, description?}], multiSelect?}]}`. `continued`: the agent
    /// stopped waiting and carried on, but still takes the answer.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub question: Option<Value>,
    /// Set on top-level sessions while they work through Open Codex, and kept once they settle.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub spend: Option<Spend>,
    /// Web servers the session's processes are listening on. Always sent, empty or not.
    pub sites: Vec<Site>,
}

/// What a session and its subagents spend, by Open Codex's request history.
#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Spend {
    /// Dollars a minute over the last five minutes of the run, when Open Codex prices its models.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub per_minute: Option<f64>,
    /// Tokens a minute over the same stretch. Both need half a minute of the run to say.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tokens_per_minute: Option<f64>,
    /// Dollars and tokens since the run started, at `since` (epoch ms).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub run_cost: Option<f64>,
    pub run_tokens: u64,
    pub since: u64,
}

/// A background command a session is waiting on.
#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct WaitingOn {
    pub command: String,
    /// Epoch ms.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub started_at: Option<u64>,
    /// Tells a command apart from a later run of the same one.
    #[serde(skip)]
    pub pid: Option<u32>,
}

/// A background command, as the agent's own TUI lists it.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BackgroundJob {
    pub id: String,
    pub command: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pid: Option<u32>,
    /// Epoch milliseconds.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub started_at: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<u64>,
    /// running, finished, or lost (Pi stopped without recording the exit).
    pub status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub exit_code: Option<i64>,
    /// Prime's persistent shells, which stay open between commands.
    pub persistent: bool,
    /// Why it looks stuck, when it does (see `Stuck`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stuck: Option<String>,
}

/// A web server an agent started in one of its sessions, found by the port its processes listen on.
#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Site {
    pub port: u16,
    /// The page's `<title>`, when it has one.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    /// What started it, as `ps` reports it.
    pub command: String,
    /// Where to open it: its tailnet address once published, else this Mac's.
    pub url: String,
    /// On the tailnet, over HTTPS, so another device can open it.
    pub published: bool,
    /// Bound to every interface rather than loopback: reachable from the LAN too, not only this Mac.
    pub exposed: bool,
    /// Why it isn't published, in words the apps show.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

/// A tool call or background command that has stood still long enough to look stuck, and why: macOS's permission
/// prompt, or the verdict of a model asked about it (`stallCheck` in config.json).
#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Stuck {
    /// "tool": the agent's current tool call. "command": a background command.
    pub kind: &'static str,
    pub command: String,
    /// One sentence for the reader: "macOS is probably asking for permission to read Documents".
    pub reason: String,
    /// How likely the model judged it stuck; none when the permission prompt was recognised from the folder.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub probability: Option<f64>,
    /// The background command's id, for cancelling it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub job_id: Option<String>,
    /// Epoch ms the command started.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub started_at: Option<u64>,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum ClientOp {
    ListSessions,
    /// Answered at once: the app's check that the connection still carries replies.
    Ping,
    CreateSession {
        agent: AgentKind,
        cwd: String,
        model: Option<String>,
        thinking: Option<String>,
    },
    Attach {
        #[serde(rename = "sessionId")]
        session_id: String,
    },
    Detach {
        #[serde(rename = "sessionId")]
        session_id: String,
    },
    Send {
        #[serde(rename = "sessionId")]
        session_id: String,
        text: String,
    },
    FollowUp {
        #[serde(rename = "sessionId")]
        session_id: String,
        text: String,
    },
    Abort {
        #[serde(rename = "sessionId")]
        session_id: String,
    },
    /// Stops a stuck tool call: the run ends, and messages queued behind the call are delivered so the agent goes on.
    StopTool {
        #[serde(rename = "sessionId")]
        session_id: String,
    },
    Compact {
        #[serde(rename = "sessionId")]
        session_id: String,
        instructions: Option<String>,
    },
    NewSession {
        #[serde(rename = "sessionId")]
        session_id: String,
    },
    ListModels {
        #[serde(rename = "sessionId")]
        session_id: String,
    },
    SetModel {
        #[serde(rename = "sessionId")]
        session_id: String,
        provider: String,
        #[serde(rename = "modelId")]
        model_id: String,
    },
    SetThinking {
        #[serde(rename = "sessionId")]
        session_id: String,
        level: String,
    },
    SetAutoCompaction {
        #[serde(rename = "sessionId")]
        session_id: String,
        enabled: bool,
    },
    ResumeSession {
        #[serde(rename = "sessionId")]
        session_id: String,
    },
    RenameSession {
        #[serde(rename = "sessionId")]
        session_id: String,
        name: String,
    },
    /// `None` goes back to the model's own window.
    SetContextLimit {
        #[serde(rename = "sessionId")]
        session_id: String,
        limit: Option<u64>,
    },
    /// Drop the session's goal, so the agent stops resuming work on it.
    ClearGoal {
        #[serde(rename = "sessionId")]
        session_id: String,
    },
    /// Kills the session's Python kernel and the commands it started; Prime starts a fresh one on the next call.
    RestartKernel {
        #[serde(rename = "sessionId")]
        session_id: String,
    },
    CloseSession {
        #[serde(rename = "sessionId")]
        session_id: String,
    },
    DeleteSession {
        #[serde(rename = "sessionId")]
        session_id: String,
    },
    ListJobs {
        #[serde(rename = "sessionId")]
        session_id: String,
    },
    JobOutput {
        #[serde(rename = "sessionId")]
        session_id: String,
        #[serde(rename = "jobId")]
        job_id: String,
        #[serde(default = "default_lines")]
        lines: u32,
    },
    KillJob {
        #[serde(rename = "sessionId")]
        session_id: String,
        #[serde(rename = "jobId")]
        job_id: String,
    },
    /// Answers to the question the session waits on, `[{id, selected, custom?}]`; none dismisses it.
    AnswerQuestion {
        #[serde(rename = "sessionId")]
        session_id: String,
        #[serde(rename = "questionId")]
        question_id: String,
        #[serde(default)]
        answers: Vec<Value>,
    },
    /// The items before `before`, the first one the client has.
    LoadEarlier {
        #[serde(rename = "sessionId")]
        session_id: String,
        before: String,
    },
    /// The models an agent can start a session on, as far as the bridge can tell; empty when it can't.
    ListAgentModels {
        agent: AgentKind,
    },
    /// Folders on the bridge's machine, for picking a working directory.
    ListDir {
        path: Option<String>,
        #[serde(default)]
        hidden: bool,
    },
    /// The git repositories the sessions work in, read with the machine's `git`: branches, uncommitted changes,
    /// recent commits and the user's commits per day. `paths` adds folders beyond the sessions'.
    GitOverview {
        #[serde(default)]
        paths: Vec<String>,
        #[serde(default = "default_days")]
        days: u32,
    },
    /// The GitHub account `gh` is signed in to on this computer: contributions per day over the last year and open
    /// pull requests.
    GithubOverview,
}

fn is_zero(n: &usize) -> bool {
    *n == 0
}

fn default_lines() -> u32 {
    80
}

fn default_days() -> u32 {
    182
}

#[derive(Debug, Deserialize)]
pub struct ClientMessage {
    pub id: Option<String>,
    #[serde(flatten)]
    pub op: ClientOp,
}

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ServerMessage {
    Reply {
        #[serde(skip_serializing_if = "Option::is_none")]
        id: Option<String>,
        ok: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        data: Option<Value>,
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },
    Sessions {
        sessions: Vec<SessionSummary>,
    },
    Session {
        session: Box<SessionSummary>,
    },
    SessionRemoved {
        #[serde(rename = "sessionId")]
        session_id: String,
    },
    Snapshot {
        #[serde(rename = "sessionId")]
        session_id: String,
        items: Vec<Item>,
        /// Older items left out, to fetch with `load_earlier`.
        #[serde(skip_serializing_if = "is_zero")]
        earlier: usize,
    },
    ItemAdd {
        #[serde(rename = "sessionId")]
        session_id: String,
        item: Item,
    },
    ItemPatch {
        #[serde(rename = "sessionId")]
        session_id: String,
        #[serde(rename = "itemId")]
        item_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        set: Option<ItemSet>,
        #[serde(skip_serializing_if = "Option::is_none")]
        append: Option<ItemAppend>,
    },
}
