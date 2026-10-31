//! Telling a stuck tool call or background command from a slow one, so the reader can be told to cancel it.
//!
//! A command that has run a minute and used no CPU for the last 45 seconds, nor has anything under it, is suspect:
//! waiting, but on what? Most often macOS's permission prompt for Documents, Desktop or Downloads, which holds the
//! command until someone answers on that Mac; that one is recognised from the folder it names. Anything else is
//! asked of OpenAI's Decisions API, when the bridge has an OpenAI key for it (`stallCheck` in config.json): a `sleep`,
//! a server or a slow download wait without CPU too, and only reading the command tells them apart. It answers with
//! the probability that the command is stuck, and what it most likely waits on. Without a key, only the permission
//! prompt is flagged.

use std::collections::VecDeque;
use std::time::{Duration, Instant};

use anyhow::{anyhow, Result};
use serde_json::{json, Value};
use tokio::io::AsyncWriteExt;

use crate::protocol::Stuck;

/// The only model the Decisions API serves for now.
pub const DEFAULT_MODEL: &str = "gpt-6-luna";
/// How sure the model must be that a command is stuck before the reader is told.
pub const DEFAULT_THRESHOLD: f64 = 0.8;
/// Younger commands are never suspect.
const MIN_AGE: Duration = Duration::from_secs(60);
/// How long a command must use (almost) no CPU to be suspect.
const STILL_FOR: Duration = Duration::from_secs(45);
const STILL_CPU: f64 = 0.1;
/// CPU over the last few seconds that shows a command flagged as stuck is moving again.
const MOVING_CPU: f64 = 0.3;
/// After a "not stuck", how long before the same command is asked about again.
const ASK_AGAIN_AFTER: Duration = Duration::from_secs(600);

/// The model asked about suspect commands.
#[derive(Clone)]
pub struct Judge {
    pub key: String,
    pub model: String,
    pub threshold: f64,
}

/// What a session is waiting on: its current tool call, run by the REPL kernel, or a background command.
#[derive(Clone, Debug, PartialEq)]
pub struct Target {
    /// "tool" or "command", as in `Stuck`.
    pub kind: &'static str,
    pub pid: u32,
    /// Tells one tool call or command from the next under the same process.
    pub id: String,
}

/// One session's watch over what it is waiting on: CPU samples, and the verdict once there is one.
#[derive(Default)]
pub struct Tracker {
    target: Option<Target>,
    samples: VecDeque<(Instant, f64)>,
    asking: bool,
    ask_after: Option<Instant>,
    pub verdict: Option<Stuck>,
}

#[derive(Debug, PartialEq)]
pub enum Step {
    Nothing,
    /// Just became suspect: find out why.
    Suspect,
}

impl Tracker {
    /// Records the CPU the target and everything under it have used so far. A verdict lapses when the target
    /// changes or moves again.
    pub fn observe(
        &mut self,
        target: Option<Target>,
        cpu: f64,
        age: Duration,
        now: Instant,
    ) -> Step {
        if self.target != target {
            *self = Tracker {
                target,
                ..Default::default()
            };
        }
        if self.target.is_none() {
            return Step::Nothing;
        }
        self.samples.push_back((now, cpu));
        while self
            .samples
            .front()
            .is_some_and(|(at, _)| now.duration_since(*at) > STILL_FOR + Duration::from_secs(5))
        {
            self.samples.pop_front();
        }
        let recent = self
            .samples
            .iter()
            .find(|(at, _)| now.duration_since(*at) <= Duration::from_secs(6))
            .map_or(cpu, |(_, c)| *c);
        if self.verdict.is_some() && cpu - recent > MOVING_CPU {
            self.verdict = None;
            self.samples.clear();
            self.samples.push_back((now, cpu));
            return Step::Nothing;
        }
        let still = self
            .samples
            .iter()
            .rev()
            .find(|(at, _)| now.duration_since(*at) >= STILL_FOR)
            .is_some_and(|(_, c)| cpu - c < STILL_CPU);
        let may_ask = self.ask_after.is_none_or(|after| now >= after);
        if still && age >= MIN_AGE && self.verdict.is_none() && !self.asking && may_ask {
            self.asking = true;
            return Step::Suspect;
        }
        Step::Nothing
    }

    /// The answer about `target`, unless the session has moved on since.
    pub fn answered(&mut self, target: &Target, verdict: Option<Stuck>, now: Instant) {
        if self.target.as_ref() != Some(target) {
            return;
        }
        self.asking = false;
        if verdict.is_none() {
            self.ask_after = Some(now + ASK_AGAIN_AFTER);
        }
        self.verdict = verdict;
    }
}

