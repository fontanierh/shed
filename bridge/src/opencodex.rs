//! Open Codex, the one gateway every agent reaches its models through. Its catalog (`/v1/models`) is the list of
//! models each agent offers in Shed, nothing added and nothing left out: the bridge writes it into Pi's and Prime's
//! `models.json` as an `opencodex` provider, and into dsh's `shed` profile, and lists only that provider's models.
//! Credentials, image limits and prices live in Open Codex, so every agent gets the same ones. Its request history is
//! also the record of what each session spends: it tags every request with the session it came from.

use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use anyhow::{anyhow, Context, Result};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

use crate::store::{Addresses, Routing, Store};

pub const PROVIDER: &str = "opencodex";
/// Open Codex trusts its loopback listener, so the agents' key is a placeholder; dsh reads it from this variable.
pub const KEY: &str = "unused";
pub const KEY_ENV: &str = "SHED_OPENCODEX_KEY";

/// Where Open Codex listens: `opencodex` in ~/.agent-remote/config.json, `{url, managementUrl, adminTokenFile}`, else
/// its defaults when it's installed (~/.opencodex). `"opencodex": false` turns routing off.
pub struct Gateway {
    pub url: String,
    management: String,
    token_file: PathBuf,
}

pub fn gateway(store: &Store) -> Option<Gateway> {
    gateway_in(store, &crate::host::home())
}

// The readers in this file take what they can of what comes from outside: a part that is missing, or of another
// type than expected, reads as absent, never as an error.

fn text(value: &Value) -> Option<String> {
    value.as_str().map(str::to_string)
}

fn list(value: &Value) -> &[Value] {
    value.as_array().map(Vec::as_slice).unwrap_or_default()
}

