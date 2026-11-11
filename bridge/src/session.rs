//! Agent sessions: Pi and DeepSeek Harness sessions are RPC children the bridge owns; Prime sessions (and their
//! subagents) live in Prime's daemon and are mirrored from its roster; the subagents of Pi and DeepSeek Harness are
//! read-only views of what their parent session reports about them.

use crate::ask::Ask;
use crate::host::now_ms;
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Instant;

use anyhow::{anyhow, bail, Result};
use serde_json::{json, Value};
use tokio::sync::{broadcast, mpsc, Mutex, RwLock};

use crate::agent::{Agents, Live, Sessions};
use crate::agent_wire::{self, ConversationId, DshSubagent, PiSubagentCall, SessionEvent};
use crate::channel::Offer;
use crate::history::{self, History};
use crate::prime::PrimeDaemon;
use crate::protocol::{
    ErrorCode, Failure, Item, ItemKind, Queue, ServerMessage, SessionKind, SessionStatus,
    SessionSummary,
};
use crate::rpc::{AgentKind, ChildOutput, SpawnOptions};
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
    /// An agent process the bridge starts and owns: `pi --mode rpc`, or DeepSeek Harness through Shed's plugin.
    Started,
    /// A session in Prime's daemon, addressed by its active-session id.
    Prime,
    /// One child of a Pi `subagent` tool call, or one subagent of a DeepSeek Harness session.
    Subagent,
}

pub struct App {
    pub token: String,
    pub sessions: RwLock<Vec<Arc<Session>>>,
    pub hub: broadcast::Sender<Arc<Envelope>>,
    pub(crate) store: Store,
    /// Registry saves run one at a time, each from the list as it is then, so an older save can't land last.
    saving: Mutex<()>,
    /// Context windows chosen per session (see `SessionSummary::context_limit`).
    limits: std::sync::Mutex<HashMap<String, u64>>,
    /// When the bridge last asked a session to compact for its limit, so one crossing asks once.
    compacting_for_limit: std::sync::Mutex<HashMap<String, Instant>>,
    /// Prime sessions' spending, subagents included, read from their session files.
    costs: crate::cost::Costs,
    /// The agents this bridge can run a session of.
    agents: Agents,
    /// The models each agent listed, kept a minute, since listing starts the agent.
    models: std::sync::Mutex<HashMap<AgentKind, (std::time::Instant, Value)>>,
}

/// What a start answers when the session was closed or deleted before its agent was up.
const CLOSED_WHILE_STARTING: &str = "the session was closed while it started";

pub struct Session {
    pub id: String,
    pub agent: AgentKind,
    pub backend: Backend,
    pub cwd: String,
    pub state: Mutex<SessionState>,
    /// Held while a message with a send id is with the agent, so the same message sent again waits to learn whether
    /// the first copy was taken.
    pub sending: Mutex<()>,
}

impl Session {
    /// The backend is read off the state, so the two can't disagree.
    fn new(id: String, agent: AgentKind, cwd: String, state: SessionState) -> Session {
        Session {
            id,
            agent,
            backend: state.own.backend(),
            cwd,
            state: Mutex::new(state),
            sending: Mutex::new(()),
        }
    }
}

/// Where a session the bridge starts is between stopped and running. It changes only under the session's lock, and
/// each step looks at it first, so a close, a delete and a start that cross cannot leave an agent nobody lists.
enum Process {
    Stopped,
    /// Its agent is being started. `closed` once someone asked for the session to stop meanwhile: the start then
    /// closes the agent it made.
    Starting {
        closed: bool,
    },
    Running(Arc<dyn Live>),
    /// Asked to stop, and not gone yet.
    Stopping(Arc<dyn Live>),
}

/// What the bridge keeps for one kind of session only.
enum BackendState {
    Started(Process),
    Prime(PrimeState),
    Subagent {
        /// Transcript length last sent, to avoid resending unchanged snapshots.
        sent_messages: usize,
    },
}

impl BackendState {
    fn started() -> BackendState {
        BackendState::Started(Process::Stopped)
    }

    fn prime() -> BackendState {
        BackendState::Prime(PrimeState::default())
    }

    fn subagent() -> BackendState {
        BackendState::Subagent {
            sent_messages: usize::MAX,
        }
    }

