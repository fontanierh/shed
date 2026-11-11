//! DeepSeek Harness driven through `dsh --profile shed`, a dsh profile whose one stdio plugin (`bridge/dsh/shed.mjs`,
//! written into the profile on each start) forwards dsh's own events: durable session events for the session and every
//! subagent under it, live assistant stream frames, and agent status. This answers what the bridge asks of the session
//! and turns that feed into Pi's events, so the rest of the bridge runs a DeepSeek
//! session as it runs a Pi one. Three events are dsh's own: `dsh_subagent` (one child's transcript and state, mirrored
//! as a read-only session), `dsh_jobs` (how many background commands are running) and `dsh_question` (what the agent
//! asks the user, or null once nothing is left to answer).

mod feed;
#[cfg(test)]
pub(crate) use feed::tests;

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use anyhow::{anyhow, bail, Context, Result};
use futures_util::future::BoxFuture;
use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::sync::{mpsc, oneshot, watch};

use crate::agent::{file_stem, Agent, JobsFrom, Sessions, Started, Starts, SubagentsFrom, Verbs};
use crate::agent_wire::ConversationId;
use crate::ask::{Ask, Delivery};
use crate::channel::Offer;
use crate::requests::{Requests, Unanswered, QUICK};
use crate::rpc::{ChildOutput, ChildProcess, Launch, SpawnOptions};
use crate::store::Store;
use feed::{effort, Feed};

/// The plugin and the profile layer that loads it, kept with the bridge so both always match.
const PLUGIN: &str = include_str!("../dsh/shed.mjs");
/// dsh's web_search and web_fetch through Shed's web provider, loaded when one is set up here.
const WEB_PLUGIN: &str = include_str!("../dsh/shed-web.mjs");
const PROFILE: &str = "shed";

pub fn agent(store: Store) -> Arc<dyn Agent> {
    Arc::new(Deepseek(store))
}

struct Deepseek(Store);

impl Agent for Deepseek {
    fn sessions(&self) -> Sessions<'_> {
        Sessions::Started(self)
    }

    fn models(&self) -> BoxFuture<'_, Result<Value>> {
        Box::pin(list_models(&self.0))
    }

    fn jobs(&self) -> JobsFrom {
        JobsFrom::Agent
    }

    fn subagents(&self) -> SubagentsFrom {
        SubagentsFrom::Events
    }

    fn gateway_session(
        &self,
        session_file: Option<&str>,
        _conversation: Option<&ConversationId>,
    ) -> Option<String> {
        Some(file_stem(session_file)?.to_string())
    }

    fn cost(&self, _session_file: Option<&str>, reported: f64, _before: f64) -> f64 {
        reported
    }

    fn spend_includes_subagents(&self) -> bool {
        false
    }

    fn verbs(&self) -> &'static dyn Verbs {
        &DshVerbs
    }
}

impl Starts for Deepseek {
    fn start(&self, opts: &SpawnOptions) -> Result<Started> {
        // The session's model, reasoning effort and resumption go to the plugin once it starts.
        let layer = install_profile(&self.0)
            .context("the Shed profile for dsh can't be written")?
            .to_string_lossy()
            .into_owned();
        let launch = Launch {
            program: "dsh".into(),
            args: ["--profile", PROFILE, "--patch", &layer]
                .iter()
                .map(|a| a.to_string())
                .collect(),
            // Shed runs its agents without asking or a sandbox, as it does Pi and Prime.
            env: vec![("DSH_PERMISSION_MODE".into(), "danger-full-access".into())],
        };
        let (stdin, stdout, process) = ChildProcess::spawn_pipes(launch, &opts.cwd)?;
        let (tx, rx) = mpsc::unbounded_channel();
        let exit_proc = process.clone();
        let dsh = Dsh::with_process(opts, stdin, stdout, tx, Some(process), async move {
            exit_proc.wait_exit().await
        });
        Ok((dsh, rx))
    }
}

