//! What the repositories the sessions work in look like, read with the machine's own `git`: each one's branch, how
//! far it is from its upstream and what is uncommitted, the commits of the last months, and a day-by-day count of
//! the commits made by the user, for the apps' home page.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::Path;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use anyhow::Result;
use serde::Serialize;
use serde_json::{json, Value};

/// Repositories read per request: a bridge that has seen hundreds of folders still answers quickly.
const MAX_REPOS: usize = 24;
/// Recent commits sent, across every repository.
const MAX_COMMITS: usize = 40;
/// A git command that takes longer than this is given up on: a repository on a sleeping network drive mustn't hold
/// the home page.
const GIT_TIMEOUT: Duration = Duration::from_secs(6);
/// The same request inside this window is answered from the last result: the apps ask on every visit to the home page.
const CACHE_FOR: Duration = Duration::from_secs(45);

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Commit {
    pub hash: String,
    pub short: String,
    pub author: String,
    /// Made by the user: their email in the repository's `user.email`.
    pub mine: bool,
    /// Epoch ms.
    pub time: u64,
    /// The day it was made on, in this machine's time zone (`2026-11-07`).
    pub day: String,
    pub subject: String,
    pub added: u32,
    pub deleted: u32,
    pub repo: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Repo {
    pub path: String,
    pub name: String,
    /// None when detached.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub branch: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub upstream: Option<String>,
    pub ahead: u32,
    pub behind: u32,
    /// Files changed, staged or not, and untracked ones.
    pub changed: u32,
    /// Its newest commit, epoch ms.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_commit_at: Option<u64>,
}

static CACHE: Mutex<Option<(Instant, String, Value)>> = Mutex::new(None);
/// Lines added and deleted per commit hash. A commit never changes, so what was counted once stays right; counting
/// is slow on repositories with large commits, so it happens in the background and fills in on a later request.
static LINES: Mutex<Option<HashMap<String, (u32, u32)>>> = Mutex::new(None);
/// Repositories whose lines are being counted.
static COUNTING: Mutex<Option<HashSet<String>>> = Mutex::new(None);
/// Counting a repository's lines gets longer than reading it: it runs in the background.
const COUNT_TIMEOUT: Duration = Duration::from_secs(90);

/// The repositories that hold `folders` and their activity over the last `days` days.
pub async fn overview(folders: Vec<String>, days: u32) -> Result<Value> {
    let days = days.clamp(7, 400);
    let mut roots: Vec<String> = Vec::new();
    let mut seen = HashSet::new();
    let mut tops = Vec::new();
    for folder in folders {
        if seen.insert(folder.clone()) && Path::new(&folder).is_dir() {
            tops.push(tokio::spawn(async move {
                match toplevel(&folder).await {
                    Some(root) => vec![root],
                    // A folder of projects (~/dev): the repositories right inside it.
                    None => children_repos(&folder),
                }
            }));
        }
    }
    for top in tops {
        if let Ok(found) = top.await {
            for root in found {
                if !roots.contains(&root) {
                    roots.push(root);
                }
            }
        }
    }
    roots.sort();
    let key = format!("{days}:{}", roots.join("\n"));
    if let Some((at, cached, value)) = CACHE.lock().unwrap().as_ref() {
        if *cached == key && at.elapsed() < CACHE_FOR {
            return Ok(value.clone());
        }
    }

    // The most recently touched first, when there are more than we read.
    let mut dated: Vec<(u64, String)> = Vec::new();
    for root in roots {
        dated.push((modified(&root), root));
    }
    dated.sort_by(|a, b| b.0.cmp(&a.0));
    dated.truncate(MAX_REPOS);

    let tasks: Vec<_> = dated
        .into_iter()
        .map(|(_, root)| tokio::spawn(async move { read_repo(root, days).await }))
        .collect();
    let mut repos = Vec::new();
    let mut commits: Vec<Commit> = Vec::new();
    let mut hashes = HashSet::new();
    for task in tasks {
        let Ok(Some((repo, repo_commits))) = task.await else {
            continue;
        };
        // Worktrees of one repository share their commits: count each once.
        commits.extend(
            repo_commits
                .into_iter()
                .filter(|c| hashes.insert(c.hash.clone())),
        );
        repos.push(repo);
    }
    repos.sort_by(|a, b| b.last_commit_at.cmp(&a.last_commit_at));
    commits.sort_by(|a, b| b.time.cmp(&a.time));

    let mut activity: BTreeMap<String, u32> = BTreeMap::new();
    let (mut mine, mut added, mut deleted) = (0u32, 0u64, 0u64);
    let mut pending = false;
    {
        let lines = LINES.lock().unwrap();
        for commit in commits.iter_mut() {
            match lines.as_ref().and_then(|l| l.get(&commit.hash)) {
                Some(&(a, d)) => (commit.added, commit.deleted) = (a, d),
                None => pending = true,
            }
        }
    }
    for commit in commits.iter().filter(|c| c.mine) {
        *activity.entry(commit.day.clone()).or_default() += 1;
        mine += 1;
        added += commit.added as u64;
        deleted += commit.deleted as u64;
    }
    let activity: Vec<Value> = activity
        .into_iter()
        .map(|(day, commits)| json!({ "day": day, "commits": commits }))
        .collect();
    commits.truncate(MAX_COMMITS);
    let value = json!({
        "days": days,
        "today": today().await,
        "repos": repos,
        "commits": commits,
        "activity": activity,
        "totals": { "commits": mine, "added": added, "deleted": deleted },
        // Line counts still being worked out: asking again in a few seconds gets them.
        "linesPending": pending,
    });
    if !pending {
        *CACHE.lock().unwrap() = Some((Instant::now(), key, value.clone()));
    }
    Ok(value)
}

async fn read_repo(root: String, days: u32) -> Option<(Repo, Vec<Commit>)> {
    let name = Path::new(&root)
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| root.clone());
    let since = format!("--since={days}.days");
    let status_args = [
        "status",
        "--porcelain=v2",
        "--branch",
        "--untracked-files=normal",
    ];
    let log_args = [
        "log",
        "--branches",
        "--no-merges",
        since.as_str(),
        "--date=format-local:%Y-%m-%d",
        "--format=%x1e%H%x1f%h%x1f%an%x1f%ae%x1f%ct%x1f%ad%x1f%s",
    ];
    let (status, email, log) = tokio::join!(
        git(&root, &status_args),
        git(&root, &["config", "user.email"]),
        git(&root, &log_args),
    );
    let status = status?;
    let me = email
        .map(|e| e.trim().to_lowercase())
        .filter(|e| !e.is_empty());
    let mut repo = parse_status(&status, &root, &name);
    let commits = log
        .map(|log| parse_log(&log, me.as_deref(), &name))
        .unwrap_or_default();
    let uncounted = {
        let lines = LINES.lock().unwrap();
        commits
            .iter()
            .any(|c| !lines.as_ref().is_some_and(|l| l.contains_key(&c.hash)))
    };
    if uncounted {
        count_lines(root.clone(), since.clone());
    }
    repo.last_commit_at = commits.iter().map(|c| c.time).max();
    if repo.last_commit_at.is_none() {
        repo.last_commit_at = git(&root, &["log", "-1", "--format=%ct"])
            .await
            .and_then(|t| t.trim().parse::<u64>().ok())
            .map(|t| t * 1000);
    }
    Some((repo, commits))
}

