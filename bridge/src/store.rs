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

    /// What one of the bridge's own files holds, or nothing for a file that isn't there yet. One that can't be
    /// understood is kept aside, since the next save writes it anew.
    fn load<T: serde::de::DeserializeOwned + Default>(&self, name: &str) -> T {
        let path = self.dir.join(name);
        let raw = match std::fs::read_to_string(&path) {
            Ok(raw) => raw,
            Err(e) => {
                if e.kind() != std::io::ErrorKind::NotFound {
                    eprintln!("{name} can't be read: {e}");
                }
                return T::default();
            }
        };
        serde_json::from_str(&raw).unwrap_or_else(|e| {
            let aside = path.with_extension("json.bad");
            match std::fs::copy(&path, &aside) {
                Ok(_) => eprintln!("{name} can't be read ({e}); kept as {}", aside.display()),
                Err(copy) => eprintln!(
                    "{name} can't be read ({e}), and can't be kept as {}: {copy}",
                    aside.display()
                ),
            }
            T::default()
        })
    }

    pub fn load_sessions(&self) -> Vec<SessionRecord> {
        self.load("sessions.json")
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
        self.load("limits.json")
    }

    /// The sites the bridge published, so it can take their routes down when they end and never touch the rest.
    pub fn load_published_sites(&self) -> std::collections::BTreeMap<u16, crate::sites::Published> {
        self.load("sites.json")
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

/// Windows saved under the `activeSessionId` a Prime session had when they were chosen, as the bridge once did,
/// move to the conversation's `sessionId`: a session gets another `activeSessionId` each time it reopens, and the
/// window was no longer found. Prime's worker records (`<daemon>/<activeSessionId>.json`) still name the
/// conversation. Returns whether anything moved.
pub fn adopt_stray_limits(limits: &mut HashMap<String, u64>, workers: &std::path::Path) -> bool {
    let daemons: Vec<PathBuf> = std::fs::read_dir(workers)
        .map(|dir| dir.flatten().map(|entry| entry.path()).collect())
        .unwrap_or_default();
    let conversation = |active: &str| {
        daemons.iter().find_map(|daemon| {
            let raw = std::fs::read_to_string(daemon.join(format!("{active}.json"))).ok()?;
            let record: serde_json::Value = serde_json::from_str(&raw).ok()?;
            record["rootSessionId"].as_str().map(str::to_string)
        })
    };
    // A session's id in a file name: nothing that could leave the folder.
    let strays: Vec<(String, String)> = limits
        .keys()
        .filter(|key| key.chars().all(|c| c.is_ascii_alphanumeric()))
        .filter_map(|key| Some((key.clone(), conversation(key)?)))
        .collect();
    for (active, conversation) in &strays {
        if let Some(limit) = limits.remove(active) {
            limits.entry(conversation.clone()).or_insert(limit);
        }
    }
    !strays.is_empty()
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
impl Store {
    /// An empty store of its own, for a test.
    pub(crate) fn temporary(name: &str) -> Store {
        let dir = std::env::temp_dir().join(format!("shed-store-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        Store { dir }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store(name: &str) -> Store {
        Store::temporary(name)
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
    fn a_window_saved_under_a_session_that_reopened_moves_to_its_conversation() {
        let dir = store("strays").dir;
        let daemon = dir.join("workers/bf0e");
        std::fs::create_dir_all(&daemon).unwrap();
        std::fs::write(
            daemon.join("409b1ffd5290.json"),
            r#"{"rootActiveSessionId": "409b1ffd5290", "rootSessionId": "01a1-conversation"}"#,
        )
        .unwrap();
        let mut limits: HashMap<String, u64> = [
            ("409b1ffd5290".to_string(), 400_000),
            ("0a1b2c3d".to_string(), 600_000),
            ("01a2-other".to_string(), 1_000_000),
        ]
        .into();
        assert!(adopt_stray_limits(&mut limits, &dir.join("workers")));
        assert_eq!(limits.get("01a1-conversation"), Some(&400_000));
        assert_eq!(limits.get("409b1ffd5290"), None);
        // A Pi session's id and a conversation's id have no worker record: they stay.
        assert_eq!(limits.get("0a1b2c3d"), Some(&600_000));
        assert_eq!(limits.get("01a2-other"), Some(&1_000_000));
        assert!(!adopt_stray_limits(&mut limits, &dir.join("workers")));
        assert!(!adopt_stray_limits(&mut limits, &dir.join("missing")));
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

    /// The files as bridges before this one wrote them: reading or writing them another way loses the sessions and
    /// windows people already have.
    #[test]
    fn the_saved_files_keep_their_shape() {
        let store = store("shape");
        let sessions = r#"[
  {
    "id": "0a1b2c3d",
    "agent": "pi",
    "cwd": "/work/project",
    "title": "List the files",
    "createdAt": 1700000000000,
    "sessionFile": "/work/sessions/one.jsonl"
  },
  {
    "id": "4e5f6a7b",
    "agent": "deepseek",
    "cwd": "/work",
    "title": "work",
    "createdAt": 1700000001000,
    "sessionFile": null
  }
]"#;
        std::fs::write(store.dir.join("sessions.json"), sessions).unwrap();
        let records = store.load_sessions();
        assert_eq!(records[0].agent, AgentKind::Pi);
        assert_eq!(
            records[0].session_file.as_deref(),
            Some("/work/sessions/one.jsonl")
        );
        assert_eq!(records[1].created_at, 1_700_000_001_000);
        store.save_sessions(&records).unwrap();
        assert_eq!(
            std::fs::read_to_string(store.dir.join("sessions.json")).unwrap(),
            sessions
        );

        // A record written before sessions kept their file still loads.
        let older = r#"[{ "id": "0a1b2c3d", "agent": "prime", "cwd": "/work", "title": "work", "createdAt": 1 }]"#;
        std::fs::write(store.dir.join("sessions.json"), older).unwrap();
        assert_eq!(store.load_sessions()[0].session_file, None);

        let limits = "{\n  \"01a1-conversation\": 200000\n}";
        std::fs::write(store.dir.join("limits.json"), limits).unwrap();
        let loaded = store.load_limits();
        assert_eq!(loaded.get("01a1-conversation"), Some(&200_000));
        store.save_limits(&loaded).unwrap();
        assert_eq!(
            std::fs::read_to_string(store.dir.join("limits.json")).unwrap(),
            limits
        );
        std::fs::remove_dir_all(&store.dir).unwrap();
    }

    #[test]
    fn a_file_that_cannot_be_understood_is_kept_aside() {
        let store = store("sessions");
        std::fs::write(store.dir.join("sessions.json"), "[{\"id\": 1}]").unwrap();
        std::fs::write(store.dir.join("limits.json"), "{\"0a1b2c3d\": \"wide\"}").unwrap();
        std::fs::write(store.dir.join("sites.json"), "not json").unwrap();
        assert!(store.load_sessions().is_empty());
        assert!(store.load_limits().is_empty());
        assert!(store.load_published_sites().is_empty());
        for name in ["sessions", "limits", "sites"] {
            assert!(store.dir.join(format!("{name}.json.bad")).is_file());
        }
        std::fs::remove_dir_all(&store.dir).unwrap();
    }

    #[test]
    fn a_file_that_is_not_there_yet_reads_as_empty_and_leaves_nothing_aside() {
        let store = store("absent");
        assert!(store.load_sessions().is_empty());
        assert!(store.load_limits().is_empty());
        assert!(store.load_published_sites().is_empty());
        assert_eq!(std::fs::read_dir(&store.dir).unwrap().count(), 0);
        std::fs::remove_dir_all(&store.dir).unwrap();
    }
}
