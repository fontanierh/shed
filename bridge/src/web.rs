//! Web search and page reading for the agents: the `shed-web` command, which is this binary under that name (or
//! `agent-remote web`). The bridge links it into ~/.agent-remote/bin and puts that folder on its agents' PATH.
//!
//! - Pi, and any other agent: the command.
//! - Prime: the `shed_web` Python module (`bridge/python/shed_web.py`), which runs the command with `--json --full`.
//! - DeepSeek Harness: its own `web_search` and `web_fetch` tools, through a provider Shed's dsh plugin registers,
//!   which runs the command with `--json`.
//!
//! The provider and its key are `web` in ~/.agent-remote/config.json, `{"provider": "firecrawl", "firecrawlApiKey":
//! "fc-…"}` (or `FIRECRAWL_API_KEY` in the environment). Firecrawl is the only provider for now. Pages come back as
//! Markdown by default; every other format Firecrawl has can be asked for. A page longer than `LONG` characters is
//! saved to a file and only its beginning printed, and HTML and screenshots always go to files, so a page never
//! floods the agent's context. Each call is logged, with the credits it used, to ~/.agent-remote/logs/web.log.

use anyhow::{anyhow, bail, Context, Result};
use serde_json::{json, Map, Value};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// Text longer than this goes to a file, and only its first `PREVIEW` characters are printed.
pub const LONG: usize = 20_000;
const PREVIEW: usize = 8_000;
/// What a search shows of each result's description, and of each result's page when it reads them too.
const SNIPPET: usize = 400;
const SCRAPED_PREVIEW: usize = 1_500;
const FIRECRAWL: &str = "https://api.firecrawl.dev";

const USAGE: &str = "\
usage: shed-web search <query> [options]
       shed-web fetch <url> [options]

Search the web, or read a page as Markdown, through Shed's web provider (Firecrawl).

search options:
  --limit N            number of results (default 5)
  --sources LIST       web, news, images (default web)
  --categories LIST    github, research, pdf
  --tbs VALUE          time range: qdr:h, qdr:d, qdr:w, qdr:m, qdr:y
  --location TEXT      search from a place, e.g. \"Paris,France\"
  --country CODE       e.g. US
  --scrape             also read each result as Markdown (saved to files)

fetch options:
  --format LIST        markdown (default), summary, html, rawHtml, rawBase64, links, images,
                       screenshot, screenshot@fullPage, json, query, question, highlights, branding,
                       product, audio, video, changeTracking; repeatable or comma-separated (a format's
                       other options go in --body)
  --prompt TEXT        what to extract (json), or what to ask the page (query, question, highlights)
  --schema JSON|FILE   the JSON schema to extract, for --format json
  --all-content        keep navigation, headers and footers (by default only the main content)
  --include-tags LIST  only these HTML tags or selectors
  --exclude-tags LIST  leave out these HTML tags or selectors
  --wait MS            wait this long after the page loads
  --mobile             load the page as a phone would
  --max-age MS         accept a cached copy up to this old (0: always fresh)
  --timeout MS         give up after this long
  --proxy TYPE         basic, stealth or auto
  --country CODE       load the page from this country, e.g. DE
  --languages LIST     in these languages, e.g. de-DE,en
  --full               print the whole page, however long
  --out DIR            where files go (default: $TMPDIR/shed-web)

both:
  --body JSON          more fields for Firecrawl's request, as its API documents them
  --json               print the result as JSON";

/// `shed-web …` or `agent-remote web …`: runs the command and exits.
pub async fn main(args: Vec<String>) -> ! {
    let code = match run(args).await {
        Ok(output) => {
            print!("{output}");
            0
        }
        Err(e) => {
            eprintln!("shed-web: {e:#}");
            1
        }
    };
    #[expect(
        clippy::let_underscore_must_use,
        reason = "a closed stdout leaves nobody to tell, and the exit code stands"
    )]
    let _ = std::io::stdout().flush();
    std::process::exit(code)
}

async fn run(args: Vec<String>) -> Result<String> {
    let mut args = args.into_iter();
    let command = args.next().unwrap_or_default();
    if matches!(command.as_str(), "" | "-h" | "--help" | "help") {
        return Ok(format!("{USAGE}\n"));
    }
    let request = Request::parse(&command, args.collect())?;
    let provider = Provider::from_config()?;
    let started = std::time::Instant::now();
    let result = match &request.what {
        What::Search(query) => provider.search(query, &request).await,
        What::Fetch(url) => provider.fetch(url, &request).await,
    };
    log(&request, &result, started.elapsed());
    let result = result?;
    match &request.what {
        What::Search(_) => present_search(&result, &request),
        What::Fetch(_) => present_page(&result, &request).await,
    }
}

/// Whether a provider is set up here: the guide tells the agents about the web only then.
pub fn configured() -> bool {
    Provider::from_config().is_ok()
}

/// Link `shed-web` to the running binary in its folder, and write the Python module, for agents started from here.
/// Done at every start, so a bridge that `setup/sync-remote.sh` updates brings both with it.
pub fn install() {
    let Ok(exe) = std::env::current_exe() else {
        return;
    };
    let Some(bin) = exe.parent() else { return };
    let link = bin.join("shed-web");
    let target = exe.file_name().map(PathBuf::from).unwrap_or_default();
    if std::fs::read_link(&link).ok().as_deref() != Some(target.as_path()) {
        #[expect(
            clippy::let_underscore_must_use,
            reason = "often there is no link yet, and one that stays is reported by the symlink below"
        )]
        let _ = std::fs::remove_file(&link);
        if let Err(e) = std::os::unix::fs::symlink(&target, &link) {
            eprintln!("shed-web: can't link {}: {e}", link.display());
        }
    }
    let python = python_dir();
    let module = python.join("shed_web.py");
    if std::fs::read_to_string(&module).ok().as_deref() != Some(PYTHON) {
        let written =
            std::fs::create_dir_all(&python).and_then(|_| std::fs::write(&module, PYTHON));
        if let Err(e) = written {
            eprintln!("shed-web: can't write {}: {e}", module.display());
        }
    }
}

const PYTHON: &str = include_str!("../python/shed_web.py");

fn home() -> PathBuf {
    PathBuf::from(std::env::var("HOME").unwrap_or_default())
}

/// Where the `shed_web` Python module is, for Prime's PYTHONPATH.
pub fn python_dir() -> PathBuf {
    home().join(".agent-remote/python")
}

/// The folder `shed-web` is in, for the agents' PATH.
pub fn bin_dir() -> PathBuf {
    std::env::current_exe()
        .ok()
        .and_then(|exe| exe.parent().map(Path::to_path_buf))
        .unwrap_or_else(|| home().join(".agent-remote/bin"))
}

/// `dir` ahead of the folders in `path`, once.
pub fn prepend_path(dir: &Path, path: &str) -> String {
    let dir = dir.to_string_lossy();
    if path.split(':').any(|p| p == dir) {
        return path.to_string();
    }
    if path.is_empty() {
        dir.into_owned()
    } else {
        format!("{dir}:{path}")
    }
}

enum What {
    Search(String),
    Fetch(String),
}

struct Request {
    what: What,
    /// Firecrawl's request body, from the options and `--body`.
    body: Map<String, Value>,
    json: bool,
    full: bool,
    out: Option<PathBuf>,
}

