//! The branch a session's folder is on, read with the machine's own `git`, for the session header in the apps.

use std::path::Path;
use std::time::Duration;

use serde_json::{json, Value};

/// A git command that takes longer than this is given up on: a repository on a sleeping network drive mustn't hold
/// the header.
const GIT_TIMEOUT: Duration = Duration::from_secs(6);

/// The branch of the repository `folder` is in. None when it is detached, or when the folder is in no repository.
pub async fn branch(folder: &str) -> Value {
    let branch = git(folder, &["symbolic-ref", "--short", "-q", "HEAD"])
        .await
        .map(|branch| branch.trim().to_string())
        .filter(|branch| !branch.is_empty());
    json!({ "branch": branch })
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
    let out = tokio::time::timeout(GIT_TIMEOUT, command.output())
        .await
        .ok()?
        .ok()?;
    out.status
        .success()
        .then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn reads_the_branch_and_none_when_detached_or_outside_a_repository() {
        let dir = std::env::temp_dir().join(format!("shed-git-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("repo/src")).unwrap();
        let repo = dir.join("repo");
        let repo = repo.to_str().unwrap();
        assert_eq!(branch(repo).await["branch"], Value::Null);

        let commit = [
            "-c",
            "user.name=Shed",
            "-c",
            "user.email=shed@example.com",
            "-c",
            "commit.gpgsign=false",
            "commit",
            "--allow-empty",
            "-q",
            "-m",
            "first",
        ];
        assert!(git(repo, &["init", "-q", "-b", "trunk"]).await.is_some());
        assert!(git(repo, &commit).await.is_some());
        assert_eq!(branch(repo).await["branch"], "trunk");
        // From a folder inside it too: sessions often work in one.
        assert_eq!(
            branch(dir.join("repo/src").to_str().unwrap()).await["branch"],
            "trunk"
        );

        assert!(git(repo, &["checkout", "-q", "--detach"]).await.is_some());
        assert_eq!(branch(repo).await["branch"], Value::Null);
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
