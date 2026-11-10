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
  --format LIST        markdown (default), summary, html, rawHtml, links, images, screenshot,
                       screenshot@fullPage, json, branding, changeTracking; repeatable or comma-separated
  --prompt TEXT        what to extract, for --format json
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
/// Done at every start, so a bridge that sync updates brings both with it.
pub fn install() {
    let Ok(exe) = std::env::current_exe() else {
        return;
    };
    let Some(bin) = exe.parent() else { return };
    let link = bin.join("shed-web");
    let target = exe.file_name().map(PathBuf::from).unwrap_or_default();
    if std::fs::read_link(&link).ok().as_deref() != Some(target.as_path()) {
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

enum Provider {
    Firecrawl { key: String, base: String },
}

impl Provider {
    fn from_config() -> Result<Provider> {
        let config: Value = std::fs::read_to_string(home().join(".agent-remote/config.json"))
            .ok()
            .and_then(|raw| serde_json::from_str(&raw).ok())
            .unwrap_or_default();
        Self::from(&config["web"], std::env::var("FIRECRAWL_API_KEY").ok())
    }

    fn from(web: &Value, env_key: Option<String>) -> Result<Provider> {
        match web["provider"].as_str().unwrap_or("firecrawl") {
            "firecrawl" => {
                let key = web["firecrawlApiKey"]
                    .as_str()
                    .map(str::to_string)
                    .or(env_key)
                    .filter(|k| !k.trim().is_empty())
                    .ok_or_else(|| {
                        anyhow!(
                            "web search isn't set up on this Mac: Shed needs a Firecrawl key, \
                             `web.firecrawlApiKey` in ~/.agent-remote/config.json"
                        )
                    })?;
                let base = web["firecrawlUrl"]
                    .as_str()
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
    let reply: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
    if !status.is_success() || reply["success"] == json!(false) {
        let message = reply["error"]
            .as_str()
            .map(str::to_string)
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
        Ok(reply) => {
            let credits = reply["creditsUsed"]
                .as_u64()
                .or(reply["data"]["metadata"]["creditsUsed"].as_u64());
            json!({ "ok": true, "credits": credits })
        }
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
    let _ = std::fs::create_dir_all(&dir);
    if let Ok(mut file) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join("web.log"))
    {
        let _ = writeln!(file, "{line}");
    }
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

fn present_search(reply: &Value, request: &Request) -> Result<String> {
    let dir = request.files();
    let mut sources = vec![];
    for kind in ["web", "news", "images"] {
        for item in reply["data"][kind].as_array().into_iter().flatten() {
            let url = item["url"].as_str().unwrap_or_default();
            let mut source = json!({
                "kind": kind,
                "url": url,
                "title": item["title"],
                "snippet": item["description"].as_str().or(item["snippet"].as_str()).map(snippet),
                "publishedAt": item["date"],
            });
            if kind == "images" {
                source["imageUrl"] = item["imageUrl"].clone();
            }
            if let Some(markdown) = item["markdown"].as_str().filter(|m| !m.is_empty()) {
                let path = save(&dir, &file_name(url, "md"), markdown.as_bytes())?;
                source["file"] = json!(path);
                source["characters"] = json!(chars(markdown));
                source["markdown"] = json!(if request.full {
                    markdown
                } else {
                    head(markdown, SCRAPED_PREVIEW)
                });
            }
            sources.push(source);
        }
    }
    if request.json {
        let out = json!({ "sources": sources, "creditsUsed": reply["creditsUsed"] });
        return Ok(format!("{out}\n"));
    }
    if sources.is_empty() {
        return Ok("No results.\n".into());
    }
    let mut out = String::new();
    for (i, s) in sources.iter().enumerate() {
        let url = s["url"].as_str().unwrap_or_default();
        let title = s["title"].as_str().filter(|t| !t.is_empty()).unwrap_or(url);
        out += &format!("{}. [{title}]({url})", i + 1);
        if s["kind"] != "web" {
            out += &format!(" ({})", s["kind"].as_str().unwrap_or_default());
        }
        if let Some(date) = s["publishedAt"].as_str() {
            out += &format!(" · {date}");
        }
        out += "\n";
        if let Some(image) = s["imageUrl"].as_str() {
            out += &format!("   image: {image}\n");
        }
        if let Some(text) = s["snippet"].as_str().filter(|t| !t.is_empty()) {
            out += &format!("   {text}\n");
        }
        if let (Some(file), Some(n)) = (s["file"].as_str(), s["characters"].as_u64()) {
            out += &format!(
                "   Page as Markdown ({} characters): {file}\n",
                thousands(n as usize)
            );
            if let Some(md) = s["markdown"].as_str() {
                for line in md.lines() {
                    out += &format!("   > {line}\n");
                }
            }
        }
    }
    Ok(out)
}

async fn present_page(reply: &Value, request: &Request) -> Result<String> {
    let data = &reply["data"];
    let meta = &data["metadata"];
    let url = meta["url"]
        .as_str()
        .or(meta["sourceURL"].as_str())
        .unwrap_or_default()
        .to_string();
    let dir = request.files();
    let mut page = json!({
        "url": url,
        "statusCode": meta["statusCode"],
        "title": meta["title"],
    });
    let mut notes: Vec<String> = vec![];

    // Text a reader wants in the reply: whole when short (or asked for), else its start and the whole in a file.
    let mut text = |field: &str, ext: &str, page: &mut Value| -> Result<()> {
        let Some(content) = data[field].as_str() else {
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
    text("markdown", "md", &mut page)?;
    text("summary", "summary.md", &mut page)?;

    // HTML goes to a file (and inline too when the whole page was asked for).
    for (field, ext) in [("html", "html"), ("rawHtml", "raw.html")] {
        if let Some(content) = data[field].as_str() {
            let path = save(&dir, &file_name(&url, ext), content.as_bytes())?;
            page[format!("{field}File")] = json!(path);
            page[format!("{field}Characters")] = json!(chars(content));
            if request.full && request.json {
                page[field] = json!(content);
            }
        }
    }
    for field in ["links", "images", "json", "branding", "changeTracking"] {
        if !data[field].is_null() {
            page[field] = data[field].clone();
        }
    }
    if let Some(shot) = data["screenshot"].as_str() {
        page["screenshotFile"] = json!(screenshot(shot, &dir, &url).await?);
    }
    if let Some(warning) = data["warning"].as_str() {
        page["warning"] = json!(warning);
    }

    if request.json {
        page["metadata"] = meta.clone();
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
    if !page["json"].is_null() {
        out += &format!("\n## Extracted\n\n{:#}\n", page["json"]);
    }
    for field in ["links", "images"] {
        if let Some(list) = page[field].as_array() {
            out += &format!("\n## {} ({})\n\n", capitalize(field), list.len());
            for item in list {
                out += &format!(
                    "- {}\n",
                    item.as_str().map_or(item.to_string(), str::to_string)
                );
            }
        }
    }
    for field in ["branding", "changeTracking"] {
        if !page[field].is_null() {
            out += &format!("\n## {field}\n\n{:#}\n", page[field]);
        }
    }
    for (field, what) in [("htmlFile", "HTML"), ("rawHtmlFile", "Raw HTML")] {
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
            Provider::from(&config, Some("fc-env".into())).unwrap();
        assert_eq!((key.as_str(), base.as_str()), ("fc-config", FIRECRAWL));
        let Provider::Firecrawl { key, .. } =
            Provider::from(&Value::Null, Some("fc-env".into())).unwrap();
        assert_eq!(key, "fc-env");
        assert!(Provider::from(&Value::Null, None).is_err());
        assert!(Provider::from(&json!({ "provider": "other" }), Some("k".into())).is_err());
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
}
