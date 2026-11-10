//! Files the agents show the user: local images, videos and audio, and documents to open or download, served to the
//! apps over HTTP.

use std::collections::HashMap;
use std::io::SeekFrom;
use std::sync::Arc;

use axum::body::Body;
use axum::extract::{Query, State};
use axum::http::{header, HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use tokio::io::{AsyncReadExt, AsyncSeekExt};

use crate::server::authorized;
use crate::session::App;

/// Appended to every session's system prompt, so the agents know how to show media and files in the apps.
pub const GUIDE: &str = "\
## Showing media and files to the user

The user follows this session in Shed, an app that renders your replies as Markdown, often on their phone. \
To show them an image, a video, an audio clip or any other file, embed it in your reply with Markdown image syntax and \
its absolute path on this machine, whatever its type, on a line of its own:

![Short caption](/absolute/path/to/chart.png)
![Screen recording of the bug](/absolute/path/to/repro.mp4)
![Voice memo](/absolute/path/to/memo.m4a)
![Design notes](/absolute/path/to/notes.md)
![The fixed parser](/absolute/path/to/parser.py)

Shed shows images inline, and videos and audio as players. Any other file (Markdown, code, text, CSV, PDF, a zip) \
shows as a file card: the user taps it to read it in a viewer (Markdown rendered, code highlighted) and can download it. \
A plain link with an absolute path, like [the notes](/absolute/path/to/notes.md), opens the same viewer, so you can \
also point at a file mid-sentence. Embed a file instead of pasting its contents when it is long; quote just the part \
that matters in the reply. https URLs work as well. Paths with spaces go in angle brackets: \
![Report](</absolute/path/with spaces/report.md>). Save anything you generate or download to a file first (in the \
working directory, or /tmp for throwaway files); never paste base64 into a reply. Images: png, jpg, gif, webp, heic, \
tiff. Video: mp4, mov, m4v. Audio: mp3, m4a, aac, wav, aiff, flac.

## Sites

To show the user a page or an app (a preview, a report, docs, a dashboard), serve it over HTTP on this machine. Shed \
finds the server by its port, publishes it on the user's tailnet over HTTPS, and lists it in the app. The user is \
usually on a phone: a localhost link or a path to an HTML file is no use to them.

- Bind 127.0.0.1. Use the framework's default port, or a free one from 8100 to 8199 (check with \
`lsof -iTCP:<port> -sTCP:LISTEN`). Never 7878, 3478 or 3479.
- Start it as a background command so it outlives your turn. Don't nohup or daemonize it: Shed then can't always tell \
the server is yours.
- Give the page a real `<title>`. It is the site's name in the app.
- Don't run `tailscale serve` or `tailscale funnel`. Shed publishes the site and takes it down when the server stops.
- Check it answers (`curl -sI http://127.0.0.1:<port>/`), then name it in your reply (\"the preview is up\"). Don't \
quote a URL or a port.
- Stop the server when it is no longer needed.";

/// The content type for a file the apps fetch, by extension: media the players need typed, the rest as bytes the apps
/// view or download.
fn content_type(path: &str) -> &'static str {
    let name = path.rsplit('/').next().unwrap_or(path);
    let ext = name
        .rsplit_once('.')
        .map(|(_, ext)| ext.to_ascii_lowercase());
    match ext.as_deref().unwrap_or("") {
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "heic" => "image/heic",
        "tif" | "tiff" => "image/tiff",
        "bmp" => "image/bmp",
        "svg" => "image/svg+xml",
        "mp4" | "m4v" => "video/mp4",
        "mov" => "video/quicktime",
        "mp3" => "audio/mpeg",
        "m4a" => "audio/mp4",
        "aac" => "audio/aac",
        "wav" => "audio/wav",
        "aif" | "aiff" => "audio/aiff",
        "flac" => "audio/flac",
        "pdf" => "application/pdf",
        "md" | "markdown" => "text/markdown; charset=utf-8",
        "txt" | "log" | "csv" | "tsv" => "text/plain; charset=utf-8",
        _ => "application/octet-stream",
    }
}

/// `GET /media?path=/absolute/file.png`, authorized like the WebSocket. Honors `Range`, which video and audio players rely on.
pub async fn media_handler(
    Query(query): Query<HashMap<String, String>>,
    headers: HeaderMap,
    State(app): State<Arc<App>>,
) -> Response {
    if !authorized(&app, &query, &headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let Some(path) = query.get("path").filter(|p| p.starts_with('/')) else {
        return (StatusCode::BAD_REQUEST, "path must be absolute").into_response();
    };
    match serve(
        path,
        content_type(path),
        headers.get(header::RANGE).and_then(|v| v.to_str().ok()),
    )
    .await
    {
        Ok(response) => response,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => StatusCode::NOT_FOUND.into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

/// `POST /upload?name=shot.png` with the file as the body, authorized like the WebSocket: a file dropped on the
/// composer, saved on this machine so the message can point the agent at it. Answers `{"path": ...}`.
pub async fn upload_handler(
    Query(query): Query<HashMap<String, String>>,
    headers: HeaderMap,
    State(app): State<Arc<App>>,
    body: axum::body::Bytes,
) -> Response {
    if !authorized(&app, &query, &headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let name = upload_name(query.get("name").map(String::as_str).unwrap_or(""));
    // A folder per upload, so two files dropped with the same name don't overwrite each other. The temp dir is
    // purged by the system, which is all the cleanup throwaway attachments need.
    let dir = std::env::temp_dir()
        .join("shed-uploads")
        .join(uuid::Uuid::new_v4().to_string());
    let path = dir.join(&name);
    let written = async {
        tokio::fs::create_dir_all(&dir).await?;
        tokio::fs::write(&path, &body).await
    };
    match written.await {
        Ok(()) => axum::Json(serde_json::json!({ "path": path.to_string_lossy() })).into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

/// The uploaded file's name, kept to its last component so it can't escape its folder.
fn upload_name(name: &str) -> String {
    let name = name.rsplit(['/', '\\']).next().unwrap_or("").trim();
    match name {
        "" | "." | ".." => "attachment".into(),
        name => name.into(),
    }
}

async fn serve(path: &str, kind: &'static str, range: Option<&str>) -> std::io::Result<Response> {
    let mut file = tokio::fs::File::open(path).await?;
    let metadata = file.metadata().await?;
    // A directory opens fine and then fails mid-stream.
    if !metadata.is_file() {
        return Err(std::io::ErrorKind::NotFound.into());
    }
    let len = metadata.len();
    let common = |builder: axum::http::response::Builder| {
        builder
            .header(header::CONTENT_TYPE, kind)
            .header(header::ACCEPT_RANGES, "bytes")
            .header(header::CACHE_CONTROL, "private, max-age=60")
    };

    let Some((start, end)) = range.and_then(|r| parse_range(r, len)) else {
        if range.is_some() {
            return Ok(Response::builder()
                .status(StatusCode::RANGE_NOT_SATISFIABLE)
                .header(header::CONTENT_RANGE, format!("bytes */{len}"))
                .body(Body::empty())
                .unwrap());
        }
        return Ok(common(Response::builder())
            .header(header::CONTENT_LENGTH, len)
            .body(stream(file, len))
            .unwrap());
    };

    // The whole range asked for: AVFoundation refuses a shorter answer than its request, even a valid partial one.
    file.seek(SeekFrom::Start(start)).await?;
    Ok(common(Response::builder())
        .status(StatusCode::PARTIAL_CONTENT)
        .header(header::CONTENT_RANGE, format!("bytes {start}-{end}/{len}"))
        .header(header::CONTENT_LENGTH, end - start + 1)
        .body(stream(file, end - start + 1))
        .unwrap())
}

/// The next `len` bytes of `file`, read as they're sent rather than all held in memory.
fn stream(file: tokio::fs::File, len: u64) -> Body {
    let chunks = futures_util::stream::unfold(file.take(len), |mut reader| async move {
        let mut chunk = vec![0; 256 << 10];
        match reader.read(&mut chunk).await {
            Ok(0) => None,
            Ok(n) => {
                chunk.truncate(n);
                Some((Ok::<_, std::io::Error>(chunk), reader))
            }
            Err(e) => Some((Err(e), reader)),
        }
    });
    Body::from_stream(chunks)
}

/// A single `bytes=` range within a file of `len` bytes, as inclusive offsets.
fn parse_range(header: &str, len: u64) -> Option<(u64, u64)> {
    let spec = header.strip_prefix("bytes=")?.split(',').next()?.trim();
    let (from, to) = spec.split_once('-')?;
    let (start, end) = match (from.trim(), to.trim()) {
        ("", suffix) => {
            let n: u64 = suffix.parse().ok()?;
            (len.checked_sub(n.min(len))?, len.checked_sub(1)?)
        }
        (from, "") => (from.parse().ok()?, len.checked_sub(1)?),
        (from, to) => (
            from.parse().ok()?,
            to.parse::<u64>().ok()?.min(len.checked_sub(1)?),
        ),
    };
    (start <= end && end < len).then_some((start, end))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ranges() {
        assert_eq!(parse_range("bytes=0-1", 10), Some((0, 1)));
        assert_eq!(parse_range("bytes=5-", 10), Some((5, 9)));
        assert_eq!(parse_range("bytes=-3", 10), Some((7, 9)));
        assert_eq!(parse_range("bytes=8-100", 10), Some((8, 9)));
        assert_eq!(parse_range("bytes=10-", 10), None);
        assert_eq!(content_type("/a/B.PNG"), "image/png");
        assert_eq!(content_type("/a/notes.md"), "text/markdown; charset=utf-8");
        assert_eq!(content_type("/a.b/Makefile"), "application/octet-stream");
        assert_eq!(upload_name("../../etc/passwd"), "passwd");
        assert_eq!(upload_name(".."), "attachment");
        assert_eq!(
            upload_name("Screenshot 2026-11-04 at 10.12.03.png"),
            "Screenshot 2026-11-04 at 10.12.03.png"
        );
    }

    #[tokio::test]
    async fn files_but_not_folders() {
        let dir = std::env::temp_dir().join(format!("shed-media-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let notes = dir.join("notes.md");
        std::fs::write(&notes, "# Notes\n").unwrap();
        let path = notes.to_str().unwrap();
        let response = serve(path, content_type(path), None).await.unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(response.headers()[header::CONTENT_LENGTH], "8");
        let folder = serve(dir.to_str().unwrap(), "application/octet-stream", None).await;
        assert_eq!(folder.unwrap_err().kind(), std::io::ErrorKind::NotFound);
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
