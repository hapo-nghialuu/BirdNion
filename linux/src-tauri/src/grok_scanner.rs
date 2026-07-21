//! Local Grok session cost scanner — port of macOS `GrokCostScanner`.
//! Walks `~/.grok/sessions/**/signals.json`.

use chrono::{DateTime, Duration, Local};
use serde_json::Value;
use std::collections::HashMap;
use std::path::PathBuf;
use walkdir::WalkDir;

use crate::usage::{DailyModel, DailyUsage, UsageReport};

/// Trailing daily window for charts / heatmap (macOS CombinedUsageReport 120d).
pub const HISTORY_DAYS: i64 = 120;

fn grok_home() -> PathBuf {
    if let Ok(h) = std::env::var("GROK_HOME") {
        let h = h.trim();
        if !h.is_empty() {
            return PathBuf::from(h);
        }
    }
    std::env::var("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("/tmp"))
        .join(".grok")
}

fn blended_usd(tokens: i64, model: &str) -> f64 {
    let m = model.to_lowercase();
    let (input, output) = if m.contains("grok-4.5") || m.contains("grok-4-5") {
        (2.0, 6.0)
    } else if m.contains("fast") {
        if m.contains("code") {
            (0.20, 1.50)
        } else {
            (0.20, 0.50)
        }
    } else if m.contains("4.3") || m.contains("4.20") || m.contains("4-3") || m.contains("4-20") {
        (1.25, 2.50)
    } else if m.contains("grok-4") {
        (3.0, 15.0)
    } else if m.contains("build") || m.contains("code") {
        (1.0, 2.0)
    } else {
        (2.0, 6.0)
    };
    let blended = 0.75 * input + 0.25 * output;
    (tokens as f64) / 1_000_000.0 * blended
}

pub fn usage_report() -> Option<UsageReport> {
    scan(Local::now())
}

pub fn scan(now: DateTime<Local>) -> Option<UsageReport> {
    let root = grok_home().join("sessions");
    if !root.is_dir() {
        return Some(empty_report(now));
    }
    let today = now.date_naive();
    let cutoff = today - Duration::days(HISTORY_DAYS - 1);

    let mut buckets: HashMap<String, (f64, i64, HashMap<String, (f64, i64)>)> = HashMap::new();

    for entry in WalkDir::new(&root).into_iter().filter_map(Result::ok) {
        if entry.file_name() != "signals.json" {
            continue;
        }
        let path = entry.path();
        let session_dir = path.parent().unwrap_or(path);
        let summary_path = session_dir.join("summary.json");

        let mut model = "grok-4.5".to_string();
        let mut active = entry
            .metadata()
            .ok()
            .and_then(|m| m.modified().ok())
            .map(DateTime::<Local>::from)
            .unwrap_or(now);

        if let Ok(text) = std::fs::read_to_string(&summary_path) {
            if let Ok(v) = serde_json::from_str::<Value>(&text) {
                if let Some(m) = v.get("current_model_id").and_then(Value::as_str) {
                    if !m.is_empty() {
                        model = m.to_string();
                    }
                }
                if let Some(raw) = v
                    .get("last_active_at")
                    .or_else(|| v.get("updated_at"))
                    .and_then(Value::as_str)
                {
                    if let Ok(dt) = DateTime::parse_from_rfc3339(raw) {
                        active = dt.with_timezone(&Local);
                    }
                }
            }
        }

        let day = active.date_naive();
        if day < cutoff {
            continue;
        }

        let Ok(text) = std::fs::read_to_string(path) else {
            continue;
        };
        let Ok(v) = serde_json::from_str::<Value>(&text) else {
            continue;
        };

        if let Some(m) = v.get("primaryModelId").and_then(Value::as_str) {
            if !m.is_empty() {
                model = m.to_string();
            }
        }

        let before = v
            .get("totalTokensBeforeCompaction")
            .and_then(Value::as_i64)
            .unwrap_or(0);
        let context = v
            .get("contextTokensUsed")
            .and_then(Value::as_i64)
            .unwrap_or(0);
        let tokens = (before + context).max(0);
        if tokens <= 0 {
            continue;
        }
        let usd = blended_usd(tokens, &model);
        let key = day.format("%Y-%m-%d").to_string();
        let b = buckets.entry(key).or_default();
        b.0 += usd;
        b.1 += tokens;
        let m = b.2.entry(model).or_default();
        m.0 += usd;
        m.1 += tokens;
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
        models.sort_by(|a, b| {
            b.usd
                .partial_cmp(&a.usd)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then(b.tokens.cmp(&a.tokens))
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
    Some(UsageReport {
        today_usd,
        today_tokens,
        last30_usd,
        last30_tokens,
        daily,
        hourly: vec![],
        top_model,
    })
}

fn empty_report(now: DateTime<Local>) -> UsageReport {
    let today = now.date_naive();
    let mut daily = Vec::new();
    for offset in (0..HISTORY_DAYS).rev() {
        let day = today - Duration::days(offset);
        daily.push(DailyUsage {
            date: day.format("%Y-%m-%d").to_string(),
            usd: 0.0,
            tokens: 0,
            models: vec![],
        });
    }
    UsageReport {
        daily,
        ..Default::default()
    }
}

