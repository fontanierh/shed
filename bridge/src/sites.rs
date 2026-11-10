//! Sites: web servers the agents start. The bridge finds them by looking at the ports the sessions' own processes
//! listen on, so any server counts (`vite`, `python -m http.server`, `cargo run`) without the agent registering it.
//!
//! Each site gets its own `tailscale serve` HTTPS port, so the iPhone can open it: one port per site, never a path
//! prefix, because an app with absolute asset URLs breaks under a prefix. Tailnet only, never Funnel;
//! `"sites": {"publish": false}` in config.json turns it off. A route somebody else made to the same server is used
//! as it is. The bridge only ever removes routes it recorded in `sites.json`: the serve config is shared with whatever
//! else the user publishes by hand, and a sweep would take those too.
//!
//! A server started detached (`nohup`, a daemon) leaves its session's process tree for launchd's. It stays its
//! session's once seen there; one never seen goes to the session working in the folder it runs in.

use std::collections::{BTreeMap, HashMap};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::jobs::ProcessTree;
use crate::protocol::Site;

/// A listening socket, as `lsof` reports it, with the process that owns it.
#[derive(Debug, Clone)]
pub struct Listener {
    pub port: u16,
    /// The address it is bound to: `127.0.0.1`, `*`, `[::1]`.
    pub bind: String,
    pub command: String,
}

/// What the bridge remembers about a site it published, so it can take the route down again.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Published {
    pub port: u16,
    pub session_id: String,
    /// The tailnet port it answers on, when the site's own was taken there.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub served: Option<u16>,
}

impl Published {
    fn tailnet_port(&self) -> u16 {
        self.served.unwrap_or(self.port)
    }
}

/// Tailnet ports for sites whose own port is taken there. The agents are told to serve on these too.
const SPARE_PORTS: std::ops::RangeInclusive<u16> = 8100..=8199;

/// `sites` in config.json: `{ "publish": false }` keeps sites off the tailnet. Read each time, so editing the file
/// takes effect without a restart.
#[derive(Debug, Clone, Copy)]
pub struct Config {
    pub publish: bool,
}

impl Config {
    pub fn read(dir: &std::path::Path) -> Config {
        let raw = std::fs::read_to_string(dir.join("config.json")).unwrap_or_default();
        Config::parse(&raw)
    }

    /// Published unless the file says not to: a site nobody can open from the phone is no use.
    fn parse(raw: &str) -> Config {
        let config = serde_json::from_str::<Value>(raw).unwrap_or(Value::Null);
        Config {
            publish: config["sites"]["publish"].as_bool().unwrap_or(true),
        }
    }
}

/// Every listening TCP socket on the machine, by the pid that holds it. One `lsof` for all sessions.
pub async fn listeners() -> Option<HashMap<u32, Vec<Listener>>> {
    let out = tokio::process::Command::new("/usr/sbin/lsof")
        .args(["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"])
        .output()
        .await
        .ok()?;
    Some(parse_lsof(&String::from_utf8_lossy(&out.stdout)))
}

/// `lsof -Fpcn` output: `p<pid>`, `c<command>`, then one `n<address>` per matching socket.
fn parse_lsof(text: &str) -> HashMap<u32, Vec<Listener>> {
    let mut out: HashMap<u32, Vec<Listener>> = HashMap::new();
    let mut pid: Option<u32> = None;
    let mut command = String::new();
    for line in text.lines() {
        let Some((tag, rest)) = line.split_at_checked(1) else {
            continue;
        };
        match tag {
            "p" => {
                pid = rest.parse().ok();
                command.clear();
            }
            "c" => command = rest.to_string(),
            "n" => {
                let (Some(pid), Some((bind, port))) = (pid, split_address(rest)) else {
                    continue;
                };
                let entry = Listener {
                    port,
                    bind: bind.to_string(),
                    command: command.clone(),
                };
                let list = out.entry(pid).or_default();
                if !list.iter().any(|l| l.port == port && l.bind == entry.bind) {
                    list.push(entry);
                }
            }
            _ => {}
        }
    }
    out
}

/// `127.0.0.1:8890`, `*:8080`, `[::1]:8080` → the address and the port.
fn split_address(name: &str) -> Option<(&str, u16)> {
    let (bind, port) = name.rsplit_once(':')?;
    Some((bind, port.parse().ok()?))
}

