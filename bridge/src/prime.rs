//! Client for the Prime Agent supervisor socket (see docs/prime-daemon-protocol.md). One connection carries
//! every Prime session, including subagents and sessions started from Prime's own TUI.

use std::collections::{HashMap, HashSet};
use std::process::Stdio;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{anyhow, bail, Context, Result};
use futures_util::future::BoxFuture;
use serde_json::{json, Value};

use crate::agent::{Agent, JobsFrom, Keeps, Live, Sessions, SubagentsFrom, Verbs};
use crate::agent_wire::{ConversationId, InactiveRow, PrimeRow};
use crate::ask::{Ask, Delivery};
use crate::channel::Offer;
use crate::protocol::SessionKind;
use crate::store::Store;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::unix::OwnedWriteHalf;
use tokio::net::UnixStream;
use tokio::sync::mpsc;

use crate::requests::{Requests, Unanswered, QUICK};

const PROTOCOL_VERSION: u64 = 7;

pub enum DaemonEvent {
    /// (Re)connected; carries the full roster from `roster_subscribe`.
    Roster(Vec<PrimeRow>),
    RosterUpdate(Vec<PrimeRow>),
    SessionEvent {
        active_session_id: String,
        event: Value,
    },
    SessionClosed(String),
    Inactive(InactiveRow),
    Disconnected(String),
}

pub fn agent(daemon: Arc<PrimeDaemon>) -> Arc<dyn Agent> {
    Arc::new(Prime {
        daemon,
        costs: crate::cost::Costs::default(),
    })
}

/// Prime Agent, whose sessions live in its daemon: the daemon announces them, and the bridge attaches.
struct Prime {
    daemon: Arc<PrimeDaemon>,
    /// Sessions' spending, subagents included, read from their session files.
    costs: crate::cost::Costs,
}

impl Agent for Prime {
    fn sessions(&self) -> Sessions<'_> {
        Sessions::Kept(self)
    }

    fn models(&self) -> BoxFuture<'_, Result<Value>> {
        Box::pin(crate::rpc::listed_models("prime-agent", &["model", "list"]))
    }

    fn jobs(&self) -> JobsFrom {
        JobsFrom::Kernel
    }

    fn subagents(&self) -> SubagentsFrom {
        SubagentsFrom::Roster
    }

    fn gateway_session(
        &self,
        _session_file: Option<&str>,
        conversation: Option<&ConversationId>,
    ) -> Option<String> {
        Some(conversation?.as_str().to_string())
    }

    /// Own calls (as Prime reports them, or as its file records them if that's more) plus its subagents', never less
    /// than before.
    fn cost(&self, session_file: Option<&str>, reported: f64, before: f64) -> f64 {
        let total = match session_file.and_then(|f| self.costs.read(f)) {
            Some((recorded, subagents)) => reported.max(recorded) + subagents,
            None => reported,
        };
        total.max(before)
    }

    /// Prime counts what its subagents spend into their parent.
    fn spend_includes_subagents(&self) -> bool {
        true
    }

    fn verbs(&self) -> &'static dyn Verbs {
        &PrimeVerbs
    }
}

impl Keeps for Prime {
    fn create(
        &self,
        cwd: String,
        model: Option<String>,
        thinking: Option<String>,
    ) -> BoxFuture<'_, Result<PrimeRow>> {
        Box::pin(async move {
            self.daemon
                .create(&cwd, model.as_deref(), thinking.as_deref())
                .await
        })
    }

    fn stop(&self, id: &str) -> BoxFuture<'_, Result<()>> {
        let id = id.to_string();
        Box::pin(async move {
            let out = tokio::process::Command::new("prime-agent")
                .args(["stop", &id])
                .output()
                .await?;
            let stderr = String::from_utf8_lossy(&out.stderr);
            // An empty draft (e.g. right after new_session) has no worker to stop.
            if !out.status.success() && !stderr.contains("Unknown active session") {
                anyhow::bail!("prime-agent stop failed: {}", stderr.trim());
            }
            Ok(())
        })
    }

    fn session(&self, id: &str) -> Arc<dyn Live> {
        Arc::new(PrimeSession {
            daemon: self.daemon.clone(),
            id: id.to_string(),
        })
    }
}

