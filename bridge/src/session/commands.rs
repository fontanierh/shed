//! What a client can ask of a running session.

use std::sync::Arc;

use anyhow::{bail, Result};
use serde_json::{json, Value};

use super::{default_title, App, Backend, Session};
use crate::ask::{Ask, Delivery};
use crate::protocol::SessionStatus;

impl App {
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
        let stopped = session.state.lock().await.stopped();
        if !stopped {
            self.command(session, Ask::SetName(name.to_string()))
                .await?;
            self.refresh(session).await?;
        }
        let mut st = session.state.lock().await;
        st.named = true;
        st.summary.title = name.to_string();
        self.publish_summary(&st);
        drop(st);
        if session.backend == Backend::Started {
            tokio::spawn(self.clone().save_registry());
        }
        Ok(())
    }

    /// Prompt when idle; steer while the agent is working.
    pub async fn send_text(
        self: &Arc<Self>,
        session: &Arc<Session>,
        text: String,
        send_id: Option<String>,
    ) -> Result<Value> {
        // One message with a send id at a time: a repeat that arrives while the first copy is still with the agent
        // waits here, and then finds the id kept (taken) or forgotten (refused, so this copy goes).
        // The server runs each operation as its own task, so a send is not cut short when its connection goes.
        let _sending = match &send_id {
            Some(_) => Some(session.sending.lock().await),
            None => None,
        };
        // Sent again after a lost reply: it was taken the first time, and that is the answer.
        if let Some(id) = &send_id {
            if !session.state.lock().await.take_send(id) {
                return Ok(json!({}));
            }
        }
        let verbs = self.agent(session.agent).verbs();
        let busy = matches!(
            session.state.lock().await.summary.status,
            SessionStatus::Running | SessionStatus::Compacting
        );
        let ask = verbs.message(text.clone(), busy);
        let turn = matches!(
            ask,
            Ask::Prompt {
                delivery: Delivery::Turn,
                ..
            }
        );
        let result = match self.command(session, ask).await {
            // A turn began between the look at its status and the prompt.
            Err(e) if turn && crate::agent_wire::refused_as_busy(&e) => {
                self.command(session, verbs.message(text, true)).await
            }
            other => other,
        };
        let mut st = session.state.lock().await;
        if let (Err(_), Some(id)) = (&result, &send_id) {
            st.forget_send(id);
        }
        self.schedule_refresh(session, &mut st);
        result
    }

    /// Compacting, in the agent's words (`Verbs::compact` says why Prime's differ).
    pub async fn compact(
        self: &Arc<Self>,
        session: &Arc<Session>,
        instructions: Option<String>,
    ) -> Result<Value> {
        let instructions = instructions.filter(|text| !text.trim().is_empty());
        let ask = self.agent(session.agent).verbs().compact(instructions);
        self.command(session, ask).await
    }

    pub async fn clear_goal(self: &Arc<Self>, session: &Arc<Session>) -> Result<Value> {
        let Some(ask) = self.agent(session.agent).verbs().clear_goal() else {
            bail!("Only Prime sessions have goals")
        };
        self.command(session, ask).await
    }

    /// Kill the session's Python kernel, for an agent whose sessions have one: it starts a fresh one on the next
    /// Python call.
    pub async fn restart_kernel(self: &Arc<Self>, session: &Arc<Session>) -> Result<Value> {
        let file = session.state.lock().await.session_file.clone();
        let Some(restart) = self.agent(session.agent).verbs().restart_kernel(file) else {
            bail!("Only Prime sessions have a Python kernel")
        };
        restart.await
    }

    pub async fn follow_up(
        self: &Arc<Self>,
        session: &Arc<Session>,
        text: String,
    ) -> Result<Value> {
        let Some(ask) = self.agent(session.agent).verbs().follow_up(text) else {
            bail!("this agent does not queue follow-up messages")
        };
        self.command(session, ask).await
    }

    pub async fn abort(self: &Arc<Self>, session: &Arc<Session>) -> Result<Value> {
        let ask = self.agent(session.agent).verbs().abort();
        self.command(session, ask).await
    }

    pub async fn stop_tool(self: &Arc<Self>, session: &Arc<Session>) -> Result<Value> {
        let stop = self.agent(session.agent).verbs().stop_tool();
        self.command(session, stop).await
    }

    pub async fn set_auto_compaction(
        self: &Arc<Self>,
        session: &Arc<Session>,
        enabled: bool,
    ) -> Result<()> {
        let Some(ask) = self.agent(session.agent).verbs().auto_compaction(enabled) else {
            bail!("this agent compacts on its own")
        };
        self.command(session, ask).await?;
        self.refresh(session).await
    }

    pub async fn answer_question(
        self: &Arc<Self>,
        session: &Arc<Session>,
        question_id: String,
        answers: Vec<Value>,
    ) -> Result<()> {
        let Some(ask) = self
            .agent(session.agent)
            .verbs()
            .answer(question_id, answers)
        else {
            bail!("this agent does not ask questions")
        };
        self.command(session, ask).await?;
        Ok(())
    }

    pub async fn new_session(self: &Arc<Self>, session: &Arc<Session>) -> Result<Value> {
        let Some(ask) = self.agent(session.agent).verbs().new_session() else {
            bail!("start a new session from the app instead")
        };
        let result = self.command(session, ask).await?;
        {
            let mut st = session.state.lock().await;
            st.named = false;
            st.summary.title = default_title(&session.cwd);
        }
        self.resnapshot(session).await?;
        self.refresh(session).await?;
        Ok(result)
    }

    pub async fn session_models(
        &self,
        session: &Session,
    ) -> Result<Vec<crate::protocol::ModelInfo>> {
        let data = self.command(session, Ask::Models).await?;
        let mut models = crate::agent_wire::models(&data);
        // With Open Codex, a session switches among its models only, like the new-session list.
        if crate::opencodex::gateway(&self.store).is_some() {
            models.retain(|m| m.provider == crate::opencodex::PROVIDER);
        }
        Ok(models)
    }

    pub async fn set_model(
        self: &Arc<Self>,
        session: &Arc<Session>,
        provider: String,
        model_id: String,
    ) -> Result<()> {
        self.command(session, Ask::SetModel { provider, model_id })
            .await?;
        self.refresh(session).await
    }

    pub async fn set_thinking(
        self: &Arc<Self>,
        session: &Arc<Session>,
        level: String,
    ) -> Result<()> {
        self.command(session, Ask::SetThinkingLevel(level)).await?;
        self.refresh(session).await
    }
}
