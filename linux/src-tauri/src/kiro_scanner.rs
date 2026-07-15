//! Local Kiro CLI session cost scanner — port of macOS `KiroCostScanner`.
//!
//! Sources (first found wins per conversation id, newer updated_at preferred):
//!   - `~/.local/share/kiro-cli/data.sqlite3` (`conversations` + `conversations_v2`)
//!   - `~/.kiro_sessions/*.json` archives (optional)
//!
//! Token/cost estimates mirror the macOS scanner (chars÷4 + cache-read
//! derivation + chunk output count; Anthropic-style cache pricing).

use chrono::{DateTime, Duration, Local, TimeZone};
use rusqlite::{Connection, OpenFlags};
use serde_json::Value;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

use crate::usage::{DailyModel, DailyUsage, UsageReport};

pub const HISTORY_DAYS: i64 = 90;
const CHARS_PER_TOKEN: usize = 4;

fn home() -> PathBuf {
    std::env::var("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("/tmp"))
}

fn cli_db_path() -> PathBuf {
    if let Ok(p) = std::env::var("KIRO_CLI_DB") {
        let p = p.trim();
        if !p.is_empty() {
            return PathBuf::from(p);
        }
    }
    // Linux default; macOS path kept for cross-platform tests / dual-boot.
    let linux = home().join(".local/share/kiro-cli/data.sqlite3");
    if linux.is_file() {
        return linux;
    }
    home().join("Library/Application Support/kiro-cli/data.sqlite3")
}

fn archive_dir() -> PathBuf {
    if let Ok(p) = std::env::var("KIRO_SESSIONS_DIR") {
        let p = p.trim();
        if !p.is_empty() {
            return PathBuf::from(p);
        }
    }
    home().join(".kiro_sessions")
}

fn price_for(model: &str) -> (f64, f64, f64) {
    let m = model.to_lowercase();
    if m.contains("opus-4.6")
        || m.contains("opus-4-6")
        || m.contains("opus-4.5")
        || m.contains("opus-4-5")
    {
        return (6.25, 0.50, 25.0);
    }
    if m.contains("opus") {
        return (18.75, 1.50, 75.0);
    }
    if m.contains("sonnet") {
        return (3.75, 0.30, 15.0);
    }
    if m.contains("haiku") {
        return (1.25, 0.10, 5.0);
    }
    (6.25, 0.50, 25.0)
}

fn estimate_usd(cw: i64, cr: i64, out: i64, model: &str) -> f64 {
    let (pw, pr, po) = price_for(model);
    (cw as f64 * pw + cr as f64 * pr + out as f64 * po) / 1_000_000.0
}

fn text_token_estimate(field: &Value) -> i64 {
    match field {
        Value::Null | Value::Bool(_) | Value::Number(_) => 0,
        Value::String(s) => (s.chars().count() / CHARS_PER_TOKEN) as i64,
        Value::Array(arr) => arr.iter().map(text_token_estimate).sum(),
        Value::Object(map) => map
            .iter()
            .filter(|(k, _)| k.as_str() != "images")
            .map(|(_, v)| text_token_estimate(v))
            .sum(),
    }
}

fn image_token_estimate(field: &Value) -> i64 {
    field
        .get("images")
        .and_then(Value::as_array)
        .map(|a| a.len() as i64 * 1600)
        .unwrap_or(0)
}

fn i64_val(v: Option<&Value>) -> i64 {
    match v {
        Some(Value::Number(n)) => n.as_i64().or_else(|| n.as_f64().map(|f| f as i64)).unwrap_or(0),
        Some(Value::String(s)) => s.parse().unwrap_or(0),
        _ => 0,
    }
}

struct SessionPoint {
    day: String, // YYYY-MM-DD local
    tokens: i64,
    usd: f64,
    model: String,
}

struct ConversationSnap {
    id: String,
    updated_ms: i64,
    created_ms: i64,
    value: Value,
}

/// Expand one conversation JSON into per-day/model points.
fn parse_conversation(
    data: &Value,
    fallback_created_ms: i64,
    cutoff: chrono::NaiveDate,
) -> Vec<SessionPoint> {
    let turns = match data.get("history").and_then(Value::as_array) {
        Some(t) if !t.is_empty() => t,
        _ => return vec![],
    };

    let summary_tok = data
        .get("latest_summary")
        .map(text_token_estimate)
        .unwrap_or(0);
    let mut cumulative = summary_tok;
    let mut prev_asst = 0i64;

    // day → model → (tokens, usd)
    let mut buckets: HashMap<String, HashMap<String, (i64, f64)>> = HashMap::new();

    for (i, turn) in turns.iter().enumerate() {
        let meta = turn.get("request_metadata").cloned().unwrap_or(Value::Null);
        let model = meta
            .get("model_id")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .unwrap_or("kiro")
            .to_string();

        let user_tok = text_token_estimate(turn.get("user").unwrap_or(&Value::Null))
            + image_token_estimate(turn.get("user").unwrap_or(&Value::Null));
        let asst_tok = text_token_estimate(turn.get("assistant").unwrap_or(&Value::Null));
        let out_tok = meta
            .get("time_between_chunks")
            .and_then(Value::as_array)
            .map(|a| a.len() as i64)
            .unwrap_or(asst_tok);

        let cr = if i > 0 { cumulative } else { 0 };
        let cw = user_tok + if i > 0 { prev_asst } else { 0 };
        let total_tokens = cw + cr + out_tok;
        let usd = estimate_usd(cw, cr, out_tok, &model);

        cumulative += user_tok + asst_tok;
        prev_asst = asst_tok;

        let ts_ms = i64_val(meta.get("request_start_timestamp_ms"));
        let active_ms = if ts_ms > 0 {
            ts_ms
        } else if fallback_created_ms > 0 {
            fallback_created_ms
        } else {
            continue;
        };
        let Some(dt) = Local.timestamp_millis_opt(active_ms).single() else {
            continue;
        };
        let day = dt.date_naive();
        if day < cutoff {
            continue;
        }
        if total_tokens <= 0 && usd <= 0.0 {
            continue;
        }
        let key = day.format("%Y-%m-%d").to_string();
        let m = buckets
            .entry(key)
            .or_default()
            .entry(model)
            .or_default();
        m.0 += total_tokens;
        m.1 += usd;
    }

    let mut points = Vec::new();
    for (day, models) in buckets {
        for (model, (tokens, usd)) in models {
            if tokens > 0 || usd > 0.0 {
                points.push(SessionPoint {
                    day: day.clone(),
                    tokens,
                    usd,
                    model,
                });
            }
        }
    }
    points
}

fn load_archive(dir: &Path, cutoff_ms: i64) -> Vec<ConversationSnap> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return vec![];
    };
    let mut out = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("json") {
            continue;
        }
        let Ok(text) = std::fs::read_to_string(&path) else {
            continue;
        };
        let Ok(json) = serde_json::from_str::<Value>(&text) else {
            continue;
        };
        let updated = i64_val(json.get("updated_at"));
        if updated > 0 && updated < cutoff_ms {
            continue;
        }
        let created = i64_val(json.get("created_at"));
        let value = json
            .get("value")
            .cloned()
            .unwrap_or_else(|| json.clone());
        let id = json
            .get("conversation_id")
            .or_else(|| value.get("conversation_id"))
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        if id.is_empty() {
            continue;
        }
        out.push(ConversationSnap {
            id,
            updated_ms: updated,
            created_ms: created,
            value,
        });
    }
    out
}