/// Prime Agent's commands, as its daemon takes them.
struct PrimeVerbs;

impl Verbs for PrimeVerbs {
    /// Prime steers or queues it itself, whatever the session is doing.
    fn message(&self, text: String, _busy: bool) -> Ask {
        Ask::Prompt {
            message: text,
            delivery: Delivery::SteerOrQueue,
        }
    }

    fn follow_up(&self, text: String) -> Option<Ask> {
        Some(Ask::FollowUp(text))
    }

    fn abort(&self) -> Ask {
        Ask::Abort
    }

    /// Prime's `compact` command aborts the session first, which drops the background-command and subagent notices
    /// waiting to wake it and holds the rest until the next prompt: an idle session waiting on its jobs never wakes.
    /// Its `/compact` slash command compacts without aborting, after the current turn if one is running.
    fn compact(&self, instructions: Option<String>) -> Ask {
        let message = match instructions {
            Some(text) => format!("/compact {text}"),
            None => "/compact".to_string(),
        };
        Ask::Prompt {
            message,
            delivery: Delivery::FollowUp,
        }
    }

    fn auto_compaction(&self, enabled: bool) -> Option<Ask> {
        Some(Ask::SetAutoCompaction(enabled))
    }

    fn new_session(&self) -> Option<Ask> {
        Some(Ask::NewSession)
    }

    /// `/goal clear`, steered in so a running turn picks it up at its next step instead of after the turn.
    fn clear_goal(&self) -> Option<Ask> {
        Some(Ask::Prompt {
            message: "/goal clear".into(),
            delivery: Delivery::Steer,
        })
    }

    /// A plain abort leaves Prime holding steered messages until the next prompt; `abort_and_send_queued` delivers
    /// them at once, so the agent hears about the stop and carries on. Prime falls back to a plain abort when nothing
    /// is queued.
    fn stop_tool(&self) -> Ask {
        Ask::AbortAndSendQueued
    }

    /// The note queued as a steer first, so stopping the reply delivers it straight away.
    fn interrupt(&self, note: String) -> [Ask; 2] {
        [
            Ask::Prompt {
                message: note,
                delivery: Delivery::SteerOrQueue,
            },
            Ask::AbortAndSendQueued,
        ]
    }

    fn restart_kernel(
        &self,
        session_file: Option<String>,
    ) -> Option<BoxFuture<'static, Result<Value>>> {
        Some(Box::pin(restart_kernel(session_file)))
    }

    fn answer(&self, _: String, _: Vec<Value>) -> Option<Ask> {
        None
    }

    /// Prime has no levels command.
    fn thinking_levels(&self) -> Option<Ask> {
        None
    }
}

struct PrimeSession {
    daemon: Arc<PrimeDaemon>,
    id: String,
}

impl Live for PrimeSession {
    fn send(&self, ask: Ask) -> BoxFuture<'_, Result<Value>> {
        Box::pin(async move {
            let limit = ask.limit();
            let Some((kind, fields)) = ask.wire() else {
                anyhow::bail!("Prime has no {ask:?} command");
            };
            self.daemon.session(&self.id, kind, fields, limit).await
        })
    }

    fn close(&self) -> BoxFuture<'_, ()> {
        Box::pin(async {})
    }
}

pub struct PrimeDaemon {
    client_id: String,
    writer: tokio::sync::Mutex<Option<OwnedWriteHalf>>,
    requests: Requests<String>,
    next_id: AtomicU64,
    /// The top-level sessions this bridge has listed, by `sessionId`, so it can reopen them after a reboot.
    shown: Mutex<HashSet<String>>,
    /// Where that list is kept across restarts.
    store: Store,
}

/// The name of a top-level session in Prime's own list; a subagent has none worth keeping.
fn top_level(row: &PrimeRow) -> Option<String> {
    (row.kind != SessionKind::Subagent)
        .then(|| row.listed_as.clone())
        .flatten()
}

