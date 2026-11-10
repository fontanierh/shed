//! Open Codex, the one gateway every agent reaches its models through. Its catalog (`/v1/models`) is the list of
//! models each agent offers in Shed, nothing added and nothing left out: the bridge writes it into Pi's and Prime's
//! `models.json` as an `opencodex` provider, and into dsh's `shed` profile, and lists only that provider's models.
//! Credentials, image limits and prices live in Open Codex, so every agent gets the same ones. Its request history is
//! also the record of what each session spends: it tags every request with the session it came from.

use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use anyhow::{anyhow, Result};
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
    let config: Value = std::fs::read_to_string(home().join(".agent-remote/config.json"))
        .ok()
        .and_then(|raw| serde_json::from_str(&raw).ok())
        .unwrap_or_default();
    let ours = &config["opencodex"];
    if ours == &json!(false) || (ours.is_null() && !home().join(".opencodex").is_dir()) {
        return None;
    }
    let text = |key: &str, default: &str| ours[key].as_str().unwrap_or(default).trim_end_matches('/').to_string();
    Some(Gateway {
        url: text("url", "http://127.0.0.1:10100"),
        management: text("managementUrl", "http://127.0.0.1:10101"),
        token_file: ours["adminTokenFile"]
            .as_str()
            .map(PathBuf::from)
            .unwrap_or_else(|| home().join(".opencodex/admin-api-token")),
    })
}

/// GET a JSON document. The admin token goes in on stdin, never in the arguments, where `ps` would show it.
async fn get(url: &str, token: Option<&str>) -> Result<Value> {
    let mut child = tokio::process::Command::new("/usr/bin/curl")
        .args(["-sS", "--fail-with-body", "--max-time", "15", "-K", "-", url])
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
    let listed = get(&format!("{}/v1/models", gateway.url), None).await?;
    let models = listed["data"]
        .as_array()
        .cloned()
        .ok_or_else(|| anyhow!("Open Codex listed no models"))?
        .into_iter()
        .filter(offered)
        .collect::<Vec<_>>();
    *CACHE.lock().unwrap() = Some((Instant::now(), models.clone()));
    Ok(models)
}

fn offered(model: &Value) -> bool {
    !model["id"].as_str().unwrap_or_default().starts_with(CLAUDE_SUBSCRIPTION)
}

/// The reasoning efforts a model takes, as Open Codex names them.
fn efforts(model: &Value) -> Vec<String> {
    model["reasoning_efforts"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|e| e["value"].as_str().map(str::to_string))
        .collect()
}

