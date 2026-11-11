//! Everything the bridge asks a session's agent, as one type, with how long it may take. Each driver turns an
//! `Ask` into its own protocol; `wire` is the JSONL RPC form shared by Pi and Prime's daemon.

use std::time::Duration;

use serde_json::{json, Value};

use crate::requests::{QUICK, SLOW};

/// How a message reaches an agent that may be in the middle of a turn.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Delivery {
    /// As a new turn: the agent refuses it while it works.
    Turn,
    /// Into the turn that is running, at its next step.
    Steer,
    /// Into the turn that is running, and kept for the next one when none is.
    SteerOrQueue,
    /// After the turn that is running.
    FollowUp,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Ask {
    Prompt {
        message: String,
        delivery: Delivery,
    },
    Steer(String),
    FollowUp(String),
    Abort,
    /// Prime's: stop the turn and hand over what was steered in meanwhile.
    AbortAndSendQueued,
    State,
    Stats,
    Messages,
    Models,
    ThinkingLevels,
    SetModel {
        provider: String,
        model_id: String,
    },
    SetThinkingLevel(String),
    SetName(String),
    SetAutoCompaction(bool),
    Compact {
        instructions: Option<String>,
    },
    NewSession,
    /// The background commands of an agent that lists its own (`JobsFrom::Agent`).
    Jobs,
    JobOutput(String),
    KillJob(String),
    /// The user's answer to a question the agent asked.
    Answer {
        question_id: String,
        answers: Vec<Value>,
    },
    /// Prime's background commands: those of its kernel, and its persistent shells.
    KernelBash,
    PersistentShells,
    TailKernelBash {
        activity: String,
        lines: u32,
    },
    TailPersistentShell {
        shell: String,
        lines: u32,
    },
    KillKernelBash(String),
    KillPersistentShell(String),
    /// Prime's: have the daemon send this session's events, and answer with its transcript.
    Attach,
}

impl Ask {
    /// The command in Pi's RPC vocabulary and Prime's daemon extensions, or `None` for commands outside it.
    pub fn wire(&self) -> Option<(&'static str, Value)> {
        Some(match self {
            Ask::Prompt { message, delivery } => (
                "prompt",
                match delivery {
                    Delivery::Turn => json!({ "message": message }),
                    Delivery::Steer => json!({ "message": message, "streamingBehavior": "steer" }),
                    Delivery::SteerOrQueue => {
                        json!({ "message": message, "streamingBehavior": "steer", "queueIfBusy": true })
                    }
                    Delivery::FollowUp => {
                        json!({ "message": message, "streamingBehavior": "followUp" })
                    }
                },
            ),
            Ask::Steer(message) => ("steer", json!({ "message": message })),
            Ask::FollowUp(message) => ("follow_up", json!({ "message": message })),
            Ask::Abort => ("abort", json!({})),
            Ask::AbortAndSendQueued => ("abort_and_send_queued", json!({})),
            Ask::State => ("get_state", json!({})),
            Ask::Stats => ("get_session_stats", json!({})),
            Ask::Messages => ("get_messages", json!({})),
            Ask::Models => ("get_available_models", json!({})),
            Ask::ThinkingLevels => ("get_available_thinking_levels", json!({})),
            Ask::SetModel { provider, model_id } => (
                "set_model",
                json!({ "provider": provider, "modelId": model_id }),
            ),
            Ask::SetThinkingLevel(level) => ("set_thinking_level", json!({ "level": level })),
            Ask::SetName(name) => ("set_session_name", json!({ "name": name })),
            Ask::SetAutoCompaction(enabled) => {
                ("set_auto_compaction", json!({ "enabled": enabled }))
            }
            Ask::Compact { instructions } => (
                "compact",
                match instructions {
                    Some(text) => json!({ "customInstructions": text }),
                    None => json!({}),
                },
            ),
            Ask::NewSession => ("new_session", json!({})),
            Ask::KernelBash => ("list_kernel_bash", json!({})),
            Ask::PersistentShells => ("list_persistent_shells", json!({})),
            Ask::TailKernelBash { activity, lines } => (
                "tail_kernel_bash",
                json!({ "activityId": activity, "lines": lines }),
            ),
            Ask::TailPersistentShell { shell, lines } => (
                "tail_persistent_shell",
                json!({ "shellId": shell, "lines": lines }),
            ),
            Ask::KillKernelBash(activity) => {
                ("kill_kernel_bash", json!({ "activityId": activity }))
            }
            Ask::KillPersistentShell(shell) => {
                ("kill_persistent_shell", json!({ "shellId": shell }))
            }
            Ask::Attach => (
                "attach",
                json!({ "capabilities": ["attach_snapshot", "event_sequence"] }),
            ),
            Ask::Jobs | Ask::JobOutput(_) | Ask::KillJob(_) | Ask::Answer { .. } => return None,
        })
    }

    /// How long an agent that is there may take to answer. A compaction is answered once it is done; everything
    /// else is answered from what the agent already holds.
    pub fn limit(&self) -> Duration {
        match self {
            Ask::Compact { .. } => SLOW,
            _ => QUICK,
        }
    }
}
