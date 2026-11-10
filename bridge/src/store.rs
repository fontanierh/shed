//! Bridge state on disk: the auth token and the registry of sessions, under ~/.agent-remote.

use std::collections::HashMap;
use std::path::PathBuf;

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::json;

use crate::rpc::AgentKind;

/// A model's default window: under its own "provider/id", or, for a model reached through Open Codex, under the
/// provider it comes from. Open Codex names the API-key accounts `openai-apikey/…` and `anthropic-apikey/…`, and
/// lists the ChatGPT subscription's models bare: all of them are "openai/…" or "anthropic/…" here, so one entry
/// covers a model however it is reached.
pub fn default_window(windows: &HashMap<String, u64>, provider: &str, id: &str) -> Option<u64> {
    if let Some(window) = windows.get(&format!("{provider}/{id}")) {
        return Some(*window);
    }
    if provider != crate::opencodex::PROVIDER {
        return None;
    }
    let (namespace, model) = id.split_once('/').unwrap_or(("openai", id));
    let namespace = namespace.strip_suffix("-apikey").unwrap_or(namespace);
    windows.get(&format!("{namespace}/{model}")).copied()
}

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
        let mut config = match std::fs::read_to_string(&path) {
            Ok(raw) => serde_json::from_str::<serde_json::Value>(&raw)
                .with_context(|| format!("{} is not valid JSON", path.display()))?,
            Err(_) => json!({}),
        };
        if let Some(token) = config["token"].as_str() {
            return Ok(token.to_string());
        }
        let token = format!(
            "{}{}",
            uuid::Uuid::new_v4().simple(),
            uuid::Uuid::new_v4().simple()
        );
        // What is already there stays: the installer writes its settings before the bridge first starts.
        config
            .as_object_mut()
            .with_context(|| format!("{} is not a JSON object", path.display()))?
            .insert("token".into(), json!(token));
        write_private(&path, &serde_json::to_vec_pretty(&config)?)?;
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
        let path = self.dir.join("sessions.json");
        let Ok(raw) = std::fs::read_to_string(&path) else {
            return Vec::new();
        };
        serde_json::from_str(&raw).unwrap_or_else(|e| {
            // Kept aside: the next save writes the list anew.
            let aside = path.with_extension("json.bad");
            let _ = std::fs::copy(&path, &aside);
            eprintln!(
                "sessions.json can't be read ({e}); kept as {}",
                aside.display()
            );
            Vec::new()
        })
    }

    pub fn save_sessions(&self, records: &[SessionRecord]) -> Result<()> {
        write_private(
            &self.dir.join("sessions.json"),
            &serde_json::to_vec_pretty(records)?,
        )
    }

    /// The window each model keeps to by default, by "provider/id" (`defaultContextWindows` in config.json, which
    /// setup/install.sh fills in). `default_window` looks one model up in it.
    pub fn default_windows(&self) -> HashMap<String, u64> {
        std::fs::read_to_string(self.dir.join("config.json"))
            .ok()
            .and_then(|raw| serde_json::from_str::<serde_json::Value>(&raw).ok())
            .and_then(|config| serde_json::from_value(config["defaultContextWindows"].clone()).ok())
            .unwrap_or_default()
    }

    /// The model asked whether a command that stopped moving is stuck: `stallCheck` in config.json, set only when
    /// the bridge is given an OpenAI key for it. Read each time, so editing the file takes effect without a restart.
    pub fn stall_check(&self) -> Option<crate::stall::Judge> {
        let raw = std::fs::read_to_string(self.dir.join("config.json")).ok()?;
        let config: serde_json::Value = serde_json::from_str(&raw).ok()?;
        let check = &config["stallCheck"];
        let key = check["openaiApiKey"].as_str().filter(|k| !k.is_empty())?;
        Some(crate::stall::Judge {
            key: key.to_string(),
            model: check["model"]
                .as_str()
                .unwrap_or(crate::stall::DEFAULT_MODEL)
                .to_string(),
            threshold: check["threshold"]
                .as_f64()
                .unwrap_or(crate::stall::DEFAULT_THRESHOLD),
        })
    }

    /// Context windows chosen per session, Pi's and Prime's alike, by session id.
    pub fn load_limits(&self) -> HashMap<String, u64> {
        std::fs::read_to_string(self.dir.join("limits.json"))
            .ok()
            .and_then(|raw| serde_json::from_str(&raw).ok())
            .unwrap_or_default()
    }

    /// The sites the bridge published, so it can take their routes down when they end and never touch the rest.
    pub fn load_published_sites(&self) -> std::collections::BTreeMap<u16, crate::sites::Published> {
        std::fs::read_to_string(self.dir.join("sites.json"))
            .ok()
            .and_then(|raw| serde_json::from_str(&raw).ok())
            .unwrap_or_default()
    }

    pub fn save_published_sites(
        &self,
        sites: &std::collections::BTreeMap<u16, crate::sites::Published>,
    ) -> Result<()> {
        write_private(
            &self.dir.join("sites.json"),
            &serde_json::to_vec_pretty(sites)?,
        )
    }

    /// The bridge's state folder, for reading `config.json` as it is now.
    pub fn dir(&self) -> &PathBuf {
        &self.dir
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

#[cfg(test)]
mod tests {
    use super::*;

    fn store(name: &str) -> Store {
        let dir = std::env::temp_dir().join(format!("shed-store-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        Store { dir }
    }

    #[test]
    fn the_first_token_keeps_what_the_installer_wrote() {
        let store = store("token");
        let path = store.dir.join("config.json");
        std::fs::write(
            &path,
            r#"{"opencodex": false, "defaultContextWindows": {"a/b": 272000}}"#,
        )
        .unwrap();
        let token = store.token().unwrap();
        let config: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(config["token"], token.as_str());
        assert_eq!(config["opencodex"], false);
        assert_eq!(store.default_windows()["a/b"], 272000);
        // And it is the same one from then on.
        assert_eq!(store.token().unwrap(), token);
        std::fs::remove_dir_all(&store.dir).unwrap();
    }

    #[test]
    fn a_default_window_covers_its_model_through_open_codex() {
        let windows: HashMap<String, u64> = [
            ("openai/gpt-6.1-terra".to_string(), 272_000),
            ("opencodex/mistral/large".to_string(), 64_000),
        ]
        .into();
        let window = |provider, id| default_window(&windows, provider, id);
        assert_eq!(window("openai", "gpt-6.1-terra"), Some(272_000));
        // The ChatGPT subscription's bare id, and the API key's account.
        assert_eq!(window("opencodex", "gpt-6.1-terra"), Some(272_000));
        assert_eq!(
            window("opencodex", "openai-apikey/gpt-6.1-terra"),
            Some(272_000)
        );
        // Its own key comes first, and nothing else matches by accident.
        assert_eq!(window("opencodex", "mistral/large"), Some(64_000));
        assert_eq!(window("opencodex", "gpt-6.1-terra-fast"), None);
        assert_eq!(window("opencodex", "anthropic-apikey/gpt-6.1-terra"), None);
        assert_eq!(window("mistral", "gpt-6.1-terra"), None);
    }

    #[test]
    fn a_token_is_made_where_there_is_no_config() {
        let store = store("fresh");
        let token = store.token().unwrap();
        assert_eq!(token.len(), 64);
        assert_eq!(store.token().unwrap(), token);
        std::fs::remove_dir_all(&store.dir).unwrap();
    }

    #[test]
    fn a_list_of_sessions_that_cannot_be_read_is_kept_aside() {
        let store = store("sessions");
        std::fs::write(store.dir.join("sessions.json"), "[{\"id\": 1}]").unwrap();
        assert!(store.load_sessions().is_empty());
        assert!(store.dir.join("sessions.json.bad").is_file());
        std::fs::remove_dir_all(&store.dir).unwrap();
    }
}