/// Where the daemon may listen: newer Prime builds use `prime-agent-rust-<uid>`, older ones `prime-agent-<uid>`.
pub fn socket_paths() -> Vec<String> {
    if let Ok(path) = std::env::var("PRIME_AGENT_DAEMON_SOCKET") {
        return vec![path];
    }
    let tmp = std::process::Command::new("getconf")
        .arg("DARWIN_USER_TEMP_DIR")
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .filter(|s| !s.is_empty())
        .or_else(|| std::env::var("TMPDIR").ok())
        .unwrap_or_else(|| "/tmp/".into());
    let uid = unsafe { libc_getuid() };
    let tmp = tmp.trim_end_matches('/');
    vec![
        format!("{tmp}/prime-agent-rust-{uid}/daemon.sock"),
        format!("{tmp}/prime-agent-{uid}/daemon.sock"),
    ]
}

async fn connect_any(paths: &[String]) -> Option<UnixStream> {
    for path in paths {
        if let Ok(stream) = UnixStream::connect(path).await {
            return Some(stream);
        }
    }
    None
}

extern "C" {
    #[link_name = "getuid"]
    fn libc_getuid() -> u32;
}

/// The environment Prime workers get for sessions the bridge creates. Prime's TUI forwards its
/// whole environment; the bridge forwards only what tools need.
fn launch_env() -> Value {
    let keys = [
        "PATH", "HOME", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL", "TERM", "TMPDIR",
    ];
    let mut env = serde_json::Map::new();
    for key in keys {
        if let Ok(value) = std::env::var(key) {
            env.insert(key.into(), Value::String(value));
        }
    }
    env.entry("TERM")
        .or_insert_with(|| Value::String("xterm-256color".into()));
    // The web the guide tells Prime about: the `shed-web` command, and the `shed_web` module for its Python.
    let path = env.get("PATH").and_then(Value::as_str).unwrap_or_default();
    let path = crate::web::prepend_path(&crate::web::bin_dir(), path);
    env.insert("PATH".into(), Value::String(path));
    let python = std::env::var("PYTHONPATH").unwrap_or_default();
    let python = crate::web::prepend_path(&crate::web::python_dir(), &python);
    env.insert("PYTHONPATH".into(), Value::String(python));
    Value::Object(env)
}

impl PrimeDaemon {
    /// A daemon nothing is connected to yet: every command is refused until `start` connects it.
    pub(crate) fn unconnected(client_id: String, store: Store) -> Arc<PrimeDaemon> {
        Arc::new(PrimeDaemon {
            client_id,
            writer: tokio::sync::Mutex::new(None),
            requests: Requests::default(),
            next_id: AtomicU64::new(0),
            shown: Mutex::new(HashSet::new()),
            store,
        })
    }

    /// Connects in the background and keeps reconnecting; events flow through the returned channel.
    pub fn start(
        client_id: String,
        store: Store,
    ) -> (Arc<PrimeDaemon>, mpsc::UnboundedReceiver<DaemonEvent>) {
        let daemon = PrimeDaemon::unconnected(client_id, store);
        let (tx, rx) = mpsc::unbounded_channel();
        tokio::spawn(daemon.clone().run(tx));
        (daemon, rx)
    }

    async fn run(self: Arc<Self>, tx: mpsc::UnboundedSender<DaemonEvent>) {
        let mut delay = Duration::from_secs(1);
        loop {
            match self.connect_once(&tx).await {
                // It was connected and lost: the next try doesn't wait as long as after a row of failures.
                Ok(()) => {
                    delay = Duration::from_secs(1);
                    tx.offer(DaemonEvent::Disconnected(
                        "Prime daemon connection closed".into(),
                    ));
                }
                Err(e) => {
                    tx.offer(DaemonEvent::Disconnected(e.to_string()));
                }
            }
            *self.writer.lock().await = None;
            // Dropped, not answered: an answer here would read as the daemon refusing the command.
            self.requests.drop_all();
            tokio::time::sleep(delay).await;
            delay = (delay * 2).min(Duration::from_secs(30));
        }
    }