/// DeepSeek Harness's commands: it compacts on its own, opens one conversation per session, and asks questions.
struct DshVerbs;

impl Verbs for DshVerbs {
    fn message(&self, text: String, busy: bool) -> Ask {
        match busy {
            true => Ask::Steer(text),
            false => Ask::Prompt {
                message: text,
                delivery: Delivery::Turn,
            },
        }
    }

    fn follow_up(&self, text: String) -> Option<Ask> {
        Some(Ask::FollowUp(text))
    }

    fn abort(&self) -> Ask {
        Ask::Abort
    }

    fn compact(&self, instructions: Option<String>) -> Ask {
        Ask::Compact { instructions }
    }

    fn auto_compaction(&self, _: bool) -> Option<Ask> {
        None
    }

    fn new_session(&self) -> Option<Ask> {
        None
    }

    fn clear_goal(&self) -> Option<Ask> {
        None
    }

    fn stop_tool(&self) -> Ask {
        Ask::Abort
    }

    fn interrupt(&self, note: String) -> [Ask; 2] {
        [
            Ask::Abort,
            Ask::Prompt {
                message: note,
                delivery: Delivery::Turn,
            },
        ]
    }

    fn restart_kernel(&self, _: Option<String>) -> Option<BoxFuture<'static, Result<Value>>> {
        None
    }

    fn answer(&self, question_id: String, answers: Vec<Value>) -> Option<Ask> {
        Some(Ask::Answer {
            question_id,
            answers,
        })
    }

    fn thinking_levels(&self) -> Option<Ask> {
        Some(Ask::ThinkingLevels)
    }
}

type PipeWriter = std::pin::Pin<Box<dyn AsyncWrite + Send>>;

pub(crate) struct Dsh {
    stdin: tokio::sync::Mutex<PipeWriter>,
    requests: Requests<u64>,
    next_id: AtomicU64,
    events: mpsc::UnboundedSender<ChildOutput>,
    /// Set once the session is open: its id, or why it couldn't start.
    ready: watch::Receiver<Option<Result<String, String>>>,
    feed: Mutex<Feed>,
    process: Option<Arc<ChildProcess>>,
}

fn install_profile(store: &Store) -> Result<PathBuf> {
    install_profile_in(
        &crate::host::home().join(".dsh/profiles").join(PROFILE),
        store,
    )
}

