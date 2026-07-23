//! Codex CLI cost scanner — parses `~/.codex/sessions/**/rollout-*.jsonl`
//! (plus `archived_sessions`) directly instead of going through CodexBarCore
//! like the macOS app does. Per rollout file we track the active model from
//! `turn_context` events and price each `token_count` event's
//! `last_token_usage` (the turn's own delta), bucketing by the event's local
//! timestamp. Validated against the macOS app: 7-day totals agree within ~3%.
//!
//! Forked/resumed sessions (`session_meta.forked_from_id`) replay the parent
//! thread's full history into the new rollout file with every replayed line
//! re-stamped to the fork moment. Left unhandled, that inflates the fork
//! day's usage by the parent's entire lifetime total (561M phantom tokens
//! observed in production, 2026-07-23). We mirror the vendored scanner's
//! fix: resolve the parent's cumulative `total_token_usage` at-or-before the
//! fork moment and subtract it from the fork file's own cumulative totals,
//! counting only the genuinely-new delta. Baselines are looked up purely
//! from data already read in this same scan (no extra file I/O), which also
//! makes multi-level fork chains resolve correctly without recursion: a
//! fork-of-a-fork's raw cumulative total already reflects its own parent's
//! full history.

use chrono::{DateTime, Duration, Local, NaiveDate, Timelike};
use serde_json::Value;
use std::collections::HashMap;
use std::path::PathBuf;
use walkdir::WalkDir;

use crate::usage::{DailyModel, DailyUsage, HourlyUsage, UsageReport};

/// Trailing daily window for charts / heatmap (macOS CombinedUsageReport 120d).
pub const HISTORY_DAYS: i64 = 120;

/// Per-token USD rates, mirroring CodexBar's built-in `CostUsagePricing`
/// table (models.dev live refresh is skipped — static table only).
/// Long-context models switch to the `above` rates when a single turn's
/// input exceeds `threshold` tokens.
struct Price {
    input: f64,
    cache_read: f64,
    output: f64,
    threshold: Option<i64>,
    input_above: f64,
    cache_read_above: f64,
    output_above: f64,
}

impl Price {
    const fn flat(input: f64, cache_read: f64, output: f64) -> Self {
        Self {
            input,
            cache_read,
            output,
            threshold: None,
            input_above: 0.0,
            cache_read_above: 0.0,
            output_above: 0.0,
        }
    }
}

