//! Shared subprocess plumbing (`ChildProcess`) and Pi's JSONL RPC driver (`RpcChild`). Agents with their own
//! stdin/stdout protocol (such as `crate::dsh`) spawn `ChildProcess` directly and implement `Live` in their own module.

use std::collections::VecDeque;
use std::process::Stdio;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use anyhow::{anyhow, bail, Result};
use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use tokio::sync::mpsc;

pub use crate::agent::AgentKind;
use crate::channel::Offer;
use crate::requests::{Requests, Unanswered};

pub struct SpawnOptions {
    pub agent: AgentKind,
    /// The bridge's id for the session.
    pub session_id: String,
    pub cwd: String,
    pub model: Option<String>,
    pub thinking: Option<String>,
    pub resume: Option<String>,
}

/// The process to run for a session.
pub struct Launch {
    pub program: String,
    pub args: Vec<String>,
    /// On top of what every agent gets.
    pub env: Vec<(String, String)>,
}

/// What the child's stdout produces besides command responses.
pub enum ChildOutput {
    Event(Value),
    Exited(String),
}

/// One spawned agent OS process: its `Child` handle, bounded stderr ring buffer, orderly wait/kill, and exit summary.
pub struct ChildProcess {
    stderr_tail: Arc<Mutex<VecDeque<String>>>,
    child: Mutex<Option<Child>>,
}

impl ChildProcess {
    pub fn spawn_pipes(
        launch: Launch,
        cwd: &str,
    ) -> Result<(ChildStdin, ChildStdout, Arc<ChildProcess>)> {
        let Launch { program, args, env } = launch;
        let mut child = Command::new(&program)
            .args(&args)
            .current_dir(cwd)
            .envs(env)
            .env(crate::opencodex::KEY_ENV, crate::opencodex::KEY)
            // `shed-web`, the web command the guide tells the agents about.
            .env(
                "PATH",
                crate::web::prepend_path(
                    &crate::web::bin_dir(),
                    &std::env::var("PATH").unwrap_or_default(),
                ),
            )
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .map_err(|e| anyhow!("failed to start {program}: {e}"))?;

        let stdin = child.stdin.take().expect("piped stdin");
        let stdout = child.stdout.take().expect("piped stdout");
        let stderr = child.stderr.take().expect("piped stderr");
        let stderr_tail = Arc::new(Mutex::new(VecDeque::new()));
        let tail = stderr_tail.clone();
        tokio::spawn(async move {
            let mut lines = BufReader::new(stderr).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                if line.trim().is_empty() {
                    continue;
                }
                let mut tail = tail.lock().unwrap();
                tail.push_back(line);
                if tail.len() > 50 {
                    tail.pop_front();
                }
            }
        });

        let proc = Arc::new(ChildProcess {
            stderr_tail,
            child: Mutex::new(Some(child)),
        });
        Ok((stdin, stdout, proc))
    }

    /// The agent process's pid, while it is running.
    pub fn pid(&self) -> Option<u32> {
        self.child.lock().ok()?.as_ref().and_then(|c| c.id())
    }

    /// Wait up to 3 seconds for the process to exit on its own, then kill and reap it.
    pub async fn shutdown(&self) {
        let child = self.child.lock().unwrap().take();
        if let Some(mut child) = child {
            if tokio::time::timeout(std::time::Duration::from_secs(3), child.wait())
                .await
                .is_err()
            {
                if let Err(e) = child.kill().await {
                    eprintln!(
                        "an agent still running 3 seconds after its close could not be killed: {e}"
                    );
                }
            }
        }
    }

    pub async fn wait_exit(&self) -> String {
        let child = self.child.lock().unwrap().take();
        let code = match child {
            Some(mut child) => child.wait().await.ok().and_then(|s| s.code()),
            None => None,
        };
        let tail: Vec<String> = self
            .stderr_tail
            .lock()
            .unwrap()
            .iter()
            .rev()
            .take(5)
            .rev()
            .cloned()
            .collect();
        let code = code.map(|c| format!(" (code {c})")).unwrap_or_default();
        if tail.is_empty() {
            format!("agent exited{code}")
        } else {
            format!("agent exited{code}: {}", tail.join("\n"))
        }
    }
}

pub struct RpcChild {
    stdin: tokio::sync::Mutex<ChildStdin>,
    requests: Arc<Requests<String>>,
    next_id: AtomicU64,
    process: Arc<ChildProcess>,
}

/// What whoever asked is told when an agent is there and does not answer.
pub fn unanswered(kind: &str, after: std::time::Duration) -> anyhow::Error {
    anyhow!(
        "the agent did not answer `{kind}` within {} seconds",
        after.as_secs()
    )
}

