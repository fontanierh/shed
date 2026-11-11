//! Wire types shared with the Swift clients (apps/Sources/ShedKit/Protocol.swift and ClientOp.swift). The tests below
//! and the apps' ProtocolFixtureTests and ClientOpTests read protocol/*.json, so a message or an operation one side
//! changes fails the other's tests.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::rpc::AgentKind;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(strum::EnumIter))]
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
#[cfg_attr(test, derive(strum::EnumIter))]
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
#[cfg_attr(test, derive(strum::EnumIter))]
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
#[cfg_attr(test, derive(strum::EnumIter))]
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
    /// Dollars since the run started.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub run_cost: Option<f64>,
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
    /// running, finished, or lost (Pi stopped without recording the exit). The agent's own word where it has one,
    /// passed on as it came, which is why it is not an enum.
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
/// What a session is stuck on.
#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum StuckKind {
    /// The agent's current tool call.
    Tool,
    /// A background command.
    Command,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Stuck {
    pub kind: StuckKind,
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
#[cfg_attr(test, derive(strum::VariantNames), strum(serialize_all = "snake_case"))]
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
        /// Names this message, so that sending it again after a lost reply does not send it twice. An app that
        /// sends none is taken at its word each time.
        #[serde(rename = "sendId", default, skip_serializing_if = "Option::is_none")]
        send_id: Option<String>,
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
    /// The branch of the repository `path` is in, read with the machine's `git`.
    GitBranch {
        path: String,
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

#[derive(Debug, Deserialize)]
pub struct ClientMessage {
    pub id: Option<String>,
    #[serde(flatten)]
    pub op: ClientOp,
}

/// The failures an app acts on rather than only shows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    /// The session is over and gone from the list: a subagent its agent has let go of.
    SessionEnded,
    /// The folder a session was to start in is not there.
    NoSuchDirectory,
}

/// What an app from before the codes compares the sentence with. It can never be reworded.
pub const SESSION_ENDED: &str = "session ended";

/// A failure with a code, answered as that code and its sentence.
#[derive(Debug)]
pub struct Failure {
    pub code: ErrorCode,
    message: String,
}

impl Failure {
    pub fn error(code: ErrorCode, message: impl Into<String>) -> anyhow::Error {
        anyhow::Error::new(Failure {
            code,
            message: message.into(),
        })
    }
}

impl std::fmt::Display for Failure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for Failure {}

/// What the bridge understands, sent with the list of sessions. It goes up when the bridge learns something an app
/// has to know before relying on it. A bridge that sends none is 1.
/// 2: a `send` with a `sendId` is taken once, however often it is sent.
pub const BRIDGE: u32 = 2;

#[derive(Debug, Clone, Serialize)]
#[cfg_attr(test, derive(strum::VariantNames), strum(serialize_all = "snake_case"))]
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
        /// Which failure it is, where an app does something about it. `error` stays the sentence to show.
        #[serde(skip_serializing_if = "Option::is_none")]
        code: Option<ErrorCode>,
    },
    Sessions {
        sessions: Vec<SessionSummary>,
        /// What this bridge understands, so an app can tell an older one: `BRIDGE`.
        bridge: u32,
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::collections::BTreeSet;
    use strum::{IntoEnumIterator, VariantNames};

    const SERVER_MESSAGES: &str = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../protocol/server_messages.json"
    );
    const CLIENT_OPS: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../protocol/client_ops.json");

    fn values<T: IntoEnumIterator + Serialize>() -> Value {
        T::iter().map(|value| json!(value)).collect()
    }

    fn bare_summary() -> SessionSummary {
        SessionSummary {
            id: "s1".into(),
            agent: AgentKind::Pi,
            kind: SessionKind::Root,
            parent_id: None,
            name: None,
            running_subagents: false,
            read_only: false,
            cwd: "/work/project".into(),
            title: "New session".into(),
            status: SessionStatus::Starting,
            error: None,
            created_at: 1_700_000_000_000,
            model: None,
            thinking_level: None,
            thinking_levels: vec![],
            context: None,
            cost: 0.0,
            queue: Queue::default(),
            auto_compaction: true,
            context_limit: None,
            standard_window: None,
            background_jobs: 0,
            waiting_on: None,
            stuck: None,
            last_active_at: None,
            goal: None,
            question: None,
            spend: None,
            sites: vec![],
        }
    }

    /// A summary with every optional field set, so the apps prove they read each one.
    fn full_summary() -> SessionSummary {
        SessionSummary {
            id: "s2".into(),
            agent: AgentKind::Prime,
            kind: SessionKind::Subagent,
            parent_id: Some("s1".into()),
            name: Some("reviewer".into()),
            running_subagents: true,
            read_only: true,
            status: SessionStatus::Running,
            error: Some("the model stopped answering".into()),
            model: Some(ModelInfo {
                provider: "example".into(),
                id: "model-1".into(),
                name: "Model One".into(),
                context_window: Some(400_000),
                reasoning: true,
            }),
            thinking_level: Some("high".into()),
            thinking_levels: vec!["low".into(), "high".into()],
            context: Some(ContextUsage {
                tokens: Some(50_000),
                window: 200_000,
                percent: Some(25.0),
            }),
            cost: 1.5,
            queue: Queue {
                steering: vec!["look at the tests".into()],
                follow_up: vec!["then open a pull request".into()],
            },
            auto_compaction: false,
            context_limit: Some(200_000),
            standard_window: Some(272_000),
            background_jobs: 2,
            waiting_on: Some(WaitingOn {
                command: "cargo test".into(),
                started_at: Some(1_700_000_001_000),
                pid: Some(4242),
            }),
            stuck: Some(Stuck {
                kind: StuckKind::Command,
                command: "cargo test".into(),
                reason: "It has printed nothing for ten minutes.".into(),
                probability: Some(0.75),
                job_id: Some("job-1".into()),
                started_at: Some(1_700_000_001_000),
            }),
            last_active_at: Some(1_700_000_002_000),
            goal: Some(Goal {
                objective: "Make the tests pass".into(),
                status: "active".into(),
                tokens_used: 12_000,
                token_budget: Some(100_000),
                time_used_seconds: 90,
                last_reason: Some("two tests still fail".into()),
            }),
            question: Some(json!({
                "id": "q1",
                "continued": false,
                "questions": [{
                    "id": "mode",
                    "question": "Which mode?",
                    "header": "Mode",
                    "detail": "A plan to review.",
                    "multiSelect": false,
                    "options": [{ "label": "Fast", "description": "Skips the slow checks." }],
                }],
            })),
            spend: Some(Spend {
                per_minute: Some(0.25),
                tokens_per_minute: Some(1500.0),
                run_cost: Some(0.5),
            }),
            sites: vec![Site {
                port: 5173,
                title: Some("Example".into()),
                command: "node".into(),
                url: "https://host.example.ts.net:5173/".into(),
                published: false,
                exposed: true,
                reason: Some("Tailscale isn't running on this computer".into()),
            }],
            ..bare_summary()
        }
    }

    fn tool_item() -> Item {
        Item {
            id: "i2".into(),
            tool_name: Some("bash".into()),
            args: Some("{\"command\":\"ls\"}".into()),
            output: Some("Cargo.toml".into()),
            status: Some(ToolStatus::Done),
            duration_ms: Some(120),
            at: Some(1_700_000_003_000),
            ..Item::new(ItemKind::Tool, "")
        }
    }

    fn server_messages() -> Vec<ServerMessage> {
        let text = Item {
            id: "i1".into(),
            ..Item::new(ItemKind::Text, "Done.")
        };
        vec![
            ServerMessage::Reply {
                id: Some("c1".into()),
                ok: true,
                data: Some(json!({ "branch": "main" })),
                error: None,
                code: None,
            },
            ServerMessage::Reply {
                id: Some("c2".into()),
                ok: false,
                data: None,
                error: Some("no such session".into()),
                code: None,
            },
            ServerMessage::Reply {
                id: Some("c3".into()),
                ok: false,
                data: None,
                error: Some(SESSION_ENDED.into()),
                code: Some(ErrorCode::SessionEnded),
            },
            ServerMessage::Sessions {
                sessions: vec![bare_summary(), full_summary()],
                bridge: BRIDGE,
            },
            ServerMessage::Session {
                session: Box::new(full_summary()),
            },
            ServerMessage::SessionRemoved {
                session_id: "s2".into(),
            },
            ServerMessage::Snapshot {
                session_id: "s1".into(),
                items: vec![text.clone(), tool_item()],
                earlier: 40,
            },
            ServerMessage::Snapshot {
                session_id: "s1".into(),
                items: vec![],
                earlier: 0,
            },
            ServerMessage::ItemAdd {
                session_id: "s1".into(),
                item: tool_item(),
            },
            ServerMessage::ItemPatch {
                session_id: "s1".into(),
                item_id: "i2".into(),
                set: Some(ItemSet {
                    text: Some("Done.".into()),
                    tool_name: Some("bash".into()),
                    args: Some("{}".into()),
                    output: Some("ok".into()),
                    status: Some(ToolStatus::Error),
                    duration_ms: Some(5),
                }),
                append: Some(ItemAppend {
                    text: Some(" More".into()),
                    args: Some("}".into()),
                }),
            },
            ServerMessage::ItemPatch {
                session_id: "s1".into(),
                item_id: "i1".into(),
                set: None,
                append: Some(ItemAppend {
                    text: Some(" more".into()),
                    args: None,
                }),
            },
        ]
    }

    /// Everything the bridge can send, as the apps' tests read it. `UPDATE_FIXTURES=1 cargo test` rewrites the file.
    #[test]
    fn server_messages_match_the_shared_fixture() {
        let messages = server_messages();
        let sent: BTreeSet<String> = messages
            .iter()
            .map(|message| json!(message)["type"].as_str().unwrap().to_string())
            .collect();
        let known: BTreeSet<String> = ServerMessage::VARIANTS
            .iter()
            .map(|name| name.to_string())
            .collect();
        assert_eq!(sent, known, "a message without an example");

        let fixture = json!({
            "enums": {
                "agent": values::<AgentKind>(),
                "itemKind": values::<ItemKind>(),
                "toolStatus": values::<ToolStatus>(),
                "sessionStatus": values::<SessionStatus>(),
                "sessionKind": values::<SessionKind>(),
            },
            "messages": messages,
        });
        let expected = serde_json::to_string_pretty(&fixture).unwrap() + "\n";
        if std::env::var_os("UPDATE_FIXTURES").is_some() {
            std::fs::write(SERVER_MESSAGES, &expected).unwrap();
        }
        assert_eq!(
            std::fs::read_to_string(SERVER_MESSAGES).unwrap(),
            expected,
            "protocol/server_messages.json is out of date: run UPDATE_FIXTURES=1 cargo test, then the apps' tests"
        );
    }

    /// Every operation, as the apps send it.
    #[test]
    fn client_ops_in_the_shared_fixture_parse() {
        let ops: Vec<Value> =
            serde_json::from_str(&std::fs::read_to_string(CLIENT_OPS).unwrap()).unwrap();
        let mut seen = BTreeSet::new();
        for op in ops {
            let parsed: ClientMessage =
                serde_json::from_value(op.clone()).unwrap_or_else(|error| panic!("{op}: {error}"));
            assert!(parsed.id.is_some(), "{op} has no id");
            seen.insert(op["op"].as_str().unwrap().to_string());
        }
        let known: BTreeSet<String> = ClientOp::VARIANTS
            .iter()
            .map(|name| name.to_string())
            .collect();
        assert_eq!(seen, known, "an operation without an example");
    }
}
