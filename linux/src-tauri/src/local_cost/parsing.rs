//! Shared lenient helpers for the local-log cost readers — port of the
//! macOS LocalCostParsing utilities. Everything fails soft: a drifting
//! record shape yields None, not a crash.

use chrono::{DateTime, Local, TimeZone};
use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};
use walkdir::WalkDir;

/// $HOME as a path, matching the other scanners' env contract.
pub fn home() -> Option<PathBuf> {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .filter(|p| !p.as_os_str().is_empty())
}

/// Epoch unit by magnitude: seconds (<1e11), milliseconds (<1e14),
/// microseconds (<1e17), otherwise nanoseconds (OTel timeUnixNano).
pub fn epoch_date(value: f64) -> Option<DateTime<Local>> {
    if !(value > 0.0) {
        return None;
    }
    let seconds = if value < 1e11 {
        value
    } else if value < 1e14 {
        value / 1e3
    } else if value < 1e17 {
        value / 1e6
    } else {
        value / 1e9
    };
    let millis = (seconds * 1_000.0) as i64;
    Local.timestamp_millis_opt(millis).single()
}

/// Best-effort timestamp: RFC3339/ISO-8601 strings and epoch s/ms/us/ns.
/// None when the record has none — callers drop such turns instead of
/// guessing a day.
pub fn parse_timestamp(value: &Value) -> Option<DateTime<Local>> {
    match value {
        Value::Number(n) => n.as_f64().and_then(epoch_date),
        Value::String(s) => {
            if let Ok(dt) = DateTime::parse_from_rfc3339(s) {
                return Some(dt.with_timezone(&Local));
            }
            s.parse::<f64>().ok().and_then(epoch_date)
        }
        _ => None,
    }
}

/// First parseable timestamp under any of keys.
pub fn timestamp_in(record: &Value, keys: &[&str]) -> Option<DateTime<Local>> {
    for key in keys {
        if let Some(date) = record.get(key).and_then(parse_timestamp) {
            return Some(date);
        }
    }
    None
}

/// Lenient integer extraction: i64, f64 (truncated, non-negative), or a
/// numeric string.
pub fn int(value: &Value) -> Option<i64> {
    match value {
        Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                return Some(i);
            }
            n.as_f64()
                .filter(|d| *d >= 0.0 && d.is_finite())
                .map(|d| d as i64)
        }
        Value::String(s) => s
            .parse::<f64>()
            .ok()
            .filter(|d| d.is_finite())
            .map(|d| d as i64),
        _ => None,
    }
}

/// First non-empty object under any of keys.
pub fn dict<'a>(record: &'a Value, keys: &[&str]) -> Option<&'a serde_json::Map<String, Value>> {
    for key in keys {
        if let Some(d) = record
            .get(key)
            .and_then(|v| v.as_object())
            .filter(|d| !d.is_empty())
        {
            return Some(d);
        }
    }
    None
}

/// Enumerate regular files under root, filtering by extension and optional
/// parent-dir name, skipping hidden files and files not modified since
/// cutoff (whole-file logs untouched in the window hold no new turns).
pub fn files_under(
    root: &Path,
    extensions: &[&str],
    parent_dir: Option<&str>,
    modified_since: DateTime<Local>,
) -> Vec<PathBuf> {
    if !root.is_dir() {
        return Vec::new();
    }
    let mut out = Vec::new();
    for entry in WalkDir::new(root)
        .into_iter()
        .filter_entry(|e| {
            e.depth() == 0
                || !e
                    .file_name()
                    .to_str()
                    .is_some_and(|name| name.starts_with('.'))
        })
        .flatten()
    {
        let path = entry.path();
        if !path.is_file() {
            continue;
        }
        let ext = path
            .extension()
            .and_then(|e| e.to_str())
            .map(|e| e.to_lowercase());
        match ext {
            Some(ext) if extensions.contains(&ext.as_str()) => {}
            _ => continue,
        }
        if let Some(wanted) = parent_dir {
            if path
                .parent()
                .and_then(|p| p.file_name())
                .and_then(|n| n.to_str())
                != Some(wanted)
            {
                continue;
            }
        }
        if entry
            .metadata()
            .ok()
            .and_then(|meta| meta.modified().ok())
            .is_some_and(|mtime| DateTime::<Local>::from(mtime) < modified_since)
        {
            continue;
        }
        out.push(path.to_path_buf());
    }
    out
}

/// Parse one JSONL file; malformed or non-object lines are skipped (fail
/// soft).
pub fn json_lines(path: &Path) -> Vec<serde_json::Map<String, Value>> {
    let Ok(text) = fs::read_to_string(path) else {
        return Vec::new();
    };
    text.split('\n')
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .filter_map(|value| value.as_object().cloned())
        .collect()
}