/// A port bound to every interface, or to a LAN address: reachable from the local network, not just this Mac and the
/// tailnet. Loopback and Tailscale's own addresses (100.64.0.0/10, fd7a:115c:a1e0::/48) are not.
fn exposed(bind: &str) -> bool {
    let addr = bind.trim_start_matches('[').trim_end_matches(']');
    if addr == "localhost" {
        return false;
    }
    match addr.parse::<std::net::IpAddr>() {
        Ok(std::net::IpAddr::V4(ip)) => {
            let [a, b, ..] = ip.octets();
            !(ip.is_loopback() || (a == 100 && (64..128).contains(&b)))
        }
        Ok(std::net::IpAddr::V6(ip)) => {
            let s = ip.segments();
            !(ip.is_loopback() || (s[0] == 0xfd7a && s[1] == 0x115c && s[2] == 0xa1e0))
        }
        // `*`: every interface.
        Err(_) => true,
    }
}

/// Where a listening port answers, from the addresses it is bound to.
#[derive(Debug, Clone, PartialEq)]
enum Reach {
    /// On this Mac's loopback, at this host: Tailscale can route to it.
    Local(&'static str),
    /// On the Mac's own tailnet address only: it is on the tailnet already, at its own port, and a route there would
    /// take its place and find nothing behind it.
    Tailnet(String),
    /// On another address only (a LAN one): Tailscale can't route to it.
    Elsewhere(String),
}

impl Reach {
    /// Where the bridge itself asks the site for its title.
    fn host(&self) -> &str {
        match self {
            Reach::Local(host) => host,
            Reach::Tailnet(bind) | Reach::Elsewhere(bind) => bind,
        }
    }
}

fn reach<'a>(binds: impl IntoIterator<Item = &'a str>) -> Reach {
    let mut v6_only = false;
    let mut tailnet = None;
    let mut other = None;
    for bind in binds {
        let addr = bind.trim_start_matches('[').trim_end_matches(']');
        match addr.parse::<std::net::IpAddr>() {
            Ok(std::net::IpAddr::V4(ip)) if ip.is_loopback() => return Reach::Local("127.0.0.1"),
            Ok(std::net::IpAddr::V6(ip)) if ip.is_loopback() => v6_only = true,
            Ok(_) if !exposed(bind) => tailnet = Some(bind),
            Ok(_) => other = Some(bind),
            // `*` (every interface) and `localhost`.
            Err(_) => return Reach::Local("127.0.0.1"),
        }
    }
    match (v6_only, tailnet, other) {
        // `localhost` rather than `[::1]`: the one name for it `tailscale serve` takes.
        (true, _, _) => Reach::Local("localhost"),
        (_, Some(bind), _) => Reach::Tailnet(bind.to_string()),
        (_, _, Some(bind)) => Reach::Elsewhere(bind.to_string()),
        (false, None, None) => Reach::Local("127.0.0.1"),
    }
}

/// The `<title>` of the page a site serves, for the list. One short request, made once per site.
async fn title(host: &str, port: u16) -> Option<String> {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let connect = tokio::net::TcpStream::connect(format!("{host}:{port}"));
    let mut stream = tokio::time::timeout(Duration::from_millis(1500), connect)
        .await
        .ok()?
        .ok()?;
    let request = format!("GET / HTTP/1.0\r\nHost: {host}:{port}\r\nAccept: text/html\r\n\r\n");
    tokio::time::timeout(
        Duration::from_millis(1500),
        stream.write_all(request.as_bytes()),
    )
    .await
    .ok()?
    .ok()?;
    let mut body = Vec::new();
    let read = tokio::time::timeout(Duration::from_millis(2500), async {
        let mut chunk = [0u8; 8192];
        while body.len() < 128 * 1024 {
            match stream.read(&mut chunk).await {
                Ok(0) | Err(_) => break,
                Ok(n) => body.extend_from_slice(&chunk[..n]),
            }
            // Enough for the head and the start of the document, where a title lives.
            if body.windows(7).any(|w| w == b"</title") {
                break;
            }
        }
    })
    .await;
    let _ = read;
    let text = String::from_utf8_lossy(&body);
    page_title(&text)
}

/// The first `<title>` in an HTML document, trimmed and shortened.
fn page_title(html: &str) -> Option<String> {
    let lower = html.to_ascii_lowercase();
    let open = lower.find("<title")?;
    let start = lower[open..].find('>')? + open + 1;
    let end = lower[start..].find("</title")? + start;
    let title = html[start..end]
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    let title = title.trim();
    if title.is_empty() {
        return None;
    }
    Some(title.chars().take(80).collect())
}

