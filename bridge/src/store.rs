//! Bridge state on disk: the auth token and the registry of sessions, under ~/.agent-remote.

use std::collections::HashMap;
use std::path::PathBuf;

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::json;

use crate::rpc::AgentKind;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionRecord {
    pub id: String,
    pub agent: AgentKind,
    pub cwd: String,
    pub title: String,
    pub created_at: u64,
    pub session_file: Option<String>,
}

pub struct Store {
    dir: PathBuf,
}

impl Store {
    pub fn open() -> Result<Store> {
        let home = std::env::var("HOME").context("HOME is not set")?;
        let dir = PathBuf::from(home).join(".agent-remote");
        std::fs::create_dir_all(&dir)?;
        Ok(Store { dir })
    }

    pub fn token(&self) -> Result<String> {
        let path = self.dir.join("config.json");
        if let Ok(raw) = std::fs::read_to_string(&path) {
            let config: serde_json::Value = serde_json::from_str(&raw)?;
            if let Some(token) = config["token"].as_str() {
                return Ok(token.to_string());
            }
        }
        let token = format!(
            "{}{}",
            uuid::Uuid::new_v4().simple(),
            uuid::Uuid::new_v4().simple()
        );
        write_private(
            &path,
            &serde_json::to_vec_pretty(&json!({ "token": token }))?,
        )?;
        Ok(token)
    }

    /// A stable identity for this bridge when it talks to Prime's daemon.
    pub fn client_id(&self) -> Result<String> {
        let path = self.dir.join("client-id");
        if let Ok(id) = std::fs::read_to_string(&path) {
            return Ok(id.trim().to_string());
        }
        let id = format!("agent-remote:{}", uuid::Uuid::new_v4().simple());
        write_private(&path, id.as_bytes())?;
        Ok(id)
    }

    pub fn load_sessions(&self) -> Vec<SessionRecord> {
        std::fs::read_to_string(self.dir.join("sessions.json"))
            .ok()
            .and_then(|raw| serde_json::from_str(&raw).ok())
            .unwrap_or_default()
    }

    pub fn save_sessions(&self, records: &[SessionRecord]) -> Result<()> {
        write_private(
            &self.dir.join("sessions.json"),
            &serde_json::to_vec_pretty(records)?,
        )
    }

    /// The window each model keeps to by default, by "provider/id" (`defaultContextWindows` in config.json, which
    /// setup/install.sh fills in).
    pub fn default_windows(&self) -> HashMap<String, u64> {
        std::fs::read_to_string(self.dir.join("config.json"))
            .ok()
            .and_then(|raw| serde_json::from_str::<serde_json::Value>(&raw).ok())
            .and_then(|config| serde_json::from_value(config["defaultContextWindows"].clone()).ok())
            .unwrap_or_default()
    }

    /// Context windows chosen per session, Pi's and Prime's alike, by session id.
    pub fn load_limits(&self) -> HashMap<String, u64> {
        std::fs::read_to_string(self.dir.join("limits.json"))
            .ok()
            .and_then(|raw| serde_json::from_str(&raw).ok())
            .unwrap_or_default()
    }

    pub fn save_limits(&self, limits: &HashMap<String, u64>) -> Result<()> {
        write_private(
            &self.dir.join("limits.json"),
            &serde_json::to_vec_pretty(limits)?,
        )
    }
}

fn write_private(path: &PathBuf, bytes: &[u8]) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    // Unique per write: concurrent saves must not rename each other's temp file away.
    let tmp = path.with_extension(format!("{}.tmp", uuid::Uuid::new_v4().simple()));
    std::fs::write(&tmp, bytes)?;
    std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600))?;
    std::fs::rename(&tmp, path)?;
    Ok(())
}
