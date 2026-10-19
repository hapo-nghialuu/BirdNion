//! Declarative walker for JSON/JSONL log formats whose usage records are
//! nested dicts of token counters (Amp threads, Droid settings, Kimi wire,
//! Qwen chats, Cursor bubbles) — port of the macOS GenericJsonCostSource.

use chrono::{DateTime, Local};
use serde_json::{Map, Value};
use std::path::{Path, PathBuf};

use super::parsing;
use super::LocalTurnRecord;

/// Declarative spec for a log format: which dict keys hold usage records,
/// which keys hold the final total, and where model/timestamp hints live
/// (deep-first match).
#[derive(Clone, Copy)]
pub struct JsonLogSourceSpec {
    /// Dict keys whose object value is a usage record.
    pub usage_container_keys: &'static [&'static str],
    /// Keys inside a usage dict that already are the final total.
    pub explicit_total_keys: &'static [&'static str],
    /// Keys carrying the model name; deep search, first hit wins.
    pub model_keys: &'static [&'static str],
    /// Keys carrying a timestamp; deep search, first hit wins.
    pub timestamp_keys: &'static [&'static str],
}

pub const DEFAULT_SPEC: JsonLogSourceSpec = JsonLogSourceSpec {
    usage_container_keys: &[
        "usage",
        "usageMetadata",
        "token_usage",
        "tokenUsage",
        "sessionUsage",
        "token_usage_details",
    ],
    explicit_total_keys: &["total", "totalTokens", "totalTokenCount", "total_tokens"],
    model_keys: &["model", "modelName", "model_name", "modelID", "modelId"],
    timestamp_keys: &[
        "timestamp",
        "time",
        "created",
        "createdAt",
        "created_at",
        "updatedAt",
        "lastUpdated",
        "ts",
    ],
};

/// Token split extracted from one usage record.
#[derive(Default)]
pub struct LocalUsageTokens {
    pub input: i64,
    pub cache_read: i64,
    pub cache_write: i64,
    pub output: i64,
    pub explicit_total: Option<i64>,
}

impl LocalUsageTokens {
    pub fn total(&self) -> i64 {
        self.explicit_total
            .unwrap_or(self.input + self.cache_read + self.cache_write + self.output)
    }
}

enum TokenBucket {
    Input,
    CacheRead,
    CacheWrite,
    Output,
}

/// Allowlist classification of a counter key; None for anything that is not
/// a token count (timestamps, ids, credits, cost, aggregate totals).
fn bucket_for_key(key: &str) -> Option<TokenBucket> {
    let k = key.to_lowercase();
    if ["total", "time", "credit", "cost", "price"]
        .iter()
        .any(|needle| k.contains(needle))
    {
        return None;
    }
    if k.contains("cache") || k.contains("cached") {
        if k.contains("creation") || k.contains("write") {
            return Some(TokenBucket::CacheWrite);
        }
        if k.contains("read") || k.contains("cached") || k.ends_with("cache") {
            return Some(TokenBucket::CacheRead);
        }
        return None;
    }
    if k.contains("input") || k.contains("prompt") {
        return Some(TokenBucket::Input);
    }
    if k.contains("output")
        || k.contains("completion")
        || k.contains("candidates")
        || k.contains("reasoning")
        || k.contains("thoughts")
        || k.contains("thinking")
        || k == "thought"
    {
        return Some(TokenBucket::Output);
    }
    None
}

/// Classifies the numeric leaves of a usage dict into input / cache read /
/// cache write / output via a token-key allowlist; unknown keys are ignored
/// rather than guessed at. prompt-style input that already includes cached
/// tokens (Gemini/Qwen shape) is reduced by the cached count so cached
/// tokens are priced once.
pub fn split_tokens(usage: &Map<String, Value>, spec: &JsonLogSourceSpec) -> LocalUsageTokens {
    let mut tokens = LocalUsageTokens::default();
    let mut prompt_includes_cache = false;
    for (key, value) in usage {
        if let Some(total) = parsing::int(value) {
            if spec.explicit_total_keys.contains(&key.as_str()) {
                tokens.explicit_total = Some(total);
                continue;
            }
            match bucket_for_key(key) {
                Some(TokenBucket::CacheWrite) => tokens.cache_write += total,
                Some(TokenBucket::CacheRead) => tokens.cache_read += total,
                Some(TokenBucket::Input) => {
                    tokens.input += total;
                    if key.to_lowercase().contains("prompt") {
                        prompt_includes_cache = true;
                    }
                }
                Some(TokenBucket::Output) => tokens.output += total,
                None => {}
            }
            continue;
        }
        // Nested usage objects (rare) still contribute their leaves.
        // Sub-breakdowns of output/cache counters repeat tokens already
        // counted by the parent key, so they are skipped.
        let k = key.to_lowercase();
        if let Some(nested) = value.as_object() {
            if !["cache", "output", "completion"]
                .iter()
                .any(|needle| k.contains(needle))
            {
                let inner = split_tokens(nested, spec);
                tokens.input += inner.input;
                tokens.cache_read += inner.cache_read;
                tokens.cache_write += inner.cache_write;
                tokens.output += inner.output;
            }
        }
    }
    if prompt_includes_cache {
        tokens.input = (tokens.input - tokens.cache_read).max(0);
    }
    tokens
}

