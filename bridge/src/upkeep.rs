//! What a newly listed model takes. Open Codex finds a provider's new models within the hour, but learns their
//! reasoning efforts and whether they read images from its own releases, which trail a launch by days. Until then
//! it lists the model bare, and Shed offers it with no effort and no attachments. The provider knows from the
//! first day, so the bridge asks it, through Open Codex: one small request with a picture, and one per effort the
//! provider's other models take. What the provider accepted goes into Open Codex's own model settings, where every
//! agent and Open Codex's other clients read it.
//!
//! Only a model nobody has described is touched: one Open Codex lists without efforts or inputs and that has no
//! setting of its own there. A model Shed has described is not looked at again; clear its setting in Open Codex to
//! have it checked afresh.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::atomic::Ordering;
use std::time::Duration;

use anyhow::{anyhow, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::opencodex::{self, Gateway};

/// The efforts worth trying, lowest first. A provider's adapter may quietly fold a name it doesn't know into one
/// it does, so only the names the provider's described models already take are tried.
const EFFORTS: [&str; 7] = ["none", "minimal", "low", "medium", "high", "xhigh", "max"];
/// Providers whose models Open Codex doesn't let anyone describe.
const FIXED: [&str; 2] = ["openai", "combo"];
/// A question that takes a little working out, so a model that reasons shows it in what it counts.
const QUESTION: &str = "A farmer has 17 rows of 23 trees and removes every fifth tree. How many remain? Reply with the number only.";
/// A red square, 32 pixels a side.
const RED: &str = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAJ0lEQVR42u3NsQkAAAjAsP7/tF7hIASyp6lTCQQCgUAgEAgEgi/BAjLD/C5w/SM9AAAAAElFTkSuQmCC";
/// Models looked at in one pass: a provider that lists many at once is worked through over a few passes.
const PER_PASS: usize = 2;
const HOUR: u64 = 3600;
const WEEK: u64 = 7 * 24 * HOUR;

/// The two things the bridge does with Open Codex here, apart so the tests can stand in for it.
pub(crate) trait Desk {
    /// Change one model's settings: `reasoningEfforts` and `inputModalities`, null to clear.
    async fn set(&self, provider: &str, model: &str, change: Value) -> Result<()>;
    /// Ask a model something, and return the status with the answer.
    async fn ask(&self, request: Value) -> Result<(u16, Value)>;
}

impl Desk for Gateway {
    async fn set(&self, provider: &str, model: &str, change: Value) -> Result<()> {
        let mut body = json!({ "provider": provider, "modelId": model });
        for (key, value) in change.as_object().into_iter().flatten() {
            body[key] = value.clone();
        }
        let token = opencodex::admin_token(self)?;
        let url = format!("{}/api/model-settings", self.management);
        let (status, answer) = opencodex::send("PUT", &url, Some(&token), &body).await?;
        if status != 200 {
            return Err(anyhow!("Open Codex model settings: {status} {answer}"));
        }
        Ok(())
    }

    async fn ask(&self, request: Value) -> Result<(u16, Value)> {
        opencodex::send(
            "POST",
            &format!("{}/v1/responses", self.url),
            None,
            &request,
        )
        .await
    }
}

/// How one request came back.
#[derive(Debug, PartialEq)]
enum Answer {
    /// Answered, with the reasoning tokens it counted.
    Taken { reasoning: u64, text: String },
    /// The provider turned the request down as it was put.
    Refused(String),
    /// Nothing to conclude from: a limit, an outage, no answer.
    Unclear(String),
}

fn answer(result: Result<(u16, Value)>) -> Answer {
    let (status, body) = match result {
        Ok(got) => got,
        Err(e) => return Answer::Unclear(e.to_string()),
    };
    let why = || {
        let message = body["error"]["message"].as_str().unwrap_or_default();
        format!("{status} {}", message.chars().take(200).collect::<String>())
    };
    match status {
        200 if body["error"].is_null() && body["status"] != "failed" => Answer::Taken {
            reasoning: body["usage"]["output_tokens_details"]["reasoning_tokens"]
                .as_u64()
                .unwrap_or(0),
            text: body["output"]
                .as_array()
                .into_iter()
                .flatten()
                .flat_map(|item| item["content"].as_array().into_iter().flatten())
                .filter_map(|part| part["text"].as_str())
                .collect(),
        },
        400 | 422 => Answer::Refused(why()),
        _ => Answer::Unclear(why()),
    }
}

fn request(id: &str, effort: Option<&str>, picture: bool) -> Value {
    let mut request = json!({
        "model": id,
        "input": QUESTION,
        "max_output_tokens": 1024,
        "stream": false,
        "store": false,
    });
    if let Some(effort) = effort {
        request["reasoning"] = json!({ "effort": effort });
    }
    if picture {
        request["input"] = json!([{ "role": "user", "content": [
            { "type": "input_text", "text": "What single colour fills this image? Reply with the colour's name only." },
            { "type": "input_image", "image_url": RED },
        ]}]);
    }
    request
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
enum Outcome {
    /// Efforts, images or both were written into Open Codex.
    Described,
    /// The model answers, and takes neither efforts nor images as far as the provider shows.
    Plain,
    /// The provider turns down even a plain request through Open Codex.
    Unusable,
    /// Not known yet: tried again later.
    Unclear,
}

/// What a look at one model found.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
struct Finding {
    outcome: Outcome,
    #[serde(default)]
    efforts: Vec<String>,
    #[serde(default)]
    images: bool,
    #[serde(default)]
    note: String,
    #[serde(default)]
    at: u64,
    #[serde(default)]
    tries: u32,
}

impl Finding {
    fn of(outcome: Outcome, note: impl Into<String>) -> Self {
        Finding {
            outcome,
            efforts: Vec::new(),
            images: false,
            note: note.into(),
            at: 0,
            tries: 0,
        }
    }

    /// When the model is worth another look, while Open Codex still lists it bare. An unclear answer is tried again
    /// within the hour, then less and less often; a settled one once a week, in case the provider has moved.
    fn due(&self, now: u64) -> bool {
        let wait = match self.outcome {
            Outcome::Unclear => (HOUR << self.tries.min(8)).min(WEEK),
            _ => WEEK,
        };
        now >= self.at + wait
    }
}

/// Look at one model. Every effort is tried alone: with several listed, Open Codex answers a refused one by
/// sending the next one down, and the refusal would never show. The model is left with what was found, or as it
/// was; an error means the last change didn't go through, and the caller keeps the model marked to be put right.
async fn examine(
    desk: &impl Desk,
    id: &str,
    provider: &str,
    model: &str,
    rungs: &[String],
) -> Result<Finding> {
    match answer(desk.ask(request(id, None, false)).await) {
        Answer::Taken { .. } => {}
        Answer::Refused(why) => return Ok(Finding::of(Outcome::Unusable, why)),
        Answer::Unclear(why) => return Ok(Finding::of(Outcome::Unclear, why)),
    }
    // A model that can't see the picture refuses it, or guesses: only the right colour counts.
    let images = match answer(desk.ask(request(id, None, true)).await) {
        Answer::Taken { text, .. } => text.to_lowercase().contains("red"),
        Answer::Refused(_) => false,
        Answer::Unclear(why) => return Ok(Finding::of(Outcome::Unclear, why)),
    };
    let efforts = |efforts: Value| json!({ "reasoningEfforts": efforts });
    let mut taken = Vec::new();
    let mut reasons = false;
    for rung in rungs {
        desk.set(provider, model, efforts(json!([rung]))).await?;
        match answer(desk.ask(request(id, Some(rung), false)).await) {
            Answer::Taken { reasoning, .. } => {
                reasons |= reasoning > 0;
                taken.push(rung.clone());
            }
            Answer::Refused(_) => {}
            Answer::Unclear(why) => {
                desk.set(provider, model, efforts(Value::Null)).await?;
                return Ok(Finding::of(Outcome::Unclear, why));
            }
        }
    }
    // An accepted effort proves little alone, since some providers ignore what they don't know. One that was
    // accepted and reasoned with does.
    if !reasons {
        taken.clear();
    }
    if !rungs.is_empty() {
        let kept = if taken.is_empty() {
            Value::Null
        } else {
            json!(taken)
        };
        desk.set(provider, model, efforts(kept)).await?;
    }
    if images {
        let inputs = json!({ "inputModalities": ["text", "image"] });
        desk.set(provider, model, inputs).await?;
    }
    let outcome = if images || !taken.is_empty() {
        Outcome::Described
    } else {
        Outcome::Plain
    };
    let note = if rungs.is_empty() {
        "no described model of this provider to take efforts from"
    } else {
        ""
    };
    Ok(Finding {
        efforts: taken,
        images,
        ..Finding::of(outcome, note)
    })
}

/// A model to look at: its id in the catalog, and the provider and id Open Codex's settings know it by.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
struct Target {
    id: String,
    provider: String,
    model: String,
}

/// Listed with nothing said about it: no efforts, no reasoning, no inputs.
fn bare(model: &Value) -> bool {
    let capabilities = &model["capabilities"];
    opencodex::efforts(model).is_empty()
        && capabilities["supports_reasoning"] != true
        && capabilities["input_modalities"].is_null()
}

/// The bare models nobody has described, each with the efforts to try: those its provider's other models take.
/// `rows` is Open Codex's own list (`/api/models`), which names each model's provider and says whether someone
/// has set it by hand.
fn targets(catalog: &[Value], rows: &[Value]) -> Vec<(Target, Vec<String>)> {
    let row = |id: &str| rows.iter().find(|row| row["namespaced"] == id);
    let provider = |id: &str| row(id).and_then(|row| row["provider"].as_str());
    catalog
        .iter()
        .filter(|model| bare(model))
        .filter_map(|model| {
            let id = model["id"].as_str()?;
            let row = row(id)?;
            let target = Target {
                id: id.to_string(),
                provider: row["provider"].as_str()?.to_string(),
                model: row["id"].as_str()?.to_string(),
            };
            let set_by_hand =
                row["reasoningOverridden"] == true || !row["inputModalitiesDeclared"].is_null();
            if set_by_hand || FIXED.contains(&target.provider.as_str()) {
                return None;
            }
            let siblings: Vec<String> = catalog
                .iter()
                .filter(|other| {
                    other["id"].as_str().and_then(provider) == Some(target.provider.as_str())
                })
                .flat_map(opencodex::efforts)
                .collect();
            let rungs = EFFORTS
                .iter()
                .filter(|effort| siblings.iter().any(|s| s == *effort))
                .map(|effort| effort.to_string())
                .collect();
            Some((target, rungs))
        })
        .collect()
}

/// What has been looked at, kept across restarts in `~/.agent-remote/catalog-checks.json`.
#[derive(Debug, Default, Serialize, Deserialize)]
struct Checks {
    /// The model whose efforts are being tried right now. Still set at the next pass, the bridge stopped half way
    /// and the model may be left with a single effort: its setting is cleared before anything else.
    #[serde(default)]
    trying: Option<Target>,
    #[serde(default)]
    models: BTreeMap<String, Finding>,
}

fn checks_file() -> PathBuf {
    PathBuf::from(std::env::var("HOME").unwrap_or_default())
        .join(".agent-remote/catalog-checks.json")
}

fn load(path: &PathBuf) -> Checks {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|raw| serde_json::from_str(&raw).ok())
        .unwrap_or_default()
}

fn save(path: &PathBuf, checks: &Checks) -> Result<()> {
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, serde_json::to_vec_pretty(checks)?)?;
    std::fs::rename(&tmp, path)?;
    Ok(())
}

