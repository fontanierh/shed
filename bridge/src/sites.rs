//! Sites: web servers the agents start. The bridge finds them by looking at the ports the sessions' own processes
//! listen on, so any server counts (`vite`, `python -m http.server`, `cargo run`) without the agent registering it.
//!
//! Publishing is opt-in (`sites.publish` in config.json). When it is on, each site gets its own `tailscale serve`
//! HTTPS port, so the iPhone can open it: one port per site, never a path prefix, because an app with absolute asset
//! URLs breaks under a prefix. The bridge only ever removes routes it recorded in `sites.json`: the serve config is
//! shared with whatever else the user publishes by hand, and a sweep would take those too.

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
}

/// `sites` in config.json: `{ "publish": true }`. Read each time, so editing the file takes effect without a restart.
#[derive(Debug, Clone, Copy, Default)]
pub struct Config {
    pub publish: bool,
}

impl Config {
    pub fn read(dir: &std::path::Path) -> Config {
        let Ok(raw) = std::fs::read_to_string(dir.join("config.json")) else {
            return Config::default();
        };
        let Ok(config) = serde_json::from_str::<Value>(&raw) else {
            return Config::default();
        };
        Config {
            publish: config["sites"]["publish"].as_bool().unwrap_or(false),
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

/// The `<title>` of the page a site serves, for the list. One short request, made once per site.
async fn title(port: u16) -> Option<String> {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let connect = tokio::net::TcpStream::connect(("127.0.0.1", port));
    let mut stream = tokio::time::timeout(Duration::from_millis(1500), connect)
        .await
        .ok()?
        .ok()?;
    let request = format!("GET / HTTP/1.0\r\nHost: 127.0.0.1:{port}\r\nAccept: text/html\r\n\r\n");
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

/// A site as the bridge found it, before it is published.
struct Found {
    session_id: String,
    listener: Listener,
}

impl crate::session::App {
    /// Finds the sites the sessions are serving, publishes the ones it can, and takes down the ones that ended.
    pub(crate) async fn watch_sites(self: std::sync::Arc<Self>) {
        let mut ticker = tokio::time::interval(Duration::from_secs(5));
        // Titles are fetched once per (port, command), not on every tick.
        let mut titles: HashMap<(u16, String), Option<String>> = HashMap::new();
        let mut published: BTreeMap<u16, Published> = self.store.load_published_sites();
        loop {
            ticker.tick().await;
            let Some(listeners) = listeners().await else {
                continue;
            };
            let tree = ProcessTree::snapshot().await;
            let found = self.found_sites(&listeners, tree.as_ref()).await;
            let config = Config::read(self.store.dir());

            // Fetched together, so one slow server doesn't hold up the rest.
            let missing: Vec<(u16, String)> = found
                .iter()
                .map(|s| (s.listener.port, s.listener.command.clone()))
                .filter(|key| !titles.contains_key(key))
                .collect();
            let fetched =
                futures_util::future::join_all(missing.iter().map(|(port, _)| title(*port))).await;
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
                published.retain(|port, _| served.contains_key(port));
            }

            if known {
                for site in &found {
                    let port = site.listener.port;
                    if published.contains_key(&port) {
                        continue;
                    }
                    // Never take over a route the bridge didn't make: 443 and anything else the user serves by hand.
                    if served.contains_key(&port) {
                        continue;
                    }
                    if publish(port).await {
                        served.insert(port, format!("http://127.0.0.1:{port}"));
                        published.insert(
                            port,
                            Published {
                                port,
                                session_id: site.session_id.clone(),
                            },
                        );
                        let _ = self.store.save_published_sites(&published);
                    }
                }
            }

            // Take down the routes whose site is gone, and only those. Turning publishing off takes them all down.
            let live: Vec<u16> = found.iter().map(|s| s.listener.port).collect();
            let gone: Vec<u16> = published
                .keys()
                .copied()
                .filter(|port| !config.publish || !live.contains(port))
                .collect();
            // A route that wouldn't come down stays recorded, so the next tick tries again.
            for port in gone {
                if unpublish(port).await {
                    published.remove(&port);
                    let _ = self.store.save_published_sites(&published);
                }
            }

            let mut by_session: HashMap<String, Vec<Site>> = HashMap::new();
            for found in &found {
                let port = found.listener.port;
                let is_published = published.contains_key(&port) && served.contains_key(&port);
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
                        url: if is_published && !host.is_empty() {
                            format!("https://{host}:{port}/")
                        } else {
                            format!("http://127.0.0.1:{port}/")
                        },
                        published: is_published,
                        exposed: exposed(&found.listener.bind),
                    });
            }
            self.set_sites(by_session).await;
        }
    }

    /// Each session's own listening ports, from the process it runs.
    async fn found_sites(
        &self,
        listeners: &HashMap<u32, Vec<Listener>>,
        tree: Option<&ProcessTree>,
    ) -> Vec<Found> {
        let Some(tree) = tree else {
            return Vec::new();
        };
        let mut roots: Vec<(String, u32)> = Vec::new();
        for session in self.sessions.read().await.clone() {
            let root = match session.backend {
                crate::session::Backend::Pi => session.pid().await,
                crate::session::Backend::Prime => session.state.lock().await.worker_pid,
                // A Pi subagent runs inside its parent's process, so its ports are the parent's.
                crate::session::Backend::PiSubagent => None,
            };
            if let Some(root) = root {
                roots.push((session.id.clone(), root));
            }
        }
        sites_of(&roots, listeners, tree)
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
                    listener: listener.clone(),
                });
            }
        }
    }
    out
}

/// `tailscale serve --bg --https=<port> http://127.0.0.1:<port>`: the site on its own tailnet port, tailnet only.
async fn publish(port: u16) -> bool {
    let target = format!("http://127.0.0.1:{port}");
    tailscale()
        .args(["serve", "--bg", &format!("--https={port}"), &target])
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
        assert_eq!(title(port).await.as_deref(), Some("Atelier"));
    }

    #[test]
    fn titles_come_out_of_a_page() {
        let html = "<html><head><title>\n  Atelier   Studio \n</title></head>";
        assert_eq!(page_title(html).as_deref(), Some("Atelier Studio"));
        assert_eq!(page_title("<html><body>no title</body></html>"), None);
        assert_eq!(page_title("<title>  </title>"), None);
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
