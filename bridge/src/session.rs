//! Agent sessions: Pi sessions are bridge-owned RPC children; Prime sessions (and their subagents)
//! live in Prime's daemon and are mirrored from its roster; Pi subagents are read-only views of the
//! parent's `subagent` tool call.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use anyhow::{anyhow, bail, Result};
use serde_json::{json, Value};
use tokio::sync::{broadcast, mpsc, Mutex, RwLock};

use crate::agent_wire::{self, DshSubagent, PiSubagentCall, SessionEvent};
use crate::history::{self, History};
use crate::prime::PrimeDaemon;
use crate::protocol::{
    Item, ItemKind, Queue, ServerMessage, SessionKind, SessionStatus, SessionSummary,
};
use crate::rpc::{AgentKind, ChildOutput, RpcChild, SpawnOptions};
use crate::store::{SessionRecord, Store};
use crate::transcript::{Change, Transcript};

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
    /// What the tests answer for the agents, and what the bridge asked them.
    #[cfg(test)]
    agents: tests::Agents,
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
    /// The bridge's state as saved, connected to Prime's daemon and watching what its sessions do.
    pub fn new(store: Store) -> Result<Arc<App>> {
        let (prime, prime_events) = PrimeDaemon::start(store.client_id()?);
        let mut limits = store.load_limits();
        let home = std::env::var("HOME").unwrap_or_default();
        if crate::store::adopt_stray_limits(
            &mut limits,
            std::path::Path::new(&format!("{home}/.prime/agent/daemon-workers")),
        ) {
            if let Err(e) = store.save_limits(&limits) {
                eprintln!("failed to save context windows: {e}");
            }
        }
        let app = App::assemble(store, prime, limits)?;
        tokio::spawn(app.clone().run_prime(prime_events));
        tokio::spawn(app.clone().watch_background_jobs());
        tokio::spawn(app.clone().watch_spend());
        tokio::spawn(app.clone().watch_sites());
        Ok(app)
    }

    /// The saved sessions, stopped, with nothing running yet: no daemon connection, no watchers.
    fn assemble(
        store: Store,
        prime: Arc<PrimeDaemon>,
        limits: HashMap<String, u64>,
    ) -> Result<Arc<App>> {
        let token = store.token()?;
        let (hub, _) = broadcast::channel(4096);
        let sessions = store
            .load_sessions()
            .into_iter()
            .map(|r| {
                let mut summary = new_summary(&r.id, r.agent, SessionKind::Root, &r.cwd);
                summary.context_limit = limits.get(&r.id).copied();
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
        let limits = std::sync::Mutex::new(limits);
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
            #[cfg(test)]
            agents: Default::default(),
        });
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
        #[cfg(test)]
        if let Some(answer) = self.agents.answer(&session.id, kind, &fields) {
            return answer;
        }
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
            let session = self.apply_prime_row(row).await;
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

    async fn handle_event(self: &Arc<Self>, session: &Arc<Session>, event: &Value) {
        let mut st = session.state.lock().await;
        let before = st.summary.status;
        let mut summary_changed = false;
        let mut refresh = false;
        let mut resnapshot = false;
        let mut pi_subagents: Option<PiSubagentCall> = None;
        let mut dsh_subagent: Option<DshSubagent> = None;
        match SessionEvent::read(event) {
            SessionEvent::AgentStarted => st.summary.status = SessionStatus::Running,
            SessionEvent::AgentSettled => {
                st.summary.status = SessionStatus::Idle;
                refresh = true;
            }
            SessionEvent::TurnEnded | SessionEvent::ActionsChanged => refresh = true,
            SessionEvent::CompactionStarted => st.summary.status = SessionStatus::Compacting,
            SessionEvent::CompactionEnded { compacted } => {
                refresh = true;
                resnapshot = compacted;
            }
            SessionEvent::Queue(queue) => {
                st.summary.queue = queue;
                summary_changed = true;
            }
            SessionEvent::ThinkingLevel(level) => {
                st.summary.thinking_level = level;
                summary_changed = true;
            }
            SessionEvent::Named(name) => {
                st.named = name.is_some();
                st.summary.title = name.unwrap_or_else(|| default_title(&session.cwd));
                summary_changed = true;
            }
            SessionEvent::Goal(goal) => {
                st.summary.goal = goal;
                summary_changed = true;
            }
            SessionEvent::Jobs(running) => {
                st.summary.background_jobs = running;
                summary_changed = true;
            }
            SessionEvent::Question(question) => {
                st.summary.question = question;
                summary_changed = true;
            }
            SessionEvent::DshSubagent(child) => dsh_subagent = Some(child),
            SessionEvent::PiSubagentCall(call) if session.backend == Backend::Pi => {
                st.summary.running_subagents = !call.finished;
                summary_changed = true;
                pi_subagents = Some(call);
            }
            SessionEvent::PiSubagentCall(_) | SessionEvent::Other => {}
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
        if let Some(call) = pi_subagents {
            self.update_pi_subagents(session, call).await;
        }
        if let Some(child) = dsh_subagent {
            self.update_dsh_subagent(session, child).await;
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

    /// Reload the whole transcript from the agent and send it to attached clients.
    pub async fn resnapshot(self: &Arc<Self>, session: &Arc<Session>) -> Result<()> {
        if session.backend == Backend::Prime && !session.state.lock().await.attached {
            return Ok(());
        }
        let data = self.command(session, "get_messages", json!({})).await?;
        let messages = agent_wire::messages(&data);
        self.load_history(session, &messages).await;
        {
            let mut st = session.state.lock().await;
            st.transcript.reset(&messages);
            self.send_snapshot(&session.id, &mut st);
        }
        // Rebuild Pi subagents from completed subagent tool results (e.g. after a resume).
        if session.backend == Backend::Pi {
            for call in PiSubagentCall::finished_in(&messages) {
                self.update_pi_subagents(session, call).await;
            }
        }
        Ok(())
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

mod commands;
mod context;
mod prime;
mod subagents;
#[cfg(test)]
mod tests;
mod watchers;