/// A model table as Pi and Prime print it: a header, then a provider and a model id leading each row.
pub async fn listed_models(program: &str, args: &[&str]) -> Result<Value> {
    let home = crate::host::home_text();
    let run = Command::new(program)
        .args(args)
        .current_dir(if home.is_empty() { "/".into() } else { home })
        .env("PRIME_AGENT_TELEMETRY", "0")
        .stdin(Stdio::null())
        .kill_on_drop(true)
        .output();
    let output = tokio::time::timeout(std::time::Duration::from_secs(30), run)
        .await
        .map_err(|_| anyhow!("{program} took too long to list its models"))?
        .map_err(|e| anyhow!("failed to run {program}: {e}"))?;
    let text = String::from_utf8_lossy(&output.stdout);
    let models: Vec<Value> = text
        .lines()
        .skip_while(|line| !line.trim_start().starts_with("provider"))
        .skip(1)
        .filter_map(|line| {
            let mut fields = line.split_whitespace();
            let (provider, id) = (fields.next()?, fields.next()?);
            Some(json!({ "provider": provider, "id": id, "name": id }))
        })
        .collect();
    if !output.status.success() {
        let said = String::from_utf8_lossy(&output.stderr);
        let said = said.lines().find(|l| !l.trim().is_empty()).unwrap_or("");
        if models.is_empty() {
            bail!(
                "{program} could not list its models ({}): {said}",
                output.status
            );
        }
        eprintln!(
            "{program} listed its models but ended with {}: {said}",
            output.status
        );
    }
    Ok(json!(models))
}

impl RpcChild {
    pub fn spawn(
        launch: Launch,
        opts: &SpawnOptions,
    ) -> Result<(Arc<RpcChild>, mpsc::UnboundedReceiver<ChildOutput>)> {
        let (stdin, stdout, process) = ChildProcess::spawn_pipes(launch, &opts.cwd)?;
        let (tx, rx) = mpsc::unbounded_channel();
        let rpc = Arc::new(RpcChild {
            stdin: tokio::sync::Mutex::new(stdin),
            requests: Arc::default(),
            next_id: AtomicU64::new(0),
            process: process.clone(),
        });

        // Read stdout continuously (a stalled reader stalls the agent) and split strictly on LF:
        // U+2028/U+2029 are valid inside JSON strings.
        let requests = rpc.requests.clone();
        tokio::spawn(async move {
            let mut reader = BufReader::new(stdout);
            let mut buf = Vec::new();
            while let Some(record) =
                crate::requests::next_message(&mut reader, &mut buf, "the agent").await
            {
                if record["type"] == "response" {
                    let Some(id) = record["id"].as_str() else {
                        eprintln!("the agent answered without saying which command: {record}");
                        continue;
                    };
                    let result = if record["success"] == true {
                        Ok(record.get("data").cloned().unwrap_or(Value::Null))
                    } else {
                        Err(record["error"]
                            .as_str()
                            .unwrap_or("command failed")
                            .to_string())
                    };
                    requests.answer(id, result);
                } else {
                    tx.offer(ChildOutput::Event(record));
                }
            }
            let reason = process.wait_exit().await;
            requests.refuse_all(&reason);
            tx.offer(ChildOutput::Exited(reason));
        });

        Ok((rpc, rx))
    }

    async fn send(&self, ask: crate::ask::Ask) -> Result<Value> {
        let limit = ask.limit();
        let Some((kind, fields)) = ask.wire() else {
            bail!("this agent has no {ask:?} command");
        };
        let id = format!("b{}", self.next_id.fetch_add(1, Ordering::Relaxed) + 1);
        let mut command = json!({ "id": id, "type": kind });
        if let (Some(obj), Value::Object(extra)) = (command.as_object_mut(), fields) {
            obj.extend(extra);
        }
        let asked = self.requests.ask(id);
        let mut line = serde_json::to_vec(&command)?;
        line.push(b'\n');
        {
            let mut stdin = self.stdin.lock().await;
            if let Err(e) = async {
                stdin.write_all(&line).await?;
                stdin.flush().await
            }
            .await
            {
                return Err(anyhow!("agent is not running: {e}"));
            }
        }
        match asked.answer(limit).await {
            Ok(Ok(data)) => Ok(data),
            Ok(Err(e)) => Err(anyhow::Error::new(crate::agent::Refused(e))),
            Err(Unanswered::Gone) => Err(anyhow!("agent exited")),
            Err(Unanswered::Late(after)) => Err(unanswered(kind, after)),
        }
    }

    async fn close(&self) {
        if let Err(e) = self.stdin.lock().await.shutdown().await {
            eprintln!("closing an agent's input: {e}");
        }
        self.process.shutdown().await;
    }
}

impl crate::agent::Live for RpcChild {
    fn send(&self, ask: crate::ask::Ask) -> futures_util::future::BoxFuture<'_, Result<Value>> {
        Box::pin(RpcChild::send(self, ask))
    }

    fn pid(&self) -> Option<u32> {
        self.process.pid()
    }

    fn close(&self) -> futures_util::future::BoxFuture<'_, ()> {
        Box::pin(RpcChild::close(self))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agent::Live;

    /// An agent that pays no heed to its input closing is killed, and is gone by the time `close` returns: a resume
    /// right after may start the session again without two agents writing one file.
    #[tokio::test(start_paused = true)]
    async fn a_close_returns_once_the_agent_is_gone() {
        let launch = Launch {
            program: "/bin/sleep".into(),
            args: vec!["30".into()],
            env: Vec::new(),
        };
        let opts = SpawnOptions {
            agent: AgentKind::Pi,
            session_id: "s1".into(),
            cwd: "/".into(),
            model: None,
            thinking: None,
            resume: None,
        };
        let (child, _output) = RpcChild::spawn(launch, &opts).unwrap();
        let pid = child.pid().expect("it runs").to_string();
        child.close().await;
        let alive = std::process::Command::new("/bin/kill")
            .args(["-0", &pid])
            .stderr(Stdio::null())
            .status()
            .unwrap()
            .success();
        assert!(!alive, "the agent outlived its close");
    }
}