/// What the model is told about a suspect command.
pub struct Question {
    /// "tool" or "command", as in `Target`.
    pub kind: &'static str,
    /// The Python code of a tool call, or the shell command.
    pub command: String,
    pub running_secs: u64,
    pub cwd: String,
    /// The process running it and everything under it (`ProcessTree::processes`).
    pub processes: Vec<Value>,
    pub output: String,
    /// What the agent wrote just before the call.
    pub said: Option<String>,
}

/// How commands run, so the model can read the evidence. Sent as the developer message.
const CONTEXT: &str = "You assess commands that an AI coding agent runs on a macOS computer, which its user controls \
remotely from a phone. Nobody is at the computer: a dialog shown on its screen, or a question asked on a terminal, \
goes unanswered. Commands have no terminal, and their standard input is /dev/null.

The agent writes Python in a long-lived REPL kernel process (`python -m rlm.repl`). A Python tool call runs inside \
that process, so a call blocked in Python shows as the kernel using no CPU, with nothing under it. Shell commands \
started from Python run under the kernel in a `bash -c` wrapper whose script holds the command between `{` and `}`. \
A background command is one the agent started and left running on purpose: often a server, a watcher or a long job.

macOS asks permission the first time a program reads Documents, Desktop, Downloads or iCloud Drive \
(~/Library/Mobile Documents), and holds the read until someone answers.

