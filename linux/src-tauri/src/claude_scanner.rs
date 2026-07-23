//! Port of the macOS `ClaudeCostScanner.swift` — scans local Claude Code CLI
//! session logs (`~/.claude/projects/**/*.jsonl`) and rolls token usage up
//! into the shared `UsageReport`. Semantics deliberately mirror the Swift
//! original so both apps show identical numbers:
//! - 120-day daily buckets, but `last30*` totals keep a strict 30-day cutoff
//! - trailing-24 h hour buckets from per-line timestamps
//! - keep-last dedup by `messageId` alone (same assistant message is logged
//!   in both the parent session and subagent files; Claude Code dropped
//!   `requestId` from JSONL)
//! - Vertex AI lines skipped; unknown models count tokens but cost $0
//! - provider-backed Claude Code models with public pricing (Hapo gpt-5.6 /
//!   MiniMax-M2.5, Fable 5, MiniMax-M3) are priced instead of falling through to $0

use chrono::{DateTime, Duration, Local, NaiveDate, Timelike};
use serde_json::Value;
use std::collections::HashMap;
use std::path::PathBuf;
use walkdir::WalkDir;

use crate::usage::{DailyModel, DailyUsage, HourlyUsage, UsageReport};

/// Trailing daily window for charts / heatmap (macOS CombinedUsageReport 120d).
pub const HISTORY_DAYS: i64 = 120;

/// Per-million-token USD prices (input / cache-write / cache-read / output).
/// Same table as the Swift scanner — revisit when Anthropic revises pricing.
struct Price {
    input: f64,
    cache_write: f64,
    cache_read: f64,
    output: f64,
}

fn price_for(model: &str, input_side_tokens: i64) -> Option<Price> {
    let m = model.to_lowercase();
    // Hapo first (matches macOS `hapoPrice` prefix checks before Opus/Haiku/Sonnet).
    if let Some(p) = hapo_price(&m, input_side_tokens) {
        return Some(p);
    }
    if m.contains("fable-5") {
        return Some(Price { input: 10.0, cache_write: 12.5, cache_read: 1.0, output: 50.0 });
    }
    if m.contains("minimax-m3") {
        let over512k = input_side_tokens > 512_000;
        let input = if over512k { 0.60 } else { 0.30 };
        return Some(Price {
            input,
            cache_write: input,
            cache_read: if over512k { 0.12 } else { 0.06 },
            output: if over512k { 2.40 } else { 1.20 },
        });
    }
    // Opus 4.x — $5/$6.25/$0.50/$25 per-M (NOT the old Opus-3 $15/$75).
    if m.contains("opus") {
        return Some(Price { input: 5.0, cache_write: 6.25, cache_read: 0.50, output: 25.0 });
    }
    if m.contains("haiku") {
        return Some(Price { input: 1.0, cache_write: 1.25, cache_read: 0.10, output: 5.0 });
    }
    if m.contains("sonnet") {
        return Some(Price { input: 3.0, cache_write: 3.75, cache_read: 0.30, output: 15.0 });
    }
    None // non-Claude model routed through Claude Code — tokens counted, $0
}

/// Hapo Anthropic-compatible ids from `/v1/models`. Prefix-matched (not
/// substring) so unrelated backends do not gain an inferred price. Mirrors
/// macOS `ClaudeModelPrice.hapoPrice`.
fn hapo_price(m: &str, input_side_tokens: i64) -> Option<Price> {
    if m.starts_with("openai.gpt-5.6-") {
        let long = input_side_tokens > 272_000;
        if m.contains("luna") {
            return Some(Price {
                input: if long { 2.0 } else { 1.0 },
                cache_write: if long { 2.0 } else { 1.0 },
                cache_read: if long { 0.20 } else { 0.10 },
                output: if long { 9.0 } else { 6.0 },
            });
        }
        if m.contains("terra") {
            return Some(Price {
                input: if long { 5.0 } else { 2.5 },
                cache_write: if long { 5.0 } else { 2.5 },
                cache_read: if long { 0.50 } else { 0.25 },
                output: if long { 22.5 } else { 15.0 },
            });
        }
        if m.contains("sol") {
            return Some(Price {
                input: if long { 10.0 } else { 5.0 },
                cache_write: if long { 10.0 } else { 5.0 },
                cache_read: if long { 1.0 } else { 0.5 },
                output: if long { 45.0 } else { 30.0 },
            });
        }
        return None;
    }

    // Current id `minimax.minimax-m2.5`; keep older `minimax-m2.5-ultra-*`
    // so existing session logs reprice.
    if m.starts_with("minimax.minimax-m2.5") || m.starts_with("minimax-m2.5-ultra") {
        let high_speed = m.contains("highspeed");
        return Some(Price {
            input: if high_speed { 0.60 } else { 0.30 },
            cache_write: 0.375,
            cache_read: 0.03,
            output: if high_speed { 2.40 } else { 1.20 },
        });
    }
    None
}

