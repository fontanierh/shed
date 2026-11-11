//! Bridge state on disk, under ~/.agent-remote: the settings and the auth token in config.json, and the files the
//! bridge keeps for itself.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use anyhow::{anyhow, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

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

/// config.json's settings. A field that is missing takes its default; one of another type than expected is a
/// mistake, and the file is then refused like one that isn't JSON.
#[derive(Clone)]
pub struct Config {
    /// `defaultContextWindows`: the window each model keeps to by default, by "provider/id".
    pub default_context_windows: HashMap<String, u64>,
    /// `stallCheck`: the model asked whether a command that stopped moving is stuck, when the bridge is given an
    /// OpenAI key for it.
    pub stall_check: Option<crate::stall::Judge>,
    pub sites: Sites,
    pub opencodex: Routing,
    pub web: Web,
}

/// `sites`: `{ "publish": false }` keeps sites off the tailnet.
#[derive(Clone, Copy)]
pub struct Sites {
    pub publish: bool,
}

/// `opencodex`: `false`, nothing, or where Open Codex listens.
#[derive(Clone)]
pub enum Routing {
    Off,
    Unset,
    On(Addresses),
}

/// The `opencodex` entry when it is an object.
#[derive(Clone, Default)]
pub struct Addresses {
    pub url: Option<String>,
    pub management_url: Option<String>,
    pub admin_token_file: Option<String>,
}

/// `web`: the provider `shed-web` asks, and its key.
#[derive(Clone)]
pub struct Web {
    pub provider: Option<String>,
    pub firecrawl_api_key: Option<String>,
    pub firecrawl_url: Option<String>,
}

/// A setting of the wrong type is a mistake in the file, not a setting left out: reading it as the default would,
/// for one, publish the sites of someone who wrote `"publish": "no"`.
fn mistyped(name: &str, wanted: &str) -> anyhow::Error {
    anyhow!("config.json: `{name}` must be {wanted}")
}

/// The object under `name`, or nothing when it is left out.
fn section<'a>(config: &'a Value, name: &str) -> Result<Option<&'a Value>> {
    match &config[name] {
        Value::Null => Ok(None),
        section @ Value::Object(_) => Ok(Some(section)),
        _ => Err(mistyped(name, "an object")),
    }
}

fn text(section: Option<&Value>, of: &str, field: &str) -> Result<Option<String>> {
    match section.map(|section| &section[field]) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(text)) => Ok(Some(text.clone())),
        Some(_) => Err(mistyped(&format!("{of}.{field}"), "text")),
    }
}

impl Config {
    pub fn read(config: &Value) -> Result<Config> {
        let default_context_windows = match &config["defaultContextWindows"] {
            Value::Null => HashMap::new(),
            windows => serde_json::from_value(windows.clone()).map_err(|_| {
                mistyped(
                    "defaultContextWindows",
                    "an object of whole numbers by model",
                )
            })?,
        };
        let check = section(config, "stallCheck")?;
        let stall_check = match text(check, "stallCheck", "openaiApiKey")? {
            Some(key) if !key.is_empty() => Some(crate::stall::Judge {
                key,
                model: text(check, "stallCheck", "model")?
                    .unwrap_or_else(|| crate::stall::DEFAULT_MODEL.to_string()),
                threshold: match check.map(|check| &check["threshold"]) {
                    None | Some(Value::Null) => crate::stall::DEFAULT_THRESHOLD,
                    Some(threshold) => threshold
                        .as_f64()
                        .ok_or_else(|| mistyped("stallCheck.threshold", "a number"))?,
                },
            }),
            _ => None,
        };
        // Published unless the file says not to: a site nobody can open from the phone is no use.
        let publish = match section(config, "sites")?.map(|sites| &sites["publish"]) {
            None | Some(Value::Null) => true,
            Some(Value::Bool(publish)) => *publish,
            Some(_) => return Err(mistyped("sites.publish", "true or false")),
        };
        let opencodex = match &config["opencodex"] {
            Value::Bool(false) => Routing::Off,
            Value::Null => Routing::Unset,
            Value::Bool(true) => Routing::On(Addresses::default()),
            on @ Value::Object(_) => Routing::On(Addresses {
                url: text(Some(on), "opencodex", "url")?,
                management_url: text(Some(on), "opencodex", "managementUrl")?,
                admin_token_file: text(Some(on), "opencodex", "adminTokenFile")?,
            }),
            _ => return Err(mistyped("opencodex", "true, false or an object")),
        };
        let web = section(config, "web")?;
        Ok(Config {
            default_context_windows,
            stall_check,
            sites: Sites { publish },
            opencodex,
            web: Web {
                provider: text(web, "web", "provider")?,
                firecrawl_api_key: text(web, "web", "firecrawlApiKey")?,
                firecrawl_url: text(web, "web", "firecrawlUrl")?,
            },
        })
    }