    async fn connect_once(self: &Arc<Self>, tx: &mpsc::UnboundedSender<DaemonEvent>) -> Result<()> {
        let paths = socket_paths();
        let stream = match connect_any(&paths).await {
            Some(s) => s,
            None => {
                start_daemon()?;
                let mut connected = None;
                for _ in 0..40 {
                    tokio::time::sleep(Duration::from_millis(250)).await;
                    connected = connect_any(&paths).await;
                    if connected.is_some() {
                        break;
                    }
                }
                connected.ok_or_else(|| {
                    anyhow!("Prime daemon did not start (socket {})", paths.join(" or "))
                })?
            }
        };
        let (read, write) = stream.into_split();
        let mut lines = BufReader::new(read);
        let mut buf = Vec::new();

        // The server greets first; refuse a protocol we haven't verified.
        // Under a limit: a daemon that accepts and never greets would hold this connection, and its retries, forever.
        tokio::time::timeout(Duration::from_secs(10), lines.read_until(b'\n', &mut buf))
            .await
            .map_err(|_| anyhow!("Prime daemon did not greet within 10 s"))??;
        let hello: Value = serde_json::from_slice(&buf)?;
        let version = hello["protocol"]["version"].as_u64().unwrap_or(0);
        if hello["type"] != "daemon_hello" || version != PROTOCOL_VERSION {
            bail!(
                "unsupported Prime daemon protocol {version} (app {}); the bridge supports {PROTOCOL_VERSION}",
                hello["appVersion"].as_str().unwrap_or("?")
            );
        }
        *self.writer.lock().await = Some(write);

        let reader = {
            let daemon = self.clone();
            let tx = tx.clone();
            tokio::spawn(async move {
                let mut buf = Vec::new();
                while let Some(message) =
                    crate::requests::next_message(&mut lines, &mut buf, "Prime's daemon").await
                {
                    daemon.dispatch(message, &tx);
                }
            })
        };

        let roster = match self.supervisor("roster_subscribe", json!({}), QUICK).await {
            Ok(roster) => roster,
            Err(e) => {
                // The next attempt opens its own connection and reader: this one goes with it.
                reader.abort();
                return Err(e);
            }
        };
        let rows: Vec<PrimeRow> = roster["roster"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|row| PrimeRow::read(&row["summary"]))
            .collect();
        let running: HashSet<String> = rows.iter().filter_map(top_level).collect();
        tx.offer(DaemonEvent::Roster(rows));
        tokio::spawn(self.clone().wake_open_sessions(running));
        if let Err(e) = reader.await {
            eprintln!("prime daemon: the reader stopped: {e}");
        }
        Ok(())
    }

    fn dispatch(&self, message: Value, tx: &mpsc::UnboundedSender<DaemonEvent>) {
        match message["type"].as_str().unwrap_or("") {
            "response" => {
                let Some(id) = message["id"].as_str() else {
                    eprintln!("prime daemon: an answer that does not say which command: {message}");
                    return;
                };
                let result = if message["success"] == true {
                    Ok(message.get("data").cloned().unwrap_or(Value::Null))
                } else {
                    Err(message["error"]
                        .as_str()
                        .unwrap_or("command failed")
                        .to_string())
                };
                self.requests.answer(id, result);
            }
            "session_event" => {
                if let Some(id) = message["activeSessionId"].as_str() {
                    tx.offer(DaemonEvent::SessionEvent {
                        active_session_id: id.into(),
                        event: message["event"].clone(),
                    });
                }
            }
            "roster_update" => {
                let mut rows = Vec::new();
                for row in message["changed"].as_array().into_iter().flatten() {
                    if row["status"] == "inactive" {
                        if let Some(row) = InactiveRow::read(&row["summary"]) {
                            tx.offer(DaemonEvent::Inactive(row));
                        }
                    } else {
                        rows.extend(PrimeRow::read(&row["summary"]));
                    }
                }
                self.note_shown(&rows);
                tx.offer(DaemonEvent::RosterUpdate(rows));
            }
            "session_closed" => {
                let id = message["activeSessionId"]
                    .as_str()
                    .or_else(|| message["summary"]["activeSessionId"].as_str());
                if let Some(id) = id {
                    tx.offer(DaemonEvent::SessionClosed(id.into()));
                }
            }
            _ => {}
        }
    }