impl Request {
    fn parse(command: &str, args: Vec<String>) -> Result<Request> {
        let mut body = Map::new();
        let mut extra: Option<Value> = None;
        let mut target: Option<String> = None;
        let (mut json_out, mut full, mut out) = (false, false, None);
        let mut formats: Vec<Value> = vec![];
        let (mut prompt, mut schema) = (None, None);
        let search = match command {
            "search" => true,
            "fetch" | "scrape" | "read" => false,
            other => bail!("unknown command {other:?}\n\n{USAGE}"),
        };
        let mut args = args.into_iter();
        let list = |v: String| -> Vec<Value> {
            v.split(',')
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(|s| json!(s))
                .collect()
        };
        while let Some(arg) = args.next() {
            let flag = arg.clone();
            let mut value = |name: &str| args.next().ok_or_else(|| anyhow!("{name} needs a value"));
            let number = |name: &str, v: String| -> Result<Value> {
                v.parse::<u64>()
                    .map(|n| json!(n))
                    .map_err(|_| anyhow!("{name} takes a number, not {v:?}"))
            };
            match flag.as_str() {
                "--json" => json_out = true,
                "--full" => full = true,
                "--out" => out = Some(PathBuf::from(value("--out")?)),
                "--body" => {
                    let v = value("--body")?;
                    extra = Some(serde_json::from_str(&v).context("--body isn't JSON")?);
                }
                "--limit" if search => {
                    let v = value("--limit")?;
                    body.insert("limit".into(), number("--limit", v)?);
                }
                "--sources" if search => {
                    let v = value("--sources")?;
                    body.insert("sources".into(), json!(list(v)));
                }
                "--categories" if search => {
                    let v = value("--categories")?;
                    body.insert("categories".into(), json!(list(v)));
                }
                "--tbs" if search => {
                    body.insert("tbs".into(), json!(value("--tbs")?));
                }
                "--location" if search => {
                    body.insert("location".into(), json!(value("--location")?));
                }
                "--country" if search => {
                    body.insert("country".into(), json!(value("--country")?));
                }
                // A page is loaded from a country, in languages: Firecrawl's `location` object.
                "--country" => {
                    let v = value("--country")?;
                    let location = body.entry("location").or_insert(json!({}));
                    location["country"] = json!(v);
                }
                "--languages" if !search => {
                    let v = value("--languages")?;
                    let location = body.entry("location").or_insert(json!({}));
                    location["languages"] = json!(list(v));
                }
                "--scrape" if search => {
                    body.insert(
                        "scrapeOptions".into(),
                        json!({ "formats": ["markdown"], "onlyMainContent": true }),
                    );
                }
                "--format" | "--formats" if !search => {
                    let v = value("--format")?;
                    formats.extend(list(v));
                }
                "--prompt" if !search => prompt = Some(value("--prompt")?),
                "--schema" if !search => {
                    let v = value("--schema")?;
                    let text = if Path::new(&v).is_file() {
                        std::fs::read_to_string(&v)?
                    } else {
                        v
                    };
                    schema =
                        Some(serde_json::from_str::<Value>(&text).context("--schema isn't JSON")?);
                }
                "--all-content" if !search => {
                    body.insert("onlyMainContent".into(), json!(false));
                }
                "--include-tags" if !search => {
                    let v = value("--include-tags")?;
                    body.insert("includeTags".into(), json!(list(v)));
                }
                "--exclude-tags" if !search => {
                    let v = value("--exclude-tags")?;
                    body.insert("excludeTags".into(), json!(list(v)));
                }
                "--wait" if !search => {
                    let v = value("--wait")?;
                    body.insert("waitFor".into(), number("--wait", v)?);
                }
                "--mobile" if !search => {
                    body.insert("mobile".into(), json!(true));
                }
                "--max-age" if !search => {
                    let v = value("--max-age")?;
                    body.insert("maxAge".into(), number("--max-age", v)?);
                }
                "--timeout" => {
                    let v = value("--timeout")?;
                    body.insert("timeout".into(), number("--timeout", v)?);
                }
                "--proxy" if !search => {
                    body.insert("proxy".into(), json!(value("--proxy")?));
                }
                "-h" | "--help" => bail!("{USAGE}"),
                flag if flag.starts_with("--") => {
                    bail!("{flag} isn't a {command} option\n\n{USAGE}")
                }
                _ if target.is_none() => target = Some(arg),
                // An unquoted query.
                _ if search => {
                    let t = target.get_or_insert_default();
                    t.push(' ');
                    t.push_str(&arg);
                }
                _ => bail!("fetch reads one page at a time ({arg:?} is one too many)"),
            }
        }
        let Some(target) = target.filter(|t| !t.trim().is_empty()) else {
            bail!(
                "{command} needs {}\n\n{USAGE}",
                if search { "a query" } else { "a URL" }
            )
        };
        let what = if search {
            body.entry("limit").or_insert(json!(5));
            body.insert("query".into(), json!(target));
            What::Search(target)
        } else {
            let url = if target.contains("://") {
                target
            } else {
                format!("https://{target}")
            };
            body.insert("url".into(), json!(url));
            if formats.is_empty() {
                formats.push(json!("markdown"));
            }
            let formats: Vec<Value> = formats
                .into_iter()
                .map(|f| match f.as_str() {
                    Some("screenshot@fullPage") => {
                        json!({ "type": "screenshot", "fullPage": true })
                    }
                    Some("json") => {
                        let mut format = json!({ "type": "json" });
                        if let Some(p) = &prompt {
                            format["prompt"] = json!(p);
                        }
                        if let Some(s) = &schema {
                            format["schema"] = s.clone();
                        }
                        format
                    }
                    // Formats that ask something of the page take `--prompt` as their question.
                    Some(kind @ ("query" | "question" | "highlights")) => {
                        let field = match kind {
                            "query" => "prompt",
                            "question" => "question",
                            _ => "query",
                        };
                        let mut format = json!({ "type": kind });
                        if let Some(p) = &prompt {
                            format[field] = json!(p);
                        }
                        format
                    }
                    _ => f,
                })
                .collect();
            body.insert("formats".into(), json!(formats));
            What::Fetch(url)
        };
        if let Some(extra) = extra {
            let Value::Object(extra) = extra else {
                bail!("--body must be a JSON object")
            };
            body.extend(extra);
        }
        Ok(Request {
            what,
            body,
            json: json_out,
            full,
            out,
        })
    }

    fn files(&self) -> PathBuf {
        self.out
            .clone()
            .unwrap_or_else(|| std::env::temp_dir().join("shed-web"))
    }
}

// The readers in this file take what they can of what comes from outside: a part that is missing, or of another
// type than expected, reads as absent, never as an error.

fn text(value: &Value) -> Option<String> {
    value.as_str().map(str::to_string)
}

fn list(value: &Value) -> &[Value] {
    value.as_array().map(Vec::as_slice).unwrap_or_default()
}

/// ~/.agent-remote/config.json, as far as the web goes.
struct Config {
    web: Settings,
}

impl Config {
    fn read(config: &Value) -> Config {
        Config {
            web: Settings::read(&config["web"]),
        }
    }
}

/// The config's `web` entry.
struct Settings {
    provider: Option<String>,
    firecrawl_api_key: Option<String>,
    firecrawl_url: Option<String>,
}

impl Settings {
    fn read(web: &Value) -> Settings {
        Settings {
            provider: text(&web["provider"]),
            firecrawl_api_key: text(&web["firecrawlApiKey"]),
            firecrawl_url: text(&web["firecrawlUrl"]),
        }
    }
}

enum Provider {
    Firecrawl { key: String, base: String },
}

impl Provider {
    fn from_config() -> Result<Provider> {
        let config: Value = std::fs::read_to_string(home().join(".agent-remote/config.json"))
            .ok()
            .and_then(|raw| serde_json::from_str(&raw).ok())
            .unwrap_or_default();
        Self::in_config(&config, std::env::var("FIRECRAWL_API_KEY").ok())
    }

    fn in_config(config: &Value, env_key: Option<String>) -> Result<Provider> {
        Self::from(Config::read(config).web, env_key)
    }