    fn backend(&self) -> Backend {
        match self {
            BackendState::Started(_) => Backend::Started,
            BackendState::Prime(_) => Backend::Prime,
            BackendState::Subagent { .. } => Backend::Subagent,
        }
    }
}

#[derive(Default)]
struct PrimeState {
    /// Attached to the daemon, so its events arrive and the transcript is live.
    attached: bool,
    /// Roster fields whose change warrants a stats refresh.
    roster_mark: (String, u64),
    /// The conversation, which outlives the `activeSessionId` the bridge knows the session by (a reopened session
    /// gets a new one). What its chosen context window is saved under.
    conversation: Option<ConversationId>,
    /// The worker process running this session, for counting its background jobs.
    worker_pid: Option<u32>,
    /// Running a tool call, which one (Prime's count of calls so far) and since when.
    tools: Option<(u64, Instant)>,
    /// The conversation before the last compaction, which the daemon no longer returns.
    history: Option<Arc<History>>,
}

pub struct SessionState {
    pub summary: SessionSummary,
    pub transcript: Transcript,
    pub seq: u64,
    own: BackendState,
    session_file: Option<String>,
    named: bool,
    /// The ids of the last messages taken from the apps, so one sent again is not sent to the agent twice.
    sent: std::collections::VecDeque<String>,
    /// Deleted: late events (a Pi child exiting after the delete) must not publish it again.
    removed: bool,
    refresh_scheduled: bool,
    /// How many times an event has moved the status: a refresh whose answer was asked for before the last move
    /// holds an older status, and leaves the status alone.
    status_moves: u64,
    levels_for: Option<String>,
    /// What Open Codex counted for the session (with its subagents, for Prime): its agent reports nothing for models
    /// Open Codex prices, so this is the least the session has cost.
    gateway_cost: f64,
    /// Watching what the session waits on for a stall.
    stall: crate::stall::Tracker,
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
    let path = crate::host::home().join(".agent-remote/logs/loops.jsonl");
    let written = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
        .and_then(|mut file| writeln!(file, "{line}"));
    if let Err(e) = written {
        eprintln!("can't log the loop to {}: {e}", path.display());
    }
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
    fn new(
        summary: SessionSummary,
        session_file: Option<String>,
        own: BackendState,
    ) -> SessionState {
        SessionState {
            summary,
            transcript: Transcript::default(),
            seq: 0,
            own,
            session_file,
            named: false,
            sent: Default::default(),
            removed: false,
            refresh_scheduled: false,
            status_moves: 0,
            levels_for: None,
            gateway_cost: 0.0,
            stall: Default::default(),
        }
    }

    /// Takes a message's id, and says whether it is new. The last 64 are remembered: an app sends one again within
    /// seconds, when the reply to the first was lost.
    fn take_send(&mut self, id: &str) -> bool {
        if self.sent.iter().any(|sent| sent == id) {
            return false;
        }
        if self.sent.len() == 64 {
            self.sent.pop_front();
        }
        self.sent.push_back(id.to_string());
        true
    }

    /// The message did not go after all, so its id may be sent again.
    fn forget_send(&mut self, id: &str) {
        self.sent.retain(|sent| sent != id);
    }

    /// A `Pi` session with no process: one that was closed, or whose agent exited.
    fn stopped(&self) -> bool {
        matches!(&self.own, BackendState::Started(Process::Stopped))
    }

    /// The agent process of a running `Pi` session.
    fn child(&self) -> Option<&Arc<dyn Live>> {
        match &self.own {
            BackendState::Started(Process::Running(child) | Process::Stopping(child)) => {
                Some(child)
            }
            BackendState::Started(Process::Stopped | Process::Starting { .. }) => None,
            BackendState::Prime(_) | BackendState::Subagent { .. } => None,
        }
    }

    fn prime(&self) -> Option<&PrimeState> {
        match &self.own {
            BackendState::Prime(prime) => Some(prime),
            BackendState::Started(_) | BackendState::Subagent { .. } => None,
        }
    }

    fn prime_mut(&mut self) -> Option<&mut PrimeState> {
        match &mut self.own {
            BackendState::Prime(prime) => Some(prime),
            BackendState::Started(_) | BackendState::Subagent { .. } => None,
        }
    }

