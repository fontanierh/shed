//! Open Codex, the one gateway every agent reaches its models through. Its catalog (`/v1/models`) is the list of
//! models each agent offers in Shed, nothing added and nothing left out: the bridge writes it into Pi's and Prime's
//! `models.json` as an `opencodex` provider, and into dsh's `shed` profile, and lists only that provider's models.
//! Credentials, image limits and prices live in Open Codex, so every agent gets the same ones. Its request history is
//! also the record of what each session spends: it tags every request with the session it came from.

use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use anyhow::{anyhow, Result};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Deserializer};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use tokio::io::AsyncWriteExt;

pub const PROVIDER: &str = "opencodex";
/// Open Codex trusts its loopback listener, so the agents' key is a placeholder; dsh reads it from this variable.
pub const KEY: &str = "unused";
pub const KEY_ENV: &str = "SHED_OPENCODEX_KEY";
/// Pi's thinking levels, lowest first.
const LEVELS: [&str; 7] = ["off", "minimal", "low", "medium", "high", "xhigh", "max"];

/// Where Open Codex listens: `opencodex` in ~/.agent-remote/config.json, `{url, managementUrl, adminTokenFile}`, else
/// its defaults when it's installed (~/.opencodex). `"opencodex": false` turns routing off.
pub struct Gateway {
    pub url: String,
    management: String,
    token_file: PathBuf,
}

fn home() -> PathBuf {
    PathBuf::from(std::env::var("HOME").unwrap_or_default())
}

pub fn gateway() -> Option<Gateway> {
    gateway_in(&home())
}

/// ~/.agent-remote/config.json, as far as Open Codex goes.
#[derive(Deserialize, Default)]
struct Config {
    #[serde(default, deserialize_with = "routing")]
    opencodex: Routing,
}

/// The config's `opencodex` entry: `false`, nothing, or where Open Codex listens.
#[derive(Default)]
enum Routing {
    Off,
    #[default]
    Unset,
    On(Addresses),
}

/// The `opencodex` entry when it is an object.
#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct Addresses {
    #[serde(default, deserialize_with = "text")]
    url: Option<String>,
    #[serde(default, deserialize_with = "text")]
    management_url: Option<String>,
    #[serde(default, deserialize_with = "text")]
    admin_token_file: Option<String>,
}

/// Anything but `false` and null turns routing on, an object or not.
fn routing<'de, D: Deserializer<'de>>(from: D) -> Result<Routing, D::Error> {
    Ok(match Value::deserialize(from)? {
        Value::Bool(false) => Routing::Off,
        Value::Null => Routing::Unset,
        other => Routing::On(read(&other)),
    })
}

fn gateway_in(home: &Path) -> Option<Gateway> {
    let config: Value = std::fs::read_to_string(home.join(".agent-remote/config.json"))
        .ok()
        .and_then(|raw| serde_json::from_str(&raw).ok())
        .unwrap_or_default();
    let ours = match read::<Config>(&config).opencodex {
        Routing::Off => return None,
        Routing::Unset if !home.join(".opencodex").is_dir() => return None,
        Routing::Unset => Addresses::default(),
        Routing::On(addresses) => addresses,
    };
    let address = |given: Option<String>, default: &str| {
        given
            .as_deref()
            .unwrap_or(default)
            .trim_end_matches('/')
            .to_string()
    };
    Some(Gateway {
        url: address(ours.url, "http://127.0.0.1:10100"),
        management: address(ours.management_url, "http://127.0.0.1:10101"),
        token_file: ours
            .admin_token_file
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join(".opencodex/admin-api-token")),
    })
}

/// A JSON object from outside as a `T`, whose fields are each read as `value["key"].as_str()` and the like read
/// them: a missing key or a value of another type is none, and an unknown key is passed over. Anything but an
/// object reads as an empty one; a derived struct would otherwise take an array as its fields in order.
fn read<T: DeserializeOwned + Default>(value: &Value) -> T {
    if !value.is_object() {
        return T::default();
    }
    T::deserialize(value).unwrap_or_default()
}

fn text<'de, D: Deserializer<'de>>(from: D) -> Result<Option<String>, D::Error> {
    Ok(Value::deserialize(from)?.as_str().map(str::to_string))
}

fn whole<'de, D: Deserializer<'de>>(from: D) -> Result<Option<u64>, D::Error> {
    Ok(Value::deserialize(from)?.as_u64())
}

fn truth<'de, D: Deserializer<'de>>(from: D) -> Result<bool, D::Error> {
    Ok(Value::deserialize(from)? == true)
}

fn list<'de, D: Deserializer<'de>>(from: D) -> Result<Option<Vec<Value>>, D::Error> {
    Ok(match Value::deserialize(from)? {
        Value::Array(elements) => Some(elements),
        _ => None,
    })
}

/// A list of objects: none when it isn't a list, and an element that isn't an object reads as an empty one.
fn each<'de, D, T>(from: D) -> Result<Vec<T>, D::Error>
where
    D: Deserializer<'de>,
    T: DeserializeOwned + Default,
{
    Ok(list(from)?.unwrap_or_default().iter().map(read).collect())
}

fn nested<'de, D, T>(from: D) -> Result<T, D::Error>
where
    D: Deserializer<'de>,
    T: DeserializeOwned + Default,
{
    Ok(read(&Value::deserialize(from)?))
}

