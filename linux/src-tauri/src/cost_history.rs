//! Persisted per-day cost history — port of macOS `CostHistoryStore`.
//!
//! File: sibling of settings.json → `cost-history.json`.
//! Merge rule: never-shrink (prefer higher tokens, then usd).

use chrono::Local;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;

use crate::config;
use crate::usage::{DailyModel, DailyUsage, UsageReport};

pub const RETAIN_DAYS: i64 = 400;
pub const WINDOW_DAYS: i64 = 90;

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct HistoryModel {
    pub name: String,
    pub usd: f64,
    pub tokens: i64,
}

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct HistoryDay {
    pub usd: f64,
    pub tokens: i64,
    #[serde(default)]
    pub models: Vec<HistoryModel>,
}

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct Document {
    #[serde(default)]
    pub version: u32,
    /// source → "YYYY-MM-DD" → day
    #[serde(default)]
    pub sources: HashMap<String, HashMap<String, HistoryDay>>,
    /// source → epoch millis of the most recent successful live scan
    /// (Data Confidence Pass). Missing entries (older documents, or a
    /// source that never had a live scan) read back as `None`.
    #[serde(default)]
    pub scanned_at: HashMap<String, i64>,
}

pub fn history_path() -> PathBuf {
    config::config_path()
        .parent()
        .map(|p| p.join("cost-history.json"))
        .unwrap_or_else(|| PathBuf::from("cost-history.json"))
}

pub fn read() -> Document {
    let path = history_path();
    std::fs::read_to_string(path)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

pub fn write(doc: &Document) -> Result<(), String> {
    let path = history_path();
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    let mut out = doc.clone();
    out.version = 1;
    let json = serde_json::to_string_pretty(&out).map_err(|e| e.to_string())?;
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, json).map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600));
    }
    std::fs::rename(&tmp, &path).map_err(|e| e.to_string())
}

pub fn prefer_higher(a: &HistoryDay, b: &HistoryDay) -> HistoryDay {
    if b.tokens > a.tokens {
        return b.clone();
    }
    if b.tokens < a.tokens {
        return a.clone();
    }
    if b.usd > a.usd {
        return b.clone();
    }
    if b.usd < a.usd {
        return a.clone();
    }
    if b.models.len() >= a.models.len() {
        b.clone()
    } else {
        a.clone()
    }
}

/// Serializes the read-modify-write below — the usage-report commands now run
/// concurrently on blocking threads, and an unguarded interleave would let one
/// source's merge overwrite another's just-written days.
static HISTORY_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// Merge live daily buckets for `source`, persist, return 90-day window as UsageReport.
pub fn apply_and_report(source: &str, live: Option<&UsageReport>) -> UsageReport {
    let _guard = HISTORY_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let now = Local::now();
    let today = now.date_naive();
    let mut doc = read();
    {
        let by_day = doc.sources.entry(source.to_string()).or_default();

        if let Some(live) = live {
            for d in &live.daily {
                if d.tokens <= 0 && d.usd <= 0.0 {
                    continue;
                }
                let incoming = HistoryDay {
                    usd: d.usd,
                    tokens: d.tokens,
                    models: d
                        .models
                        .iter()
                        .map(|m| HistoryModel {
                            name: m.name.clone(),
                            usd: m.usd,
                            tokens: m.tokens,
                        })
                        .collect(),
                };
                match by_day.get(&d.date) {
                    Some(existing) => {
                        by_day.insert(d.date.clone(), prefer_higher(existing, &incoming));
                    }
                    None => {
                        by_day.insert(d.date.clone(), incoming);
                    }
                }
            }
        }

        // Prune
        let prune_before = today - chrono::Duration::days(RETAIN_DAYS - 1);
        by_day.retain(|key, _| {
            chrono::NaiveDate::parse_from_str(key, "%Y-%m-%d")
                .map(|d| d >= prune_before)
                .unwrap_or(false)
        });
    }

    // Data Confidence Pass: stamp the last successful live-scan time so a
    // later history-only cycle (live == None) can still report freshness.
    if live.is_some() {
        doc.scanned_at
            .insert(source.to_string(), now.timestamp_millis());
    }

    let _ = write(&doc);
    let by_day = doc.sources.get(source).cloned().unwrap_or_default();
    let history_has_data = by_day.values().any(|d| d.tokens > 0 || d.usd > 0.0);
    let scanned_at = doc.scanned_at.get(source).copied();

    // Build contiguous window
    let mut daily = Vec::with_capacity(WINDOW_DAYS as usize);
    for offset in (0..WINDOW_DAYS).rev() {
        let day = today - chrono::Duration::days(offset);
        let key = day.format("%Y-%m-%d").to_string();
        let stored = by_day.get(&key);
        daily.push(DailyUsage {
            date: key,
            usd: stored.map(|s| s.usd).unwrap_or(0.0),
            tokens: stored.map(|s| s.tokens).unwrap_or(0),
            models: stored
                .map(|s| {
                    s.models
                        .iter()
                        .map(|m| DailyModel {
                            name: m.name.clone(),
                            usd: m.usd,
                            tokens: m.tokens,
                        })
                        .collect()
                })
                .unwrap_or_default(),
        });
    }

    let last30: Vec<_> = daily.iter().rev().take(30).collect();
    let last30_usd: f64 = last30.iter().map(|d| d.usd).sum();
    let last30_tokens: i64 = last30.iter().map(|d| d.tokens).sum();
    let today_u = daily.last();

    let mut votes: HashMap<String, i64> = HashMap::new();
    for d in &last30 {
        for m in &d.models {
            *votes.entry(m.name.clone()).or_default() += m.tokens;
        }
    }
    let top = votes.into_iter().max_by_key(|(_, t)| *t).map(|(n, _)| n);

    UsageReport {
        today_usd: today_u.map(|d| d.usd).unwrap_or(0.0),
        today_tokens: today_u.map(|d| d.tokens).unwrap_or(0),
        last30_usd,
        last30_tokens,
        daily,
        hourly: live.map(|l| l.hourly.clone()).unwrap_or_default(),
        top_model: top,
        included: is_included(live.is_some(), history_has_data),
        live: live.is_some(),
        scanned_at,
    }
}

