//! A Prime session's conversation before its last compaction, rebuilt from its JSONL file: the daemon's
//! `get_messages` only returns the current context (the last summary and what it kept).

use std::sync::Arc;

use anyhow::Result;
use serde::Deserialize;
use serde_json::{json, Value};

use crate::protocol::Item;
use crate::transcript::Transcript;

/// Tool arguments and output are clipped harder than live ones: a long session holds thousands.
const MAX_FIELD: usize = 4_000;
/// Items sent with a snapshot, and per request for more.
pub const PAGE: usize = 150;

pub struct History {
    /// The entry the last compaction kept from: everything before it is history.
    pub cut: String,
    pub items: Vec<Item>,
}

/// Just enough of an entry to find the current branch and its last compaction.
#[derive(Deserialize)]
struct Head {
    #[serde(rename = "type")]
    kind: String,
    id: Option<String>,
    #[serde(rename = "parentId")]
    parent_id: Option<String>,
    #[serde(rename = "firstKeptEntryId")]
    first_kept: Option<String>,
    summary: Option<String>,
}

/// The history of the session in `path` before the compaction whose summary starts the current context, reusing
/// `previous` when that compaction hasn't changed. `None` when the file's last compaction isn't that one (not
/// written yet): better no history than a gap.
pub fn load(path: &str, summary: &str, previous: Option<Arc<History>>) -> Result<Option<Arc<History>>> {
    let file = std::fs::read_to_string(path)?;
    let lines: Vec<&str> = file.lines().filter(|l| !l.trim().is_empty()).collect();
    let heads: Vec<Option<Head>> = lines.iter().map(|l| serde_json::from_str(l).ok()).collect();

    // The entries are a tree (the session can be rewound and branched): follow the last one back to the root.
    let at: std::collections::HashMap<&str, usize> =
        heads.iter().enumerate().filter_map(|(i, h)| Some((h.as_ref()?.id.as_deref()?, i))).collect();
    let mut branch = Vec::new();
    let mut next = heads.iter().rposition(|h| h.as_ref().is_some_and(|h| h.id.is_some()));
    while let Some(i) = next {
        branch.push(i);
        next = heads[i].as_ref().and_then(|h| h.parent_id.as_deref()).and_then(|p| at.get(p).copied()).filter(|&p| p < i);
    }
    branch.reverse();

    let Some((last, cut)) = branch.iter().rev().find_map(|&i| {
        let head = heads[i].as_ref().filter(|h| h.kind == "compaction")?;
        Some((i, head.first_kept.clone()?))
    }) else {
        return Ok(None);
    };
    if heads[last].as_ref().and_then(|h| h.summary.as_deref()) != Some(summary) {
        return Ok(None);
    }
    if let Some(previous) = previous.filter(|p| p.cut == cut) {
        return Ok(Some(previous));
    }
    let messages: Vec<Value> = branch
        .iter()
        .take_while(|&&i| heads[i].as_ref().and_then(|h| h.id.as_deref()) != Some(cut.as_str()))
        // The last compaction's summary is the first thing in the current context.
        .filter(|&&i| i != last)
        .filter_map(|&i| serde_json::from_str::<Value>(lines[i]).ok())
        .filter_map(|entry| message_of(&entry))
        .collect();
    let mut items = Transcript::rebuild(&messages, MAX_FIELD);
    for (n, item) in items.iter_mut().enumerate() {
        item.id = format!("h{n}");
    }
    Ok(Some(Arc::new(History { cut, items })))
}

