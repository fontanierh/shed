//! A session's state as its agent reports it, and its context window: the one chosen for it, and compacting when
//! it gets near.

use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{bail, Result};
use serde_json::Value;

use super::{limit_key, App, Backend, Session, SessionState};
use crate::agent_wire::{self, AgentState, AgentStats, ConversationId};
use crate::ask::Ask;
use crate::protocol::{ModelInfo, SessionStatus};

/// Room left for the next turn when compacting for a chosen window, as Pi's own auto-compaction leaves (16k), but
/// never more than a fifth of a small window.
fn compaction_reserve(window: u64) -> u64 {
    16_384.min(window / 5)
}

impl App {
    pub(super) fn schedule_refresh(
        self: &Arc<Self>,
        session: &Arc<Session>,
        st: &mut SessionState,
    ) {
        if st.refresh_scheduled || session.backend == Backend::Subagent {
            return;
        }
        st.refresh_scheduled = true;
        let (app, session) = (self.clone(), session.clone());
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(150)).await;
            if let Err(e) = app.refresh(&session).await {
                eprintln!("refreshing {} failed: {e}", session.id);
            }
        });
    }

    /// Re-read state and stats from the agent and publish the session summary.
    pub async fn refresh(self: &Arc<Self>, session: &Arc<Session>) -> Result<()> {
        let (levels_for, moves) = {
            let mut st = session.state.lock().await;
            st.refresh_scheduled = false;
            if st.stopped() {
                return Ok(());
            }
            (st.levels_for.clone(), st.status_moves)
        };
        let (state, stats) = tokio::join!(
            self.command(session, Ask::State),
            self.command(session, Ask::Stats)
        );
        let state = AgentState::read(&state?);
        // Without its figures the session still shows; they come with the next refresh.
        let stats = match stats {
            Ok(stats) => Some(AgentStats::read(&stats)),
            Err(e) => {
                eprintln!("session {}: no figures from its agent: {e:#}", session.id);
                None
            }
        };
        let model_key = state
            .model
            .as_ref()
            .map(|m| format!("{}/{}", m.provider, m.id));
        let levels = if model_key != levels_for {
            Some(self.thinking_levels(session, state.model.as_ref()).await)
        } else {
            None
        };

        let mut st = session.state.lock().await;
        if let Some(levels) = levels {
            st.summary.thinking_levels = levels;
            st.levels_for = model_key;
        }
        if let Some(mut model) = state.model {
            // Prime's daemon state omits the context window; stats carry it.
            if model.context_window.is_none() {
                model.context_window = stats
                    .as_ref()
                    .and_then(|stats| stats.context.as_ref())
                    .map(|context| context.window);
            }
            st.summary.model = Some(model);
        }
        if let Some(level) = state.thinking_level {
            st.summary.thinking_level = Some(level);
        }
        if let Some(auto) = state.auto_compaction {
            st.summary.auto_compaction = auto;
        }
        // An event that moved the status while the agent answered is newer than the answer: a turn the agent began
        // by itself meanwhile must not be set back to idle, with nothing to refresh it until the turn ends.
        if st.status_moves == moves
            && !matches!(
                st.summary.status,
                SessionStatus::Stopped | SessionStatus::Error | SessionStatus::Done
            )
        {
            st.summary.status = state.status;
        }
        if let Some(name) = state.name {
            st.named = true;
            st.summary.title = name;
        }
        if let Some(queue) = state.queue {
            st.summary.queue = queue;
        }
        if let Some(stats) = stats {
            if let Some(own) = stats.cost {
                st.summary.cost = match session.backend {
                    Backend::Prime => {
                        let file = stats.session_file.or_else(|| st.session_file.clone());
                        self.prime_cost(file.as_deref(), own, st.summary.cost)
                    }
                    Backend::Started | Backend::Subagent => own,
                }
                .max(st.gateway_cost);
            }
            st.summary.context = stats.context;
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
        let file_changed = state.session_file.is_some() && state.session_file != st.session_file;
        if file_changed {
            st.session_file = state.session_file;
        }
        self.publish_summary(&st);
        drop(st);
        if file_changed && session.backend == Backend::Started {
            tokio::spawn(self.clone().save_registry());
        }
        if compact {
            self.compact_for_limit(session);
        }
        Ok(())
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
            if let Err(e) = app.refresh(&session).await {
                eprintln!("refreshing {} failed: {e}", session.id);
            }
        });
    }

    /// A window chosen before the session's `sessionId` was known (or by a bridge that saved it under the
    /// `activeSessionId`) moves to it, so it survives the session reopening.
    pub(super) fn rekey_limit(&self, id: &str, key: &ConversationId) {
        let limits = {
            let mut limits = self.limits.lock().unwrap();
            let Some(limit) = limits.remove(id) else {
                return;
            };
            limits.entry(key.as_str().to_string()).or_insert(limit);
            limits.clone()
        };
        if let Err(e) = self.store.save_limits(&limits) {
            eprintln!("failed to save context windows: {e}");
        }
    }

    pub(super) fn forget_limit(&self, id: &str) {
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
        let stopped = st.stopped();
        if stopped {
            self.publish_summary(&st);
        }
        drop(st);
        if !stopped {
            self.refresh(session).await?;
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
        if session.backend == Backend::Started {
            if let Ok(data) = self.command(session, Ask::ThinkingLevels).await {
                if let Some(levels) = agent_wire::thinking_levels(&data) {
                    return levels;
                }
            }
        }
        // Prime has no levels command; its model catalog marks unsupported levels as null.
        let models = self
            .command(session, Ask::Models)
            .await
            .unwrap_or(Value::Null);
        agent_wire::model_levels(&models, model, &agent_wire::THINKING_LEVELS)
    }
}
