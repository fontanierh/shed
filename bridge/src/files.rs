//! Folder browsing for choosing a session's working directory from a remote client.

use std::time::UNIX_EPOCH;

use anyhow::Result;
use serde_json::{json, Value};

use crate::session::expand_dir;

/// The folders inside `path` (default: home), sorted by name. Each says when it last changed, so a client can put the
/// newest first.
pub fn list_dir(path: Option<&str>, hidden: bool) -> Result<Value> {
    let home = crate::host::home_text();
    let dir = expand_dir(path.filter(|p| !p.is_empty()).unwrap_or("~"))?;
    let mut entries = Vec::new();
    for entry in std::fs::read_dir(&dir)?.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if !hidden && name.starts_with('.') {
            continue;
        }
        // Follows symlinks, so linked project folders are listed too.
        let Ok(meta) = std::fs::metadata(entry.path()) else {
            continue;
        };
        if !meta.is_dir() {
            continue;
        }
        let modified = meta
            .modified()
            .ok()
            .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
            .map(|d| d.as_millis() as u64);
        entries.push(json!({
            "name": name,
            "path": entry.path().to_string_lossy(),
            "git": entry.path().join(".git").exists(),
            "branch": branch(&entry.path()),
            "modified": modified,
        }));
    }
    entries.sort_by_key(|e| e["name"].as_str().unwrap_or("").to_lowercase());
    let parent = std::path::Path::new(&dir)
        .parent()
        .map(|p| p.to_string_lossy().into_owned());
    Ok(json!({
        "path": dir,
        "parent": parent,
        "home": home,
        "entries": entries,
    }))
}

/// The checked-out branch of a repository or worktree, from `HEAD` (a short hash when detached).
fn branch(dir: &std::path::Path) -> Option<String> {
    let dot_git = dir.join(".git");
    let git_dir = if dot_git.is_file() {
        let pointer = std::fs::read_to_string(&dot_git).ok()?;
        let target = pointer.trim().strip_prefix("gitdir:")?.trim();
        let path = std::path::PathBuf::from(target);
        if path.is_absolute() {
            path
        } else {
            dir.join(path)
        }
    } else {
        dot_git
    };
    let head = std::fs::read_to_string(git_dir.join("HEAD")).ok()?;
    let head = head.trim();
    Some(match head.strip_prefix("ref: refs/heads/") {
        Some(name) => name.to_string(),
        None => head.chars().take(7).collect(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lists_folders_hides_dotfiles_and_reads_repo_and_worktree_branches() {
        let root = std::env::temp_dir().join(format!("shed-files-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join(".hidden")).unwrap();
        std::fs::create_dir_all(root.join("alpha/.git")).unwrap();
        std::fs::write(root.join("alpha/.git/HEAD"), "ref: refs/heads/main\n").unwrap();
        std::fs::create_dir_all(root.join("wt-gitdir")).unwrap();
        std::fs::write(root.join("wt-gitdir/HEAD"), "ref: refs/heads/feature/x\n").unwrap();
        std::fs::create_dir_all(root.join("beta")).unwrap();
        std::fs::write(root.join("beta/.git"), "gitdir: ../wt-gitdir\n").unwrap();
        std::fs::write(root.join("plain.txt"), "ignored").unwrap();

        let visible = list_dir(root.to_str(), false).unwrap();
        let entries = visible["entries"].as_array().unwrap();
        assert_eq!(entries.len(), 3);
        assert_eq!(entries[0]["name"], "alpha");
        assert_eq!(entries[0]["branch"], "main");
        assert_eq!(entries[1]["name"], "beta");
        assert_eq!(entries[1]["git"], true);
        assert_eq!(entries[1]["branch"], "feature/x");

        let with_hidden = list_dir(root.to_str(), true).unwrap();
        assert_eq!(with_hidden["entries"].as_array().unwrap().len(), 4);
        std::fs::remove_dir_all(&root).unwrap();
    }
}