/// Write the `shed` profile into `dir`: the bundles it composes, the plugin, and the layer that swaps the SDK's
/// JSON-RPC server for it. Returns the path to `shed.patch.yml`.
fn install_profile_in(dir: &Path, store: &Store) -> Result<PathBuf> {
    std::fs::create_dir_all(dir)?;
    let package = json!({
        "name": "dsh-profile-shed",
        "private": true,
        "dependencies": {},
        "dsh": { "profile": { "bundles": ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-sdk-app"] } },
    });
    let write = |name: &str, text: &str| -> Result<()> {
        let path = dir.join(name);
        if std::fs::read_to_string(&path).ok().as_deref() != Some(text) {
            std::fs::write(&path, text)?;
        }
        Ok(())
    };
    write("package.json", &format!("{package:#}\n"))?;
    write("cordis.yml", "[]\n")?;
    write(
        "pnpm-workspace.yaml",
        "packages:\n  - .\n\nnodeLinker: hoisted\nautoInstallPeers: false\n",
    )?;
    write("shed.mjs", PLUGIN)?;
    if !dir.join("cordis.patch.yml").exists() {
        write(
            "cordis.patch.yml",
            "# Your patch layer for this dsh profile, as in dsh's own profiles. Shed loads its plugin from\n# shed.patch.yml, which it rewrites on every start.\n[]\n",
        )?;
    }
    // JSON is YAML, so the strings need no escaping of their own.
    let plugin = dir.join("shed.mjs");
    let persona = format!(
        "You are a coding agent powered by the {{{{model}}}} model.\n\n{}",
        crate::guide::text(crate::rpc::AgentKind::Deepseek, store)
    );
    let layer = format!(
        "- id: sdk-jsonrpc-server\n  disabled: true\n- id: system-prompt\n  config:\n    personaPrefix: {}\n- insert:\n    - id: tool-ask-user\n      name: '@deepseek-ai/dsh-tool-ask-user'\n      config:\n        mode: timed\n    - id: shed\n      name: {}\n      inject: [sdkAppStartup]\n",
        json!(persona),
        json!(plugin.to_string_lossy()),
    );
    let layer = layer
        + &web_layer(store, dir, &write)?
        + &crate::opencodex::dsh_layer(store).unwrap_or_default();
    write("shed.patch.yml", &layer)?;
    Ok(dir.join("shed.patch.yml"))
}

/// With a web provider set up here, the plugin that registers it in dsh's web service, and the service pinned to it
/// for both search and fetch. Without one, dsh's own defaults stay.
fn web_layer(
    store: &crate::store::Store,
    dir: &std::path::Path,
    write: &impl Fn(&str, &str) -> Result<()>,
) -> Result<String> {
    if !crate::web::configured(store) {
        return Ok(String::new());
    }
    write("shed-web.mjs", WEB_PLUGIN)?;
    Ok(format!(
        "- id: web\n  config:\n    searchProvider: shed\n    fetchProvider: shed\n- insert:\n    - id: shed-web\n      name: {}\n      config:\n        command: {}\n",
        json!(dir.join("shed-web.mjs").to_string_lossy()),
        json!(crate::web::bin_dir().join("shed-web").to_string_lossy()),
    ))
}

/// The models the `shed` profile has set up, as `[{provider, id, name}]`, for choosing one before a session starts:
/// providers added in the profile's own patch layer are among them. Asks a short-lived dsh that opens no session.
async fn list_models(store: &Store) -> Result<Value> {
    let layer = install_profile(store)?;
    let home = crate::host::home_text();
    let mut child = tokio::process::Command::new("dsh")
        .args(["--profile", PROFILE, "--patch"])
        .arg(&layer)
        .env(crate::opencodex::KEY_ENV, crate::opencodex::KEY)
        .current_dir(if home.is_empty() { "/".into() } else { home })
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| anyhow!("failed to start dsh: {e}"))?;
    let mut stdin = child.stdin.take().expect("piped stdin");
    let mut lines = BufReader::new(child.stdout.take().expect("piped stdout")).lines();
    let ask = async {
        let request = b"{\"id\":1,\"method\":\"models\",\"params\":{}}\n";
        while let Some(line) = lines.next_line().await? {
            let Ok(message) = serde_json::from_str::<Value>(&line) else {
                continue;
            };
            if message["event"] == "ready" {
                stdin.write_all(request).await?;
                stdin.flush().await?;
            } else if message["id"] == 1 {
                if let Some(error) = message.get("error") {
                    bail!("dsh: {}", error.as_str().unwrap_or("models request failed"));
                }
                let models = &message["result"]["models"];
                if models.as_array().is_some_and(|m| !m.is_empty()) {
                    return Ok(models.clone());
                }
                // Ready comes before its providers have loaded, a few seconds later: ask again until they have.
                tokio::time::sleep(std::time::Duration::from_millis(300)).await;
                stdin.write_all(request).await?;
                stdin.flush().await?;
            }
        }
        bail!("dsh exited before listing its models")
    };
    let models = tokio::time::timeout(std::time::Duration::from_secs(30), ask)
        .await
        .map_err(|_| anyhow!("dsh took too long to list its models"))??;
    Ok(models)
}

impl Dsh {
    /// Read a `dsh` plugin stream over in-memory or OS pipes, then open or resume the session once the plugin is up.
    #[cfg(test)]
    pub fn start<W, R>(
        opts: &SpawnOptions,
        stdin: W,
        stdout: R,
        events: mpsc::UnboundedSender<ChildOutput>,
        exited: impl std::future::Future<Output = String> + Send + 'static,
    ) -> Arc<Dsh>
    where
        W: AsyncWrite + Send + 'static,
        R: AsyncRead + Unpin + Send + 'static,
    {
        Self::with_process(opts, stdin, stdout, events, None, exited)
    }

    fn with_process<W, R>(
        opts: &SpawnOptions,
        stdin: W,
        stdout: R,
        events: mpsc::UnboundedSender<ChildOutput>,
        process: Option<Arc<ChildProcess>>,
        exited: impl std::future::Future<Output = String> + Send + 'static,
    ) -> Arc<Dsh>
    where
        W: AsyncWrite + Send + 'static,
        R: AsyncRead + Unpin + Send + 'static,
    {
        let (ready_tx, ready) = watch::channel(None);
        let (up_tx, up) = oneshot::channel::<()>();
        let dsh = Arc::new(Dsh {
            stdin: tokio::sync::Mutex::new(Box::pin(stdin)),
            requests: Requests::default(),
            next_id: AtomicU64::new(0),
            events,
            ready,
            feed: Mutex::new(Feed::default()),
            process,
        });

        let reader = Arc::downgrade(&dsh);
        tokio::spawn(async move {
            let mut up = Some(up_tx);
            let mut lines = BufReader::new(stdout);
            let mut buf = Vec::new();
            while let Some(message) =
                crate::requests::next_message(&mut lines, &mut buf, "dsh").await
            {
                if message["event"] == "ready" {
                    if let Some(up) = up.take() {
                        up.offer(());
                    }
                    continue;
                }
                let Some(dsh) = reader.upgrade() else { break };
                dsh.receive(message);
            }
            let mut reason = exited.await;
            if let Some(dsh) = reader.upgrade() {
                // Exited because the session couldn't open: that's the reason to show.
                if let Some(Err(e)) = dsh.ready.borrow().as_ref() {
                    reason = e.clone();
                }
                dsh.requests.refuse_all(&reason);
                dsh.events.offer(ChildOutput::Exited(reason));
            }
        });

        let (opener, cwd) = (dsh.clone(), opts.cwd.clone());
        let (resume, model, thinking) = (
            opts.resume.clone(),
            opts.model.clone(),
            opts.thinking.clone(),
        );
        tokio::spawn(async move {
            let opened = match up.await {
                Ok(()) => opener.open(&cwd, resume, model, thinking).await,
                Err(_) => Err(anyhow!("dsh exited before it started")),
            };
            let failed = opened.is_err();
            ready_tx.offer(Some(opened.map_err(|e| e.to_string())));
            // No session, so no reason to keep dsh running: it exits once its stdin closes.
            if failed {
                if let Err(e) = opener.stdin.lock().await.shutdown().await {
                    eprintln!("dsh: closing its input after a failed open: {e}");
                }
            }
        });
        dsh
    }

    async fn open(
        &self,
        cwd: &str,
        resume: Option<String>,
        model: Option<String>,
        thinking: Option<String>,
    ) -> Result<String> {
        let mut selection = json!({});
        if let Some((provider, id)) = model.as_deref().and_then(|m| m.split_once('/')) {
            selection = json!({ "provider": provider, "model": id });
        }
        if let Some(level) = thinking.as_deref().filter(|l| !l.is_empty()) {
            selection["reasoningEffort"] = json!(effort(level));
        }
        let opened = self
            .call(
                "open",
                json!({
                    "cwd": cwd,
                    "resume": resume.is_some(),
                    "sessionId": resume,
                    "model": selection,
                }),
                QUICK,
            )
            .await?;
        let id = opened["sessionId"]
            .as_str()
            .ok_or_else(|| anyhow!("dsh opened no session"))?
            .to_string();
        let models = self
            .call("models", json!({}), QUICK)
            .await
            .unwrap_or_default();
        let mut feed = self.feed.lock().unwrap();
        feed.root = id.clone();
        feed.describe(&opened);
        feed.models = models["models"].as_array().cloned().unwrap_or_default();
        if let Some(events) = opened["events"].as_array() {
            feed.replay(events);
        }
        // A resumed session's subagents, read back from their own events: they show again as they did.
        let mut subagents = Vec::new();
        for child in opened["children"].as_array().into_iter().flatten() {
            let Some(child_id) = child["sessionId"].as_str() else {
                continue;
            };
            let parent = child["parent"].as_str().map(str::to_string);
            let events = child["events"]
                .as_array()
                .map(Vec::as_slice)
                .unwrap_or_default();
            feed.replay_subagent(child_id, parent, events);
            // One stored without events made no entry to describe.
            if feed.sessions.contains_key(child_id) {
                subagents.push(feed.subagent(child_id));
            }
        }
        drop(feed);
        for event in subagents {
            self.emit(event);
        }
        Ok(id)
    }

    async fn session(&self) -> Result<String> {
        let mut ready = self.ready.clone();
        let opened = ready
            .wait_for(Option::is_some)
            .await
            .map_err(|_| anyhow!("agent exited"))?;
        opened.clone().unwrap().map_err(|e| anyhow!(e))
    }

    pub async fn send(&self, ask: Ask) -> Result<Value> {
        let limit = ask.limit();
        let session = self.session().await?;
        match ask {
            Ask::State => Ok(self.feed.lock().unwrap().pi_state(&session)),
            Ask::Stats => {
                let feed = self.feed.lock().unwrap();
                Ok(match (feed.tokens, feed.window) {
                    (Some(tokens), Some(window)) => json!({ "contextUsage": {
                        "tokens": tokens,
                        "contextWindow": window,
                        "percent": tokens as f64 * 100.0 / window.max(1) as f64,
                    } }),
                    _ => json!({}),
                })
            }
            Ask::Messages => Ok(json!({ "messages": self.feed.lock().unwrap().root_messages() })),
            Ask::Models => Ok(json!({ "models": self.feed.lock().unwrap().pi_models() })),
            Ask::ThinkingLevels => Ok(json!({ "levels": self.feed.lock().unwrap().efforts() })),
            Ask::SetModel { provider, model_id } => {
                let state = self
                    .call(
                        "select",
                        json!({ "provider": provider, "model": model_id }),
                        limit,
                    )
                    .await?;
                self.feed.lock().unwrap().describe(&state);
                self.emit(json!({ "type": "session_action_update" }));
                Ok(Value::Null)
            }
            Ask::SetThinkingLevel(level) => {
                let state = self
                    .call("select", json!({ "effort": effort(&level) }), limit)
                    .await?;
                self.feed.lock().unwrap().describe(&state);
                self.emit(json!({ "type": "thinking_level_changed", "level": level }));
                Ok(Value::Null)
            }
            Ask::SetName(name) => {
                self.feed.lock().unwrap().name = Some(name.clone());
                self.emit(json!({ "type": "session_info_changed", "name": name }));
                Ok(Value::Null)
            }
            Ask::Prompt { message, delivery } => {
                let steer = matches!(delivery, Delivery::Steer | Delivery::SteerOrQueue);
                self.prompt(message, steer, limit).await
            }
            Ask::Steer(text) => self.prompt(text, true, limit).await,
            Ask::FollowUp(text) => self.prompt(text, false, limit).await,
            Ask::Abort => self.cancel(false, limit).await,
            Ask::AbortAndSendQueued => self.cancel(true, limit).await,
            // dsh's own compaction events (as for one it starts itself) tell how it goes once it has begun; a request
            // it turns down before then (nothing to compact) ends here.
            Ask::Compact { .. } => {
                self.emit(json!({ "type": "compaction_start", "reason": "manual" }));
                let before = self.feed.lock().unwrap().compactions;
                let result = self
                    .call("command", json!({ "line": "/compact" }), limit)
                    .await;
                let ended = self.feed.lock().unwrap().compactions != before;
                match &result {
                    _ if ended => {}
                    Ok(r) if r["kind"] == "success" => {
                        self.emit(json!({ "type": "compaction_end" }))
                    }
                    Ok(r) => {
                        self.emit(json!({ "type": "compaction_end", "errorMessage": r["text"] }))
                    }
                    Err(e) => self
                        .emit(json!({ "type": "compaction_end", "errorMessage": e.to_string() })),
                }
                result.map(|_| Value::Null)
            }
            Ask::Jobs => self.call("jobs", json!({}), limit).await,
            Ask::JobOutput(job) => {
                self.call("job_output", json!({ "jobId": job }), limit)
                    .await
            }
            Ask::KillJob(job) => self.call("kill_job", json!({ "jobId": job }), limit).await,
            Ask::Answer {
                question_id,
                answers,
            } => {
                let answers = (!answers.is_empty()).then_some(answers);
                self.call(
                    "answer",
                    json!({ "id": question_id, "answers": answers }),
                    limit,
                )
                .await
            }
            Ask::SetAutoCompaction(_) => bail!("this agent compacts on its own"),
            Ask::NewSession => bail!("start a new session from the app instead"),
            Ask::KernelBash
            | Ask::PersistentShells
            | Ask::TailKernelBash { .. }
            | Ask::TailPersistentShell { .. }
            | Ask::KillKernelBash(_)
            | Ask::KillPersistentShell(_)
            | Ask::Attach => bail!("DeepSeek Harness has no {ask:?} command"),
        }
    }

    async fn prompt(&self, text: String, steer: bool, limit: std::time::Duration) -> Result<Value> {
        // While the agent waits on a question, what's typed is the answer to it.
        let waiting = self.feed.lock().unwrap().question.clone();
        if let Some(question) = waiting.filter(|_| !text.trim().is_empty()) {
            let answers: Vec<Value> = question["questions"]
                .as_array()
                .into_iter()
                .flatten()
                .map(|q| json!({ "id": q["id"], "selected": [], "custom": text }))
                .collect();
            self.call(
                "answer",
                json!({ "id": question["id"], "answers": answers }),
                limit,
            )
            .await?;
            return Ok(Value::Null);
        }
        let mode = if steer { "steer" } else { "followup" };
        let sent = self
            .call(
                "prompt",
                json!({ "text": text, "images": [], "mode": mode }),
                limit,
            )
            .await?;
        // Until dsh takes it into a turn, it waits in the session's inbox: shown as queued.
        let queued = {
            let mut feed = self.feed.lock().unwrap();
            let queued = feed.running;
            if queued {
                let id = sent["messageId"].as_str().unwrap_or("").to_string();
                feed.queue.push_back((id, text, steer));
            }
            queued
        };
        if queued {
            self.queue_changed();
        }
        Ok(Value::Null)
    }

    async fn cancel(&self, keep: bool, limit: std::time::Duration) -> Result<Value> {
        if !keep {
            self.feed.lock().unwrap().queue.clear();
            self.queue_changed();
        }
        self.call("cancel", json!({ "keepInbox": keep }), limit)
            .await?;
        Ok(Value::Null)
    }

    pub async fn close(&self) {
        let close = self.call("close", json!({}), QUICK);
        match tokio::time::timeout(std::time::Duration::from_secs(10), close).await {
            Ok(Ok(_)) => {}
            Ok(Err(e)) => eprintln!("dsh: close failed: {e}"),
            Err(_) => eprintln!("dsh: no answer to close after 10 seconds"),
        }
        if let Err(e) = self.stdin.lock().await.shutdown().await {
            eprintln!("dsh: closing its input: {e}");
        }
        if let Some(process) = &self.process {
            process.shutdown().await;
        }
    }

    fn queue_changed(&self) {
        let (steering, follow_up): (Vec<String>, Vec<String>) = {
            let feed = self.feed.lock().unwrap();
            let pick = |steer: bool| {
                feed.queue
                    .iter()
                    .filter(|q| q.2 == steer)
                    .map(|q| q.1.clone())
                    .collect()
            };
            (pick(true), pick(false))
        };
        self.emit(json!({ "type": "queue_update", "steering": steering, "followUp": follow_up }));
    }

    fn emit(&self, event: Value) {
        self.events.offer(ChildOutput::Event(event));
    }

    // ---- the plugin's protocol ----

    fn receive(&self, message: Value) {
        if let Some(id) = message["id"].as_u64() {
            let result = match message.get("error") {
                Some(error) => Err(error.as_str().unwrap_or("dsh request failed").to_string()),
                None => Ok(message.get("result").cloned().unwrap_or(Value::Null)),
            };
            self.requests.answer(&id, result);
            return;
        }
        let (events, queue_changed) = {
            let mut feed = self.feed.lock().unwrap();
            let before = feed.queue.len();
            let events = feed.receive(&message);
            (events, feed.queue.len() != before)
        };
        if queue_changed {
            self.queue_changed();
        }
        for event in events {
            self.emit(event);
        }
    }

    async fn call(&self, method: &str, params: Value, limit: std::time::Duration) -> Result<Value> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed) + 1;
        let asked = self.requests.ask(id);
        let mut line = json!({ "id": id, "method": method, "params": params })
            .to_string()
            .into_bytes();
        line.push(b'\n');
        let written = {
            let mut stdin = self.stdin.lock().await;
            stdin.write_all(&line).await.is_ok() && stdin.flush().await.is_ok()
        };
        if !written {
            bail!("agent is not running");
        }
        match asked.answer(limit).await {
            Ok(Ok(result)) => Ok(result),
            Ok(Err(e)) => Err(anyhow::Error::new(crate::agent::Refused(e))),
            Err(Unanswered::Gone) => Err(anyhow!("agent exited")),
            Err(Unanswered::Late(after)) => Err(crate::rpc::unanswered(method, after)),
        }
    }
}