/// The Tailscale CLI: on PATH, or inside the app as the App Store and the cask install it (as `setup/install.sh` finds it).
fn tailscale() -> tokio::process::Command {
    const APP: &str = "/Applications/Tailscale.app/Contents/MacOS/Tailscale";
    let on_path = std::env::var_os("PATH").is_some_and(|path| {
        std::env::split_paths(&path).any(|dir| dir.join("tailscale").is_file())
    });
    let program = if !on_path && std::path::Path::new(APP).is_file() {
        APP
    } else {
        "tailscale"
    };
    tokio::process::Command::new(program)
}

/// The tailnet name this bridge is published under, e.g. `jims-macbook-pro.tail362838.ts.net`, and the ports
/// `tailscale serve` already answers on. `None` when Tailscale isn't installed or isn't running.
async fn serve_state() -> Option<(String, HashMap<u16, String>)> {
    let status = tailscale().args(["status", "--json"]).output().await.ok()?;
    if !status.status.success() {
        return None;
    }
    let status: Value = serde_json::from_slice(&status.stdout).ok()?;
    let host = status["Self"]["DNSName"]
        .as_str()?
        .trim_end_matches('.')
        .to_string();
    let served = tailscale()
        .args(["serve", "status", "--json"])
        .output()
        .await
        .ok()?;
    if !served.status.success() {
        return None;
    }
    // Nothing served prints `{}`, or nothing at all on some versions.
    let served: Value = if served.stdout.iter().all(u8::is_ascii_whitespace) {
        Value::Null
    } else {
        serde_json::from_slice(&served.stdout).ok()?
    };
    Some((host, served_ports(&served)))
}

/// The ports `tailscale serve` has handlers on, each with what the `/` handler proxies to. TCP forwards count too: a
/// port is taken whatever answers on it.
fn served_ports(served: &Value) -> HashMap<u16, String> {
    let mut out = HashMap::new();
    for port in served["TCP"]
        .as_object()
        .into_iter()
        .flat_map(|tcp| tcp.keys())
    {
        if let Ok(port) = port.parse::<u16>() {
            out.insert(port, String::new());
        }
    }
    let Some(web) = served["Web"].as_object() else {
        return out;
    };
    for (host, config) in web {
        let Some(port) = host
            .rsplit_once(':')
            .and_then(|(_, p)| p.parse::<u16>().ok())
        else {
            continue;
        };
        let proxy = config["Handlers"]["/"]["Proxy"]
            .as_str()
            .unwrap_or_default()
            .to_string();
        out.insert(port, proxy);
    }
    out
}

/// The served port that already leads to a site: a route the user or an agent made by hand, or the bridge's own.
fn route_to(served: &HashMap<u16, String>, port: u16) -> Option<u16> {
    served
        .iter()
        .filter(|(_, proxy)| proxies_to(proxy, port))
        .map(|(served, _)| *served)
        .min()
}

/// `http://127.0.0.1:8123`, `localhost:8123`, `https+insecure://127.0.0.1:8123/`: this Mac's `port`.
fn proxies_to(proxy: &str, port: u16) -> bool {
    let address = proxy.rsplit_once("://").map_or(proxy, |(_, rest)| rest);
    let address = address.split('/').next().unwrap_or(address);
    let Some((host, to)) = address.rsplit_once(':') else {
        // `tailscale serve 8123` records the bare port.
        return address.parse() == Ok(port);
    };
    matches!(host, "127.0.0.1" | "localhost" | "[::1]") && to.parse() == Ok(port)
}

/// A tailnet port for a site: its own, or the first spare one when that is taken.
fn tailnet_port(port: u16, served: &HashMap<u16, String>, listening: &[u16]) -> Option<u16> {
    if !served.contains_key(&port) {
        return Some(port);
    }
    SPARE_PORTS
        .into_iter()
        .find(|spare| !served.contains_key(spare) && !listening.contains(spare))
}

/// A site as the bridge found it, before it is published.
struct Found {
    session_id: String,
    pid: u32,
    listener: Listener,
}

/// A session a detached server may belong to.
#[derive(Debug, Clone)]
pub(crate) struct Candidate {
    id: String,
    cwd: String,
    created_at: u64,
}