    fn from(web: Settings, env_key: Option<String>) -> Result<Provider> {
        match web.provider.as_deref().unwrap_or("firecrawl") {
            "firecrawl" => {
                let key = web
                    .firecrawl_api_key
                    .or(env_key)
                    .filter(|k| !k.trim().is_empty())
                    .ok_or_else(|| {
                        anyhow!(
                            "web search isn't set up on this Mac: Shed needs a Firecrawl key, \
                             `web.firecrawlApiKey` in ~/.agent-remote/config.json"
                        )
                    })?;
                let base = web
                    .firecrawl_url
                    .as_deref()
                    .unwrap_or(FIRECRAWL)
                    .trim_end_matches('/')
                    .to_string();
                Ok(Provider::Firecrawl { key, base })
            }
            other => bail!("Shed has no web provider called {other:?} (it knows: firecrawl)"),
        }
    }

    async fn search(&self, _query: &str, request: &Request) -> Result<Value> {
        match self {
            Provider::Firecrawl { key, base } => {
                firecrawl(key, &format!("{base}/v2/search"), &request.body).await
            }
        }
    }

    async fn fetch(&self, _url: &str, request: &Request) -> Result<Value> {
        match self {
            Provider::Firecrawl { key, base } => {
                firecrawl(key, &format!("{base}/v2/scrape"), &request.body).await
            }
        }
    }
}

async fn firecrawl(key: &str, url: &str, body: &Map<String, Value>) -> Result<Value> {
    // A scrape waits for the page, and a search that reads its results waits for each of them.
    let timeout = body
        .get("timeout")
        .and_then(Value::as_u64)
        .unwrap_or(60_000)
        + 30_000;
    let response = reqwest::Client::new()
        .post(url)
        .bearer_auth(key)
        .json(body)
        .timeout(Duration::from_millis(timeout))
        .send()
        .await
        .map_err(|e| anyhow!("can't reach Firecrawl: {e}"))?;
    let status = response.status();
    let text = response.text().await.unwrap_or_default();
    answer(status, &text)
}

/// What any reply of Firecrawl's says of how it went.
struct Outcome {
    success: Option<bool>,
    error: Option<String>,
}

impl Outcome {
    fn read(reply: &Value) -> Outcome {
        Outcome {
            success: reply["success"].as_bool(),
            error: text(&reply["error"]),
        }
    }
}

/// Firecrawl's reply, or what it said went wrong.
fn answer(status: reqwest::StatusCode, text: &str) -> Result<Value> {
    let reply: Value = serde_json::from_str(text).unwrap_or(Value::Null);
    let outcome = Outcome::read(&reply);
    if !status.is_success() || outcome.success == Some(false) {
        let message = outcome
            .error
            .unwrap_or_else(|| text.chars().take(500).collect());
        bail!("Firecrawl answered {status}: {message}");
    }
    Ok(reply)
}

/// One line per call: when, what, how long and the credits it used, never the key.
fn log(request: &Request, result: &Result<Value>, took: Duration) {
    let (kind, target) = match &request.what {
        What::Search(q) => ("search", q.as_str()),
        What::Fetch(u) => ("fetch", u.as_str()),
    };
    let outcome = match result {
        Ok(reply) => json!({ "ok": true, "credits": credits(reply) }),
        Err(e) => json!({ "ok": false, "error": format!("{e:#}") }),
    };
    let line = json!({
        "at": std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or_default(),
        "kind": kind,
        "target": target,
        "ms": took.as_millis() as u64,
        "pid": std::process::id(),
        "outcome": outcome,
    });
    let dir = home().join(".agent-remote/logs");
    #[expect(
        clippy::let_underscore_must_use,
        reason = "this runs inside an agent's tool call, where stderr is the agent's reading: a log line lost is not \
                  the agent's business"
    )]
    let _ = std::fs::create_dir_all(&dir)
        .and_then(|()| {
            std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(dir.join("web.log"))
        })
        .and_then(|mut file| writeln!(file, "{line}"));
}

/// Where a reply of Firecrawl's says the credits it used: a search at its top, a scrape in its page's metadata.
struct Used {
    credits_used: Option<u64>,
    page_credits_used: Option<u64>,
}

impl Used {
    fn read(reply: &Value) -> Used {
        Used {
            credits_used: reply["creditsUsed"].as_u64(),
            page_credits_used: reply["data"]["metadata"]["creditsUsed"].as_u64(),
        }
    }
}

/// The credits a reply says it used: a search says so itself, a scrape in its page's metadata.
fn credits(reply: &Value) -> Option<u64> {
    let used = Used::read(reply);
    used.credits_used.or(used.page_credits_used)
}

/// A file name for what was read from `url`: its host and path, readable, plus a short hash so two pages differ.
fn file_name(url: &str, ext: &str) -> String {
    use sha2::{Digest, Sha256};
    let rest = url.split_once("://").map_or(url, |(_, rest)| rest);
    let mut slug: String = rest
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect();
    while slug.contains("--") {
        slug = slug.replace("--", "-");
    }
    let slug: String = slug.trim_matches('-').chars().take(60).collect();
    let hash = Sha256::digest(url.as_bytes());
    let hash: String = hash.iter().take(4).map(|b| format!("{b:02x}")).collect();
    format!("{slug}-{hash}.{ext}")
}

fn save(dir: &Path, name: &str, bytes: &[u8]) -> Result<PathBuf> {
    std::fs::create_dir_all(dir).with_context(|| format!("can't create {}", dir.display()))?;
    let path = dir.join(name);
    std::fs::write(&path, bytes).with_context(|| format!("can't write {}", path.display()))?;
    Ok(path)
}

/// The first `limit` characters of `text`, cut at a line end when there is one near the limit.
fn head(text: &str, limit: usize) -> &str {
    let Some((cut, _)) = text.char_indices().nth(limit) else {
        return text;
    };
    let head = &text[..cut];
    match head.rfind('\n') {
        Some(line) if line > cut / 2 => &head[..line],
        _ => head,
    }
}

fn chars(text: &str) -> usize {
    text.chars().count()
}

fn thousands(n: usize) -> String {
    let digits = n.to_string();
    let mut out = String::new();
    for (i, c) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i).is_multiple_of(3) {
            out.push(',');
        }
        out.push(c);
    }
    out
}

/// One line of a snippet: whitespace folded, at most `SNIPPET` characters.
fn snippet(text: &str) -> String {
    let folded = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if chars(&folded) > SNIPPET {
        format!("{}…", head(&folded, SNIPPET).trim_end())
    } else {
        folded
    }
}

/// Firecrawl's reply to a search. Its credits go out in `--json` as they came, whatever they are.
struct Found {
    credits_used: Value,
    data: Results,
}

impl Found {
    fn read(reply: &Value) -> Found {
        Found {
            credits_used: reply["creditsUsed"].clone(),
            data: Results::read(&reply["data"]),
        }
    }
}

/// A search's results, by where they were found.
struct Results {
    web: Vec<Hit>,
    news: Vec<Hit>,
    images: Vec<Hit>,
}

impl Results {
    fn read(data: &Value) -> Results {
        let hits = |kind: &str| list(&data[kind]).iter().map(Hit::read).collect();
        Results {
            web: hits("web"),
            news: hits("news"),
            images: hits("images"),
        }
    }
}

/// One result of a search. Its title, date and image link go out in `--json` as they came, whatever they are.
struct Hit {
    url: Option<String>,
    title: Value,
    description: Option<String>,
    snippet: Option<String>,
    date: Value,
    image_url: Value,
    markdown: Option<String>,
}

impl Hit {
    fn read(hit: &Value) -> Hit {
        Hit {
            url: text(&hit["url"]),
            title: hit["title"].clone(),
            description: text(&hit["description"]),
            snippet: text(&hit["snippet"]),
            date: hit["date"].clone(),
            image_url: hit["imageUrl"].clone(),
            markdown: text(&hit["markdown"]),
        }
    }
}

