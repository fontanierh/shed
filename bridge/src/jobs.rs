//! Background commands: shell jobs an agent started that keep running after its turn and wake it with a
//! `[bash-done]` notice when they finish. Listed, tailed and cancelled the way each agent's own TUI does it.
//!
//! - Prime: the daemon's kernel bash activity (`bash()` from the REPL) and persistent shells.
//! - Pi: the `background-jobs` extension, which keeps a JSON record and a log per job in a folder the bridge
//!   chooses for each session (`AGENT_REMOTE_JOBS_DIR`).

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

use anyhow::{anyhow, bail, Result};
use serde_json::{json, Value};

use crate::protocol::BackgroundJob;
use crate::session::{parse_iso_ms, App, Backend, Session};

/// Where a Pi session's background-jobs extension keeps its jobs.
pub fn pi_dir(session_id: &str) -> PathBuf {
    PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".agent-remote/jobs").join(session_id)
}

/// Prime prefixes persistent shell ids so one list can hold both kinds.
const SHELL: &str = "shell:";
/// A command running under the session's REPL kernel that Prime no longer lists (its list keeps recent activity only).
const PROCESS: &str = "process:";

/// `ps -axo pid=,ppid=,command=`, by parent.
pub struct ProcessTree {
    children: HashMap<u32, Vec<(u32, String)>>,
}

impl ProcessTree {
    pub fn parse(ps: &str) -> Self {
        let mut children: HashMap<u32, Vec<(u32, String)>> = HashMap::new();
        for line in ps.lines() {
            let line = line.trim_start();
            let Some((pid, rest)) = line.split_once(char::is_whitespace) else { continue };
            let rest = rest.trim_start();
            let (ppid, command) = rest.split_once(char::is_whitespace).unwrap_or((rest, ""));
            let (Ok(pid), Ok(ppid)) = (pid.parse(), ppid.parse()) else { continue };
            children.entry(ppid).or_default().push((pid, command.trim().to_string()));
        }
        Self { children }
    }

    pub async fn snapshot() -> Option<Self> {
        let out = tokio::process::Command::new("/bin/ps").args(["-axo", "pid=,ppid=,command="]).output().await.ok()?;
        Some(Self::parse(&String::from_utf8_lossy(&out.stdout)))
    }

    /// The commands a Prime worker's REPL kernel is running: each runs in a `bash -c` wrapper under the kernel. A
    /// wrapper with nothing under it is left over from a command that already ended, and is not counted.
    pub fn kernel_jobs(&self, worker: u32) -> Vec<(u32, String)> {
        let none = Vec::new();
        let kernels = self.children.get(&worker).unwrap_or(&none).iter().filter(|(_, cmd)| cmd.contains("rlm.repl"));
        kernels
            .flat_map(|(kernel, _)| self.children.get(kernel).unwrap_or(&none))
            .filter(|(pid, _)| self.children.get(pid).is_some_and(|c| !c.is_empty()))
            .map(|(pid, cmd)| (*pid, wrapped_command(cmd)))
            .collect()
    }
}

/// The command inside Prime's wrapper: `exec 9>&0 …`, `read -r _prime_agent_gate …`, `{`, the command, `}`.
fn wrapped_command(wrapper: &str) -> String {
    let script = wrapper.strip_prefix("/bin/bash -c ").unwrap_or(wrapper).replace("\\012", "\n");
    let lines: Vec<&str> = script.lines().collect();
    match lines.iter().position(|l| l.trim() == "{") {
        Some(open) => {
            let body = &lines[open + 1..];
            let end = body.iter().rposition(|l| l.trim().starts_with('}')).unwrap_or(body.len());
            body[..end].join("\n").trim().to_string()
        }
        None => script.trim().to_string(),
    }
}