fn parse_status(status: &str, root: &str, name: &str) -> Repo {
    let mut repo = Repo {
        path: root.to_string(),
        name: name.to_string(),
        branch: None,
        upstream: None,
        ahead: 0,
        behind: 0,
        changed: 0,
        last_commit_at: None,
    };
    for line in status.lines() {
        if let Some(head) = line.strip_prefix("# branch.head ") {
            repo.branch = (head != "(detached)").then(|| head.to_string());
        } else if let Some(upstream) = line.strip_prefix("# branch.upstream ") {
            repo.upstream = Some(upstream.to_string());
        } else if let Some(ab) = line.strip_prefix("# branch.ab ") {
            for part in ab.split_whitespace() {
                if let Some(n) = part.strip_prefix('+') {
                    repo.ahead = n.parse().unwrap_or(0);
                } else if let Some(n) = part.strip_prefix('-') {
                    repo.behind = n.parse().unwrap_or(0);
                }
            }
        } else if !line.starts_with('#') && !line.is_empty() {
            repo.changed += 1;
        }
    }
    repo
}

/// `git log` records: a header line after \x1e, with any `--shortstat` line after it.
fn parse_log(log: &str, me: Option<&str>, repo: &str) -> Vec<Commit> {
    let mut commits = Vec::new();
    for record in log.split('\x1e').filter(|r| !r.trim().is_empty()) {
        let mut lines = record.lines();
        let Some(header) = lines.next() else { continue };
        let fields: Vec<&str> = header.split('\x1f').collect();
        if fields.len() < 7 {
            continue;
        }
        let (added, deleted) = stat(lines);
        commits.push(Commit {
            hash: fields[0].to_string(),
            short: fields[1].to_string(),
            author: fields[2].to_string(),
            mine: me.is_some_and(|me| fields[3].trim().eq_ignore_ascii_case(me)),
            time: fields[4].parse::<u64>().unwrap_or(0) * 1000,
            day: fields[5].to_string(),
            // The subject is last, so a stray separator in it stays part of it.
            subject: fields[6..].join("\u{1f}"),
            added,
            deleted,
            repo: repo.to_string(),
        });
    }
    commits
}