    /// What config.json in `dir` says now: nothing when there is no file, an error when there is one that can't
    /// be read or isn't a JSON object. It keeps nothing and logs nothing; `config_in` does both.
    pub fn load(dir: &Path) -> Result<Config> {
        match document(&dir.join("config.json"))? {
            Some(config) => Config::read(&config),
            None => Ok(Config::default()),
        }
    }
}

impl Default for Config {
    /// What a config with nothing in it says.
    fn default() -> Config {
        Config {
            default_context_windows: HashMap::new(),
            stall_check: None,
            sites: Sites { publish: true },
            opencodex: Routing::Unset,
            web: Web {
                provider: None,
                firecrawl_api_key: None,
                firecrawl_url: None,
            },
        }
    }
}

/// config.json as written, or nothing when there is no file.
fn document(path: &Path) -> Result<Option<Value>> {
    let raw = match std::fs::read_to_string(path) {
        Ok(raw) => raw,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(anyhow!("{} can't be read: {e}", path.display())),
    };
    let document: Value = serde_json::from_str(&raw)
        .with_context(|| format!("{} is not valid JSON", path.display()))?;
    if !document.is_object() {
        return Err(anyhow!("{} is not a JSON object", path.display()));
    }
    Ok(Some(document))
}

/// What a config file last gave, and the failure last logged for it.
#[derive(Default)]
struct Kept {
    good: Option<Config>,
    failure: Option<String>,
}

impl Kept {
    /// The settings to go by after this read, and the line to log: a file that stopped being readable keeps what
    /// it last gave, and says so once for each different failure. Several watchers read the file every few seconds.
    fn take(&mut self, read: Result<Config>) -> (Config, Option<String>) {
        match read {
            Ok(config) => {
                self.good = Some(config.clone());
                self.failure = None;
                (config, None)
            }
            Err(e) => {
                let failure = format!("{e:#}");
                let line = (self.failure.as_ref() != Some(&failure)).then(|| match self.good {
                    Some(_) => format!("{failure}: keeping the settings it last gave"),
                    None => format!("{failure}: going by the defaults"),
                });
                self.failure = Some(failure);
                (self.good.clone().unwrap_or_default(), line)
            }
        }
    }
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

/// The bridge's folder. Copies share what its config last gave.
#[derive(Clone)]
pub struct Store {
    dir: PathBuf,
    kept: Arc<Mutex<Kept>>,
}

impl Store {
    pub fn open() -> Result<Store> {
        let home = std::env::var("HOME").context("HOME is not set")?;
        let dir = PathBuf::from(home).join(".agent-remote");
        std::fs::create_dir_all(&dir)?;
        Ok(Store::at(dir))
    }

    /// The store in a folder that is there.
    pub(crate) fn at(dir: PathBuf) -> Store {
        Store {
            dir,
            kept: Default::default(),
        }
    }

