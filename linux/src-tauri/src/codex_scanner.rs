//! Codex CLI cost scanner — parses `~/.codex/sessions/**/rollout-*.jsonl`
//! (plus `archived_sessions`) directly instead of going through CodexBarCore
//! like the macOS app does. Per rollout file we track the active model from
//! `turn_context` events and price each `token_count` event's
//! `last_token_usage` (the turn's own delta), bucketing by the event's local
//! timestamp. Validated against the macOS app: 7-day totals agree within ~3%
//! (the vendored scanner additionally reconciles forked-session baselines,
//! which this port deliberately skips — YAGNI until numbers drift).

use chrono::{DateTime, Duration, Local, NaiveDate, Timelike};
use serde_json::Value;
use std::collections::HashMap;
use std::path::PathBuf;
use walkdir::WalkDir;

use crate::usage::{DailyModel, DailyUsage, HourlyUsage, UsageReport};

pub const HISTORY_DAYS: i64 = 90;

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

/// Session roots: `$CODEX_HOME` (or `~/.codex`) `sessions` + `archived_sessions`.
pub fn default_roots() -> Vec<PathBuf> {
    let home = std::env::var("CODEX_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".codex")
        });
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
            // Model comes from the most recent turn_context line in the file.
            let mut model = String::from("gpt-5");
            for line in content.lines() {
                let Ok(obj) = serde_json::from_str::<Value>(line) else {
                    continue;
                };
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
                        let Some(last) = p.get("info").and_then(|i| i.get("last_token_usage"))
                        else {
                            continue;
                        };
                        let get =
                            |k: &str| last.get(k).and_then(Value::as_i64).unwrap_or(0);
                        let ts = obj
                            .get("timestamp")
                            .and_then(Value::as_str)
                            .and_then(|s| DateTime::parse_from_rfc3339(s).ok())
                            .map(|d| d.with_timezone(&Local));
                        let Some(ts) = ts else { continue };
                        if ts < cutoff || ts > now {
                            continue;
                        }

                        let usd = cost_usd(
                            &model,
                            get("input_tokens"),
                            get("cached_input_tokens"),
                            get("output_tokens"),
                        );
                        let tokens = get("total_tokens");
                        if usd == 0.0 && tokens == 0 {
                            continue;
                        }

                        let day = ts.date_naive();
                        let acc = buckets.entry(day).or_default();
                        acc.usd += usd;
                        acc.tokens += tokens;
                        let m = acc.models.entry(model.clone()).or_insert((0.0, 0));
                        m.0 += usd;
                        m.1 += tokens;

                        if ts >= last30_cutoff {
                            month_usd += usd;
                            month_tokens += tokens;
                            let t = model_totals.entry(model.clone()).or_insert((0.0, 0));
                            t.0 += usd;
                            t.1 += tokens;
                        }
                        if day >= start_of_today {
                            today_usd += usd;
                            today_tokens += tokens;
                        }
                        if ts >= hour_cutoff {
                            let h = hour_buckets
                                .entry((day, ts.hour()))
                                .or_insert((0.0, 0));
                            h.0 += usd;
                            h.1 += tokens;
                        }
                    }
                    _ => {}
                }
            }
        }
    }
    if !any_root {
        return None;
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
        assert!((daily_total - 2.5).abs() < 0.001); // both on the 90d chart
        let hourly_tokens: i64 = report.hourly.iter().map(|h| h.tokens).sum();
        assert_eq!(hourly_tokens, 1_000_000); // 40d-old entry outside 24h
        fs::remove_dir_all(&base).ok();
    }

    #[test]
    fn returns_none_without_any_root() {
        let missing = PathBuf::from("/nonexistent/birdnion-codex-root");
        assert!(scan(&[missing], Local::now()).is_none());
    }
}
