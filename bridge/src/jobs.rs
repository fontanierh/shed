//! Background commands: shell jobs an agent started that keep running after its turn and wake it with a
//! `[bash-done]` notice when they finish. Listed, tailed and cancelled the way each agent's own TUI does it.
//!
//! - Prime: the daemon's kernel bash activity (`bash()` from the REPL) and persistent shells.
//! - Pi: the `background-jobs` extension, which keeps a JSON record and a log per job in a folder the bridge
//!   chooses for each session (`AGENT_REMOTE_JOBS_DIR`).
//! - DeepSeek: dsh's own job registry, through Shed's dsh plugin.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

use anyhow::{anyhow, bail, Result};
use serde_json::{json, Value};

use crate::agent::JobsFrom;
use crate::ask::Ask;
use crate::protocol::{BackgroundJob, JobStatus, WaitingOn};
use crate::session::{parse_iso_ms, App, Backend, Session};

/// Where a Pi session's background-jobs extension keeps its jobs.
pub fn pi_dir(store: &crate::store::Store, session_id: &str) -> PathBuf {
    store.dir().join("jobs").join(session_id)
}

/// Prime prefixes persistent shell ids so one list can hold both kinds.
const SHELL: &str = "shell:";
/// A command running under the session's REPL kernel that Prime no longer lists (its list keeps recent activity only).
const PROCESS: &str = "process:";

/// `ps -axo pid=,ppid=,etime=,time=,command=`, by parent.
pub struct ProcessTree {
    children: HashMap<u32, Vec<(u32, String)>>,
    parents: HashMap<u32, u32>,
    /// Seconds each process has been running.
    elapsed: HashMap<u32, u64>,
    /// CPU seconds each process has used.
    cpu: HashMap<u32, f64>,
}

/// How long a command sits idle on a protected folder before it counts as waiting for macOS's permission prompt.
const PROMPT_AFTER_SECS: u64 = 30;

impl ProcessTree {
    pub fn parse(ps: &str) -> Self {
        let mut children: HashMap<u32, Vec<(u32, String)>> = HashMap::new();
        let mut parents = HashMap::new();
        let mut elapsed = HashMap::new();
        let mut cpu = HashMap::new();
        for line in ps.lines() {
            let (pid, rest) = field(line);
            let (ppid, rest) = field(rest);
            let (etime, rest) = field(rest);
            let (time, command) = field(rest);
            let (Ok(pid), Ok(ppid)) = (pid.parse(), ppid.parse()) else {
                continue;
            };
            if let Some(seconds) = parse_etime(etime) {
                elapsed.insert(pid, seconds);
            }
            if let Some(seconds) = parse_cpu_time(time) {
                cpu.insert(pid, seconds);
            }
            if pid != ppid {
                parents.insert(pid, ppid);
                children
                    .entry(ppid)
                    .or_default()
                    .push((pid, command.trim().to_string()));
            }
        }
        Self {
            children,
            parents,
            elapsed,
            cpu,
        }
    }

    pub async fn snapshot() -> Option<Self> {
        let mut ps = tokio::process::Command::new("/bin/ps");
        ps.args(["-axo", "pid=,ppid=,etime=,time=,command="])
            .kill_on_drop(true);
        let out = tokio::time::timeout(std::time::Duration::from_secs(10), ps.output())
            .await
            .ok()?
            .ok()?;
        Some(Self::parse(&String::from_utf8_lossy(&out.stdout)))
    }

    /// The commands a Prime worker's REPL kernel is running: each runs in a `bash -c` wrapper under the kernel. A
    /// wrapper with nothing under it is left over from a command that already ended, and is not counted.
    pub fn kernel_jobs(&self, worker: u32) -> Vec<(u32, String)> {
        let none = Vec::new();
        let kernels = self
            .children
            .get(&worker)
            .unwrap_or(&none)
            .iter()
            .filter(|(_, cmd)| cmd.contains("rlm.repl"));
        kernels
            .flat_map(|(kernel, _)| self.children.get(kernel).unwrap_or(&none))
            .filter(|(pid, _)| self.children.get(pid).is_some_and(|c| !c.is_empty()))
            .map(|(pid, cmd)| (*pid, wrapped_command(cmd)))
            .collect()
    }