/// The entry as the message `get_messages` would have returned for it.
fn message_of(entry: &Value) -> Option<Value> {
    match entry["type"].as_str()? {
        "message" => Some(entry["message"].clone()),
        "custom_message" => Some(json!({
            "role": "custom",
            "content": entry["content"],
            "display": entry["display"],
            "timestamp": entry["timestamp"],
        })),
        "compaction" => Some(json!({
            "role": "compactionSummary",
            "summary": entry["summary"],
            "tokensBefore": entry["tokensBefore"],
            "timestamp": entry["timestamp"],
        })),
        "branch_summary" => Some(json!({ "role": "branchSummary", "summary": entry["summary"], "timestamp": entry["timestamp"] })),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::ItemKind;

    fn write(lines: &[Value]) -> String {
        let path = std::env::temp_dir().join(format!("history-test-{}-{}.jsonl", std::process::id(), rand_suffix()));
        let text: Vec<String> = lines.iter().map(Value::to_string).collect();
        std::fs::write(&path, text.join("\n") + "\n").unwrap();
        path.to_string_lossy().into_owned()
    }

    fn rand_suffix() -> u64 {
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos() as u64
    }

    fn message(id: &str, parent: &str, message: Value) -> Value {
        json!({ "type": "message", "id": id, "parentId": parent, "timestamp": "2026-10-30T15:17:03.138Z", "message": message })
    }

    #[test]
    fn rebuilds_everything_before_the_last_compaction() {
        let big = "x".repeat(10_000);
        let path = write(&[
            json!({ "type": "session", "id": "s", "timestamp": "2026-10-30T15:16:39.382Z" }),
            message("a", "s", json!({ "role": "user", "content": [{ "type": "text", "text": "first" }], "timestamp": 1000 })),
            message("b", "a", json!({ "role": "assistant", "content": [{ "type": "toolCall", "id": "t1", "name": "bash", "arguments": { "command": "ls" } }], "timestamp": 2000 })),
            message("c", "b", json!({ "role": "toolResult", "toolCallId": "t1", "content": [{ "type": "text", "text": big }], "timestamp": 3000 })),
            json!({ "type": "child_usage_attributed", "id": "u", "parentId": "c", "timestamp": "2026-10-30T15:18:00.000Z" }),
            json!({ "type": "custom_message", "id": "d", "parentId": "u", "timestamp": "2026-10-30T15:18:01.000Z", "content": "child says hi", "display": true }),
            json!({ "type": "compaction", "id": "e", "parentId": "d", "timestamp": "2026-10-30T15:19:00.000Z", "summary": "first summary", "firstKeptEntryId": "d", "tokensBefore": 100 }),
            message("f", "e", json!({ "role": "user", "content": "second", "timestamp": 5000 })),
            json!({ "type": "compaction", "id": "g", "parentId": "f", "timestamp": "2026-10-30T15:20:00.000Z", "summary": "second summary", "firstKeptEntryId": "f", "tokensBefore": 200 }),
            message("h", "g", json!({ "role": "user", "content": "live", "timestamp": 7000 })),
        ]);
        let history = load(&path, "second summary", None).unwrap().unwrap();
        assert_eq!(history.cut, "f");
        let kinds: Vec<ItemKind> = history.items.iter().map(|i| i.kind).collect();
        assert_eq!(kinds, [ItemKind::User, ItemKind::Tool, ItemKind::Note, ItemKind::Compaction]);
        assert_eq!(history.items[0].text, "first");
        assert_eq!(history.items[0].id, "h0");
        assert!(history.items[1].output.as_ref().unwrap().len() < 5_000);
        assert_eq!(history.items[2].at, Some(crate::session::parse_iso_ms("2026-10-30T15:18:01.000Z").unwrap()));
        assert_eq!(history.items[3].text, "first summary");

        // Unchanged compaction: the same history back, without rebuilding.
        let again = load(&path, "second summary", Some(history.clone())).unwrap().unwrap();
        assert!(Arc::ptr_eq(&again, &history));
        // The context's summary isn't the file's last compaction yet: no history rather than a gap.
        assert!(load(&path, "third summary", Some(history)).unwrap().is_none());
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn follows_the_current_branch_and_skips_uncompacted_sessions() {
        let path = write(&[
            json!({ "type": "session", "id": "s" }),
            message("a", "s", json!({ "role": "user", "content": "abandoned", "timestamp": 1000 })),
            message("b", "s", json!({ "role": "user", "content": "kept", "timestamp": 2000 })),
            json!({ "type": "compaction", "id": "c", "parentId": "b", "summary": "s", "firstKeptEntryId": "c2" }),
            message("c2", "c", json!({ "role": "user", "content": "live", "timestamp": 3000 })),
        ]);
        let history = load(&path, "s", None).unwrap().unwrap();
        let texts: Vec<&str> = history.items.iter().map(|i| i.text.as_str()).collect();
        assert_eq!(texts, ["kept"]);
        std::fs::remove_file(&path).unwrap();

        let path = write(&[json!({ "type": "session", "id": "s" }), message("a", "s", json!({ "role": "user", "content": "hi" }))]);
        assert!(load(&path, "", None).unwrap().is_none());
        std::fs::remove_file(path).unwrap();
    }
}
