//! Kiro CLI cost scanner — port of macOS `KiroCostScanner.swift`.
//!
//! Ba thế hệ lưu trữ được quét, đúng thứ tự macOS (archive -> sqlite -> cli),
//! gộp theo id session/conversation và ưu tiên bản `updated_at` mới nhất:
//!   - `~/.kiro_sessions/*.json` — archive cũ (tùy chọn).
//!   - `~/.local/share/kiro-cli/data.sqlite3` (hoặc `$XDG_DATA_HOME/kiro-cli/...`)
//!     — CLI thế hệ cũ hơn, bảng `conversations_v2` + `conversations`.
//!   - `~/.kiro/sessions/cli/<id>.json` — TUI kiro-cli hiện tại (BẮT BUỘC).
//!     USD là số credit BỊ TÍNH PHÍ THẬT (`metering_usage`) × $0.04/credit.
//! Không có dữ liệu thật thì trả về báo cáo trống — không suy diễn số liệu.

use chrono::{DateTime, Duration, Local, NaiveDate, TimeZone};
use rusqlite::{Connection, OpenFlags};
use serde_json::Value;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

use crate::usage::{DailyModel, DailyUsage, UsageReport};

pub const HISTORY_DAYS: i64 = 120;
const CHARS_PER_TOKEN: i64 = 4;
/// Kiro bills in credits; add-on/overage credits are $0.04 each
/// (kiro.dev/pricing) — chuyển credit bị tính phí thật sang USD.
const USD_PER_CREDIT: f64 = 0.04;

pub struct KiroUsageScan {
    pub usage: UsageReport,
}

/// Bảng giá theo $/MTok (write/read/output) cho các model Kiro hay host,
/// dùng cho thế hệ SQLite/archive (ước lượng chars÷4, không phải credit thật).
struct KiroModelPrice {
    write_per_m: f64,
    read_per_m: f64,
    output_per_m: f64,
}

impl KiroModelPrice {
    fn for_model(model: &str) -> Self {
        let m = model.to_lowercase();
        if m.contains("opus-4.6") || m.contains("opus-4-6") || m.contains("opus-4.5") || m.contains("opus-4-5") {
            return Self { write_per_m: 6.25, read_per_m: 0.50, output_per_m: 25.0 };
        }
        if m.contains("opus") {
            return Self { write_per_m: 18.75, read_per_m: 1.50, output_per_m: 75.0 };
        }
        if m.contains("sonnet") {
            return Self { write_per_m: 3.75, read_per_m: 0.30, output_per_m: 15.0 };
        }
        if m.contains("haiku") {
            return Self { write_per_m: 1.25, read_per_m: 0.10, output_per_m: 5.0 };
        }
        // Model không rõ / free tier: mặc định theo giá Opus 4.5 để vẫn hiển thị chi phí.
        Self { write_per_m: 6.25, read_per_m: 0.50, output_per_m: 25.0 }
    }

    fn estimate_usd(cache_write: i64, cache_read: i64, output: i64, model: &str) -> f64 {
        let p = Self::for_model(model);
        (cache_write as f64 * p.write_per_m + cache_read as f64 * p.read_per_m + output as f64 * p.output_per_m)
            / 1_000_000.0
    }
}

struct SessionPoint {
    day: NaiveDate,
    tokens: i64,
    usd: f64,
    model: String,
}

/// Full scan using the real `$HOME`. Returns an empty report (never
/// fabricated numbers) when `$HOME` is unset or no storage generation is
/// readable.
pub fn scan_kiro_usage(now: DateTime<Local>) -> KiroUsageScan {
    let Ok(home) = std::env::var("HOME") else {
        return KiroUsageScan { usage: UsageReport::default() };
    };
    if home.trim().is_empty() {
        return KiroUsageScan { usage: UsageReport::default() };
    }
    scan_kiro_usage_at(Path::new(&home), now)
}

