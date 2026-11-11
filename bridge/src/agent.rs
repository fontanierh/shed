//! What the bridge asks of an agent, and the agents it has. Adding one is implementing `Agent` for it and giving it
//! its place in `Agents`; `docs/architecture.md` says what else a new agent needs.

use std::sync::Arc;

use anyhow::{bail, Context, Result};
use futures_util::future::BoxFuture;
use serde_json::Value;
use tokio::sync::mpsc;

use crate::agent_wire::PrimeRow;
use crate::prime::PrimeDaemon;
use crate::rpc::{AgentKind, ChildOutput, Launch, Protocol, RpcChild, SpawnOptions};
use crate::store::Store;

/// One kind of agent. An agent the bridge runs as a process starts its sessions here (`start`); one that keeps its
/// sessions itself, as Prime's daemon does, hands out the ones it has (`session`).
pub trait Agent: Send + Sync {
    /// Start a session as a process of this agent: what runs it, and what it says besides answers.
    fn start(&self, opts: &SpawnOptions) -> Result<Started> {
        bail!("{:?} sessions are not started by the bridge", opts.agent)
    }

    /// The session this agent keeps under `id`, for an agent that keeps its sessions itself.
    fn session(&self, _id: &str) -> Option<Arc<dyn Live>> {
        None
    }

    /// For an agent that keeps its sessions itself: make one there, and say how its roster will list it. None from
    /// an agent whose sessions the bridge starts.
    fn create(
        &self,
        _cwd: String,
        _model: Option<String>,
        _thinking: Option<String>,
    ) -> Option<BoxFuture<'_, Result<PrimeRow>>> {
        None
    }

    /// The models a session can start on, as `[{provider, id, name}]`.
    fn models(&self) -> BoxFuture<'_, Result<Value>>;

    /// Whether it lists, shows and stops its background commands itself (`dsh_jobs`, `dsh_job_output`,
    /// `dsh_kill_job`) and reports them as events. Otherwise the bridge reads them where the agent leaves them.
    fn lists_own_jobs(&self) -> bool;

    /// The session id it sends Open Codex with its requests, from the name of the session's file without its
    /// extension. An agent that keeps its own sessions is known by its conversation instead.
    fn gateway_session(&self, file_name: &str) -> String;

    /// Whether what Open Codex counts for a session already holds what its subagents spent.
    fn spend_includes_subagents(&self) -> bool;
}

pub type Started = (Arc<dyn Live>, mpsc::UnboundedReceiver<ChildOutput>);

/// A session's agent while it runs.
pub trait Live: Send + Sync {
    /// Ask it one command, in Pi's vocabulary, and wait for the answer.
    fn send(&self, kind: &str, fields: Value) -> BoxFuture<'_, Result<Value>>;

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

impl Agent for Pi {
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

    fn models(&self) -> BoxFuture<'_, Result<Value>> {
        Box::pin(crate::rpc::listed_models("pi", &["--list-models"]))
    }

    fn lists_own_jobs(&self) -> bool {
        false
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

impl Agent for Deepseek {
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

    fn models(&self) -> BoxFuture<'_, Result<Value>> {
        Box::pin(crate::dsh::list_models(&self.0))
    }

    fn lists_own_jobs(&self) -> bool {
        true
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

impl Agent for Prime {
    fn create(
        &self,
        cwd: String,
        model: Option<String>,
        thinking: Option<String>,
    ) -> Option<BoxFuture<'_, Result<PrimeRow>>> {
        Some(Box::pin(async move {
            self.0
                .create(&cwd, model.as_deref(), thinking.as_deref())
                .await
        }))
    }

    fn session(&self, id: &str) -> Option<Arc<dyn Live>> {
        Some(Arc::new(PrimeSession {
            daemon: self.0.clone(),
            id: id.to_string(),
        }))
    }

    fn models(&self) -> BoxFuture<'_, Result<Value>> {
        Box::pin(crate::rpc::listed_models("prime-agent", &["model", "list"]))
    }

    fn lists_own_jobs(&self) -> bool {
        false
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
    fn send(&self, kind: &str, fields: Value) -> BoxFuture<'_, Result<Value>> {
        let kind = kind.to_string();
        Box::pin(async move { self.daemon.session(&self.id, &kind, fields).await })
    }

    fn close(&self) -> BoxFuture<'_, ()> {
        Box::pin(async {})
    }
}

impl Live for RpcChild {
    fn send(&self, kind: &str, fields: Value) -> BoxFuture<'_, Result<Value>> {
        let kind = kind.to_string();
        Box::pin(async move { RpcChild::send(self, &kind, fields).await })
    }

    fn pid(&self) -> Option<u32> {
        RpcChild::pid(self)
    }

    fn close(&self) -> BoxFuture<'_, ()> {
        Box::pin(RpcChild::close(self))
    }
}