/// GET a JSON document. The admin token goes in on stdin, never in the arguments, where `ps` would show it.
async fn get(url: &str, token: Option<&str>) -> Result<Value> {
    let mut child = tokio::process::Command::new("/usr/bin/curl")
        .args([
            "-sS",
            "--fail-with-body",
            "--max-time",
            "15",
            "-K",
            "-",
            url,
        ])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true)
        .spawn()?;
    let mut stdin = child.stdin.take().ok_or_else(|| anyhow!("no stdin"))?;
    if let Some(token) = token {
        stdin
            .write_all(format!("header = \"Authorization: Bearer {token}\"\n").as_bytes())
            .await?;
    }
    drop(stdin);
    let out = child.wait_with_output().await?;
    if !out.status.success() {
        return Err(anyhow!(
            "Open Codex: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    Ok(serde_json::from_slice(&out.stdout)?)
}

/// Open Codex's provider for a Claude Pro or Max login. Its models stay out of Shed: a Claude subscription is
/// meant for Anthropic's own apps, so Claude reaches the agents through an API key alone.
const CLAUDE_SUBSCRIPTION: &str = "anthropic/";

/// The models Open Codex serves, as it lists them, less the Claude subscription's. Cached for a minute.
pub async fn catalog(gateway: &Gateway) -> Result<Vec<Value>> {
    static CACHE: Mutex<Option<(Instant, Vec<Value>)>> = Mutex::new(None);
    if let Some((at, models)) = CACHE.lock().unwrap().as_ref() {
        if at.elapsed() < Duration::from_secs(60) {
            return Ok(models.clone());
        }
    }
    let models = listed(&get(&format!("{}/v1/models", gateway.url), None).await?)?;
    *CACHE.lock().unwrap() = Some((Instant::now(), models.clone()));
    Ok(models)
}

/// Open Codex's reply to `/v1/models`. Its models stay as it listed them, which is what `sync` returns.
#[derive(Deserialize, Default)]
struct Listing {
    #[serde(default, deserialize_with = "list")]
    data: Option<Vec<Value>>,
}

/// A model as Open Codex's `/v1/models` lists one.
#[derive(Deserialize, Default)]
struct Model {
    #[serde(default, deserialize_with = "text")]
    id: Option<String>,
    #[serde(default, deserialize_with = "each")]
    reasoning_efforts: Vec<Effort>,
    #[serde(default, deserialize_with = "nested")]
    capabilities: Capabilities,
    #[serde(default, deserialize_with = "whole")]
    context_window: Option<u64>,
    #[serde(default, deserialize_with = "whole")]
    max_output_tokens: Option<u64>,
}

/// One of a listed model's `reasoning_efforts`.
#[derive(Deserialize, Default)]
struct Effort {
    #[serde(default, deserialize_with = "text")]
    value: Option<String>,
}

/// A listed model's `capabilities`.
#[derive(Deserialize, Default)]
struct Capabilities {
    #[serde(default, deserialize_with = "list")]
    input_modalities: Option<Vec<Value>>,
    #[serde(default, deserialize_with = "whole")]
    max_output_tokens: Option<u64>,
}

/// The models in a `/v1/models` reply, each as Open Codex listed it, less the Claude subscription's.
fn listed(reply: &Value) -> Result<Vec<Value>> {
    Ok(read::<Listing>(reply)
        .data
        .ok_or_else(|| anyhow!("Open Codex listed no models"))?
        .into_iter()
        .filter(|model| offered(&read(model)))
        .collect())
}

fn offered(model: &Model) -> bool {
    !model
        .id
        .as_deref()
        .unwrap_or_default()
        .starts_with(CLAUDE_SUBSCRIPTION)
}

/// The reasoning efforts a model takes, as Open Codex names them.
fn efforts(model: &Model) -> Vec<String> {
    model
        .reasoning_efforts
        .iter()
        .filter_map(|e| e.value.clone())
        .collect()
}

/// Each Pi thinking level and the effort it sends: the same name when the model takes it, otherwise none.
fn level_map(model: &Model) -> Option<Value> {
    let efforts = efforts(model);
    if efforts.is_empty() {
        return None;
    }
    let map: serde_json::Map<String, Value> = LEVELS
        .iter()
        .map(|level| {
            let wire = if *level == "off" { "none" } else { level };
            let value = efforts.iter().any(|e| e == wire).then(|| json!(wire));
            (level.to_string(), value.unwrap_or(Value::Null))
        })
        .collect();
    Some(Value::Object(map))
}

fn input(model: &Model) -> Value {
    let listed = &model.capabilities.input_modalities;
    let images = listed
        .as_ref()
        .is_some_and(|m| m.iter().any(|m| m == "image"));
    json!(if images {
        vec!["text", "image"]
    } else {
        vec!["text"]
    })
}

fn window(model: &Model) -> u64 {
    model.context_window.unwrap_or(128_000)
}

fn max_tokens(model: &Model) -> u64 {
    model
        .max_output_tokens
        .or(model.capabilities.max_output_tokens)
        .unwrap_or(32_768)
}

/// A model as Pi's and Prime's `models.json` define one. Its price stays at zero: Open Codex keeps the prices and
/// reports what each session spends.
fn agent_model(model: &Model, session_header: bool) -> Option<Value> {
    let id = model.id.as_deref()?;
    let mut entry = json!({
        "id": id,
        "name": id,
        "reasoning": level_map(model).is_some(),
        "input": input(model),
        "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
        "contextWindow": window(model),
        "maxTokens": max_tokens(model),
    });
    if let Some(map) = level_map(model) {
        entry["thinkingLevelMap"] = map;
    }
    // Pi sends its session id as `session_id` only when asked to, and Open Codex attributes requests by it.
    if session_header {
        entry["compat"] = json!({ "sessionAffinityFormat": "openai" });
    }
    Some(entry)
}

/// A model as dsh's `llm-pi-ai` plugin defines one: its reasoning efforts by dsh's own levels.
fn dsh_model(model: &Model) -> Option<Value> {
    let id = model.id.as_deref()?;
    let efforts = efforts(model);
    let reasoning = if efforts.is_empty() {
        json!(false)
    } else {
        let mut map = serde_json::Map::new();
        map.insert(
            "off".into(),
            if efforts.iter().any(|e| e == "none") {
                json!("none")
            } else {
                Value::Null
            },
        );
        for level in ["low", "medium", "high", "max"] {
            if efforts.iter().any(|e| e == level) {
                map.insert(level.into(), json!(level));
            }
        }
        Value::Object(map)
    };
    Some(json!({
        "id": id,
        "name": id,
        "contextWindow": window(model),
        "maxTokens": max_tokens(model),
        "input": input(model),
        "reasoningEfforts": reasoning,
    }))
}

/// Where the catalog is kept for dsh's profile layer, which is written without waiting on the network.
fn dsh_catalog_file(home: &Path) -> PathBuf {
    home.join(".agent-remote/opencodex-models.json")
}

/// Write the catalog into each agent's configuration, as its `opencodex` provider, and move a default model that
/// Open Codex also serves onto it. Other providers are left as they are, for the agents' own use and their older
/// sessions. Returns the catalog.
pub async fn sync(gateway: &Gateway) -> Result<Vec<Value>> {
    let listed = catalog(gateway).await?;
    let models: Vec<Model> = listed.iter().map(read).collect();
    write(&home(), &gateway.url, &models)?;
    Ok(listed)
}

/// What `sync` writes, in the agents' folders under `home`.
fn write(home: &Path, url: &str, models: &[Model]) -> Result<()> {
    for (agent, session_header) in [(".pi/agent", true), (".prime/agent", false)] {
        let dir = home.join(agent);
        if !dir.is_dir() {
            continue;
        }
        let entries: Vec<Value> = models
            .iter()
            .filter_map(|m| agent_model(m, session_header))
            .collect();
        let provider = json!({
            "baseUrl": format!("{url}/v1"),
            "api": "openai-responses",
            "apiKey": KEY,
            "models": entries,
        });
        update(&dir.join("models.json"), |config| {
            config["providers"][PROVIDER] = provider.clone();
        })?;
        update(&dir.join("settings.json"), |settings| {
            move_default(settings, models)
        })?;
    }
    let dsh: Vec<Value> = models.iter().filter_map(dsh_model).collect();
    write_if_changed(&dsh_catalog_file(home), &serde_json::to_vec_pretty(&dsh)?)
}

/// The default model in an agent's `settings.json`.
#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct Chosen {
    #[serde(default, deserialize_with = "text")]
    default_provider: Option<String>,
    #[serde(default, deserialize_with = "text")]
    default_model: Option<String>,
}

/// A default model of another provider that Open Codex serves too ("mistral" "deepseek-v4-1-flash-1017" as
/// "mistral/deepseek-v4-1-flash-1017") becomes the same model through Open Codex. The agents reach OpenAI and
/// Anthropic with API keys, which Open Codex names `openai-apikey` and `anthropic-apikey`: its bare OpenAI ids are
/// the ChatGPT subscription, a different account.
fn move_default(settings: &mut Value, models: &[Model]) {
    let Chosen {
        default_provider: Some(provider),
        default_model: Some(id),
    } = read(settings)
    else {
        return;
    };
    if provider == PROVIDER {
        return;
    }
    let namespace = match provider.as_str() {
        "openai" => "openai-apikey",
        "anthropic" => "anthropic-apikey",
        other => other,
    };
    let target = format!("{namespace}/{id}");
    let target = models
        .iter()
        .any(|m| m.id.as_deref() == Some(target.as_str()))
        .then_some(target);
    if let Some(target) = target {
        settings["defaultProvider"] = json!(PROVIDER);
        settings["defaultModel"] = json!(target);
    }
}

/// Read a JSON file (an empty object if it's missing), change it, and write it back if that changed anything.
fn update(path: &PathBuf, change: impl FnOnce(&mut Value)) -> Result<()> {
    let raw = std::fs::read_to_string(path).ok();
    let mut value: Value = match &raw {
        Some(raw) => serde_json::from_str(raw)?,
        None => json!({}),
    };
    if !value.is_object() {
        return Ok(());
    }
    // By value, not by text: the agents write these files in their own layout, and rewriting them in ours each
    // time would only reorder their keys.
    let before = value.clone();
    change(&mut value);
    if raw.is_none() || value != before {
        write_if_changed(path, format!("{:#}\n", value).as_bytes())?;
    }
    Ok(())
}

fn write_if_changed(path: &PathBuf, bytes: &[u8]) -> Result<()> {
    if std::fs::read(path).ok().as_deref() == Some(bytes) {
        return Ok(());
    }
    // Unique per write: two syncs at once must not rename each other's temp file away.
    let tmp = path.with_extension(format!("{}.tmp", uuid::Uuid::new_v4().simple()));
    std::fs::write(&tmp, bytes)?;
    // The agents keep some of these to their user alone.
    if let Ok(old) = std::fs::metadata(path) {
        let _ = std::fs::set_permissions(&tmp, old.permissions());
    }
    std::fs::rename(&tmp, path)?;
    Ok(())
}

/// The `llm-pi-ai` patch for dsh's `shed` profile: Open Codex as its one provider, from the catalog the last sync
/// kept. None when Open Codex isn't in use or hasn't been listed yet.
pub fn dsh_layer() -> Option<String> {
    let gateway = gateway()?;
    let models: Value =
        serde_json::from_slice(&std::fs::read(dsh_catalog_file(&home())).ok()?).ok()?;
    let providers = json!({
        PROVIDER: {
            "displayName": "Open Codex",
            "api": "openai-responses",
            "baseURL": format!("{}/v1", gateway.url),
            "apiKeyEnv": KEY_ENV,
            "models": models,
        }
    });
    // JSON is YAML, so it needs no escaping of its own.
    Some(format!(
        "- id: llm-pi-ai\n  config:\n    providers: {providers}\n"
    ))
}

/// The id Open Codex files a session's requests under: the first half of the SHA-256 of the session id it sends.
pub fn conversation(session_id: &str) -> String {
    let digest = Sha256::digest(session_id.as_bytes());
    digest[..16].iter().map(|b| format!("{b:02x}")).collect()
}

/// What a conversation has spent: dollars where Open Codex has a price for the model, tokens either way, and the
/// time of the latest request counted, from which the next count carries on.
#[derive(Debug, Default, Clone, Copy)]
pub struct Tally {
    pub cost: f64,
    pub priced: bool,
    pub tokens: u64,
    pub through: u64,
}

impl Tally {
    /// Count the requests made after this tally's latest one.
    pub async fn update(&mut self, gateway: &Gateway, conversation: &str) -> Result<()> {
        let token = std::fs::read_to_string(&gateway.token_file)
            .map_err(|e| anyhow!("Open Codex admin token: {e}"))?;
        let token = token.trim();
        let since = if self.through == 0 {
            0
        } else {
            self.through + 1
        };
        let mut cursor: Option<String> = None;
        // Added up apart and kept only when every page came: a failed page leaves the tally as it was, so the next
        // try doesn't count the first pages twice.
        let mut counted = *self;
        // Pages of 100, newest first: a long session's whole history the first time, a few requests after that.
        for _ in 0..100 {
            let mut url = format!(
                "{}/api/request-history?limit=100&from={since}&conversationId={conversation}",
                gateway.management
            );
            if let Some(cursor) = &cursor {
                url.push_str("&cursor=");
                url.push_str(cursor);
            }
            match counted.add(read(&get(&url, Some(token)).await?)) {
                Some(next) => cursor = Some(next),
                None => break,
            }
        }
        *self = counted;
        Ok(())
    }

    /// Count one page of the request history. Returns the cursor of the page after it, when there is one.
    fn add(&mut self, page: Page) -> Option<String> {
        for entry in &page.entries {
            self.through = self.through.max(entry.timestamp.unwrap_or(0));
            self.tokens += entry.total_tokens.unwrap_or(0);
            if let Some(cost) = entry.cost {
                self.cost += cost;
                self.priced = true;
            }
        }
        page.next_cursor.filter(|_| page.has_more)
    }
}

/// A page of Open Codex's request history (`/api/request-history`).
#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct Page {
    #[serde(default, deserialize_with = "each")]
    entries: Vec<Entry>,
    #[serde(default, deserialize_with = "text")]
    next_cursor: Option<String>,
    #[serde(default, deserialize_with = "truth")]
    has_more: bool,
}