    /// The command under a Prime worker's REPL kernel the session is waiting on: one stuck on a permission prompt,
    /// or else the longest-running.
    pub fn kernel_waiting_on(&self, worker: u32, now_ms: u64, home: &str) -> Option<WaitingOn> {
        let (pid, command) = self
            .kernel_jobs(worker)
            .into_iter()
            .max_by_key(|(pid, _)| {
                (
                    self.permission_prompt(*pid, home).is_some(),
                    self.elapsed.get(pid).copied(),
                )
            })?;
        let started_at = self
            .elapsed
            .get(&pid)
            .map(|seconds| now_ms.saturating_sub(seconds * 1000));
        Some(WaitingOn {
            command,
            started_at,
            pid: Some(pid),
        })
    }

    /// The protected folder a command is most likely waiting for macOS's permission to read: macOS holds the first
    /// read of Documents, Desktop, Downloads or iCloud Drive until someone answers its prompt on that Mac. Seen from
    /// outside as a process with nothing under it that names the folder, has been running a while and used no CPU.
    pub fn permission_prompt(&self, root: u32, home: &str) -> Option<&'static str> {
        let own = self
            .children
            .values()
            .flatten()
            .find(|(pid, _)| *pid == root)
            .map(|(_, command)| command.as_str());
        let mut stack = vec![(root, own)];
        while let Some((pid, command)) = stack.pop() {
            let kids = self.children.get(&pid).map_or(&[][..], Vec::as_slice);
            if kids.is_empty() {
                let idle = self
                    .elapsed
                    .get(&pid)
                    .is_some_and(|s| *s >= PROMPT_AFTER_SECS)
                    && self.cpu.get(&pid).is_some_and(|s| *s < 0.2);
                if let (true, Some(folder)) =
                    (idle, command.and_then(|c| protected_folder(c, home)))
                {
                    return Some(folder);
                }
            }
            stack.extend(
                kids.iter()
                    .map(|(pid, command)| (*pid, Some(command.as_str()))),
            );
        }
        None
    }
}

/// What the reader is told about a command waiting on macOS's permission prompt.
pub fn permission_reason(folder: &str) -> String {
    format!("macOS is probably asking for permission to read {folder}, and holds the command until someone answers on this Mac")
}

impl ProcessTree {
    /// A Prime worker's REPL kernel, which runs the agent's Python.
    pub fn kernel_of(&self, worker: u32) -> Option<u32> {
        self.children
            .get(&worker)?
            .iter()
            .find(|(_, cmd)| cmd.contains("rlm.repl"))
            .map(|(pid, _)| *pid)
    }

    pub fn parent(&self, pid: u32) -> Option<u32> {
        self.parents.get(&pid).copied()
    }

    /// Seconds a process has been running.
    pub fn elapsed(&self, pid: u32) -> Option<u64> {
        self.elapsed.get(&pid).copied()
    }

    /// A process and everything under it, with each one's command.
    pub fn subtree(&self, root: u32) -> Vec<(u32, &str)> {
        let mut out = Vec::new();
        let mut seen = HashSet::from([root]);
        let mut stack = vec![root];
        while let Some(pid) = stack.pop() {
            for (child, command) in self.children.get(&pid).into_iter().flatten() {
                if seen.insert(*child) {
                    out.push((*child, command.as_str()));
                    stack.push(*child);
                }
            }
        }
        out
    }

    /// CPU seconds a process and everything under it have used.
    pub fn subtree_cpu(&self, root: u32) -> f64 {
        let own = self.cpu.get(&root).copied().unwrap_or(0.0);
        own + self
            .subtree(root)
            .iter()
            .map(|(pid, _)| self.cpu.get(pid).copied().unwrap_or(0.0))
            .sum::<f64>()
    }

    pub fn has_children(&self, pid: u32) -> bool {
        self.children.get(&pid).is_some_and(|c| !c.is_empty())
    }

    /// For the stall check: `root` and each process under it, with its parent, running time and CPU time.
    pub fn processes(&self, root: u32) -> Vec<Value> {
        let parent: HashMap<u32, u32> = self
            .children
            .iter()
            .flat_map(|(ppid, kids)| kids.iter().map(move |(pid, _)| (*pid, *ppid)))
            .collect();
        let own = self
            .children
            .values()
            .flatten()
            .find(|(pid, _)| *pid == root)
            .map(|(_, command)| command.as_str())
            .unwrap_or_default();
        std::iter::once((root, own))
            .chain(self.subtree(root))
            .take(25)
            .map(|(pid, command)| {
                json!({
                    "pid": pid,
                    "parentPid": parent.get(&pid),
                    "command": command.replace("\\012", "\n").chars().take(600).collect::<String>(),
                    "runningSeconds": self.elapsed.get(&pid),
                    "cpuSeconds": self.cpu.get(&pid),
                    "hasChildren": self.has_children(pid),
                })
            })
            .collect()
    }
}