fn present_search(reply: &Value, request: &Request) -> Result<String> {
    let reply = Found::read(reply);
    let dir = request.files();
    let mut sources = vec![];
    let mut out = String::new();
    let Results { web, news, images } = &reply.data;
    for (kind, hits) in [("web", web), ("news", news), ("images", images)] {
        for hit in hits {
            let url = hit.url.as_deref().unwrap_or_default();
            let excerpt = hit
                .description
                .as_deref()
                .or(hit.snippet.as_deref())
                .map(snippet);
            let mut source = json!({
                "kind": kind,
                "url": url,
                "title": hit.title,
                "snippet": excerpt,
                "publishedAt": hit.date,
            });
            let title = hit.title.as_str().filter(|t| !t.is_empty()).unwrap_or(url);
            out += &format!("{}. [{title}]({url})", sources.len() + 1);
            if kind != "web" {
                out += &format!(" ({kind})");
            }
            if let Some(date) = hit.date.as_str() {
                out += &format!(" · {date}");
            }
            out += "\n";
            if kind == "images" {
                source["imageUrl"] = hit.image_url.clone();
                if let Some(image) = hit.image_url.as_str() {
                    out += &format!("   image: {image}\n");
                }
            }
            if let Some(text) = excerpt.as_deref().filter(|t| !t.is_empty()) {
                out += &format!("   {text}\n");
            }
            if let Some(markdown) = hit.markdown.as_deref().filter(|m| !m.is_empty()) {
                let path = save(&dir, &file_name(url, "md"), markdown.as_bytes())?;
                let characters = chars(markdown);
                let shown = if request.full {
                    markdown
                } else {
                    head(markdown, SCRAPED_PREVIEW)
                };
                source["file"] = json!(path);
                source["characters"] = json!(characters);
                source["markdown"] = json!(shown);
                out += &format!(
                    "   Page as Markdown ({} characters): {}\n",
                    thousands(characters),
                    path.display()
                );
                for line in shown.lines() {
                    out += &format!("   > {line}\n");
                }
            }
            sources.push(source);
        }
    }
    if request.json {
        let out = json!({ "sources": sources, "creditsUsed": reply.credits_used });
        return Ok(format!("{out}\n"));
    }
    if sources.is_empty() {
        return Ok("No results.\n".into());
    }
    Ok(out)
}

/// Firecrawl's reply to a scrape.
struct Scraped {
    data: Page,
}

impl Scraped {
    fn read(reply: &Value) -> Scraped {
        Scraped {
            data: Page::read(&reply["data"]),
        }
    }
}

/// The parts of a scrape `present_page` lays out itself; anything else in it is passed on as it is.
const HANDLED: &[&str] = &[
    "markdown",
    "summary",
    "html",
    "rawHtml",
    "rawBase64",
    "screenshot",
    "warning",
    "metadata",
];

/// A scraped page: the parts `present_page` lays out itself, and in `other` anything else, passed on as it is.
struct Page {
    markdown: Option<String>,
    summary: Option<String>,
    html: Option<String>,
    raw_html: Option<String>,
    raw_base64: Option<String>,
    screenshot: Option<String>,
    warning: Option<String>,
    /// Goes out whole in `--json`; `Metadata` is what is read of it.
    metadata: Value,
    other: Map<String, Value>,
}

impl Page {
    fn read(data: &Value) -> Page {
        Page {
            markdown: text(&data["markdown"]),
            summary: text(&data["summary"]),
            html: text(&data["html"]),
            raw_html: text(&data["rawHtml"]),
            raw_base64: text(&data["rawBase64"]),
            screenshot: text(&data["screenshot"]),
            warning: text(&data["warning"]),
            metadata: data["metadata"].clone(),
            other: data
                .as_object()
                .into_iter()
                .flatten()
                .filter(|(field, _)| !HANDLED.contains(&field.as_str()))
                .map(|(field, value)| (field.clone(), value.clone()))
                .collect(),
        }
    }
}

/// What is read of a page's `metadata`. Its status and title go out in `--json` as they came, whatever they are.
struct Metadata {
    url: Option<String>,
    source_url: Option<String>,
    status_code: Value,
    title: Value,
}

impl Metadata {
    fn read(metadata: &Value) -> Metadata {
        Metadata {
            url: text(&metadata["url"]),
            source_url: text(&metadata["sourceURL"]),
            status_code: metadata["statusCode"].clone(),
            title: metadata["title"].clone(),
        }
    }
}

async fn present_page(reply: &Value, request: &Request) -> Result<String> {
    let data = Scraped::read(reply).data;
    let meta = Metadata::read(&data.metadata);
    let url = meta.url.or(meta.source_url).unwrap_or_default();
    let dir = request.files();
    let mut page = json!({
        "url": url,
        "statusCode": meta.status_code,
        "title": meta.title,
    });
    let mut notes: Vec<String> = vec![];

    // Text a reader wants in the reply: whole when short (or asked for), else its start and the whole in a file.
    let mut text = |field: &str, found: Option<&str>, ext: &str, page: &mut Value| -> Result<()> {
        let Some(content) = found else {
            return Ok(());
        };
        let n = chars(content);
        if request.full || n <= LONG {
            page[field] = json!(content);
            return Ok(());
        }
        let path = save(&dir, &file_name(&url, ext), content.as_bytes())?;
        page[field] = json!(head(content, PREVIEW));
        page[format!("{field}File")] = json!(path);
        page["truncated"] = json!(true);
        notes.push(format!(
            "The {field} is {} characters; the first {} are above. All of it: {}",
            thousands(n),
            thousands(PREVIEW),
            path.display()
        ));
        Ok(())
    };
    text("markdown", data.markdown.as_deref(), "md", &mut page)?;
    text("summary", data.summary.as_deref(), "summary.md", &mut page)?;

    // HTML goes to a file (and inline too when the whole page was asked for).
    for (field, content, ext) in [
        ("html", &data.html, "html"),
        ("rawHtml", &data.raw_html, "raw.html"),
    ] {
        if let Some(content) = content {
            let path = save(&dir, &file_name(&url, ext), content.as_bytes())?;
            page[format!("{field}File")] = json!(path);
            page[format!("{field}Characters")] = json!(chars(content));
            if request.full && request.json {
                page[field] = json!(content);
            }
        }
    }
    // The response body as the server sent it, decoded, in a file.
    if let Some(raw) = &data.raw_base64 {
        let path = save(&dir, &file_name(&url, "raw"), &base64_decode(raw)?)?;
        page["rawFile"] = json!(path);
    }
    // Every other format as Firecrawl returns it (links, images, json, an answer, a product, audio and video links…),
    // so a format added there needs nothing here.
    for (field, value) in &data.other {
        if !value.is_null() {
            page[field] = value.clone();
        }
    }
    if let Some(shot) = &data.screenshot {
        page["screenshotFile"] = json!(screenshot(shot, &dir, &url).await?);
    }
    if let Some(warning) = &data.warning {
        page["warning"] = json!(warning);
    }

    if request.json {
        page["metadata"] = data.metadata.clone();
        return Ok(format!("{page}\n"));
    }
    let mut out = String::new();
    if let Some(title) = page["title"].as_str().filter(|t| !t.is_empty()) {
        out += &format!("# {title}\n");
    }
    out += &url;
    if let Some(status) = page["statusCode"].as_u64().filter(|s| *s != 200) {
        out += &format!(" (HTTP {status})");
    }
    out += "\n";
    if let Some(warning) = page["warning"].as_str() {
        out += &format!("Warning: {warning}\n");
    }
    if let Some(summary) = page["summary"].as_str() {
        out += &format!("\n## Summary\n\n{summary}\n");
    }
    if let Some(markdown) = page["markdown"].as_str() {
        out += &format!("\n{markdown}\n");
    }
    for field in data.other.keys() {
        if page[field].is_null() {
            continue;
        }
        let value = &page[field];
        let heading = if field == "json" { "Extracted" } else { field };
        let body = match value {
            Value::String(s) => s.clone(),
            Value::Array(list) if list.iter().all(Value::is_string) => {
                let items: Vec<String> = list
                    .iter()
                    .map(|i| format!("- {}", i.as_str().unwrap_or_default()))
                    .collect();
                out += &format!("\n## {} ({})\n\n", capitalize(heading), list.len());
                out += &(items.join("\n") + "\n");
                continue;
            }
            other => format!("{other:#}"),
        };
        if !request.full && chars(&body) > LONG {
            let path = save(
                &dir,
                &file_name(&url, &format!("{field}.txt")),
                body.as_bytes(),
            )?;
            notes.push(format!("{}: {}", capitalize(heading), path.display()));
        } else {
            out += &format!("\n## {}\n\n{body}\n", capitalize(heading));
        }
    }
    for (field, what) in [
        ("htmlFile", "HTML"),
        ("rawHtmlFile", "Raw HTML"),
        ("rawFile", "Response body"),
    ] {
        if let Some(path) = page[field].as_str() {
            notes.push(format!("{what}: {path}"));
        }
    }
    if let Some(path) = page["screenshotFile"].as_str() {
        notes.push(format!("Screenshot: {path}"));
    }
    if !notes.is_empty() {
        out += "\n";
        for note in notes {
            out += &format!("[{note}]\n");
        }
    }
    Ok(out)
}