fn price_for(model: &str) -> Option<Price> {
    // Strip the provider prefix and a trailing "-YYYY-MM-DD" date suffix,
    // same as CodexBar's normalizeCodexModel.
    let mut key = model.trim().strip_prefix("openai/").unwrap_or(model.trim());
    if key.len() > 11 {
        let (base, suffix) = key.split_at(key.len() - 11);
        let bytes = suffix.as_bytes();
        let dated = bytes[0] == b'-'
            && suffix[1..].chars().enumerate().all(|(i, c)| match i {
                4 | 7 => c == '-',
                _ => c.is_ascii_digit(),
            });
        if dated {
            key = base;
        }
    }
    let p = match key {
        "gpt-5" | "gpt-5-codex" | "gpt-5.1" | "gpt-5.1-codex" | "gpt-5.1-codex-max" => {
            Price::flat(1.25e-6, 1.25e-7, 1e-5)
        }
        "gpt-5-mini" | "gpt-5.1-codex-mini" => Price::flat(2.5e-7, 2.5e-8, 2e-6),
        "gpt-5-nano" => Price::flat(5e-8, 5e-9, 4e-7),
        "gpt-5-pro" => Price::flat(1.5e-5, 1.5e-5, 1.2e-4),
        "gpt-5.2" | "gpt-5.2-codex" | "gpt-5.3-codex" => Price::flat(1.75e-6, 1.75e-7, 1.4e-5),
        "gpt-5.2-pro" => Price::flat(2.1e-5, 2.1e-5, 1.68e-4),
        "gpt-5.3-codex-spark" => Price::flat(0.0, 0.0, 0.0),
        "gpt-5.4" => Price {
            input: 2.5e-6,
            cache_read: 2.5e-7,
            output: 1.5e-5,
            threshold: Some(272_000),
            input_above: 5e-6,
            cache_read_above: 5e-7,
            output_above: 2.25e-5,
        },
        "gpt-5.4-mini" => Price::flat(7.5e-7, 7.5e-8, 4.5e-6),
        "gpt-5.4-nano" => Price::flat(2e-7, 2e-8, 1.25e-6),
        "gpt-5.4-pro" | "gpt-5.5-pro" => Price::flat(3e-5, 3e-5, 1.8e-4),
        "gpt-5.5" => Price {
            input: 5e-6,
            cache_read: 5e-7,
            output: 3e-5,
            threshold: Some(272_000),
            input_above: 1e-5,
            cache_read_above: 1e-6,
            output_above: 4.5e-5,
        },
        // GPT-5.6 family (OpenAI public pricing, short/long context).
        // Sol matches gpt-5.5 rate card; Terra ~half; Luna is the fast tier.
        // Model ids in Codex logs: "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna".
        "gpt-5.6" | "gpt-5.6-sol" => Price {
            input: 5e-6,
            cache_read: 5e-7,
            output: 3e-5,
            threshold: Some(272_000),
            input_above: 1e-5,
            cache_read_above: 1e-6,
            output_above: 4.5e-5,
        },
        "gpt-5.6-terra" => Price {
            input: 2.5e-6,
            cache_read: 2.5e-7,
            output: 1.5e-5,
            threshold: Some(272_000),
            input_above: 5e-6,
            cache_read_above: 5e-7,
            output_above: 2.25e-5,
        },
        "gpt-5.6-luna" => Price {
            input: 1e-6,
            cache_read: 1e-7,
            output: 6e-6,
            threshold: Some(272_000),
            input_above: 2e-6,
            cache_read_above: 2e-7,
            output_above: 9e-6,
        },
        _ => return None,
    };
    Some(p)
}

/// CodexBar's cost formula: cached reads are clamped to the input count,
/// the remainder is fresh input; long-context rates kick in when the turn's
/// input exceeds the model threshold.
fn cost_usd(model: &str, input: i64, cached: i64, output: i64) -> f64 {
    let Some(p) = price_for(model) else { return 0.0 };
    let cached = cached.clamp(0, input.max(0));
    let non_cached = (input - cached).max(0);
    let above = p.threshold.is_some_and(|t| input.max(0) > t);
    let (ir, cr, or) = if above {
        (p.input_above, p.cache_read_above, p.output_above)
    } else {
        (p.input, p.cache_read, p.output)
    };
    non_cached as f64 * ir + cached as f64 * cr + output.max(0) as f64 * or
}

/// A `token_count` event's input/cached/output/total fields, read from
/// either `last_token_usage` (a turn's own delta) or `total_token_usage`
/// (the session's running cumulative counter) — same shape, different
/// semantics depending on which JSON object it was read from.
#[derive(Clone, Copy, Default)]
struct CodexTotals {
    input: i64,
    cached: i64,
    output: i64,
    total: i64,
}

impl CodexTotals {
    fn from_value(v: &Value) -> Self {
        let get = |k: &str| v.get(k).and_then(Value::as_i64).unwrap_or(0);
        Self {
            input: get("input_tokens"),
            cached: get("cached_input_tokens"),
            output: get("output_tokens"),
            total: get("total_tokens"),
        }
    }

    /// Component-wise `self - baseline`, clamped to zero per field so a
    /// stale/short baseline never produces a negative count.
    fn saturating_sub(&self, baseline: &CodexTotals) -> CodexTotals {
        CodexTotals {
            input: (self.input - baseline.input).max(0),
            cached: (self.cached - baseline.cached).max(0),
            output: (self.output - baseline.output).max(0),
            total: (self.total - baseline.total).max(0),
        }
    }
}