/// Whose a detached server is: the session working in the folder the server runs in (or a folder above it) that was
/// there before the server started. The nearest folder wins, then the newest session. A session in the home folder or
/// at the root is too wide a net to claim anything.
fn owner_of(cwd: &str, started_ms: u64, sessions: &[Candidate], home: &str) -> Option<String> {
    sessions
        .iter()
        .filter(|s| {
            let folder = s.cwd.trim_end_matches('/');
            !folder.is_empty()
                && folder != home.trim_end_matches('/')
                && (cwd == folder || cwd.strip_prefix(folder).is_some_and(|rest| rest.starts_with('/')))
                // The clocks are a second apart at most; `ps` rounds.
                && s.created_at <= started_ms + 5_000
        })
        .max_by_key(|s| (s.cwd.trim_end_matches('/').len(), s.created_at))
        .map(|s| s.id.clone())
}

/// The folder each of `pids` runs in. One `lsof` for all of them.
async fn working_folders(pids: &[u32]) -> HashMap<u32, String> {
    let list = pids.iter().map(u32::to_string).collect::<Vec<_>>().join(",");
    let out = tokio::process::Command::new("/usr/sbin/lsof")
        .args(["-a", "-d", "cwd", "-p", &list, "-Fpn"])
        .output()
        .await;
    let Ok(out) = out else {
        return HashMap::new();
    };
    parse_folders(&String::from_utf8_lossy(&out.stdout))
}

/// `lsof -Fpn` output: `p<pid>`, then `n<folder>`.
fn parse_folders(text: &str) -> HashMap<u32, String> {
    let mut out = HashMap::new();
    let mut pid: Option<u32> = None;
    for line in text.lines() {
        match line.split_at_checked(1) {
            Some(("p", rest)) => pid = rest.parse().ok(),
            Some(("n", rest)) => {
                if let Some(pid) = pid {
                    out.insert(pid, rest.to_string());
                }
            }
            _ => {}
        }
    }
    out
}

/// What the bridge knows of servers that left their session's process tree.
#[derive(Default)]
struct Detached {
    /// The session of every site seen in a session's tree, by process and port.
    owners: HashMap<(u32, u16), String>,
    /// The folder of each launchd-parented listener, asked once (`None`: it wouldn't say).
    folders: HashMap<u32, Option<String>>,
}

