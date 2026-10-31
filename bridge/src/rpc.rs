//! One agent subprocess speaking the Pi/Prime JSONL RPC protocol on stdin/stdout.

use std::collections::{HashMap, VecDeque};
use std::process::Stdio;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use anyhow::{anyhow, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, Command};
use tokio::sync::{mpsc, oneshot};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AgentKind {
    Pi,
    Prime,
}

pub struct SpawnOptions {
    pub agent: AgentKind,
    pub cwd: String,
    pub model: Option<String>,
    pub thinking: Option<String>,
    pub resume: Option<String>,
    pub env: Vec<(String, String)>,
}

/// What the child's stdout produces besides command responses.
pub enum ChildOutput {
    Event(Value),
    Exited(String),
}

type Pending = oneshot::Sender<Result<Value, String>>;

pub struct RpcChild {
    stdin: tokio::sync::Mutex<ChildStdin>,
    pending: Arc<Mutex<HashMap<String, Pending>>>,
    stderr_tail: Arc<Mutex<VecDeque<String>>>,
    next_id: AtomicU64,
    child: Mutex<Option<Child>>,
}

fn command_line(opts: &SpawnOptions) -> (String, Vec<String>) {
    let mut args: Vec<String> = vec!["--mode".into(), "rpc".into()];
    let program = match opts.agent {
        AgentKind::Pi => "pi",
        AgentKind::Prime => {
            args.extend(["--cwd".into(), opts.cwd.clone()]);
            "prime-agent"
        }
    };
    if let Some(model) = &opts.model {
        args.extend(["--model".into(), model.clone()]);
    }
    if let Some(thinking) = &opts.thinking {
        args.extend(["--thinking".into(), thinking.clone()]);
    }
    args.extend(["--append-system-prompt".into(), crate::media::GUIDE.into()]);
    if let Some(resume) = &opts.resume {
        let flag = if opts.agent == AgentKind::Pi { "--session" } else { "--resume" };
        args.extend([flag.into(), resume.clone()]);
    }
    (program.into(), args)
}

impl RpcChild {
    pub fn spawn(opts: &SpawnOptions) -> Result<(Arc<RpcChild>, mpsc::UnboundedReceiver<ChildOutput>)> {
        let (program, args) = command_line(opts);
        let mut child = Command::new(&program)
            .args(&args)
            .current_dir(&opts.cwd)
            .envs(opts.env.iter().cloned())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .map_err(|e| anyhow!("failed to start {program}: {e}"))?;

        let stdin = child.stdin.take().expect("piped stdin");
        let stdout = child.stdout.take().expect("piped stdout");
        let stderr = child.stderr.take().expect("piped stderr");
        let (tx, rx) = mpsc::unbounded_channel();
        let rpc = Arc::new(RpcChild {
            stdin: tokio::sync::Mutex::new(stdin),
            pending: Arc::new(Mutex::new(HashMap::new())),
            stderr_tail: Arc::new(Mutex::new(VecDeque::new())),
            next_id: AtomicU64::new(0),
            child: Mutex::new(Some(child)),
        });

        let tail = rpc.stderr_tail.clone();
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

        // Read stdout continuously (a stalled reader stalls the agent) and split strictly on LF:
        // U+2028/U+2029 are valid inside JSON strings.
        let pending = rpc.pending.clone();
        let reader_rpc = Arc::downgrade(&rpc);
        tokio::spawn(async move {
            let mut reader = BufReader::new(stdout);
            let mut buf = Vec::new();
            loop {
                buf.clear();
                match reader.read_until(b'\n', &mut buf).await {
                    Ok(0) | Err(_) => break,
                    Ok(_) => {}
                }
                let line = String::from_utf8_lossy(&buf);
                let line = line.trim_end_matches(['\n', '\r']);
                let Ok(record) = serde_json::from_str::<Value>(line) else { continue };
                if record["type"] == "response" {
                    let Some(id) = record["id"].as_str() else { continue };
                    let Some(waiter) = pending.lock().unwrap().remove(id) else { continue };
                    let result = if record["success"] == true {
                        Ok(record.get("data").cloned().unwrap_or(Value::Null))
                    } else {
                        Err(record["error"].as_str().unwrap_or("command failed").to_string())
                    };
                    let _ = waiter.send(result);
                } else {
                    let _ = tx.send(ChildOutput::Event(record));
                }
            }
            let reason = match reader_rpc.upgrade() {
                Some(rpc) => rpc.wait_exit().await,
                None => "agent exited".into(),
            };
            for (_, waiter) in pending.lock().unwrap().drain() {
                let _ = waiter.send(Err(reason.clone()));
            }
            let _ = tx.send(ChildOutput::Exited(reason));
        });

        Ok((rpc, rx))
    }

    pub async fn send(&self, kind: &str, fields: Value) -> Result<Value> {
        let id = format!("b{}", self.next_id.fetch_add(1, Ordering::Relaxed) + 1);
        let mut command = json!({ "id": id, "type": kind });
        if let (Some(obj), Value::Object(extra)) = (command.as_object_mut(), fields) {
            obj.extend(extra);
        }
        let (tx, rx) = oneshot::channel();
        self.pending.lock().unwrap().insert(id.clone(), tx);
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
                self.pending.lock().unwrap().remove(&id);
                return Err(anyhow!("agent is not running: {e}"));
            }
        }
        match rx.await {
            Ok(Ok(data)) => Ok(data),
            Ok(Err(e)) => Err(anyhow!(e)),
            Err(_) => Err(anyhow!("agent exited")),
        }
    }

    /// Close stdin for an orderly shutdown; kill if the agent hasn't exited after 3 seconds.
    pub async fn close(&self) {
        let _ = self.stdin.lock().await.shutdown().await;
        let child = self.child.lock().unwrap().take();
        if let Some(mut child) = child {
            tokio::spawn(async move {
                if tokio::time::timeout(std::time::Duration::from_secs(3), child.wait()).await.is_err() {
                    let _ = child.kill().await;
                }
            });
        }
    }

    async fn wait_exit(&self) -> String {
        let child = self.child.lock().unwrap().take();
        let code = match child {
            Some(mut child) => child.wait().await.ok().and_then(|s| s.code()),
            None => None,
        };
        let tail: Vec<String> = self.stderr_tail.lock().unwrap().iter().rev().take(5).rev().cloned().collect();
        let code = code.map(|c| format!(" (code {c})")).unwrap_or_default();
        if tail.is_empty() {
            format!("agent exited{code}")
        } else {
            format!("agent exited{code}: {}", tail.join("\n"))
        }
    }
}