/// The folder macOS asks permission for that a command names, as the prompt calls it.
pub fn protected_folder(command: &str, home: &str) -> Option<&'static str> {
    const FOLDERS: [(&str, &str); 4] = [
        ("Documents", "Documents"),
        ("Desktop", "Desktop"),
        ("Downloads", "Downloads"),
        ("Library/Mobile Documents", "iCloud Drive"),
    ];
    let mut homes = vec!["~/".to_string(), "$HOME/".to_string()];
    if !home.is_empty() {
        homes.push(format!("{home}/"));
    }
    FOLDERS.iter().find_map(|(folder, name)| {
        homes
            .iter()
            .any(|h| {
                let path = format!("{h}{folder}");
                command.match_indices(&path).any(|(at, _)| {
                    let after = command[at + path.len()..].chars().next();
                    after.is_none_or(|c| !c.is_alphanumeric() && c != '_' && c != '-')
                })
            })
            .then_some(*name)
    })
}

/// The first whitespace-separated field of a line, and the rest of it.
fn field(line: &str) -> (&str, &str) {
    let line = line.trim_start();
    line.split_once(char::is_whitespace)
        .map_or((line, ""), |(first, rest)| (first, rest.trim_start()))
}

/// `ps`'s elapsed time, `[[dd-]hh:]mm:ss`, in seconds.
fn parse_etime(etime: &str) -> Option<u64> {
    let (days, clock) = match etime.split_once('-') {
        Some((days, clock)) => (days.parse::<u64>().ok()?, clock),
        None => (0, etime),
    };
    let seconds = clock.split(':').try_fold(0u64, |total, part| {
        Some(total * 60 + part.parse::<u64>().ok()?)
    })?;
    Some(days * 86_400 + seconds)
}

/// `ps`'s CPU time, `[[hh:]mm:]ss.cc`, in seconds.
fn parse_cpu_time(time: &str) -> Option<f64> {
    time.split(':').try_fold(0f64, |total, part| {
        Some(total * 60.0 + part.parse::<f64>().ok()?)
    })
}

/// The command inside Prime's wrapper: `exec 9>&0 …`, `read -r _prime_agent_gate …`, `{`, the command, `}`.
fn wrapped_command(wrapper: &str) -> String {
    let script = wrapper
        .strip_prefix("/bin/bash -c ")
        .unwrap_or(wrapper)
        .replace("\\012", "\n");
    let lines: Vec<&str> = script.lines().collect();
    match lines.iter().position(|l| l.trim() == "{") {
        Some(open) => {
            let body = &lines[open + 1..];
            let end = body
                .iter()
                .rposition(|l| l.trim().starts_with('}'))
                .unwrap_or(body.len());
            body[..end].join("\n").trim().to_string()
        }
        None => script.trim().to_string(),
    }
}

impl App {
    /// Where the session's background commands are found. A subagent has none of its own.
    fn jobs_from(&self, session: &Session) -> Option<JobsFrom> {
        match session.backend {
            Backend::Started | Backend::Prime => Some(self.agent(session.agent).jobs()),
            Backend::Subagent => None,
        }
    }