    /// Records how long a subagent's transcript is now, and says whether that differs from what was last sent.
    fn note_sent(&mut self, messages: usize) -> bool {
        match &mut self.own {
            BackendState::Subagent { sent_messages } => {
                std::mem::replace(sent_messages, messages) != messages
            }
            BackendState::Started(_) | BackendState::Prime(_) => true,
        }
    }

    /// The Prime worker process running this session.
    pub(crate) fn worker_pid(&self) -> Option<u32> {
        self.prime().and_then(|prime| prime.worker_pid)
    }

    /// History applies while the current context starts with the summary that cut it off.
    fn earlier(&self) -> &[Item] {
        let history = self.prime().and_then(|prime| prime.history.as_ref());
        match (history, self.transcript.items.first()) {
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
        let child = self.state.lock().await.child().cloned();
        child.as_ref().and_then(|child| child.pid())
    }
}

impl App {
    /// The bridge's state as saved, connected to Prime's daemon and watching what its sessions do.
    pub fn new(store: Store) -> Result<Arc<App>> {
        let (prime, prime_events) = PrimeDaemon::start(store.client_id()?, store.clone());
        let mut limits = store.load_limits();
        let home = crate::host::home_text();
        if crate::store::adopt_stray_limits(
            &mut limits,
            std::path::Path::new(&format!("{home}/.prime/agent/daemon-workers")),
        ) {
            if let Err(e) = store.save_limits(&limits) {
                eprintln!("failed to save context windows: {e}");
            }
        }
        let agents = Agents::installed(prime.clone(), store.clone());
        let app = App::assemble(store, limits, agents)?;
        tokio::spawn(app.clone().run_prime(prime_events));
        tokio::spawn(app.clone().watch_background_jobs());
        tokio::spawn(app.clone().watch_spend());
        tokio::spawn(app.clone().watch_sites());
        Ok(app)
    }