/// Path-injectable core scan — unit-testable without touching real `$HOME`.
fn scan_kiro_usage_at(home: &Path, now: DateTime<Local>) -> KiroUsageScan {
    let cutoff_date = (now - Duration::days(HISTORY_DAYS)).date_naive();
    let cutoff_ms = cutoff_date
        .and_hms_opt(0, 0, 0)
        .and_then(|dt| Local.from_local_datetime(&dt).single())
        .map(|dt| dt.timestamp_millis())
        .unwrap_or_else(|| now.timestamp_millis() - HISTORY_DAYS * 86_400_000);

    // Gộp theo session/conversation id: id -> (updated_at ms, points). Nguồn
    // xử lý sau chỉ thắng nguồn trước khi updated_at THỰC SỰ mới hơn, giống
    // `loadPointsResult` bên Swift.
    let mut by_id: HashMap<String, (i64, Vec<SessionPoint>)> = HashMap::new();

    load_archive(home, cutoff_ms, cutoff_date, &mut by_id);
    load_sqlite(home, cutoff_ms, cutoff_date, &mut by_id);
    load_cli_sessions(home, cutoff_ms, cutoff_date, &mut by_id); // Thế hệ bắt buộc.

    let points: Vec<SessionPoint> = by_id.into_values().flat_map(|(_, pts)| pts).collect();
    KiroUsageScan { usage: build_report(points, now) }
}

fn merge_points(
    by_id: &mut HashMap<String, (i64, Vec<SessionPoint>)>,
    id: String,
    updated_ms: i64,
    points: Vec<SessionPoint>,
) {
    if let Some((existing_updated, _)) = by_id.get(&id) {
        if *existing_updated >= updated_ms {
            return;
        }
    }
    by_id.insert(id, (updated_ms, points));
}

// --- Generation: ~/.kiro/sessions/cli/<id>.json (MANDATORY) ---------------

fn cli_sessions_dir(home: &Path) -> PathBuf {
    home.join(".kiro").join("sessions").join("cli")
}

/// TUI kiro-cli hiện tại lưu mỗi session thành `cli/<id>.json` (metadata +
/// metering theo turn); các bảng SQLite cũ vẫn trống trên bản build này.
fn load_cli_sessions(
    home: &Path,
    cutoff_ms: i64,
    cutoff_date: NaiveDate,
    by_id: &mut HashMap<String, (i64, Vec<SessionPoint>)>,
) {
    let dir = cli_sessions_dir(home);
    if !dir.is_dir() {
        return;
    }
    let Ok(entries) = std::fs::read_dir(&dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|s| s.to_str()) != Some("json") {
            continue;
        }
        let Ok(text) = std::fs::read_to_string(&path) else { continue };
        let Ok(json) = serde_json::from_str::<Value>(&text) else { continue };
        if !json.get("session_state").map(Value::is_object).unwrap_or(false) {
            continue;
        }
        let sid = json
            .get("session_id")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .map(str::to_string)
            .or_else(|| path.file_stem().and_then(|s| s.to_str()).map(str::to_string));
        let Some(sid) = sid else { continue };

        let updated_ms = json
            .get("updated_at")
            .and_then(Value::as_str)
            .and_then(parse_iso_date)
            .map(|d| d.timestamp_millis())
            .unwrap_or(0);
        // Lenient: file thiếu updated_at (0) vẫn được xét, khác với sqlite/archive.
        if updated_ms > 0 && updated_ms < cutoff_ms {
            continue;
        }

        let points = parse_cli_session_sidecar(&json, cutoff_date);
        if points.is_empty() {
            continue;
        }
        merge_points(by_id, sid, updated_ms, points);
    }
}

