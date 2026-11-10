//! Prime sessions live in Prime's daemon: the bridge mirrors them from its roster and attaches to the ones somebody
//! is looking at.

use std::sync::Arc;
use std::time::Instant;

use anyhow::{bail, Result};
use serde_json::{json, Value};
use tokio::sync::mpsc;

use super::{
    default_title, first_line, limit_key, new_summary, now_ms, App, Backend, BackendState, Session,
    SessionState,
};
use crate::agent_wire::{self, Attached, InactiveRow, PrimeRow};
use crate::history;
use crate::prime::DaemonEvent;
use crate::protocol::{ItemKind, ModelInfo, SessionKind, SessionStatus};
use crate::rpc::AgentKind;

impl App {
    pub(super) async fn run_prime(self: Arc<Self>, mut rx: mpsc::UnboundedReceiver<DaemonEvent>) {
        let mut last_error: Option<String> = None;
        while let Some(event) = rx.recv().await {
            match event {
                DaemonEvent::Roster(rows) => {
                    last_error = None;
                    let mut live = Vec::new();
                    for row in rows {
                        live.push(self.apply_prime_row(row).await.id.clone());
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
                        let was_attached = match s.state.lock().await.prime_mut() {
                            Some(prime) => std::mem::replace(&mut prime.attached, false),
                            None => false,
                        };
                        if was_attached {
                            let app = self.clone();
                            tokio::spawn(async move {
                                if let Err(e) = app.ensure_attached(&s).await {
                                    eprintln!("attaching to {} again failed: {e}", s.id);
                                }
                            });
                        }
                    }
                }
                DaemonEvent::RosterUpdate(rows) => {
                    for row in rows {
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
                // The row has no id left to find the session by, only what it was stored as.
                DaemonEvent::Inactive(InactiveRow {
                    session_file,
                    conversation,
                }) => {
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
                                    && conversation.is_some()
                                    && st.prime().and_then(|prime| prime.conversation.as_ref())
                                        == conversation.as_ref())
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
    pub(super) async fn apply_prime_row(self: &Arc<Self>, row: PrimeRow) -> Arc<Session> {
        let session = match self.find(&row.id).await {
            Ok(s) => s,
            Err(_) => {
                let mut summary =
                    new_summary(&row.id, AgentKind::Prime, SessionKind::Root, &row.cwd);
                summary.created_at = row.created_at.unwrap_or_else(now_ms);
                let state = SessionState::new(summary, None, BackendState::prime());
                let session = Arc::new(Session::new(
                    row.id.clone(),
                    AgentKind::Prime,
                    row.cwd,
                    state,
                ));
                let mut sessions = self.sessions.write().await;
                match sessions.iter().find(|s| s.id == row.id) {
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
        s.kind = row.kind;
        s.parent_id = row.parent_id;
        s.name = row.name;
        s.running_subagents = row.running_subagents;
        s.last_active_at = row.last_active_at.or(s.last_active_at);
        s.title = match (&s.name, row.first_message.as_deref()) {
            (Some(name), _) => name.clone(),
            (None, Some(first)) if !first_line(first, 60).is_empty() => first_line(first, 60),
            _ => default_title(&s.cwd),
        };
        s.status = row.status;
        s.error = None;
        if let Some(model) = row.model {
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
        if let Some(level) = row.thinking_level {
            s.thinking_level = Some(level);
        }
        if let Some(queue) = row.queue {
            s.queue = queue;
        }
        st.session_file = row.session_file;
        // `new_session` replaces the conversation, and the window chosen for the session goes with it, or a
        // restarted bridge would look for the window under an id the session no longer has.
        if let Some(current) = row.conversation {
            let known = st.prime().and_then(|prime| prime.conversation.as_ref());
            if known != Some(&current) {
                let before = limit_key(&session, &st).to_string();
                self.rekey_limit(&before, &current);
                if let Some(prime) = st.prime_mut() {
                    prime.conversation = Some(current);
                }
            }
        }
        if let Some(own) = row.cost {
            st.summary.cost = self
                .prime_cost(st.session_file.as_deref(), own, st.summary.cost)
                .max(st.gateway_cost);
        }
        let mark = (row.activity, row.message_count);
        let mut changed = true;
        if let Some(prime) = st.prime_mut() {
            if let Some(pid) = row.worker_pid {
                prime.worker_pid = Some(pid);
            }
            prime.tools = match (row.running_tools, prime.tools) {
                (None, _) => None,
                (Some(calls), Some((n, since))) if n == calls => Some((n, since)),
                (Some(calls), _) => Some((calls, Instant::now())),
            };
            changed = prime.roster_mark != mark;
            prime.roster_mark = mark;
        }
        let refresh = changed || st.summary.thinking_levels.is_empty();
        self.publish_summary(&st);
        if refresh {
            self.schedule_refresh(&session, &mut st);
        }
        drop(st);
        session
    }

    /// Prime: attach to the daemon session so its events stream, and load the transcript.
    pub async fn ensure_attached(self: &Arc<Self>, session: &Arc<Session>) -> Result<()> {
        if session.backend != Backend::Prime {
            return Ok(());
        }
        let current = {
            let st = session.state.lock().await;
            st.prime().is_some_and(|prime| prime.attached).then(|| {
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
        let Attached { messages, goal } = Attached::read(&data);
        self.load_history(session, &messages).await;
        let mut st = session.state.lock().await;
        if let Some(prime) = st.prime_mut() {
            prime.attached = true;
        }
        st.summary.goal = goal;
        self.publish_summary(&st);
        st.transcript.reset(&messages);
        self.send_snapshot(&session.id, &mut st);
        Ok(())
    }

    /// Prime: read the history before the last compaction from the session's file, off the session lock. A
    /// failure only leaves the earlier history out.
    pub(super) async fn load_history(&self, session: &Session, messages: &[Value]) {
        let summary = agent_wire::compaction_summary(messages);
        let (file, previous) = {
            let mut st = session.state.lock().await;
            let Some(prime) = st.prime_mut() else {
                return;
            };
            if summary.is_none() {
                prime.history = None;
                return;
            }
            let previous = prime.history.clone();
            (st.session_file.clone(), previous)
        };
        let (Some(file), Some(summary)) = (file, summary.map(str::to_string)) else {
            return;
        };
        let path = file.clone();
        match tokio::task::spawn_blocking(move || history::load(&path, &summary, previous)).await {
            Ok(Ok(history)) => {
                if let Some(prime) = session.state.lock().await.prime_mut() {
                    prime.history = history;
                }
            }
            Ok(Err(e)) => eprintln!("history of {}: {file}: {e}", session.id),
            Err(e) => eprintln!("history of {}: {e}", session.id),
        }
    }

    // ---- client operations ----

    /// A Prime session's spending: its own calls (as Prime reports them, or as its file records them if that's more)
    /// plus its subagents'. Never less than before: a total doesn't go back down.
    pub(super) fn prime_cost(&self, file: Option<&str>, own: f64, before: f64) -> f64 {
        let total = match file.and_then(|f| self.costs.read(f)) {
            Some((recorded, subagents)) => own.max(recorded) + subagents,
            None => own,
        };
        total.max(before)
    }
}