    /// Newest first.
    pub async fn list_jobs(&self, session: &Session) -> Result<Vec<BackgroundJob>> {
        let mut jobs = match self.jobs_from(session) {
            Some(JobsFrom::Agent) => {
                let data = self.command(session, Ask::Jobs).await?;
                data["jobs"]
                    .as_array()
                    .map(|jobs| jobs.iter().map(dsh_job).collect())
                    .unwrap_or_default()
            }
            Some(JobsFrom::Kernel) => {
                let bash = self.command(session, Ask::KernelBash).await?;
                let mut jobs: Vec<BackgroundJob> =
                    activities(&bash).filter_map(|a| prime_job(a, "")).collect();
                // Older daemons have no persistent shells; they still list kernel bash.
                if let Ok(shells) = self.command(session, Ask::PersistentShells).await {
                    jobs.extend(activities(&shells).filter_map(|a| prime_job(a, SHELL)));
                }
                // The count comes from the processes, so list every running one, listed by Prime or not.
                let worker = session.state.lock().await.worker_pid();
                let tree = ProcessTree::snapshot().await;
                if let (Some(worker), Some(tree)) = (worker, &tree) {
                    let known: HashSet<u32> = jobs.iter().filter_map(|job| job.pid).collect();
                    for (pid, command) in tree
                        .kernel_jobs(worker)
                        .into_iter()
                        .filter(|(pid, _)| !known.contains(pid))
                    {
                        jobs.push(BackgroundJob {
                            id: format!("{PROCESS}{pid}"),
                            command,
                            pid: Some(pid),
                            started_at: None,
                            duration_ms: None,
                            status: JobStatus::Running,
                            exit_code: None,
                            persistent: false,
                            stuck: None,
                        });
                    }
                }
                mark_permission_prompts(&mut jobs, tree.as_ref());
                jobs
            }
            Some(JobsFrom::Files) => {
                let mut jobs = pi_jobs(&self.store, &session.id);
                mark_permission_prompts(&mut jobs, ProcessTree::snapshot().await.as_ref());
                jobs
            }
            None => Vec::new(),
        };
        jobs.sort_by_key(|job| std::cmp::Reverse(job.started_at));
        Ok(jobs)
    }

    /// The last `lines` lines of a job's output.
    pub async fn job_output(&self, session: &Session, job_id: &str, lines: u32) -> Result<String> {
        let lines = lines.clamp(1, 200);
        match self.jobs_from(session) {
            Some(JobsFrom::Agent) => {
                let data = self
                    .command(session, Ask::JobOutput(job_id.to_string()))
                    .await?;
                let text = data["text"].as_str().unwrap_or_default();
                let all: Vec<&str> = text.lines().collect();
                Ok(all[all.len().saturating_sub(lines as usize)..].join("\n"))
            }
            Some(JobsFrom::Kernel) if job_id.starts_with(PROCESS) => {
                Ok("Prime no longer lists this command, so its output can't be shown.".into())
            }
            Some(JobsFrom::Kernel) => {
                let data = match job_id.strip_prefix(SHELL) {
                    Some(shell) => {
                        self.command(
                            session,
                            Ask::TailPersistentShell {
                                shell: shell.to_string(),
                                lines,
                            },
                        )
                        .await?
                    }
                    None => {
                        self.command(
                            session,
                            Ask::TailKernelBash {
                                activity: job_id.to_string(),
                                lines,
                            },
                        )
                        .await?
                    }
                };
                Ok(data["tail"]
                    .as_str()
                    .or(data["output"].as_str())
                    .unwrap_or_default()
                    .to_string())
            }
            Some(JobsFrom::Files) => {
                use std::io::{Read, Seek, SeekFrom};
                let mut file = std::fs::File::open(
                    pi_dir(&self.store, &session.id).join(format!("{}.log", safe_id(job_id)?)),
                )
                .map_err(|_| anyhow!("This command is no longer available."))?;
                let len = file.metadata().map(|m| m.len()).unwrap_or(0);
                file.seek(SeekFrom::Start(len.saturating_sub(16 * 1024)))
                    .map_err(|_| anyhow!("This command is no longer available."))?;
                let mut tail_bytes = Vec::new();
                file.take(16 * 1024)
                    .read_to_end(&mut tail_bytes)
                    .map_err(|_| anyhow!("This command is no longer available."))?;
                let text = String::from_utf8_lossy(&tail_bytes).into_owned();
                let all: Vec<&str> = text.lines().collect();
                Ok(all[all.len().saturating_sub(lines as usize)..].join("\n"))
            }
            None => bail!("Subagents have no background commands"),
        }
    }