/// One sidecar -> per-day SessionPoints. USD là REAL (credit `metering_usage`
/// mỗi turn × $0.04); token ưu tiên số đếm chính xác của CLI, fallback sang
/// tăng trưởng context-window (delta `context_usage_percentage` × cửa sổ)
/// khi CLI trả về 0.
fn parse_cli_session_sidecar(json: &Value, cutoff_date: NaiveDate) -> Vec<SessionPoint> {
    let Some(turns) = json
        .pointer("/session_state/conversation_metadata/user_turn_metadatas")
        .and_then(Value::as_array)
    else {
        return Vec::new();
    };
    if turns.is_empty() {
        return Vec::new();
    }

    let model = json
        .pointer("/session_state/rts_model_state/model_info/model_id")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or("kiro")
        .to_string();
    let context_window = json
        .pointer("/session_state/rts_model_state/model_info/context_window_tokens")
        .and_then(Value::as_i64)
        .filter(|&w| w > 0)
        .unwrap_or(200_000);

    let session_created = json.get("created_at").and_then(Value::as_str).and_then(parse_iso_date);

    let mut prev_pct = 0.0_f64;
    let mut buckets: HashMap<NaiveDate, (i64, f64)> = HashMap::new();

    for turn in turns {
        // Real billed credits for the turn (one entry per request).
        let mut credits = 0.0_f64;
        if let Some(entries) = turn.get("metering_usage").and_then(Value::as_array) {
            for e in entries {
                let unit = e.get("unit").and_then(Value::as_str).unwrap_or("").to_lowercase();
                if !unit.contains("credit") {
                    continue;
                }
                credits += e.get("value").and_then(Value::as_f64).unwrap_or(0.0);
            }
        }
        let usd = credits * USD_PER_CREDIT;

        // Exact token counts when the CLI populates them; else grow-of-context
        // estimate (context_usage_percentage là lũy tiến, nên delta theo turn
        // mới là phần turn này thêm vào; kẹp về 0 vì compaction có thể giảm nó).
        let mut tokens = turn.get("input_token_count").and_then(Value::as_i64).unwrap_or(0)
            + turn.get("output_token_count").and_then(Value::as_i64).unwrap_or(0);
        let pct = turn.get("context_usage_percentage").and_then(Value::as_f64).unwrap_or(0.0);
        if tokens == 0 && pct > 0.0 {
            let delta = (pct - prev_pct).max(0.0);
            tokens = ((delta / 100.0) * context_window as f64).round() as i64;
        }
        if pct > 0.0 {
            prev_pct = pct;
        }

        let active_at = turn
            .get("end_timestamp")
            .and_then(Value::as_str)
            .and_then(parse_iso_date)
            .or(session_created);
        let Some(active_at) = active_at else { continue };
        let day = active_at.date_naive();
        if day < cutoff_date {
            continue;
        }
        if tokens <= 0 && usd <= 0.0 {
            continue;
        }

        let acc = buckets.entry(day).or_insert((0, 0.0));
        acc.0 += tokens;
        acc.1 += usd;
    }

    buckets
        .into_iter()
        .map(|(day, (tokens, usd))| SessionPoint { day, tokens, usd, model: model.clone() })
        .collect()
}

/// ISO8601 with or without fractional seconds ("2026-07-15T06:20:44.636576Z").
fn parse_iso_date(raw: &str) -> Option<DateTime<Local>> {
    if raw.is_empty() {
        return None;
    }
    DateTime::parse_from_rfc3339(raw).ok().map(|dt| dt.with_timezone(&Local))
}

// --- Generation: ~/.local/share/kiro-cli/data.sqlite3 ----------------------

fn cli_db_path(home: &Path) -> PathBuf {
    if let Ok(xdg) = std::env::var("XDG_DATA_HOME") {
        if !xdg.trim().is_empty() {
            return PathBuf::from(xdg).join("kiro-cli").join("data.sqlite3");
        }
    }
    home.join(".local").join("share").join("kiro-cli").join("data.sqlite3")
}

fn load_sqlite(
    home: &Path,
    cutoff_ms: i64,
    cutoff_date: NaiveDate,
    by_id: &mut HashMap<String, (i64, Vec<SessionPoint>)>,
) {
    let db_path = cli_db_path(home);
    if !db_path.is_file() {
        return;
    }
    // immutable=1 để một tiến trình kiro-cli đang chạy ghi song song không bị chặn.
    let uri = format!("file:{}?mode=ro&immutable=1", db_path.to_string_lossy());
    let flags = OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_URI;
    let Ok(conn) = Connection::open_with_flags(&uri, flags) else { return };
    let _ = conn.busy_timeout(std::time::Duration::from_millis(200));

    query_conversations_v2(&conn, cutoff_ms, cutoff_date, by_id);
    query_conversations_v1(&conn, cutoff_ms, cutoff_date, by_id);
}

