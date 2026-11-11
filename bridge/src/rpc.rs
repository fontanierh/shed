//! One agent subprocess speaking Pi's JSONL RPC protocol on stdin/stdout: Pi itself, or DeepSeek Harness through
//! Shed's plugin (`crate::dsh`). Prime's sessions go through its daemon instead (`crate::prime`).

use std::collections::{HashMap, VecDeque};
use std::process::Stdio;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use anyhow::{anyhow, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, Command};
use tokio::sync::mpsc;

use crate::channel::Offer;
use crate::requests::{Requests, Unanswered, QUICK, SLOW};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(test, derive(strum::EnumIter))]
#[serde(rename_all = "lowercase")]
pub enum AgentKind {
    Pi,
    Prime,
    /// DeepSeek Harness, driven through Shed's dsh plugin by `crate::dsh`.
    Deepseek,
}

pub struct SpawnOptions {
    pub agent: AgentKind,
    pub cwd: String,
    pub model: Option<String>,
    pub thinking: Option<String>,
    pub resume: Option<String>,
    pub env: Vec<(String, String)>,
}

/// The process to run for a session.
pub struct Launch {
    pub program: String,
    pub args: Vec<String>,
    /// On top of what every agent gets.
    pub env: Vec<(String, String)>,
    pub protocol: Protocol,
}

/// What the process speaks on its stdin and stdout.
#[derive(PartialEq)]
pub enum Protocol {
    /// Pi's JSONL RPC.
    Pi,
    /// Shed's dsh plugin, which `crate::dsh` translates.
    Dsh,
}

/// What the child's stdout produces besides command responses.
pub enum ChildOutput {
    Event(Value),
    Exited(String),
}

pub struct RpcChild {
    /// Pi: commands go straight to stdin. DeepSeek: `dsh` owns stdin and answers them.
    stdin: tokio::sync::Mutex<Option<ChildStdin>>,
    dsh: Option<Arc<crate::dsh::Dsh>>,
    requests: Arc<Requests<String>>,
    stderr_tail: Arc<Mutex<VecDeque<String>>>,
    next_id: AtomicU64,
    child: Mutex<Option<Child>>,
}

/// What whoever asked is told when an agent is there and does not answer.
pub fn unanswered(kind: &str, after: std::time::Duration) -> anyhow::Error {
    anyhow!(
        "the agent did not answer `{kind}` within {} seconds",
        after.as_secs()
    )
}

/// The models an agent can start a session on, as `[{provider, id, name}]`: what Pi and Prime list from their own
/// settings, and the providers set up in DeepSeek Harness. Kept a minute, since listing starts the agent.
pub async fn list_models(agents: &crate::agent::Agents, agent: AgentKind) -> Result<Value> {
    static CACHE: Mutex<Option<HashMap<AgentKind, (std::time::Instant, Value)>>> = Mutex::new(None);
    if let Some((at, models)) = CACHE.lock().unwrap().get_or_insert_default().get(&agent) {
        if at.elapsed().as_secs() < 60 {
            return Ok(models.clone());
        }
    }
    // With Open Codex, each agent offers exactly its catalog: written into the agent's configuration first, then
    // listed as the agent sees it.
    let gateway = crate::opencodex::gateway();
    if let Some(gateway) = &gateway {
        if let Err(e) = crate::opencodex::sync(gateway).await {
            eprintln!("Open Codex catalog: {e}");
        }
    }
    let mut models = agents.get(agent).models().await?;
    if gateway.is_some() {
        if let Some(list) = models.as_array_mut() {
            list.retain(|m| m["provider"] == crate::opencodex::PROVIDER);
        }
    }
    CACHE
        .lock()
        .unwrap()
        .get_or_insert_default()
        .insert(agent, (std::time::Instant::now(), models.clone()));
    Ok(models)
}

/// A model table as Pi and Prime print it: a header, then a provider and a model id leading each row.
pub async fn listed_models(program: &str, args: &[&str]) -> Result<Value> {
    let home = std::env::var("HOME").unwrap_or_default();
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
    Ok(json!(models))
}

