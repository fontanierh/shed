//! What a client can ask of a running session.

use std::sync::Arc;

use anyhow::{bail, Context, Result};
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
        if session.backend == Backend::Pi {
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
        let result = match session.backend {
            Backend::Prime => {
                let prompt = Ask::Prompt {
                    message: text,
                    delivery: Delivery::SteerOrQueue,
                };
                self.command(session, prompt).await
            }
            Backend::Pi | Backend::PiSubagent => {
                let busy = matches!(
                    session.state.lock().await.summary.status,
                    SessionStatus::Running | SessionStatus::Compacting
                );
                if busy {
                    self.command(session, Ask::Steer(text)).await
                } else {
                    let prompt = Ask::Prompt {
                        message: text.clone(),
                        delivery: Delivery::Turn,
                    };
                    match self.command(session, prompt).await {
                        Err(e) if e.to_string().to_lowercase().contains("stream") => {
                            self.command(session, Ask::Steer(text)).await
                        }
                        other => other,
                    }
                }
            }
        };
        let mut st = session.state.lock().await;
        if let (Err(_), Some(id)) = (&result, &send_id) {
            st.forget_send(id);
        }
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
        match session.backend {
            Backend::Prime => {
                let message = match instructions {
                    Some(text) => format!("/compact {text}"),
                    None => "/compact".to_string(),
                };
                let prompt = Ask::Prompt {
                    message,
                    delivery: Delivery::FollowUp,
                };
                self.command(session, prompt).await
            }
            Backend::Pi | Backend::PiSubagent => {
                self.command(session, Ask::Compact { instructions }).await
            }
        }
    }

    /// Prime's `/goal clear`, steered in so a running turn picks it up at its next step instead of after the turn.
    pub async fn clear_goal(self: &Arc<Self>, session: &Arc<Session>) -> Result<Value> {
        match session.backend {
            Backend::Prime => {
                let prompt = Ask::Prompt {
                    message: "/goal clear".into(),
                    delivery: Delivery::Steer,
                };
                self.command(session, prompt).await
            }
            Backend::Pi | Backend::PiSubagent => bail!("Only Prime sessions have goals"),
        }
    }

    /// Prime offers no command for this (its terminal asks the user itself, and never asks a remote client), but its
    /// kernels run on this machine: kill the session's own kernel, found by the session id in its environment, along
    /// with whatever it started. Prime notices the kernel is gone and starts a fresh one on the next Python call.
    pub async fn restart_kernel(self: &Arc<Self>, session: &Arc<Session>) -> Result<Value> {
        match session.backend {
            Backend::Prime => {}
            Backend::Pi | Backend::PiSubagent => bail!("Only Prime sessions have a Python kernel"),
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
        let output = tokio::process::Command::new("/bin/ps")
            .args(["-axww", "-E", "-o", "pid=,ppid=,command="])
            .output()
            .await?;
        if !output.status.success() {
            bail!("the processes on this computer can't be listed");
        }
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
        let killed = tokio::process::Command::new("/bin/kill")
            .arg("-9")
            .args(&pids)
            .output()
            .await?;
        // Some of them may have gone on their own meanwhile, which `kill` also reports as a failure: said, not
        // answered as an error, since the kernel it was asked to end is ended either way.
        if !killed.status.success() {
            eprintln!(
                "restarting the kernel of {}: kill said {}",
                session.id,
                String::from_utf8_lossy(&killed.stderr).trim()
            );
        }
        Ok(json!({ "killed": doomed.len() }))
    }

    /// A plain abort leaves Prime holding steered messages until the next prompt; `abort_and_send_queued` delivers
    /// them at once, so the agent hears about the stop and carries on. Prime falls back to a plain abort when nothing
    /// is queued.
    pub async fn stop_tool(self: &Arc<Self>, session: &Arc<Session>) -> Result<Value> {
        let stop = match session.backend {
            Backend::Prime => Ask::AbortAndSendQueued,
            Backend::Pi | Backend::PiSubagent => Ask::Abort,
        };
        self.command(session, stop).await
    }

    pub async fn new_session(self: &Arc<Self>, session: &Arc<Session>) -> Result<Value> {
        let result = self.command(session, Ask::NewSession).await?;
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
