//! What the bridge asks of an agent, and the agents it has. Adding one is implementing `Agent` for it and listing it
//! in `Agents::installed`; `docs/architecture.md` says what else a new agent needs.

use std::collections::HashMap;
use std::sync::Arc;

use anyhow::{anyhow, bail, Context, Result};
use futures_util::future::BoxFuture;
use serde_json::Value;
use tokio::sync::mpsc;

use crate::prime::PrimeDaemon;
use crate::rpc::{AgentKind, ChildOutput, Launch, Protocol, RpcChild, SpawnOptions};

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

    /// The models a session can start on, as `[{provider, id, name}]`.
    fn models(&self) -> BoxFuture<'_, Result<Value>>;
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

/// The agents by kind.
pub struct Agents(HashMap<AgentKind, Arc<dyn Agent>>);

impl Agents {
    /// The agents Shed ships with.
    pub fn installed(prime: Arc<PrimeDaemon>) -> Agents {
        Agents::of([
            (AgentKind::Pi, Arc::new(Pi) as Arc<dyn Agent>),
            (AgentKind::Deepseek, Arc::new(Deepseek)),
            (AgentKind::Prime, Arc::new(Prime(prime))),
        ])
    }

    pub fn of(agents: impl IntoIterator<Item = (AgentKind, Arc<dyn Agent>)>) -> Agents {
        Agents(agents.into_iter().collect())
    }

    pub fn get(&self, kind: AgentKind) -> Result<&Arc<dyn Agent>> {
        self.0
            .get(&kind)
            .ok_or_else(|| anyhow!("this bridge has no {kind:?} agent"))
    }
}

struct Pi;

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
            crate::guide::text(opts.agent),
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
}

/// DeepSeek Harness, driven through Shed's dsh plugin by `crate::dsh`.
struct Deepseek;

impl Agent for Deepseek {
    fn start(&self, opts: &SpawnOptions) -> Result<Started> {
        // The session's model, reasoning effort and resumption go to the plugin once it starts.
        let layer = crate::dsh::install_profile()
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
        Box::pin(crate::dsh::list_models())
    }
}

/// Prime Agent, whose sessions live in its daemon: the daemon announces them, and the bridge attaches.
struct Prime(Arc<PrimeDaemon>);

impl Agent for Prime {
    fn session(&self, id: &str) -> Option<Arc<dyn Live>> {
        Some(Arc::new(PrimeSession {
            daemon: self.0.clone(),
            id: id.to_string(),
        }))
    }

    fn models(&self) -> BoxFuture<'_, Result<Value>> {
        Box::pin(crate::rpc::listed_models("prime-agent", &["model", "list"]))
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