    /// A supervisor-level command.
    pub async fn supervisor(&self, kind: &str, fields: Value, limit: Duration) -> Result<Value> {
        let id = format!("ar_{}", self.next_id.fetch_add(1, Ordering::Relaxed) + 1);
        let mut command = json!({ "type": kind, "id": id });
        if let (Some(obj), Value::Object(extra)) = (command.as_object_mut(), fields) {
            obj.extend(extra);
        }
        let envelope = json!({
            "type": "command",
            "id": id,
            "protocol": { "name": "prime-agent.daemon", "version": PROTOCOL_VERSION },
            "clientId": self.client_id,
            "command": command,
        });
        let asked = self.requests.ask(id);
        let mut line = serde_json::to_vec(&envelope)?;
        line.push(b'\n');
        {
            let mut writer = self.writer.lock().await;
            let Some(writer) = writer.as_mut() else {
                bail!("Prime daemon is not connected");
            };
            if let Err(e) = writer.write_all(&line).await {
                bail!("Prime daemon write failed: {e}");
            }
        }
        match asked.answer(limit).await {
            Ok(Ok(data)) => Ok(data),
            Ok(Err(e)) => Err(anyhow::Error::new(crate::agent::Refused(e))),
            Err(Unanswered::Gone) => Err(anyhow!("Prime daemon disconnected")),
            Err(Unanswered::Late(after)) => Err(crate::rpc::unanswered(kind, after)),
        }
    }

    /// An RPC-style command addressed to one session.
    pub async fn session(
        &self,
        active_session_id: &str,
        kind: &str,
        mut fields: Value,
        limit: Duration,
    ) -> Result<Value> {
        if let Value::Object(obj) = &mut fields {
            obj.insert(
                "activeSessionId".into(),
                Value::String(active_session_id.into()),
            );
        } else {
            fields = json!({ "activeSessionId": active_session_id });
        }
        self.supervisor(kind, fields, limit).await
    }

    pub async fn create(
        &self,
        cwd: &str,
        model: Option<&str>,
        thinking: Option<&str>,
    ) -> Result<PrimeRow> {
        let home = crate::host::home_text();
        let mut config = json!({
            "cwd": cwd,
            "executionMode": "interactive",
            "sessionDir": format!("{home}/.prime/agent/sessions"),
            "appendSystemPrompt": [crate::guide::text(crate::rpc::AgentKind::Prime, &self.store)],
        });
        if let Some(model) = model {
            config["model"] = json!(model);
        }
        if let Some(thinking) = thinking {
            config["thinking"] = json!(thinking);
        }
        let created = self
            .supervisor(
                "create",
                json!({ "config": config, "launchEnv": launch_env() }),
                QUICK,
            )
            .await?;
        PrimeRow::read(&created).ok_or_else(|| anyhow!("Prime returned no session id"))
    }

    fn save_shown(&self, shown: &HashSet<String>) {
        if let Err(e) = self.store.save_prime_sessions(shown) {
            eprintln!("failed to save the Prime session list: {e}");
        }
    }

    /// Remembers top-level sessions that start while connected, so a reboot doesn't lose them either.
    fn note_shown(&self, rows: &[PrimeRow]) {
        let mut shown = self.shown.lock().unwrap();
        let before = shown.len();
        shown.extend(rows.iter().filter_map(top_level));
        if shown.len() != before {
            self.save_shown(&shown);
        }
    }