/// One `token_count` event as read from a rollout file: the model active at
/// that point, the turn's own delta (`last`), and the session's cumulative
/// counter at that point (`total`, when the line carries `total_token_usage`
/// — real Codex CLI output always does, but older/malformed lines might not).
struct CodexTokenEvent {
    ts: DateTime<Local>,
    model: String,
    last: CodexTotals,
    total: Option<CodexTotals>,
}

/// One rollout file's parsed identity + event stream. `session_id` is this
/// file's own identity (see `parse_codex_session_meta` for why `id` must be
/// checked before the `session_id` JSON key); `forked_from_id`/`fork_ts`
/// are populated only when this file is a fork/resume of another session.
#[derive(Default)]
struct CodexFileScan {
    session_id: Option<String>,
    forked_from_id: Option<String>,
    fork_ts: Option<DateTime<Local>>,
    events: Vec<CodexTokenEvent>,
}

/// Extracts a `session_meta` line's own identity, fork parent, and
/// timestamp. Returns `None` for any other line type.
///
/// `id` must be checked BEFORE `session_id`/`sessionId`: for a normal or
/// forked top-level session the two match, but a spawned-subagent thread's
/// `session_meta` carries the ROOT conversation's id in `session_id` while
/// `id` holds the subagent's own identity. Preferring `session_id` would
/// collapse every subagent belonging to the same root onto one index key,
/// corrupting the fork-baseline lookup below (it would resolve to a random
/// subagent transcript instead of the true parent).
fn parse_codex_session_meta(obj: &Value) -> Option<(Option<String>, Option<String>, Option<String>)> {
    if obj.get("type").and_then(Value::as_str) != Some("session_meta") {
        return None;
    }
    let payload = obj.get("payload")?;
    let field = |v: &Value, keys: &[&str]| -> Option<String> {
        keys.iter().find_map(|k| v.get(*k).and_then(Value::as_str)).map(String::from)
    };
    let id = field(payload, &["id", "session_id", "sessionId"]);
    let forked_from_id = field(payload, &["forked_from_id", "forkedFromId"]);
    let timestamp = field(payload, &["timestamp"]).or_else(|| field(obj, &["timestamp"]));
    Some((id, forked_from_id, timestamp))
}

/// This file's direct parent's cumulative totals at-or-before the fork
/// moment — the baseline to subtract from the fork file's own cumulative
/// counter. `None` when the parent wasn't among the files scanned this run
/// (e.g. outside the history window); callers fall back to per-turn deltas
/// in that case, same as an unforked file.
fn resolve_codex_fork_baseline(
    scans: &[CodexFileScan],
    id_index: &HashMap<String, usize>,
    parent_id: &str,
    fork_ts: DateTime<Local>,
) -> Option<CodexTotals> {
    let parent = &scans[*id_index.get(parent_id)?];
    let mut baseline = None;
    for ev in &parent.events {
        if ev.ts > fork_ts {
            break;
        }
        if let Some(total) = ev.total {
            baseline = Some(total);
        }
    }
    baseline
}

/// Session roots under the active Codex account's home (system `~/.codex`/
/// `$CODEX_HOME`, or a managed account's private home) — so cost tracking
/// follows account switches the same way the quota provider does. Managed
/// account homes don't have session logs (only `auth.json` is copied), so
/// this naturally falls back to an empty/no-op scan for those; the system
/// account keeps working exactly as before.
pub fn default_roots() -> Vec<PathBuf> {
    let home = crate::codex_accounts::active_auth_path()
        .parent()
        .map(std::path::Path::to_path_buf)
        .unwrap_or_else(|| PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".codex"));
    vec![home.join("sessions"), home.join("archived_sessions")]
}

pub fn usage_report() -> Option<UsageReport> {
    scan(&default_roots(), Local::now())
}

