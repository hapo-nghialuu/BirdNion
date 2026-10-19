//! Local agent cost engine — port of macOS `LocalAgentCostEngine`: a
//! registry of session-log readers for sources that have no dedicated
//! scanner (Devin, OpenCode, Gemini CLI, Copilot CLI, Antigravity, Cursor,
//! Amp, Droid, Kimi, Qwen Code, Goose). Turns are deduped, bucketed per
//! day, and merged into the shared cost-history store with the same
//! revision/scan-back semantics as the typed scanners.

pub mod generic;
pub mod parsing;
pub mod pricing;
pub mod readers;

use chrono::{DateTime, Duration, Local};
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

use crate::cost_history;
use crate::usage::{DailyModel, DailyUsage, HourlyUsage, UsageReport};

/// One usage-bearing turn extracted from an agent's logs.
pub struct LocalTurnRecord {
    pub date: DateTime<Local>,
    pub model: String,
    pub tokens: i64,
    pub usd: f64,
    /// Stable key for dedup across files that replay the same turn
    /// (forked sessions, overlapping exports).
    pub dedupe_key: String,
}

/// A finished read pass over a source's roots.
pub struct ScanOutcome {
    pub turns: Vec<LocalTurnRecord>,
    /// False when a read/parse failure or a cap means the scan saw only part
    /// of the data — merged but never counted as a completed deep pass.
    pub completed: bool,
}

impl ScanOutcome {
    pub fn complete(turns: Vec<LocalTurnRecord>) -> Self {
        Self {
            turns,
            completed: true,
        }
    }
}

/// Registered reader for one local cost source.
pub struct LocalCostSource {
    /// Bump when the counting semantics change — older stored data is
    /// replaced wholesale on the next scan.
    pub counting_revision: i64,
    /// Candidate roots that actually exist on this machine.
    pub roots: fn() -> Vec<PathBuf>,
    /// Reads all usage turns newer than cutoff under the resolved roots.
    pub read_turns: fn(&[PathBuf], DateTime<Local>) -> ScanOutcome,
}

/// Extra sources served by this engine (the six typed scanners own claude,
/// codex, grok, omp, pi, kiro). Order matches macOS registry order.
pub const EXTRA_SOURCES: [&str; 11] = [
    "devin",
    "opencode",
    "gemini",
    "copilot",
    "antigravity",
    "cursor",
    "amp",
    "droid",
    "kimi",
    "qwen",
    "goose",
];

pub fn descriptor(source: &str) -> Option<LocalCostSource> {
    match source {
        "devin" => Some(readers::devin::descriptor()),
        "opencode" => Some(readers::opencode::descriptor()),
        "gemini" => Some(readers::gemini::descriptor()),
        "copilot" => Some(readers::copilot::descriptor()),
        "antigravity" => Some(readers::antigravity::descriptor()),
        "cursor" => Some(readers::cursor::descriptor()),
        "amp" => Some(readers::amp::descriptor()),
        "droid" => Some(readers::droid::descriptor()),
        "kimi" => Some(readers::kimi::descriptor()),
        "qwen" => Some(readers::qwen::descriptor()),
        "goose" => Some(readers::goose::descriptor()),
        _ => None,
    }
}

/// &'static id for cache keying — the frontend passes a String but the cache
/// is keyed on 'static str like the typed scanners.
pub fn canonical_id(source: &str) -> Option<&'static str> {
    EXTRA_SOURCES.iter().copied().find(|id| *id == source)
}

/// Per-model rows are bounded like the store validator allows.
const MAX_MODELS_PER_DAY: usize = 32;