fn now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// One pass: put right a model left half tried, then look at the bare models that are due. Returns whether
/// Open Codex's settings changed.
async fn pass(
    desk: &impl Desk,
    catalog: &[Value],
    rows: &[Value],
    path: &PathBuf,
    now: u64,
) -> Result<bool> {
    let mut checks = load(path);
    let mut changed = false;
    if let Some(left) = checks.trying.clone() {
        desk.set(
            &left.provider,
            &left.model,
            json!({ "reasoningEfforts": null }),
        )
        .await?;
        checks.trying = None;
        save(path, &checks)?;
        changed = true;
    }
    let due = targets(catalog, rows)
        .into_iter()
        .filter(|(target, _)| checks.models.get(&target.id).is_none_or(|f| f.due(now)))
        .take(PER_PASS)
        .collect::<Vec<_>>();
    for (target, rungs) in due {
        checks.trying = Some(target.clone());
        save(path, &checks)?;
        let found = examine(desk, &target.id, &target.provider, &target.model, &rungs).await?;
        checks.trying = None;
        let tries = match (found.outcome, checks.models.get(&target.id)) {
            (Outcome::Unclear, Some(before)) if before.outcome == Outcome::Unclear => {
                before.tries + 1
            }
            _ => 0,
        };
        eprintln!("Open Codex catalog: {} {}", target.id, describe(&found));
        changed |= found.outcome == Outcome::Described;
        checks.models.insert(
            target.id,
            Finding {
                at: now,
                tries,
                ..found
            },
        );
        save(path, &checks)?;
    }
    Ok(changed)
}

