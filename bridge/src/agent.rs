//! What the bridge asks of an agent, and the agents it has. Adding one is implementing `Agent` for it (with its
//! `Verbs`, and `Starts` or `Keeps`) and giving it its place in `Agents`; `docs/architecture.md` says what else a
//! new agent needs.

use std::sync::Arc;

use anyhow::{Context, Result};
use futures_util::future::BoxFuture;
use serde_json::Value;
use tokio::sync::mpsc;

use crate::agent_wire::PrimeRow;
use crate::ask::{Ask, Delivery};
use crate::prime::PrimeDaemon;
use crate::rpc::{AgentKind, ChildOutput, Launch, Protocol, RpcChild, SpawnOptions};
use crate::store::Store;

/// One kind of agent.
pub trait Agent: Send + Sync {
    /// How its sessions come about. Every agent says which: there is no third way, and no default.
    fn sessions(&self) -> Sessions<'_>;

    /// The models a session can start on, as `[{provider, id, name}]`.
    fn models(&self) -> BoxFuture<'_, Result<Value>>;

    /// Whether it lists, shows and stops its background commands itself (`Ask::Jobs`, `Ask::JobOutput`,
    /// `Ask::KillJob`) and reports them as events. Otherwise the bridge reads them where the agent leaves them.
    fn jobs(&self) -> JobsFrom;

    /// The session id it sends Open Codex with its requests, from the name of the session's file without its
    /// extension. An agent that keeps its own sessions is known by its conversation instead.
    fn gateway_session(&self, file_name: &str) -> String;

    /// Whether what Open Codex counts for a session already holds what its subagents spent.
    fn spend_includes_subagents(&self) -> bool;

    /// What the commands an app gives one of its sessions become, in this agent's words.
    fn verbs(&self) -> &'static dyn Verbs;
}

/// What a session's commands become in one agent's words. None has a default: an agent says each, with `None` when
/// it has no such command.
pub trait Verbs: Send + Sync {
    /// A message from the person, `busy` when the session is working.
    fn message(&self, text: String, busy: bool) -> Ask;

    /// A message queued to run after the current turn.
    fn follow_up(&self, text: String) -> Option<Ask>;

    /// Stopping the current turn.
    fn abort(&self) -> Ask;

    /// Compacting the conversation, with what to keep if the person said.
    fn compact(&self, instructions: Option<String>) -> Ask;

    /// Turning automatic compaction on or off, for an agent that exposes a switch.
    fn auto_compaction(&self, enabled: bool) -> Option<Ask>;

    /// Starting a fresh conversation inside the same session, for an agent that supports it.
    fn new_session(&self) -> Option<Ask>;

    /// Clearing the session's goal, for an agent whose sessions have one.
    fn clear_goal(&self) -> Option<Ask>;

    /// Stopping the tool call that is running.
    fn stop_tool(&self) -> Ask;

    /// Stopping a reply that loops and telling the agent why, in the order to ask them.
    fn interrupt(&self, note: String) -> [Ask; 2];

    /// Restarting the session's Python kernel, for an agent whose sessions have one: given the session's file.
    fn restart_kernel(
        &self,
        session_file: Option<String>,
    ) -> Option<BoxFuture<'static, Result<Value>>>;

    /// Answering a question the agent asked the user, for an agent that asks questions.
    fn answer(&self, question_id: String, answers: Vec<Value>) -> Option<Ask>;

    /// Asking which thinking levels the session's model takes, for an agent that answers it. Otherwise they are read
    /// from the model list, where a level the model lacks is null.
    fn thinking_levels(&self) -> Option<Ask>;
}

/// Pi's RPC commands.
pub struct PiRpc;

impl Verbs for PiRpc {
    /// Prompted when idle; steered while it works. A prompt the agent refuses as busy (a turn began meanwhile) is
    /// steered by the caller.
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

    fn auto_compaction(&self, enabled: bool) -> Option<Ask> {
        Some(Ask::SetAutoCompaction(enabled))
    }

    fn new_session(&self) -> Option<Ask> {
        Some(Ask::NewSession)
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

    fn answer(&self, _: String, _: Vec<Value>) -> Option<Ask> {
        None
    }

    fn thinking_levels(&self) -> Option<Ask> {
        Some(Ask::ThinkingLevels)
    }
}

/// DeepSeek Harness's commands: it compacts on its own, opens one conversation per session, and asks questions.
pub struct DshVerbs;

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

/// Prime Agent's commands, as its daemon takes them.
pub struct PrimeVerbs;

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
        Some(Box::pin(crate::prime::restart_kernel(session_file)))
    }

    fn answer(&self, _: String, _: Vec<Value>) -> Option<Ask> {
        None
    }

    /// Prime has no levels command.
    fn thinking_levels(&self) -> Option<Ask> {
        None
    }
}