/// Depth-first search of keys inside an arbitrary JSON object, returning the
/// first value extract accepts.
fn deep_first<T>(
    object: &Value,
    keys: &[&str],
    extract: &dyn Fn(&Value) -> Option<T>,
) -> Option<T> {
    match object {
        Value::Object(dict) => {
            for key in keys {
                if let Some(result) = dict.get(*key).and_then(|v| extract(v)) {
                    return Some(result);
                }
            }
            for value in dict.values() {
                if let Some(result) = deep_first(value, keys, extract) {
                    return Some(result);
                }
            }
            None
        }
        Value::Array(array) => {
            for element in array {
                if let Some(result) = deep_first(element, keys, extract) {
                    return Some(result);
                }
            }
            None
        }
        _ => None,
    }
}

/// Looks keys up in the record that owns the usage first, then in the
/// parent context.
fn hint<T>(
    record: &Map<String, Value>,
    parent: Option<&Map<String, Value>>,
    keys: &[&str],
    extract: &dyn Fn(&Value) -> Option<T>,
) -> Option<T> {
    deep_first(&Value::Object(record.clone()), keys, extract)
        .or_else(|| parent.and_then(|p| deep_first(&Value::Object(p.clone()), keys, extract)))
}

/// Visits every dict stored under a usage-container key, with the enclosing
/// record as context for model/timestamp hints.
fn collect_usage_records<'a>(
    object: &'a Value,
    spec: &JsonLogSourceSpec,
    context: Option<&'a Map<String, Value>>,
    visit: &mut dyn FnMut(
        &'a Map<String, Value>,
        &'a Map<String, Value>,
        Option<&'a Map<String, Value>>,
    ),
) {
    match object {
        Value::Object(dict) => {
            let mut emitted = false;
            for key in spec.usage_container_keys {
                if let Some(usage) = dict
                    .get(*key)
                    .and_then(|v| v.as_object())
                    .filter(|u| !u.is_empty())
                {
                    // The record that owns the usage is the primary context;
                    // the enclosing parent only fills fields it lacks.
                    visit(usage, dict, context);
                    emitted = true;
                }
            }
            if emitted {
                return;
            }
            for (key, value) in dict {
                if spec.usage_container_keys.contains(&key.as_str()) {
                    continue;
                }
                collect_usage_records(value, spec, Some(dict), visit);
            }
        }
        Value::Array(array) => {
            for element in array {
                collect_usage_records(element, spec, context, visit);
            }
        }
        _ => {}
    }
}

/// Turns extracted from one parsed JSON object (a whole file, one JSONL
/// line, or one DB value). Turns with no timestamp hint are dropped;
/// cutoff drops older turns.
pub fn turns_in_object(
    object: &Value,
    spec: &JsonLogSourceSpec,
    cutoff: DateTime<Local>,
    dedupe_prefix: &str,
) -> Vec<LocalTurnRecord> {
    let mut out = Vec::new();
    let mut ordinal: usize = 0;
    collect_usage_records(object, spec, None, &mut |usage_dict, record, parent| {
        ordinal += 1;
        let tokens = split_tokens(usage_dict, spec);
        if tokens.total() <= 0 {
            return;
        }
        // Turns without a real timestamp are dropped: guessing a day (mtime,
        // cutoff) would move cumulative data between scans.
        let Some(date) = hint(
            record,
            parent,
            spec.timestamp_keys,
            &parsing::parse_timestamp,
        ) else {
            return;
        };
        if date < cutoff {
            return;
        }
        let model = hint(record, parent, spec.model_keys, &|v| {
            v.as_str().map(|s| s.to_string())
        })
        .unwrap_or_else(|| "unknown".to_string());
        out.push(LocalTurnRecord {
            date,
            usd: super::pricing::estimate_local_cost(
                &model,
                tokens.input,
                tokens.cache_read,
                tokens.cache_write,
                tokens.output,
            ),
            model,
            tokens: tokens.total(),
            dedupe_key: format!("{}:{}", dedupe_prefix, ordinal),
        });
    });
    out
}

/// Reads turns from every matching file under roots.
pub fn turns_in_roots(
    roots: &[PathBuf],
    extensions: &[&str],
    file_filter: Option<&dyn Fn(&Path) -> bool>,
    spec: &JsonLogSourceSpec,
    cutoff: DateTime<Local>,
    dedupe_prefix: &str,
) -> Vec<LocalTurnRecord> {
    let mut out = Vec::new();
    for root in roots {
        for file in parsing::files_under(root, extensions, None, cutoff) {
            if let Some(filter) = file_filter {
                if !filter(&file) {
                    continue;
                }
            }
            let prefix = format!("{}:{}", dedupe_prefix, file.display());
            if file
                .extension()
                .and_then(|e| e.to_str())
                .is_some_and(|e| e.eq_ignore_ascii_case("jsonl"))
            {
                for (index, line) in parsing::json_lines(&file).into_iter().enumerate() {
                    let line_prefix = format!("{}:{}", prefix, index);
                    out.extend(turns_in_object(
                        &Value::Object(line),
                        spec,
                        cutoff,
                        &line_prefix,
                    ));
                }
                continue;
            }
            let Ok(text) = std::fs::read_to_string(&file) else {
                continue;
            };
            let Ok(object) = serde_json::from_str::<Value>(&text) else {
                continue;
            };
            out.extend(turns_in_object(&object, spec, cutoff, &prefix));
        }
    }
    out
}
