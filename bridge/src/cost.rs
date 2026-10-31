//! What a Prime session has really cost: its own model calls plus everything its subagents spent on its behalf.
//! Prime's stats and roster only count the session's own calls, and a subagent's own figure goes when the subagent is
//! retired, so the session file is the record: it's append-only, and Prime writes each subagent's spending into the
//! parent's file as `child_usage_attributed` entries (themselves including the subagent's own subagents).
use serde_json::Value;
use std::collections::HashMap;
use std::io::{Read, Seek, SeekFrom};

#[derive(Default)]
struct Ledger {
    /// Bytes read so far; a file shorter than this was rewritten, so it's read again from the start.
    offset: u64,
    /// A last line not yet complete.
    partial: Vec<u8>,
    own: f64,
    children: f64,
}

#[derive(Default)]
pub struct Costs {
    ledgers: std::sync::Mutex<HashMap<String, Ledger>>,
}

impl Costs {
    /// Spending recorded in `file`, read from where the last call stopped: `(own, subagents)`.
    pub fn read(&self, file: &str) -> Option<(f64, f64)> {
        let mut ledgers = self.ledgers.lock().unwrap();
        let ledger = ledgers.entry(file.to_string()).or_default();
        let mut f = std::fs::File::open(file).ok()?;
        let len = f.metadata().ok()?.len();
        if len < ledger.offset {
            *ledger = Ledger::default();
        }
        if len > ledger.offset {
            f.seek(SeekFrom::Start(ledger.offset)).ok()?;
            let mut bytes = std::mem::take(&mut ledger.partial);
            let read = f.take(len - ledger.offset).read_to_end(&mut bytes).ok()? as u64;
            ledger.offset += read;
            let complete = bytes.iter().rposition(|&b| b == b'\n').map_or(0, |i| i + 1);
            ledger.partial = bytes.split_off(complete);
            for line in bytes.split(|&b| b == b'\n').filter(|l| !l.is_empty()) {
                let Ok(entry) = serde_json::from_slice::<Value>(line) else { continue };
                match entry["type"].as_str().unwrap_or("") {
                    "message" if entry["message"]["role"] == "assistant" => ledger.own += total(&entry["message"]["usage"]),
                    "compaction" | "branch_summary" | "usage" => ledger.own += total(&entry["usage"]),
                    "child_usage_attributed" => ledger.children += total(&entry["childUsage"]),
                    _ => {}
                }
            }
        }
        Some((ledger.own, ledger.children))
    }
}

/// `usage.cost.total`, or a bare `usage.cost` number.
fn total(usage: &Value) -> f64 {
    usage["cost"]["total"].as_f64().or_else(|| usage["cost"].as_f64()).unwrap_or(0.0)
}
