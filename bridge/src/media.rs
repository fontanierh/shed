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
const MAX_UPLOAD_BYTES: usize = 512 << 20;

pub async fn upload_handler(
    Query(query): Query<HashMap<String, String>>,
    headers: HeaderMap,
    State(app): State<Arc<App>>,
    body: Body,
) -> Response {
    use futures_util::StreamExt;
    use std::os::unix::fs::PermissionsExt;
    use tokio::io::AsyncWriteExt;

    // Checked before reading a single byte of the body so unauthenticated callers cannot buffer into memory.
    if !authorized(&app, &query, &headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let name = upload_name(query.get("name").map(String::as_str).unwrap_or(""));
    let root = std::env::temp_dir().join("shed-uploads");
    let dir = root.join(uuid::Uuid::new_v4().to_string());
    let path = dir.join(&name);
    let written: Result<(), (StatusCode, String)> = async {
        tokio::fs::create_dir_all(&dir)
            .await
            .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
        if let Err(e) = std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)) {
            eprintln!("upload root permissions: {e}");
        }
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700))
            .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
        let mut opts = tokio::fs::OpenOptions::new();
        opts.write(true).create_new(true).mode(0o600);
        let mut file = opts
            .open(&path)
            .await
            .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
        let mut stream = body.into_data_stream();
        let mut total = 0usize;
        while let Some(chunk) = stream.next().await {
            let chunk = chunk.map_err(|e| (StatusCode::BAD_REQUEST, e.to_string()))?;
            total = total.saturating_add(chunk.len());
            if total > MAX_UPLOAD_BYTES {
                return Err((
                    StatusCode::PAYLOAD_TOO_LARGE,
                    "upload exceeds 512 MiB".into(),
                ));
            }
            file.write_all(&chunk)
                .await
                .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
        }
        file.flush()
            .await
            .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))
    }
    .await;
    match written {
        Ok(()) => axum::Json(serde_json::json!({ "path": path.to_string_lossy() })).into_response(),
        Err((code, msg)) => {
            if let Err(e) = tokio::fs::remove_dir_all(&dir).await {
                if e.kind() != std::io::ErrorKind::NotFound {
                    eprintln!("cleaning failed upload {}: {e}", dir.display());
                }
            }
            (code, msg).into_response()
        }
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
