//! agent-remote: control Pi, Prime Agent and DeepSeek Harness sessions on this Mac from the macOS and iOS apps.

mod cost;
mod dsh;
mod files;
mod git;
mod github;
mod guide;
mod history;
mod jobs;
mod media;
mod opencodex;
mod prime;
mod protocol;
mod rpc;
mod runaway;
mod server;
mod session;
mod sites;
mod stall;
mod store;
mod transcript;
mod web;

use anyhow::{bail, Result};
use axum::extract::DefaultBodyLimit;
use axum::routing::{get, post};
use axum::Router;

fn usage() -> ! {
    eprintln!("usage: agent-remote [--host 127.0.0.1] [--port 7878]");
    eprintln!();
    eprintln!("Binds to localhost by default. Expose it on your tailnet with TLS via:");
    eprintln!("  tailscale serve --bg --https=7878 http://127.0.0.1:7878");
    std::process::exit(2)
}

#[tokio::main]
async fn main() -> Result<()> {
    // `shed-web …` (this binary under that name) or `agent-remote web …`: the agents' web command.
    let argv: Vec<String> = std::env::args().collect();
    let called = argv
        .first()
        .and_then(|a| a.rsplit('/').next())
        .unwrap_or_default();
    if called == "shed-web" {
        web::main(argv[1..].to_vec()).await;
    }
    if argv.get(1).map(String::as_str) == Some("web") {
        web::main(argv[2..].to_vec()).await;
    }
    // What an agent is told about Shed, as its sessions here get it.
    if argv.get(1).map(String::as_str) == Some("guide") {
        let agent = match argv.get(2).map(String::as_str) {
            Some("pi") => rpc::AgentKind::Pi,
            Some("prime") => rpc::AgentKind::Prime,
            Some("deepseek" | "dsh") => rpc::AgentKind::Deepseek,
            _ => bail!("usage: agent-remote guide pi|prime|deepseek"),
        };
        println!("{}", guide::text(agent));
        return Ok(());
    }

    let mut host = "127.0.0.1".to_string();
    let mut port: u16 = 7878;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--host" => host = args.next().unwrap_or_else(|| usage()),
            "--port" => {
                port = args
                    .next()
                    .and_then(|p| p.parse().ok())
                    .unwrap_or_else(|| usage())
            }
            "-h" | "--help" => usage(),
            other => bail!("unknown argument: {other}"),
        }
    }

    web::install();
    let app = session::App::new(store::Store::open()?)?;
    let router = Router::new()
        .route("/ws", get(server::ws_handler))
        .route("/media", get(media::media_handler))
        .route(
            "/upload",
            post(media::upload_handler).layer(DefaultBodyLimit::max(512 << 20)),
        )
        .route("/health", get(|| async { "ok" }))
        .with_state(app.clone());

    let listener = tokio::net::TcpListener::bind((host.as_str(), port)).await?;
    eprintln!("agent-remote listening on ws://{host}:{port}/ws");
    eprintln!("token: ~/.agent-remote/config.json");

    let shutdown_app = app.clone();
    axum::serve(listener, router)
        .with_graceful_shutdown(async move {
            // Ctrl-C in a terminal, SIGTERM from launchd.
            let mut terminate =
                tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
                    .expect("SIGTERM can be listened for");
            tokio::select! {
                _ = tokio::signal::ctrl_c() => {}
                _ = terminate.recv() => {}
            }
            eprintln!("shutting down, closing agent sessions");
            // A session that doesn't answer must not hold the restart: launchd waits, then kills.
            let _ =
                tokio::time::timeout(std::time::Duration::from_secs(3), shutdown_app.shutdown())
                    .await;
            tokio::time::sleep(std::time::Duration::from_millis(500)).await;
            // The apps' open connections would keep the server waiting.
            std::process::exit(0);
        })
        .await?;
    Ok(())
}