impl crate::session::App {
    /// Finds the sites the sessions are serving, publishes the ones it can, and takes down the ones that ended.
    pub(crate) async fn watch_sites(self: std::sync::Arc<Self>) {
        let mut ticker = tokio::time::interval(Duration::from_secs(5));
        // Titles are fetched once per (port, command), not on every tick.
        let mut titles: HashMap<(u16, String), Option<String>> = HashMap::new();
        let mut published: BTreeMap<u16, Published> = self.store.load_published_sites();
        let mut detached = Detached::default();
        loop {
            ticker.tick().await;
            let Some(listeners) = listeners().await else {
                continue;
            };
            let tree = ProcessTree::snapshot().await;
            let found = self
                .found_sites(&listeners, tree.as_ref(), &mut detached)
                .await;
            let config = Config::read(self.store.dir());
            // Every address a site's process listens on at its port, not just the first.
            let reaches: HashMap<u16, Reach> = found
                .iter()
                .map(|site| {
                    let port = site.listener.port;
                    let binds = listeners.get(&site.pid).into_iter().flatten();
                    let binds = binds.filter(|l| l.port == port).map(|l| l.bind.as_str());
                    (port, reach(binds))
                })
                .collect();

            // Fetched together, so one slow server doesn't hold up the rest.
            let missing: Vec<(u16, String)> = found
                .iter()
                .map(|s| (s.listener.port, s.listener.command.clone()))
                .filter(|key| !titles.contains_key(key))
                .collect();
            let fetched = futures_util::future::join_all(
                missing.iter().map(|(port, _)| title(reaches[port].host(), *port)),
            )
            .await;
            titles.extend(missing.into_iter().zip(fetched));
            titles.retain(|(port, _), _| found.iter().any(|s| s.listener.port == *port));

            // Nothing to publish, nothing to ask Tailscale about. Without its serve config, publishing waits: the bridge
            // couldn't tell which ports the user serves by hand.
            let state = if config.publish {
                serve_state().await
            } else {
                None
            };
            let known = state.is_some();
            let (host, mut served) = state.unwrap_or_default();
            if known {
                // A route taken down from outside the bridge (`tailscale serve reset`) is published again.
                let before = published.len();
                published.retain(|_, site| served.contains_key(&site.tailnet_port()));
                if published.len() != before {
                    let _ = self.store.save_published_sites(&published);
                }
            }

            if known {
                let listening: Vec<u16> = listeners.values().flatten().map(|l| l.port).collect();
                for site in &found {
                    let port = site.listener.port;
                    // Only what answers on this Mac's loopback can be routed to.
                    let Reach::Local(local) = reaches[&port] else {
                        continue;
                    };
                    // Already on the tailnet, by the bridge or by a route made by hand: that one is used as it is.
                    if published.contains_key(&port) || route_to(&served, port).is_some() {
                        continue;
                    }
                    // Never take over a route the bridge didn't make: 443 and anything else the user serves by hand.
                    // The site then goes on a spare port.
                    let Some(to) = tailnet_port(port, &served, &listening) else {
                        continue;
                    };
                    if publish(to, local, port).await {
                        served.insert(to, format!("http://{local}:{port}"));
                        published.insert(
                            port,
                            Published {
                                port,
                                session_id: site.session_id.clone(),
                                served: (to != port).then_some(to),
                            },
                        );
                        let _ = self.store.save_published_sites(&published);
                    }
                }
            }

            // Take down the routes whose site is gone or can't be routed to, and only those. Turning publishing off
            // takes them all down.
            let live: Vec<u16> = found
                .iter()
                .map(|s| s.listener.port)
                .filter(|port| matches!(reaches[port], Reach::Local(_)))
                .collect();
            let gone: Vec<(u16, u16)> = published
                .iter()
                .filter(|(port, _)| !config.publish || !live.contains(port))
                .map(|(port, site)| (*port, site.tailnet_port()))
                .collect();
            // A route that wouldn't come down stays recorded, so the next tick tries again.
            for (port, to) in gone {
                if unpublish(to).await {
                    served.remove(&to);
                    published.remove(&port);
                    let _ = self.store.save_published_sites(&published);
                }
            }

            let mut by_session: HashMap<String, Vec<Site>> = HashMap::new();
            for found in &found {
                let port = found.listener.port;
                let reach = &reaches[&port];
                let to = match published.get(&port) {
                    _ if !matches!(reach, Reach::Local(_)) => None,
                    Some(site) => Some(site.tailnet_port()).filter(|to| served.contains_key(to)),
                    None => route_to(&served, port),
                };
                let to = to.filter(|_| !host.is_empty());
                let (url, reason) = match (to, reach) {
                    (Some(443), _) => (format!("https://{host}/"), None),
                    (Some(to), _) => (format!("https://{host}:{to}/"), None),
                    // On the tailnet by itself, at the Mac's name when the bridge knows it.
                    (None, Reach::Tailnet(bind)) => {
                        let at = if host.is_empty() { bind } else { &host };
                        (format!("http://{at}:{port}/"), None)
                    }
                    (None, Reach::Elsewhere(bind)) => (
                        format!("http://{bind}:{port}/"),
                        Some(format!("It only listens on {bind}")),
                    ),
                    (None, Reach::Local(local)) => (
                        format!("http://{local}:{port}/"),
                        Some(
                            if !config.publish {
                                "Publishing is off on this computer"
                            } else if !known {
                                "Tailscale isn't running on this computer"
                            } else {
                                "Tailscale wouldn't publish it"
                            }
                            .to_string(),
                        ),
                    ),
                };
                let on_tailnet = to.is_some() || matches!(reach, Reach::Tailnet(_));
                by_session
                    .entry(found.session_id.clone())
                    .or_default()
                    .push(Site {
                        port,
                        title: titles
                            .get(&(port, found.listener.command.clone()))
                            .cloned()
                            .flatten(),
                        command: found.listener.command.clone(),
                        url,
                        published: on_tailnet,
                        exposed: exposed(&found.listener.bind),
                        reason,
                    });
            }
            self.set_sites(by_session).await;
        }
    }

