//! Agent sessions: Pi sessions are bridge-owned RPC children; Prime sessions (and their subagents)
//! live in Prime's daemon and are mirrored from its roster; Pi subagents are read-only views of the
//! parent's `subagent` tool call.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{anyhow, bail, Context, Result};
use serde_json::{json, Value};
use tokio::sync::{broadcast, mpsc, Mutex, RwLock};

use crate::history::{self, History};
use crate::prime::{DaemonEvent, PrimeDaemon};
use crate::protocol::{
    ContextUsage, Goal, Item, ItemKind, ModelInfo, Queue, ServerMessage, SessionKind,
    SessionStatus, SessionSummary, Spend, WaitingOn,
};
use crate::rpc::{AgentKind, ChildOutput, RpcChild, SpawnOptions};
use crate::store::{SessionRecord, Store};
use crate::transcript::{Change, Transcript};

const ALL_LEVELS: [&str; 7] = ["off", "minimal", "low", "medium", "high", "xhigh", "max"];

/// A serialized server message. Session-scoped ones carry that session's sequence number so a
/// client that just received a snapshot can drop events the snapshot already contains.
pub struct Envelope {
    pub session_id: Option<String>,
    pub seq: u64,
    pub json: Arc<str>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Backend {
    /// `pi --mode rpc` child owned by the bridge.
    Pi,
    /// A session in Prime's daemon, addressed by its active-session id.
    Prime,
    /// One child of a Pi `subagent` tool call.
    PiSubagent,
}

pub struct App {
    pub token: String,
    pub sessions: RwLock<Vec<Arc<Session>>>,
    pub hub: broadcast::Sender<Arc<Envelope>>,
    prime: Arc<PrimeDaemon>,
    pub(crate) store: Store,
    /// Registry saves run one at a time, each from the list as it is then, so an older save can't land last.
    saving: Mutex<()>,
    /// Context windows chosen per session (see `SessionSummary::context_limit`).
    limits: std::sync::Mutex<HashMap<String, u64>>,
    /// When the bridge last asked a session to compact for its limit, so one crossing asks once.
    compacting_for_limit: std::sync::Mutex<HashMap<String, Instant>>,
    /// Prime sessions' spending, subagents included, read from their session files.
    costs: crate::cost::Costs,
}

/// Room left for the next turn when compacting for a chosen window, as Pi's own auto-compaction leaves (16k), but
/// never more than a fifth of a small window.
fn compaction_reserve(window: u64) -> u64 {
    16_384.min(window / 5)
}

pub struct Session {
    pub id: String,
    pub agent: AgentKind,
    pub backend: Backend,
    pub cwd: String,
    pub state: Mutex<SessionState>,
}

pub struct SessionState {
    pub summary: SessionSummary,
    pub transcript: Transcript,
    pub seq: u64,
    child: Option<Arc<RpcChild>>,
    /// Prime: attached to the daemon, so its events arrive and the transcript is live.
    attached: bool,
    session_file: Option<String>,
    named: bool,
    stopping: bool,
    /// Deleted: late events (a Pi child exiting after the delete) must not publish it again.
    removed: bool,
    refresh_scheduled: bool,
    levels_for: Option<String>,
    /// Prime roster fields whose change warrants a stats refresh.
    roster_mark: (String, u64),
    /// Pi subagents: transcript length last sent, to avoid resending unchanged snapshots.
    sent_messages: usize,
    /// Prime: the conversation's `sessionId`, which outlives the `activeSessionId` the bridge knows it by (a reopened
    /// session gets a new one). What its chosen context window is saved under.
    prime_session: Option<String>,
    /// What Open Codex counted for the session (with its subagents, for Prime): its agent reports nothing for models
    /// Open Codex prices, so this is the least the session has cost.
    gateway_cost: f64,
    /// Prime: the worker process running this session, for counting its background jobs.
    pub(crate) worker_pid: Option<u32>,
    /// Prime: running a tool call, which one (Prime's count of calls so far) and since when.
    tools: Option<(u64, Instant)>,
    /// Watching what the session waits on for a stall.
    stall: crate::stall::Tracker,
    /// Prime: the conversation before the last compaction, which the daemon no longer returns.
    history: Option<Arc<History>>,
}

/// What the stall check is told about a suspect target.
struct StallContext {
    command: String,
    output: String,
    job_id: Option<String>,
    /// What the agent wrote just before the call, for what it meant the command to do.
    said: Option<String>,
}

/// The agent's last words before the item at `at`: its text, or else its thinking.
fn said_before(items: &[crate::protocol::Item], at: usize) -> Option<String> {
    use crate::protocol::ItemKind;
    items[..at]
        .iter()
        .rev()
        .take_while(|i| i.kind != ItemKind::User)
        .find(|i| {
            matches!(i.kind, ItemKind::Text | ItemKind::Thinking) && !i.text.trim().is_empty()
        })
        .map(|i| {
            let text = i.text.trim();
            let start = text.len().saturating_sub(1500);
            let start = (start..=text.len())
                .find(|&b| text.is_char_boundary(b))
                .unwrap_or(0);
            text[start..].to_string()
        })
}

/// The code of a Python tool call, or the arguments of any other.
fn tool_code(item: &crate::protocol::Item) -> String {
    let args = item.args.clone().unwrap_or_default();
    serde_json::from_str::<Value>(&args)
        .ok()
        .and_then(|v| {
            v["code"]
                .as_str()
                .or(v["command"].as_str())
                .map(str::to_string)
        })
        .unwrap_or(args)
}

/// One line per stopped loop in ~/.agent-remote/logs/loops.jsonl, with what was streaming, to tell why models loop.
fn log_loop(
    session_id: &str,
    summary: &SessionSummary,
    reason: &str,
    sample: &crate::runaway::LoopSample,
) {
    use std::io::Write;
    let line = json!({
        "at": now_ms(),
        "session": session_id,
        "title": summary.title,
        "model": summary.model.as_ref().map(|m| &m.id),
        "effort": summary.thinking_level,
        "contextTokens": summary.context.as_ref().and_then(|c| c.tokens),
        "reason": reason,
        "sample": sample,
    });
    let path = std::path::PathBuf::from(std::env::var("HOME").unwrap_or_default())
        .join(".agent-remote/logs/loops.jsonl");
    if let Ok(mut file) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
    {
        let _ = writeln!(file, "{line}");
    }
}

pub(crate) fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// Parses `2026-10-30T09:49:57.304Z` into epoch milliseconds.
pub fn parse_iso_ms(s: &str) -> Option<u64> {
    let (date, time) = s.trim_end_matches('Z').split_once('T')?;
    let mut d = date.split('-').map(|p| p.parse::<i64>().ok());
    let (y, m, day) = (d.next()??, d.next()??, d.next()??);
    let (hms, frac) = time.split_once('.').unwrap_or((time, "0"));
    let mut t = hms.split(':').map(|p| p.parse::<i64>().ok());
    let (hh, mm, ss) = (t.next()??, t.next()??, t.next()??);
    let ms: i64 = format!("{frac:0<3}")[..3].parse().ok()?;
    // Days from civil (Howard Hinnant).
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146097 + doe - 719468;
    Some(((days * 86400 + hh * 3600 + mm * 60 + ss) * 1000 + ms) as u64)
}

fn default_title(cwd: &str) -> String {
    std::path::Path::new(cwd)
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| cwd.to_string())
}

fn first_line(text: &str, max: usize) -> String {
    text.lines()
        .find(|l| !l.trim().is_empty())
        .unwrap_or("")
        .trim()
        .chars()
        .take(max)
        .collect()
}