/// One assistant turn's per-day accounting.
struct Entry {
    ts: DateTime<Local>,
    day: NaiveDate,
    usd: f64,
    tokens: i64,
    model: String,
    /// `messageId` for cross-file / multi-block dedup; None → counted individually.
    key: Option<String>,
}

/// Project roots to scan. `CLAUDE_CONFIG_DIR` wins (comma-separated, each
/// entry's `projects/` subdir); otherwise both XDG and legacy homes are
/// scanned — identical to the Swift scanner.
pub fn default_roots() -> Vec<PathBuf> {
    if let Ok(raw) = std::env::var("CLAUDE_CONFIG_DIR") {
        let roots: Vec<PathBuf> = raw
            .split(',')
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(|p| {
                let path = PathBuf::from(p);
                if path.file_name().is_some_and(|n| n == "projects") {
                    path
                } else {
                    path.join("projects")
                }
            })
            .collect();
        if !roots.is_empty() {
            return roots;
        }
    }
    let home = PathBuf::from(std::env::var("HOME").unwrap_or_default());
    vec![
        home.join(".config/claude/projects"),
        home.join(".claude/projects"),
    ]
}

pub fn usage_report() -> Option<UsageReport> {
    scan(&default_roots(), Local::now())
}

/// Walks every session jsonl once and produces the full report.
/// Returns None only when no projects root is readable.
pub fn scan(roots: &[PathBuf], now: DateTime<Local>) -> Option<UsageReport> {
    let cutoff = now - Duration::days(HISTORY_DAYS);
    let last30_cutoff = now - Duration::days(30);
    let hour_cutoff = now - Duration::hours(24);
    let start_of_today = now.date_naive();

    let mut keyed: HashMap<String, Entry> = HashMap::new();
    let mut unkeyed: Vec<Entry> = Vec::new();
    let mut any_root = false;

    for root in roots {
        if !root.is_dir() {
            continue;
        }
        any_root = true;
        let mut files: Vec<PathBuf> = WalkDir::new(root)
            .into_iter()
            .filter_map(Result::ok)
            .filter(|e| e.file_type().is_file())
            .filter(|e| e.path().extension().is_some_and(|x| x == "jsonl"))
            .filter(|e| {
                // Fast-path skip: files untouched inside the window hold no
                // usable line.
                e.metadata()
                    .ok()
                    .and_then(|m| m.modified().ok())
                    .is_some_and(|m| DateTime::<Local>::from(m) >= cutoff)
            })
            .map(|e| e.into_path())
            .collect();
        // Sorted so keep-last dedup is deterministic across runs.
        files.sort();
        for file in files {
            let Ok(content) = std::fs::read_to_string(&file) else {
                continue;
            };
            for line in content.lines() {
                if let Some(entry) = parse_line(line) {
                    match &entry.key {
                        Some(k) => {
                            keyed.insert(k.clone(), entry);
                        }
                        None => unkeyed.push(entry),
                    }
                }
            }
        }
    }
    if !any_root {
        return None;
    }

    // --- Aggregation ---------------------------------------------------
    #[derive(Default)]
    struct DayAcc {
        usd: f64,
        tokens: i64,
        models: HashMap<String, (f64, i64)>,
    }

    let mut today_usd = 0.0;
    let mut today_tokens: i64 = 0;
    let mut month_usd = 0.0;
    let mut month_tokens: i64 = 0;
    let mut buckets: HashMap<NaiveDate, DayAcc> = HashMap::new();
    let mut hour_buckets: HashMap<(NaiveDate, u32), (f64, i64)> = HashMap::new();
    let mut model_votes: HashMap<String, i64> = HashMap::new();

    for entry in keyed.into_values().chain(unkeyed) {
        // Local-midnight instant of the entry's day, for window comparisons
        // (DST-ambiguous midnights fall back to the earliest candidate).
        let Some(day_start) = entry
            .day
            .and_hms_opt(0, 0, 0)
            .and_then(|dt| dt.and_local_timezone(Local).earliest())
        else {
            continue;
        };
        if day_start < cutoff {
            continue;
        }
        let acc = buckets.entry(entry.day).or_default();
        acc.usd += entry.usd;
        acc.tokens += entry.tokens;
        let m = acc.models.entry(entry.model.clone()).or_insert((0.0, 0));
        m.0 += entry.usd;
        m.1 += entry.tokens;

        // Totals + top-model vote keep 30-day semantics even though the
        // bucket window is wider.
        if day_start >= last30_cutoff {
            *model_votes.entry(entry.model.clone()).or_insert(0) += entry.tokens;
            month_usd += entry.usd;
            month_tokens += entry.tokens;
        }
        if entry.day >= start_of_today {
            today_usd += entry.usd;
            today_tokens += entry.tokens;
        }
        if entry.ts >= hour_cutoff && entry.ts <= now {
            let h = hour_buckets
                .entry((entry.ts.date_naive(), entry.ts.hour()))
                .or_insert((0.0, 0));
            h.0 += entry.usd;
            h.1 += entry.tokens;
        }
    }

    // Contiguous HISTORY_DAYS array so the chart has a slot for every day.
    let mut daily = Vec::with_capacity(HISTORY_DAYS as usize);
    for offset in (0..HISTORY_DAYS).rev() {
        let day = start_of_today - Duration::days(offset);
        let (usd, tokens, models) = match buckets.get(&day) {
            Some(acc) => {
                let mut models: Vec<DailyModel> = acc
                    .models
                    .iter()
                    // Drop the noisy "<synthetic>" placeholder and zero-token
                    // models so the breakdown only lists real usage.
                    .filter(|(name, (_, t))| name.as_str() != "<synthetic>" && *t > 0)
                    .map(|(name, (usd, tokens))| DailyModel {
                        name: name.clone(),
                        usd: *usd,
                        tokens: *tokens,
                    })
                    .collect();
                models.sort_by(|a, b| b.tokens.cmp(&a.tokens));
                models.truncate(5);
                (acc.usd, acc.tokens, models)
            }
            None => (0.0, 0, Vec::new()),
        };
        daily.push(DailyUsage { date: day.to_string(), usd, tokens, models });
    }

    // Contiguous 24 hour buckets ending at the current clock hour.
    let mut hourly = Vec::with_capacity(24);
    for offset in (0..24).rev() {
        let t = now - Duration::hours(offset);
        let (usd, tokens) = hour_buckets
            .get(&(t.date_naive(), t.hour()))
            .copied()
            .unwrap_or((0.0, 0));
        hourly.push(HourlyUsage {
            hour: format!("{}T{:02}:00", t.date_naive(), t.hour()),
            usd,
            tokens,
        });
    }

    let top_model = model_votes
        .into_iter()
        .max_by_key(|(_, tokens)| *tokens)
        .map(|(name, _)| name);

    Some(UsageReport {
        today_usd,
        today_tokens,
        last30_usd: month_usd,
        last30_tokens: month_tokens,
        daily,
        hourly,
        top_model,
    })
}

