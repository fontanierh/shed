//! Watchers: what the bridge keeps an eye on for every session without being asked. What each has spent, the
//! background commands it has running, and whether it is stuck waiting on one.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use super::{now_ms, App, Backend, Session, SessionState};
use crate::agent_wire;
use crate::protocol::{SessionStatus, Spend, WaitingOn};
use crate::rpc::AgentKind;
use crate::transcript::Transcript;

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

/// The session id an agent sends Open Codex with its requests: Prime's own session id, dsh's session file id, and the
/// id in a Pi session file's name (`<time>_<id>.jsonl`).
fn agent_session_id(agent: AgentKind, st: &SessionState) -> Option<String> {
    if agent == AgentKind::Prime {
        let conversation = st.prime().and_then(|prime| prime.conversation.as_ref());
        return conversation.map(|conversation| conversation.as_str().to_string());
    }
    let file = st.session_file.as_deref()?;
    let name = std::path::Path::new(file).file_stem()?.to_str()?;
    Some(match agent {
        AgentKind::Pi => name.rsplit('_').next().unwrap_or(name).to_string(),
        _ => name.to_string(),
    })
}

impl App {
    /// What each working session spends, from Open Codex's request history: each session's own requests, counted as
    /// they're made, give its cost; a top-level session's family (it and everything under it) gives what the run has
    /// spent and its rate over the last five minutes. A run starts when a top-level session gets to work and ends when
    /// it and its subagents settle, after one last count. Sessions on other providers keep the cost their agent reports.
    pub(super) async fn watch_spend(self: Arc<Self>) {
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
    pub(super) async fn watch_background_jobs(self: Arc<Self>) {
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
                    Backend::PiSubagent => continue,
                    Backend::Prime => {
                        let worker = session.state.lock().await.worker_pid();
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
        let tools = st.prime().and_then(|prime| prime.tools);
        let tool = tools.zip(st.worker_pid().and_then(|w| tree.kernel_of(w)));
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
                    let messages = agent_wire::messages(&data);
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
}