fn load_sqlite(db: &Path, cutoff_ms: i64) -> Vec<ConversationSnap> {
    if !db.is_file() {
        return vec![];
    }
    // immutable URI so a live kiro-cli writer does not block us.
    let uri = format!("file:{}?mode=ro&immutable=1", db.display());
    let Ok(conn) = Connection::open_with_flags(
        &uri,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_URI,
    ) else {
        return vec![];
    };
    let _ = conn.busy_timeout(std::time::Duration::from_millis(200));

    let mut out = Vec::new();

    // conversations_v2
    if let Ok(mut stmt) = conn.prepare(
        "SELECT conversation_id, created_at, updated_at, value FROM conversations_v2 WHERE updated_at >= ?",
    ) {
        if let Ok(rows) = stmt.query_map([cutoff_ms], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, i64>(1)?,
                row.get::<_, i64>(2)?,
                row.get::<_, String>(3)?,
            ))
        }) {
            for row in rows.flatten() {
                let (cid, created, updated, raw) = row;
                if let Ok(value) = serde_json::from_str::<Value>(&raw) {
                    out.push(ConversationSnap {
                        id: cid,
                        updated_ms: updated,
                        created_ms: created,
                        value,
                    });
                }
            }
        }
    }

    // conversations (kiro-cli 2.0.1+)
    if let Ok(mut stmt) = conn.prepare("SELECT value FROM conversations") {
        if let Ok(rows) = stmt.query_map([], |row| row.get::<_, String>(0)) {
            for raw in rows.flatten() {
                let Ok(value) = serde_json::from_str::<Value>(&raw) else {
                    continue;
                };
                let Some(cid) = value.get("conversation_id").and_then(Value::as_str) else {
                    continue;
                };
                let history = value
                    .get("history")
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default();
                if history.is_empty() {
                    continue;
                }
                let first = history
                    .first()
                    .and_then(|t| t.get("request_metadata"))
                    .map(|m| i64_val(m.get("request_start_timestamp_ms")))
                    .unwrap_or(0);
                let last = history
                    .last()
                    .and_then(|t| t.get("request_metadata"))
                    .map(|m| i64_val(m.get("request_start_timestamp_ms")))
                    .unwrap_or(first);
                if last < cutoff_ms {
                    continue;
                }
                out.push(ConversationSnap {
                    id: cid.to_string(),
                    updated_ms: last,
                    created_ms: first,
                    value,
                });
            }
        }
    }

    out
}