    /// Terminates a running job (its whole process group). The agent then gets its `[bash-done]` notice, as when it
    /// stops the job itself.
    pub async fn kill_job(&self, session: &Session, job_id: &str) -> Result<bool> {
        let from = self.jobs_from(session);
        let process = job_id
            .strip_prefix(PROCESS)
            .filter(|_| from != Some(JobsFrom::Agent));
        if let Some(pid) = process {
            // Only a command still running under this session's kernel, never an arbitrary pid.
            let pid: u32 = pid.parse().map_err(|_| anyhow!("invalid job id"))?;
            let worker = session
                .state
                .lock()
                .await
                .worker_pid()
                .ok_or_else(|| anyhow!("This command is no longer available."))?;
            let tree = ProcessTree::snapshot()
                .await
                .ok_or_else(|| anyhow!("could not list processes"))?;
            if !tree.kernel_jobs(worker).iter().any(|(p, _)| *p == pid) {
                return Ok(false);
            }
            // The wrapper leads its own process group: terminate the whole command, as Prime's kill does.
            let status = tokio::process::Command::new("/bin/kill")
                .args(["-TERM", "--", &format!("-{pid}")])
                .status()
                .await?;
            return Ok(status.success());
        }
        match from {
            Some(JobsFrom::Agent) => {
                self.command(session, Ask::KillJob(job_id.to_string()))
                    .await?;
                Ok(true)
            }
            Some(JobsFrom::Kernel) => {
                let data = match job_id.strip_prefix(SHELL) {
                    Some(shell) => {
                        self.command(session, Ask::KillPersistentShell(shell.to_string()))
                            .await?
                    }
                    None => {
                        self.command(session, Ask::KillKernelBash(job_id.to_string()))
                            .await?
                    }
                };
                Ok(data["killed"].as_bool().unwrap_or(true))
            }
            Some(JobsFrom::Files) => {
                let job = pi_jobs(&self.store, &session.id)
                    .into_iter()
                    .find(|job| job.id == job_id)
                    .ok_or_else(|| anyhow!("This command is no longer available."))?;
                if job.status != JobStatus::Running {
                    return Ok(false);
                }
                let pid = job.pid.ok_or_else(|| anyhow!("job has no pid"))?;
                let group = format!("-{pid}");
                let status = tokio::process::Command::new("/bin/kill")
                    .args(["-TERM", "--", &group])
                    .status()
                    .await?;
                // Like the extension's job_kill: SIGKILL after 5 seconds for commands that ignore SIGTERM, checking
                // first that the job record is still running under the same pid so a recycled pid isn't signalled.
                let store = self.store.clone();
                let session_id = session.id.clone();
                let target_id = job_id.to_string();
                let started_at = job.started_at;
                tokio::spawn(async move {
                    tokio::time::sleep(std::time::Duration::from_secs(5)).await;
                    let still_same = pi_jobs(&store, &session_id).into_iter().any(|j| {
                        j.id == target_id
                            && j.status == JobStatus::Running
                            && j.pid == Some(pid)
                            && j.started_at == started_at
                    });
                    if still_same && alive(pid) {
                        let killed = tokio::process::Command::new("/bin/kill")
                            .args(["-KILL", "--", &group])
                            .status()
                            .await;
                        if let Err(e) = killed {
                            eprintln!("job {pid} ignored the stop and could not be killed: {e}");
                        }
                    }
                });
                Ok(status.success())
            }
            None => bail!("Subagents have no background commands"),
        }
    }
}

/// One of dsh's jobs (its registry's view) as a background command.
fn dsh_job(job: &Value) -> BackgroundJob {
    let started = job["startedAt"].as_u64();
    let finished = job["finishedAt"].as_u64();
    let running = matches!(job["status"].as_str(), Some("running" | "stopping"));
    // dsh words a shell job's exit as "exit code: N".
    let exit_code = job["detail"]
        .as_str()
        .and_then(|d| d.strip_prefix("exit code: "))
        .and_then(|code| code.trim().parse().ok());
    BackgroundJob {
        id: job["id"].as_str().unwrap_or_default().to_string(),
        command: job["label"].as_str().unwrap_or_default().to_string(),
        pid: None,
        started_at: started,
        duration_ms: match (started, finished) {
            (Some(s), Some(f)) => Some(f.saturating_sub(s)),
            _ => None,
        },
        status: if running {
            JobStatus::Running
        } else {
            JobStatus::Finished
        },
        exit_code,
        persistent: false,
        stuck: None,
    }
}

/// Running jobs that look stuck on macOS's permission prompt.
fn mark_permission_prompts(jobs: &mut [BackgroundJob], tree: Option<&ProcessTree>) {
    let Some(tree) = tree else { return };
    let home = crate::host::home_text();
    for job in jobs
        .iter_mut()
        .filter(|job| job.status == JobStatus::Running)
    {
        job.stuck = job
            .pid
            .and_then(|pid| tree.permission_prompt(pid, &home))
            .map(permission_reason);
    }
}

fn activities(data: &Value) -> impl Iterator<Item = &Value> {
    data["activities"]
        .as_array()
        .or(data["shells"].as_array())
        .into_iter()
        .flatten()
}