/// Each Pi thinking level and the effort it sends: the same name when the model takes it, otherwise none.
fn level_map(model: &Value) -> Option<Value> {
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

fn input(model: &Value) -> Value {
    let listed = &model["capabilities"]["input_modalities"];
    let images = listed
        .as_array()
        .is_some_and(|m| m.iter().any(|m| m == "image"));
    json!(if images { vec!["text", "image"] } else { vec!["text"] })
}

fn window(model: &Value) -> u64 {
    model["context_window"].as_u64().unwrap_or(128_000)
}

fn max_tokens(model: &Value) -> u64 {
    model["max_output_tokens"]
        .as_u64()
        .or_else(|| model["capabilities"]["max_output_tokens"].as_u64())
        .unwrap_or(32_768)
}

/// A model as Pi's and Prime's `models.json` define one. Its price stays at zero: Open Codex keeps the prices and
/// reports what each session spends.
fn agent_model(model: &Value, session_header: bool) -> Option<Value> {
    let id = model["id"].as_str()?;
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
fn dsh_model(model: &Value) -> Option<Value> {
    let id = model["id"].as_str()?;
    let efforts = efforts(model);
    let reasoning = if efforts.is_empty() {
        json!(false)
    } else {
        let mut map = serde_json::Map::new();
        map.insert("off".into(), if efforts.iter().any(|e| e == "none") { json!("none") } else { Value::Null });
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
fn dsh_catalog_file() -> PathBuf {
    home().join(".agent-remote/opencodex-models.json")
}

/// Write the catalog into each agent's configuration, as its `opencodex` provider, and move a default model that
/// Open Codex also serves onto it. Other providers are left as they are, for the agents' own use and their older
/// sessions. Returns the catalog.
pub async fn sync(gateway: &Gateway) -> Result<Vec<Value>> {
    let models = catalog(gateway).await?;
    for (agent, session_header) in [(".pi/agent", true), (".prime/agent", false)] {
        let dir = home().join(agent);
        if !dir.is_dir() {
            continue;
        }
        let entries: Vec<Value> = models
            .iter()
            .filter_map(|m| agent_model(m, session_header))
            .collect();
        let provider = json!({
            "baseUrl": format!("{}/v1", gateway.url),
            "api": "openai-responses",
            "apiKey": KEY,
            "models": entries,
        });
        update(&dir.join("models.json"), |config| {
            config["providers"][PROVIDER] = provider.clone();
        })?;
        update(&dir.join("settings.json"), |settings| {
            move_default(settings, &models)
        })?;
    }
    let dsh: Vec<Value> = models.iter().filter_map(dsh_model).collect();
    write_if_changed(&dsh_catalog_file(), &serde_json::to_vec_pretty(&dsh)?)?;
    Ok(models)
}

/// A default model of another provider that Open Codex serves too ("mistral" "deepseek-v4-1-flash-1017" as
/// "mistral/deepseek-v4-1-flash-1017") becomes the same model through Open Codex. The agents reach OpenAI and
/// Anthropic with API keys, which Open Codex names `openai-apikey` and `anthropic-apikey`: its bare OpenAI ids are
/// the ChatGPT subscription, a different account.
fn move_default(settings: &mut Value, models: &[Value]) {
    let (Some(provider), Some(id)) = (
        settings["defaultProvider"].as_str(),
        settings["defaultModel"].as_str(),
    ) else {
        return;
    };
    if provider == PROVIDER {
        return;
    }
    let namespace = match provider {
        "openai" => "openai-apikey",
        "anthropic" => "anthropic-apikey",
        other => other,
    };
    let target = format!("{namespace}/{id}");
    let target = models.iter().any(|m| m["id"] == target.as_str()).then_some(target);
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
    let models: Value = serde_json::from_slice(&std::fs::read(dsh_catalog_file()).ok()?).ok()?;
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
    Some(format!("- id: llm-pi-ai\n  config:\n    providers: {providers}\n"))
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
        let since = if self.through == 0 { 0 } else { self.through + 1 };
        let mut cursor: Option<String> = None;
        let mut latest = self.through;
        // Added up apart and kept only when every page came: a failed page leaves the tally as it was, so the next
        // try doesn't count the first pages twice.
        let (mut tokens, mut cost, mut priced) = (self.tokens, self.cost, self.priced);
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
            let page = get(&url, Some(token)).await?;
            for entry in page["entries"].as_array().into_iter().flatten() {
                latest = latest.max(entry["timestamp"].as_u64().unwrap_or(0));
                tokens += entry["totalTokens"].as_u64().unwrap_or(0);
                if let Some(entry_cost) = entry["displayMetrics"]["cost"]["estimate"]["cost"]["total"].as_f64() {
                    cost += entry_cost;
                    priced = true;
                }
            }
            match page["nextCursor"].as_str() {
                Some(next) if page["hasMore"] == true => cursor = Some(next.to_string()),
                _ => break,
            }
        }
        (self.tokens, self.cost, self.priced, self.through) = (tokens, cost, priced, latest);
        Ok(())
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
        let map = level_map(&model).unwrap();
        assert_eq!(map["low"], "low");
        assert_eq!(map["high"], "high");
        assert_eq!(map["medium"], Value::Null);
        assert_eq!(map["off"], Value::Null);
        assert!(level_map(&json!({ "id": "plain" })).is_none());
        assert_eq!(dsh_model(&json!({ "id": "plain" })).unwrap()["reasoningEfforts"], false);
    }

    #[test]
    fn a_served_default_moves_onto_open_codex() {
        let models = vec![
            json!({ "id": "mistral/deepseek-v4-1-flash-1017" }),
            json!({ "id": "gpt-6-astra" }),
            json!({ "id": "openai-apikey/gpt-5.6" }),
        ];
        let mut settings = json!({ "defaultProvider": "mistral", "defaultModel": "deepseek-v4-1-flash-1017" });
        move_default(&mut settings, &models);
        assert_eq!(settings["defaultProvider"], PROVIDER);
        assert_eq!(settings["defaultModel"], "mistral/deepseek-v4-1-flash-1017");
        // An API-key default stays on the API key, never the subscription's bare id.
        let mut subscription = json!({ "defaultProvider": "openai", "defaultModel": "gpt-6-astra" });
        move_default(&mut subscription, &models);
        assert_eq!(subscription["defaultProvider"], "openai");
        let mut key = json!({ "defaultProvider": "openai", "defaultModel": "gpt-5.6" });
        move_default(&mut key, &models);
        assert_eq!(key["defaultModel"], "openai-apikey/gpt-5.6");
        let mut other = json!({ "defaultProvider": "google", "defaultModel": "gemini" });
        move_default(&mut other, &models);
        assert_eq!(other["defaultProvider"], "google");
    }
}
