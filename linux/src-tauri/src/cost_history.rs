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

    let _ = write(&doc);
    let by_day = doc.sources.get(source).cloned().unwrap_or_default();

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
    }
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
}