/// Turns → live UsageReport: dedupe by key, per-day totals + model split,
/// trailing-24h hourly buckets, strict 30-day totals.
fn report_from_turns(turns: &[LocalTurnRecord], now: DateTime<Local>) -> UsageReport {
    let mut seen: HashSet<&str> = HashSet::new();
    let mut by_day: HashMap<String, (f64, i64, HashMap<String, (f64, i64)>)> = HashMap::new();
    let mut by_hour: HashMap<String, (f64, i64)> = HashMap::new();
    let today = now.date_naive();
    for turn in turns {
        if !turn.usd.is_finite() || turn.usd < 0.0 || turn.tokens < 0 {
            continue;
        }
        if !seen.insert(turn.dedupe_key.as_str()) {
            continue;
        }
        let day_key = turn.date.format("%Y-%m-%d").to_string();
        let bucket = by_day.entry(day_key).or_default();
        bucket.0 += turn.usd;
        bucket.1 += turn.tokens;
        let model = bucket.2.entry(turn.model.clone()).or_default();
        model.0 += turn.usd;
        model.1 += turn.tokens;
        let hour_key = turn.date.format("%Y-%m-%dT%H:00").to_string();
        let hour = by_hour.entry(hour_key).or_default();
        hour.0 += turn.usd;
        hour.1 += turn.tokens;
    }

    let mut daily: Vec<DailyUsage> = by_day
        .into_iter()
        .map(|(date, (usd, tokens, models))| {
            let mut rows: Vec<DailyModel> = models
                .into_iter()
                .map(|(name, (usd, tokens))| DailyModel { name, usd, tokens })
                .collect();
            rows.sort_by(|a, b| b.tokens.cmp(&a.tokens).then_with(|| a.name.cmp(&b.name)));
            rows.truncate(MAX_MODELS_PER_DAY);
            DailyUsage {
                date,
                usd,
                tokens,
                models: rows,
            }
        })
        .collect();
    daily.sort_by(|a, b| a.date.cmp(&b.date));

    let mut hourly: Vec<HourlyUsage> = by_hour
        .into_iter()
        .map(|(hour, (usd, tokens))| HourlyUsage { hour, usd, tokens })
        .collect();
    hourly.sort_by(|a, b| a.hour.cmp(&b.hour));

    let last30_start = today - Duration::days(29);
    let mut last30_usd = 0.0;
    let mut last30_tokens = 0i64;
    let mut model_totals: HashMap<&str, i64> = HashMap::new();
    let mut today_usd = 0.0;
    let mut today_tokens = 0i64;
    for day in &daily {
        let Ok(date) = chrono::NaiveDate::parse_from_str(&day.date, "%Y-%m-%d") else {
            continue;
        };
        if date == today {
            today_usd = day.usd;
            today_tokens = day.tokens;
        }
        if date >= last30_start {
            last30_usd += day.usd;
            last30_tokens += day.tokens;
            for model in &day.models {
                *model_totals.entry(model.name.as_str()).or_default() += model.tokens;
            }
        }
    }
    let top_model = model_totals
        .into_iter()
        .max_by(|(a_name, a), (b_name, b)| a.cmp(b).then_with(|| b_name.cmp(a_name)))
        .map(|(name, _)| name.to_string());

    UsageReport {
        today_usd,
        today_tokens,
        last30_usd,
        last30_tokens,
        daily,
        hourly,
        top_model,
        ..Default::default()
    }
}

/// Full pipeline for one registered source — mirrors macOS loadReport:
/// roots → stored-revision plan → scan-back window → read turns → merge
/// into cost-history (replace on revision bump) → deep-scan ack.
pub fn load_report(source: &str) -> Option<UsageReport> {
    let descriptor = descriptor(source)?;
    let roots = (descriptor.roots)();
    if roots.is_empty() {
        return Some(cost_history::apply_and_report(source, None));
    }
    let stored_revision = cost_history::counting_revision(source);
    if stored_revision > descriptor.counting_revision {
        // History newer than what this build counts: serve stored data only.
        return Some(cost_history::report(source));
    }
    let plan = cost_history::scan_back_plan(source);
    let replacing = stored_revision < descriptor.counting_revision;
    let scan_days = if replacing {
        cost_history::WINDOW_DAYS
    } else {
        plan.days
    };
    let now = Local::now();
    let cutoff = (now - Duration::days(scan_days))
        .date_naive()
        .and_hms_opt(0, 0, 0)
        .map(|t| t.and_local_timezone(Local).earliest().unwrap_or(now))
        .unwrap_or(now);

    let outcome = (descriptor.read_turns)(&roots, cutoff);
    let live = report_from_turns(&outcome.turns, now);
    let merged = cost_history::apply_and_report_at_counting_revision(
        source,
        Some(&live),
        descriptor.counting_revision,
    );
    // A partial pass merges what it saw but must not consume the deep slot —
    // the next refresh still owes a full look-back.
    if plan.is_deep && merged.live && outcome.completed {
        cost_history::mark_deep_scan_succeeded(source);
    }
    Some(merged)
}