/// `conversations_v2` (kiro-cli cũ hơn).
fn query_conversations_v2(
    conn: &Connection,
    cutoff_ms: i64,
    cutoff_date: NaiveDate,
    by_id: &mut HashMap<String, (i64, Vec<SessionPoint>)>,
) {
    let sql = "SELECT conversation_id, created_at, updated_at, value FROM conversations_v2 WHERE updated_at >= ?";
    let Ok(mut stmt) = conn.prepare(sql) else { return };
    let Ok(mut rows) = stmt.query([cutoff_ms]) else { return };
    while let Ok(Some(row)) = rows.next() {
        let cid: Option<String> = row.get(0).ok().filter(|s: &String| !s.is_empty());
        let Some(cid) = cid else { continue };
        let created: i64 = row.get(1).unwrap_or(0);
        let updated: i64 = row.get(2).unwrap_or(0);
        let Some(raw) = row.get::<_, String>(3).ok() else { continue };
        let Ok(value) = serde_json::from_str::<Value>(&raw) else { continue };
        if !has_conversation_schema(&value) {
            continue;
        }
        let points = parse_conversation(&value, created, cutoff_date);
        if points.is_empty() {
            continue;
        }
        merge_points(by_id, cid, updated, points);
    }
}

/// `conversations` (kiro-cli 2.0.1+, không có cột updated_at riêng — lấy mốc
/// thời gian từ `request_metadata` của lượt đầu/cuối trong `history`).
fn query_conversations_v1(
    conn: &Connection,
    cutoff_ms: i64,
    cutoff_date: NaiveDate,
    by_id: &mut HashMap<String, (i64, Vec<SessionPoint>)>,
) {
    let sql = "SELECT value FROM conversations";
    let Ok(mut stmt) = conn.prepare(sql) else { return };
    let Ok(mut rows) = stmt.query([]) else { return };
    while let Ok(Some(row)) = rows.next() {
        let Some(raw) = row.get::<_, String>(0).ok() else { continue };
        let Ok(value) = serde_json::from_str::<Value>(&raw) else { continue };
        let Some(cid) = value
            .get("conversation_id")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .map(str::to_string)
        else {
            continue;
        };
        if !has_conversation_schema(&value) {
            continue;
        }
        let Some(history) = value.get("history").and_then(Value::as_array) else { continue };
        if history.is_empty() {
            continue;
        }
        let first = history
            .first()
            .and_then(|t| t.pointer("/request_metadata/request_start_timestamp_ms"))
            .and_then(Value::as_i64)
            .unwrap_or(0);
        let last = history
            .last()
            .and_then(|t| t.pointer("/request_metadata/request_start_timestamp_ms"))
            .and_then(Value::as_i64)
            .unwrap_or(first);
        if last < cutoff_ms {
            continue;
        }
        let points = parse_conversation(&value, first, cutoff_date);
        if points.is_empty() {
            continue;
        }
        merge_points(by_id, cid, last, points);
    }
}

// --- Generation: ~/.kiro_sessions/*.json archives ---------------------------

fn archive_dir(home: &Path) -> PathBuf {
    home.join(".kiro_sessions")
}

fn load_archive(
    home: &Path,
    cutoff_ms: i64,
    cutoff_date: NaiveDate,
    by_id: &mut HashMap<String, (i64, Vec<SessionPoint>)>,
) {
    let dir = archive_dir(home);
    if !dir.is_dir() {
        return;
    }
    let Ok(entries) = std::fs::read_dir(&dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|s| s.to_str()) != Some("json") {
            continue;
        }
        let Ok(text) = std::fs::read_to_string(&path) else { continue };
        let Ok(json) = serde_json::from_str::<Value>(&text) else { continue };

        let created = json.get("created_at").and_then(Value::as_i64).unwrap_or(0);
        let updated = json.get("updated_at").and_then(Value::as_i64).unwrap_or(0);
        // Strict: archive thiếu updated_at (0) bị loại — khác thế hệ cli.
        if updated < cutoff_ms {
            continue;
        }

        let nested = json.get("value").filter(|v| v.is_object());
        let value = nested.unwrap_or(&json);
        let resolved_id = json
            .get("conversation_id")
            .and_then(Value::as_str)
            .or_else(|| value.get("conversation_id").and_then(Value::as_str))
            .filter(|s| !s.is_empty())
            .map(str::to_string);
        let Some(resolved_id) = resolved_id else { continue };
        if !has_conversation_schema(value) {
            continue;
        }

        let points = parse_conversation(value, created, cutoff_date);
        if points.is_empty() {
            continue;
        }
        merge_points(by_id, resolved_id, updated, points);
    }
}