/// Counts the lines of a repository's commits since `since` in the background, once at a time per repository.
fn count_lines(root: String, since: String) {
    if !COUNTING
        .lock()
        .unwrap()
        .get_or_insert_with(HashSet::new)
        .insert(root.clone())
    {
        return;
    }
    tokio::spawn(async move {
        let args = [
            "log",
            "--branches",
            "--no-merges",
            "--no-renames",
            since.as_str(),
            "--format=%x1e%H",
            "--shortstat",
        ];
        if let Some(log) = git_with(&root, &args, COUNT_TIMEOUT).await {
            let counted = parse_lines(&log);
            let mut lines = LINES.lock().unwrap();
            let lines = lines.get_or_insert_with(HashMap::new);
            lines.extend(counted);
        }
        if let Some(counting) = COUNTING.lock().unwrap().as_mut() {
            counting.remove(&root);
        }
    });
}

/// `--format=%x1e%H --shortstat` records: hash, then the stat line. Commits that change no text count as 0/0.
fn parse_lines(log: &str) -> Vec<(String, (u32, u32))> {
    log.split('\x1e')
        .filter_map(|record| {
            let mut lines = record.lines();
            let hash = lines.next()?.trim().to_string();
            if hash.is_empty() {
                return None;
            }
            Some((hash, stat(lines)))
        })
        .collect()
}

/// Lines added and deleted, from a `--shortstat` line (` 2 files changed, 10 insertions(+), 3 deletions(-)`).
fn stat<'a>(lines: impl Iterator<Item = &'a str>) -> (u32, u32) {
    let (mut added, mut deleted) = (0, 0);
    for part in lines.flat_map(|line| line.split(',')) {
        let part = part.trim();
        let n = part
            .split_whitespace()
            .next()
            .and_then(|n| n.parse::<u32>().ok())
            .unwrap_or(0);
        if part.contains("insertion") {
            added = n;
        } else if part.contains("deletion") {
            deleted = n;
        }
    }
    (added, deleted)
}