impl RpcChild {
    pub fn spawn(
        launch: Launch,
        opts: &SpawnOptions,
    ) -> Result<(Arc<RpcChild>, mpsc::UnboundedReceiver<ChildOutput>)> {
        let Launch {
            program,
            args,
            env,
            protocol,
        } = launch;
        let mut child = Command::new(&program)
            .args(&args)
            .current_dir(&opts.cwd)
            .envs(opts.env.iter().cloned())
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
        let mut stdout = child.stdout.take();
        let stderr = child.stderr.take().expect("piped stderr");
        let (tx, rx) = mpsc::unbounded_channel();
        let deepseek = protocol == Protocol::Dsh;
        let rpc = Arc::new_cyclic(|me: &std::sync::Weak<RpcChild>| {
            let me = me.clone();
            let exited = async move {
                match me.upgrade() {
                    Some(rpc) => rpc.wait_exit().await,
                    None => "agent exited".into(),
                }
            };
            let (stdin, dsh) = if deepseek {
                let stdout = stdout.take().expect("piped stdout");
                (
                    None,
                    Some(crate::dsh::Dsh::start(
                        opts,
                        stdin,
                        stdout,
                        tx.clone(),
                        exited,
                    )),
                )
            } else {
                (Some(stdin), None)
            };
            RpcChild {
                stdin: tokio::sync::Mutex::new(stdin),
                dsh,
                requests: Arc::default(),
                stderr_tail: Arc::new(Mutex::new(VecDeque::new())),
                next_id: AtomicU64::new(0),
                child: Mutex::new(Some(child)),
            }
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

        let Some(stdout) = stdout else {
            return Ok((rpc, rx));
        };
        // Read stdout continuously (a stalled reader stalls the agent) and split strictly on LF:
        // U+2028/U+2029 are valid inside JSON strings.
        let requests = rpc.requests.clone();
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
                let Ok(record) = serde_json::from_str::<Value>(line) else {
                    continue;
                };
                if record["type"] == "response" {
                    let Some(id) = record["id"].as_str() else {
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
            let reason = match reader_rpc.upgrade() {
                Some(rpc) => rpc.wait_exit().await,
                None => "agent exited".into(),
            };
            requests.refuse_all(&reason);
            tx.offer(ChildOutput::Exited(reason));
        });

        Ok((rpc, rx))
    }

    pub async fn send(&self, kind: &str, fields: Value) -> Result<Value> {
        if let Some(dsh) = &self.dsh {
            return dsh.send(kind, fields).await;
        }
        let id = format!("b{}", self.next_id.fetch_add(1, Ordering::Relaxed) + 1);
        let mut command = json!({ "id": id, "type": kind });
        if let (Some(obj), Value::Object(extra)) = (command.as_object_mut(), fields) {
            obj.extend(extra);
        }
        let asked = self.requests.ask(id);
        let mut line = serde_json::to_vec(&command)?;
        line.push(b'\n');
        {
            let mut guard = self.stdin.lock().await;
            let Some(stdin) = guard.as_mut() else {
                return Err(anyhow!("agent is not running"));
            };
            if let Err(e) = async {
                stdin.write_all(&line).await?;
                stdin.flush().await
            }
            .await
            {
                return Err(anyhow!("agent is not running: {e}"));
            }
        }
        // Pi answers `compact` once the compaction is done, and everything else at once.
        let limit = if kind == "compact" { SLOW } else { QUICK };
        match asked.answer(limit).await {
            Ok(Ok(data)) => Ok(data),
            Ok(Err(e)) => Err(anyhow!(e)),
            Err(Unanswered::Gone) => Err(anyhow!("agent exited")),
            Err(Unanswered::Late(after)) => Err(unanswered(kind, after)),
        }
    }

    /// The agent process's pid, while it is running.
    pub fn pid(&self) -> Option<u32> {
        self.child.lock().ok()?.as_ref().and_then(|c| c.id())
    }

    /// Close stdin for an orderly shutdown; kill if the agent hasn't exited after 3 seconds.
    pub async fn close(&self) {
        match &self.dsh {
            Some(dsh) => dsh.close().await,
            None => {
                if let Some(stdin) = self.stdin.lock().await.as_mut() {
                    if let Err(e) = stdin.shutdown().await {
                        eprintln!("closing an agent's input: {e}");
                    }
                }
            }
        }
        let child = self.child.lock().unwrap().take();
        if let Some(mut child) = child {
            tokio::spawn(async move {
                if tokio::time::timeout(std::time::Duration::from_secs(3), child.wait())
                    .await
                    .is_err()
                {
                    if let Err(e) = child.kill().await {
                        eprintln!("an agent still running 3 seconds after its close could not be killed: {e}");
                    }
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