    /// The saved sessions, stopped, with nothing running yet: no daemon connection, no watchers.
    fn assemble(store: Store, limits: HashMap<String, u64>, agents: Agents) -> Result<Arc<App>> {
        let token = store.token()?;
        let (hub, _) = broadcast::channel(4096);
        let sessions = store
            .load_sessions()
            .into_iter()
            // Only sessions the bridge starts are saved here. One of an agent that keeps its own can't be started
            // from this file, and asking it anything would reach some other session of that agent's.
            .filter(|r| match agents.get(r.agent).sessions() {
                Sessions::Started(_) => true,
                Sessions::Kept(_) => {
                    eprintln!(
                        "sessions.json lists {} as a {:?} session, which the bridge does not start: left out",
                        r.id, r.agent
                    );
                    false
                }
            })
            .map(|r| {
                let mut summary = new_summary(&r.id, r.agent, SessionKind::Root, &r.cwd);
                summary.context_limit = limits.get(&r.id).copied();
                summary.title = r.title.clone();
                summary.status = SessionStatus::Stopped;
                summary.created_at = r.created_at;
                let mut state = SessionState::new(summary, r.session_file, BackendState::started());
                state.named = r.title != default_title(&r.cwd);
                Arc::new(Session::new(r.id, r.agent, r.cwd, state))
            })
            .collect();
        let limits = std::sync::Mutex::new(limits);
        let app = Arc::new(App {
            token,
            sessions: RwLock::new(sessions),
            hub,
            store,
            saving: Mutex::new(()),
            limits,
            compacting_for_limit: std::sync::Mutex::new(HashMap::new()),
            costs: crate::cost::Costs::default(),
            agents,
            models: Default::default(),
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
        self.hub.offer(Arc::new(Envelope {
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
        self.hub.offer(Arc::new(envelope));
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
        for s in sessions.iter().filter(|s| s.backend == Backend::Started) {
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

    pub(crate) fn agent(&self, kind: AgentKind) -> &Arc<dyn crate::agent::Agent> {
        self.agents.get(kind)
    }

    /// The models a session of this agent can start on.
    pub async fn list_models(&self, agent: AgentKind) -> Result<Value> {
        if let Some((at, models)) = self.models.lock().unwrap().get(&agent) {
            if at.elapsed().as_secs() < 60 {
                return Ok(models.clone());
            }
        }
        let models = crate::rpc::list_models(&self.agents, agent, &self.store).await?;
        self.models
            .lock()
            .unwrap()
            .insert(agent, (std::time::Instant::now(), models.clone()));
        Ok(models)
    }

    /// Run an agent command against a session: by the process the bridge runs for it, or else by the agent itself
    /// when it keeps its own sessions.
    pub async fn command(&self, session: &Session, ask: Ask) -> Result<Value> {
        if session.backend == Backend::Subagent {
            bail!("Subagents are read-only; steer the parent session instead")
        }
        let child = session.state.lock().await.child().cloned();
        let live = match child {
            Some(child) => Some(child),
            None => match self.agents.get(session.agent).sessions() {
                Sessions::Kept(agent) => Some(agent.session(&session.id)),
                Sessions::Started(_) => None,
            },
        };
        let live = live.ok_or_else(|| anyhow!("session is not running"))?;
        live.send(ask).await
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
        // An agent that keeps its own sessions makes it, and it is taken in as its roster would announce it.
        if let Sessions::Kept(keeps) = self.agents.get(agent).sessions() {
            let row = keeps
                .create(cwd.clone(), model.clone(), thinking.clone())
                .await?;
            let session = self.apply_prime_row(row).await;
            // It exists now, so that is the answer: an error here would have the user make a second one.
            if let Err(e) = self.refresh(&session).await {
                eprintln!("a new {agent:?} session's state can't be read yet: {e:#}");
            }
            let summary = session.state.lock().await.summary.clone();
            return Ok(summary);
        }
        let id = uuid::Uuid::new_v4().simple().to_string()[..8].to_string();
        let summary = new_summary(&id, agent, SessionKind::Root, &cwd);
        // Starting from its first moment in the list, so nothing else starts it too.
        let starting = BackendState::Started(Process::Starting { closed: false });
        let state = SessionState::new(summary, None, starting);
        let session = Arc::new(Session::new(id, agent, cwd, state));
        self.sessions.write().await.push(session.clone());
        if let Err(e) = self.start_pi(&session, None, model, thinking).await {
            // Nothing to come back to: it has no transcript, and whoever asked is told why.
            self.remove(&session.id).await;
            return Err(e);
        }
        tokio::spawn(self.clone().save_registry());
        let summary = session.state.lock().await.summary.clone();
        Ok(summary)
    }

    pub async fn resume_session(
        self: &Arc<Self>,
        session: &Arc<Session>,
    ) -> Result<SessionSummary> {
        match session.backend {
            Backend::Started => {}
            Backend::Prime | Backend::Subagent => {
                bail!("this session is kept by its agent, which has it running: there is nothing to resume")
            }
        }
        let resume = {
            let mut st = session.state.lock().await;
            match &st.own {
                // Resuming twice does no harm: a session that runs, or is about to, is the answer.
                BackendState::Started(Process::Running(_) | Process::Starting { .. }) => {
                    return Ok(st.summary.clone())
                }
                BackendState::Started(Process::Stopping(_)) => {
                    bail!("the session is still stopping; resume it in a moment")
                }
                BackendState::Started(Process::Stopped) => {}
                BackendState::Prime(_) | BackendState::Subagent { .. } => {
                    unreachable!("checked above: only a started session gets here")
                }
            }
            let resume = st
                .session_file
                .clone()
                .ok_or_else(|| anyhow!("session has no saved transcript to resume"))?;
            st.own = BackendState::Started(Process::Starting { closed: false });
            resume
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
        // The guide as a file, for the subagents Pi starts: they get no system prompt from the bridge.
        let guide = self.store.dir().join("guide.md");
        if let Err(e) = std::fs::write(
            &guide,
            crate::guide::text(crate::rpc::AgentKind::Pi, &self.store),
        ) {
            eprintln!(
                "can't write the guide for Pi's subagents to {}: {e}",
                guide.display()
            );
        }
        let env = vec![
            // Where Pi's background-jobs extension keeps this session's jobs, for listing and cancelling them here.
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
        let spawned = match self.agents.get(session.agent).sessions() {
            Sessions::Started(agent) => agent.start(&opts),
            Sessions::Kept(_) => Err(anyhow!(
                "{:?} keeps its own sessions: the bridge does not start them",
                session.agent
            )),
        };
        let (child, rx) = {
            let mut st = session.state.lock().await;
            let closed = st.removed
                || matches!(
                    st.own,
                    BackendState::Started(Process::Starting { closed: true })
                );
            match spawned {
                Ok(pair) if closed => {
                    // Closed or deleted while its agent started: the agent goes, and the session is stopped.
                    st.own = BackendState::started();
                    st.summary.status = SessionStatus::Stopped;
                    st.summary.error = None;
                    self.publish_summary(&st);
                    drop(st);
                    pair.0.close().await;
                    bail!("{CLOSED_WHILE_STARTING}");
                }
                Ok(pair) => {
                    st.own = BackendState::Started(Process::Running(pair.0.clone()));
                    st.summary.status = SessionStatus::Starting;
                    st.summary.error = None;
                    self.publish_summary(&st);
                    pair
                }
                Err(e) => {
                    st.own = BackendState::started();
                    st.summary.status = SessionStatus::Error;
                    st.summary.error = Some(e.to_string());
                    self.publish_summary(&st);
                    return Err(e);
                }
            }
        };
        tokio::spawn(
            self.clone()
                .run_pi_events(session.clone(), child.clone(), rx),
        );
        let started = async {
            self.resnapshot(session).await?;
            self.refresh(session).await
        }
        .await;
        let mut st = session.state.lock().await;
        let ours = |c: &Arc<dyn Live>| Arc::ptr_eq(c, &child);
        match (&st.own, started) {
            (BackendState::Started(Process::Running(c)), Ok(())) if ours(c) => Ok(()),
            (BackendState::Started(Process::Running(c)), Err(e)) if ours(c) => {
                // An agent that started and cannot be read is not left running behind a session marked as failed.
                st.own = BackendState::started();
                st.summary.status = SessionStatus::Error;
                st.summary.error = Some(e.to_string());
                self.publish_summary(&st);
                drop(st);
                child.close().await;
                Err(e)
            }
            // Closed meanwhile, and whoever closed it saw to the agent and to what the session shows.
            _ => bail!("{CLOSED_WHILE_STARTING}"),
        }
    }

    pub async fn close_session(&self, session: &Session) -> Result<()> {
        match session.backend {
            Backend::Started => {
                let child = {
                    let mut st = session.state.lock().await;
                    match std::mem::replace(&mut st.own, BackendState::started()) {
                        BackendState::Started(
                            Process::Running(child) | Process::Stopping(child),
                        ) => {
                            st.own = BackendState::Started(Process::Stopping(child.clone()));
                            Some(child)
                        }
                        // The start closes the agent it is making.
                        BackendState::Started(Process::Starting { .. }) => {
                            st.own = BackendState::Started(Process::Starting { closed: true });
                            None
                        }
                        other => {
                            st.own = other;
                            None
                        }
                    }
                };
                let Some(child) = child else { return Ok(()) };
                child.close().await;
                // It is gone now, whether or not its last word has been read yet.
                let mut st = session.state.lock().await;
                if st.child().is_some_and(|c| Arc::ptr_eq(c, &child)) {
                    st.own = BackendState::started();
                    st.summary.question = None;
                    st.summary.status = SessionStatus::Stopped;
                    st.summary.error = None;
                    self.publish_summary(&st);
                }
                Ok(())
            }
            Backend::Prime => match self.agent(session.agent).sessions() {
                Sessions::Kept(agent) => agent.stop(&session.id).await,
                Sessions::Started(_) => bail!(
                    "{:?} starts its sessions here, yet this one is kept by its agent",
                    session.agent
                ),
            },
            Backend::Subagent => bail!("Subagents end with their tool call"),
        }
    }

    pub async fn delete_session(self: &Arc<Self>, session: &Arc<Session>) -> Result<()> {
        let key = limit_key(session, &*session.state.lock().await).to_string();
        // What is kept for the session is forgotten once it is closed: a close that fails leaves it as it was.
        if session.backend != Backend::Subagent {
            self.close_session(session).await?;
        }
        self.forget_limit(&key);
        self.compacting_for_limit
            .lock()
            .unwrap()
            .remove(&session.id);
        if session.backend == Backend::Prime {
            return Ok(());
        }
        // Its subagents and theirs: dsh nests them.
        let mut subagents = Vec::new();
        let all = self.sessions.read().await.clone();
        for s in all.iter().filter(|s| s.backend == Backend::Subagent) {
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
        // All at once: each close may wait up to 3 seconds for its agent to end.
        let closes = sessions
            .iter()
            .filter(|s| s.backend == Backend::Started)
            .map(|s| async move {
                if let Err(e) = self.close_session(s).await {
                    eprintln!("closing {} failed: {e}", s.id);
                }
            });
        futures_util::future::join_all(closes).await;
    }

    // ---- events ----

    async fn run_pi_events(
        self: Arc<Self>,
        session: Arc<Session>,
        child: Arc<dyn Live>,
        mut rx: mpsc::UnboundedReceiver<ChildOutput>,
    ) {
        while let Some(output) = rx.recv().await {
            match output {
                ChildOutput::Event(event) => {
                    // What an agent the session no longer has says changes nothing.
                    let ours = {
                        let st = session.state.lock().await;
                        st.child().is_some_and(|c| Arc::ptr_eq(c, &child))
                    };
                    if !ours {
                        break;
                    }
                    self.handle_event(&session, &event).await
                }
                ChildOutput::Exited(reason) => {
                    let mut st = session.state.lock().await;
                    let stopping = match &st.own {
                        BackendState::Started(Process::Running(c)) if Arc::ptr_eq(c, &child) => {
                            false
                        }
                        BackendState::Started(Process::Stopping(c)) if Arc::ptr_eq(c, &child) => {
                            true
                        }
                        _ => break,
                    };
                    st.own = BackendState::started();
                    st.summary.question = None;
                    if stopping {
                        st.summary.status = SessionStatus::Stopped;
                    } else {
                        st.summary.status = SessionStatus::Error;
                        st.summary.error = Some(reason);
                    }
                    self.publish_summary(&st);
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
            SessionEvent::PiSubagentCall(call) if session.backend == Backend::Started => {
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
            && session.backend == Backend::Started
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
        if st.summary.status != before {
            st.status_moves += 1;
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
                if let Err(e) = app.resnapshot(&session).await {
                    eprintln!("reloading the transcript of {} failed: {e}", session.id);
                }
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
        let mut stopped = Vec::new();
        for ask in self.agent(session.agent).verbs().interrupt(note) {
            stopped.push(self.command(session, ask).await);
        }
        for error in stopped.into_iter().filter_map(Result::err) {
            eprintln!(
                "stopping the looping reply of {} failed: {error}",
                session.id
            );
        }
        let mut st = session.state.lock().await;
        self.schedule_refresh(session, &mut st);
    }

    /// Reload the whole transcript from the agent and send it to attached clients.
    pub async fn resnapshot(self: &Arc<Self>, session: &Arc<Session>) -> Result<()> {
        let detached = session
            .state
            .lock()
            .await
            .prime()
            .is_some_and(|prime| !prime.attached);
        if detached {
            return Ok(());
        }
        let data = self.command(session, Ask::Messages).await?;
        let messages = agent_wire::messages(&data);
        self.load_history(session, &messages).await;
        {
            let mut st = session.state.lock().await;
            st.transcript.reset(&messages);
            self.send_snapshot(&session.id, &mut st);
        }
        // Rebuild Pi subagents from completed subagent tool results (e.g. after a resume).
        if session.backend == Backend::Started {
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
        Some(rest) => format!("{}{}", crate::host::home_text(), rest),
        None => path.to_string(),
    };
    // The sentence is the system's ("No such file or directory"), which apps from before the codes look for.
    let canonical = std::fs::canonicalize(&path).map_err(|e| match e.kind() {
        std::io::ErrorKind::NotFound => {
            Failure::error(ErrorCode::NoSuchDirectory, format!("{path}: {e}"))
        }
        _ => anyhow!("{path}: {e}"),
    })?;
    if !canonical.is_dir() {
        bail!("{path} is not a directory");
    }
    Ok(canonical.to_string_lossy().into_owned())
}

/// What a session's chosen context window is saved under: a Prime conversation's `sessionId`, else the session's id.
fn limit_key<'a>(session: &'a Session, st: &'a SessionState) -> &'a str {
    st.prime()
        .and_then(|prime| prime.conversation.as_ref())
        .map_or(&session.id, |conversation| conversation.as_str())
}

mod commands;
mod context;
mod prime;
mod subagents;
#[cfg(test)]
mod tests;
mod watchers;
