//! Media the agents show the user: local images, videos and audio, served to the apps over HTTP.

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

/// Appended to every session's system prompt, so the agents know how to show media in the apps.
pub const GUIDE: &str = "\
## Showing media to the user

The user follows this session in Shed, an app that renders your replies as Markdown. \
To show them an image, a video or an audio clip, embed the file in your reply with Markdown image syntax and its \
absolute path on this machine, whatever its type, on a line of its own:

![Short caption](/absolute/path/to/chart.png)
![Screen recording of the bug](/absolute/path/to/repro.mp4)
![Voice memo](/absolute/path/to/memo.m4a)

Shed shows images inline, and videos and audio as players. https URLs work as well. \
Save anything you generate or download to a file first (in the working directory, or /tmp for throwaway files); \
never paste base64 into a reply. Images: png, jpg, gif, webp, heic, tiff. Video: mp4, mov, m4v. \
Audio: mp3, m4a, aac, wav, aiff, flac.";

/// The content type for a file the apps may fetch, by extension. Anything else is refused.
fn content_type(path: &str) -> Option<&'static str> {
    let ext = path.rsplit('.').next()?.to_ascii_lowercase();
    Some(match ext.as_str() {
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
        _ => return None,
    })
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
    let Some(kind) = content_type(path) else {
        return (StatusCode::UNSUPPORTED_MEDIA_TYPE, "not a media file").into_response();
    };
    match serve(path, kind, headers.get(header::RANGE).and_then(|v| v.to_str().ok())).await {
        Ok(response) => response,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => StatusCode::NOT_FOUND.into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

async fn serve(path: &str, kind: &'static str, range: Option<&str>) -> std::io::Result<Response> {
    let mut file = tokio::fs::File::open(path).await?;
    let len = file.metadata().await?.len();
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
        return Ok(common(Response::builder()).header(header::CONTENT_LENGTH, len).body(stream(file, len)).unwrap());
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
        (from, to) => (from.parse().ok()?, to.parse::<u64>().ok()?.min(len.checked_sub(1)?)),
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
        assert_eq!(content_type("/a/B.PNG"), Some("image/png"));
        assert_eq!(content_type("/etc/passwd"), None);
    }
}