fn has_conversation_schema(value: &Value) -> bool {
    match value.get("history").and_then(Value::as_array) {
        Some(history) => history.iter().all(Value::is_object),
        None => false,
    }
}

/// Expand one conversation into per-day SessionPoints (one per model/day).
/// Dùng cho sqlite + archive — ước lượng token (chars÷4), USD qua bảng giá
/// (không phải credit thật, khác thế hệ CLI hiện tại).
fn parse_conversation(value: &Value, fallback_created_ms: i64, cutoff_date: NaiveDate) -> Vec<SessionPoint> {
    let Some(turns) = value.get("history").and_then(Value::as_array) else { return Vec::new() };
    if turns.is_empty() {
        return Vec::new();
    }

    // Compact summary được gửi lại sau compaction — seed cache lũy tiến.
    let mut cumulative = value.get("latest_summary").map(text_token_estimate).unwrap_or(0);
    let mut prev_asst: i64 = 0;

    // day -> model -> (tokens, usd)
    let mut buckets: HashMap<NaiveDate, HashMap<String, (i64, f64)>> = HashMap::new();

    for (i, turn) in turns.iter().enumerate() {
        let meta = turn.get("request_metadata");
        let model = meta
            .and_then(|m| m.get("model_id"))
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .unwrap_or("kiro")
            .to_string();

        let user_tok = turn.get("user").map(text_token_estimate).unwrap_or(0)
            + turn.get("user").map(image_token_estimate).unwrap_or(0);
        let asst_tok = turn.get("assistant").map(text_token_estimate).unwrap_or(0);
        // Output tokens: accurate chunk count when present.
        let out_tok = meta
            .and_then(|m| m.get("time_between_chunks"))
            .and_then(Value::as_array)
            .map(|a| a.len() as i64)
            .unwrap_or(asst_tok);

        let cr = if i > 0 { cumulative } else { 0 };
        let cw = user_tok + if i > 0 { prev_asst } else { 0 };
        let total_tokens = cw + cr + out_tok;
        let usd = KiroModelPrice::estimate_usd(cw, cr, out_tok, &model);

        cumulative += user_tok + asst_tok;
        prev_asst = asst_tok;

        let ts_ms = meta
            .and_then(|m| m.get("request_start_timestamp_ms"))
            .and_then(Value::as_i64)
            .unwrap_or(0);
        let active_at_ms = if ts_ms > 0 {
            ts_ms
        } else if fallback_created_ms > 0 {
            fallback_created_ms
        } else {
            continue;
        };
        let Some(day) = DateTime::from_timestamp_millis(active_at_ms).map(|dt| dt.with_timezone(&Local).date_naive())
        else {
            continue;
        };
        if day < cutoff_date {
            continue;
        }
        if total_tokens <= 0 && usd <= 0.0 {
            continue;
        }

        let day_models = buckets.entry(day).or_default();
        let acc = day_models.entry(model).or_insert((0, 0.0));
        acc.0 += total_tokens;
        acc.1 += usd;
    }

    let mut points = Vec::new();
    for (day, models) in buckets {
        for (model, (tokens, usd)) in models {
            if tokens > 0 || usd > 0.0 {
                points.push(SessionPoint { day, tokens, usd, model });
            }
        }
    }
    points
}

/// Approximate tokens from textual content (chars ÷ 4), excluding base64 images.
fn text_token_estimate(field: &Value) -> i64 {
    match field {
        Value::String(s) => (s.chars().count() as i64 / CHARS_PER_TOKEN).max(0),
        Value::Object(map) => map
            .iter()
            .filter(|(k, _)| k.as_str() != "images")
            .map(|(_, v)| text_token_estimate(v))
            .sum(),
        Value::Array(arr) => arr.iter().map(text_token_estimate).sum(),
        _ => 0,
    }
}