impl App {
    /// Newest first.
    pub async fn list_jobs(&self, session: &Session) -> Result<Vec<BackgroundJob>> {
        let mut jobs = match session.backend {
            Backend::Prime => {
                let bash = self.command(session, "list_kernel_bash", json!({})).await?;
                let mut jobs: Vec<BackgroundJob> = activities(&bash).filter_map(|a| prime_job(a, "")).collect();
                // Older daemons have no persistent shells; they still list kernel bash.
                if let Ok(shells) = self.command(session, "list_persistent_shells", json!({})).await {
                    jobs.extend(activities(&shells).filter_map(|a| prime_job(a, SHELL)));
                }
                // The count comes from the processes, so list every running one, listed by Prime or not.
                let worker = session.state.lock().await.worker_pid;
                if let (Some(worker), Some(tree)) = (worker, ProcessTree::snapshot().await) {
                    let known: HashSet<u32> = jobs.iter().filter_map(|job| job.pid).collect();
                    for (pid, command) in tree.kernel_jobs(worker).into_iter().filter(|(pid, _)| !known.contains(pid)) {
                        jobs.push(BackgroundJob {
                            id: format!("{PROCESS}{pid}"),
                            command,
                            pid: Some(pid),
                            started_at: None,
                            duration_ms: None,
                            status: "running".into(),
                            exit_code: None,
                            persistent: false,
                        });
                    }
                }
                jobs
            }
            Backend::Pi => pi_jobs(&session.id),
            Backend::PiSubagent => Vec::new(),
        };
        jobs.sort_by_key(|job| std::cmp::Reverse(job.started_at));
        Ok(jobs)
    }

    /// The last `lines` lines of a job's output.
    pub async fn job_output(&self, session: &Session, job_id: &str, lines: u32) -> Result<String> {
        let lines = lines.clamp(1, 200);
        match session.backend {
            Backend::Prime if job_id.starts_with(PROCESS) => {
                Ok("Prime no longer lists this command, so its output can't be shown.".into())
            }
            Backend::Prime => {
                let data = match job_id.strip_prefix(SHELL) {
                    Some(shell) => {
                        self.command(session, "tail_persistent_shell", json!({ "shellId": shell, "lines": lines }))
                            .await?
                    }
                    None => {
                        self.command(session, "tail_kernel_bash", json!({ "activityId": job_id, "lines": lines }))
                            .await?
                    }
                };
                Ok(data["tail"].as_str().or(data["output"].as_str()).unwrap_or_default().to_string())
            }
            Backend::Pi => {
                let log = std::fs::read(pi_dir(&session.id).join(format!("{}.log", safe_id(job_id)?)))
                    .map_err(|_| anyhow!("This command is no longer available."))?;
                // At most 16 KiB, like Prime's tail.
                let text = String::from_utf8_lossy(&log[log.len().saturating_sub(16 * 1024)..]).into_owned();
                let all: Vec<&str> = text.lines().collect();
                Ok(all[all.len().saturating_sub(lines as usize)..].join("\n"))
            }
            Backend::PiSubagent => bail!("Pi subagents have no background commands"),
        }
    }

    /// Terminates a running job (its whole process group). The agent then gets its `[bash-done]` notice, as when it
    /// stops the job itself.
    pub async fn kill_job(&self, session: &Session, job_id: &str) -> Result<bool> {
        if let Some(pid) = job_id.strip_prefix(PROCESS) {
            // Only a command still running under this session's kernel, never an arbitrary pid.
            let pid: u32 = pid.parse().map_err(|_| anyhow!("invalid job id"))?;
            let worker = session.state.lock().await.worker_pid.ok_or_else(|| anyhow!("This command is no longer available."))?;
            let tree = ProcessTree::snapshot().await.ok_or_else(|| anyhow!("could not list processes"))?;
            if !tree.kernel_jobs(worker).iter().any(|(p, _)| *p == pid) {
                return Ok(false);
            }
            // The wrapper leads its own process group: terminate the whole command, as Prime's kill does.
            let status = tokio::process::Command::new("/bin/kill").args(["-TERM", "--", &format!("-{pid}")]).status().await?;
            return Ok(status.success());
        }
        match session.backend {
            Backend::Prime => {
                let data = match job_id.strip_prefix(SHELL) {
                    Some(shell) => {
                        self.command(session, "kill_persistent_shell", json!({ "shellId": shell })).await?
                    }
                    None => self.command(session, "kill_kernel_bash", json!({ "activityId": job_id })).await?,
                };
                Ok(data["killed"].as_bool().unwrap_or(true))
            }
            Backend::Pi => {
                let job = pi_jobs(&session.id)
                    .into_iter()
                    .find(|job| job.id == job_id)
                    .ok_or_else(|| anyhow!("This command is no longer available."))?;
                if job.status != "running" {
                    return Ok(false);
                }
                let pid = job.pid.ok_or_else(|| anyhow!("job has no pid"))?;
                let group = format!("-{pid}");
                let status = tokio::process::Command::new("/bin/kill").args(["-TERM", "--", &group]).status().await?;
                // Like the extension's job_kill: SIGKILL after 5 seconds for commands that ignore SIGTERM.
                tokio::spawn(async move {
                    tokio::time::sleep(std::time::Duration::from_secs(5)).await;
                    if alive(pid) {
                        let _ = tokio::process::Command::new("/bin/kill").args(["-KILL", "--", &group]).status().await;
                    }
                });
                Ok(status.success())
            }
            Backend::PiSubagent => bail!("Pi subagents have no background commands"),
        }
    }
}