    /// Each session's own listening ports, from the process it runs, and the detached servers that are its too.
    async fn found_sites(
        &self,
        listeners: &HashMap<u32, Vec<Listener>>,
        tree: Option<&ProcessTree>,
        detached: &mut Detached,
    ) -> Vec<Found> {
        let Some(tree) = tree else {
            return Vec::new();
        };
        let mut roots: Vec<(String, u32)> = Vec::new();
        let mut candidates: Vec<Candidate> = Vec::new();
        for session in self.sessions.read().await.clone() {
            let root = match session.backend {
                crate::session::Backend::Pi => session.pid().await,
                crate::session::Backend::Prime => session.state.lock().await.worker_pid,
                // A Pi subagent runs inside its parent's process, so its ports are the parent's.
                crate::session::Backend::PiSubagent => continue,
            };
            candidates.push(Candidate {
                id: session.id.clone(),
                cwd: session.cwd.clone(),
                created_at: session.state.lock().await.summary.created_at,
            });
            if let Some(root) = root {
                roots.push((session.id.clone(), root));
            }
        }
        let mut found = sites_of(&roots, listeners, tree);
        for site in &found {
            detached
                .owners
                .insert((site.pid, site.listener.port), site.session_id.clone());
        }

        // Launchd's own children that listen: a detached server is one of them. Each is asked its folder once.
        let own = std::process::id();
        let orphans: Vec<u32> = listeners
            .keys()
            .copied()
            .filter(|pid| *pid != own && tree.parent(*pid) == Some(1))
            .collect();
        detached.folders.retain(|pid, _| orphans.contains(pid));
        let unknown: Vec<u32> = orphans
            .iter()
            .copied()
            .filter(|pid| !detached.folders.contains_key(pid))
            .filter(|pid| {
                let ports = &listeners[pid];
                ports.iter().any(|l| !detached.owners.contains_key(&(*pid, l.port)))
            })
            .collect();
        if !unknown.is_empty() {
            let mut folders = working_folders(&unknown).await;
            for pid in unknown {
                detached.folders.insert(pid, folders.remove(&pid));
            }
        }
        let home = std::env::var("HOME").unwrap_or_default();
        let now = crate::session::now_ms();
        for pid in &orphans {
            for listener in &listeners[pid] {
                if found.iter().any(|site| site.listener.port == listener.port) {
                    continue;
                }
                let key = (*pid, listener.port);
                let session_id = match detached.owners.get(&key) {
                    Some(id) => Some(id.clone()),
                    None => detached.folders.get(pid).cloned().flatten().and_then(|folder| {
                        let started = now.saturating_sub(tree.elapsed(*pid)? * 1000);
                        owner_of(&folder, started, &candidates, &home)
                    }),
                };
                let Some(session_id) = session_id else {
                    continue;
                };
                // Its session ended: the server is nobody's, and its route comes down.
                if !candidates.iter().any(|s| s.id == session_id) {
                    continue;
                }
                detached.owners.insert(key, session_id.clone());
                found.push(Found {
                    session_id,
                    pid: *pid,
                    listener: listener.clone(),
                });
            }
        }
        detached.owners.retain(|(pid, port), _| {
            listeners
                .get(pid)
                .is_some_and(|list| list.iter().any(|l| l.port == *port))
        });
        found
    }
}

/// The sites each session's processes listen on. A port is listed once, under the first session whose process tree
/// holds it, so a subagent sharing its parent's process doesn't duplicate one.
fn sites_of(
    roots: &[(String, u32)],
    listeners: &HashMap<u32, Vec<Listener>>,
    tree: &ProcessTree,
) -> Vec<Found> {
    let mut claimed: Vec<u16> = Vec::new();
    let mut out = Vec::new();
    for (session_id, root) in roots {
        let pids =
            std::iter::once(*root).chain(tree.subtree(*root).into_iter().map(|(pid, _)| pid));
        for pid in pids {
            for listener in listeners.get(&pid).into_iter().flatten() {
                if claimed.contains(&listener.port) {
                    continue;
                }
                claimed.push(listener.port);
                out.push(Found {
                    session_id: session_id.clone(),
                    pid,
                    listener: listener.clone(),
                });
            }
        }
    }
    out
}

/// `tailscale serve --bg --https=<to> http://127.0.0.1:<port>`: the site on its own tailnet port, tailnet only.
async fn publish(to: u16, local: &str, port: u16) -> bool {
    let target = format!("http://{local}:{port}");
    tailscale()
        .args(["serve", "--bg", &format!("--https={to}"), &target])
        .output()
        .await
        .map(|out| out.status.success())
        .unwrap_or(false)
}