fn queue_texts(v: &Value) -> Vec<String> {
    let Some(entries) = v.as_array() else {
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

fn to_json(msg: &ServerMessage) -> Arc<str> {
    serde_json::to_string(msg)
        .expect("server messages serialize")
        .into()
}

fn new_summary(id: &str, agent: AgentKind, kind: SessionKind, cwd: &str) -> SessionSummary {
    SessionSummary {
        id: id.to_string(),
        agent,
        kind,
        parent_id: None,
        name: None,
        running_subagents: false,
        read_only: false,
        cwd: cwd.to_string(),
        title: default_title(cwd),
        status: SessionStatus::Starting,
        error: None,
        created_at: now_ms(),
        model: None,
        thinking_level: None,
        thinking_levels: Vec::new(),
        context: None,
        cost: 0.0,
        queue: Queue::default(),
        auto_compaction: true,
        background_jobs: 0,
        waiting_on: None,
        stuck: None,
        context_limit: None,
        standard_window: None,
        last_active_at: None,
        goal: None,
        question: None,
        spend: None,
        sites: Vec::new(),
    }
}

impl SessionState {
    fn new(summary: SessionSummary, session_file: Option<String>) -> SessionState {
        SessionState {
            summary,
            transcript: Transcript::default(),
            seq: 0,
            child: None,
            attached: false,
            session_file,
            named: false,
            stopping: false,
            removed: false,
            refresh_scheduled: false,
            levels_for: None,
            roster_mark: (String::new(), 0),
            sent_messages: usize::MAX,
            prime_session: None,
            gateway_cost: 0.0,
            worker_pid: None,
            tools: None,
            stall: Default::default(),
            history: None,
        }
    }

    /// History applies while the current context starts with the summary that cut it off.
    fn earlier(&self) -> &[Item] {
        match (&self.history, self.transcript.items.first()) {
            (Some(history), Some(first)) if first.kind == ItemKind::Compaction => &history.items,
            _ => &[],
        }
    }

    /// What a client opening the session gets: the end of the history and the current context.
    fn snapshot(&self, session_id: &str) -> ServerMessage {
        let earlier = self.earlier();
        let start = earlier.len().saturating_sub(history::PAGE);
        let mut items = earlier[start..].to_vec();
        items.extend(self.transcript.items.iter().cloned());
        ServerMessage::Snapshot {
            session_id: session_id.to_string(),
            items,
            earlier: start,
        }
    }

    /// Up to a page of the history items just before `before`, and how many remain before those.
    pub fn earlier_page(&self, before: &str) -> (Vec<Item>, usize) {
        let earlier = self.earlier();
        let end = earlier.iter().position(|i| i.id == before).unwrap_or(0);
        let start = end.saturating_sub(history::PAGE);
        (earlier[start..end].to_vec(), start)
    }
}

impl Session {
    /// The pid of the agent process this session runs in, for finding the ports it listens on.
    pub async fn pid(&self) -> Option<u32> {
        let child = self.state.lock().await.child.clone();
        child.as_ref().and_then(|child| child.pid())
    }
}

impl App {
    pub fn new(store: Store) -> Result<Arc<App>> {
        let token = store.token()?;
        let (prime, prime_events) = PrimeDaemon::start(store.client_id()?);
        let (hub, _) = broadcast::channel(4096);
        let sessions = store
            .load_sessions()
            .into_iter()
            .map(|r| {
                let mut summary = new_summary(&r.id, r.agent, SessionKind::Root, &r.cwd);
                summary.title = r.title.clone();
                summary.status = SessionStatus::Stopped;
                summary.created_at = r.created_at;
                let mut state = SessionState::new(summary, r.session_file);
                state.named = r.title != default_title(&r.cwd);
                Arc::new(Session {
                    id: r.id,
                    agent: r.agent,
                    backend: Backend::Pi,
                    cwd: r.cwd,
                    state: Mutex::new(state),
                })
            })
            .collect();
        let limits = std::sync::Mutex::new(store.load_limits());
        let app = Arc::new(App {
            token,
            sessions: RwLock::new(sessions),
            hub,
            prime,
            store,
            saving: Mutex::new(()),
            limits,
            compacting_for_limit: std::sync::Mutex::new(HashMap::new()),
            costs: crate::cost::Costs::default(),
        });
        tokio::spawn(app.clone().run_prime(prime_events));
        tokio::spawn(app.clone().watch_background_jobs());
        tokio::spawn(app.clone().watch_spend());
        tokio::spawn(app.clone().watch_sites());
        Ok(app)
    }

    pub async fn find(&self, id: &str) -> Result<Arc<Session>> {
        self.sessions
            .read()
            .await
            .iter()
            .find(|s| s.id == id)
            .cloned()
            .ok_or_else(|| anyhow!("unknown session {id}"))
    }

    pub async fn summaries(&self) -> Vec<SessionSummary> {
        let sessions = self.sessions.read().await.clone();
        let mut out = Vec::with_capacity(sessions.len());
        for s in sessions {
            out.push(s.state.lock().await.summary.clone());
        }
        out
    }

    /// Replaces each session's sites with the ones it serves now, and forgets the sites of every other session.
    /// Wholesale rather than one at a time: a server that moves to another port must not leave the old one listed.
    pub async fn set_sites(
        &self,
        found: std::collections::HashMap<String, Vec<crate::protocol::Site>>,
    ) {
        for session in self.sessions.read().await.clone() {
            let sites = found.get(&session.id).cloned().unwrap_or_default();
            let mut st = session.state.lock().await;
            if st.summary.sites == sites {
                continue;
            }
            st.summary.sites = sites;
            self.publish_summary(&st);
        }
    }

    pub fn broadcast_global(&self, msg: &ServerMessage) {
        let _ = self.hub.send(Arc::new(Envelope {
            session_id: None,
            seq: 0,
            json: to_json(msg),
        }));
    }

    fn broadcast_session(&self, session_id: &str, st: &mut SessionState, msg: &ServerMessage) {
        st.seq += 1;
        let envelope = Envelope {
            session_id: Some(session_id.to_string()),
            seq: st.seq,
            json: to_json(msg),
        };
        let _ = self.hub.send(Arc::new(envelope));
    }

    fn publish_summary(&self, st: &SessionState) {
        if st.removed {
            return;
        }
        self.broadcast_global(&ServerMessage::Session {
            session: Box::new(st.summary.clone()),
        });
    }

    fn flush_changes(&self, session_id: &str, st: &mut SessionState) {
        for change in st.transcript.take_changes() {
            let msg = match change {
                Change::Add(item) => ServerMessage::ItemAdd {
                    session_id: session_id.to_string(),
                    item,
                },
                Change::Patch {
                    item_id,
                    set,
                    append,
                } => ServerMessage::ItemPatch {
                    session_id: session_id.to_string(),
                    item_id,
                    set,
                    append,
                },
            };
            self.broadcast_session(session_id, st, &msg);
        }
    }

    fn send_snapshot(&self, session_id: &str, st: &mut SessionState) {
        let msg = st.snapshot(session_id);
        self.broadcast_session(session_id, st, &msg);
    }

    async fn remove(&self, id: &str) {
        let removed: Vec<Arc<Session>> = {
            let mut sessions = self.sessions.write().await;
            let gone = sessions.iter().filter(|s| s.id == id).cloned().collect();
            sessions.retain(|s| s.id != id);
            gone
        };
        for session in removed {
            session.state.lock().await.removed = true;
        }
        self.broadcast_global(&ServerMessage::SessionRemoved {
            session_id: id.to_string(),
        });
    }

    /// Persist the registry of Pi sessions. Never call while holding a session lock.
    pub async fn save_registry(self: Arc<Self>) {
        let _saving = self.saving.lock().await;
        let sessions = self.sessions.read().await.clone();
        let mut records = Vec::new();
        for s in sessions.iter().filter(|s| s.backend == Backend::Pi) {
            let st = s.state.lock().await;
            if st.removed {
                continue;
            }
            records.push(SessionRecord {
                id: s.id.clone(),
                agent: s.agent,
                cwd: s.cwd.clone(),
                title: st.summary.title.clone(),
                created_at: st.summary.created_at,
                session_file: st.session_file.clone(),
            });
        }
        if let Err(e) = self.store.save_sessions(&records) {
            eprintln!("failed to save session registry: {e}");
        }
    }

    /// Run an agent command against a session, whichever backend owns it.
    pub async fn command(&self, session: &Session, kind: &str, fields: Value) -> Result<Value> {
        match session.backend {
            Backend::Pi => self.child(session).await?.send(kind, fields).await,
            Backend::Prime => self.prime.session(&session.id, kind, fields).await,
            Backend::PiSubagent => {
                bail!("Pi subagents are read-only; steer the parent session instead")
            }
        }
    }

    async fn child(&self, session: &Session) -> Result<Arc<RpcChild>> {
        session
            .state
            .lock()
            .await
            .child
            .clone()
            .ok_or_else(|| anyhow!("session is not running"))
    }

    // ---- creating and stopping ----

    pub async fn create_session(
        self: &Arc<Self>,
        agent: AgentKind,
        cwd: String,
        model: Option<String>,
        thinking: Option<String>,
    ) -> Result<SessionSummary> {
        let cwd = expand_dir(&cwd)?;
        if agent == AgentKind::Prime {
            let row = self
                .prime
                .create(&cwd, model.as_deref(), thinking.as_deref())
                .await?;
            let session = self
                .apply_prime_row(&row)
                .await
                .ok_or_else(|| anyhow!("Prime returned no session id"))?;
            self.refresh(&session).await?;
            let summary = session.state.lock().await.summary.clone();
            return Ok(summary);
        }
        let id = uuid::Uuid::new_v4().simple().to_string()[..8].to_string();
        let summary = new_summary(&id, agent, SessionKind::Root, &cwd);
        let session = Arc::new(Session {
            id,
            agent,
            backend: Backend::Pi,
            cwd,
            state: Mutex::new(SessionState::new(summary, None)),
        });
        self.sessions.write().await.push(session.clone());
        self.start_pi(&session, None, model, thinking).await?;
        tokio::spawn(self.clone().save_registry());
        let summary = session.state.lock().await.summary.clone();
        Ok(summary)
    }

    pub async fn resume_session(
        self: &Arc<Self>,
        session: &Arc<Session>,
    ) -> Result<SessionSummary> {
        if session.backend != Backend::Pi {
            bail!("only Pi sessions can be resumed; Prime sessions stay live in its daemon");
        }
        let resume = {
            let st = session.state.lock().await;
            if st.child.is_some() {
                bail!("session is already running");
            }
            st.session_file
                .clone()
                .ok_or_else(|| anyhow!("session has no saved transcript to resume"))?
        };
        self.start_pi(session, Some(resume), None, None).await?;
        let summary = session.state.lock().await.summary.clone();
        Ok(summary)
    }

    async fn start_pi(
        self: &Arc<Self>,
        session: &Arc<Session>,
        resume: Option<String>,
        model: Option<String>,
        thinking: Option<String>,
    ) -> Result<()> {
        // Where Pi's background-jobs extension keeps this session's jobs, for listing and cancelling them here.
        // The guide as a file, for the subagents Pi starts: they get no system prompt from the bridge.
        let guide = self.store.dir().join("guide.md");
        let _ = std::fs::write(&guide, crate::guide::text(crate::rpc::AgentKind::Pi));
        let env = vec![
            (
                "AGENT_REMOTE_JOBS_DIR".to_string(),
                crate::jobs::pi_dir(&session.id)
                    .to_string_lossy()
                    .into_owned(),
            ),
            (
                "AGENT_REMOTE_GUIDE".to_string(),
                guide.to_string_lossy().into_owned(),
            ),
        ];
        let opts = SpawnOptions {
            agent: session.agent,
            cwd: session.cwd.clone(),
            model,
            thinking,
            resume,
            env,
        };
        let spawned = RpcChild::spawn(&opts);
        let (child, rx) = {
            let mut st = session.state.lock().await;
            match spawned {
                Ok(pair) => {
                    st.child = Some(pair.0.clone());
                    st.stopping = false;
                    st.summary.status = SessionStatus::Starting;
                    st.summary.error = None;
                    self.publish_summary(&st);
                    pair
                }
                Err(e) => {
                    st.summary.status = SessionStatus::Error;
                    st.summary.error = Some(e.to_string());
                    self.publish_summary(&st);
                    return Err(e);
                }
            }
        };
        tokio::spawn(self.clone().run_pi_events(session.clone(), child, rx));
        let started = async {
            self.resnapshot(session).await?;
            self.refresh(session).await
        }
        .await;
        if let Err(e) = &started {
            let mut st = session.state.lock().await;
            st.summary.status = SessionStatus::Error;
            st.summary.error = Some(e.to_string());
            self.publish_summary(&st);
        }
        started
    }

    pub async fn close_session(&self, session: &Session) -> Result<()> {
        match session.backend {
            Backend::Pi => {
                let child = {
                    let mut st = session.state.lock().await;
                    st.stopping = true;
                    st.child.clone()
                };
                if let Some(child) = child {
                    child.close().await;
                }
                Ok(())
            }
            Backend::Prime => {
                let out = tokio::process::Command::new("prime-agent")
                    .args(["stop", &session.id])
                    .output()
                    .await?;
                let stderr = String::from_utf8_lossy(&out.stderr);
                // An empty draft (e.g. right after new_session) has no worker to stop.
                if !out.status.success() && !stderr.contains("Unknown active session") {
                    bail!("prime-agent stop failed: {}", stderr.trim());
                }
                Ok(())
            }
            Backend::PiSubagent => bail!("Pi subagents end with their tool call"),
        }
    }

    pub async fn delete_session(self: &Arc<Self>, session: &Arc<Session>) -> Result<()> {
        let key = limit_key(session, &*session.state.lock().await).to_string();
        self.forget_limit(&key);
        self.compacting_for_limit
            .lock()
            .unwrap()
            .remove(&session.id);
        match session.backend {
            Backend::Prime => return self.close_session(session).await,
            Backend::Pi => self.close_session(session).await?,
            Backend::PiSubagent => {}
        }
        // Its subagents and theirs: dsh nests them.
        let mut subagents = Vec::new();
        let all = self.sessions.read().await.clone();
        for s in all.iter().filter(|s| s.backend == Backend::PiSubagent) {
            subagents.push((s.id.clone(), s.state.lock().await.summary.parent_id.clone()));
        }
        let mut family = vec![session.id.clone()];
        let mut i = 0;
        while i < family.len() {
            let parent = family[i].clone();
            family.extend(
                subagents
                    .iter()
                    .filter(|s| s.1.as_deref() == Some(parent.as_str()))
                    .map(|s| s.0.clone()),
            );
            i += 1;
        }
        for id in family.iter().skip(1) {
            self.remove(id).await;
        }
        crate::jobs::forget(&session.id);
        self.remove(&session.id).await;
        tokio::spawn(self.clone().save_registry());
        Ok(())
    }

    pub async fn shutdown(&self) {
        let sessions = self.sessions.read().await.clone();
        for s in sessions.iter().filter(|s| s.backend == Backend::Pi) {
            let _ = self.close_session(s).await;
        }
    }

    // ---- events ----

    async fn run_pi_events(
        self: Arc<Self>,
        session: Arc<Session>,
        child: Arc<RpcChild>,
        mut rx: mpsc::UnboundedReceiver<ChildOutput>,
    ) {
        while let Some(output) = rx.recv().await {
            match output {
                ChildOutput::Event(event) => self.handle_event(&session, &event).await,
                ChildOutput::Exited(reason) => {
                    let mut st = session.state.lock().await;
                    if st.child.as_ref().is_some_and(|c| Arc::ptr_eq(c, &child)) {
                        st.child = None;
                        st.summary.question = None;
                        if st.stopping {
                            st.summary.status = SessionStatus::Stopped;
                        } else {
                            st.summary.status = SessionStatus::Error;
                            st.summary.error = Some(reason);
                        }
                        self.publish_summary(&st);
                    }
                    break;
                }
            }
        }
    }

    /// What each working session spends, from Open Codex's request history: each session's own requests, counted as
    /// they're made, give its cost; a top-level session's family (it and everything under it) gives what the run has
    /// spent and its rate over the last five minutes. A run starts when a top-level session gets to work and ends when
    /// it and its subagents settle, after one last count. Sessions on other providers keep the cost their agent reports.
    async fn watch_spend(self: Arc<Self>) {
        const WINDOW: u64 = 5 * 60 * 1000;
        let mut ticker = tokio::time::interval(Duration::from_secs(10));
        let mut tallies: HashMap<String, crate::opencodex::Tally> = HashMap::new();
        // The last failure logged: one that lasts (no admin token yet) is said once, not every ten seconds.
        let mut logged = String::new();
        // Per top-level session: the family's totals when the run started, and its recent (time, cost, tokens).
        let mut runs: HashMap<String, (u64, f64, u64)> = HashMap::new();
        let mut samples: HashMap<String, std::collections::VecDeque<(u64, f64, u64)>> =
            HashMap::new();
        loop {
            ticker.tick().await;
            let Some(gateway) = crate::opencodex::gateway() else {
                continue;
            };
            let sessions = self.sessions.read().await.clone();
            // (session, parent, working, the id it sends Open Codex, whether its model is Open Codex's)
            let mut rows = Vec::with_capacity(sessions.len());
            for s in &sessions {
                let st = s.state.lock().await;
                let working = matches!(
                    st.summary.status,
                    SessionStatus::Starting | SessionStatus::Running | SessionStatus::Compacting
                ) || st.summary.running_subagents
                    || st.summary.background_jobs > 0;
                let gateway_model = st
                    .summary
                    .model
                    .as_ref()
                    .is_some_and(|m| m.provider == crate::opencodex::PROVIDER);
                rows.push((
                    s.clone(),
                    st.summary.parent_id.clone(),
                    working,
                    agent_session_id(s.agent, &st),
                    gateway_model,
                ));
            }
            let now = now_ms();
            for top in rows.iter().filter(|r| r.1.is_none()) {
                let session = &top.0;
                let ended = if top.2 {
                    false
                } else if runs.contains_key(&session.id) {
                    true
                } else {
                    continue;
                };
                // The session and everything under it.
                let mut family = vec![session.id.clone()];
                let mut i = 0;
                while i < family.len() {
                    let id = family[i].clone();
                    family.extend(
                        rows.iter()
                            .filter(|r| r.1.as_deref() == Some(id.as_str()))
                            .map(|r| r.0.id.clone()),
                    );
                    i += 1;
                }
                let members: Vec<_> = rows.iter().filter(|r| family.contains(&r.0.id)).collect();
                let mut failed = false;
                for member in &members {
                    let Some(conversation) =
                        member.3.as_deref().map(crate::opencodex::conversation)
                    else {
                        continue;
                    };
                    if let Err(e) = tallies
                        .entry(conversation.clone())
                        .or_default()
                        .update(&gateway, &conversation)
                        .await
                    {
                        let e = e.to_string();
                        if e != logged {
                            eprintln!("Open Codex spend: {e}");
                            logged = e;
                        }
                        failed = true;
                        break;
                    }
                }
                if failed {
                    continue;
                }
                let own = |r: &(Arc<Session>, Option<String>, bool, Option<String>, bool)| {
                    r.3.as_deref()
                        .and_then(|id| tallies.get(&crate::opencodex::conversation(id)))
                        .copied()
                        .unwrap_or_default()
                };
                let (cost, tokens, priced) = members
                    .iter()
                    .map(|m| own(m))
                    .fold((0.0, 0, false), |acc, t| {
                        (acc.0 + t.cost, acc.1 + t.tokens, acc.2 || t.priced)
                    });
                let run = *runs
                    .entry(session.id.clone())
                    .or_insert((now, cost, tokens));
                let recent = samples.entry(session.id.clone()).or_default();
                recent.push_back((now, cost, tokens));
                // Keep the last sample before the window as its baseline.
                while recent.len() > 1 && now - recent[1].0 >= WINDOW {
                    recent.pop_front();
                }
                let base = recent[0];
                // Under half a minute of history says little about a rate.
                let minutes = (now - base.0) as f64 / 60_000.0;
                let spend = Spend {
                    per_minute: (priced && minutes >= 0.5)
                        .then(|| (cost - base.1).max(0.0) / minutes),
                    // A family that lost a member counts fewer tokens than before: never below zero.
                    tokens_per_minute: (minutes >= 0.5)
                        .then(|| tokens.saturating_sub(base.2) as f64 / minutes),
                    run_cost: priced.then(|| (cost - run.1).max(0.0)),
                };
                if ended {
                    runs.remove(&session.id);
                    samples.remove(&session.id);
                }
                for member in &members {
                    let mut st = member.0.state.lock().await;
                    let mut changed = false;
                    // Prime counts what its subagents spend into their parent; Pi's and dsh's add up in the apps.
                    let tally = own(member);
                    let figure = if member.0.id == session.id && session.agent == AgentKind::Prime {
                        cost
                    } else {
                        tally.cost
                    };
                    if member.4 && (tally.priced || priced) && st.gateway_cost != figure {
                        st.gateway_cost = figure;
                        st.summary.cost = st.summary.cost.max(figure);
                        changed = true;
                    }
                    if member.0.id == session.id && st.summary.spend.as_ref() != Some(&spend) {
                        st.summary.spend = Some(spend.clone());
                        changed = true;
                    }
                    if changed {
                        self.publish_summary(&st);
                    }
                }
            }
        }
    }

    /// Background commands keep running after the agent ends its turn and wake it when they finish. Pi's
    /// background-jobs extension records them in the session's jobs folder. Prime's REPL jobs (`h = bash(...)`) are
    /// in the daemon's kernel bash list, but polling it would wake idle workers, so count the commands running under
    /// each live worker's REPL kernel (`python -m rlm.repl`) instead; the list is fetched when asked for.
    async fn watch_background_jobs(self: Arc<Self>) {
        let mut ticker = tokio::time::interval(Duration::from_secs(2));
        let home = crate::jobs::home();
        loop {
            ticker.tick().await;
            let sessions: Vec<Arc<Session>> = self
                .sessions
                .read()
                .await
                .iter()
                .filter(|s| matches!(s.backend, Backend::Pi | Backend::Prime))
                .cloned()
                .collect();
            if sessions.is_empty() {
                continue;
            }
            // Also tells a command stuck on macOS's permission prompt, Pi's included.
            let tree = crate::jobs::ProcessTree::snapshot().await;
            for session in sessions {
                // DeepSeek reports its own background commands as events.
                if session.agent == AgentKind::Deepseek {
                    continue;
                }
                let (jobs, waiting) = match session.backend {
                    Backend::Pi => crate::jobs::pi_running(&session.id, tree.as_ref()),
                    _ => {
                        let worker = session.state.lock().await.worker_pid;
                        let (Some(worker), Some(tree)) = (worker, &tree) else {
                            continue;
                        };
                        (
                            tree.kernel_jobs(worker).len() as u32,
                            tree.kernel_waiting_on(worker, now_ms(), &home),
                        )
                    }
                };
                if let Some(tree) = &tree {
                    self.watch_for_stall(&session, tree, waiting.as_ref(), &home)
                        .await;
                }
                self.set_background_jobs(&session, jobs, waiting).await;
            }
        }
    }

    /// Follows what a session waits on, its tool call or else its longest-running background command, and finds
    /// out why once it has stood still long enough (see `stall`). The verdict shows in the summary as `stuck`.
    async fn watch_for_stall(
        self: &Arc<Self>,
        session: &Arc<Session>,
        tree: &crate::jobs::ProcessTree,
        waiting: Option<&WaitingOn>,
        home: &str,
    ) {
        use crate::stall::{Step, Target};
        let mut st = session.state.lock().await;
        let tool = st.tools.zip(st.worker_pid.and_then(|w| tree.kernel_of(w)));
        let (target, age) = match (tool, waiting) {
            (Some(((calls, since), kernel)), _) => (
                Some(Target {
                    kind: "tool",
                    pid: kernel,
                    id: format!("call {calls}"),
                }),
                since.elapsed(),
            ),
            (
                None,
                Some(WaitingOn {
                    pid: Some(pid),
                    command,
                    started_at,
                    ..
                }),
            ) => (
                Some(Target {
                    kind: "command",
                    pid: *pid,
                    id: command.clone(),
                }),
                Duration::from_millis(now_ms().saturating_sub(started_at.unwrap_or(u64::MAX))),
            ),
            _ => (None, Duration::ZERO),
        };
        let cpu = target.as_ref().map_or(0.0, |t| tree.subtree_cpu(t.pid));
        let step = st.stall.observe(target.clone(), cpu, age, Instant::now());
        if st.summary.stuck != st.stall.verdict {
            st.summary.stuck = st.stall.verdict.clone();
            self.publish_summary(&st);
        }
        let (Step::Suspect, Some(target)) = (step, target) else {
            return;
        };
        // What can be told from here: a process stuck on a protected folder it names.
        let folder = tree.permission_prompt(target.pid, home);
        let lone_kernel = target.kind == "tool" && !tree.has_children(target.pid);
        let processes = tree.processes(target.pid);
        let cwd = st.summary.cwd.clone();
        let started_at = now_ms().saturating_sub(age.as_millis() as u64);
        drop(st);
        let app = self.clone();
        let session = session.clone();
        let home = home.to_string();
        tokio::spawn(async move {
            let StallContext {
                command,
                output,
                job_id,
                said,
            } = app.stall_context(&session, &target).await;
            // The kernel itself, reading a protected folder in Python.
            let folder = folder.or(if lone_kernel {
                crate::jobs::protected_folder(&command, &home)
            } else {
                None
            });
            let verdict = match (folder, app.store.stall_check()) {
                (Some(folder), _) => Some(crate::stall::Verdict {
                    probability: f64::NAN,
                    reason: crate::jobs::permission_reason(folder),
                }),
                (None, Some(judge)) => {
                    let question = crate::stall::Question {
                        kind: target.kind,
                        command: command.clone(),
                        running_secs: age.as_secs(),
                        cwd,
                        processes,
                        output,
                        said,
                    };
                    match crate::stall::ask(&judge, &question).await {
                        Ok(verdict) => verdict,
                        Err(e) => {
                            eprintln!("stall check for {}: {e}", session.id);
                            None
                        }
                    }
                }
                (None, None) => None,
            };
            let stuck = verdict.map(|verdict| crate::protocol::Stuck {
                kind: target.kind,
                command: crate::transcript::clip_to(command, 2000),
                reason: verdict.reason,
                probability: Some(verdict.probability).filter(|p| !p.is_nan()),
                job_id,
                started_at: Some(started_at),
            });
            let mut st = session.state.lock().await;
            st.stall.answered(&target, stuck, Instant::now());
            if st.summary.stuck != st.stall.verdict {
                st.summary.stuck = st.stall.verdict.clone();
                app.publish_summary(&st);
            }
        });
    }

    /// What the stall check is told about a suspect target, from the transcript and the job list.
    async fn stall_context(
        &self,
        session: &Arc<Session>,
        target: &crate::stall::Target,
    ) -> StallContext {
        let live = session.state.lock().await.transcript.items.clone();
        let items = if live
            .iter()
            .any(|i| i.kind == crate::protocol::ItemKind::Tool)
        {
            live
        } else {
            // Not attached: the transcript isn't kept live, so read it.
            self.command(session, "get_messages", json!({}))
                .await
                .ok()
                .map(|data| {
                    let messages = data["messages"].as_array().cloned().unwrap_or_default();
                    Transcript::rebuild(&messages, 8000)
                })
                .unwrap_or_default()
        };
        if target.kind == "tool" {
            // The call running now is the last one.
            let call = items
                .iter()
                .rposition(|i| i.kind == crate::protocol::ItemKind::Tool);
            let item = call.map(|at| &items[at]);
            return StallContext {
                command: item.map(tool_code).unwrap_or_default(),
                output: item.and_then(|i| i.output.clone()).unwrap_or_default(),
                job_id: None,
                said: call.and_then(|at| said_before(&items, at)),
            };
        }
        let job = self
            .list_jobs(session)
            .await
            .ok()
            .and_then(|jobs| jobs.into_iter().find(|j| j.pid == Some(target.pid)));
        let id = job
            .map(|j| j.id)
            .unwrap_or_else(|| format!("process:{}", target.pid));
        let output = self.job_output(session, &id, 40).await.unwrap_or_default();
        // The call that started it, for what the agent meant it to do.
        let needle: String = target.id.chars().take(60).collect();
        let call = items.iter().rposition(|i| {
            i.kind == crate::protocol::ItemKind::Tool && tool_code(i).contains(&needle)
        });
        StallContext {
            command: target.id.clone(),
            output,
            job_id: Some(id),
            said: call.and_then(|at| said_before(&items, at)),
        }
    }

    /// Publishes a change in a session's background commands. The same command keeps the start time first seen for
    /// it, so a start time derived from `ps` doesn't republish the summary every time it rounds differently.
    async fn set_background_jobs(&self, session: &Session, jobs: u32, waiting: Option<WaitingOn>) {
        let mut st = session.state.lock().await;
        let same = match (&st.summary.waiting_on, &waiting) {
            (Some(old), Some(new)) => old.pid == new.pid && old.command == new.command,
            (old, new) => old.is_none() && new.is_none(),
        };
        if st.summary.background_jobs != jobs || !same {
            st.summary.background_jobs = jobs;
            if !same {
                st.summary.waiting_on = waiting;
            }
            self.publish_summary(&st);
        }
    }

    async fn run_prime(self: Arc<Self>, mut rx: mpsc::UnboundedReceiver<DaemonEvent>) {
        let mut last_error: Option<String> = None;
        while let Some(event) = rx.recv().await {
            match event {
                DaemonEvent::Roster(rows) => {
                    last_error = None;
                    let mut live = Vec::new();
                    for row in &rows {
                        if let Some(s) = self.apply_prime_row(row).await {
                            live.push(s.id.clone());
                        }
                    }
                    // Drop sessions that ended while disconnected, and re-attach the rest.
                    let prime: Vec<Arc<Session>> = self
                        .sessions
                        .read()
                        .await
                        .iter()
                        .filter(|s| s.backend == Backend::Prime)
                        .cloned()
                        .collect();
                    for s in prime {
                        if !live.contains(&s.id) {
                            self.remove(&s.id).await;
                            continue;
                        }
                        let was_attached =
                            std::mem::replace(&mut s.state.lock().await.attached, false);
                        if was_attached {
                            let app = self.clone();
                            tokio::spawn(async move {
                                let _ = app.ensure_attached(&s).await;
                            });
                        }
                    }
                }
                DaemonEvent::RosterUpdate(rows) => {
                    for row in &rows {
                        self.apply_prime_row(row).await;
                    }
                }
                DaemonEvent::SessionEvent {
                    active_session_id,
                    event,
                } => {
                    if let Ok(session) = self.find(&active_session_id).await {
                        self.handle_event(&session, &event).await;
                    }
                }
                DaemonEvent::SessionClosed(id) => self.remove(&id).await,
                DaemonEvent::Inactive {
                    session_file,
                    session_id,
                } => {
                    let prime: Vec<Arc<Session>> = self
                        .sessions
                        .read()
                        .await
                        .iter()
                        .filter(|s| s.backend == Backend::Prime)
                        .cloned()
                        .collect();
                    for s in prime {
                        let ended = {
                            let st = s.state.lock().await;
                            // A subagent's row may come without its file. Its session id never changes, unlike a
                            // top-level session's, which `new_session` replaces.
                            (session_file.is_some() && st.session_file == session_file)
                                || (st.summary.kind == SessionKind::Subagent
                                    && session_id.is_some()
                                    && st.prime_session == session_id)
                        };
                        if ended {
                            self.remove(&s.id).await;
                        }
                    }
                }
                DaemonEvent::Disconnected(error) => {
                    if last_error.as_deref() != Some(&error) {
                        eprintln!("prime daemon: {error}");
                        last_error = Some(error.clone());
                    }
                    let prime: Vec<Arc<Session>> = self
                        .sessions
                        .read()
                        .await
                        .iter()
                        .filter(|s| s.backend == Backend::Prime)
                        .cloned()
                        .collect();
                    for s in prime {
                        let mut st = s.state.lock().await;
                        st.summary.status = SessionStatus::Error;
                        st.summary.error = Some(format!("Prime daemon unavailable: {error}"));
                        self.publish_summary(&st);
                    }
                }
            }
        }
    }

    /// Mirror one Prime roster row into a session, creating it on first sight.
    async fn apply_prime_row(self: &Arc<Self>, row: &Value) -> Option<Arc<Session>> {
        let id = row["activeSessionId"].as_str()?.to_string();
        let cwd = row["cwd"].as_str().unwrap_or("").to_string();
        let session = match self.find(&id).await {
            Ok(s) => s,
            Err(_) => {
                let mut summary = new_summary(&id, AgentKind::Prime, SessionKind::Root, &cwd);
                summary.created_at = row["created"]
                    .as_str()
                    .and_then(parse_iso_ms)
                    .unwrap_or_else(now_ms);
                let session = Arc::new(Session {
                    id: id.clone(),
                    agent: AgentKind::Prime,
                    backend: Backend::Prime,
                    cwd,
                    state: Mutex::new(SessionState::new(summary, None)),
                });
                let mut sessions = self.sessions.write().await;
                match sessions.iter().find(|s| s.id == id) {
                    Some(existing) => existing.clone(),
                    None => {
                        sessions.push(session.clone());
                        session
                    }
                }
            }
        };
        let mut st = session.state.lock().await;
        let s = &mut st.summary;
        s.kind = if row["runtimeKind"] == "subagent" {
            SessionKind::Subagent
        } else {
            SessionKind::Root
        };
        s.parent_id = row["parentActiveSessionId"].as_str().map(str::to_string);
        s.name = row["sessionName"].as_str().map(str::to_string);
        s.running_subagents = row["hasRunningSubagents"] == true;
        s.last_active_at = row["lastActivityAt"]
            .as_str()
            .and_then(parse_iso_ms)
            .or(s.last_active_at);
        s.title = match (&s.name, row["firstMessage"].as_str()) {
            (Some(name), _) => name.clone(),
            (None, Some(first)) if !first_line(first, 60).is_empty() => first_line(first, 60),
            _ => default_title(&s.cwd),
        };
        s.status = if row["isCompacting"] == true {
            SessionStatus::Compacting
        } else if row["isStreaming"] == true
            || row["activity"].as_str().is_some_and(|a| a != "idle")
        {
            SessionStatus::Running
        } else {
            SessionStatus::Idle
        };
        s.error = None;
        if let Some(model) = ModelInfo::from_value(&row["model"]) {
            let window = s
                .model
                .as_ref()
                .filter(|m| m.id == model.id)
                .and_then(|m| m.context_window);
            s.model = Some(ModelInfo {
                context_window: model.context_window.or(window),
                ..model
            });
        }
        if let Some(level) = row["thinkingLevel"].as_str() {
            s.thinking_level = Some(level.to_string());
        }
        let reported = row["usage"]["cost"].as_f64();
        if let Some(actions) = row.get("sessionActions") {
            s.queue = Queue {
                steering: queue_texts(&actions["steering"]),
                follow_up: queue_texts(&actions["followUps"]),
            };
        }
        st.session_file = row["sessionFile"].as_str().map(str::to_string);
        if st.prime_session.is_none() {
            st.prime_session = row["sessionId"].as_str().map(str::to_string);
            if let Some(key) = &st.prime_session {
                self.rekey_limit(&session.id, key);
            }
        }
        if let Some(own) = reported {
            st.summary.cost = self
                .prime_cost(st.session_file.as_deref(), own, st.summary.cost)
                .max(st.gateway_cost);
        }
        if let Some(pid) = row["workerPid"].as_u64() {
            st.worker_pid = Some(pid as u32);
        }
        let calls = row["toolUseCount"].as_u64().unwrap_or(0);
        st.tools = match st.tools {
            _ if row["isRunningTools"] != true => None,
            Some((n, since)) if n == calls => Some((n, since)),
            _ => Some((calls, Instant::now())),
        };
        let mark = (
            row["activity"].as_str().unwrap_or("").to_string(),
            row["messageCount"].as_u64().unwrap_or(0),
        );
        let refresh = st.roster_mark != mark || st.summary.thinking_levels.is_empty();
        st.roster_mark = mark;
        self.publish_summary(&st);
        if refresh {
            self.schedule_refresh(&session, &mut st);
        }
        drop(st);
        Some(session)
    }

    /// Prime: attach to the daemon session so its events stream, and load the transcript.
    pub async fn ensure_attached(self: &Arc<Self>, session: &Arc<Session>) -> Result<()> {
        if session.backend != Backend::Prime {
            return Ok(());
        }
        let current = {
            let st = session.state.lock().await;
            st.attached.then(|| {
                st.transcript
                    .items
                    .first()
                    .filter(|i| i.kind == ItemKind::Compaction)
                    .map(|i| i.text.clone())
            })
        };
        if let Some(summary) = current {
            // Already live: only catch up on history a compaction wrote after the last load.
            let messages: Vec<Value> = summary
                .into_iter()
                .map(|s| json!({ "role": "compactionSummary", "summary": s }))
                .collect();
            self.load_history(session, &messages).await;
            return Ok(());
        }
        let data = match self.prime.attach(&session.id).await {
            Ok(data) => data,
            Err(error) => {
                // The daemon no longer has this subagent: it ended. Off the list, so nobody is sent to it again.
                let subagent = session.state.lock().await.summary.kind == SessionKind::Subagent;
                if subagent && error.downcast_ref::<crate::prime::Refused>().is_some() {
                    eprintln!("Prime subagent {} is gone: {error}", session.id);
                    self.remove(&session.id).await;
                    bail!("session ended");
                }
                return Err(error);
            }
        };
        let messages = data["snapshot"]["messages"]
            .as_array()
            .cloned()
            .unwrap_or_default();
        self.load_history(session, &messages).await;
        let mut st = session.state.lock().await;
        st.attached = true;
        st.summary.goal = Goal::from_value(&data["snapshot"]["state"]["goal"]);
        self.publish_summary(&st);
        st.transcript.reset(&messages);
        self.send_snapshot(&session.id, &mut st);
        Ok(())
    }

    async fn handle_event(self: &Arc<Self>, session: &Arc<Session>, event: &Value) {
        let mut st = session.state.lock().await;
        let before = st.summary.status;
        let mut summary_changed = false;
        let mut refresh = false;
        let mut resnapshot = false;
        let mut pi_subagents: Option<(String, Value, bool)> = None;
        let mut dsh_subagent: Option<Value> = None;
        let kind = event["type"].as_str().unwrap_or("");
        match kind {
            "agent_start" => st.summary.status = SessionStatus::Running,
            "agent_settled" => {
                st.summary.status = SessionStatus::Idle;
                refresh = true;
            }
            "agent_end" | "turn_end" => refresh = true,
            "compaction_start" => st.summary.status = SessionStatus::Compacting,
            "compaction_end" => {
                refresh = true;
                resnapshot = event["aborted"] != true && !event["errorMessage"].is_string();
            }
            "queue_update" => {
                st.summary.queue = Queue {
                    steering: queue_texts(&event["steering"]),
                    follow_up: queue_texts(&event["followUp"]),
                };
                summary_changed = true;
            }
            "thinking_level_changed" => {
                st.summary.thinking_level = event["level"].as_str().map(str::to_string);
                summary_changed = true;
            }
            "session_info_changed" => {
                st.named = event["name"].is_string();
                st.summary.title = event["name"]
                    .as_str()
                    .map(str::to_string)
                    .unwrap_or_else(|| default_title(&session.cwd));
                summary_changed = true;
            }
            "session_action_update" => refresh = true,
            "goal_update" => {
                st.summary.goal = Goal::from_value(&event["goal"]);
                summary_changed = true;
            }
            "dsh_jobs" => {
                st.summary.background_jobs = event["running"].as_u64().unwrap_or(0) as u32;
                summary_changed = true;
            }
            "dsh_subagent" => dsh_subagent = Some(event.clone()),
            "dsh_question" => {
                st.summary.question = Some(event["question"].clone()).filter(|q| q.is_object());
                summary_changed = true;
            }
            "tool_execution_start" | "tool_execution_update" | "tool_execution_end"
                if session.backend == Backend::Pi && event["toolName"] == "subagent" =>
            {
                let finished = kind == "tool_execution_end";
                st.summary.running_subagents = !finished;
                summary_changed = true;
                let details = if finished {
                    &event["result"]["details"]
                } else {
                    &event["partialResult"]["details"]
                };
                if details.is_object() {
                    let call_id = event["toolCallId"].as_str().unwrap_or("call").to_string();
                    pi_subagents = Some((call_id, details.clone(), finished));
                }
            }
            _ => {}
        }
        st.transcript.handle_event(event);
        let looping = st.transcript.take_looping();
        self.flush_changes(&session.id, &mut st);
        // Titled once, from the first message: after a compaction the transcript starts at a later one.
        if !st.named
            && session.backend == Backend::Pi
            && st.summary.title == default_title(&session.cwd)
        {
            if let Some(first) = st.transcript.first_user_text() {
                let title = first_line(first, 60);
                if !title.is_empty() && title != st.summary.title {
                    st.summary.title = title;
                    summary_changed = true;
                    tokio::spawn(self.clone().save_registry());
                }
            }
        }
        if summary_changed || st.summary.status != before {
            self.publish_summary(&st);
        }
        if refresh {
            self.schedule_refresh(session, &mut st);
        }
        drop(st);
        if let Some((call_id, details, finished)) = pi_subagents {
            self.update_pi_subagents(session, &call_id, &details, finished)
                .await;
        }
        if let Some(child) = dsh_subagent {
            self.update_dsh_subagent(session, &child).await;
        }
        if resnapshot {
            let (app, session) = (self.clone(), session.clone());
            tokio::spawn(async move {
                let _ = app.resnapshot(&session).await;
            });
        }
        if let Some((reason, sample)) = looping {
            let (app, session) = (self.clone(), session.clone());
            tokio::spawn(async move { app.stop_looping_reply(&session, reason, sample).await });
        }
    }

    /// A reply stuck in a generation loop streams until the model's output limit, a quarter of an hour or more, with
    /// nothing to show. Stop it, and tell the agent why so it tries again rather than repeating itself.
    async fn stop_looping_reply(
        self: &Arc<Self>,
        session: &Arc<Session>,
        reason: &str,
        sample: crate::runaway::LoopSample,
    ) {
        eprintln!(
            "session {}: stopping a looping reply ({reason})",
            session.id
        );
        log_loop(
            &session.id,
            &session.state.lock().await.summary,
            reason,
            &sample,
        );
        let note = format!(
            "[Shed] Your last reply was stopped automatically: {reason}, a generation loop. Nothing from it was kept. \
             Carry on from where you were; if you were writing a tool call, write it again."
        );
        if session.backend == Backend::Prime {
            // Queued as a steer first, so stopping the reply delivers it straight away.
            let _ = self
                .command(
                    session,
                    "prompt",
                    json!({ "message": note, "streamingBehavior": "steer", "queueIfBusy": true }),
                )
                .await;
            let _ = self
                .command(session, "abort_and_send_queued", json!({}))
                .await;
        } else {
            let _ = self.command(session, "abort", json!({})).await;
            let _ = self
                .command(session, "prompt", json!({ "message": note }))
                .await;
        }
        let mut st = session.state.lock().await;
        self.schedule_refresh(session, &mut st);
    }

    /// Mirror the children of a Pi `subagent` tool call as read-only sessions.
    async fn update_pi_subagents(
        self: &Arc<Self>,
        parent: &Arc<Session>,
        call_id: &str,
        details: &Value,
        finished: bool,
    ) {
        let Some(results) = details["results"].as_array() else {
            return;
        };
        let parent_window = parent
            .state
            .lock()
            .await
            .summary
            .context
            .as_ref()
            .map(|c| c.window);
        let mode = details["mode"].as_str().unwrap_or("single");
        let short_call: String = call_id
            .chars()
            .filter(|c| c.is_ascii_alphanumeric())
            .rev()
            .take(8)
            .collect::<String>()
            .chars()
            .rev()
            .collect();
        for (index, result) in results.iter().enumerate() {
            let id = format!("{}.{}.{}", parent.id, short_call, index);
            let session = match self.find(&id).await {
                Ok(s) => s,
                Err(_) => {
                    let mut summary =
                        new_summary(&id, AgentKind::Pi, SessionKind::Subagent, &parent.cwd);
                    summary.parent_id = Some(parent.id.clone());
                    summary.read_only = true;
                    let session = Arc::new(Session {
                        id: id.clone(),
                        agent: AgentKind::Pi,
                        backend: Backend::PiSubagent,
                        cwd: parent.cwd.clone(),
                        state: Mutex::new(SessionState::new(summary, None)),
                    });
                    self.sessions.write().await.push(session.clone());
                    session
                }
            };
            let exit = result["exitCode"].as_i64().unwrap_or(0);
            // A running child reports exitCode 0 (or -1 as a parallel placeholder) until its process exits; it is
            // finished once its last assistant message stopped for a reason other than calling tools.
            let settled = exit != -1
                && matches!(result["stopReason"].as_str(), Some(reason) if reason != "toolUse");
            let done = finished || settled || (mode == "chain" && index + 1 < results.len());
            let failed =
                exit > 0 || matches!(result["stopReason"].as_str(), Some("error" | "aborted"));
            let messages: Vec<Value> = result["messages"]
                .as_array()
                .map(|ms| {
                    ms.iter()
                        .filter(|m| m["role"] != "system")
                        .cloned()
                        .collect()
                })
                .unwrap_or_default();

            let mut st = session.state.lock().await;
            let agent = result["agent"].as_str().unwrap_or("subagent");
            if !done
                || !matches!(
                    st.summary.status,
                    SessionStatus::Done | SessionStatus::Error
                )
            {
                st.summary.last_active_at = Some(now_ms());
            }
            st.summary.name = Some(agent.to_string());
            st.summary.title = format!(
                "{agent}: {}",
                first_line(result["task"].as_str().unwrap_or(""), 60)
            );
            st.summary.status = match (done, failed) {
                (false, _) => SessionStatus::Running,
                (true, true) => SessionStatus::Error,
                (true, false) => SessionStatus::Done,
            };
            st.summary.error = if done && failed {
                result["stderr"].as_str().map(|e| first_line(e, 200))
            } else {
                None
            };
            if let Some((provider, model)) =
                result["model"].as_str().and_then(|m| m.split_once('/'))
            {
                st.summary.model = Some(ModelInfo {
                    provider: provider.into(),
                    id: model.into(),
                    name: model.into(),
                    context_window: parent_window,
                    reasoning: true,
                });
            }
            let usage = &result["usage"];
            st.summary.cost = usage["cost"].as_f64().unwrap_or(0.0).max(st.gateway_cost);
            st.summary.context = parent_window.map(|window| {
                let tokens = usage["contextTokens"].as_u64();
                ContextUsage {
                    tokens,
                    window,
                    percent: tokens.map(|t| t as f64 * 100.0 / window as f64),
                }
            });
            if messages.len() != st.sent_messages || done {
                st.transcript.reset(&messages);
                st.sent_messages = messages.len();
                self.send_snapshot(&session.id, &mut st);
            }
            self.publish_summary(&st);
        }
    }

    /// Mirror one of a DeepSeek session's subagents as a read-only session. dsh runs them in the session's own
    /// process, each with its own conversation, and can nest them; the feed gives one child's whole state at a time.
    async fn update_dsh_subagent(self: &Arc<Self>, root: &Arc<Session>, child: &Value) {
        let short = |dsh_id: &str| {
            dsh_id
                .chars()
                .filter(|c| c.is_ascii_alphanumeric())
                .take(8)
                .collect::<String>()
        };
        let Some(dsh_id) = child["id"].as_str() else {
            return;
        };
        let id = format!("{}.{}", root.id, short(dsh_id));
        let parent_id = match child["parent"].as_str() {
            Some(parent) => format!("{}.{}", root.id, short(parent)),
            None => root.id.clone(),
        };
        let session = match self.find(&id).await {
            Ok(s) => s,
            Err(_) => {
                let mut summary =
                    new_summary(&id, AgentKind::Deepseek, SessionKind::Subagent, &root.cwd);
                summary.parent_id = Some(parent_id);
                summary.read_only = true;
                let session = Arc::new(Session {
                    id: id.clone(),
                    agent: AgentKind::Deepseek,
                    backend: Backend::PiSubagent,
                    cwd: root.cwd.clone(),
                    state: Mutex::new(SessionState::new(summary, None)),
                });
                self.sessions.write().await.push(session.clone());
                session
            }
        };
        let root_model = root.state.lock().await.summary.model.clone();
        let messages: Vec<Value> = child["messages"].as_array().cloned().unwrap_or_default();
        let status = match child["status"].as_str() {
            Some("running") => SessionStatus::Running,
            Some("error") => SessionStatus::Error,
            _ => SessionStatus::Done,
        };
        {
            let mut st = session.state.lock().await;
            st.summary.last_active_at = Some(child["lastActiveAt"].as_u64().unwrap_or_else(now_ms));
            if let Some(created) = child["createdAt"].as_u64() {
                st.summary.created_at = created;
            }
            st.summary.name = Some("subagent".into());
            st.summary.title = first_line(child["title"].as_str().unwrap_or("subagent"), 60);
            st.summary.status = status;
            st.summary.error = child["error"].as_str().map(|e| first_line(e, 200));
            st.summary.model = match child["model"].as_str().and_then(|m| m.split_once('/')) {
                Some((provider, model)) => Some(ModelInfo {
                    provider: provider.into(),
                    id: model.into(),
                    name: model.into(),
                    context_window: root_model.as_ref().and_then(|m| m.context_window),
                    reasoning: true,
                }),
                None => root_model,
            };
            if messages.len() != st.sent_messages || status != SessionStatus::Running {
                st.transcript.reset(&messages);
                st.sent_messages = messages.len();
                self.send_snapshot(&session.id, &mut st);
            }
            self.publish_summary(&st);
        }
        // The parent shows subagents at work while any of its children is.
        let prefix = format!("{}.", root.id);
        let mut running = false;
        let all = self.sessions.read().await.clone();
        for s in all.iter().filter(|s| s.id.starts_with(&prefix)) {
            if s.backend == Backend::PiSubagent
                && s.state.lock().await.summary.status == SessionStatus::Running
            {
                running = true;
            }
        }
        let mut st = root.state.lock().await;
        if st.summary.running_subagents != running {
            st.summary.running_subagents = running;
            self.publish_summary(&st);
        }
    }

    fn schedule_refresh(self: &Arc<Self>, session: &Arc<Session>, st: &mut SessionState) {
        if st.refresh_scheduled || session.backend == Backend::PiSubagent {
            return;
        }
        st.refresh_scheduled = true;
        let (app, session) = (self.clone(), session.clone());
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(150)).await;
            let _ = app.refresh(&session).await;
        });
    }

    /// Re-read state and stats from the agent and publish the session summary.
    pub async fn refresh(self: &Arc<Self>, session: &Arc<Session>) -> Result<()> {
        let levels_for = {
            let mut st = session.state.lock().await;
            st.refresh_scheduled = false;
            if session.backend == Backend::Pi && st.child.is_none() {
                return Ok(());
            }
            st.levels_for.clone()
        };
        let (state, stats) = tokio::join!(
            self.command(session, "get_state", json!({})),
            self.command(session, "get_session_stats", json!({}))
        );
        let state = state?;
        let model = ModelInfo::from_value(&state["model"]);
        let model_key = model.as_ref().map(|m| format!("{}/{}", m.provider, m.id));
        let levels = if model_key != levels_for {
            Some(self.thinking_levels(session, model.as_ref()).await)
        } else {
            None
        };

        let mut st = session.state.lock().await;
        if let Some(levels) = levels {
            st.summary.thinking_levels = levels;
            st.levels_for = model_key;
        }
        if let Some(mut model) = model {
            // Prime's daemon state omits the context window; stats carry it.
            if model.context_window.is_none() {
                model.context_window = stats
                    .as_ref()
                    .ok()
                    .and_then(|s| s["contextUsage"]["contextWindow"].as_u64());
            }
            st.summary.model = Some(model);
        }
        if let Some(level) = state["thinkingLevel"].as_str() {
            st.summary.thinking_level = Some(level.to_string());
        }
        if let Some(auto) = state["autoCompactionEnabled"].as_bool() {
            st.summary.auto_compaction = auto;
        }
        if !matches!(
            st.summary.status,
            SessionStatus::Stopped | SessionStatus::Error | SessionStatus::Done
        ) {
            st.summary.status = if state["isCompacting"] == true {
                SessionStatus::Compacting
            } else if state["isStreaming"] == true {
                SessionStatus::Running
            } else {
                SessionStatus::Idle
            };
        }
        if let Some(name) = state["sessionName"].as_str() {
            st.named = true;
            st.summary.title = name.to_string();
        }
        if let Some(actions) = state.get("sessionActions") {
            st.summary.queue = Queue {
                steering: queue_texts(&actions["steering"]),
                follow_up: queue_texts(&actions["followUps"]),
            };
        }
        if let Ok(stats) = stats {
            if let Some(own) = stats["cost"].as_f64() {
                st.summary.cost = if session.backend == Backend::Prime {
                    let file = stats["sessionFile"]
                        .as_str()
                        .map(str::to_string)
                        .or_else(|| st.session_file.clone());
                    self.prime_cost(file.as_deref(), own, st.summary.cost)
                } else {
                    own
                }
                .max(st.gateway_cost);
            }
            let usage = &stats["contextUsage"];
            st.summary.context = usage["contextWindow"].as_u64().map(|window| ContextUsage {
                tokens: usage["tokens"].as_u64(),
                window,
                percent: usage["percent"].as_f64(),
            });
        }
        // A chosen window, else the model's standard one: report against it, and compact once the session settles
        // near it.
        let chosen = self
            .limits
            .lock()
            .unwrap()
            .get(limit_key(session, &st))
            .copied();
        let standard = st.summary.model.as_ref().and_then(|m| {
            crate::store::default_window(&self.store.default_windows(), &m.provider, &m.id)
        });
        st.summary.context_limit = chosen;
        st.summary.standard_window = standard;
        let limit = chosen.or(standard);
        let settled = st.summary.auto_compaction && st.summary.status == SessionStatus::Idle;
        let mut compact = false;
        if let (Some(limit), Some(context)) = (limit, st.summary.context.as_mut()) {
            context.window = limit.min(context.window);
            context.percent = context
                .tokens
                .map(|t| t as f64 * 100.0 / context.window as f64);
            compact = settled
                && context
                    .tokens
                    .is_some_and(|t| t > context.window - compaction_reserve(context.window));
        }
        let file = state["sessionFile"].as_str().map(str::to_string);
        let file_changed = file.is_some() && file != st.session_file;
        if file_changed {
            st.session_file = file;
        }
        self.publish_summary(&st);
        drop(st);
        if file_changed && session.backend == Backend::Pi {
            tokio::spawn(self.clone().save_registry());
        }
        if compact {
            self.compact_for_limit(session);
        }
        Ok(())
    }

    /// A Prime session's spending: its own calls (as Prime reports them, or as its file records them if that's more)
    /// plus its subagents'. Never less than before: a total doesn't go back down.
    fn prime_cost(&self, file: Option<&str>, own: f64, before: f64) -> f64 {
        let total = match file.and_then(|f| self.costs.read(f)) {
            Some((recorded, subagents)) => own.max(recorded) + subagents,
            None => own,
        };
        total.max(before)
    }

    fn compact_for_limit(self: &Arc<Self>, session: &Arc<Session>) {
        {
            let mut asked = self.compacting_for_limit.lock().unwrap();
            if asked
                .get(&session.id)
                .is_some_and(|at| at.elapsed() < Duration::from_secs(120))
            {
                return;
            }
            asked.insert(session.id.clone(), Instant::now());
        }
        let (app, session) = (self.clone(), session.clone());
        tokio::spawn(async move {
            if let Err(e) = app.compact(&session, None).await {
                eprintln!(
                    "compacting {} for its context window failed: {e}",
                    session.id
                );
            }
            let _ = app.refresh(&session).await;
        });
    }

    /// A window chosen before the session's `sessionId` was known (or by a bridge that saved it under the
    /// `activeSessionId`) moves to it, so it survives the session reopening.
    fn rekey_limit(&self, id: &str, key: &str) {
        let limits = {
            let mut limits = self.limits.lock().unwrap();
            let Some(limit) = limits.remove(id) else {
                return;
            };
            limits.entry(key.to_string()).or_insert(limit);
            limits.clone()
        };
        if let Err(e) = self.store.save_limits(&limits) {
            eprintln!("failed to save context windows: {e}");
        }
    }

    fn forget_limit(&self, id: &str) {
        let limits = {
            let mut limits = self.limits.lock().unwrap();
            if limits.remove(id).is_none() {
                return;
            }
            limits.clone()
        };
        if let Err(e) = self.store.save_limits(&limits) {
            eprintln!("failed to save context windows: {e}");
        }
    }

    pub async fn set_context_limit(
        self: &Arc<Self>,
        session: &Arc<Session>,
        limit: Option<u64>,
    ) -> Result<()> {
        // Pi keeps the last 20k tokens verbatim when it compacts, so a smaller window could never get under its limit.
        if limit.is_some_and(|l| l < 32_000) {
            bail!("a context window needs at least 32k tokens");
        }
        let key = limit_key(session, &*session.state.lock().await).to_string();
        let limits = {
            let mut limits = self.limits.lock().unwrap();
            match limit {
                Some(limit) => limits.insert(key, limit),
                None => limits.remove(&key),
            };
            limits.clone()
        };
        self.compacting_for_limit
            .lock()
            .unwrap()
            .remove(&session.id);
        self.store.save_limits(&limits)?;
        let mut st = session.state.lock().await;
        st.summary.context_limit = limit;
        let running = !(session.backend == Backend::Pi && st.child.is_none());
        if !running {
            self.publish_summary(&st);
        }
        drop(st);
        if running {
            self.refresh(session).await?;
        }
        Ok(())
    }

    /// Names the session in the agent itself, so its own listings agree. A stopped Pi session is named here and
    /// takes the name when it resumes.
    pub async fn rename_session(
        self: &Arc<Self>,
        session: &Arc<Session>,
        name: &str,
    ) -> Result<()> {
        let name = name.trim();
        if name.is_empty() {
            bail!("a session name can't be empty");
        }
        let stopped = session.backend == Backend::Pi && session.state.lock().await.child.is_none();
        if !stopped {
            self.command(session, "set_session_name", json!({ "name": name }))
                .await?;
            self.refresh(session).await?;
        }
        let mut st = session.state.lock().await;
        st.named = true;
        st.summary.title = name.to_string();
        self.publish_summary(&st);
        drop(st);
        if session.backend == Backend::Pi {
            tokio::spawn(self.clone().save_registry());
        }
        Ok(())
    }

    async fn thinking_levels(&self, session: &Session, model: Option<&ModelInfo>) -> Vec<String> {
        let Some(model) = model else {
            return Vec::new();
        };
        if !model.reasoning {
            return vec!["off".to_string()];
        }
        if session.backend == Backend::Pi {
            if let Ok(data) = self
                .command(session, "get_available_thinking_levels", json!({}))
                .await
            {
                if let Ok(levels) = serde_json::from_value::<Vec<String>>(data["levels"].clone()) {
                    return levels;
                }
            }
        }
        // Prime has no levels command; its model catalog marks unsupported levels as null.
        let models = self
            .command(session, "get_available_models", json!({}))
            .await
            .unwrap_or(Value::Null);
        let map = models["models"]
            .as_array()
            .and_then(|ms| {
                ms.iter().find(|x| {
                    x["id"] == model.id.as_str() && x["provider"] == model.provider.as_str()
                })
            })
            .map(|x| x["thinkingLevelMap"].clone())
            .unwrap_or(Value::Null);
        ALL_LEVELS
            .iter()
            .filter(|l| !map.get(**l).is_some_and(Value::is_null))
            .map(|s| s.to_string())
            .collect()
    }

    /// Reload the whole transcript from the agent and send it to attached clients.
    pub async fn resnapshot(self: &Arc<Self>, session: &Arc<Session>) -> Result<()> {
        if session.backend == Backend::Prime && !session.state.lock().await.attached {
            return Ok(());
        }
        let data = self.command(session, "get_messages", json!({})).await?;
        let messages = data["messages"].as_array().cloned().unwrap_or_default();
        self.load_history(session, &messages).await;
        {
            let mut st = session.state.lock().await;
            st.transcript.reset(&messages);
            self.send_snapshot(&session.id, &mut st);
        }
        // Rebuild Pi subagents from completed subagent tool results (e.g. after a resume).
        if session.backend == Backend::Pi {
            for message in messages
                .iter()
                .filter(|m| m["role"] == "toolResult" && m["toolName"] == "subagent")
            {
                let call_id = message["toolCallId"].as_str().unwrap_or("call").to_string();
                self.update_pi_subagents(session, &call_id, &message["details"], true)
                    .await;
            }
        }
        Ok(())
    }

    /// Prime: read the history before the last compaction from the session's file, off the session lock. A
    /// failure only leaves the earlier history out.
    async fn load_history(&self, session: &Session, messages: &[Value]) {
        if session.backend != Backend::Prime {
            return;
        }
        let summary = messages
            .first()
            .filter(|m| m["role"] == "compactionSummary")
            .and_then(|m| m["summary"].as_str());
        let (file, previous) = {
            let mut st = session.state.lock().await;
            if summary.is_none() {
                st.history = None;
                return;
            }
            (st.session_file.clone(), st.history.clone())
        };
        let (Some(file), Some(summary)) = (file, summary.map(str::to_string)) else {
            return;
        };
        let path = file.clone();
        match tokio::task::spawn_blocking(move || history::load(&path, &summary, previous)).await {
            Ok(Ok(history)) => session.state.lock().await.history = history,
            Ok(Err(e)) => eprintln!("history of {}: {file}: {e}", session.id),
            Err(e) => eprintln!("history of {}: {e}", session.id),
        }
    }

    // ---- client operations ----

    /// Prompt when idle; steer while the agent is working.
    pub async fn send_text(
        self: &Arc<Self>,
        session: &Arc<Session>,
        text: String,
    ) -> Result<Value> {
        let result = if session.backend == Backend::Prime {
            let fields =
                json!({ "message": text, "streamingBehavior": "steer", "queueIfBusy": true });
            self.command(session, "prompt", fields).await
        } else {
            let busy = matches!(
                session.state.lock().await.summary.status,
                SessionStatus::Running | SessionStatus::Compacting
            );
            if busy {
                self.command(session, "steer", json!({ "message": text }))
                    .await
            } else {
                match self
                    .command(session, "prompt", json!({ "message": text }))
                    .await
                {
                    Err(e) if e.to_string().to_lowercase().contains("stream") => {
                        self.command(session, "steer", json!({ "message": text }))
                            .await
                    }
                    other => other,
                }
            }
        };
        let mut st = session.state.lock().await;
        self.schedule_refresh(session, &mut st);
        result
    }

    /// Prime's `compact` command aborts the session first, which drops the background-command and subagent notices
    /// waiting to wake it and holds the rest until the next prompt: an idle session waiting on its jobs never wakes.
    /// Its `/compact` slash command compacts without aborting, after the current turn if one is running.
    pub async fn compact(
        self: &Arc<Self>,
        session: &Arc<Session>,
        instructions: Option<String>,
    ) -> Result<Value> {
        let instructions = instructions.filter(|text| !text.trim().is_empty());
        if session.backend == Backend::Prime {
            let message = match instructions {
                Some(text) => format!("/compact {text}"),
                None => "/compact".to_string(),
            };
            return self
                .command(
                    session,
                    "prompt",
                    json!({ "message": message, "streamingBehavior": "followUp" }),
                )
                .await;
        }
        let fields = match instructions {
            Some(text) => json!({ "customInstructions": text }),
            None => json!({}),
        };
        self.command(session, "compact", fields).await
    }

    /// Prime's `/goal clear`, steered in so a running turn picks it up at its next step instead of after the turn.
    pub async fn clear_goal(self: &Arc<Self>, session: &Arc<Session>) -> Result<Value> {
        if session.backend != Backend::Prime {
            bail!("Only Prime sessions have goals");
        }
        self.command(
            session,
            "prompt",
            json!({ "message": "/goal clear", "streamingBehavior": "steer" }),
        )
        .await
    }

    /// Prime offers no command for this (its terminal asks the user itself, and never asks a remote client), but its
    /// kernels run on this machine: kill the session's own kernel, found by the session id in its environment, along
    /// with whatever it started. Prime notices the kernel is gone and starts a fresh one on the next Python call.
    pub async fn restart_kernel(self: &Arc<Self>, session: &Arc<Session>) -> Result<Value> {
        if session.backend != Backend::Prime {
            bail!("Only Prime sessions have a Python kernel");
        }
        let file = session
            .state
            .lock()
            .await
            .session_file
            .clone()
            .context("Prime hasn't reported this session's file yet")?;
        let rlm_session = std::path::Path::new(&file)
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or_default()
            .to_string();
        let output = tokio::process::Command::new("ps")
            .args(["-axww", "-E", "-o", "pid=,ppid=,command="])
            .output()
            .await?;
        let table = String::from_utf8_lossy(&output.stdout);
        let processes: Vec<(u32, u32, &str)> = table
            .lines()
            .filter_map(|line| {
                let mut parts = line.split_whitespace();
                let pid = parts.next()?.parse().ok()?;
                let ppid = parts.next()?.parse().ok()?;
                Some((pid, ppid, line))
            })
            .collect();
        let marker = format!("RLM_SESSION_ID={rlm_session}");
        let kernels: Vec<u32> = processes
            .iter()
            .filter(|(_, _, line)| {
                line.contains(" -m rlm.repl") && line.split_whitespace().any(|word| word == marker)
            })
            .map(|(pid, _, _)| *pid)
            .collect();
        if kernels.is_empty() {
            bail!("No Python kernel is running for this session");
        }
        // The kernels and everything under them: a hung shell command would otherwise outlive its kernel.
        let mut doomed = kernels.clone();
        let mut i = 0;
        while i < doomed.len() {
            let parent = doomed[i];
            let children: Vec<u32> = processes
                .iter()
                .filter(|(pid, ppid, _)| *ppid == parent && !doomed.contains(pid))
                .map(|(pid, _, _)| *pid)
                .collect();
            doomed.extend(children);
            i += 1;
        }
        let pids: Vec<String> = doomed.iter().map(u32::to_string).collect();
        tokio::process::Command::new("kill")
            .arg("-9")
            .args(&pids)
            .status()
            .await?;
        Ok(json!({ "killed": doomed.len() }))
    }

    /// A plain abort leaves Prime holding steered messages until the next prompt; `abort_and_send_queued` delivers
    /// them at once, so the agent hears about the stop and carries on. Prime falls back to a plain abort when nothing
    /// is queued.
    pub async fn stop_tool(self: &Arc<Self>, session: &Arc<Session>) -> Result<Value> {
        let command = if session.backend == Backend::Prime {
            "abort_and_send_queued"
        } else {
            "abort"
        };
        self.command(session, command, json!({})).await
    }

    pub async fn new_session(self: &Arc<Self>, session: &Arc<Session>) -> Result<Value> {
        let result = self.command(session, "new_session", json!({})).await?;
        {
            let mut st = session.state.lock().await;
            st.named = false;
            st.summary.title = default_title(&session.cwd);
        }
        self.resnapshot(session).await?;
        self.refresh(session).await?;
        Ok(result)
    }
}

