//! Subagents of Pi and DeepSeek Harness sessions, mirrored as read-only sessions of their own.

use std::sync::Arc;

use tokio::sync::Mutex;

use super::{first_line, new_summary, now_ms, App, Backend, Session, SessionState};
use crate::agent_wire::{DshSubagent, PiSubagentCall, PiSubagents};
use crate::protocol::{ContextUsage, SessionKind, SessionStatus};
use crate::rpc::AgentKind;

impl App {
    /// Mirror the children of a Pi `subagent` tool call as read-only sessions.
    pub(super) async fn update_pi_subagents(
        self: &Arc<Self>,
        parent: &Arc<Session>,
        call: PiSubagentCall,
    ) {
        let PiSubagentCall {
            call_id,
            finished,
            children: Some(PiSubagents { chain, runs }),
        } = call
        else {
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
        let short_call: String = call_id
            .chars()
            .filter(|c| c.is_ascii_alphanumeric())
            .rev()
            .take(8)
            .collect::<String>()
            .chars()
            .rev()
            .collect();
        let count = runs.len();
        for (index, run) in runs.into_iter().enumerate() {
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
            let done = finished || run.settled() || (chain && index + 1 < count);
            let failed = run.failed();

            let mut st = session.state.lock().await;
            if !done
                || !matches!(
                    st.summary.status,
                    SessionStatus::Done | SessionStatus::Error
                )
            {
                st.summary.last_active_at = Some(now_ms());
            }
            st.summary.title = format!("{}: {}", run.agent, first_line(&run.task, 60));
            st.summary.name = Some(run.agent);
            st.summary.status = match (done, failed) {
                (false, _) => SessionStatus::Running,
                (true, true) => SessionStatus::Error,
                (true, false) => SessionStatus::Done,
            };
            st.summary.error = if done && failed {
                run.stderr.as_deref().map(|e| first_line(e, 200))
            } else {
                None
            };
            if let Some(model) = run.model {
                st.summary.model = Some(model.info(parent_window));
            }
            st.summary.cost = run.cost.max(st.gateway_cost);
            st.summary.context = parent_window.map(|window| ContextUsage {
                tokens: run.context_tokens,
                window,
                percent: run.context_tokens.map(|t| t as f64 * 100.0 / window as f64),
            });
            if run.messages.len() != st.sent_messages || done {
                st.transcript.reset(&run.messages);
                st.sent_messages = run.messages.len();
                self.send_snapshot(&session.id, &mut st);
            }
            self.publish_summary(&st);
        }
    }

    /// Mirror one of a DeepSeek session's subagents as a read-only session. dsh runs them in the session's own
    /// process, each with its own conversation, and can nest them; the feed gives one child's whole state at a time.
    pub(super) async fn update_dsh_subagent(
        self: &Arc<Self>,
        root: &Arc<Session>,
        child: DshSubagent,
    ) {
        let short = |dsh_id: &str| {
            dsh_id
                .chars()
                .filter(|c| c.is_ascii_alphanumeric())
                .take(8)
                .collect::<String>()
        };
        let id = format!("{}.{}", root.id, short(&child.id));
        let parent_id = match &child.parent {
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
        {
            let mut st = session.state.lock().await;
            st.summary.last_active_at = Some(child.last_active_at.unwrap_or_else(now_ms));
            if let Some(created) = child.created_at {
                st.summary.created_at = created;
            }
            st.summary.name = Some("subagent".into());
            st.summary.title = first_line(child.title.as_deref().unwrap_or("subagent"), 60);
            st.summary.status = child.status;
            st.summary.error = child.error.as_deref().map(|e| first_line(e, 200));
            st.summary.model = match child.model {
                Some(model) => Some(model.info(root_model.as_ref().and_then(|m| m.context_window))),
                None => root_model,
            };
            if child.messages.len() != st.sent_messages || child.status != SessionStatus::Running {
                st.transcript.reset(&child.messages);
                st.sent_messages = child.messages.len();
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
}
