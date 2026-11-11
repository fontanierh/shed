//! What the bridge asks of the machine it runs on, in one place: the user's home folder and the clock.

use std::path::PathBuf;
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