fn describe(found: &Finding) -> String {
    match found.outcome {
        Outcome::Described => {
            let efforts = if found.efforts.is_empty() {
                "no reasoning effort".to_string()
            } else {
                format!("efforts {}", found.efforts.join(", "))
            };
            let images = if found.images { "images" } else { "no images" };
            format!("takes {efforts} and {images}: written into Open Codex")
        }
        Outcome::Plain => format!("takes no effort and no images {}", found.note)
            .trim()
            .to_string(),
        Outcome::Unusable => format!("can't be used through Open Codex: {}", found.note),
        Outcome::Unclear => format!("couldn't be checked, will try again: {}", found.note),
    }
}

/// Holds the agents' catalog still for as long as it lives, however the pass ends.
struct Trying;

impl Trying {
    fn start() -> Self {
        opencodex::TRYING.store(true, Ordering::Relaxed);
        Trying
    }
}

impl Drop for Trying {
    fn drop(&mut self) {
        opencodex::TRYING.store(false, Ordering::Relaxed);
    }
}

/// Look at Open Codex's catalog now, and describe the models it lists bare.
async fn run(gateway: &Gateway) -> Result<()> {
    opencodex::forget_catalog();
    let catalog = opencodex::catalog(gateway).await?;
    let path = checks_file();
    if !catalog.iter().any(bare) && load(&path).trying.is_none() {
        return Ok(());
    }
    let token = opencodex::admin_token(gateway)?;
    let rows = opencodex::get(&format!("{}/api/models", gateway.management), Some(&token)).await?;
    let rows = rows.as_array().cloned().unwrap_or_default();
    // The agents keep the catalog as it was read above while single efforts come and go in Open Codex.
    let changed = {
        let _trying = Trying::start();
        pass(gateway, &catalog, &rows, &path, now()).await
    };
    if changed? {
        opencodex::forget_catalog();
        opencodex::sync(gateway).await?;
    }
    Ok(())
}