/// A snapshot of one session for a client that is attaching: the sequence number it reflects,
/// summary, and items.
pub async fn attach_snapshot(session: &Session) -> (u64, SessionSummary, ServerMessage) {
    let st = session.state.lock().await;
    (st.seq, st.summary.clone(), st.snapshot(&session.id))
}

pub fn expand_dir(path: &str) -> Result<String> {
    let path = match path.strip_prefix("~") {
        Some(rest) => format!("{}{}", std::env::var("HOME").unwrap_or_default(), rest),
        None => path.to_string(),
    };
    let canonical = std::fs::canonicalize(&path).map_err(|e| anyhow!("{path}: {e}"))?;
    if !canonical.is_dir() {
        bail!("{path} is not a directory");
    }
    Ok(canonical.to_string_lossy().into_owned())
}

/// What a session's chosen context window is saved under: a Prime conversation's `sessionId`, else the session's id.
fn limit_key<'a>(session: &'a Session, st: &'a SessionState) -> &'a str {
    st.prime_session.as_deref().unwrap_or(&session.id)
}

/// The session id an agent sends Open Codex with its requests: Prime's own session id, dsh's session file id, and the
/// id in a Pi session file's name (`<time>_<id>.jsonl`).
fn agent_session_id(agent: AgentKind, st: &SessionState) -> Option<String> {
    if agent == AgentKind::Prime {
        return st.prime_session.clone();
    }
    let file = st.session_file.as_deref()?;
    let name = std::path::Path::new(file).file_stem()?.to_str()?;
    Some(match agent {
        AgentKind::Pi => name.rsplit('_').next().unwrap_or(name).to_string(),
        _ => name.to_string(),
    })
}
