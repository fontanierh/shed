//! The user's GitHub, read with this machine's `gh` (signed in with `gh auth login`): their contributions per day
//! over the last year, across every repository, and their open pull requests with review and check status, for the
//! apps' home page.

use std::sync::Mutex;
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Result};
use serde_json::{json, Value};

/// GitHub's API can be slow: past this the home page shows what it had.
const GH_TIMEOUT: Duration = Duration::from_secs(20);
/// The home page asks on every visit; GitHub's numbers move slowly.
const CACHE_FOR: Duration = Duration::from_secs(90);
/// At most this many open pull requests are sent, the most recently updated first.
const MAX_PRS: usize = 30;

static CACHE: Mutex<Option<(Instant, Value)>> = Mutex::new(None);

const CALENDAR: &str = "query { viewer { login name avatarUrl contributionsCollection { contributionCalendar { totalContributions weeks { contributionDays { date contributionCount } } } } } }";

const PULLS: &str = "query($q: String!, $n: Int!) { search(query: $q, type: ISSUE, first: $n) { nodes { ... on PullRequest { number title url isDraft createdAt updatedAt additions deletions reviewDecision repository { nameWithOwner } commits(last: 1) { nodes { commit { statusCheckRollup { state } } } } } } } }";

/// Contributions and open pull requests of the account `gh` is signed in to here.
pub async fn overview() -> Result<Value> {
    if let Some((at, value)) = CACHE.lock().unwrap().as_ref() {
        if at.elapsed() < CACHE_FOR {
            return Ok(value.clone());
        }
    }
    let calendar = gh_graphql(CALENDAR, &[]).await?;
    let viewer = &calendar["data"]["viewer"];
    let login = viewer["login"]
        .as_str()
        .ok_or_else(|| anyhow!("gh returned no account"))?
        .to_string();
    let query = format!("is:pr is:open archived:false author:{login} sort:updated-desc");
    let pulls = gh_graphql(PULLS, &[("q", &query), ("n", &MAX_PRS.to_string())]).await?;

    let value = shape(&calendar, &pulls);
    *CACHE.lock().unwrap() = Some((Instant::now(), value.clone()));
    Ok(value)
}

/// The apps' shape: `{login, name, total, days: [{day, count}], prs: [...]}`.
fn shape(calendar: &Value, pulls: &Value) -> Value {
    let viewer = &calendar["data"]["viewer"];
    let cal = &viewer["contributionsCollection"]["contributionCalendar"];
    let days: Vec<Value> = cal["weeks"]
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|w| {
            w["contributionDays"]
                .as_array()
                .cloned()
                .unwrap_or_default()
        })
        .map(|d| json!({ "day": d["date"], "count": d["contributionCount"] }))
        .collect();
    let prs: Vec<Value> = pulls["data"]["search"]["nodes"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|n| n["number"].is_number())
        .map(|n| {
            let checks = &n["commits"]["nodes"][0]["commit"]["statusCheckRollup"]["state"];
            json!({
                "number": n["number"],
                "title": n["title"],
                "url": n["url"],
                "repo": n["repository"]["nameWithOwner"],
                "draft": n["isDraft"].as_bool().unwrap_or(false),
                "createdAt": n["createdAt"],
                "updatedAt": n["updatedAt"],
                "added": n["additions"].as_u64().unwrap_or(0),
                "deleted": n["deletions"].as_u64().unwrap_or(0),
                // APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED, or null.
                "review": n["reviewDecision"],
                // SUCCESS, FAILURE, ERROR, PENDING, EXPECTED, or null without checks.
                "checks": checks,
            })
        })
        .collect();
    json!({
        "login": viewer["login"],
        "name": viewer["name"],
        "total": cal["totalContributions"].as_u64().unwrap_or(0),
        "days": days,
        "prs": prs,
    })
}

async fn gh_graphql(query: &str, vars: &[(&str, &str)]) -> Result<Value> {
    let mut command = tokio::process::Command::new(gh_binary());
    command
        .args(["api", "graphql", "-f"])
        .arg(format!("query={query}"));
    for (name, value) in vars {
        // -F types numbers; strings go with -f.
        let flag = if value.parse::<i64>().is_ok() {
            "-F"
        } else {
            "-f"
        };
        command.arg(flag).arg(format!("{name}={value}"));
    }
    command
        .env("GH_PROMPT_DISABLED", "1")
        .env("GH_NO_UPDATE_NOTIFIER", "1")
        .kill_on_drop(true)
        .stdin(std::process::Stdio::null());
    let out = tokio::time::timeout(GH_TIMEOUT, command.output())
        .await
        .map_err(|_| anyhow!("GitHub didn't answer in time"))?
        .map_err(|_| anyhow!("gh isn't installed on this computer"))?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        if err.contains("auth login") || err.contains("not logged") {
            bail!("gh isn't signed in on this computer: run `gh auth login`");
        }
        bail!("gh: {}", err.lines().next().unwrap_or("failed"));
    }
    Ok(serde_json::from_slice(&out.stdout)?)
}

fn gh_binary() -> String {
    crate::host::find_binary("gh", &["/opt/homebrew/bin/gh", "/usr/local/bin/gh"])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shapes_calendar_and_pull_requests() {
        let calendar = json!({"data": {"viewer": {"login": "me", "name": "Me", "contributionsCollection": {"contributionCalendar": {
            "totalContributions": 5,
            "weeks": [{"contributionDays": [{"date": "2026-11-01", "contributionCount": 2}, {"date": "2026-11-02", "contributionCount": 3}]}]
        }}}}});
        let pulls = json!({"data": {"search": {"nodes": [
            {"number": 7, "title": "Fix", "url": "u", "isDraft": false, "createdAt": "c", "updatedAt": "u", "additions": 10, "deletions": 2,
             "reviewDecision": "APPROVED", "repository": {"nameWithOwner": "o/r"},
             "commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": "SUCCESS"}}}]}},
            {}
        ]}}});
        let v = shape(&calendar, &pulls);
        assert_eq!(v["total"], 5);
        assert_eq!(v["days"].as_array().unwrap().len(), 2);
        assert_eq!(v["days"][1]["count"], 3);
        assert_eq!(v["prs"].as_array().unwrap().len(), 1);
        assert_eq!(v["prs"][0]["repo"], "o/r");
        assert_eq!(v["prs"][0]["checks"], "SUCCESS");
        assert_eq!(v["prs"][0]["review"], "APPROVED");
    }
}