fn capitalize(s: &str) -> String {
    let mut c = s.chars();
    c.next()
        .map(|f| f.to_uppercase().collect::<String>() + c.as_str())
        .unwrap_or_default()
}

/// Firecrawl hands a screenshot back as a link that expires (or, from some hosts, inline as base64): saved here.
async fn screenshot(shot: &str, dir: &Path, url: &str) -> Result<PathBuf> {
    let name = file_name(url, "png");
    if let Some(data) = shot.strip_prefix("data:image/png;base64,") {
        return save(dir, &name, &base64_decode(data)?);
    }
    let bytes = reqwest::Client::new()
        .get(shot)
        .timeout(Duration::from_secs(60))
        .send()
        .await
        .and_then(|r| r.error_for_status())
        .map_err(|e| anyhow!("can't download the screenshot: {e}"))?
        .bytes()
        .await?;
    save(dir, &name, &bytes)
}

fn base64_decode(text: &str) -> Result<Vec<u8>> {
    let value = |c: u8| -> Option<u32> {
        Some(match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            _ => return None,
        } as u32)
    };
    let mut out = Vec::with_capacity(text.len() * 3 / 4);
    let (mut acc, mut bits) = (0u32, 0);
    for c in text
        .bytes()
        .filter(|c| !c.is_ascii_whitespace() && *c != b'=')
    {
        acc = (acc << 6) | value(c).ok_or_else(|| anyhow!("the screenshot isn't base64"))?;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn a_search_takes_its_options_and_an_unquoted_query() {
        let r = Request::parse(
            "search",
            args(&[
                "rust",
                "async",
                "--limit",
                "3",
                "--sources",
                "web,news",
                "--json",
            ]),
        )
        .unwrap();
        assert_eq!(r.body["query"], "rust async");
        assert_eq!(r.body["limit"], 3);
        assert_eq!(r.body["sources"], json!(["web", "news"]));
        assert!(r.json);
        let r = Request::parse("search", args(&["q"])).unwrap();
        assert_eq!(r.body["limit"], 5);
    }

    #[test]
    fn a_fetch_reads_markdown_unless_told_otherwise() {
        let r = Request::parse("fetch", args(&["example.com"])).unwrap();
        assert_eq!(r.body["url"], "https://example.com");
        assert_eq!(r.body["formats"], json!(["markdown"]));
        let r = Request::parse(
            "fetch",
            args(&[
                "https://x.dev",
                "--format",
                "html,screenshot@fullPage",
                "--format",
                "json",
                "--prompt",
                "the price",
                "--all-content",
                "--body",
                r#"{"blockAds": false}"#,
            ]),
        )
        .unwrap();
        assert_eq!(
            r.body["formats"],
            json!([
                "html",
                { "type": "screenshot", "fullPage": true },
                { "type": "json", "prompt": "the price" }
            ])
        );
        assert_eq!(r.body["onlyMainContent"], false);
        assert_eq!(r.body["blockAds"], false);
    }

    #[test]
    fn options_of_the_other_command_are_refused() {
        assert!(Request::parse("fetch", args(&["x.dev", "--limit", "3"])).is_err());
        assert!(Request::parse("search", args(&["q", "--format", "html"])).is_err());
        assert!(Request::parse("search", args(&[])).is_err());
        assert!(Request::parse("fetch", args(&["a.dev", "b.dev"])).is_err());
    }

    #[test]
    fn the_key_comes_from_the_config_or_the_environment() {
        let config = json!({ "provider": "firecrawl", "firecrawlApiKey": "fc-config" });
        let Provider::Firecrawl { key, base } =
            Provider::from(Settings::read(&config), Some("fc-env".into())).unwrap();
        assert_eq!((key.as_str(), base.as_str()), ("fc-config", FIRECRAWL));
        let Provider::Firecrawl { key, .. } =
            Provider::from(Settings::read(&Value::Null), Some("fc-env".into())).unwrap();
        assert_eq!(key, "fc-env");
        assert!(Provider::from(Settings::read(&Value::Null), None).is_err());
        assert!(Provider::from(
            Settings::read(&json!({ "provider": "other" })),
            Some("k".into())
        )
        .is_err());
    }

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("shed-web-test-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }

    #[test]
    fn a_long_page_goes_to_a_file_and_only_its_start_is_printed() {
        let dir = scratch("long");
        let mut r = Request::parse("fetch", args(&["https://x.dev/doc"])).unwrap();
        r.out = Some(dir.clone());
        let long = "line of text\n".repeat(3_000);
        let reply = json!({ "success": true, "data": {
            "markdown": long,
            "metadata": { "title": "Doc", "url": "https://x.dev/doc", "statusCode": 200 },
        }});
        let out = futures_util::FutureExt::now_or_never(present_page(&reply, &r))
            .unwrap()
            .unwrap();
        assert!(out.starts_with("# Doc\nhttps://x.dev/doc\n"));
        assert!(out.len() < PREVIEW + 500, "printed {} bytes", out.len());
        assert!(out.contains("The markdown is 39,000 characters"));
        let saved = std::fs::read_dir(&dir)
            .unwrap()
            .next()
            .unwrap()
            .unwrap()
            .path();
        assert_eq!(std::fs::read_to_string(&saved).unwrap(), long);

        r.full = true;
        let out = futures_util::FutureExt::now_or_never(present_page(&reply, &r))
            .unwrap()
            .unwrap();
        assert!(out.contains(&long));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_short_page_is_printed_whole_with_its_links() {
        let mut r = Request::parse(
            "fetch",
            args(&["https://x.dev", "--format", "markdown,links"]),
        )
        .unwrap();
        r.out = Some(scratch("short"));
        let reply = json!({ "success": true, "data": {
            "markdown": "Hello",
            "links": ["https://a.dev"],
            "metadata": { "sourceURL": "https://x.dev", "statusCode": 404 },
        }});
        let out = futures_util::FutureExt::now_or_never(present_page(&reply, &r))
            .unwrap()
            .unwrap();
        assert_eq!(
            out,
            "https://x.dev (HTTP 404)\n\nHello\n\n## Links (1)\n\n- https://a.dev\n"
        );
    }

    #[test]
    fn formats_without_a_layout_of_their_own_are_passed_on() {
        let mut r = Request::parse(
            "fetch",
            args(&[
                "https://x.dev",
                "--format",
                "query,product",
                "--prompt",
                "price?",
            ]),
        )
        .unwrap();
        assert_eq!(
            r.body["formats"],
            json!([{ "type": "query", "prompt": "price?" }, "product"])
        );
        r.out = Some(scratch("pass"));
        let reply = json!({ "success": true, "data": {
            "answer": "12 euros",
            "product": { "title": "Mug", "price": 12 },
            "metadata": { "url": "https://x.dev", "statusCode": 200 },
        }});
        let out = futures_util::FutureExt::now_or_never(present_page(&reply, &r))
            .unwrap()
            .unwrap();
        assert!(out.contains("## Answer\n\n12 euros\n"), "{out}");
        assert!(out.contains("## Product\n\n{\n  \"price\": 12"), "{out}");
        r.json = true;
        let out = futures_util::FutureExt::now_or_never(present_page(&reply, &r))
            .unwrap()
            .unwrap();
        let page: Value = serde_json::from_str(&out).unwrap();
        assert_eq!(page["answer"], "12 euros");
        assert_eq!(page["product"]["price"], 12);
    }

    #[test]
    fn search_results_list_title_link_and_a_short_snippet() {
        let mut r = Request::parse("search", args(&["q"])).unwrap();
        r.out = Some(scratch("search"));
        let reply = json!({ "success": true, "creditsUsed": 2, "data": {
            "web": [{ "url": "https://a.dev", "title": "A", "description": "x ".repeat(500) }],
            "news": [{ "url": "https://b.dev", "title": "B", "snippet": "news", "date": "2 days ago" }],
        }});
        let out = present_search(&reply, &r).unwrap();
        let lines: Vec<&str> = out.lines().collect();
        assert_eq!(lines[0], "1. [A](https://a.dev)");
        assert!(lines[1].ends_with('…') && lines[1].len() < SNIPPET + 10);
        assert_eq!(lines[2], "2. [B](https://b.dev) (news) · 2 days ago");
        r.json = true;
        let out: Value = serde_json::from_str(&present_search(&reply, &r).unwrap()).unwrap();
        assert_eq!(out["sources"][1]["snippet"], "news");
        assert_eq!(out["creditsUsed"], 2);
    }

    #[test]
    fn file_names_are_readable_and_distinct() {
        let a = file_name("https://docs.rs/reqwest/latest/?q=1", "md");
        assert!(a.starts_with("docs-rs-reqwest-latest-q-1-") && a.ends_with(".md"));
        assert_ne!(a, file_name("https://docs.rs/reqwest/latest/?q=2", "md"));
    }

    #[test]
    fn decodes_base64() {
        assert_eq!(base64_decode("aGVsbG8=").unwrap(), b"hello");
    }

    #[test]
    fn path_gets_the_folder_once() {
        let dir = Path::new("/h/.agent-remote/bin");
        assert_eq!(
            prepend_path(dir, "/usr/bin"),
            "/h/.agent-remote/bin:/usr/bin"
        );
        assert_eq!(
            prepend_path(dir, "/h/.agent-remote/bin:/usr/bin"),
            "/h/.agent-remote/bin:/usr/bin"
        );
    }

    fn firecrawl_of(provider: Result<Provider>) -> (String, String) {
        let Provider::Firecrawl { key, base } = provider.unwrap();
        (key, base)
    }

    #[test]
    fn the_web_config_s_mistyped_parts_fall_back() {
        let both = |key: &str, base: &str| (key.to_string(), base.to_string());
        // A provider that isn't text is Firecrawl, and an address loses its last slashes.
        let web = json!({
            "provider": 7,
            "firecrawlApiKey": "fc-config",
            "firecrawlUrl": "http://firecrawl.test//",
            "extra": true,
        });
        assert_eq!(
            firecrawl_of(Provider::from(Settings::read(&web), None)),
            both("fc-config", "http://firecrawl.test")
        );
        // A key or an address that isn't text is as good as missing.
        let web = json!({ "firecrawlApiKey": 7, "firecrawlUrl": 7 });
        assert_eq!(
            firecrawl_of(Provider::from(Settings::read(&web), Some("fc-env".into()))),
            both("fc-env", FIRECRAWL)
        );
        // So is a `web` that isn't an object.
        for web in [
            json!("other"),
            json!(["other", "fc-config", "http://firecrawl.test"]),
            json!(true),
        ] {
            assert_eq!(
                firecrawl_of(Provider::from(Settings::read(&web), Some("fc-env".into()))),
                both("fc-env", FIRECRAWL),
                "{web}"
            );
        }
        // A blank key is no key, and one in the config hides the environment's.
        assert!(Provider::from(Settings::read(&Value::Null), Some(" ".into())).is_err());
        assert!(Provider::from(
            Settings::read(&json!({ "firecrawlApiKey": "" })),
            Some("fc-env".into())
        )
        .is_err());
        let Err(unknown) = Provider::from(
            Settings::read(&json!({ "provider": "other" })),
            Some("fc-env".into()),
        ) else {
            panic!("an unknown provider was taken")
        };
        assert_eq!(
            unknown.to_string(),
            "Shed has no web provider called \"other\" (it knows: firecrawl)"
        );

        // `web` within the whole config.
        let config = json!({ "web": { "firecrawlApiKey": "fc-config" }, "opencodex": false });
        assert_eq!(
            firecrawl_of(Provider::in_config(&config, None)),
            both("fc-config", FIRECRAWL)
        );
        for config in [
            json!([{ "firecrawlApiKey": "fc-config" }]),
            json!({ "web": null }),
            json!({ "firecrawl": { "firecrawlApiKey": "fc-config" } }),
            Value::Null,
        ] {
            assert!(Provider::in_config(&config, None).is_err(), "{config}");
            assert_eq!(
                firecrawl_of(Provider::in_config(&config, Some("fc-env".into()))),
                both("fc-env", FIRECRAWL),
                "{config}"
            );
        }
    }

    #[test]
    fn a_reply_is_taken_unless_its_status_or_firecrawl_says_it_failed() {
        use reqwest::StatusCode;
        let taken = |text: &str| answer(StatusCode::OK, text).unwrap();
        assert_eq!(
            taken(r#"{"success":true,"data":{"web":[]},"extra":1}"#),
            json!({ "success": true, "data": { "web": [] }, "extra": 1 })
        );
        // Only `false` itself is a failure.
        for text in [
            r#"{"data":{}}"#,
            r#"{"success":"false","error":"quota"}"#,
            r#"{"success":0,"error":"quota"}"#,
            r#"{"success":null,"error":"quota"}"#,
            r#"[false,"quota"]"#,
        ] {
            let reply: Value = serde_json::from_str(text).unwrap();
            assert_eq!(taken(text), reply);
        }
        // A body that isn't JSON is an empty reply.
        assert_eq!(taken("<html>"), Value::Null);
        assert_eq!(taken(""), Value::Null);

        let failed = |status: StatusCode, text: &str| answer(status, text).unwrap_err().to_string();
        assert_eq!(
            failed(
                StatusCode::OK,
                r#"{"success":false,"error":"no credits left","code":7}"#
            ),
            "Firecrawl answered 200 OK: no credits left"
        );
        assert_eq!(
            failed(
                StatusCode::PAYMENT_REQUIRED,
                r#"{"error":"no credits left"}"#
            ),
            "Firecrawl answered 402 Payment Required: no credits left"
        );
        // Without an error in text, the body as it came, or its first 500 characters.
        for text in [
            r#"{"success":false,"error":{"code":7}}"#,
            r#"{"success":false}"#,
            r#"[false,"quota"]"#,
            "<html>down</html>",
            "",
        ] {
            assert_eq!(
                failed(StatusCode::BAD_GATEWAY, text),
                format!("Firecrawl answered 502 Bad Gateway: {text}")
            );
        }
        assert_eq!(
            failed(StatusCode::OK, r#"{"success":false,"error":7}"#),
            r#"Firecrawl answered 200 OK: {"success":false,"error":7}"#
        );
        assert_eq!(
            failed(StatusCode::BAD_GATEWAY, &"é".repeat(600)),
            format!("Firecrawl answered 502 Bad Gateway: {}", "é".repeat(500))
        );
    }

    #[test]
    fn the_credits_logged_are_the_reply_s_or_else_its_page_s() {
        let page = |used: Value| json!({ "success": true, "data": { "metadata": { "creditsUsed": used, "title": "T" } } });
        assert_eq!(
            credits(&json!({ "creditsUsed": 2, "data": { "metadata": { "creditsUsed": 5 } } })),
            Some(2)
        );
        assert_eq!(credits(&json!({ "creditsUsed": 0, "data": {} })), Some(0));
        assert_eq!(credits(&page(json!(5))), Some(5));
        // A count that isn't a whole number is no count.
        for used in [json!("2"), json!(2.0), json!(-2), json!([2]), Value::Null] {
            let mut reply = page(json!(5));
            reply["creditsUsed"] = used.clone();
            assert_eq!(credits(&reply), Some(5), "{used}");
            assert_eq!(credits(&json!({ "creditsUsed": used })), None, "{used}");
            assert_eq!(credits(&page(used.clone())), None, "{used}");
        }
        for reply in [
            json!({}),
            json!({ "data": { "creditsUsed": 5 } }),
            json!({ "data": [{ "creditsUsed": 5 }] }),
            json!({ "data": { "metadata": [5] } }),
            json!({ "data": { "metadata": 5 } }),
            json!([2, { "metadata": { "creditsUsed": 5 } }]),
            Value::Null,
        ] {
            assert_eq!(credits(&reply), None, "{reply}");
        }
    }

    /// A JSON string holding the path of the file `url` was saved to in `dir`.
    fn saved(dir: &Path, url: &str, ext: &str) -> String {
        json!(dir.join(file_name(url, ext))).to_string()
    }

    #[test]
    fn a_search_reads_each_result_s_parts_as_they_come() {
        let dir = scratch("search-shapes");
        let mut r = Request::parse("search", args(&["q"])).unwrap();
        r.out = Some(dir.clone());
        let reply = json!({ "success": true, "creditsUsed": "two", "warning": null, "data": {
            "web": [
                {
                    "url": "https://a.test/one",
                    "title": "One",
                    "description": "first  result\n here",
                    "snippet": "unused",
                    "date": "2026-01-02",
                    "imageUrl": "https://a.test/one.png",
                    "markdown": "# One\n\nbody",
                    "position": 1,
                },
                { "url": 7, "title": 7, "description": 7, "snippet": "from snippet", "date": 2026, "markdown": 7 },
                { "url": "https://a.test/empty", "title": "", "snippet": 7, "markdown": "" },
                "bare",
                ["https://a.test/listed", "Listed"],
            ],
            "news": { "url": "https://a.test/not-a-list" },
            "images": [
                { "url": "https://a.test/pic", "title": "Pic", "imageUrl": "https://a.test/pic.png" },
                { "url": "https://a.test/other-pic", "imageUrl": 9 },
            ],
            "videos": [{ "url": "https://a.test/video" }],
        }});
        let file = saved(&dir, "https://a.test/one", "md");
        let shown = &file[1..file.len() - 1];
        assert_eq!(
            present_search(&reply, &r).unwrap(),
            format!(
                "1. [One](https://a.test/one) · 2026-01-02\n\
                 \x20  first result here\n\
                 \x20  Page as Markdown (11 characters): {shown}\n\
                 \x20  > # One\n\
                 \x20  > \n\
                 \x20  > body\n\
                 2. []()\n\
                 \x20  from snippet\n\
                 3. [https://a.test/empty](https://a.test/empty)\n\
                 4. []()\n\
                 5. []()\n\
                 6. [Pic](https://a.test/pic) (images)\n\
                 \x20  image: https://a.test/pic.png\n\
                 7. [https://a.test/other-pic](https://a.test/other-pic) (images)\n"
            )
        );
        assert_eq!(
            std::fs::read_to_string(dir.join(file_name("https://a.test/one", "md"))).unwrap(),
            "# One\n\nbody"
        );
        // As JSON, a title, a date, an image link and the credits go out as they came, whatever they are.
        r.json = true;
        assert_eq!(
            present_search(&reply, &r).unwrap(),
            [
                r#"{"creditsUsed":"two","sources":["#,
                r#"{"characters":11,"file":"#,
                &file,
                r##","kind":"web","markdown":"# One\n\nbody","publishedAt":"2026-01-02","##,
                r#""snippet":"first result here","title":"One","url":"https://a.test/one"},"#,
                r#"{"kind":"web","publishedAt":2026,"snippet":"from snippet","title":7,"url":""},"#,
                r#"{"kind":"web","publishedAt":null,"snippet":null,"title":"","url":"https://a.test/empty"},"#,
                r#"{"kind":"web","publishedAt":null,"snippet":null,"title":null,"url":""},"#,
                r#"{"kind":"web","publishedAt":null,"snippet":null,"title":null,"url":""},"#,
                r#"{"imageUrl":"https://a.test/pic.png","kind":"images","publishedAt":null,"snippet":null,"#,
                r#""title":"Pic","url":"https://a.test/pic"},"#,
                r#"{"imageUrl":9,"kind":"images","publishedAt":null,"snippet":null,"title":null,"#,
                r#""url":"https://a.test/other-pic"}"#,
                "]}\n",
            ]
            .concat()
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_search_with_nothing_to_read_has_no_results() {
        let mut r = Request::parse("search", args(&["q"])).unwrap();
        r.out = Some(scratch("search-empty"));
        for reply in [
            json!({ "success": true, "data": { "web": [] } }),
            json!({ "data": [[{ "url": "https://a.test" }]] }),
            json!({ "data": "none" }),
            json!({ "web": [{ "url": "https://a.test" }] }),
            json!([2, { "web": [{ "url": "https://a.test" }] }]),
            Value::Null,
        ] {
            r.json = false;
            assert_eq!(present_search(&reply, &r).unwrap(), "No results.\n");
            r.json = true;
            assert_eq!(
                present_search(&reply, &r).unwrap(),
                "{\"creditsUsed\":null,\"sources\":[]}\n",
                "{reply}"
            );
        }
    }

    #[test]
    fn a_search_that_reads_its_results_prints_the_start_of_each() {
        let dir = scratch("search-scrape");
        let mut r = Request::parse("search", args(&["q", "--scrape", "--json"])).unwrap();
        r.out = Some(dir.clone());
        let long = "word ".repeat(400);
        let reply = json!({ "creditsUsed": 3, "data": { "news": [
            { "url": "https://a.test/long", "markdown": long },
        ]}});
        let out: Value = serde_json::from_str(&present_search(&reply, &r).unwrap()).unwrap();
        assert_eq!(out["creditsUsed"], 3);
        assert_eq!(out["sources"][0]["kind"], "news");
        assert_eq!(out["sources"][0]["characters"], 2_000);
        assert_eq!(out["sources"][0]["markdown"], long[..SCRAPED_PREVIEW]);
        r.full = true;
        let out: Value = serde_json::from_str(&present_search(&reply, &r).unwrap()).unwrap();
        assert_eq!(out["sources"][0]["markdown"], long);
        let _ = std::fs::remove_dir_all(&dir);
    }

    fn page_of(reply: &Value, r: &Request) -> String {
        futures_util::FutureExt::now_or_never(present_page(reply, r))
            .unwrap()
            .unwrap()
    }

    #[test]
    fn a_page_s_formats_are_laid_out_or_passed_on() {
        let dir = scratch("page-shapes");
        let mut r = Request::parse("fetch", args(&["https://x.test/doc"])).unwrap();
        r.out = Some(dir.clone());
        let reply = json!({ "success": true, "data": {
            "markdown": "Hello",
            "summary": 5,
            "html": "<p>Hello</p>",
            "rawHtml": null,
            "rawBase64": "aGVsbG8=",
            "screenshot": "data:image/png;base64,aGVsbG8=",
            "warning": "slow page",
            "links": ["https://a.test/one", "https://a.test/two"],
            "json": { "price": 12 },
            "actions": null,
            "answer": "42",
            "metadata": {
                "url": "https://x.test/doc",
                "sourceURL": "https://x.test/source",
                "statusCode": "200",
                "title": 7,
                "creditsUsed": 1,
                "language": "en",
            },
        }});
        let url = "https://x.test/doc";
        let (html, raw, shot) = (
            saved(&dir, url, "html"),
            saved(&dir, url, "raw"),
            saved(&dir, url, "png"),
        );
        let shown = |file: &str| file[1..file.len() - 1].to_string();
        assert_eq!(
            page_of(&reply, &r),
            format!(
                "https://x.test/doc\n\
                 Warning: slow page\n\
                 \n\
                 Hello\n\
                 \n\
                 ## Answer\n\
                 \n\
                 42\n\
                 \n\
                 ## Extracted\n\
                 \n\
                 {{\n\
                 \x20 \"price\": 12\n\
                 }}\n\
                 \n\
                 ## Links (2)\n\
                 \n\
                 - https://a.test/one\n\
                 - https://a.test/two\n\
                 \n\
                 [HTML: {}]\n\
                 [Response body: {}]\n\
                 [Screenshot: {}]\n",
                shown(&html),
                shown(&raw),
                shown(&shot)
            )
        );
        let read = |ext: &str| std::fs::read(dir.join(file_name(url, ext))).unwrap();
        assert_eq!(read("html"), b"<p>Hello</p>");
        assert_eq!(read("raw"), b"hello");
        assert_eq!(read("png"), b"hello");

        // As JSON, the metadata goes out whole, and a status and a title as they came, whatever they are.
        r.json = true;
        let metadata = r#"{"creditsUsed":1,"language":"en","sourceURL":"https://x.test/source","statusCode":"200","title":7,"url":"https://x.test/doc"}"#;
        let expected = |html_inline: &str| {
            [
                r#"{"answer":"42","#,
                html_inline,
                r#""htmlCharacters":12,"htmlFile":"#,
                &html,
                r#","json":{"price":12},"links":["https://a.test/one","https://a.test/two"],"#,
                r#""markdown":"Hello","metadata":"#,
                metadata,
                r#","rawFile":"#,
                &raw,
                r#","screenshotFile":"#,
                &shot,
                r#","statusCode":"200","title":7,"url":"https://x.test/doc","warning":"slow page"}"#,
                "\n",
            ]
            .concat()
        };
        assert_eq!(page_of(&reply, &r), expected(""));
        r.full = true;
        assert_eq!(page_of(&reply, &r), expected(r#""html":"<p>Hello</p>","#));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_page_with_parts_missing_or_mistyped_is_printed_without_them() {
        let mut r = Request::parse("fetch", args(&["https://x.test"])).unwrap();
        r.out = Some(scratch("page-missing"));
        let both = |reply: Value, r: &mut Request| {
            r.json = false;
            let text = page_of(&reply, r);
            r.json = true;
            (text, page_of(&reply, r))
        };
        let empty = "{\"metadata\":null,\"statusCode\":null,\"title\":null,\"url\":\"\"}\n";
        for reply in [
            json!({ "success": true }),
            json!({ "data": null }),
            json!({ "data": ["Hello"] }),
            json!({ "data": "Hello" }),
            json!({ "markdown": "Hello" }),
            json!([{ "markdown": "Hello" }]),
            Value::Null,
        ] {
            assert_eq!(
                both(reply.clone(), &mut r),
                ("\n".into(), empty.into()),
                "{reply}"
            );
        }
        // No metadata: no address, title or status.
        assert_eq!(
            both(json!({ "data": { "markdown": "Hi", "summary": "Short" } }), &mut r),
            (
                "\n\n## Summary\n\nShort\n\nHi\n".into(),
                "{\"markdown\":\"Hi\",\"metadata\":null,\"statusCode\":null,\"summary\":\"Short\",\"title\":null,\"url\":\"\"}\n"
                    .into()
            )
        );
        // Metadata that isn't an object goes out as it came and is read as empty.
        for metadata in [
            json!("none"),
            json!(["https://x.test", "https://x.test", 404, "T"]),
        ] {
            assert_eq!(
                both(json!({ "data": { "metadata": metadata } }), &mut r),
                (
                    "\n".into(),
                    format!("{{\"metadata\":{metadata},\"statusCode\":null,\"title\":null,\"url\":\"\"}}\n")
                )
            );
        }
        // An address that isn't text gives way to the source's; text that isn't text is left out.
        assert_eq!(
            both(
                json!({ "data": {
                    "markdown": ["Hi"],
                    "html": 7,
                    "rawHtml": 7,
                    "rawBase64": 7,
                    "screenshot": 7,
                    "warning": 7,
                    "metadata": { "url": 7, "sourceURL": "https://x.test/source", "statusCode": 404.0, "title": "" },
                }}),
                &mut r
            ),
            (
                "https://x.test/source\n".into(),
                "{\"metadata\":{\"sourceURL\":\"https://x.test/source\",\"statusCode\":404.0,\"title\":\"\",\"url\":7},\
                 \"statusCode\":404.0,\"title\":\"\",\"url\":\"https://x.test/source\"}\n"
                    .into()
            )
        );
    }

    #[test]
    fn a_format_named_like_one_of_the_page_s_own_fields_takes_its_place() {
        let mut r = Request::parse("fetch", args(&["https://x.test/doc"])).unwrap();
        r.out = Some(scratch("page-names"));
        let reply = json!({ "data": {
            "title": "Top",
            "url": "https://x.test/other",
            "statusCode": 404,
            "htmlFile": "/elsewhere",
            "metadata": { "url": "https://x.test/doc", "title": "Doc", "statusCode": 200 },
        }});
        assert_eq!(
            page_of(&reply, &r),
            "# Top\n\
             https://x.test/doc (HTTP 404)\n\
             \n\
             ## HtmlFile\n\
             \n\
             /elsewhere\n\
             \n\
             ## StatusCode\n\
             \n\
             404\n\
             \n\
             ## Title\n\
             \n\
             Top\n\
             \n\
             ## Url\n\
             \n\
             https://x.test/other\n\
             \n\
             [HTML: /elsewhere]\n"
        );
        r.json = true;
        assert_eq!(
            page_of(&reply, &r),
            "{\"htmlFile\":\"/elsewhere\",\
             \"metadata\":{\"statusCode\":200,\"title\":\"Doc\",\"url\":\"https://x.test/doc\"},\
             \"statusCode\":404,\"title\":\"Top\",\"url\":\"https://x.test/other\"}\n"
        );
    }

    #[test]
    fn long_text_is_cut_as_json_too_and_a_long_format_goes_to_a_file() {
        let dir = scratch("page-long");
        let mut r = Request::parse("fetch", args(&["https://x.test/doc", "--json"])).unwrap();
        r.out = Some(dir.clone());
        let long = "line of text\n".repeat(3_000);
        let reply = json!({ "data": {
            "summary": long,
            "answer": "a".repeat(LONG + 1),
            "metadata": { "url": "https://x.test/doc" },
        }});
        let page: Value = serde_json::from_str(&page_of(&reply, &r)).unwrap();
        assert_eq!(page["truncated"], true);
        assert_eq!(page["summary"], head(&long, PREVIEW));
        let file = dir.join(file_name("https://x.test/doc", "summary.md"));
        assert_eq!(page["summaryFile"], json!(file));
        assert_eq!(std::fs::read_to_string(&file).unwrap(), long);
        assert_eq!(page["answer"], "a".repeat(LONG + 1));

        r.json = false;
        let out = page_of(&reply, &r);
        let answer = dir.join(file_name("https://x.test/doc", "answer.txt"));
        assert!(!out.contains("## Answer"), "{out}");
        assert!(
            out.ends_with(&format!(
                "[The summary is 39,000 characters; the first 8,000 are above. All of it: {}]\n[Answer: {}]\n",
                file.display(),
                answer.display()
            )),
            "{out}"
        );
        assert_eq!(
            std::fs::read_to_string(&answer).unwrap(),
            "a".repeat(LONG + 1)
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}