#[cfg(test)]
mod tests {
    use super::generic::{self, DEFAULT_SPEC};
    use super::*;
    use chrono::TimeZone;
    use serde_json::json;

    fn turn(key: &str, day: &str, model: &str, tokens: i64, usd: f64) -> LocalTurnRecord {
        LocalTurnRecord {
            date: Local
                .datetime_from_str(&format!("{} 12:00", day), "%Y-%m-%d %H:%M")
                .unwrap(),
            model: model.to_string(),
            tokens,
            usd,
            dedupe_key: key.to_string(),
        }
    }

    #[test]
    fn report_dedupes_turns_and_buckets_per_day() {
        let now = Local.with_ymd_and_hms(2026, 10, 19, 12, 0, 0).unwrap();
        let turns = vec![
            turn("a:1", "2026-10-19", "claude-opus", 100, 1.0),
            turn("a:1", "2026-10-19", "claude-opus", 100, 1.0), // replayed turn
            turn("a:2", "2026-10-18", "claude-opus", 50, 0.5),
        ];
        let report = report_from_turns(&turns, now);
        assert_eq!(report.daily.len(), 2);
        assert_eq!(report.today_tokens, 100);
        assert_eq!(report.today_usd, 1.0);
        assert_eq!(report.daily[0].date, "2026-10-18");
        assert_eq!(report.last30_tokens, 150);
        assert_eq!(report.top_model.as_deref(), Some("claude-opus"));
    }

    #[test]
    fn generic_walker_classifies_usage_dicts() {
        let record = json!({
            "model": "claude-sonnet-4",
            "timestamp": "2026-10-19T10:00:00Z",
            "usage": {
                "prompt_tokens": 1000,
                "cached_tokens": 200,
                "cache_creation_tokens": 50,
                "completion_tokens": 300,
                "total": 1350,
                "cost": 99.0
            }
        });
        let cutoff = Local.with_ymd_and_hms(2026, 10, 1, 0, 0, 0).unwrap();
        let turns = generic::turns_in_object(&record, &DEFAULT_SPEC, cutoff, "t");
        assert_eq!(turns.len(), 1);
        let turn = &turns[0];
        assert_eq!(turn.tokens, 1350);
        assert_eq!(turn.model, "claude-sonnet-4");
        // prompt-style input already includes cached tokens: priced as
        // (1000-200+50) input + 200 cache-read + 300 output.
        let expected = {
            let p = pricing::ClaudeModelPrice::price_for("claude-sonnet-4", 850).unwrap();
            (850.0 * p.input_per_m + 200.0 * p.cache_read_per_m + 300.0 * p.output_per_m)
                / 1_000_000.0
        };
        assert!(
            (turn.usd - expected).abs() < 1e-9,
            "{} vs {}",
            turn.usd,
            expected
        );
    }

    #[test]
    fn generic_walker_drops_records_without_timestamp() {
        let record = json!({ "usage": { "input": 10, "output": 5 } });
        let cutoff = Local.with_ymd_and_hms(2026, 10, 1, 0, 0, 0).unwrap();
        assert!(generic::turns_in_object(&record, &DEFAULT_SPEC, cutoff, "t").is_empty());
    }
}