/// Parses one jsonl line into a priced entry. None for non-usage lines,
/// Vertex AI lines (separately billed — "_vrtx_" ids or "model@version"),
/// and lines whose timestamp is missing/unparseable (cannot attribute a day).
fn parse_line(line: &str) -> Option<Entry> {
    let obj: Value = serde_json::from_str(line).ok()?;
    let message = obj.get("message")?;
    let usage = message.get("usage")?;

    let get = |key: &str| usage.get(key).and_then(Value::as_i64).unwrap_or(0);
    let input = get("input_tokens");
    let cache_creation = get("cache_creation_input_tokens");
    let cache_read = get("cache_read_input_tokens");
    let output = get("output_tokens");
    let raw_model = message
        .get("model")
        .and_then(Value::as_str)
        .unwrap_or("claude-sonnet")
        .to_string();

    let message_id = message.get("id").and_then(Value::as_str);
    let request_id = obj.get("requestId").and_then(Value::as_str);
    if message_id.is_some_and(|s| s.contains("_vrtx_"))
        || request_id.is_some_and(|s| s.contains("_vrtx_"))
        || (raw_model.starts_with("claude-") && raw_model.contains('@'))
    {
        return None;
    }

    // Anthropic's `input_tokens` is already the fresh (uncached) count, so
    // it is priced directly (no cache-read subtraction).
    let input_side_tokens = input + cache_creation + cache_read;
    let usd = match price_for(&raw_model, input_side_tokens) {
        Some(p) => {
            (input as f64 * p.input
                + cache_creation as f64 * p.cache_write
                + cache_read as f64 * p.cache_read
                + output as f64 * p.output)
                / 1_000_000.0
        }
        None => 0.0,
    };

    // Bucket by the line's own timestamp. Missing/unparseable timestamps used
    // to fall back to "now" and inflate today's totals — drop the line instead.
    let ts = obj
        .get("timestamp")
        .and_then(Value::as_str)
        .and_then(|s| DateTime::parse_from_rfc3339(s).ok())
        .map(|d| d.with_timezone(&Local))?;

    // Dedup by messageId alone — Claude Code no longer writes requestId;
    // mid is unique per API response (retries get a new id).
    let key = message_id.map(|m| m.to_string());
    Some(Entry {
        day: ts.date_naive(),
        ts,
        usd,
        // Totals INCLUDE cache tokens — they dominate Claude usage (~99%).
        tokens: input + cache_creation + cache_read + output,
        model: raw_model,
        key,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::Path;

    fn temp_base(tag: &str) -> PathBuf {
        let base = std::env::temp_dir().join(format!(
            "birdnion-test-{tag}-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&base);
        base
    }

    fn write_lines(dir: &Path, name: &str, lines: &[String]) {
        fs::create_dir_all(dir).unwrap();
        fs::write(dir.join(name), lines.join("\n")).unwrap();
    }

    fn line(ts: &str, id: &str, model: &str, input: i64, output: i64) -> String {
        format!(
            r#"{{"type":"assistant","timestamp":"{ts}","requestId":"{id}","message":{{"id":"{id}","model":"{model}","usage":{{"input_tokens":{input},"output_tokens":{output}}}}}}}"#
        )
    }

    /// Same shape as `line` but without `requestId` — matches current Claude
    /// Code JSONL schema (requestId was dropped from the log format).
    fn line_no_request_id(ts: &str, id: &str, model: &str, input: i64, output: i64) -> String {
        format!(
            r#"{{"type":"assistant","timestamp":"{ts}","message":{{"id":"{id}","model":"{model}","usage":{{"input_tokens":{input},"output_tokens":{output}}}}}}}"#
        )
    }

    #[test]
    fn dedups_same_message_across_roots() {
        let base = temp_base("dedup");
        let now = Local::now();
        let ts = now.to_rfc3339();
        let l = line(&ts, "m1", "claude-sonnet", 100, 50);
        write_lines(&base.join("a/projects/enc"), "p.jsonl", &[l.clone()]);
        write_lines(&base.join("b/projects/enc"), "p.jsonl", &[l]);

        let report = scan(
            &[base.join("a/projects"), base.join("b/projects")],
            now,
        )
        .unwrap();
        assert_eq!(report.last30_tokens, 150); // 100+50 deduped, not 300
        assert_eq!(report.today_tokens, 150);
        fs::remove_dir_all(&base).ok();
    }

    /// Multi-content-block assistant turns repeat the same usage on 3 lines
    /// with the same message.id and no requestId — must count once.
    #[test]
    fn dedups_same_message_id_without_request_id_in_one_file() {
        let base = temp_base("dedup-mid-only");
        let now = Local::now();
        let ts = now.to_rfc3339();
        let l = line_no_request_id(&ts, "m1", "claude-sonnet", 100, 50);
        write_lines(
            &base.join("projects/enc"),
            "p.jsonl",
            &[l.clone(), l.clone(), l],
        );

        let report = scan(&[base.join("projects")], now).unwrap();
        assert_eq!(report.last30_tokens, 150); // not 450
        assert_eq!(report.today_tokens, 150);
        fs::remove_dir_all(&base).ok();
    }

    /// Parent session + subagent file both log the same message.id without
    /// requestId — must count once.
    #[test]
    fn dedups_same_message_id_without_request_id_across_files() {
        let base = temp_base("dedup-mid-files");
        let now = Local::now();
        let ts = now.to_rfc3339();
        let l = line_no_request_id(&ts, "m1", "claude-sonnet", 100, 50);
        write_lines(&base.join("projects/enc"), "parent.jsonl", &[l.clone()]);
        write_lines(&base.join("projects/enc"), "agent.jsonl", &[l]);

        let report = scan(&[base.join("projects")], now).unwrap();
        assert_eq!(report.last30_tokens, 150); // not 300
        fs::remove_dir_all(&base).ok();
    }

    #[test]
    fn strict_30_day_totals_with_90_day_daily_window() {
        let base = temp_base("windows");
        let now = Local::now();
        let old = (now - Duration::days(40)).to_rfc3339();
        let recent = now.to_rfc3339();
        write_lines(
            &base.join("projects/enc"),
            "s.jsonl",
            &[
                line(&old, "m1", "claude-opus-4-8", 1_000_000, 0), // $5, outside 30d
                line(&recent, "m2", "claude-opus-4-8", 1_000_000, 0), // $5, today
            ],
        );

        let report = scan(&[base.join("projects")], now).unwrap();
        assert_eq!(report.daily.len(), HISTORY_DAYS as usize);
        assert!((report.last30_usd - 5.0).abs() < 0.001); // 40d-old entry excluded
        let daily_total: f64 = report.daily.iter().map(|d| d.usd).sum();
        assert!((daily_total - 10.0).abs() < 0.001); // but still on the history chart
        assert_eq!(report.top_model.as_deref(), Some("claude-opus-4-8"));
        fs::remove_dir_all(&base).ok();
    }

    #[test]
    fn hourly_buckets_cover_trailing_24h_only() {
        let base = temp_base("hourly");
        let now = Local::now();
        let recent = (now - Duration::hours(1)).to_rfc3339();
        let stale = (now - Duration::hours(30)).to_rfc3339();
        write_lines(
            &base.join("projects/enc"),
            "s.jsonl",
            &[
                line(&recent, "m1", "claude-sonnet", 100, 50),
                line(&stale, "m2", "claude-sonnet", 900, 0),
            ],
        );

        let report = scan(&[base.join("projects")], now).unwrap();
        assert_eq!(report.hourly.len(), 24);
        let hourly_tokens: i64 = report.hourly.iter().map(|h| h.tokens).sum();
        assert_eq!(hourly_tokens, 150); // 30h-old entry excluded
        fs::remove_dir_all(&base).ok();
    }

    #[test]
    fn vertex_lines_skipped_and_unknown_models_cost_zero() {
        let base = temp_base("filters");
        let now = Local::now();
        let ts = now.to_rfc3339();
        write_lines(
            &base.join("projects/enc"),
            "s.jsonl",
            &[
                line(&ts, "msg_vrtx_1", "claude-sonnet", 500, 0), // Vertex → skipped
                line(&ts, "m2", "minimax-m2", 100, 50),           // unknown → $0
            ],
        );

        let report = scan(&[base.join("projects")], now).unwrap();
        assert_eq!(report.last30_tokens, 150);
        assert!(report.last30_usd.abs() < f64::EPSILON);
        fs::remove_dir_all(&base).ok();
    }

    #[test]
    fn returns_none_without_any_root() {
        let missing = PathBuf::from("/nonexistent/birdnion-test-root");
        assert!(scan(&[missing], Local::now()).is_none());
    }

    /// Hapo rate card parity with macOS `hapoPrice` (prefix match + long-context).
    #[test]
    fn hapo_model_prices() {
        // openai.gpt-5.6-terra @ 100k input-side → $2.50/M → $0.25 for 100k.
        let terra = price_for("openai.gpt-5.6-terra", 100_000).unwrap();
        assert!((terra.input - 2.5).abs() < 0.001);
        assert!((terra.cache_write - 2.5).abs() < 0.001);
        assert!((terra.cache_read - 0.25).abs() < 0.001);
        assert!((terra.output - 15.0).abs() < 0.001);
        let terra_cost = 100_000.0 * terra.input / 1_000_000.0;
        assert!((terra_cost - 0.25).abs() < 0.001);

        // Long-context terra (>272k) doubles.
        let terra_long = price_for("openai.gpt-5.6-terra", 272_001).unwrap();
        assert!((terra_long.input - 5.0).abs() < 0.001);
        assert!((terra_long.output - 22.5).abs() < 0.001);

        let luna = price_for("openai.gpt-5.6-luna", 0).unwrap();
        assert!((luna.input - 1.0).abs() < 0.001);
        assert!((luna.output - 6.0).abs() < 0.001);
        let sol = price_for("openai.gpt-5.6-sol", 0).unwrap();
        assert!((sol.input - 5.0).abs() < 0.001);
        assert!((sol.output - 30.0).abs() < 0.001);
        // Prefix match without a known variant → $0 (None).
        assert!(price_for("openai.gpt-5.6-unknown", 0).is_none());
        // Not a Hapo prefix (no `openai.`).
        assert!(price_for("gpt-5.6-luna", 0).is_none());

        // MiniMax-M2.5: base 0.30/M, highspeed 0.60/M.
        let m25 = price_for("minimax.minimax-m2.5", 0).unwrap();
        assert!((m25.input - 0.30).abs() < 0.001);
        assert!((m25.cache_write - 0.375).abs() < 0.001);
        assert!((m25.cache_read - 0.03).abs() < 0.001);
        assert!((m25.output - 1.20).abs() < 0.001);
        let m25_hs = price_for("minimax.minimax-m2.5-highspeed", 0).unwrap();
        assert!((m25_hs.input - 0.60).abs() < 0.001);
        assert!((m25_hs.output - 2.40).abs() < 0.001);
        assert!(price_for("minimax-m2.5-ultra-5", 0).is_some());
    }

    /// Lines without a parseable timestamp must not fall into "today".
    #[test]
    fn drops_lines_without_parseable_timestamp() {
        let base = temp_base("bad-ts");
        let now = Local::now();
        let ts = now.to_rfc3339();
        // Valid line (150 tokens) + lines with missing / garbage timestamps.
        let good = line(&ts, "m1", "claude-sonnet", 100, 50);
        let no_ts = r#"{"type":"assistant","message":{"id":"m2","model":"claude-sonnet","usage":{"input_tokens":900,"output_tokens":0}}}"#.to_string();
        let bad_ts = r#"{"type":"assistant","timestamp":"not-a-date","message":{"id":"m3","model":"claude-sonnet","usage":{"input_tokens":800,"output_tokens":0}}}"#.to_string();
        write_lines(
            &base.join("projects/enc"),
            "s.jsonl",
            &[good, no_ts, bad_ts],
        );

        let report = scan(&[base.join("projects")], now).unwrap();
        assert_eq!(report.today_tokens, 150);
        assert_eq!(report.last30_tokens, 150);
        fs::remove_dir_all(&base).ok();
    }
}