/// Rough vision tokens for images (~1600 each when dimensions unknown).
fn image_token_estimate(field: &Value) -> i64 {
    let Some(images) = field.get("images").and_then(Value::as_array) else { return 0 };
    if images.is_empty() {
        return 0;
    }
    images.len() as i64 * 1600
}

// --- Report build ------------------------------------------------------------

fn build_report(points: Vec<SessionPoint>, now: DateTime<Local>) -> UsageReport {
    let today_date = now.date_naive();
    let mut daily_map: HashMap<NaiveDate, (f64, i64, HashMap<String, (f64, i64)>)> = HashMap::new();
    for p in points {
        let entry = daily_map.entry(p.day).or_insert_with(|| (0.0, 0, HashMap::new()));
        entry.0 += p.usd;
        entry.1 += p.tokens;
        let m_entry = entry.2.entry(p.model).or_insert((0.0, 0));
        m_entry.0 += p.usd;
        m_entry.1 += p.tokens;
    }

    let mut daily_list = Vec::with_capacity(HISTORY_DAYS as usize);
    let mut last30_usd = 0.0;
    let mut last30_tokens = 0;
    let last30_cutoff = (now - Duration::days(30)).date_naive();

    for i in (0..HISTORY_DAYS).rev() {
        let d = (now - Duration::days(i)).date_naive();
        if let Some((usd, tokens, model_map)) = daily_map.get(&d) {
            let mut models: Vec<DailyModel> = model_map
                .iter()
                .map(|(name, (m_usd, m_tok))| DailyModel { name: name.clone(), usd: *m_usd, tokens: *m_tok })
                .collect();
            // Token-first ranking (matches the All chart preference), top 5.
            models.sort_by(|a, b| {
                b.tokens.cmp(&a.tokens).then_with(|| b.usd.partial_cmp(&a.usd).unwrap_or(std::cmp::Ordering::Equal))
            });
            models.truncate(5);

            if d > last30_cutoff {
                last30_usd += usd;
                last30_tokens += tokens;
            }

            daily_list.push(DailyUsage { date: d.format("%Y-%m-%d").to_string(), usd: *usd, tokens: *tokens, models });
        } else {
            daily_list.push(DailyUsage { date: d.format("%Y-%m-%d").to_string(), usd: 0.0, tokens: 0, models: Vec::new() });
        }
    }

    let today_entry = daily_map.get(&today_date);
    let today_usd = today_entry.map(|e| e.0).unwrap_or(0.0);
    let today_tokens = today_entry.map(|e| e.1).unwrap_or(0);

    let mut model_totals: HashMap<String, (i64, f64)> = HashMap::new();
    for d in daily_list.iter().rev().take(30) {
        for m in &d.models {
            let t = model_totals.entry(m.name.clone()).or_insert((0, 0.0));
            t.0 += m.tokens;
            t.1 += m.usd;
        }
    }
    let top_model = model_totals
        .into_iter()
        .max_by(|a, b| a.1 .0.cmp(&b.1 .0).then(a.1 .1.partial_cmp(&b.1 .1).unwrap_or(std::cmp::Ordering::Equal)))
        .map(|(name, _)| name);

    UsageReport {
        today_usd,
        today_tokens,
        last30_usd,
        last30_tokens,
        daily: daily_list,
        hourly: Vec::new(),
        top_model,
        included: true,
        live: true,
        scanned_at: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write as _;

    #[test]
    fn pricing_table_maps_models_to_expected_rates() {
        let opus45 = KiroModelPrice::for_model("claude-opus-4-5-20260101");
        assert_eq!((opus45.write_per_m, opus45.read_per_m, opus45.output_per_m), (6.25, 0.50, 25.0));

        let opus_legacy = KiroModelPrice::for_model("claude-opus-4-20250101");
        assert_eq!((opus_legacy.write_per_m, opus_legacy.read_per_m, opus_legacy.output_per_m), (18.75, 1.50, 75.0));

        let sonnet = KiroModelPrice::for_model("claude-sonnet-4-5");
        assert_eq!((sonnet.write_per_m, sonnet.read_per_m, sonnet.output_per_m), (3.75, 0.30, 15.0));

        let haiku = KiroModelPrice::for_model("claude-haiku-4-5");
        assert_eq!((haiku.write_per_m, haiku.read_per_m, haiku.output_per_m), (1.25, 0.10, 5.0));

        // Unknown/free-tier models default to Opus 4.5 rates so they stay visible.
        let unknown = KiroModelPrice::for_model("");
        assert_eq!((unknown.write_per_m, unknown.read_per_m, unknown.output_per_m), (6.25, 0.50, 25.0));
    }

    fn write_json(path: &Path, value: &Value) {
        let mut f = std::fs::File::create(path).unwrap();
        f.write_all(serde_json::to_string(value).unwrap().as_bytes()).unwrap();
    }

    #[test]
    fn scan_over_temp_home_reads_cli_session_and_totals_usd_tokens() {
        let tmp = std::env::temp_dir().join(format!("birdnion-kiro-scanner-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp);
        let cli_dir = tmp.join(".kiro").join("sessions").join("cli");
        std::fs::create_dir_all(&cli_dir).unwrap();

        let now = Local::now();
        let end_ts = now.to_rfc3339();
        let session = serde_json::json!({
            "session_id": "sess-1",
            "created_at": end_ts,
            "updated_at": end_ts,
            "session_state": {
                "rts_model_state": {
                    "model_info": { "model_id": "claude-sonnet-4-5", "context_window_tokens": 200000 }
                },
                "conversation_metadata": {
                    "user_turn_metadatas": [
                        {
                            "metering_usage": [ { "unit": "credit", "value": 2.5 } ],
                            "input_token_count": 100,
                            "output_token_count": 50,
                            "end_timestamp": end_ts
                        },
                        {
                            "metering_usage": [ { "unit": "credit", "value": 1.5 } ],
                            "input_token_count": 30,
                            "output_token_count": 20,
                            "end_timestamp": end_ts
                        }
                    ]
                }
            }
        });
        write_json(&cli_dir.join("sess-1.json"), &session);

        let scan = scan_kiro_usage_at(&tmp, now);
        // credits: 2.5 + 1.5 = 4.0 -> USD = 4.0 * 0.04 = 0.16
        assert!((scan.usage.today_usd - 0.16).abs() < 1e-9, "unexpected today_usd: {}", scan.usage.today_usd);
        assert_eq!(scan.usage.today_tokens, 200);
        assert!((scan.usage.last30_usd - 0.16).abs() < 1e-9);
        assert_eq!(scan.usage.last30_tokens, 200);
        assert_eq!(scan.usage.top_model.as_deref(), Some("claude-sonnet-4-5"));

        // Days without sessions must not carry fabricated numbers.
        let yesterday_key = (now - Duration::days(1)).date_naive().format("%Y-%m-%d").to_string();
        let yesterday = scan.usage.daily.iter().find(|d| d.date == yesterday_key).unwrap();
        assert_eq!(yesterday.tokens, 0);
        assert_eq!(yesterday.usd, 0.0);
        assert!(yesterday.models.is_empty());

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn scan_over_missing_home_dir_is_empty_not_fabricated() {
        let tmp = std::env::temp_dir().join(format!("birdnion-kiro-scanner-missing-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp);
        let now = Local::now();
        let scan = scan_kiro_usage_at(&tmp, now);
        assert_eq!(scan.usage.today_tokens, 0);
        assert_eq!(scan.usage.last30_tokens, 0);
        assert!(scan.usage.daily.iter().all(|d| d.tokens == 0 && d.usd == 0.0));
    }

    #[test]
    fn parse_conversation_estimates_tokens_and_usd_from_char_counts() {
        let now = Local::now();
        let value = serde_json::json!({
            "history": [
                {
                    "request_metadata": { "model_id": "claude-sonnet-4-5", "request_start_timestamp_ms": now.timestamp_millis() },
                    "user": "hello world this is a test message with enough characters",
                    "assistant": "this is the assistant reply text with several words in it too"
                }
            ]
        });
        let cutoff = (now - Duration::days(1)).date_naive();
        let points = parse_conversation(&value, 0, cutoff);
        assert_eq!(points.len(), 1);
        assert!(points[0].tokens > 0);
        assert!(points[0].usd > 0.0);
        assert_eq!(points[0].model, "claude-sonnet-4-5");
    }
}