/// Data Confidence Pass: whether `source` counts as "included" — present on
/// this machine — from this cycle's live-scan outcome and whether history
/// already holds a real (non-zero) day for it.
fn is_included(live_present: bool, history_has_data: bool) -> bool {
    live_present || history_has_data
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prefer_higher_keeps_tokens() {
        let low = HistoryDay {
            usd: 1.0,
            tokens: 10,
            models: vec![],
        };
        let high = HistoryDay {
            usd: 2.0,
            tokens: 20,
            models: vec![],
        };
        assert_eq!(prefer_higher(&low, &high).tokens, 20);
        assert_eq!(prefer_higher(&high, &low).tokens, 20);
    }

    // --- Data Confidence Pass: included/live/scanned_at ---------------

    use crate::config::TEST_ENV_LOCK as ENV_LOCK;

    fn temp_config(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "birdnion-cost-history-{tag}-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn live_report_for_today(tokens: i64) -> UsageReport {
        let today = Local::now().date_naive().to_string();
        UsageReport {
            daily: vec![DailyUsage {
                date: today,
                usd: 0.01,
                tokens,
                models: vec![],
            }],
            ..Default::default()
        }
    }

    #[test]
    fn apply_and_report_live_scan_marks_included_and_live() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config("live");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));

        let live = live_report_for_today(500);
        let report = apply_and_report("claude", Some(&live));

        assert!(report.included, "live scan should mark the source included");
        assert!(report.live, "this cycle had a live scan");
        assert!(report.scanned_at.is_some(), "live scan stamps scanned_at");

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn apply_and_report_history_only_keeps_scanned_at_and_included() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config("history-only");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));

        let live = live_report_for_today(500);
        let seeded = apply_and_report("codex", Some(&live));
        let first_scanned_at = seeded.scanned_at.expect("seeded scan stamps scanned_at");

        // Next cycle's scanner found nothing readable (live == None) — the
        // source must still report included/history-only with the SAME
        // last-known scanned_at, not a fresh one and not None.
        let history_only = apply_and_report("codex", None);
        assert!(
            history_only.included,
            "prior history keeps the source included"
        );
        assert!(!history_only.live, "no scan ran this cycle");
        assert_eq!(history_only.scanned_at, Some(first_scanned_at));

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn apply_and_report_without_any_data_is_not_included() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config("no-data");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));

        let report = apply_and_report("grok", None);
        assert!(
            !report.included,
            "no live scan and no history means not included"
        );
        assert!(!report.live);
        assert!(report.scanned_at.is_none());

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn usage_report_default_confidence_fields() {
        let report = UsageReport::default();
        assert!(!report.included);
        assert!(!report.live);
        assert_eq!(report.scanned_at, None);
    }
}
