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

/// The checked-out branch of a repository, from `.git/HEAD` (a short hash when detached). None outside a repository;
/// worktrees, whose `.git` is a file, report no branch.
fn branch(dir: &std::path::Path) -> Option<String> {
    let head = std::fs::read_to_string(dir.join(".git/HEAD")).ok()?;
    let head = head.trim();
    Some(match head.strip_prefix("ref: refs/heads/") {
        Some(name) => name.to_string(),
        None => head.chars().take(7).collect(),
    })
}