fn activities(data: &Value) -> impl Iterator<Item = &Value> {
    data["activities"].as_array().or(data["shells"].as_array()).into_iter().flatten()
}

fn prime_job(a: &Value, prefix: &str) -> Option<BackgroundJob> {
    let id = a["id"].as_str().or(a["shellId"].as_str())?;
    Some(BackgroundJob {
        id: format!("{prefix}{id}"),
        command: a["command"].as_str().unwrap_or_default().to_string(),
        pid: a["pid"].as_u64().map(|p| p as u32),
        started_at: a["startedAt"].as_str().and_then(parse_iso_ms),
        duration_ms: a["durationMs"].as_u64(),
        status: a["status"].as_str().unwrap_or("running").to_string(),
        exit_code: a["exitCode"].as_i64(),
        persistent: !prefix.is_empty() || a["persistent"].as_bool().unwrap_or(false),
    })
}

/// A Pi job whose process is gone without a recorded exit (Pi was killed) is reported as lost.
fn pi_jobs(session_id: &str) -> Vec<BackgroundJob> {
    let Ok(entries) = std::fs::read_dir(pi_dir(session_id)) else { return Vec::new() };
    entries
        .flatten()
        .filter(|e| e.path().extension().is_some_and(|x| x == "json"))
        .filter_map(|e| serde_json::from_slice::<Value>(&std::fs::read(e.path()).ok()?).ok())
        .filter_map(|j| {
            let pid = j["pid"].as_u64().map(|p| p as u32);
            let mut status = j["status"].as_str().unwrap_or("finished").to_string();
            if status == "running" && !pid.is_some_and(alive) {
                status = "lost".into();
            }
            let started_at = j["startedAt"].as_str().and_then(parse_iso_ms);
            Some(BackgroundJob {
                id: j["id"].as_str()?.to_string(),
                command: j["command"].as_str().unwrap_or_default().to_string(),
                pid,
                started_at,
                duration_ms: j["durationMs"].as_u64(),
                status,
                exit_code: j["exitCode"].as_i64(),
                persistent: false,
            })
        })
        .collect()
}

/// The running Pi jobs of a session, for the summary's count.
pub fn pi_running(session_id: &str) -> u32 {
    pi_jobs(session_id).iter().filter(|job| job.status == "running").count() as u32
}

fn alive(pid: u32) -> bool {
    std::process::Command::new("/bin/kill").args(["-0", &pid.to_string()]).status().is_ok_and(|s| s.success())
}

/// Job ids name files; keep them to the extension's alphabet.
fn safe_id(id: &str) -> Result<&str> {
    if id.is_empty() || !id.chars().all(|c| c.is_ascii_alphanumeric()) {
        bail!("invalid job id");
    }
    Ok(id)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn counts_only_wrappers_still_running_a_command() {
        let ps = "  10     1 prime-agent worker\n  11    10 python -m rlm.repl\n  20    11 /bin/bash -c exec 9>&0 8>&1 0</dev/null\\012read -r _prime_agent_gate <&9 || exit 127\\012{\\012sleep 50; echo hi\\012}\\012\n  21    20 sleep 50\n  30    11 /bin/bash -c exec 9>&0\\012{\\012python -m http.server 1\\012}\n";
        let tree = ProcessTree::parse(ps);
        assert_eq!(tree.kernel_jobs(10), vec![(20, "sleep 50; echo hi".to_string())]);
        assert!(tree.kernel_jobs(11).is_empty());
    }
}