/// Keep at it for as long as the bridge runs: soon after it starts, then every half hour, about as often as
/// Open Codex looks for new models.
pub async fn keep() {
    tokio::time::sleep(Duration::from_secs(90)).await;
    loop {
        if let Some(gateway) = opencodex::gateway().filter(|gateway| gateway.upkeep) {
            if let Err(e) = run(&gateway).await {
                eprintln!("Open Codex catalog upkeep: {e}");
            }
        }
        tokio::time::sleep(Duration::from_secs(30 * 60)).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    /// Open Codex with one provider behind it: which efforts the provider accepts, how many reasoning tokens each
    /// spends, and what it does with a picture. Every setting written is kept, in order.
    #[derive(Default)]
    struct Fake {
        accepts: Vec<(&'static str, u64)>,
        sees: bool,
        plain: u16,
        limited_at: Option<&'static str>,
        sets: Mutex<Vec<Value>>,
    }

    impl Fake {
        fn sets(&self) -> Vec<Value> {
            self.sets.lock().unwrap().clone()
        }
    }

    fn taken(reasoning: u64, text: &str) -> (u16, Value) {
        (
            200,
            json!({
                "status": "completed",
                "output": [{ "type": "message", "content": [{ "type": "output_text", "text": text }] }],
                "usage": { "output_tokens_details": { "reasoning_tokens": reasoning } },
            }),
        )
    }

    fn refused(why: &str) -> (u16, Value) {
        (400, json!({ "error": { "message": why } }))
    }

    impl Desk for Fake {
        async fn set(&self, _: &str, _: &str, change: Value) -> Result<()> {
            self.sets.lock().unwrap().push(change);
            Ok(())
        }

        async fn ask(&self, request: Value) -> Result<(u16, Value)> {
            if request["input"].is_array() {
                return Ok(if self.sees {
                    taken(0, "Red")
                } else {
                    refused("Image input is not enabled for this model")
                });
            }
            let Some(effort) = request["reasoning"]["effort"].as_str() else {
                return Ok(match self.plain {
                    200 => taken(0, "313"),
                    status => (status, json!({ "error": { "message": "not served here" } })),
                });
            };
            // Open Codex sends the effort only when it is the one listed for the model.
            let listed = self.sets().last().cloned().unwrap_or_default();
            assert_eq!(listed["reasoningEfforts"], json!([effort]));
            if self.limited_at == Some(effort) {
                return Ok((429, json!({ "error": { "message": "slow down" } })));
            }
            Ok(
                match self.accepts.iter().find(|(name, _)| *name == effort) {
                    Some((_, reasoning)) => taken(*reasoning, "313"),
                    None => refused("Thinking level is not supported for this model"),
                },
            )
        }
    }

    fn rungs(names: &[&str]) -> Vec<String> {
        names.iter().map(|name| name.to_string()).collect()
    }

    async fn look(fake: &Fake, names: &[&str]) -> Finding {
        examine(fake, "google/new", "google", "new", &rungs(names))
            .await
            .unwrap()
    }

    #[tokio::test]
    async fn a_new_model_keeps_the_efforts_its_provider_accepts() {
        let fake = Fake {
            accepts: vec![("low", 0), ("medium", 283), ("high", 900)],
            sees: true,
            plain: 200,
            ..Fake::default()
        };
        let found = look(&fake, &["minimal", "low", "medium", "high"]).await;
        assert_eq!(found.outcome, Outcome::Described);
        assert_eq!(found.efforts, ["low", "medium", "high"]);
        assert!(found.images);
        let sets = fake.sets();
        // Each effort alone, then the ones that held, then the picture.
        assert_eq!(sets.len(), 6);
        assert_eq!(
            sets[4],
            json!({ "reasoningEfforts": ["low", "medium", "high"] })
        );
        assert_eq!(sets[5], json!({ "inputModalities": ["text", "image"] }));
    }

    #[tokio::test]
    async fn efforts_accepted_without_any_reasoning_are_not_kept() {
        let fake = Fake {
            accepts: vec![("low", 0), ("medium", 0), ("high", 0)],
            plain: 200,
            ..Fake::default()
        };
        let found = look(&fake, &["low", "medium", "high"]).await;
        assert_eq!(found.outcome, Outcome::Plain);
        assert!(found.efforts.is_empty());
        assert_eq!(
            fake.sets().last().unwrap(),
            &json!({ "reasoningEfforts": null })
        );
    }

    #[tokio::test]
    async fn a_model_that_answers_nothing_is_left_alone() {
        let fake = Fake {
            accepts: vec![("low", 50)],
            sees: true,
            plain: 400,
            ..Fake::default()
        };
        let found = look(&fake, &["low"]).await;
        assert_eq!(found.outcome, Outcome::Unusable);
        assert!(fake.sets().is_empty());
        // An outage is not a refusal: nothing is concluded, and nothing written.
        let down = Fake {
            plain: 503,
            ..Fake::default()
        };
        assert_eq!(look(&down, &["low"]).await.outcome, Outcome::Unclear);
        assert!(down.sets().is_empty());
    }

    #[tokio::test]
    async fn a_limit_half_way_puts_the_model_back() {
        let fake = Fake {
            accepts: vec![("low", 10), ("medium", 20)],
            plain: 200,
            limited_at: Some("medium"),
            ..Fake::default()
        };
        let found = look(&fake, &["low", "medium", "high"]).await;
        assert_eq!(found.outcome, Outcome::Unclear);
        assert_eq!(
            fake.sets().last().unwrap(),
            &json!({ "reasoningEfforts": null })
        );
    }

    #[tokio::test]
    async fn a_picture_alone_is_written_when_there_is_no_effort_to_try() {
        let fake = Fake {
            sees: true,
            plain: 200,
            ..Fake::default()
        };
        let found = look(&fake, &[]).await;
        assert_eq!(found.outcome, Outcome::Described);
        assert_eq!(
            fake.sets(),
            [json!({ "inputModalities": ["text", "image"] })]
        );
    }

    fn listed() -> (Vec<Value>, Vec<Value>) {
        let efforts = |names: &[&str]| -> Value {
            names.iter().map(|name| json!({ "value": name })).collect()
        };
        let known = |id: &str, names: &[&str]| {
            json!({ "id": id, "reasoning_efforts": efforts(names),
                "capabilities": { "supports_reasoning": true, "input_modalities": ["text", "image"] } })
        };
        let unknown =
            |id: &str| json!({ "id": id, "capabilities": { "supports_reasoning": false } });
        let catalog = vec![
            known("google/argon", &["low", "medium", "high"]),
            known("google/flash", &["minimal", "low", "medium", "high"]),
            unknown("google/carbon"),
            unknown("google/pinned"),
            unknown("gpt-new"),
            unknown("fireworks/routers/fast"),
            known("mistral/large", &["none", "high", "ultra"]),
            json!({ "id": "mistral/small", "capabilities": { "supports_reasoning": false, "input_modalities": ["text"] } }),
        ];
        let row = |provider: &str, id: &str, namespaced: &str| json!({ "provider": provider, "id": id, "namespaced": namespaced });
        let mut pinned = row("google", "pinned", "google/pinned");
        pinned["reasoningOverridden"] = json!(true);
        let rows = vec![
            row("google", "argon", "google/argon"),
            row("google", "flash", "google/flash"),
            row("google", "carbon", "google/carbon"),
            pinned,
            row("openai", "gpt-new", "gpt-new"),
            row("fireworks", "routers/fast", "fireworks/routers/fast"),
            row("mistral", "large", "mistral/large"),
            row("mistral", "small", "mistral/small"),
        ];
        (catalog, rows)
    }

    #[test]
    fn only_bare_models_nobody_described_are_looked_at() {
        let (catalog, rows) = listed();
        let found = targets(&catalog, &rows);
        let ids: Vec<&str> = found.iter().map(|(t, _)| t.id.as_str()).collect();
        // Not the one set by hand, not OpenAI's (its settings are fixed), not the one listed as text only.
        assert_eq!(ids, ["google/carbon", "fireworks/routers/fast"]);
        // The efforts of the provider's other models, lowest first, and none where it has no other.
        assert_eq!(found[0].1, ["minimal", "low", "medium", "high"]);
        assert_eq!(found[0].0.model, "carbon");
        assert_eq!(found[1].0.model, "routers/fast");
        assert!(found[1].1.is_empty());
    }

    #[tokio::test]
    async fn a_pass_describes_a_model_once_and_cleans_up_after_a_crash() {
        let dir = std::env::temp_dir().join(format!("shed-upkeep-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("catalog-checks.json");
        let (catalog, rows) = listed();
        let fake = Fake {
            accepts: vec![("low", 0), ("medium", 120), ("high", 400)],
            sees: true,
            plain: 200,
            ..Fake::default()
        };
        assert!(pass(&fake, &catalog, &rows, &path, 1_000).await.unwrap());
        let checks = load(&path);
        assert!(checks.trying.is_none());
        assert_eq!(
            checks.models["google/carbon"].efforts,
            ["low", "medium", "high"]
        );
        // While Open Codex still lists them bare, neither is looked at again before a week is out.
        let written = fake.sets().len();
        assert!(!pass(&fake, &catalog, &rows, &path, 2_000).await.unwrap());
        assert_eq!(fake.sets().len(), written);

        // A bridge that stopped between two efforts left the model with one: the next pass clears it first.
        let mut checks = load(&path);
        checks.trying = Some(Target {
            id: "google/carbon".into(),
            provider: "google".into(),
            model: "carbon".into(),
        });
        save(&path, &checks).unwrap();
        assert!(pass(&fake, &catalog, &rows, &path, 3_000).await.unwrap());
        assert_eq!(fake.sets()[written], json!({ "reasoningEfforts": null }));
        assert!(load(&path).trying.is_none());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn an_unclear_look_is_tried_again_sooner_than_a_settled_one() {
        let mut found = Finding::of(Outcome::Unclear, "429");
        found.at = 10_000;
        assert!(!found.due(10_000 + HOUR - 1));
        assert!(found.due(10_000 + HOUR));
        found.tries = 3;
        assert!(!found.due(10_000 + 7 * HOUR));
        assert!(found.due(10_000 + 8 * HOUR));
        found.tries = 40;
        assert!(found.due(10_000 + WEEK));
        let mut settled = Finding::of(Outcome::Plain, "");
        settled.at = 10_000;
        assert!(!settled.due(10_000 + WEEK - 1));
        assert!(settled.due(10_000 + WEEK));
    }

    #[test]
    fn a_refusal_and_an_outage_are_told_apart() {
        assert_eq!(
            answer(Ok(taken(42, "313"))),
            Answer::Taken {
                reasoning: 42,
                text: "313".into()
            }
        );
        assert!(matches!(
            answer(Ok(refused("no such level"))),
            Answer::Refused(_)
        ));
        for status in [401, 404, 429, 500, 503] {
            assert!(matches!(
                answer(Ok((status, Value::Null))),
                Answer::Unclear(_)
            ));
        }
        assert!(matches!(
            answer(Err(anyhow!("timed out"))),
            Answer::Unclear(_)
        ));
        // Answered 200, but as a failure.
        let failed = (200, json!({ "status": "failed", "error": null }));
        assert!(matches!(answer(Ok(failed)), Answer::Unclear(_)));
    }
}