fn prime_job(a: &Value, prefix: &str) -> Option<BackgroundJob> {
    let id = a["id"].as_str().or(a["shellId"].as_str())?;
    Some(BackgroundJob {
        id: format!("{prefix}{id}"),
        command: a["command"].as_str().unwrap_or_default().to_string(),
        pid: valid_pid(a["pid"].as_u64()),
        started_at: a["startedAt"].as_str().and_then(parse_iso_ms),
        duration_ms: a["durationMs"].as_u64(),
        status: JobStatus::read(a["status"].as_str().unwrap_or("running")),
        exit_code: a["exitCode"].as_i64(),
        persistent: !prefix.is_empty() || a["persistent"].as_bool().unwrap_or(false),
        stuck: None,
    })
}

/// A Pi job whose process is gone without a recorded exit (Pi was killed) is reported as lost.
fn pi_jobs(store: &crate::store::Store, session_id: &str) -> Vec<BackgroundJob> {
    let Ok(entries) = std::fs::read_dir(pi_dir(store, session_id)) else {
        return Vec::new();
    };
    entries
        .flatten()
        .map(|e| e.path())
        .filter(|path| path.extension().is_some_and(|x| x == "json"))
        .filter_map(|path| {
            Some((
                serde_json::from_slice::<Value>(&std::fs::read(&path).ok()?).ok()?,
                path,
            ))
        })
        .filter_map(|(j, path)| {
            let pid = valid_pid(j["pid"].as_u64());
            let mut status = JobStatus::read(j["status"].as_str().unwrap_or("finished"));
            // Only Pi rewrites the record, so a job it left behind says "running" for good. Once seen gone, that is
            // noted beside it: the pid can be given to another process later, and that one isn't this job.
            let lost = path.with_extension("lost");
            if status == JobStatus::Running && (lost.exists() || !pid.is_some_and(alive)) {
                status = JobStatus::Lost;
                if !lost.exists() {
                    if let Err(e) = std::fs::write(&lost, b"") {
                        eprintln!("can't note a lost job in {}: {e}", lost.display());
                    }
                }
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
                stuck: None,
            })
        })
        .collect()
}

/// A deleted session's job records and logs go with it.
pub fn forget(store: &crate::store::Store, session_id: &str) {
    let dir = pi_dir(store, session_id);
    match std::fs::remove_dir_all(&dir) {
        Ok(()) => {}
        // A session that never ran a job has no folder.
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => eprintln!("can't remove the job records in {}: {e}", dir.display()),
    }
}

/// The running Pi jobs of a session, for the summary: how many, and the one stuck on a permission prompt or else
/// the longest-running.
pub fn pi_running(
    store: &crate::store::Store,
    session_id: &str,
    tree: Option<&ProcessTree>,
) -> (u32, Option<WaitingOn>) {
    let running: Vec<BackgroundJob> = pi_jobs(store, session_id)
        .into_iter()
        .filter(|job| job.status == JobStatus::Running)
        .collect();
    let home = crate::host::home_text();
    let prompt = |job: &BackgroundJob| {
        tree.zip(job.pid)
            .and_then(|(tree, pid)| tree.permission_prompt(pid, &home))
    };
    let waiting = running
        .iter()
        .map(|job| (job, prompt(job)))
        .min_by_key(|(job, prompt)| (prompt.is_none(), job.started_at.unwrap_or(u64::MAX)))
        .map(|(job, _)| WaitingOn {
            command: job.command.clone(),
            started_at: job.started_at,
            pid: job.pid,
        });
    (running.len() as u32, waiting)
}

fn valid_pid(raw: Option<u64>) -> Option<u32> {
    let pid = u32::try_from(raw?).ok()?;
    (pid > 1 && pid != std::process::id()).then_some(pid)
}

