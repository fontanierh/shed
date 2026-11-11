//! What the bridge asks of an agent, and the agents it has. Adding one is implementing `Agent` for it and giving it
//! its place in `Agents`; `docs/architecture.md` says what else a new agent needs.

use std::sync::Arc;

use anyhow::{Context, Result};
use futures_util::future::BoxFuture;
use serde_json::Value;
use tokio::sync::mpsc;

use crate::agent_wire::PrimeRow;
use crate::ask::Ask;
use crate::prime::PrimeDaemon;
use crate::rpc::{AgentKind, ChildOutput, Launch, Protocol, RpcChild, SpawnOptions};
use crate::store::Store;

/// One kind of agent.
pub trait Agent: Send + Sync {
    /// How its sessions come about. Every agent says which: there is no third way, and no default.
    fn sessions(&self) -> Sessions<'_>;

    /// The models a session can start on, as `[{provider, id, name}]`.
    fn models(&self) -> BoxFuture<'_, Result<Value>>;

    /// Whether it lists, shows and stops its background commands itself (`dsh_jobs`, `dsh_job_output`,
    /// `dsh_kill_job`) and reports them as events. Otherwise the bridge reads them where the agent leaves them.
    fn jobs(&self) -> JobsFrom;

    /// The session id it sends Open Codex with its requests, from the name of the session's file without its
    /// extension. An agent that keeps its own sessions is known by its conversation instead.
    fn gateway_session(&self, file_name: &str) -> String;

    /// Whether what Open Codex counts for a session already holds what its subagents spent.
    fn spend_includes_subagents(&self) -> bool;
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
        let launch = Launch {
            program: "pi".into(),
            args,
            env: Vec::new(),
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
}

struct PrimeSession {
    daemon: Arc<PrimeDaemon>,
    id: String,
}

impl Live for PrimeSession {
    fn send(&self, ask: Ask) -> BoxFuture<'_, Result<Value>> {
        Box::pin(async move {
            let (kind, fields) = ask.wire();
            self.daemon.session(&self.id, kind, fields).await
        })
    }

    fn close(&self) -> BoxFuture<'_, ()> {
        Box::pin(async {})
    }
}

impl Live for RpcChild {
    fn send(&self, ask: Ask) -> BoxFuture<'_, Result<Value>> {
        Box::pin(async move {
            let (kind, fields) = ask.wire();
            RpcChild::send(self, kind, fields, ask.limit()).await
        })
    }

    fn pid(&self) -> Option<u32> {
        RpcChild::pid(self)
    }

    fn close(&self) -> BoxFuture<'_, ()> {
        Box::pin(RpcChild::close(self))
    }
}
