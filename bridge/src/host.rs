//! What the bridge asks of the machine it runs on, in one place: the user's home folder, the clock, executables on
//! `PATH`, and the shared HTTP client.

use std::path::PathBuf;
use std::sync::OnceLock;
use std::time::{SystemTime, UNIX_EPOCH};

/// The bridge's user's home folder. Empty when `HOME` is not set, which `Store::open` refuses at the start.
pub fn home() -> PathBuf {
    PathBuf::from(home_text())
}

/// The home folder as commands and agents spell it out.
pub fn home_text() -> String {
    std::env::var("HOME").unwrap_or_default()
}

/// Now, in milliseconds since 1970.
pub fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// Shared connection-pooled HTTP client for local Open Codex, Firecrawl and stall checks.
pub fn http() -> &'static reqwest::Client {
    static CLIENT: OnceLock<reqwest::Client> = OnceLock::new();
    CLIENT.get_or_init(reqwest::Client::new)
}

/// Resolves an executable on `PATH`, falling back to common macOS / Homebrew locations when launchd starts with a
/// minimal `PATH`.
pub fn find_binary(name: &str, fallbacks: &[&str]) -> String {
    if let Some(paths) = std::env::var_os("PATH") {
        if let Some(found) = std::env::split_paths(&paths)
            .map(|dir| dir.join(name))
            .find(|p| p.is_file())
        {
            return found.to_string_lossy().into_owned();
        }
    }
    for candidate in fallbacks {
        if std::path::Path::new(candidate).is_file() {
            return (*candidate).to_string();
        }
    }
    name.to_string()
}