fn alive(pid: u32) -> bool {
    if pid <= 1 || pid == std::process::id() {
        return false;
    }
    std::process::Command::new("/bin/kill")
        .args(["-0", &pid.to_string()])
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
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
        let ps = "  10     1 1-02:03:04 0:01.00 prime-agent worker\n  11    10 05:00 0:00.50 python -m rlm.repl\n  20    11 01:40 0:00.00 /bin/bash -c exec 9>&0 8>&1 0</dev/null\\012read -r _prime_agent_gate <&9 || exit 127\\012{\\012sleep 50; echo hi\\012}\\012\n  21    20 01:40 0:00.00 sleep 50\n  30    11 00:03 0:00.00 /bin/bash -c exec 9>&0\\012{\\012python -m http.server 1\\012}\n";
        let tree = ProcessTree::parse(ps);
        assert_eq!(
            tree.kernel_jobs(10),
            vec![(20, "sleep 50; echo hi".to_string())]
        );
        assert!(tree.kernel_jobs(11).is_empty());
        let waiting = tree.kernel_waiting_on(10, 1_000_000, "/Users/me").unwrap();
        assert_eq!(
            (waiting.command.as_str(), waiting.started_at),
            ("sleep 50; echo hi", Some(900_000))
        );
    }

    #[test]
    fn tells_a_command_stuck_on_a_permission_prompt() {
        let ps = "  10     1 20:00 0:01.00 prime-agent worker\n  11    10 20:00 0:00.50 python -m rlm.repl\n  20    11 17:44 0:00.00 /bin/bash -c exec 9>&0\\012{\\012ls /Users/me/Documents; ls ~/Downloads\\012}\n  21    20 17:44 0:00.00 ls /Users/me/Documents\n  30    11 20:00 0:00.00 /bin/bash -c exec 9>&0\\012{\\012sleep 5000\\012}\n  31    30 20:00 0:00.00 sleep 5000\n";
        let tree = ProcessTree::parse(ps);
        assert_eq!(tree.permission_prompt(20, "/Users/me"), Some("Documents"));
        assert_eq!(tree.permission_prompt(30, "/Users/me"), None);
        // Stuck beats longest-running.
        let waiting = tree.kernel_waiting_on(10, 2_000_000, "/Users/me").unwrap();
        assert_eq!(waiting.pid, Some(20));
        // Not yet idle long enough, or busy reading.
        let young = ProcessTree::parse(&ps.replace("17:44 0:00.00 ls", "00:10 0:00.00 ls"));
        assert_eq!(young.permission_prompt(20, "/Users/me"), None);
        let busy = ProcessTree::parse(&ps.replace("17:44 0:00.00 ls", "17:44 0:03.20 ls"));
        assert_eq!(busy.permission_prompt(20, "/Users/me"), None);
    }

    #[test]
    fn names_only_the_protected_folders_in_the_home() {
        let home = "/Users/me";
        assert_eq!(
            protected_folder("ls /Users/me/Documents", home),
            Some("Documents")
        );
        assert_eq!(
            protected_folder("cat ~/Desktop/notes.txt", home),
            Some("Desktop")
        );
        assert_eq!(
            protected_folder("du -sh \"$HOME/Downloads\"", home),
            Some("Downloads")
        );
        assert_eq!(
            protected_folder(
                "ls '/Users/me/Library/Mobile Documents/com~apple~CloudDocs'",
                home
            ),
            Some("iCloud Drive")
        );
        assert_eq!(
            protected_folder("ls /Users/me/DocumentsArchive", home),
            None
        );
        assert_eq!(protected_folder("ls /srv/Documents", home), None);
        assert_eq!(protected_folder("ls /Users/me/src", home), None);
    }

    #[test]
    fn parses_cpu_times() {
        assert_eq!(parse_cpu_time("0:00.00"), Some(0.0));
        assert_eq!(parse_cpu_time("1:55.68"), Some(115.68));
        assert_eq!(parse_cpu_time("1:00:01.50"), Some(3601.5));
    }

    #[test]
    fn parses_elapsed_times() {
        assert_eq!(parse_etime("00:07"), Some(7));
        assert_eq!(parse_etime("10:13"), Some(613));
        assert_eq!(parse_etime("02:00:01"), Some(7201));
        assert_eq!(parse_etime("1-00:00:00"), Some(86_400));
    }

    #[test]
    fn rejects_dangerous_pids_and_handles_self_parented_processes() {
        assert_eq!(valid_pid(Some(0)), None);
        assert_eq!(valid_pid(Some(1)), None);
        assert_eq!(valid_pid(Some(u64::from(std::process::id()))), None);
        assert_eq!(valid_pid(Some(u64::from(u32::MAX) + 1)), None);
        assert!(!alive(0));
        assert!(!alive(1));

        let ps = "   0     0 10:00 0:00.00 kernel_task\n  10     0 05:00 0:01.00 launchd\n";
        let tree = ProcessTree::parse(ps);
        assert_eq!(tree.subtree(0), vec![(10, "launchd")]);
    }
}