    /// After a reboot the daemon still counts its open sessions as live but runs no worker for them, so they are
    /// missing from the roster until a client opens one. Attaching starts the worker, as resuming in Prime's TUI
    /// does, and the roster then reports the session like any other. Only sessions this bridge listed before are
    /// reopened: Prime also keeps sessions live that nobody has opened since an older reboot. Archived ones are
    /// dropped from the list.
    async fn wake_open_sessions(self: Arc<Self>, running: HashSet<String>) {
        let Ok(list) = self.supervisor("list", json!({ "all": true }), QUICK).await else {
            return;
        };
        let live: HashMap<String, String> = list["sessions"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|s| s["lifecycle"] == "live")
            .filter_map(PrimeRow::read)
            .filter_map(|row| Some((top_level(&row)?, row.id)))
            .collect();
        // The first run has no list yet: start it from what is running.
        let before = self.store.load_prime_sessions();
        let asleep: Vec<&String> = before
            .iter()
            .filter(|id| !running.contains(*id))
            .filter_map(|id| live.get(id))
            .collect();
        {
            let mut shown = self.shown.lock().unwrap();
            shown.extend(before.iter().filter(|id| live.contains_key(*id)).cloned());
            shown.extend(running.iter().cloned());
            shown.retain(|id| live.contains_key(id) || running.contains(id));
            self.save_shown(&shown);
        }
        for id in asleep {
            match self.attach(id).await {
                Ok(_) => {
                    eprintln!("reopened Prime session {id} the daemon had left without a worker");
                    if let Err(e) = self.session(id, "detach", json!({}), QUICK).await {
                        eprintln!("could not detach from Prime session {id} again: {e}");
                    }
                }
                Err(e) => eprintln!("could not reopen Prime session {id}: {e}"),
            }
        }
    }

    pub async fn attach(&self, active_session_id: &str) -> Result<Value> {
        let ask = crate::ask::Ask::Attach;
        let (kind, fields) = ask.wire().expect("Prime attach has wire");
        self.session(active_session_id, kind, fields, ask.limit())
            .await
    }
}