pub fn usage_report() -> Option<UsageReport> {
    Some(scan(Local::now()))
}

pub fn scan(now: DateTime<Local>) -> UsageReport {
    let today = now.date_naive();
    let cutoff = today - Duration::days(HISTORY_DAYS - 1);
    let cutoff_ms = Local
        .from_local_datetime(&cutoff.and_hms_opt(0, 0, 0).unwrap_or_default())
        .single()
        .map(|d| d.timestamp_millis())
        .unwrap_or(0);

    // Dedup by conversation id (prefer newer updated_at).
    let mut by_id: HashMap<String, ConversationSnap> = HashMap::new();
    for snap in load_archive(&archive_dir(), cutoff_ms) {
        match by_id.get(&snap.id) {
            Some(existing) if existing.updated_ms >= snap.updated_ms => {}
            _ => {
                by_id.insert(snap.id.clone(), snap);
            }
        }
    }
    for snap in load_sqlite(&cli_db_path(), cutoff_ms) {
        match by_id.get(&snap.id) {
            Some(existing) if existing.updated_ms >= snap.updated_ms => {}
            _ => {
                by_id.insert(snap.id.clone(), snap);
            }
        }
    }

    // day → (usd, tokens, model → (usd, tokens))
    let mut buckets: HashMap<String, (f64, i64, HashMap<String, (f64, i64)>)> = HashMap::new();
    for snap in by_id.values() {
        for p in parse_conversation(&snap.value, snap.created_ms, cutoff) {
            let b = buckets.entry(p.day).or_default();
            b.0 += p.usd;
            b.1 += p.tokens;
            let m = b.2.entry(p.model).or_default();
            m.0 += p.usd;
            m.1 += p.tokens;
        }
    }

    let mut daily = Vec::new();
    for offset in (0..HISTORY_DAYS).rev() {
        let day = today - Duration::days(offset);
        let key = day.format("%Y-%m-%d").to_string();
        let (usd, tokens, models_map) = buckets.remove(&key).unwrap_or_default();
        let mut models: Vec<DailyModel> = models_map
            .into_iter()
            .map(|(name, (u, t))| DailyModel {
                name,
                usd: u,
                tokens: t,
            })
            .collect();
        // Token-first (macOS All chart parity).
        models.sort_by(|a, b| {
            b.tokens
                .cmp(&a.tokens)
                .then(
                    b.usd
                        .partial_cmp(&a.usd)
                        .unwrap_or(std::cmp::Ordering::Equal),
                )
        });
        models.truncate(5);
        daily.push(DailyUsage {
            date: key,
            usd,
            tokens,
            models,
        });
    }

    let last30_usd: f64 = daily.iter().rev().take(30).map(|d| d.usd).sum();
    let last30_tokens: i64 = daily.iter().rev().take(30).map(|d| d.tokens).sum();
    let today_usd = daily.last().map(|d| d.usd).unwrap_or(0.0);
    let today_tokens = daily.last().map(|d| d.tokens).unwrap_or(0);
    let top_model = daily
        .iter()
        .rev()
        .take(30)
        .flat_map(|d| d.models.iter())
        .max_by_key(|m| m.tokens)
        .map(|m| m.name.clone());

    UsageReport {
        today_usd,
        today_tokens,
        last30_usd,
        last30_tokens,
        daily,
        hourly: vec![],
        top_model,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parse_conversation_emits_tokens() {
        let now = Local::now();
        let ts = now.timestamp_millis();
        let data = json!({
            "conversation_id": "sess-1",
            "history": [{
                "user": { "content": "a".repeat(400) },
                "assistant": { "content": "b".repeat(200) },
                "request_metadata": {
                    "model_id": "claude-sonnet-4",
                    "request_start_timestamp_ms": ts,
                    "time_between_chunks": [1, 1, 1, 1]
                }
            }]
        });
        let cutoff = now.date_naive() - Duration::days(1);
        let points = parse_conversation(&data, ts, cutoff);
        assert!(!points.is_empty());
        assert!(points.iter().any(|p| p.model == "claude-sonnet-4"));
        assert!(points.iter().map(|p| p.tokens).sum::<i64>() > 0);
    }

    #[test]
    fn empty_db_yields_90_zero_days() {
        let report = scan(Local::now());
        assert_eq!(report.daily.len(), HISTORY_DAYS as usize);
        assert_eq!(report.today_tokens, 0);
    }
}