/// One request in the history.
#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct Entry {
    #[serde(default, deserialize_with = "whole")]
    timestamp: Option<u64>,
    #[serde(default, deserialize_with = "whole")]
    total_tokens: Option<u64>,
    /// The dollars Open Codex estimates the request cost, where it has a price for the model.
    #[serde(default, rename = "displayMetrics", deserialize_with = "estimate")]
    cost: Option<f64>,
}

/// An entry's `displayMetrics`, of which the bridge reads one number four objects down.
fn estimate<'de, D: Deserializer<'de>>(from: D) -> Result<Option<f64>, D::Error> {
    Ok(Value::deserialize(from)?["cost"]["estimate"]["cost"]["total"].as_f64())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn conversation_ids_match_open_codex() {
        // A Prime session id and the conversation id Open Codex logged for it.
        assert_eq!(
            conversation("01a1a741-a177-717e-a671-ac8139c47b00"),
            "9632a2da6f62ee6f41b8490a792783b8"
        );
    }

    #[test]
    fn levels_follow_the_efforts_open_codex_lists() {
        let model = json!({ "id": "mistral/m", "reasoning_efforts": [{ "value": "low" }, { "value": "high" }] });
        let map = level_map(&read(&model)).unwrap();
        assert_eq!(map["low"], "low");
        assert_eq!(map["high"], "high");
        assert_eq!(map["medium"], Value::Null);
        assert_eq!(map["off"], Value::Null);
        assert!(level_map(&read(&json!({ "id": "plain" }))).is_none());
        assert_eq!(
            dsh_model(&read(&json!({ "id": "plain" }))).unwrap()["reasoningEfforts"],
            false
        );
    }

    #[test]
    fn a_served_default_moves_onto_open_codex() {
        let models: Vec<Model> = [
            json!({ "id": "mistral/deepseek-v4-1-flash-1017" }),
            json!({ "id": "gpt-6-astra" }),
            json!({ "id": "openai-apikey/gpt-5.6" }),
        ]
        .iter()
        .map(read)
        .collect();
        let mut settings =
            json!({ "defaultProvider": "mistral", "defaultModel": "deepseek-v4-1-flash-1017" });
        move_default(&mut settings, &models);
        assert_eq!(settings["defaultProvider"], PROVIDER);
        assert_eq!(settings["defaultModel"], "mistral/deepseek-v4-1-flash-1017");
        // An API-key default stays on the API key, never the subscription's bare id.
        let mut subscription =
            json!({ "defaultProvider": "openai", "defaultModel": "gpt-6-astra" });
        move_default(&mut subscription, &models);
        assert_eq!(subscription["defaultProvider"], "openai");
        let mut key = json!({ "defaultProvider": "openai", "defaultModel": "gpt-5.6" });
        move_default(&mut key, &models);
        assert_eq!(key["defaultModel"], "openai-apikey/gpt-5.6");
        let mut other = json!({ "defaultProvider": "google", "defaultModel": "gemini" });
        move_default(&mut other, &models);
        assert_eq!(other["defaultProvider"], "google");
    }

    #[test]
    fn a_default_with_mistyped_or_missing_parts_stays() {
        let models: Vec<Model> = [json!({ "id": "mistral/small" }), json!({ "id": 7 })]
            .iter()
            .map(read)
            .collect();
        for settings in [
            json!({ "defaultProvider": 3, "defaultModel": "small" }),
            json!({ "defaultProvider": "mistral", "defaultModel": ["small"] }),
            json!({ "defaultProvider": "mistral" }),
            json!({ "defaultModel": "small" }),
            json!({ "defaultProvider": PROVIDER, "defaultModel": "small" }),
            json!({ "defaultProvider": "mistral", "defaultModel": "7" }),
            json!(["mistral", "small"]),
            json!("mistral/small"),
            Value::Null,
        ] {
            let mut moved = settings.clone();
            move_default(&mut moved, &models);
            assert_eq!(moved, settings);
        }
        let mut settings =
            json!({ "defaultProvider": "mistral", "defaultModel": "small", "theme": "dark" });
        move_default(&mut settings, &models);
        assert_eq!(
            settings,
            json!({ "defaultProvider": PROVIDER, "defaultModel": "mistral/small", "theme": "dark" })
        );
    }

    fn scratch(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("shed-opencodex-test-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// A home folder with this `config.json`, where Open Codex is installed or not.
    fn home_with(config: Option<&str>, installed: bool) -> PathBuf {
        let home = scratch("gateway");
        std::fs::create_dir_all(home.join(".agent-remote")).unwrap();
        if let Some(config) = config {
            std::fs::write(home.join(".agent-remote/config.json"), config).unwrap();
        }
        if installed {
            std::fs::create_dir_all(home.join(".opencodex")).unwrap();
        }
        home
    }

    fn assert_defaults(gateway: &Gateway, home: &Path) {
        assert_eq!(gateway.url, "http://127.0.0.1:10100");
        assert_eq!(gateway.management, "http://127.0.0.1:10101");
        assert_eq!(gateway.token_file, home.join(".opencodex/admin-api-token"));
    }

    // One test, so the three share a folder without racing.
    #[test]
    fn the_gateway_is_off_unset_or_on() {
        for installed in [false, true] {
            let home = home_with(Some(r#"{ "opencodex": false }"#), installed);
            assert!(gateway_in(&home).is_none());
        }

        // Unset, or a config that can't be read: on only where Open Codex is installed.
        for config in [
            None,
            Some("{}"),
            Some(r#"{ "opencodex": null, "web": {} }"#),
            Some("not json"),
            Some("[]"),
        ] {
            assert!(gateway_in(&home_with(config, false)).is_none());
            let home = home_with(config, true);
            assert_defaults(&gateway_in(&home).unwrap(), &home);
        }

        // Anything else is on, with the default for whatever it doesn't give as text.
        for config in [
            r#"{ "opencodex": true }"#,
            r#"{ "opencodex": "yes" }"#,
            r#"{ "opencodex": 1 }"#,
            r#"{ "opencodex": ["http://gateway.test:1", "http://gateway.test:2", "/keys/admin"] }"#,
            r#"{ "opencodex": {} }"#,
            r#"{ "opencodex": { "url": 7, "managementUrl": null, "adminTokenFile": false } }"#,
        ] {
            let home = home_with(Some(config), false);
            assert_defaults(&gateway_in(&home).unwrap(), &home);
        }

        let home = home_with(
            Some(
                r#"{ "opencodex": {
                    "url": "http://gateway.test:1/",
                    "managementUrl": "http://gateway.test:2//",
                    "adminTokenFile": "/keys/admin",
                    "extra": 1
                } }"#,
            ),
            false,
        );
        let gateway = gateway_in(&home).unwrap();
        assert_eq!(gateway.url, "http://gateway.test:1");
        assert_eq!(gateway.management, "http://gateway.test:2");
        assert_eq!(gateway.token_file, PathBuf::from("/keys/admin"));
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn the_catalog_is_the_reply_s_data_less_the_claude_subscription() {
        let reply = json!({ "object": "list", "data": [
            { "id": "mistral/small", "owned_by": "mistral" },
            { "id": "anthropic/claude-one" },
            { "id": "anthropic-apikey/claude-one" },
            { "id": 7 },
            "bare",
            ["mistral/listed"],
            {},
        ]});
        assert_eq!(
            listed(&reply).unwrap(),
            [
                json!({ "id": "mistral/small", "owned_by": "mistral" }),
                json!({ "id": "anthropic-apikey/claude-one" }),
                json!({ "id": 7 }),
                json!("bare"),
                json!(["mistral/listed"]),
                json!({}),
            ]
        );
        assert!(listed(&json!({ "data": [] })).unwrap().is_empty());
        for reply in [
            json!({}),
            json!({ "data": null }),
            json!({ "data": { "id": "mistral/small" } }),
            json!({ "data": "mistral/small" }),
            json!([[{ "id": "mistral/small" }]]),
            json!("mistral/small"),
            Value::Null,
        ] {
            assert_eq!(
                listed(&reply).unwrap_err().to_string(),
                "Open Codex listed no models"
            );
        }
    }

    #[test]
    fn a_model_without_a_text_id_is_written_nowhere() {
        for model in [
            json!({ "id": 7, "context_window": 1000 }),
            json!({ "context_window": 1000 }),
            json!({ "id": null }),
            json!("mistral/small"),
            json!(["mistral/small"]),
            Value::Null,
        ] {
            assert!(agent_model(&read(&model), true).is_none(), "{model}");
            assert!(dsh_model(&read(&model)).is_none(), "{model}");
        }
    }

    #[test]
    fn a_model_s_limits_default_unless_they_are_whole_numbers() {
        let window = |listed: Value| {
            let model = json!({ "id": "m", "context_window": listed });
            let agent = agent_model(&read(&model), false).unwrap();
            let dsh = dsh_model(&read(&model)).unwrap();
            assert_eq!(agent["contextWindow"], dsh["contextWindow"]);
            agent["contextWindow"].clone()
        };
        assert_eq!(window(json!(200_000)), 200_000);
        assert_eq!(window(json!(0)), 0);
        for other in [
            json!("200000"),
            json!(200_000.0),
            json!(-1),
            json!([200_000]),
            Value::Null,
        ] {
            assert_eq!(window(other), 128_000);
        }
        assert_eq!(
            agent_model(&read(&json!({ "id": "m" })), false).unwrap()["contextWindow"],
            128_000
        );

        // The model's own limit first, then its capabilities', then the default.
        let max_tokens = |mut model: Value| {
            model["id"] = json!("m");
            let agent = agent_model(&read(&model), false).unwrap();
            let dsh = dsh_model(&read(&model)).unwrap();
            assert_eq!(agent["maxTokens"], dsh["maxTokens"]);
            agent["maxTokens"].clone()
        };
        for (model, expected) in [
            (
                json!({ "max_output_tokens": 1000, "capabilities": { "max_output_tokens": 2000 } }),
                1000,
            ),
            (
                json!({ "capabilities": { "max_output_tokens": 2000, "tools": true } }),
                2000,
            ),
            (
                json!({ "max_output_tokens": "1000", "capabilities": { "max_output_tokens": 2000 } }),
                2000,
            ),
            (
                json!({ "max_output_tokens": 1000.5, "capabilities": { "max_output_tokens": 2000 } }),
                2000,
            ),
            (
                json!({ "max_output_tokens": null, "capabilities": { "max_output_tokens": "2000" } }),
                32_768,
            ),
            (json!({ "capabilities": [2000] }), 32_768),
            (json!({ "capabilities": [[], 2000] }), 32_768),
            (json!({ "capabilities": 2000 }), 32_768),
            (json!({}), 32_768),
        ] {
            assert_eq!(max_tokens(model.clone()), expected, "{model}");
        }
    }

    #[test]
    fn a_model_takes_images_when_its_list_of_modalities_says_so() {
        let input = |capabilities: Value| {
            let model = json!({ "id": "m", "capabilities": capabilities });
            let agent = agent_model(&read(&model), false).unwrap();
            assert_eq!(agent["input"], dsh_model(&read(&model)).unwrap()["input"]);
            agent["input"].clone()
        };
        for capabilities in [
            json!({ "input_modalities": ["text", "image"] }),
            json!({ "input_modalities": [3, null, "image"], "output_modalities": ["text"] }),
        ] {
            assert_eq!(input(capabilities), json!(["text", "image"]));
        }
        for capabilities in [
            json!({ "input_modalities": ["text", "Image", ["image"]] }),
            json!({ "input_modalities": "image" }),
            json!({ "input_modalities": { "image": true } }),
            json!({ "output_modalities": ["image"] }),
            json!([["image"]]),
            json!("image"),
            Value::Null,
        ] {
            assert_eq!(
                input(capabilities.clone()),
                json!(["text"]),
                "{capabilities}"
            );
        }
    }

    #[test]
    fn efforts_are_the_listed_values_that_are_text() {
        let model = json!({ "id": "m", "reasoning_efforts": [
            { "value": "low", "label": "Low" },
            "medium",
            ["high"],
            { "value": 3 },
            { "label": "xhigh" },
            null,
            { "value": "ultra" },
            { "value": "none" },
        ]});
        assert_eq!(
            level_map(&read(&model)).unwrap(),
            json!({
                "off": "none", "minimal": null, "low": "low", "medium": null,
                "high": null, "xhigh": null, "max": null,
            })
        );
        assert_eq!(
            dsh_model(&read(&model)).unwrap()["reasoningEfforts"],
            json!({ "off": "none", "low": "low" })
        );

        // Efforts the bridge has no level for still make a reasoning model.
        let unknown = json!({ "id": "m", "reasoning_efforts": [{ "value": "ultra" }] });
        assert_eq!(
            agent_model(&read(&unknown), false).unwrap()["reasoning"],
            true
        );
        assert_eq!(
            dsh_model(&read(&unknown)).unwrap()["reasoningEfforts"],
            json!({ "off": null })
        );

        for efforts in [
            json!("low"),
            json!({ "value": "low" }),
            json!(["low", ["low"], { "value": 1 }]),
            json!([]),
            Value::Null,
        ] {
            let model = json!({ "id": "m", "reasoning_efforts": efforts });
            let agent = agent_model(&read(&model), false).unwrap();
            assert_eq!(agent["reasoning"], false, "{model}");
            assert!(agent.get("thinkingLevelMap").is_none(), "{model}");
            assert_eq!(dsh_model(&read(&model)).unwrap()["reasoningEfforts"], false);
        }
    }

    /// A catalog with a model that says everything, one that says nothing, and one the agents can't be given.
    fn small_catalog() -> Vec<Model> {
        listed(&json!({ "data": [
            {
                "id": "mistral/large",
                "object": "model",
                "context_window": 400_000,
                "max_output_tokens": 64_000,
                "capabilities": { "input_modalities": ["text", "image"], "max_output_tokens": 1 },
                "reasoning_efforts": [{ "value": "none" }, { "value": "low" }, { "value": "high" }],
            },
            { "id": "mistral/small" },
            { "id": 7 },
            { "id": "anthropic/claude-one" },
        ]}))
        .unwrap()
        .iter()
        .map(read)
        .collect()
    }

    const PI_MODELS: &str = r#"{
  "providers": {
    "mistral": {
      "baseUrl": "http://mistral.test"
    },
    "opencodex": {
      "api": "openai-responses",
      "apiKey": "unused",
      "baseUrl": "http://gateway.test/v1",
      "models": [
        {
          "compat": {
            "sessionAffinityFormat": "openai"
          },
          "contextWindow": 400000,
          "cost": {
            "cacheRead": 0,
            "cacheWrite": 0,
            "input": 0,
            "output": 0
          },
          "id": "mistral/large",
          "input": [
            "text",
            "image"
          ],
          "maxTokens": 64000,
          "name": "mistral/large",
          "reasoning": true,
          "thinkingLevelMap": {
            "high": "high",
            "low": "low",
            "max": null,
            "medium": null,
            "minimal": null,
            "off": "none",
            "xhigh": null
          }
        },
        {
          "compat": {
            "sessionAffinityFormat": "openai"
          },
          "contextWindow": 128000,
          "cost": {
            "cacheRead": 0,
            "cacheWrite": 0,
            "input": 0,
            "output": 0
          },
          "id": "mistral/small",
          "input": [
            "text"
          ],
          "maxTokens": 32768,
          "name": "mistral/small",
          "reasoning": false
        }
      ]
    }
  },
  "zeta": 1
}
"#;
    const PRIME_MODELS: &str = r#"{
  "providers": {
    "opencodex": {
      "api": "openai-responses",
      "apiKey": "unused",
      "baseUrl": "http://gateway.test/v1",
      "models": [
        {
          "contextWindow": 400000,
          "cost": {
            "cacheRead": 0,
            "cacheWrite": 0,
            "input": 0,
            "output": 0
          },
          "id": "mistral/large",
          "input": [
            "text",
            "image"
          ],
          "maxTokens": 64000,
          "name": "mistral/large",
          "reasoning": true,
          "thinkingLevelMap": {
            "high": "high",
            "low": "low",
            "max": null,
            "medium": null,
            "minimal": null,
            "off": "none",
            "xhigh": null
          }
        },
        {
          "contextWindow": 128000,
          "cost": {
            "cacheRead": 0,
            "cacheWrite": 0,
            "input": 0,
            "output": 0
          },
          "id": "mistral/small",
          "input": [
            "text"
          ],
          "maxTokens": 32768,
          "name": "mistral/small",
          "reasoning": false
        }
      ]
    }
  }
}
"#;
    const DSH_MODELS: &str = r#"[
  {
    "contextWindow": 400000,
    "id": "mistral/large",
    "input": [
      "text",
      "image"
    ],
    "maxTokens": 64000,
    "name": "mistral/large",
    "reasoningEfforts": {
      "high": "high",
      "low": "low",
      "off": "none"
    }
  },
  {
    "contextWindow": 128000,
    "id": "mistral/small",
    "input": [
      "text"
    ],
    "maxTokens": 32768,
    "name": "mistral/small",
    "reasoningEfforts": false
  }
]"#;

    #[test]
    fn sync_writes_the_catalog_into_each_agent_s_files() {
        let home = scratch("write");
        for dir in [".pi/agent", ".prime/agent", ".agent-remote"] {
            std::fs::create_dir_all(home.join(dir)).unwrap();
        }
        // Pi's files as Pi lays them out, with a provider and a default of its own; Prime has none yet.
        std::fs::write(
            home.join(".pi/agent/models.json"),
            r#"{"zeta":1,"providers":{"mistral":{"baseUrl":"http://mistral.test"}}}"#,
        )
        .unwrap();
        std::fs::write(
            home.join(".pi/agent/settings.json"),
            r#"{"theme":"dark","defaultProvider":"mistral","defaultModel":"small"}"#,
        )
        .unwrap();
        write(&home, "http://gateway.test", &small_catalog()).unwrap();
        let read = |file: &str| std::fs::read_to_string(home.join(file)).unwrap();
        assert_eq!(read(".pi/agent/models.json"), PI_MODELS);
        assert_eq!(
            read(".pi/agent/settings.json"),
            "{\n  \"defaultModel\": \"mistral/small\",\n  \"defaultProvider\": \"opencodex\",\n  \"theme\": \"dark\"\n}\n"
        );
        assert_eq!(read(".prime/agent/models.json"), PRIME_MODELS);
        assert_eq!(read(".prime/agent/settings.json"), "{}\n");
        assert_eq!(read(".agent-remote/opencodex-models.json"), DSH_MODELS);
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn a_file_the_sync_would_not_change_keeps_its_own_layout() {
        let home = scratch("layout");
        for dir in [".pi/agent", ".agent-remote"] {
            std::fs::create_dir_all(home.join(dir)).unwrap();
        }
        write(&home, "http://gateway.test", &small_catalog()).unwrap();
        // The same content on one line, as an agent might rewrite it.
        let models = home.join(".pi/agent/models.json");
        let written: Value =
            serde_json::from_str(&std::fs::read_to_string(&models).unwrap()).unwrap();
        let compact = written.to_string();
        std::fs::write(&models, &compact).unwrap();
        let settings = home.join(".pi/agent/settings.json");
        std::fs::write(
            &settings,
            r#"{"defaultProvider":"google","defaultModel":"small"}"#,
        )
        .unwrap();
        write(&home, "http://gateway.test", &small_catalog()).unwrap();
        assert_eq!(std::fs::read_to_string(&models).unwrap(), compact);
        assert_eq!(
            std::fs::read_to_string(&settings).unwrap(),
            r#"{"defaultProvider":"google","defaultModel":"small"}"#
        );
        // An agent that isn't installed gets no folder.
        assert!(!home.join(".prime").exists());
        // Neither file is a JSON object: left alone.
        std::fs::write(&models, "[1]").unwrap();
        std::fs::write(&settings, "\"dark\"").unwrap();
        write(&home, "http://gateway.test", &small_catalog()).unwrap();
        assert_eq!(std::fs::read_to_string(&models).unwrap(), "[1]");
        assert_eq!(std::fs::read_to_string(&settings).unwrap(), "\"dark\"");
        // A file that isn't JSON stops the sync.
        std::fs::write(&models, "not json").unwrap();
        assert!(write(&home, "http://gateway.test", &small_catalog()).is_err());
        let _ = std::fs::remove_dir_all(&home);
    }

    fn metered(total: Value) -> Value {
        json!({ "cost": { "estimate": { "cost": { "total": total } } } })
    }

    #[test]
    fn a_history_page_adds_its_tokens_its_cost_and_its_latest_time() {
        let mut tally = Tally {
            through: 50,
            ..Default::default()
        };
        let next = tally.add(read(&json!({
            "entries": [
                { "timestamp": 100, "totalTokens": 10, "displayMetrics": metered(json!(0.25)), "model": "mistral/small" },
                { "timestamp": 90, "totalTokens": 5, "displayMetrics": metered(json!(1)) },
                { "timestamp": 40, "totalTokens": 2 },
            ],
            "nextCursor": "page-2",
            "hasMore": true,
            "total": 3,
        })));
        assert_eq!(next.as_deref(), Some("page-2"));
        assert_eq!(
            (tally.tokens, tally.cost, tally.priced, tally.through),
            (17, 1.25, true, 100)
        );
        // An entry without a price leaves a tally unpriced.
        let mut unpriced = Tally::default();
        unpriced.add(read(
            &json!({ "entries": [{ "timestamp": 40, "totalTokens": 2 }] }),
        ));
        assert_eq!(
            (
                unpriced.tokens,
                unpriced.cost,
                unpriced.priced,
                unpriced.through
            ),
            (2, 0.0, false, 40)
        );
    }

    #[test]
    fn a_history_entry_s_mistyped_parts_count_for_nothing() {
        let mut tally = Tally {
            through: 7,
            ..Default::default()
        };
        for page in [
            json!({ "entries": [
                { "timestamp": "100", "totalTokens": 1.5, "displayMetrics": metered(json!("0.5")) },
                { "timestamp": -4, "totalTokens": null, "displayMetrics": { "cost": { "estimate": 3 } } },
                { "timestamp": 8.0, "displayMetrics": [metered(json!(0.5))] },
                { "displayMetrics": { "cost": [{ "estimate": { "cost": { "total": 0.5 } } }] } },
                { "displayMetrics": metered(Value::Null) },
                [100, 10, metered(json!(0.5))],
                "entry",
                null,
            ]}),
            json!({ "entries": { "timestamp": 100, "totalTokens": 10 } }),
            json!({ "entries": "none" }),
            json!([[{ "timestamp": 100, "totalTokens": 10 }], "page-2", true]),
            json!({}),
            Value::Null,
        ] {
            assert_eq!(tally.add(read(&page)), None, "{page}");
            assert_eq!(
                (tally.tokens, tally.cost, tally.priced, tally.through),
                (0, 0.0, false, 7),
                "{page}"
            );
        }
    }

    #[test]
    fn the_history_goes_on_only_with_a_cursor_and_more_to_come() {
        let next = |page: Value| Tally::default().add(read(&page));
        assert_eq!(
            next(json!({ "nextCursor": "page-2", "hasMore": true })).as_deref(),
            Some("page-2")
        );
        for page in [
            json!({ "nextCursor": "page-2", "hasMore": false }),
            json!({ "nextCursor": "page-2", "hasMore": "true" }),
            json!({ "nextCursor": "page-2", "hasMore": 1 }),
            json!({ "nextCursor": "page-2" }),
            json!({ "nextCursor": 2, "hasMore": true }),
            json!({ "nextCursor": null, "hasMore": true }),
            json!({ "hasMore": true }),
        ] {
            assert_eq!(next(page.clone()), None, "{page}");
        }
    }
}
