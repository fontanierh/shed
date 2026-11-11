//! Pi (`pi --mode rpc`): one subprocess per session, plus `PiRpc` for any agent speaking Pi's JSONL RPC protocol.

use std::sync::Arc;

use anyhow::Result;
use futures_util::future::BoxFuture;
use serde_json::Value;

use crate::agent::AgentKind;
use crate::agent::{file_stem, Agent, JobsFrom, Sessions, Started, Starts, SubagentsFrom, Verbs};
use crate::agent_wire::ConversationId;
use crate::ask::{Ask, Delivery};
use crate::rpc::{Launch, RpcChild, SpawnOptions};
use crate::store::Store;

pub fn agent(store: Store) -> Arc<dyn Agent> {
    Arc::new(Pi(store))
}

struct Pi(Store);

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

    fn subagents(&self) -> SubagentsFrom {
        SubagentsFrom::PiTool
    }

    /// The id in the file's name, `<time>_<id>.jsonl`.
    fn gateway_session(
        &self,
        session_file: Option<&str>,
        _conversation: Option<&ConversationId>,
    ) -> Option<String> {
        let name = file_stem(session_file)?;
        Some(name.rsplit('_').next().unwrap_or(name).to_string())
    }

    fn cost(&self, _session_file: Option<&str>, reported: f64, _before: f64) -> f64 {
        reported
    }

    fn spend_includes_subagents(&self) -> bool {
        false
    }

    fn verbs(&self) -> &'static dyn Verbs {
        &PiRpc
    }
}

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
        // The guide as a file, for the subagents Pi starts: written atomically only when changed so a subagent
        // reading it concurrently never sees a truncated file.
        let guide = self.0.dir().join("guide.md");
        let guide_text = crate::guide::text(AgentKind::Pi, &self.0);
        if std::fs::read_to_string(&guide).ok().as_deref() != Some(guide_text.as_str()) {
            if let Err(e) = crate::store::write_private(&guide, guide_text.as_bytes()) {
                eprintln!(
                    "can't write the guide for Pi's subagents to {}: {e}",
                    guide.display()
                );
            }
        }
        let env = vec![
            // Where Pi's background-jobs extension keeps this session's jobs, for listing and cancelling them here.
            (
                "AGENT_REMOTE_JOBS_DIR".to_string(),
                crate::jobs::pi_dir(&self.0, &opts.session_id)
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
        };
        let (child, output) = RpcChild::spawn(launch, opts)?;
        Ok((child, output))
    }
}

/// Pi's RPC commands, reusable by any agent speaking Pi's JSONL RPC protocol.
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
