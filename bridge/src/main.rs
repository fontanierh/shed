//! agent-remote: control Pi and Prime Agent sessions on this Mac from the macOS and iOS apps.

mod dsh;
mod cost;
mod files;
mod history;
mod jobs;
mod media;
mod prime;
mod protocol;
mod rpc;
mod runaway;
mod server;
mod session;
mod stall;
mod store;
mod transcript;

use anyhow::{bail, Result};
use axum::routing::get;
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

    let app = session::App::new(store::Store::open()?)?;
    let router = Router::new()
        .route("/ws", get(server::ws_handler))
        .route("/media", get(media::media_handler))
        .route("/health", get(|| async { "ok" }))
        .with_state(app.clone());

    let listener = tokio::net::TcpListener::bind((host.as_str(), port)).await?;
    eprintln!("agent-remote listening on ws://{host}:{port}/ws");
    eprintln!("token: ~/.agent-remote/config.json");

    let shutdown_app = app.clone();
    axum::serve(listener, router)
        .with_graceful_shutdown(async move {
            let _ = tokio::signal::ctrl_c().await;
            eprintln!("shutting down, closing agent sessions");
            shutdown_app.shutdown().await;
            tokio::time::sleep(std::time::Duration::from_millis(500)).await;
        })
        .await?;
    Ok(())
}