impl crate::agent::Live for Dsh {
    fn send(&self, ask: Ask) -> futures_util::future::BoxFuture<'_, Result<Value>> {
        Box::pin(Dsh::send(self, ask))
    }

    fn pid(&self) -> Option<u32> {
        self.process.as_ref()?.pid()
    }

    fn close(&self) -> futures_util::future::BoxFuture<'_, ()> {
        Box::pin(Dsh::close(self))
    }
}

#[cfg(test)]
mod profile_tests {
    use super::*;

    #[test]
    fn writes_profile_and_patch_layers_in_a_temp_folder() {
        let store = Store::temporary("dsh-profile");
        std::fs::write(
            store.dir().join("config.json"),
            r#"{"token": "t-secret-12345678", "opencodex": {"url": "http://127.0.0.1:10100"}, "web": {"provider": "firecrawl", "firecrawlApiKey": "fc-test"}}"#,
        )
        .unwrap();
        std::fs::write(
            store.dir().join("opencodex-models.json"),
            r#"[{"id": "deepseek/deepseek-flash", "name": "DeepSeek Flash"}]"#,
        )
        .unwrap();

        let profile_dir = store.dir().join("profile");
        let patch_path = install_profile_in(&profile_dir, &store).unwrap();
        let pkg: Value =
            serde_json::from_slice(&std::fs::read(profile_dir.join("package.json")).unwrap())
                .unwrap();
        assert_eq!(pkg["name"], "dsh-profile-shed");
        assert!(profile_dir.join("shed.mjs").is_file());
        assert!(profile_dir.join("shed-web.mjs").is_file());
        assert!(profile_dir.join("cordis.patch.yml").is_file());

        let patch = std::fs::read_to_string(&patch_path).unwrap();
        assert!(patch.contains("id: sdk-jsonrpc-server"));
        assert!(patch.contains("searchProvider: shed"));
        assert!(patch.contains("id: llm-pi-ai"));
        assert!(patch.contains("deepseek/deepseek-flash"));
        let _ = std::fs::remove_dir_all(store.dir());
    }
}