async fn toplevel(folder: &str) -> Option<String> {
    git(folder, &["rev-parse", "--show-toplevel"])
        .await
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// When the repository last changed on disk: its index, which every commit and checkout rewrites.
fn modified(root: &str) -> u64 {
    std::fs::metadata(Path::new(root).join(".git/index"))
        .or_else(|_| std::fs::metadata(root))
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

async fn today() -> String {
    let out = tokio::process::Command::new("/bin/date")
        .arg("+%Y-%m-%d")
        .output()
        .await;
    out.ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_default()
}

/// The installed `git`, from the PATH or where macOS and Homebrew put it: launchd starts the bridge with a short PATH.
fn git_binary() -> &'static str {
    static FOUND: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    FOUND.get_or_init(|| {
        let mut candidates: Vec<String> = std::env::var("PATH")
            .unwrap_or_default()
            .split(':')
            .map(|dir| format!("{dir}/git"))
            .collect();
        candidates.extend(
            [
                "/opt/homebrew/bin/git",
                "/usr/local/bin/git",
                "/usr/bin/git",
            ]
            .map(String::from),
        );
        candidates
            .into_iter()
            .find(|path| Path::new(path).is_file())
            .unwrap_or_else(|| "git".to_string())
    })
}

/// A git command's output, or None when it fails or takes too long.
async fn git(dir: &str, args: &[&str]) -> Option<String> {
    git_with(dir, args, GIT_TIMEOUT).await
}

async fn git_with(dir: &str, args: &[&str], timeout: Duration) -> Option<String> {
    let mut command = tokio::process::Command::new(git_binary());
    command
        .arg("-C")
        .arg(dir)
        // Read-only: never take the index lock to refresh it, so a session's own git commands never collide with us.
        .arg("--no-optional-locks")
        .args(args)
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("LC_ALL", "C")
        .kill_on_drop(true)
        .stdin(std::process::Stdio::null());
    let out = tokio::time::timeout(timeout, command.output())
        .await
        .ok()?
        .ok()?;
    out.status
        .success()
        .then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

/// The repositories directly inside `folder`: subfolders with a `.git` (a directory, or a file in a worktree).
fn children_repos(folder: &str) -> Vec<String> {
    let Ok(entries) = std::fs::read_dir(folder) else {
        return Vec::new();
    };
    entries
        .flatten()
        .take(500)
        .map(|e| e.path())
        .filter(|p| p.is_dir() && p.join(".git").exists())
        .filter_map(|p| p.to_str().map(str::to_owned))
        .collect()
}

/// Folders worth reading: where the sessions work, then any the app adds.
pub fn folders(sessions: &[crate::protocol::SessionSummary], extra: Vec<String>) -> Vec<String> {
    let mut counts: HashMap<String, u64> = HashMap::new();
    for s in sessions {
        let latest = counts.entry(s.cwd.clone()).or_default();
        *latest = (*latest).max(s.created_at);
    }
    let mut folders: Vec<(u64, String)> = counts.into_iter().map(|(f, t)| (t, f)).collect();
    folders.sort_by(|a, b| b.0.cmp(&a.0));
    let mut out: Vec<String> = folders.into_iter().map(|(_, f)| f).collect();
    out.extend(extra);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_branch_distance_and_changes() {
        let status = "# branch.oid abc\n# branch.head main\n# branch.upstream origin/main\n# branch.ab +2 -3\n1 .M N... 100644 100644 100644 a b src/x.rs\n? new.txt\n";
        let repo = parse_status(status, "/r", "r");
        assert_eq!(repo.branch.as_deref(), Some("main"));
        assert_eq!(repo.upstream.as_deref(), Some("origin/main"));
        assert_eq!((repo.ahead, repo.behind, repo.changed), (2, 3, 2));
    }

    #[test]
    fn finds_repositories_inside_a_folder_of_projects() {
        let dir = std::env::temp_dir().join(format!("shed-git-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("a/.git")).unwrap();
        std::fs::create_dir_all(dir.join("b")).unwrap();
        std::fs::create_dir_all(dir.join("c")).unwrap();
        std::fs::write(dir.join("c/.git"), "gitdir: elsewhere").unwrap();
        let mut found = children_repos(dir.to_str().unwrap());
        found.sort();
        let names: Vec<_> = found
            .iter()
            .map(|p| p.rsplit('/').next().unwrap())
            .collect();
        assert_eq!(names, ["a", "c"]);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn detached_head_has_no_branch() {
        let repo = parse_status("# branch.oid abc\n# branch.head (detached)\n", "/r", "r");
        assert!(repo.branch.is_none());
    }

    #[test]
    fn reads_commits_with_their_line_counts() {
        let log = "\x1eaaa\x1fa1\x1fHenry\x1fH@x.com\x1f1700000000\x1f2026-11-07\x1fFix the thing\n\n 2 files changed, 10 insertions(+), 3 deletions(-)\n\x1ebbb\x1fb1\x1fJim\x1fjim@x.com\x1f1700000100\x1f2026-11-06\x1fOnly adds\n\n 1 file changed, 4 insertions(+)\n";
        let commits = parse_log(log, Some("h@x.com"), "shed");
        assert_eq!(commits.len(), 2);
        assert!(commits[0].mine && !commits[1].mine);
        assert_eq!((commits[0].added, commits[0].deleted), (10, 3));
        assert_eq!((commits[1].added, commits[1].deleted), (4, 0));
        assert_eq!(commits[0].time, 1_700_000_000_000);
        assert_eq!(commits[1].day, "2026-11-06");
    }

    #[test]
    fn counts_lines_per_hash() {
        let log = "\x1eaaa\n\n 2 files changed, 10 insertions(+), 3 deletions(-)\n\x1ebbb\n\x1eccc\n\n 1 file changed, 1 deletion(-)\n";
        let lines: HashMap<_, _> = parse_lines(log).into_iter().collect();
        assert_eq!(lines["aaa"], (10, 3));
        assert_eq!(lines["bbb"], (0, 0));
        assert_eq!(lines["ccc"], (0, 1));
    }
}