async fn unpublish(port: u16) -> bool {
    tailscale()
        .args(["serve", &format!("--https={port}"), "off"])
        .output()
        .await
        .map(|out| out.status.success())
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lsof_output_becomes_listeners_by_pid() {
        let text = "p625\ncrapportd\nf7\nn*:49158\nf11\nn*:49158\np8890\ncnode\nf14\nn127.0.0.1:8890\nf15\nn[::1]:8890\n";
        let map = parse_lsof(text);
        assert_eq!(map[&625].len(), 1);
        assert_eq!(map[&625][0].port, 49158);
        assert_eq!(map[&625][0].bind, "*");
        assert_eq!(map[&8890].len(), 2);
        assert_eq!(map[&8890][0].command, "node");
    }

    #[test]
    fn addresses_split_into_bind_and_port() {
        assert_eq!(split_address("127.0.0.1:8890"), Some(("127.0.0.1", 8890)));
        assert_eq!(split_address("*:8080"), Some(("*", 8080)));
        assert_eq!(split_address("[::1]:8443"), Some(("[::1]", 8443)));
        assert_eq!(split_address("nonsense"), None);
    }

    #[test]
    fn loopback_and_tailnet_binds_are_not_exposed() {
        assert!(!exposed("127.0.0.1"));
        assert!(!exposed("[::1]"));
        assert!(!exposed("100.121.116.92"));
        assert!(!exposed("[fd7a:115c:a1e0::1]"));
        assert!(exposed("*"));
        assert!(exposed("192.168.0.67"));
        assert!(exposed("[::]"));
    }

    #[tokio::test]
    async fn a_sites_title_is_read_from_the_page_it_serves() {
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
            .await
            .unwrap();
        let port = listener.local_addr().unwrap().port();
        tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            use tokio::io::{AsyncReadExt, AsyncWriteExt};
            let mut request = [0u8; 1024];
            let _ = socket.read(&mut request).await;
            let body = "<html><head><title>Atelier</title></head></html>";
            let response = format!(
                "HTTP/1.0 200 OK\r\nContent-Type: text/html\r\nContent-Length: {}\r\n\r\n{body}",
                body.len()
            );
            let _ = socket.write_all(response.as_bytes()).await;
        });
        assert_eq!(title("127.0.0.1", port).await.as_deref(), Some("Atelier"));
    }

    #[test]
    fn titles_come_out_of_a_page() {
        let html = "<html><head><title>\n  Atelier   Studio \n</title></head>";
        assert_eq!(page_title(html).as_deref(), Some("Atelier Studio"));
        assert_eq!(page_title("<html><body>no title</body></html>"), None);
        assert_eq!(page_title("<title>  </title>"), None);
    }

    #[test]
    fn only_what_answers_on_loopback_is_routed_to() {
        assert_eq!(reach(["127.0.0.1"]), Reach::Local("127.0.0.1"));
        assert_eq!(reach(["*"]), Reach::Local("127.0.0.1"));
        assert_eq!(reach(["[::1]", "127.0.0.1"]), Reach::Local("127.0.0.1"));
        // Vite on a recent Node: `localhost` there is the IPv6 loopback alone.
        assert_eq!(reach(["[::1]"]), Reach::Local("localhost"));
        // On the tailnet address itself: there already, and a route at its port would shadow it.
        assert_eq!(reach(["100.121.116.92"]), Reach::Tailnet("100.121.116.92".into()));
        assert_eq!(reach(["192.168.1.20"]), Reach::Elsewhere("192.168.1.20".into()));
        assert_eq!(reach(["192.168.1.20", "127.0.0.1"]), Reach::Local("127.0.0.1"));
    }

    #[test]
    fn a_sessions_ports_come_from_its_own_process_tree() {
        // 100 (agent) -> 101 (vite), and 200 (another agent) -> 201 (python), which shares nothing with the first.
        let ps = "100 1 10:00 0:01.00 pi --mode rpc\n101 100 09:00 0:00.20 node vite\n200 1 10:00 0:00.50 prime\n201 200 09:00 0:00.10 python -m http.server\n";
        let tree = ProcessTree::parse(ps);
        let mut listeners: HashMap<u32, Vec<Listener>> = HashMap::new();
        listeners.insert(
            101,
            vec![Listener {
                port: 5173,
                bind: "127.0.0.1".into(),
                command: "node".into(),
            }],
        );
        listeners.insert(
            201,
            vec![Listener {
                port: 8000,
                bind: "*".into(),
                command: "python".into(),
            }],
        );
        // A port held by both trees is listed once, under the first.
        listeners.get_mut(&201).unwrap().push(Listener {
            port: 5173,
            bind: "127.0.0.1".into(),
            command: "python".into(),
        });

        let roots = vec![("a".to_string(), 100), ("b".to_string(), 200)];
        let found = sites_of(&roots, &listeners, &tree);
        assert_eq!(found.len(), 2);
        assert_eq!(
            (found[0].session_id.as_str(), found[0].listener.port),
            ("a", 5173)
        );
        assert_eq!(
            (found[1].session_id.as_str(), found[1].listener.port),
            ("b", 8000)
        );
    }

    #[test]
    fn sites_are_published_unless_the_config_says_not_to() {
        assert!(Config::parse("").publish);
        assert!(Config::parse(r#"{"token":"x"}"#).publish);
        assert!(Config::parse(r#"{"sites":{"publish":true}}"#).publish);
        assert!(!Config::parse(r#"{"sites":{"publish":false}}"#).publish);
    }

    #[test]
    fn a_route_made_by_hand_to_a_site_is_used() {
        let mut served = HashMap::new();
        served.insert(443, "http://127.0.0.1:7878".to_string());
        served.insert(8443, "http://localhost:5173".to_string());
        served.insert(9000, "https+insecure://127.0.0.1:8123/".to_string());
        served.insert(5432, String::new());
        assert_eq!(route_to(&served, 5173), Some(8443));
        assert_eq!(route_to(&served, 8123), Some(9000));
        assert_eq!(route_to(&served, 7878), Some(443));
        assert_eq!(route_to(&served, 3000), None);
        assert!(proxies_to("8123", 8123));
        assert!(!proxies_to("http://192.168.0.4:8123", 8123));
        assert!(!proxies_to("http://127.0.0.1:81230", 8123));
    }

    #[test]
    fn a_site_whose_port_is_taken_on_the_tailnet_gets_a_spare_one() {
        let mut served = HashMap::new();
        assert_eq!(tailnet_port(5173, &served, &[5173]), Some(5173));
        served.insert(5173, "http://127.0.0.1:9999".to_string());
        served.insert(8100, String::new());
        // 8101 is some server's own port on this Mac: left to it.
        assert_eq!(tailnet_port(5173, &served, &[5173, 8101]), Some(8102));
    }

    #[test]
    fn a_detached_server_goes_to_the_session_in_its_folder() {
        let session = |id: &str, cwd: &str, created_at: u64| Candidate {
            id: id.into(),
            cwd: cwd.into(),
            created_at,
        };
        let sessions = vec![
            session("home", "/Users/me", 100_000),
            session("old", "/Users/me/src/app", 100_000),
            session("new", "/Users/me/src/app", 200_000),
            session("later", "/Users/me/src/app", 900_000),
            session("web", "/Users/me/src/app/web", 150_000),
            session("other", "/Users/me/src/application", 100_000),
        ];
        let owner = |cwd: &str, started: u64| owner_of(cwd, started, &sessions, "/Users/me");
        // The newest session that was there before the server started.
        assert_eq!(owner("/Users/me/src/app", 500_000).as_deref(), Some("new"));
        // The nearest folder wins.
        assert_eq!(owner("/Users/me/src/app/web/dist", 500_000).as_deref(), Some("web"));
        assert_eq!(owner("/Users/me/src/app/api", 500_000).as_deref(), Some("new"));
        // A server older than every session there is nobody's, and the home folder claims nothing.
        assert_eq!(owner("/Users/me/src/app", 10), None);
        assert_eq!(owner("/Users/me/Library", 500_000), None);
        assert_eq!(owner("/", 500_000), None);
    }

    #[test]
    fn folders_come_out_of_lsof() {
        let folders = parse_folders("p4821\nfcwd\nn/Users/me/src/app\np4900\nfcwd\nn/\n");
        assert_eq!(folders[&4821], "/Users/me/src/app");
        assert_eq!(folders[&4900], "/");
    }

    #[test]
    fn served_ports_come_from_the_serve_config() {
        let served: Value = serde_json::from_str(
            r#"{"TCP":{"443":{"HTTPS":true},"5432":{"TCPForward":"127.0.0.1:5432"}},
                "Web":{"host.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8890"}}},
                        "host.ts.net:7878":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:7878"}}}}}"#,
        )
        .unwrap();
        let ports = served_ports(&served);
        assert_eq!(
            ports.get(&443).map(String::as_str),
            Some("http://127.0.0.1:8890")
        );
        assert_eq!(
            ports.get(&7878).map(String::as_str),
            Some("http://127.0.0.1:7878")
        );
        assert!(ports.contains_key(&5432));
    }
}