The evidence is a JSON object: what is running (`kind`: `tool` for the agent's current Python tool call, \
`background command` for a shell command left running), its code or command, how long it has run, how long it has \
used no CPU, every process from the one running it down with its parent, running time and CPU time, its latest \
output, the working directory, and what the agent wrote just before starting it.";

/// The proposition the model gives a probability for.
const STUCK: &str = "The command is stuck: it waits on something that will not happen without a person, such as a \
permission or password prompt, a question on a terminal nobody can answer, a pager, a lock held by another process, a \
pipe nobody writes to, or a network connection that hung with no timeout. A command waiting as intended is not \
stuck: sleep, a server or watcher, polling, waiting on a subagent or another job, or a download or remote call that \
is plausibly still in progress.";

/// What a stuck command most likely waits on, and how the reader is told.
const CAUSES: [(&str, &str, &str); 6] = [
    (
        "permission",
        "A macOS prompt asking permission to read a protected folder",
        "It is probably waiting on a macOS permission prompt on this Mac",
    ),
    (
        "input",
        "A password, passphrase, confirmation or other input nobody can type",
        "It is probably waiting for a password or other input nobody can type",
    ),
    (
        "process",
        "Another process: a pipe nobody writes to, a lock, or a child that never exits",
        "It is probably waiting on another process: a pipe, a lock or a child that never ends",
    ),
    (
        "network",
        "A network connection or remote call that hung",
        "A network call it made has probably hung",
    ),
    (
        "terminal",
        "A pager, editor or other interactive program waiting for a terminal",
        "It is probably waiting on an interactive program, such as a pager or an editor",
    ),
    (
        "nothing",
        "Nothing wrong: sleeping, serving, watching or polling as intended",
        "It has stopped making progress",
    ),
];

/// A command the model judged stuck.
#[derive(Debug, PartialEq)]
pub struct Verdict {
    pub probability: f64,
    pub reason: String,
}

/// Asks the model how likely the command is stuck, and on what: a verdict when it is likely enough.
pub async fn ask(judge: &Judge, question: &Question) -> Result<Option<Verdict>> {
    let evidence = json!({
        "kind": if question.kind == "tool" { "tool" } else { "background command" },
        "language": if question.kind == "tool" { "python" } else { "shell" },
        "code": clip(&question.command, 8000),
        "runningSeconds": question.running_secs,
        "secondsWithoutCpu": STILL_FOR.as_secs(),
        "workingDirectory": question.cwd,
        "processes": question.processes,
        "latestOutput": clip(&question.output, 4000),
        "agentSaidBefore": question.said.as_deref().map(|s| clip(s, 1500)),
    });
    let input = json!([
        { "role": "developer", "content": [{ "type": "input_text", "text": CONTEXT }] },
        { "role": "user", "content": [{ "type": "input_json", "data": evidence }] },
    ]);
    let choices: Vec<Value> = CAUSES
        .iter()
        .map(|(value, description, _)| json!({ "value": value, "description": description }))
        .collect();
    let body = json!({
        "model": judge.model,
        "input": input,
        "questions": [
            { "type": "predicate", "name": "stuck", "instructions": STUCK },
            { "type": "choice", "name": "cause", "instructions": "What is the command most likely waiting on?",
              "choices": choices },
        ],
    });
    // The key goes in on stdin, never in the arguments, where `ps` would show it.
    let config = format!(
        "header = \"Authorization: Bearer {}\"\nheader = \"Content-Type: application/json\"\ndata = \"{}\"\n",
        judge.key,
        body.to_string().replace('\\', "\\\\").replace('"', "\\\"")
    );
    let mut child = tokio::process::Command::new("/usr/bin/curl")
        .args([
            "-sS",
            "--max-time",
            "30",
            "-K",
            "-",
            "https://api.openai.com/v1/decisions",
        ])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true)
        .spawn()?;
    let mut stdin = child.stdin.take().ok_or_else(|| anyhow!("no stdin"))?;
    stdin.write_all(config.as_bytes()).await?;
    drop(stdin);
    let out = child.wait_with_output().await?;
    if !out.status.success() {
        return Err(anyhow!(
            "curl: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    verdict(&serde_json::from_slice(&out.stdout)?, judge.threshold)
}

/// The verdict in a Decisions API reply: stuck at least as likely as `threshold`.
fn verdict(response: &Value, threshold: f64) -> Result<Option<Verdict>> {
    if let Some(error) = response["error"]["message"].as_str() {
        return Err(anyhow!("{error}"));
    }
    let answers = response["answers"]
        .as_array()
        .ok_or_else(|| anyhow!("no answers in the reply"))?;
    let answer = |name: &str| answers.iter().find(|a| a["name"] == name);
    let probability = answer("stuck")
        .and_then(|a| a["probability"].as_f64())
        .ok_or_else(|| anyhow!("no probability in the reply"))?;
    if probability < threshold {
        return Ok(None);
    }
    let cause = answer("cause")
        .and_then(|a| a["choice"].as_str())
        .unwrap_or("nothing");
    let reason = CAUSES
        .iter()
        .find(|(value, ..)| *value == cause)
        .map_or(CAUSES[5].2, |(_, _, reason)| *reason);
    Ok(Some(Verdict {
        probability,
        reason: reason.to_string(),
    }))
}

/// The last `max` bytes of a text, on a character boundary.
fn clip(text: &str, max: usize) -> String {
    let mut start = text.len().saturating_sub(max);
    while !text.is_char_boundary(start) {
        start += 1;
    }
    text[start..].to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn target() -> Option<Target> {
        Some(Target {
            kind: "command",
            pid: 7,
            id: "ls ~/Documents".into(),
        })
    }

    #[test]
    fn suspects_a_command_only_once_it_has_been_still() {
        let t0 = Instant::now();
        let mut tracker = Tracker::default();
        let at = |s: u64| t0 + Duration::from_secs(s);
        // Busy for its first 40 seconds, then still.
        for s in (0..=40).step_by(2) {
            let step = tracker.observe(target(), s as f64, Duration::from_secs(20 + s), at(s));
            assert_eq!(step, Step::Nothing);
        }
        let mut suspected = None;
        for s in (42..=100).step_by(2) {
            if tracker.observe(target(), 40.0, Duration::from_secs(20 + s), at(s)) == Step::Suspect
            {
                suspected = Some(s);
                break;
            }
        }
        // Still from 40s, so suspect 45 seconds later.
        assert_eq!(suspected, Some(86));
        // Asked once, not on every sample.
        assert_eq!(
            tracker.observe(target(), 40.0, Duration::from_secs(108), at(88)),
            Step::Nothing
        );
    }

    #[test]
    fn a_verdict_lapses_when_the_command_moves_or_changes() {
        let t0 = Instant::now();
        let mut tracker = Tracker::default();
        let target = target().unwrap();
        tracker.observe(Some(target.clone()), 1.0, Duration::from_secs(100), t0);
        let stuck = Stuck {
            kind: "command",
            command: "ls".into(),
            reason: "waiting".into(),
            probability: Some(0.9),
            job_id: None,
            started_at: None,
        };
        tracker.answered(&target, Some(stuck), t0);
        assert!(tracker.verdict.is_some());
        tracker.observe(
            Some(target.clone()),
            1.0,
            Duration::from_secs(102),
            t0 + Duration::from_secs(2),
        );
        assert!(tracker.verdict.is_some());
        tracker.observe(
            Some(target.clone()),
            3.0,
            Duration::from_secs(104),
            t0 + Duration::from_secs(4),
        );
        assert!(tracker.verdict.is_none());
        tracker.answered(&target, None, t0);
        let other = Target {
            pid: 8,
            ..target.clone()
        };
        tracker.observe(
            Some(other),
            0.0,
            Duration::from_secs(1),
            t0 + Duration::from_secs(6),
        );
        assert!(tracker.verdict.is_none());
    }

    #[test]
    fn reads_the_verdict_from_a_reply() {
        let reply = json!({ "answers": [
            { "type": "predicate", "name": "stuck", "probability": 0.93 },
            { "type": "choice", "name": "cause", "choice": "input", "probabilities": [], "confidence": 0.9 }
        ] });
        assert_eq!(
            verdict(&reply, 0.8).unwrap(),
            Some(Verdict {
                probability: 0.93,
                reason: "It is probably waiting for a password or other input nobody can type"
                    .into()
            })
        );
        assert_eq!(verdict(&reply, 0.95).unwrap(), None);
        let refused = json!({ "answers": [
            { "type": "predicate", "name": "stuck", "probability": 0.9 },
            { "type": "refusal", "name": "cause" }
        ] });
        assert_eq!(
            verdict(&refused, 0.8).unwrap().unwrap().reason,
            "It has stopped making progress"
        );
        assert!(verdict(&json!({ "error": { "message": "bad key" } }), 0.8).is_err());
    }

    /// Asks the configured model for real: `cargo test -- --ignored asks_the_model`.
    #[tokio::test]
    #[ignore]
    async fn asks_the_model() {
        let config: Value = serde_json::from_str(
            &std::fs::read_to_string(format!(
                "{}/.agent-remote/config.json",
                std::env::var("HOME").unwrap()
            ))
            .unwrap(),
        )
        .unwrap();
        let judge = Judge {
            key: config["stallCheck"]["openaiApiKey"]
                .as_str()
                .unwrap()
                .to_string(),
            model: DEFAULT_MODEL.to_string(),
            threshold: 0.0,
        };
        let proc = |pid: u32, parent: u32, command: &str, secs: u64, cpu: f64, kids: bool| {
            json!({ "pid": pid, "parentPid": parent, "command": command, "runningSeconds": secs,
                    "cpuSeconds": cpu, "hasChildren": kids })
        };
        let wrapper = |command: &str| {
            format!("/bin/bash -c exec 9>&0 8>&1 0</dev/null\nread -r _prime_agent_gate <&9 || exit 127\n{{\n{command}\n}} 8>&- 9>&-")
        };
        let kernel = "/Users/me/.prime/agent/kernel-venv/bin/python -m rlm.repl";
        let cases = [
            ("passphrase", true, Question {
                kind: "command",
                command: "cd ~/src/app && git push origin main".into(),
                running_secs: 600,
                cwd: "/Users/me/src/app".into(),
                processes: vec![
                    proc(20, 11, &wrapper("cd ~/src/app && git push origin main"), 600, 0.0, true),
                    proc(21, 20, "git push origin main", 600, 0.01, true),
                    proc(22, 21, "ssh git@github.com git-receive-pack 'me/app.git'", 600, 0.0, false),
                ],
                output: "Enter passphrase for key '/Users/me/.ssh/id_ed25519':".into(),
                said: Some("Pushing the fix to main.".into()),
            }),
            ("server", false, Question {
                kind: "command",
                command: "python -m http.server 8000".into(),
                running_secs: 600,
                cwd: "/Users/me/src/site".into(),
                processes: vec![
                    proc(20, 11, &wrapper("python -m http.server 8000"), 600, 0.0, true),
                    proc(21, 20, "python -m http.server 8000", 600, 0.05, false),
                ],
                output: "Serving HTTP on :: port 8000 (http://[::]:8000/) ...".into(),
                said: Some("I'll serve the site locally so you can preview it.".into()),
            }),
            ("sleep", false, Question {
                kind: "tool",
                command: "import time\n# give the deploy time to roll out\ntime.sleep(300)\nprint(check_status())".into(),
                running_secs: 120,
                cwd: "/Users/me/src/app".into(),
                processes: vec![proc(11, 10, kernel, 3000, 2.5, false)],
                output: String::new(),
                said: Some("Waiting five minutes for the rollout before checking.".into()),
            }),
            ("documents", true, Question {
                kind: "tool",
                command: "import os\nprint(os.listdir('/Users/me/Documents'))".into(),
                running_secs: 300,
                cwd: "/Users/me/dev".into(),
                processes: vec![proc(11, 10, kernel, 3000, 1.1, false)],
                output: String::new(),
                said: Some("Let me see what's in your Documents folder.".into()),
            }),
            ("fifo", true, Question {
                kind: "tool",
                command: "import os\np = '/tmp/fifo'\nos.path.exists(p) or os.mkfifo(p)\nprint(open(p).read())".into(),
                running_secs: 120,
                cwd: "/Users/me/tmp".into(),
                processes: vec![proc(11, 10, kernel, 300, 0.4, false)],
                output: String::new(),
                said: None,
            }),
        ];
        // Threshold 0: every answer comes back, with its probability.
        for (name, stuck, question) in cases {
            let verdict = ask(&judge, &question).await.unwrap().unwrap();
            println!("{name}: {:.2} {}", verdict.probability, verdict.reason);
            assert_eq!(verdict.probability >= DEFAULT_THRESHOLD, stuck, "{name}");
        }
    }
}