    pub fn token(&self) -> Result<String> {
        let path = self.dir.join("config.json");
        // An invalid file stops the bridge here, at its start. Read later, it keeps the settings of this read.
        let mut config = document(&path)?.unwrap_or_else(|| json!({}));
        self.keep(Ok(Config::read(&config)?));
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

    /// The settings in config.json, read each time, so editing the file takes effect without a restart. A file
    /// that can't be read or understood changes nothing: an edit left half done must not turn back on what was
    /// turned off.
    pub fn config(&self) -> Config {
        self.keep(Config::load(&self.dir))
    }

    fn keep(&self, read: Result<Config>) -> Config {
        let (config, line) = self.kept.lock().unwrap().take(read);
        if let Some(line) = line {
            eprintln!("{line}");
        }
        config
    }

    /// `setup/install.sh` fills these in. `default_window` looks one model up in them.
    pub fn default_windows(&self) -> HashMap<String, u64> {
        self.config().default_context_windows
    }

    pub fn stall_check(&self) -> Option<crate::stall::Judge> {
        self.config().stall_check
    }

    /// The top-level Prime sessions the bridge has listed, by `sessionId`.
    pub fn load_prime_sessions(&self) -> HashSet<String> {
        self.load("prime-sessions.json")
    }

    pub fn save_prime_sessions(&self, shown: &HashSet<String>) -> Result<()> {
        let mut ids: Vec<&String> = shown.iter().collect();
        ids.sort();
        write_private(
            &self.dir.join("prime-sessions.json"),
            &serde_json::to_vec_pretty(&ids)?,
        )
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

    /// The bridge's state folder.
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
        Store::at(dir)
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
    fn a_config_that_breaks_keeps_the_settings_it_last_gave() {
        let store = store("config-broken");
        let path = store.dir.join("config.json");
        std::fs::write(
            &path,
            r#"{"defaultContextWindows": {"a/b": 272000}, "stallCheck": {"openaiApiKey": "sk-test"}}"#,
        )
        .unwrap();
        assert_eq!(store.default_windows()["a/b"], 272000);
        for broken in [
            "{\"defaultContextWindows\": {\"a/b\": 1},}",
            "",
            "[]",
            "\"text\"",
        ] {
            std::fs::write(&path, broken).unwrap();
            assert_eq!(store.default_windows()["a/b"], 272000, "{broken}");
            assert_eq!(store.stall_check().unwrap().key, "sk-test", "{broken}");
        }
        // Mended, it is read again.
        std::fs::write(&path, r#"{"defaultContextWindows": {"a/b": 64000}}"#).unwrap();
        assert_eq!(store.default_windows()["a/b"], 64000);
        assert!(store.stall_check().is_none());
        std::fs::remove_dir_all(&store.dir).unwrap();
    }

    #[test]
    fn sites_stay_unpublished_when_the_config_breaks() {
        let store = store("config-sites");
        let path = store.dir.join("config.json");
        std::fs::write(&path, r#"{"sites": {"publish": false}}"#).unwrap();
        assert!(!store.config().sites.publish);
        std::fs::write(&path, r#"{"sites": {"publish": false},}"#).unwrap();
        assert!(!store.config().sites.publish);
        // No file is not a broken one: the defaults again.
        std::fs::remove_file(&path).unwrap();
        assert!(store.config().sites.publish);
        std::fs::remove_dir_all(&store.dir).unwrap();
    }

    #[test]
    fn a_config_that_never_was_good_gives_the_defaults() {
        let store = store("config-never");
        assert!(Config::load(&store.dir).is_ok());
        std::fs::write(store.dir.join("config.json"), "not json").unwrap();
        assert!(Config::load(&store.dir).is_err());
        assert_defaults(&store.config());
        // The bridge does not start on it.
        assert!(store.token().is_err());
        std::fs::remove_dir_all(&store.dir).unwrap();
    }

    fn assert_defaults(config: &Config) {
        assert!(config.default_context_windows.is_empty());
        assert!(config.stall_check.is_none());
        assert!(config.sites.publish);
        assert!(matches!(config.opencodex, Routing::Unset));
        assert_eq!(config.web.provider, None);
        assert_eq!(config.web.firecrawl_api_key, None);
        assert_eq!(config.web.firecrawl_url, None);
    }

    #[test]
    fn a_missing_field_takes_its_default() {
        let store = store("config-defaults");
        let read = |config: Value| Config::read(&config).unwrap();
        assert_defaults(&store.config());
        assert_defaults(&Config::default());
        assert_defaults(&read(json!({})));
        assert_defaults(&read(json!({ "token": "x", "other": 1 })));
        assert_defaults(&read(json!({
            "defaultContextWindows": {},
            "stallCheck": { "openaiApiKey": "", "model": "m" },
            "sites": {},
            "opencodex": null,
            "web": { "provider": null },
        })));

        let judge = |check: Value| read(json!({ "stallCheck": check })).stall_check;
        let plain = judge(json!({ "openaiApiKey": "sk-test" })).unwrap();
        assert_eq!(plain.model, crate::stall::DEFAULT_MODEL);
        assert_eq!(plain.threshold, crate::stall::DEFAULT_THRESHOLD);
        let chosen =
            judge(json!({ "openaiApiKey": "sk-test", "model": "m", "threshold": 0.5 })).unwrap();
        assert_eq!((chosen.model.as_str(), chosen.threshold), ("m", 0.5));

        let publish = |config: Value| read(config).sites.publish;
        assert!(publish(json!({ "sites": { "publish": true } })));
        assert!(!publish(json!({ "sites": { "publish": false } })));

        let routing = |entry: Value| read(json!({ "opencodex": entry })).opencodex;
        assert!(matches!(routing(json!(false)), Routing::Off));
        let Routing::On(bare) = routing(json!(true)) else {
            panic!("`true` turns routing on")
        };
        assert_eq!(
            (bare.url, bare.management_url, bare.admin_token_file),
            (None, None, None)
        );
        std::fs::remove_dir_all(&store.dir).unwrap();
    }

    /// A setting of the wrong type is refused and named, not read as its default.
    #[test]
    fn a_mistyped_field_is_refused_by_name() {
        let refused = |config: Value| match Config::read(&config) {
            Ok(_) => panic!("{config} was read"),
            Err(e) => e.to_string(),
        };
        assert_eq!(
            refused(json!({ "sites": { "publish": "no" } })),
            "config.json: `sites.publish` must be true or false"
        );
        for (config, named) in [
            (json!({ "sites": false }), "`sites`"),
            (
                json!({ "defaultContextWindows": { "a/b": 272000, "c/d": "wide" } }),
                "`defaultContextWindows`",
            ),
            (
                json!({ "defaultContextWindows": [] }),
                "`defaultContextWindows`",
            ),
            (json!({ "stallCheck": "sk-test" }), "`stallCheck`"),
            (
                json!({ "stallCheck": { "openaiApiKey": "k", "model": 7 } }),
                "`stallCheck.model`",
            ),
            (
                json!({ "stallCheck": { "openaiApiKey": "k", "threshold": "high" } }),
                "`stallCheck.threshold`",
            ),
            (json!({ "opencodex": "on" }), "`opencodex`"),
            (json!({ "opencodex": { "url": 7 } }), "`opencodex.url`"),
            (json!({ "web": ["firecrawl"] }), "`web`"),
            (
                json!({ "web": { "firecrawlApiKey": 7 } }),
                "`web.firecrawlApiKey`",
            ),
        ] {
            assert!(refused(config.clone()).contains(named), "{config}");
        }
    }

    /// And while the bridge runs, a file with such a mistake changes nothing.
    #[test]
    fn sites_stay_unpublished_when_a_setting_is_mistyped() {
        let store = store("config-mistyped");
        let path = store.dir.join("config.json");
        std::fs::write(&path, r#"{"sites": {"publish": false}}"#).unwrap();
        assert!(!store.config().sites.publish);
        std::fs::write(&path, r#"{"sites": {"publish": "no"}}"#).unwrap();
        assert!(!store.config().sites.publish);
        std::fs::remove_dir_all(&store.dir).unwrap();
    }

    #[test]
    fn a_config_s_failure_is_logged_once() {
        let failed = |why: &str| Err(anyhow!("{why}"));
        let mut kept = Kept::default();
        let (config, line) = kept.take(failed("a stray comma"));
        assert_defaults(&config);
        assert_eq!(
            line.as_deref(),
            Some("a stray comma: going by the defaults")
        );
        assert_eq!(kept.take(failed("a stray comma")).1, None);

        let good = Config::read(&json!({ "sites": { "publish": false } })).unwrap();
        assert_eq!(kept.take(Ok(good)).1, None);
        let (config, line) = kept.take(failed("a stray comma"));
        assert!(!config.sites.publish);
        assert_eq!(
            line.as_deref(),
            Some("a stray comma: keeping the settings it last gave")
        );
        assert_eq!(kept.take(failed("a stray comma")).1, None);
        // Another failure is said too.
        let (config, line) = kept.take(failed("a stray brace"));
        assert!(!config.sites.publish);
        assert_eq!(
            line.as_deref(),
            Some("a stray brace: keeping the settings it last gave")
        );
    }

    #[test]
    fn the_prime_session_list_keeps_its_shape_and_a_broken_one_is_kept_aside() {
        let store = store("prime-sessions");
        let path = store.dir.join("prime-sessions.json");
        assert!(store.load_prime_sessions().is_empty());
        let list = "[\n  \"01a1-conversation\",\n  \"01a2-other\"\n]";
        std::fs::write(&path, list).unwrap();
        let shown = store.load_prime_sessions();
        assert_eq!(shown.len(), 2);
        store.save_prime_sessions(&shown).unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), list);

        // A write cut short.
        std::fs::write(&path, "[\n  \"01a1-conver").unwrap();
        assert!(store.load_prime_sessions().is_empty());
        assert!(store.dir.join("prime-sessions.json.bad").is_file());
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