/// Start the supervisor detached from the bridge so it outlives it (a running one makes this a no-op).
fn start_daemon() -> Result<()> {
    use std::os::unix::process::CommandExt;
    std::process::Command::new("prime-agent")
        .args(["--mode", "daemon"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .process_group(0)
        .spawn()
        .map_err(|e| anyhow!("failed to start prime-agent daemon: {e}"))?;
    Ok(())
}

/// Prime offers no command for this (its terminal asks the user itself, and never asks a remote client), but its
/// kernels run on this machine: kill the session's own kernel, found by the session id in its environment, along with
/// whatever it started. Prime notices the kernel is gone and starts a fresh one on the next Python call.
async fn restart_kernel(session_file: Option<String>) -> Result<Value> {
    let file = session_file.context("Prime hasn't reported this session's file yet")?;
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
            "restarting the kernel of {rlm_session}: kill said {}",
            String::from_utf8_lossy(&killed.stderr).trim()
        );
    }
    Ok(json!({ "killed": doomed.len() }))
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn only_top_level_sessions_are_remembered() {
        let row = |more: Value| {
            let mut row = json!({ "activeSessionId": "a1", "sessionId": "s1" });
            row.as_object_mut()
                .unwrap()
                .extend(more.as_object().unwrap().clone());
            PrimeRow::read(&row).unwrap()
        };
        assert_eq!(top_level(&row(json!({}))).as_deref(), Some("s1"));
        assert_eq!(top_level(&row(json!({ "runtimeKind": "subagent" }))), None);
    }

    #[tokio::test(start_paused = true)]
    async fn a_session_command_waits_up_to_its_own_limit() {
        let store = Store::temporary("prime-limit");
        let daemon = PrimeDaemon::unconnected("test".into(), store.clone());
        let (client, server) = UnixStream::pair().unwrap();
        let (read, write) = client.into_split();
        *daemon.writer.lock().await = Some(write);
        let (tx, _rx) = mpsc::unbounded_channel();
        let reader_daemon = daemon.clone();
        tokio::spawn(async move {
            let mut lines = BufReader::new(read);
            let mut buf = Vec::new();
            while let Some(msg) =
                crate::requests::next_message(&mut lines, &mut buf, "test-daemon").await
            {
                reader_daemon.dispatch(msg, &tx);
            }
        });
        tokio::spawn(async move {
            let (read, mut write) = server.into_split();
            let mut lines = BufReader::new(read);
            let mut buf = Vec::new();
            let msg = crate::requests::next_message(&mut lines, &mut buf, "test-client")
                .await
                .unwrap();
            let id = msg["id"].as_str().unwrap().to_string();
            // Longer than QUICK (120 s), within Ask::Compact's SLOW (30 min).
            tokio::time::sleep(Duration::from_secs(180)).await;
            let reply = json!({
                "id": id,
                "type": "response",
                "command": "compact",
                "success": true,
                "data": { "summary": "done" },
            });
            write
                .write_all(format!("{reply}\n").as_bytes())
                .await
                .unwrap();
        });

        let agents = crate::agent::Agents::installed(daemon, store.clone());
        let crate::agent::Sessions::Kept(keeps) =
            agents.get(crate::rpc::AgentKind::Prime).sessions()
        else {
            unreachable!()
        };
        let answer = keeps
            .session("a1")
            .send(crate::ask::Ask::Compact { instructions: None })
            .await;
        let _ = std::fs::remove_dir_all(store.dir());
        assert_eq!(answer.unwrap(), json!({ "summary": "done" }));
    }

    #[test]
    fn prime_daemon_protocol_doc_lists_the_session_commands_the_bridge_sends() {
        use std::collections::BTreeSet;

        use crate::agent::Verbs;
        use crate::ask::Ask;

        let verbs = PrimeVerbs;
        let mut asks = vec![
            verbs.message("hi".into(), false),
            verbs.message("hi".into(), true),
            verbs.abort(),
            verbs.compact(None),
            verbs.stop_tool(),
            Ask::State,
            Ask::Stats,
            Ask::Messages,
            Ask::Models,
            Ask::SetModel {
                provider: "p".into(),
                model_id: "m".into(),
            },
            Ask::SetThinkingLevel("high".into()),
            Ask::SetName("n".into()),
            Ask::Attach,
            Ask::KernelBash,
            Ask::PersistentShells,
            Ask::TailKernelBash {
                activity: "a".into(),
                lines: 10,
            },
            Ask::TailPersistentShell {
                shell: "s".into(),
                lines: 10,
            },
            Ask::KillKernelBash("a".into()),
            Ask::KillPersistentShell("s".into()),
        ];
        asks.extend(verbs.interrupt("loop".into()));
        asks.extend(verbs.follow_up("later".into()));
        asks.extend(verbs.auto_compaction(true));
        asks.extend(verbs.new_session());
        asks.extend(verbs.clear_goal());
        asks.extend(verbs.answer("q".into(), vec![]));
        asks.extend(verbs.thinking_levels());

        let mut sent: BTreeSet<String> = asks
            .iter()
            .map(|ask| ask.wire().expect("Prime Ask has wire").0.to_string())
            .collect();
        sent.insert("detach".into());

        let doc = include_str!("../../docs/prime-daemon-protocol.md");
        let section = doc
            .split("Session commands are Prime's RPC commands")
            .nth(1)
            .and_then(|s| s.split("Supervisor commands:").next())
            .unwrap();
        let mut documented = BTreeSet::new();
        for part in section.split('`').skip(1).step_by(2) {
            if part != "activeSessionId" && !part.starts_with('/') {
                documented.insert(part.to_string());
            }
        }
        // Unused / avoided commands explicitly called out in that paragraph.
        for not_sent in [
            "compact",
            "steer",
            "clear_queue",
            "get_available_thinking_levels",
            "thinkingLevelMap",
        ] {
            documented.remove(not_sent);
        }
        for cmd in [
            "list_kernel_bash",
            "tail_kernel_bash",
            "kill_kernel_bash",
            "list_persistent_shells",
            "tail_persistent_shell",
            "kill_persistent_shell",
        ] {
            assert!(doc.contains(&format!("`{cmd}`")), "doc missing {cmd}");
            documented.insert(cmd.into());
        }
        assert_eq!(documented, sent);
    }
}