fn gateway_in(store: &Store, home: &Path) -> Option<Gateway> {
    let ours = match store.config().opencodex {
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

async fn get(url: &str, token: Option<&str>) -> Result<Value> {
    let mut req = crate::host::http()
        .get(url)
        .timeout(Duration::from_secs(15));
    if let Some(token) = token {
        req = req.bearer_auth(token);
    }
    let response = req.send().await.map_err(|e| anyhow!("Open Codex: {e}"))?;
    let status = response.status();
    let body = response
        .bytes()
        .await
        .map_err(|e| anyhow!("Open Codex: {e}"))?;
    if !status.is_success() {
        let detail = String::from_utf8_lossy(&body);
        return Err(anyhow!("Open Codex ({status}): {}", detail.trim()));
    }
    Ok(serde_json::from_slice(&body)?)
}

/// Open Codex's provider for a Claude Pro or Max login. Its models stay out of Shed: a Claude subscription is
/// meant for Anthropic's own apps, so Claude reaches the agents through an API key alone.
const CLAUDE_SUBSCRIPTION: &str = "anthropic/";

/// The models Open Codex serves, as it lists them, less the Claude subscription's. Cached for a minute.
async fn catalog(gateway: &Gateway) -> Result<Vec<Model>> {
    static CACHE: Mutex<Option<(String, Instant, Vec<Model>)>> = Mutex::new(None);
    if let Some((url, at, models)) = CACHE.lock().unwrap().as_ref() {
        if url == &gateway.url && at.elapsed() < Duration::from_secs(60) {
            return Ok(models.clone());
        }
    }
    let reply = get(&format!("{}/v1/models", gateway.url), None).await?;
    let models: Vec<Model> = listed(&reply)?.iter().map(Model::read).collect();
    *CACHE.lock().unwrap() = Some((gateway.url.clone(), Instant::now(), models.clone()));
    Ok(models)
}

/// Open Codex's reply to `/v1/models`, with its models as it listed them.
struct Listing {
    data: Option<Vec<Value>>,
}

impl Listing {
    fn read(reply: &Value) -> Listing {
        Listing {
            data: reply["data"].as_array().cloned(),
        }
    }
}

/// A model as Open Codex's `/v1/models` lists one.
#[derive(Clone)]
struct Model {
    id: Option<String>,
    reasoning_efforts: Vec<Effort>,
    capabilities: Capabilities,
    context_window: Option<u64>,
    max_output_tokens: Option<u64>,
}

impl Model {
    fn read(model: &Value) -> Model {
        Model {
            id: text(&model["id"]),
            reasoning_efforts: list(&model["reasoning_efforts"])
                .iter()
                .map(Effort::read)
                .collect(),
            capabilities: Capabilities::read(&model["capabilities"]),
            context_window: model["context_window"].as_u64(),
            max_output_tokens: model["max_output_tokens"].as_u64(),
        }
    }
}

/// One of a listed model's `reasoning_efforts`.
#[derive(Clone)]
struct Effort {
    value: Option<String>,
}

impl Effort {
    fn read(effort: &Value) -> Effort {
        Effort {
            value: text(&effort["value"]),
        }
    }
}

/// A listed model's `capabilities`.
#[derive(Clone)]
struct Capabilities {
    input_modalities: Vec<Value>,
    max_output_tokens: Option<u64>,
}

impl Capabilities {
    fn read(capabilities: &Value) -> Capabilities {
        Capabilities {
            input_modalities: list(&capabilities["input_modalities"]).to_vec(),
            max_output_tokens: capabilities["max_output_tokens"].as_u64(),
        }
    }
}

/// The models in a `/v1/models` reply, each as Open Codex listed it, less the Claude subscription's.
fn listed(reply: &Value) -> Result<Vec<Value>> {
    Ok(Listing::read(reply)
        .data
        .ok_or_else(|| anyhow!("Open Codex listed no models"))?
        .into_iter()
        .filter(|model| offered(&Model::read(model)))
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
    let map: serde_json::Map<String, Value> = crate::agent_wire::THINKING_LEVELS
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
    let images = listed.iter().any(|m| m == "image");
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
fn dsh_catalog_file(store_dir: &Path) -> PathBuf {
    store_dir.join("opencodex-models.json")
}

/// Write the catalog into each agent's configuration, as its `opencodex` provider, and move a default model that
/// Open Codex also serves onto it. Other providers are left as they are, for the agents' own use and their older
/// sessions.
pub async fn sync(store: &Store, gateway: &Gateway) -> Result<()> {
    write(
        &crate::host::home(),
        store.dir(),
        &gateway.url,
        &catalog(gateway).await?,
    )
}

/// What `sync` writes, in the agents' folders under `home` and the bridge's `store_dir`.
fn write(home: &Path, store_dir: &Path, url: &str, models: &[Model]) -> Result<()> {
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
    write_if_changed(
        &dsh_catalog_file(store_dir),
        &serde_json::to_vec_pretty(&dsh)?,
    )
}

/// The default model in an agent's `settings.json`.
struct Chosen {
    default_provider: Option<String>,
    default_model: Option<String>,
}

impl Chosen {
    fn read(settings: &Value) -> Chosen {
        Chosen {
            default_provider: text(&settings["defaultProvider"]),
            default_model: text(&settings["defaultModel"]),
        }
    }
}

/// A default model of another provider that Open Codex serves too ("mistral" "deepseek-v4-1-flash-1017" as
/// "mistral/deepseek-v4-1-flash-1017") becomes the same model through Open Codex. The agents reach OpenAI and
/// Anthropic with API keys, which Open Codex names `openai-apikey` and `anthropic-apikey`: its bare OpenAI ids are
/// the ChatGPT subscription, a different account.
fn move_default(settings: &mut Value, models: &[Model]) {
    let Chosen {
        default_provider: Some(provider),
        default_model: Some(id),
    } = Chosen::read(settings)
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

/// Read a JSON file (an empty object only when it is missing), change it, and write it back if that changed anything.
fn update(path: &PathBuf, change: impl FnOnce(&mut Value)) -> Result<()> {
    let raw = match std::fs::read_to_string(path) {
        Ok(raw) => Some(raw),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
        Err(e) => return Err(e).with_context(|| format!("reading {}", path.display())),
    };
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
    // The agents keep some of these to their user alone, and they hold keys: a copy that can't be given the same
    // permissions never takes the file's place.
    let replaced = std::fs::metadata(path)
        .map_or(Ok(()), |old| {
            std::fs::set_permissions(&tmp, old.permissions())
        })
        .and_then(|()| std::fs::rename(&tmp, path));
    if let Err(e) = replaced {
        if let Err(left) = std::fs::remove_file(&tmp) {
            eprintln!("can't remove {}: {left}", tmp.display());
        }
        return Err(e).with_context(|| format!("replacing {}", path.display()));
    }
    Ok(())
}

/// The `llm-pi-ai` patch for dsh's `shed` profile: Open Codex as its one provider, from the catalog the last sync
/// kept. None when Open Codex isn't in use or hasn't been listed yet.
pub fn dsh_layer(store: &Store) -> Option<String> {
    let gateway = gateway(store)?;
    let models: Value =
        serde_json::from_slice(&std::fs::read(dsh_catalog_file(store.dir())).ok()?).ok()?;
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
#[derive(Debug, Default, Clone)]
pub struct Tally {
    pub cost: f64,
    pub priced: bool,
    pub tokens: u64,
    pub through: u64,
    /// When a window spans >100 pages (newest-first), holds `(since, next_cursor, newest_seen)` until drained so
    /// `through` never advances past unread older pages.
    pending: Option<(u64, String, u64)>,
}

impl Tally {
    /// Count the requests made after this tally's latest one.
    pub async fn update(&mut self, gateway: &Gateway, conversation: &str) -> Result<()> {
        let token = std::fs::read_to_string(&gateway.token_file)
            .map_err(|e| anyhow!("Open Codex admin token: {e}"))?;
        let token = token.trim();
        let (since, mut cursor, mut newest) = match self.pending.clone() {
            Some((since, cursor, newest)) => (since, Some(cursor), newest),
            None => (
                if self.through == 0 {
                    0
                } else {
                    self.through + 1
                },
                None,
                self.through,
            ),
        };
        let mut counted = self.clone();
        let mut more = false;
        for _ in 0..100 {
            let mut url = format!(
                "{}/api/request-history?limit=100&from={since}&conversationId={conversation}",
                gateway.management
            );
            if let Some(cursor) = &cursor {
                url.push_str("&cursor=");
                for b in cursor.bytes() {
                    if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~') {
                        url.push(b as char);
                    } else {
                        url.push_str(&format!("%{b:02X}"));
                    }
                }
            }
            let before = counted.through;
            counted.through = newest;
            let next = counted.add(Page::read(&get(&url, Some(token)).await?));
            newest = newest.max(counted.through);
            counted.through = before;
            match next {
                Some(next) => {
                    cursor = Some(next);
                    more = true;
                }
                None => {
                    more = false;
                    break;
                }
            }
        }
        if more {
            counted.pending = cursor.map(|c| (since, c, newest));
        } else {
            counted.pending = None;
            counted.through = newest;
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
struct Page {
    entries: Vec<Entry>,
    next_cursor: Option<String>,
    has_more: bool,
}

impl Page {
    fn read(page: &Value) -> Page {
        Page {
            entries: list(&page["entries"]).iter().map(Entry::read).collect(),
            next_cursor: text(&page["nextCursor"]),
            has_more: page["hasMore"] == true,
        }
    }
}

/// One request in the history.
struct Entry {
    timestamp: Option<u64>,
    total_tokens: Option<u64>,
    /// The dollars Open Codex estimates the request cost, where it has a price for the model.
    cost: Option<f64>,
}

impl Entry {
    fn read(entry: &Value) -> Entry {
        Entry {
            timestamp: entry["timestamp"].as_u64(),
            total_tokens: entry["totalTokens"].as_u64(),
            cost: entry["displayMetrics"]["cost"]["estimate"]["cost"]["total"].as_f64(),
        }
    }
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
        let map = level_map(&Model::read(&model)).unwrap();
        assert_eq!(map["low"], "low");
        assert_eq!(map["high"], "high");
        assert_eq!(map["medium"], Value::Null);
        assert_eq!(map["off"], Value::Null);
        assert!(level_map(&Model::read(&json!({ "id": "plain" }))).is_none());
        assert_eq!(
            dsh_model(&Model::read(&json!({ "id": "plain" }))).unwrap()["reasoningEfforts"],
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
        .map(Model::read)
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
            .map(Model::read)
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
    /// The gateway as a bridge whose folder is in `home` sees it.
    fn at(home: &Path) -> Option<Gateway> {
        gateway_in(&Store::at(home.join(".agent-remote")), home)
    }

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
            assert!(at(&home).is_none());
        }

        // Unset, or a config that can't be read and never could: on only where Open Codex is installed.
        for config in [
            None,
            Some("{}"),
            Some(r#"{ "opencodex": null, "web": {} }"#),
            Some("not json"),
            Some("[]"),
            // A mistyped entry is a broken file, not a way to turn routing on.
            Some(r#"{ "opencodex": "yes" }"#),
            Some(r#"{ "opencodex": 1 }"#),
            Some(r#"{ "opencodex": ["http://gateway.test:1"] }"#),
            Some(r#"{ "opencodex": { "url": 7 } }"#),
        ] {
            assert!(at(&home_with(config, false)).is_none());
            let home = home_with(config, true);
            assert_defaults(&at(&home).unwrap(), &home);
        }

        // `true` or an object is on, with the default for whatever it doesn't give.
        for config in [
            r#"{ "opencodex": true }"#,
            r#"{ "opencodex": {} }"#,
            r#"{ "opencodex": { "managementUrl": null } }"#,
        ] {
            let home = home_with(Some(config), false);
            assert_defaults(&at(&home).unwrap(), &home);
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
        let gateway = at(&home).unwrap();
        assert_eq!(gateway.url, "http://gateway.test:1");
        assert_eq!(gateway.management, "http://gateway.test:2");
        assert_eq!(gateway.token_file, PathBuf::from("/keys/admin"));
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn routing_turned_off_stays_off_when_the_config_breaks() {
        let home = scratch("gateway-broken");
        std::fs::create_dir_all(home.join(".agent-remote")).unwrap();
        std::fs::create_dir_all(home.join(".opencodex")).unwrap();
        let config = home.join(".agent-remote/config.json");
        // One bridge reads the file twice: its store remembers what the file last gave.
        let store = Store::at(home.join(".agent-remote"));
        std::fs::write(&config, r#"{ "opencodex": false }"#).unwrap();
        assert!(gateway_in(&store, &home).is_none());
        std::fs::write(&config, r#"{ "opencodex": false, }"#).unwrap();
        assert!(gateway_in(&store, &home).is_none());
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
            assert!(agent_model(&Model::read(&model), true).is_none(), "{model}");
            assert!(dsh_model(&Model::read(&model)).is_none(), "{model}");
        }
    }

    #[test]
    fn a_model_s_limits_default_unless_they_are_whole_numbers() {
        let window = |listed: Value| {
            let model = json!({ "id": "m", "context_window": listed });
            let agent = agent_model(&Model::read(&model), false).unwrap();
            let dsh = dsh_model(&Model::read(&model)).unwrap();
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
            agent_model(&Model::read(&json!({ "id": "m" })), false).unwrap()["contextWindow"],
            128_000
        );

        // The model's own limit first, then its capabilities', then the default.
        let max_tokens = |mut model: Value| {
            model["id"] = json!("m");
            let agent = agent_model(&Model::read(&model), false).unwrap();
            let dsh = dsh_model(&Model::read(&model)).unwrap();
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
            let agent = agent_model(&Model::read(&model), false).unwrap();
            assert_eq!(
                agent["input"],
                dsh_model(&Model::read(&model)).unwrap()["input"]
            );
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
            level_map(&Model::read(&model)).unwrap(),
            json!({
                "off": "none", "minimal": null, "low": "low", "medium": null,
                "high": null, "xhigh": null, "max": null,
            })
        );
        assert_eq!(
            dsh_model(&Model::read(&model)).unwrap()["reasoningEfforts"],
            json!({ "off": "none", "low": "low" })
        );

        // Efforts the bridge has no level for still make a reasoning model.
        let unknown = json!({ "id": "m", "reasoning_efforts": [{ "value": "ultra" }] });
        assert_eq!(
            agent_model(&Model::read(&unknown), false).unwrap()["reasoning"],
            true
        );
        assert_eq!(
            dsh_model(&Model::read(&unknown)).unwrap()["reasoningEfforts"],
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
            let agent = agent_model(&Model::read(&model), false).unwrap();
            assert_eq!(agent["reasoning"], false, "{model}");
            assert!(agent.get("thinkingLevelMap").is_none(), "{model}");
            assert_eq!(
                dsh_model(&Model::read(&model)).unwrap()["reasoningEfforts"],
                false
            );
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
        .map(Model::read)
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
        write(
            &home,
            &home.join(".agent-remote"),
            "http://gateway.test",
            &small_catalog(),
        )
        .unwrap();
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
        write(
            &home,
            &home.join(".agent-remote"),
            "http://gateway.test",
            &small_catalog(),
        )
        .unwrap();
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
        write(
            &home,
            &home.join(".agent-remote"),
            "http://gateway.test",
            &small_catalog(),
        )
        .unwrap();
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
        write(
            &home,
            &home.join(".agent-remote"),
            "http://gateway.test",
            &small_catalog(),
        )
        .unwrap();
        assert_eq!(std::fs::read_to_string(&models).unwrap(), "[1]");
        assert_eq!(std::fs::read_to_string(&settings).unwrap(), "\"dark\"");
        // A file that isn't JSON stops the sync.
        std::fs::write(&models, "not json").unwrap();
        assert!(write(
            &home,
            &home.join(".agent-remote"),
            "http://gateway.test",
            &small_catalog()
        )
        .is_err());
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
        let next = tally.add(Page::read(&json!({
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
        unpriced.add(Page::read(
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
            assert_eq!(tally.add(Page::read(&page)), None, "{page}");
            assert_eq!(
                (tally.tokens, tally.cost, tally.priced, tally.through),
                (0, 0.0, false, 7),
                "{page}"
            );
        }
    }

    #[test]
    fn the_history_goes_on_only_with_a_cursor_and_more_to_come() {
        let next = |page: Value| Tally::default().add(Page::read(&page));
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