/// How an agent's sessions come about.
pub enum Sessions<'a> {
    /// The bridge starts a process for each session, and stops it.
    Started(&'a dyn Starts),
    /// The agent keeps its sessions itself, as Prime's daemon does: the bridge asks it to make one, and asks the
    /// ones it has.
    Kept(&'a dyn Keeps),
}

/// An agent the bridge runs as a process for each session.
pub trait Starts {
    /// Start a session: what runs it, and what it says besides answers.
    fn start(&self, opts: &SpawnOptions) -> Result<Started>;
}

/// An agent that keeps its sessions itself.
pub trait Keeps {
    /// The session it keeps under `id`.
    fn session(&self, id: &str) -> Arc<dyn Live>;

    /// Stop the session it keeps under `id`.
    fn stop(&self, id: &str) -> BoxFuture<'_, Result<()>>;

    /// Make one there, and say how its roster will list it.
    fn create(
        &self,
        cwd: String,
        model: Option<String>,
        thinking: Option<String>,
    ) -> BoxFuture<'_, Result<PrimeRow>>;
}

/// An agent answered a command and said no, in its own words: as opposed to not being there, or not answering.
#[derive(Debug)]
pub struct Refused(pub String);

impl std::fmt::Display for Refused {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for Refused {}

/// Where a session's background commands are found.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JobsFrom {
    /// The files Pi's background-command extension keeps for each session.
    Files,
    /// The processes under the session's Python kernel, with what Prime lists of them.
    Kernel,
    /// The agent is asked, and reports their number in its events.
    Agent,
}

pub type Started = (Arc<dyn Live>, mpsc::UnboundedReceiver<ChildOutput>);

/// A session's agent while it runs.
pub trait Live: Send + Sync {
    /// Ask it one thing and wait for the answer.
    fn send(&self, ask: Ask) -> BoxFuture<'_, Result<Value>>;

    /// Its process here, when it has one.
    fn pid(&self) -> Option<u32> {
        None
    }

    /// End it in good order.
    fn close(&self) -> BoxFuture<'_, ()>;
}

/// The agents, one for each kind: a kind without one does not compile.
pub struct Agents {
    pi: Arc<dyn Agent>,
    prime: Arc<dyn Agent>,
    deepseek: Arc<dyn Agent>,
}

impl Agents {
    /// The agents Shed ships with.
    pub fn installed(prime: Arc<PrimeDaemon>, store: Store) -> Agents {
        Agents::of(|kind| match kind {
            AgentKind::Pi => Arc::new(Pi(store.clone())),
            AgentKind::Deepseek => Arc::new(Deepseek(store.clone())),
            AgentKind::Prime => Arc::new(Prime(prime.clone())),
        })
    }

    pub fn of(agent: impl Fn(AgentKind) -> Arc<dyn Agent>) -> Agents {
        Agents {
            pi: agent(AgentKind::Pi),
            prime: agent(AgentKind::Prime),
            deepseek: agent(AgentKind::Deepseek),
        }
    }

    pub fn get(&self, kind: AgentKind) -> &Arc<dyn Agent> {
        match kind {
            AgentKind::Pi => &self.pi,
            AgentKind::Prime => &self.prime,
            AgentKind::Deepseek => &self.deepseek,
        }
    }
}

struct Pi(Store);

impl Starts for Pi {
    fn start(&self, opts: &SpawnOptions) -> Result<Started> {
        let mut args: Vec<String> = vec!["--mode".into(), "rpc".into()];
        if let Some(model) = &opts.model {
            args.extend(["--model".into(), model.clone()]);
        }
        if let Some(thinking) = &opts.thinking {
            args.extend(["--thinking".into(), thinking.clone()]);
        }
        args.extend([
            "--append-system-prompt".into(),
            crate::guide::text(opts.agent, &self.0),
        ]);
        if let Some(resume) = &opts.resume {
            args.extend(["--session".into(), resume.clone()]);
        }
        // The guide as a file, for the subagents Pi starts: they get no system prompt from the bridge.
        let guide = self.0.dir().join("guide.md");
        if let Err(e) = std::fs::write(&guide, crate::guide::text(AgentKind::Pi, &self.0)) {
            eprintln!(
                "can't write the guide for Pi's subagents to {}: {e}",
                guide.display()
            );
        }
        let env = vec![
            // Where Pi's background-jobs extension keeps this session's jobs, for listing and cancelling them here.
            (
                "AGENT_REMOTE_JOBS_DIR".to_string(),
                crate::jobs::pi_dir(&opts.session_id)
                    .to_string_lossy()
                    .into_owned(),
            ),
            // Read by Pi's subagent extension.
            (
                "AGENT_REMOTE_GUIDE".to_string(),
                guide.to_string_lossy().into_owned(),
            ),
        ];
        let launch = Launch {
            program: "pi".into(),
            args,
            env,
            protocol: Protocol::Pi,
        };
        let (child, output) = RpcChild::spawn(launch, opts)?;
        Ok((child, output))
    }
}

impl Agent for Pi {
    fn sessions(&self) -> Sessions<'_> {
        Sessions::Started(self)
    }

    fn models(&self) -> BoxFuture<'_, Result<Value>> {
        Box::pin(crate::rpc::listed_models("pi", &["--list-models"]))
    }

    fn jobs(&self) -> JobsFrom {
        JobsFrom::Files
    }

    /// The id in the file's name, `<time>_<id>.jsonl`.
    fn gateway_session(&self, file_name: &str) -> String {
        file_name
            .rsplit('_')
            .next()
            .unwrap_or(file_name)
            .to_string()
    }

    fn spend_includes_subagents(&self) -> bool {
        false
    }

    fn verbs(&self) -> &'static dyn Verbs {
        &PiRpc
    }
}

