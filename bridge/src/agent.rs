//! What the bridge asks of an agent (`Agent`, `Verbs`, `Starts`, `Keeps`, `Live`) and the registry of installed
//! agents (`Agents`). Each agent implements these traits in its own module (`pi`, `dsh`, `prime`); see
//! `docs/architecture.md` for adding another.

use std::sync::Arc;

use anyhow::Result;
use futures_util::future::BoxFuture;
use serde_json::Value;
use tokio::sync::mpsc;

use crate::agent_wire::{ConversationId, PrimeRow};
use crate::ask::Ask;
use crate::prime::PrimeDaemon;
use crate::rpc::{AgentKind, ChildOutput, SpawnOptions};
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

    /// How a session's subagents reach the bridge.
    fn subagents(&self) -> SubagentsFrom;

    /// The session id it sends Open Codex with its requests, from the session's file or conversation id.
    fn gateway_session(
        &self,
        session_file: Option<&str>,
        conversation: Option<&ConversationId>,
    ) -> Option<String>;

    /// What a session has spent, given its file, what the agent reports now, and what was counted before.
    fn cost(&self, session_file: Option<&str>, reported: f64, before: f64) -> f64;

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

/// How a session's subagents reach the bridge.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SubagentsFrom {
    /// Streamed inside the parent's `subagent` tool call (`details.results`).
    PiTool,
    /// Sent as events of their own (`dsh_subagent`).
    Events,
    /// Listed as sessions in the agent's own roster.
    Roster,
}

pub(crate) fn file_stem(path: Option<&str>) -> Option<&str> {
    std::path::Path::new(path?).file_stem()?.to_str()
}

/// What a session of `agent` supports across the wire. Read-only subagents are views of a parent's conversation and
/// take no commands or background jobs of their own.
pub fn capabilities(agent: &dyn Agent, read_only: bool) -> crate::protocol::Capabilities {
    if read_only {
        return crate::protocol::Capabilities {
            resume: false,
            restart_kernel: false,
            clear_goal: false,
            new_session: false,
            auto_compaction_switch: false,
            follow_up: false,
            answer: false,
            background_commands: false,
            spend_includes_subagents: agent.spend_includes_subagents(),
        };
    }
    let verbs = agent.verbs();
    crate::protocol::Capabilities {
        resume: matches!(agent.sessions(), Sessions::Started(_)),
        restart_kernel: verbs.restart_kernel(None).is_some(),
        clear_goal: verbs.clear_goal().is_some(),
        new_session: verbs.new_session().is_some(),
        auto_compaction_switch: verbs.auto_compaction(true).is_some(),
        follow_up: verbs.follow_up(String::new()).is_some(),
        answer: verbs.answer(String::new(), Vec::new()).is_some(),
        background_commands: true,
        spend_includes_subagents: agent.spend_includes_subagents(),
    }
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
            AgentKind::Pi => crate::pi::agent(store.clone()),
            AgentKind::Deepseek => crate::dsh::agent(store.clone()),
            AgentKind::Prime => crate::prime::agent(prime.clone()),
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

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn each_agent_names_its_gateway_session_from_its_own_record() {
        let store = Store::temporary("agent-gateway");
        let prime = PrimeDaemon::unconnected("test".into(), store.clone());
        let agents = Agents::installed(prime, store.clone());
        let conv = PrimeRow::read(&json!({ "activeSessionId": "a1", "sessionId": "conv-1" }))
            .unwrap()
            .conversation
            .unwrap();

        assert_eq!(
            agents
                .get(AgentKind::Pi)
                .gateway_session(Some("/sessions/2026-11-11_abc123.jsonl"), Some(&conv)),
            Some("abc123".into())
        );
        assert_eq!(
            agents
                .get(AgentKind::Deepseek)
                .gateway_session(Some("/sessions/2026-11-11_abc123.jsonl"), Some(&conv)),
            Some("2026-11-11_abc123".into())
        );
        assert_eq!(
            agents
                .get(AgentKind::Prime)
                .gateway_session(Some("/sessions/file.jsonl"), None),
            None
        );
        assert_eq!(
            agents
                .get(AgentKind::Prime)
                .gateway_session(Some("/sessions/file.jsonl"), Some(&conv)),
            Some("conv-1".into())
        );
        let _ = std::fs::remove_dir_all(store.dir());
    }

    #[test]
    fn prime_adds_subagent_spending_from_the_session_file_and_never_drops() {
        let store = Store::temporary("agent-cost");
        let prime = PrimeDaemon::unconnected("test".into(), store.clone());
        let agents = Agents::installed(prime, store.clone());
        let file = store.dir().join("s1.jsonl");
        std::fs::write(
            &file,
            "{\"type\":\"message\",\"message\":{\"role\":\"assistant\",\"usage\":{\"cost\":0.4}}}\n\
             {\"type\":\"child_usage_attributed\",\"childUsage\":{\"cost\":{\"total\":0.25}}}\n",
        )
        .unwrap();
        let path = file.to_str();

        assert_eq!(agents.get(AgentKind::Pi).cost(path, 0.3, 0.5), 0.3);
        assert_eq!(agents.get(AgentKind::Deepseek).cost(path, 0.3, 0.5), 0.3);
        assert!((agents.get(AgentKind::Prime).cost(path, 0.3, 0.0) - 0.65).abs() < 1e-9);
        assert!((agents.get(AgentKind::Prime).cost(path, 0.3, 0.8) - 0.8).abs() < 1e-9);
        let _ = std::fs::remove_dir_all(store.dir());
    }
}
