//! Client for the Prime Agent supervisor socket (see docs/prime-daemon-protocol.md). One connection carries
//! every Prime session, including subagents and sessions started from Prime's own TUI.

use std::collections::{HashMap, HashSet};
use std::process::Stdio;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{anyhow, bail, Result};
use serde_json::{json, Value};

use crate::agent_wire::{InactiveRow, PrimeRow};
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

/// The daemon answered a command and said no, as opposed to not being reachable.
#[derive(Debug)]
pub struct Refused(pub String);

impl std::fmt::Display for Refused {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for Refused {}

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
        lines.read_until(b'\n', &mut buf).await?;
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

        let roster = self.supervisor("roster_subscribe", json!({})).await?;
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
    pub async fn supervisor(&self, kind: &str, fields: Value) -> Result<Value> {
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
        match asked.answer(QUICK).await {
            Ok(Ok(data)) => Ok(data),
            Ok(Err(e)) => Err(anyhow::Error::new(Refused(e))),
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
    ) -> Result<Value> {
        if let Value::Object(obj) = &mut fields {
            obj.insert(
                "activeSessionId".into(),
                Value::String(active_session_id.into()),
            );
        } else {
            fields = json!({ "activeSessionId": active_session_id });
        }
        self.supervisor(kind, fields).await
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
        let Ok(list) = self.supervisor("list", json!({ "all": true })).await else {
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
                    if let Err(e) = self.session(id, "detach", json!({})).await {
                        eprintln!("could not detach from Prime session {id} again: {e}");
                    }
                }
                Err(e) => eprintln!("could not reopen Prime session {id}: {e}"),
            }
        }
    }

    pub async fn attach(&self, active_session_id: &str) -> Result<Value> {
        let fields = json!({ "capabilities": ["attach_snapshot", "event_sequence"] });
        self.session(active_session_id, "attach", fields).await
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
}