/// DeepSeek Harness, driven through Shed's dsh plugin by `crate::dsh`.
struct Deepseek(Store);

impl Starts for Deepseek {
    fn start(&self, opts: &SpawnOptions) -> Result<Started> {
        // The session's model, reasoning effort and resumption go to the plugin once it starts.
        let layer = crate::dsh::install_profile(&self.0)
            .context("the Shed profile for dsh can't be written")?
            .to_string_lossy()
            .into_owned();
        let launch = Launch {
            program: "dsh".into(),
            args: ["--profile", crate::dsh::PROFILE, "--patch", &layer]
                .iter()
                .map(|a| a.to_string())
                .collect(),
            // Shed runs its agents without asking or a sandbox, as it does Pi and Prime.
            env: vec![("DSH_PERMISSION_MODE".into(), "danger-full-access".into())],
            protocol: Protocol::Dsh,
        };
        let (child, output) = RpcChild::spawn(launch, opts)?;
        Ok((child, output))
    }
}

impl Agent for Deepseek {
    fn sessions(&self) -> Sessions<'_> {
        Sessions::Started(self)
    }

    fn models(&self) -> BoxFuture<'_, Result<Value>> {
        Box::pin(crate::dsh::list_models(&self.0))
    }

    fn jobs(&self) -> JobsFrom {
        JobsFrom::Agent
    }

    fn gateway_session(&self, file_name: &str) -> String {
        file_name.to_string()
    }

    fn spend_includes_subagents(&self) -> bool {
        false
    }

    fn verbs(&self) -> &'static dyn Verbs {
        &DshVerbs
    }
}

/// Prime Agent, whose sessions live in its daemon: the daemon announces them, and the bridge attaches.
struct Prime(Arc<PrimeDaemon>);

impl Keeps for Prime {
    fn create(
        &self,
        cwd: String,
        model: Option<String>,
        thinking: Option<String>,
    ) -> BoxFuture<'_, Result<PrimeRow>> {
        Box::pin(async move {
            self.0
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
            daemon: self.0.clone(),
            id: id.to_string(),
        })
    }
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

    fn gateway_session(&self, file_name: &str) -> String {
        file_name.to_string()
    }

    /// Prime counts what its subagents spend into their parent.
    fn spend_includes_subagents(&self) -> bool {
        true
    }

    fn verbs(&self) -> &'static dyn Verbs {
        &PrimeVerbs
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

impl Live for RpcChild {
    fn send(&self, ask: Ask) -> BoxFuture<'_, Result<Value>> {
        Box::pin(RpcChild::send(self, ask))
    }

    fn pid(&self) -> Option<u32> {
        RpcChild::pid(self)
    }

    fn close(&self) -> BoxFuture<'_, ()> {
        Box::pin(RpcChild::close(self))
    }
}