/// Returns None only when no sessions root is readable.
pub fn scan(roots: &[PathBuf], now: DateTime<Local>) -> Option<UsageReport> {
    let cutoff = now - Duration::days(HISTORY_DAYS);
    let last30_cutoff = now - Duration::days(30);
    let hour_cutoff = now - Duration::hours(24);
    let start_of_today = now.date_naive();

    #[derive(Default)]
    struct DayAcc {
        usd: f64,
        tokens: i64,
        models: HashMap<String, (f64, i64)>,
    }

    let mut any_root = false;
    let mut buckets: HashMap<NaiveDate, DayAcc> = HashMap::new();
    let mut hour_buckets: HashMap<(NaiveDate, u32), (f64, i64)> = HashMap::new();
    // Top model over the trailing 30 days, by summed cost (CodexBar parity).
    let mut model_totals: HashMap<String, (f64, i64)> = HashMap::new();
    let mut today_usd = 0.0;
    let mut today_tokens: i64 = 0;
    let mut month_usd = 0.0;
    let mut month_tokens: i64 = 0;

    // Pass 1: read every file once, capturing its identity/fork lineage and
    // full event stream (not yet bucketed — a forked file's events need its
    // parent's baseline resolved first, and that parent may be discovered
    // later in this same loop).
    let mut scans: Vec<CodexFileScan> = Vec::new();
    let mut id_index: HashMap<String, usize> = HashMap::new();

    for root in roots {
        if !root.is_dir() {
            continue;
        }
        any_root = true;
        let files = WalkDir::new(root)
            .into_iter()
            .filter_map(Result::ok)
            .filter(|e| e.file_type().is_file())
            .filter(|e| {
                e.path()
                    .file_name()
                    .and_then(|n| n.to_str())
                    .is_some_and(|n| n.starts_with("rollout-") && n.ends_with(".jsonl"))
            })
            .filter(|e| {
                e.metadata()
                    .ok()
                    .and_then(|m| m.modified().ok())
                    .is_some_and(|m| DateTime::<Local>::from(m) >= cutoff)
            })
            .map(|e| e.into_path());

        for file in files {
            let Ok(content) = std::fs::read_to_string(&file) else {
                continue;
            };
            let mut file_scan = CodexFileScan::default();
            // Model comes from the most recent turn_context line in the file.
            let mut model = String::from("gpt-5");
            for line in content.lines() {
                let Ok(obj) = serde_json::from_str::<Value>(line) else {
                    continue;
                };
                if let Some((id, forked_from_id, ts_str)) = parse_codex_session_meta(&obj) {
                    if file_scan.session_id.is_none() {
                        file_scan.session_id = id;
                    }
                    if file_scan.forked_from_id.is_none() && forked_from_id.is_some() {
                        file_scan.forked_from_id = forked_from_id;
                        file_scan.fork_ts = ts_str
                            .as_deref()
                            .and_then(|s| DateTime::parse_from_rfc3339(s).ok())
                            .map(|d| d.with_timezone(&Local));
                    }
                    continue;
                }
                let payload = obj.get("payload");
                match obj.get("type").and_then(Value::as_str) {
                    Some("turn_context") => {
                        if let Some(m) = payload
                            .and_then(|p| p.get("model"))
                            .and_then(Value::as_str)
                        {
                            model = m.to_string();
                        }
                    }
                    Some("event_msg") => {
                        let Some(p) = payload else { continue };
                        if p.get("type").and_then(Value::as_str) != Some("token_count") {
                            continue;
                        }
                        let Some(info) = p.get("info") else { continue };
                        let Some(last) = info.get("last_token_usage") else { continue };
                        let ts = obj
                            .get("timestamp")
                            .and_then(Value::as_str)
                            .and_then(|s| DateTime::parse_from_rfc3339(s).ok())
                            .map(|d| d.with_timezone(&Local));
                        let Some(ts) = ts else { continue };
                        file_scan.events.push(CodexTokenEvent {
                            ts,
                            model: model.clone(),
                            last: CodexTotals::from_value(last),
                            total: info.get("total_token_usage").map(CodexTotals::from_value),
                        });
                    }
                    _ => {}
                }
            }
            if let Some(id) = file_scan.session_id.clone() {
                id_index.entry(id).or_insert(scans.len());
            }
            scans.push(file_scan);
        }
    }
    if !any_root {
        return None;
    }

    // Pass 2: bucket each file's events, subtracting a resolved fork
    // baseline from cumulative totals where applicable (see module docs).
    for scan_index in 0..scans.len() {
        let baseline = scans[scan_index]
            .forked_from_id
            .as_deref()
            .zip(scans[scan_index].fork_ts)
            .and_then(|(parent_id, fork_ts)| {
                resolve_codex_fork_baseline(&scans, &id_index, parent_id, fork_ts)
            });

        let mut previous_adjusted = CodexTotals::default();
        for ev in &scans[scan_index].events {
            // Unresolved baseline (parent outside the scan window, or no
            // fork at all) falls back to the turn's own delta — identical
            // to this file's pre-fork-handling behavior.
            let counted = match (baseline, ev.total) {
                (Some(base), Some(total)) => {
                    let adjusted = total.saturating_sub(&base);
                    let delta = adjusted.saturating_sub(&previous_adjusted);
                    previous_adjusted = adjusted;
                    delta
                }
                _ => ev.last,
            };

            if ev.ts < cutoff || ev.ts > now {
                continue;
            }
            let usd = cost_usd(&ev.model, counted.input, counted.cached, counted.output);
            let tokens = counted.total;
            if usd == 0.0 && tokens == 0 {
                continue;
            }

            let day = ev.ts.date_naive();
            let acc = buckets.entry(day).or_default();
            acc.usd += usd;
            acc.tokens += tokens;
            let m = acc.models.entry(ev.model.clone()).or_insert((0.0, 0));
            m.0 += usd;
            m.1 += tokens;

            if ev.ts >= last30_cutoff {
                month_usd += usd;
                month_tokens += tokens;
                let t = model_totals.entry(ev.model.clone()).or_insert((0.0, 0));
                t.0 += usd;
                t.1 += tokens;
            }
            if day >= start_of_today {
                today_usd += usd;
                today_tokens += tokens;
            }
            if ev.ts >= hour_cutoff {
                let h = hour_buckets.entry((day, ev.ts.hour())).or_insert((0.0, 0));
                h.0 += usd;
                h.1 += tokens;
            }
        }
    }

    let mut daily = Vec::with_capacity(HISTORY_DAYS as usize);
    for offset in (0..HISTORY_DAYS).rev() {
        let day = start_of_today - Duration::days(offset);
        let (usd, tokens, models) = match buckets.get(&day) {
            Some(acc) => {
                let mut models: Vec<DailyModel> = acc
                    .models
                    .iter()
                    .filter(|(_, (usd, tokens))| *usd > 0.0 || *tokens > 0)
                    .map(|(name, (usd, tokens))| DailyModel {
                        name: name.clone(),
                        usd: *usd,
                        tokens: *tokens,
                    })
                    .collect();
                // Sorted by cost (CodexBar's day detail), top 5.
                models.sort_by(|a, b| b.usd.total_cmp(&a.usd));
                models.truncate(5);
                (acc.usd, acc.tokens, models)
            }
            None => (0.0, 0, Vec::new()),
        };
        daily.push(DailyUsage { date: day.to_string(), usd, tokens, models });
    }

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

    let top_model = model_totals
        .into_iter()
        .max_by(|a, b| {
            a.1 .0
                .total_cmp(&b.1 .0)
                .then_with(|| a.1 .1.cmp(&b.1 .1))
        })
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::Path;

    fn temp_base(tag: &str) -> PathBuf {
        let base = std::env::temp_dir().join(format!(
            "birdnion-codex-test-{tag}-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&base);
        base
    }

    fn write_lines(dir: &Path, name: &str, lines: &[String]) {
        fs::create_dir_all(dir).unwrap();
        fs::write(dir.join(name), lines.join("\n")).unwrap();
    }

    fn turn_context(model: &str) -> String {
        format!(r#"{{"timestamp":"2026-01-01T00:00:00Z","type":"turn_context","payload":{{"model":"{model}"}}}}"#)
    }

    fn token_count(ts: &str, input: i64, cached: i64, output: i64, total: i64) -> String {
        format!(
            r#"{{"timestamp":"{ts}","type":"event_msg","payload":{{"type":"token_count","info":{{"total_token_usage":{{"total_tokens":0}},"last_token_usage":{{"input_tokens":{input},"cached_input_tokens":{cached},"output_tokens":{output},"total_tokens":{total}}}}}}}}}"#
        )
    }

    fn session_meta(ts: &str, id: &str, forked_from_id: Option<&str>) -> String {
        let fork_field = forked_from_id
            .map(|p| format!(r#","forked_from_id":"{p}""#))
            .unwrap_or_default();
        format!(
            r#"{{"timestamp":"{ts}","type":"session_meta","payload":{{"id":"{id}","timestamp":"{ts}"{fork_field}}}}}"#
        )
    }

    /// Like `token_count`, but with an explicit cumulative `total_token_usage`
    /// (needed to exercise fork-baseline resolution, which only looks at
    /// the cumulative counter, not `last_token_usage`).
    fn token_count_cumulative(
        ts: &str,
        last: (i64, i64, i64, i64),
        total: (i64, i64, i64, i64),
    ) -> String {
        format!(
            r#"{{"timestamp":"{ts}","type":"event_msg","payload":{{"type":"token_count","info":{{"total_token_usage":{{"input_tokens":{ti},"cached_input_tokens":{tc},"output_tokens":{to},"total_tokens":{tt}}},"last_token_usage":{{"input_tokens":{li},"cached_input_tokens":{lc},"output_tokens":{lo},"total_tokens":{lt}}}}}}}}}"#,
            li = last.0, lc = last.1, lo = last.2, lt = last.3,
            ti = total.0, tc = total.1, to = total.2, tt = total.3,
        )
    }

    #[test]
    fn prices_turns_with_the_active_model() {
        let base = temp_base("pricing");
        let now = Local::now();
        let ts = now.to_rfc3339();
        write_lines(
            &base.join("sessions/2026/01/01"),
            "rollout-a.jsonl",
            &[
                turn_context("gpt-5.5"),
                // 200K fresh input, below the 272K threshold → base rate
                // $5e-6/token = $1.00.
                token_count(&ts, 200_000, 0, 0, 200_000),
            ],
        );

        let report = scan(&[base.join("sessions")], now).unwrap();
        assert!((report.today_usd - 1.0).abs() < 0.001);
        assert_eq!(report.today_tokens, 200_000);
        assert_eq!(report.top_model.as_deref(), Some("gpt-5.5"));
        fs::remove_dir_all(&base).ok();
    }

    #[test]
    fn cached_tokens_use_cache_read_rate_and_threshold_switches_rates() {
        // 100K cached on gpt-5.5, below threshold: 100K × $5e-7 = $0.05.
        let below = cost_usd("gpt-5.5", 100_000, 100_000, 0);
        assert!((below - 0.05).abs() < 1e-9);
        // 300K input crosses the 272K threshold → above rates ($1e-5/fresh).
        let above = cost_usd("gpt-5.5", 300_000, 0, 0);
        assert!((above - 3.0).abs() < 1e-9);
        // Dated + prefixed model names normalize to the base entry.
        assert!(cost_usd("openai/gpt-5.5-2026-01-01", 1_000, 0, 0) > 0.0);
        // gpt-5.6-sol was missing from the table → $0 despite real tokens.
        // Use 100K (below 272K threshold) so short-context rates apply.
        assert!((cost_usd("gpt-5.6-sol", 100_000, 0, 0) - 0.5).abs() < 1e-9);
        assert!((cost_usd("gpt-5.6-terra", 100_000, 0, 0) - 0.25).abs() < 1e-9);
        assert!((cost_usd("gpt-5.6-luna", 100_000, 0, 0) - 0.1).abs() < 1e-9);
        assert!(cost_usd("gpt-5.6-sol", 1_000_000, 0, 0) > 0.0);
        // Unknown models cost $0.
        assert_eq!(cost_usd("mystery-model", 1_000_000, 0, 0), 0.0);
    }

    #[test]
    fn strict_30_day_totals_with_90_day_daily_window() {
        let base = temp_base("windows");
        let now = Local::now();
        let old = (now - Duration::days(40)).to_rfc3339();
        let recent = now.to_rfc3339();
        write_lines(
            &base.join("sessions/2026/01/01"),
            "rollout-a.jsonl",
            &[
                turn_context("gpt-5"),
                token_count(&old, 1_000_000, 0, 0, 1_000_000),    // $1.25, outside 30d
                token_count(&recent, 1_000_000, 0, 0, 1_000_000), // $1.25, today
            ],
        );

        let report = scan(&[base.join("sessions")], now).unwrap();
        assert_eq!(report.daily.len(), HISTORY_DAYS as usize);
        assert!((report.last30_usd - 1.25).abs() < 0.001);
        let daily_total: f64 = report.daily.iter().map(|d| d.usd).sum();
        assert!((daily_total - 2.5).abs() < 0.001); // both on the history chart
        let hourly_tokens: i64 = report.hourly.iter().map(|h| h.tokens).sum();
        assert_eq!(hourly_tokens, 1_000_000); // 40d-old entry outside 24h
        fs::remove_dir_all(&base).ok();
    }

    #[test]
    fn returns_none_without_any_root() {
        let missing = PathBuf::from("/nonexistent/birdnion-codex-root");
        assert!(scan(&[missing], Local::now()).is_none());
    }

    /// Regression for the 561M-phantom-token bug (2026-07-23): forking/
    /// resuming an old thread replays the parent's entire history into the
    /// new rollout file, all re-stamped to the fork moment. Without
    /// baseline subtraction this counts the parent's full lifetime total
    /// as new usage on the fork day. With it, only genuinely-new turns
    /// after the fork should be counted.
    #[test]
    fn fork_baseline_excludes_replayed_parent_history() {
        let base = temp_base("fork");
        let now = Local::now();
        let fork_ts = now.to_rfc3339();

        // Parent session: one real turn totalling 1M tokens ($1.25 on gpt-5).
        write_lines(
            &base.join("sessions/2026/01/01"),
            "rollout-parent.jsonl",
            &[
                session_meta(&fork_ts, "parent-id", None),
                turn_context("gpt-5"),
                token_count_cumulative(
                    &fork_ts,
                    (1_000_000, 0, 0, 1_000_000),
                    (1_000_000, 0, 0, 1_000_000),
                ),
            ],
        );

        // Fork: replays the parent's turn (cumulative total unchanged —
        // same 1M) then adds exactly one genuinely-new turn of 50K tokens
        // (cumulative total 1,050,000). Only the 50K delta should be priced.
        write_lines(
            &base.join("sessions/2026/01/01"),
            "rollout-fork.jsonl",
            &[
                session_meta(&fork_ts, "fork-id", Some("parent-id")),
                turn_context("gpt-5"),
                token_count_cumulative(
                    &fork_ts,
                    (1_000_000, 0, 0, 1_000_000), // replayed line
                    (1_000_000, 0, 0, 1_000_000),
                ),
                token_count_cumulative(
                    &fork_ts,
                    (50_000, 0, 0, 50_000), // genuinely new turn
                    (1_050_000, 0, 0, 1_050_000),
                ),
            ],
        );

        let report = scan(&[base.join("sessions")], now).unwrap();
        // Parent's 1M ($1.25) + fork's real 50K delta ($0.0625) = $1.3125.
        // Without the fix this would double the parent's total again via
        // the fork's replayed line: $1.25 (parent) + $1.25 (bogus replay)
        // + $0.0625 (real) = $2.5625.
        assert!(
            (report.last30_usd - 1.3125).abs() < 0.001,
            "expected fork replay to be excluded, got {}",
            report.last30_usd
        );
        assert_eq!(report.last30_tokens, 1_050_000);
        fs::remove_dir_all(&base).ok();
    }
}
