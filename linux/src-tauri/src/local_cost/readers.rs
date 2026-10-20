//! Per-source readers for the extra local cost sources + Devin CLI — port
//! of the macOS *CostSource descriptors and DevinCostScanner. Each reader
//! resolves its session-log roots and converts them into LocalTurnRecords;
//! incremental windows, high-water merge, and confidence live in the
//! engine (local_cost.rs) + cost_history.

use chrono::{DateTime, Local};
use serde_json::{Map, Value};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

use super::generic;
use super::parsing;
use super::pricing;
use super::{LocalCostSource, LocalTurnRecord, ScanOutcome};

const GENERIC_REVISION: i64 = 2;

fn existing_dirs(candidates: Vec<PathBuf>) -> Vec<PathBuf> {
    candidates.into_iter().filter(|p| p.is_dir()).collect()
}

fn generic_roots(paths: Vec<PathBuf>, fallbacks: Vec<PathBuf>) -> Vec<PathBuf> {
    let roots = existing_dirs(paths);
    if !roots.is_empty() {
        return roots;
    }
    existing_dirs(fallbacks)
}

fn generic_turns(
    roots: &[PathBuf],
    extensions: &[&str],
    file_filter: Option<&dyn Fn(&Path) -> bool>,
    cutoff: DateTime<Local>,
    prefix: &str,
) -> ScanOutcome {
    ScanOutcome::complete(generic::turns_in_roots(
        roots,
        extensions,
        file_filter,
        &generic::DEFAULT_SPEC,
        cutoff,
        prefix,
    ))
}

// MARK: - Amp

pub mod amp {
    use super::*;

    pub fn descriptor() -> LocalCostSource {
        LocalCostSource {
            counting_revision: GENERIC_REVISION,
            roots,
            read_turns,
        }
    }

    fn roots() -> Vec<PathBuf> {
        let Some(home) = parsing::home() else {
            return vec![];
        };
        let threads = home.join(".local/share/amp/threads");
        if threads.is_dir() {
            return vec![threads];
        }
        let base = home.join(".local/share/amp");
        if base.is_dir() {
            vec![base]
        } else {
            vec![]
        }
    }

    fn read_turns(roots: &[PathBuf], cutoff: DateTime<Local>) -> ScanOutcome {
        generic_turns(roots, &["json"], None, cutoff, "amp")
    }
}

// MARK: - Droid

pub mod droid {
    use super::*;

    pub fn descriptor() -> LocalCostSource {
        LocalCostSource {
            counting_revision: GENERIC_REVISION,
            roots,
            read_turns,
        }
    }

    fn roots() -> Vec<PathBuf> {
        let Some(home) = parsing::home() else {
            return vec![];
        };
        existing_dirs(vec![home.join(".factory/sessions")])
    }

    fn read_turns(roots: &[PathBuf], cutoff: DateTime<Local>) -> ScanOutcome {
        generic_turns(
            roots,
            &["json"],
            Some(&|file: &Path| {
                file.file_name()
                    .and_then(|n| n.to_str())
                    .is_some_and(|n| n.ends_with(".settings.json"))
            }),
            cutoff,
            "droid",
        )
    }
}

// MARK: - Kimi

pub mod kimi {
    use super::*;

    pub fn descriptor() -> LocalCostSource {
        LocalCostSource {
            counting_revision: GENERIC_REVISION,
            roots,
            read_turns,
        }
    }

    fn roots() -> Vec<PathBuf> {
        let Some(home) = parsing::home() else {
            return vec![];
        };
        existing_dirs(vec![home.join(".kimi"), home.join(".kimi-code")])
    }

    fn read_turns(roots: &[PathBuf], cutoff: DateTime<Local>) -> ScanOutcome {
        generic_turns(
            roots,
            &["jsonl"],
            Some(&|file: &Path| file.file_name().and_then(|n| n.to_str()) == Some("wire.jsonl")),
            cutoff,
            "kimi",
        )
    }
}

// MARK: - Qwen

pub mod qwen {
    use super::*;

    pub fn descriptor() -> LocalCostSource {
        LocalCostSource {
            counting_revision: GENERIC_REVISION,
            roots,
            read_turns,
        }
    }

    fn roots() -> Vec<PathBuf> {
        let Some(home) = parsing::home() else {
            return vec![];
        };
        generic_roots(vec![home.join(".qwen/projects")], vec![home.join(".qwen")])
    }

    fn read_turns(roots: &[PathBuf], cutoff: DateTime<Local>) -> ScanOutcome {
        generic_turns(roots, &["jsonl"], None, cutoff, "qwen")
    }
}

// MARK: - Gemini CLI

pub mod gemini {
    use super::*;

    pub fn descriptor() -> LocalCostSource {
        LocalCostSource {
            counting_revision: GENERIC_REVISION,
            roots,
            read_turns,
        }
    }

    fn roots() -> Vec<PathBuf> {
        let Some(home) = parsing::home() else {
            return vec![];
        };
        existing_dirs(vec![home.join(".gemini/tmp")])
    }

    fn read_turns(roots: &[PathBuf], cutoff: DateTime<Local>) -> ScanOutcome {
        let mut out = Vec::new();
        for root in roots {
            for file in parsing::files_under(root, &["json", "jsonl"], Some("chats"), cutoff) {
                out.extend(records_in(&file, cutoff));
            }
        }
        ScanOutcome::complete(out)
    }

    fn records_in(file: &Path, cutoff: DateTime<Local>) -> Vec<LocalTurnRecord> {
        let session_fallback = file
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or_default()
            .to_string();
        if file
            .extension()
            .and_then(|e| e.to_str())
            .is_some_and(|e| e.eq_ignore_ascii_case("jsonl"))
        {
            return parsing::json_lines(file)
                .into_iter()
                .enumerate()
                .filter_map(|(index, record)| turn(&record, &session_fallback, index, cutoff))
                .collect();
        }
        let Ok(text) = std::fs::read_to_string(file) else {
            return vec![];
        };
        let Ok(Value::Object(object)) = serde_json::from_str::<Value>(&text) else {
            return vec![];
        };
        let session = object
            .get("sessionId")
            .or_else(|| object.get("session_id"))
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
            .unwrap_or(session_fallback);
        let messages = object
            .get("messages")
            .and_then(|v| v.as_array())
            .cloned()
            .unwrap_or_default();
        messages
            .iter()
            .enumerate()
            .filter_map(|(index, message)| {
                message
                    .as_object()
                    .and_then(|record| turn(record, &session, index, cutoff))
            })
            .collect()
    }

    /// input/prompt already includes the cached tokens, so the total is not
    /// topped up with cached and only the non-cached part is priced as fresh
    /// input. Records without a timestamp are dropped.
    fn turn(
        record: &Map<String, Value>,
        session: &str,
        ordinal: usize,
        cutoff: DateTime<Local>,
    ) -> Option<LocalTurnRecord> {
        let record_value = Value::Object(record.clone());
        let tokens = parsing::dict(&record_value, &["tokens", "usage", "stats", "tokenUsage"])?;
        let first_int = |keys: &[&str]| -> Option<i64> {
            keys.iter()
                .find_map(|k| tokens.get(*k).and_then(parsing::int))
        };
        let input = first_int(&["input", "input_tokens", "prompt", "promptTokens"]).unwrap_or(0);
        let output =
            first_int(&["output", "output_tokens", "candidates", "candidatesTokens"]).unwrap_or(0);
        let cached =
            first_int(&["cached", "cached_tokens", "cachedContent", "cache_read"]).unwrap_or(0);
        let thoughts = first_int(&["thoughts", "thought", "reasoning"]).unwrap_or(0);
        let tool = first_int(&["tool", "tool_tokens"]).unwrap_or(0);
        let explicit_total = first_int(&["total", "total_tokens", "totalTokens"]);
        let total = explicit_total.unwrap_or(input + output + thoughts + tool);
        if total <= 0 {
            return None;
        }
        let date = parsing::timestamp_in(
            &Value::Object(record.clone()),
            &[
                "timestamp",
                "time",
                "created",
                "createdAt",
                "created_at",
                "startTime",
                "lastUpdated",
            ],
        )?;
        if date < cutoff {
            return None;
        }
        let model = record
            .get("model")
            .or_else(|| record.get("model_name"))
            .and_then(|v| v.as_str())
            .unwrap_or("unknown")
            .to_string();
        let usd = pricing::GeminiModelPrice::cost(
            &model,
            (input - cached).max(0),
            output + thoughts + tool,
            cached,
        );
        Some(LocalTurnRecord {
            date,
            usd,
            dedupe_key: format!("gemini:{}:{}:{}", session, ordinal, model),
            model,
            tokens: total,
        })
    }
}

// MARK: - OpenCode

pub mod opencode {
    use super::*;
    use chrono::TimeZone;
    use rusqlite::OpenFlags;

    pub fn descriptor() -> LocalCostSource {
        LocalCostSource {
            counting_revision: 1,
            roots,
            read_turns,
        }
    }

    fn roots() -> Vec<PathBuf> {
        let Some(home) = parsing::home() else {
            return vec![];
        };
        let dir = home.join(".local/share/opencode");
        if dir.join("opencode.db").is_file() {
            vec![dir]
        } else {
            vec![]
        }
    }

    fn read_turns(roots: &[PathBuf], cutoff: DateTime<Local>) -> ScanOutcome {
        let mut out = Vec::new();
        for root in roots {
            out.extend(turns_in_db(&root.join("opencode.db"), cutoff));
        }
        ScanOutcome::complete(out)
    }

    const PROVIDER_MESSAGES_SQL: &str = "
        SELECT
          id AS key,
          CAST(COALESCE(json_extract(data, '$.time.created'), time_created) AS INTEGER) AS createdMs,
          CAST(json_extract(data, '$.cost') AS REAL) AS cost,
          json_type(data, '$.cost') IN ('integer', 'real') AS hasCost,
          COALESCE(json_extract(data, '$.modelID'), '') AS modelID,
          CASE WHEN json_type(data, '$.tokens') = 'object'
            THEN json_extract(data, '$.tokens') END AS tokens
        FROM message
        WHERE json_valid(data)
          AND json_extract(data, '$.providerID') = 'opencode-go'
          AND json_extract(data, '$.role') = 'assistant'
    ";

    fn usage_sql(db: &rusqlite::Connection) -> String {
        if has_table(db, "part") {
            format!(
                "WITH provider_messages AS ({})
                SELECT
                  'p:' || p.id AS key,
                  CAST(COALESCE(json_extract(p.data, '$.time.created'), p.time_created, m.createdMs) AS INTEGER) AS createdMs,
                  CAST(json_extract(p.data, '$.cost') AS REAL) AS cost,
                  m.modelID AS modelID,
                  CASE WHEN json_type(p.data, '$.tokens') = 'object'
                    THEN json_extract(p.data, '$.tokens') END AS tokens
                FROM part p
                JOIN provider_messages m ON m.key = p.message_id
                WHERE json_valid(p.data)
                  AND json_extract(p.data, '$.type') = 'step-finish'
                  AND json_type(p.data, '$.cost') IN ('integer', 'real')
                UNION ALL
                SELECT 'm:' || key, createdMs, cost, modelID, tokens
                FROM provider_messages m
                WHERE hasCost
                  AND NOT EXISTS (
                    SELECT 1
                    FROM part p
                    WHERE p.message_id = m.key
                      AND json_valid(p.data)
                      AND json_extract(p.data, '$.type') = 'step-finish'
                      AND json_type(p.data, '$.cost') IN ('integer', 'real')
                  )",
                PROVIDER_MESSAGES_SQL
            )
        } else {
            format!(
                "SELECT key, createdMs, cost, modelID, tokens FROM ({}) WHERE hasCost",
                PROVIDER_MESSAGES_SQL
            )
        }
    }

    fn has_table(db: &rusqlite::Connection, name: &str) -> bool {
        db.query_row(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
            [name],
            |_| Ok(()),
        )
        .is_ok()
    }

    /// Normal open first; when a clean WAL shutdown left no sidecars the
    /// header still claims WAL mode, so retry with immutable=1.
    fn open_db(path: &Path) -> Option<rusqlite::Connection> {
        let normal = rusqlite::Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY);
        if let Ok(db) = normal {
            db.busy_timeout(std::time::Duration::from_millis(250)).ok();
            return Some(db);
        }
        let uri = format!("file:{}?immutable=1", path.to_string_lossy());
        let db = rusqlite::Connection::open_with_flags(
            &uri,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_URI,
        )
        .ok()?;
        Some(db)
    }

    fn resolved_total(tokens_json: Option<String>) -> i64 {
        let Some(json) = tokens_json else { return 0 };
        let Ok(value) = serde_json::from_str::<Value>(&json) else {
            return 0;
        };
        let Some(obj) = value.as_object() else {
            return 0;
        };
        let get = |k: &str| obj.get(k).and_then(parsing::int);
        if let Some(total) = get("total") {
            return total;
        }
        let parts = [
            get("input"),
            get("output"),
            get("reasoning"),
            obj.get("cache")
                .and_then(|c| c.get("read"))
                .and_then(parsing::int),
            obj.get("cache")
                .and_then(|c| c.get("write"))
                .and_then(parsing::int),
        ];
        if parts.iter().all(|p| p.is_some()) {
            parts.iter().flatten().sum()
        } else {
            0
        }
    }

    fn turns_in_db(path: &Path, cutoff: DateTime<Local>) -> Vec<LocalTurnRecord> {
        if !path.is_file() {
            return vec![];
        }
        let Some(db) = open_db(path) else {
            return vec![];
        };
        let sql = usage_sql(&db);
        let Ok(mut stmt) = db.prepare(&sql) else {
            return vec![];
        };
        let Ok(rows) = stmt.query_map([], |row| {
            Ok((
                row.get::<_, String>(0).unwrap_or_default(),
                row.get::<_, i64>(1).unwrap_or(0),
                row.get::<_, f64>(2).unwrap_or(0.0),
                row.get::<_, String>(3).unwrap_or_default(),
                row.get::<_, Option<String>>(4).unwrap_or(None),
            ))
        }) else {
            return vec![];
        };
        let cutoff_ms = cutoff.timestamp_millis();
        let mut out = Vec::new();
        for row in rows.flatten() {
            let (key, created_ms, cost, model, tokens_json) = row;
            if created_ms <= 0 || !(cost >= 0.0 && cost.is_finite()) || created_ms < cutoff_ms {
                continue;
            }
            let Some(date) = Local.timestamp_millis_opt(created_ms).single() else {
                continue;
            };
            out.push(LocalTurnRecord {
                date,
                model: if model.is_empty() {
                    "opencode".into()
                } else {
                    model
                },
                tokens: resolved_total(tokens_json),
                usd: cost,
                dedupe_key: key,
            });
        }
        out
    }
}

// MARK: - Cursor

pub mod cursor {
    use super::*;
    use rusqlite::OpenFlags;

    pub fn descriptor() -> LocalCostSource {
        LocalCostSource {
            counting_revision: GENERIC_REVISION,
            roots,
            read_turns,
        }
    }

    /// Roots are the globalStorage dirs that contain state.vscdb — both the
    /// macOS Application Support path and the Linux XDG path.
    fn roots() -> Vec<PathBuf> {
        let Some(home) = parsing::home() else {
            return vec![];
        };
        let candidates = [
            home.join("Library/Application Support/Cursor/User/globalStorage"),
            home.join(".config/Cursor/User/globalStorage"),
        ];
        candidates
            .into_iter()
            .filter(|dir| dir.join("state.vscdb").is_file())
            .collect()
    }

    fn read_turns(roots: &[PathBuf], cutoff: DateTime<Local>) -> ScanOutcome {
        let mut out = Vec::new();
        for root in roots {
            out.extend(turns_in_db(&root.join("state.vscdb"), cutoff));
        }
        ScanOutcome::complete(out)
    }

    fn open_db(path: &Path) -> Option<rusqlite::Connection> {
        let uri = format!("file:{}?mode=ro", path.to_string_lossy());
        rusqlite::Connection::open_with_flags(
            &uri,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_URI,
        )
        .ok()
    }

    fn turns_in_db(path: &Path, cutoff: DateTime<Local>) -> Vec<LocalTurnRecord> {
        let Some(db) = open_db(path) else {
            return vec![];
        };
        let has_table = db
            .query_row(
                "SELECT 1 FROM main.sqlite_master WHERE type='table' AND name='cursorDiskKV' LIMIT 1",
                [],
                |_| Ok(()),
            )
            .is_ok();
        if !has_table {
            return vec![];
        }
        let Ok(mut stmt) = db.prepare(
            "SELECT key, value FROM main.cursorDiskKV WHERE key LIKE 'bubbleId:%' ORDER BY rowid DESC LIMIT 20000",
        ) else {
            return vec![];
        };
        let Ok(rows) = stmt.query_map([], |row| {
            Ok((
                row.get::<_, String>(0).unwrap_or_default(),
                match row.get_ref(1) {
                    Ok(rusqlite::types::ValueRef::Text(t)) => {
                        String::from_utf8_lossy(t).to_string()
                    }
                    Ok(rusqlite::types::ValueRef::Blob(b)) => {
                        String::from_utf8_lossy(b).to_string()
                    }
                    _ => String::new(),
                },
            ))
        }) else {
            return vec![];
        };
        let mut out = Vec::new();
        for row in rows.flatten() {
            let (key, text) = row;
            if text.is_empty() {
                continue;
            }
            let Ok(object) = serde_json::from_str::<Value>(&text) else {
                continue;
            };
            out.extend(generic::turns_in_object(
                &object,
                &generic::DEFAULT_SPEC,
                cutoff,
                &format!("cursor:{}", key),
            ));
        }
        out
    }
}

// MARK: - Copilot CLI

pub mod copilot {
    use super::*;

    pub fn descriptor() -> LocalCostSource {
        LocalCostSource {
            counting_revision: GENERIC_REVISION,
            roots,
            read_turns,
        }
    }

    fn roots() -> Vec<PathBuf> {
        let Some(home) = parsing::home() else {
            return vec![];
        };
        existing_dirs(vec![home.join(".copilot")])
    }

    fn read_turns(roots: &[PathBuf], cutoff: DateTime<Local>) -> ScanOutcome {
        let mut out = Vec::new();
        let mut covered_pairs: HashSet<String> = HashSet::new();
        for root in roots {
            let state_root = root.join("session-state");
            for file in parsing::files_under(&state_root, &["jsonl"], None, cutoff) {
                let result = session_state_turns(&file, cutoff);
                covered_pairs.extend(result.1);
                out.extend(result.0);
            }
            let otel_root = root.join("otel");
            let mut otel_files = parsing::files_under(&otel_root, &["jsonl"], None, cutoff);
            if let Ok(explicit) = std::env::var("COPILOT_OTEL_FILE_EXPORTER_PATH") {
                if !explicit.is_empty() {
                    otel_files.push(PathBuf::from(explicit));
                }
            }
            for file in otel_files {
                out.extend(otel_turns(&file, cutoff, &covered_pairs));
            }
        }
        ScanOutcome::complete(out)
    }

    /// session-state events.jsonl: only session.shutdown rows count;
    /// data.modelMetrics.<model>.usage is cumulative per session+model, so
    /// each snapshot reports the delta from its predecessor.
    fn session_state_turns(
        file: &Path,
        cutoff: DateTime<Local>,
    ) -> (Vec<LocalTurnRecord>, HashSet<String>) {
        let session = file
            .parent()
            .and_then(|p| p.file_name())
            .and_then(|n| n.to_str())
            .unwrap_or_default()
            .to_string();
        let mut last: HashMap<String, pricing::CopilotTokenCounts> = HashMap::new();
        let mut snapshot_ordinal: usize = 0;
        let mut pairs = HashSet::new();
        let mut out = Vec::new();
        for event in parsing::json_lines(file) {
            let event_type = event
                .get("type")
                .and_then(|v| v.as_str())
                .unwrap_or_default();
            if event_type != "session.shutdown" && event_type != "session_shutdown" {
                continue;
            }
            snapshot_ordinal += 1;
            let data = event
                .get("data")
                .and_then(|v| v.as_object())
                .cloned()
                .unwrap_or_else(|| event.clone());
            let date = parsing::timestamp_in(
                &Value::Object(event.clone()),
                &[
                    "timestamp",
                    "time",
                    "created",
                    "createdAt",
                    "created_at",
                    "startTime",
                    "lastUpdated",
                ],
            )
            .or_else(|| {
                parsing::timestamp_in(
                    &Value::Object(data.clone()),
                    &[
                        "timestamp",
                        "time",
                        "created",
                        "createdAt",
                        "created_at",
                        "startTime",
                        "lastUpdated",
                    ],
                )
            });
            let metrics = data
                .get("modelMetrics")
                .or_else(|| data.get("model_metrics"))
                .and_then(|v| v.as_object())
                .cloned()
                .unwrap_or_default();
            for (model, raw) in metrics {
                let Some(metric) = raw.as_object() else {
                    continue;
                };
                let usage = metric
                    .get("usage")
                    .and_then(|v| v.as_object())
                    .unwrap_or(metric);
                let counts = pricing::CopilotTokenCounts::from_usage(usage);
                if counts.total() <= 0 {
                    continue;
                }
                pairs.insert(format!("{}|{}", session, model));
                let delta = counts.delta(last.get(&model).unwrap_or(&Default::default()));
                last.insert(model.clone(), counts);
                let Some(date) = date else { continue };
                if delta.total() <= 0 || date < cutoff {
                    continue;
                }
                out.push(LocalTurnRecord {
                    date,
                    usd: pricing::copilot_estimate(&model, &delta),
                    dedupe_key: format!("copilot:{}:{}:s{}", session, model, snapshot_ordinal),
                    model,
                    tokens: delta.total(),
                });
            }
        }
        (out, pairs)
    }

    /// Walk nested arrays/dicts and merge every "attributes" entry
    /// ({"key":…,"value":{…}} OTel shape or plain dict) into flat.
    fn flatten_attributes(object: &Value, flat: &mut HashMap<String, Value>) {
        match object {
            Value::Object(dict) => {
                for (key, value) in dict {
                    if key == "attributes" {
                        flatten_attributes(value, flat);
                    } else if value.is_object() || value.is_array() {
                        flatten_attributes(value, flat);
                    } else if !flat.contains_key(key) {
                        flat.insert(key.clone(), value.clone());
                    }
                }
            }
            Value::Array(array) => {
                for element in array {
                    if let Some(pair) = element.as_object() {
                        if let (Some(key), Some(value)) =
                            (pair.get("key").and_then(|k| k.as_str()), pair.get("value"))
                        {
                            if let Some(inner) = value.as_object() {
                                if let Some(first) = inner.values().next() {
                                    flat.insert(key.to_string(), first.clone());
                                    continue;
                                }
                            }
                            flat.insert(key.to_string(), value.clone());
                            continue;
                        }
                    }
                    flatten_attributes(element, flat);
                }
            }
            _ => {}
        }
    }

    /// Best-effort walk of OTel log records: any nested object carrying a
    /// numeric *_tokens attribute is treated as a usage row. Session/model
    /// pairs already covered by session-state are skipped.
    fn otel_turns(
        file: &Path,
        cutoff: DateTime<Local>,
        covered: &HashSet<String>,
    ) -> Vec<LocalTurnRecord> {
        parsing::json_lines(file)
            .into_iter()
            .enumerate()
            .filter_map(|(index, line)| {
                let mut flat: HashMap<String, Value> = HashMap::new();
                flatten_attributes(&Value::Object(line), &mut flat);
                let flat_token = |keys: &[&str]| -> Option<i64> {
                    keys.iter()
                        .find_map(|k| flat.get(*k).and_then(parsing::int))
                };
                let input =
                    flat_token(&["gen_ai.usage.input_tokens", "input_tokens", "inputTokens"])
                        .unwrap_or(0);
                let output = flat_token(&[
                    "gen_ai.usage.output_tokens",
                    "output_tokens",
                    "outputTokens",
                ])
                .unwrap_or(0);
                let cached =
                    flat_token(&["gen_ai.usage.cache_read_input_tokens", "cache_read_tokens"])
                        .unwrap_or(0);
                let reasoning =
                    flat_token(&["gen_ai.usage.reasoning_tokens", "reasoning_tokens"]).unwrap_or(0);
                let total = input + output + cached + reasoning;
                if total <= 0 {
                    return None;
                }
                let str_of = |keys: &[&str]| -> Option<String> {
                    keys.iter()
                        .find_map(|k| flat.get(*k).and_then(|v| v.as_str()).map(|s| s.to_string()))
                };
                let model = str_of(&["gen_ai.request.model", "gen_ai.response.model", "model"])
                    .unwrap_or_else(|| "unknown".to_string());
                let session = str_of(&["session.id", "service.session.id"]).unwrap_or_else(|| {
                    file.file_stem()
                        .and_then(|s| s.to_str())
                        .unwrap_or_default()
                        .to_string()
                });
                if covered.contains(&format!("{}|{}", session, model)) {
                    return None;
                }
                let flat_obj: Map<String, Value> = flat.into_iter().collect();
                let date = parsing::timestamp_in(
                    &Value::Object(flat_obj),
                    &["timestamp", "timeUnixNano", "observedTimeUnixNano"],
                )?;
                if date < cutoff {
                    return None;
                }
                let counts = pricing::CopilotTokenCounts {
                    input,
                    output: output + reasoning,
                    cache_read: cached,
                    ..Default::default()
                };
                Some(LocalTurnRecord {
                    date,
                    usd: pricing::copilot_estimate(&model, &counts),
                    dedupe_key: format!(
                        "copilot-otel:{}:{}",
                        file.file_name()
                            .and_then(|n| n.to_str())
                            .unwrap_or_default(),
                        index
                    ),
                    model,
                    tokens: total,
                })
            })
            .collect()
    }
}

// MARK: - Antigravity

pub mod antigravity {
    use super::*;
    use chrono::TimeZone;
    use rusqlite::OpenFlags;

    pub fn descriptor() -> LocalCostSource {
        LocalCostSource {
            counting_revision: 1,
            roots,
            read_turns,
        }
    }

    fn roots() -> Vec<PathBuf> {
        let Some(home) = parsing::home() else {
            return vec![];
        };
        existing_dirs(vec![
            home.join(".gemini/antigravity-cli/conversations"),
            home.join(".gemini/antigravity/conversations"),
            home.join(".config/tokscale/antigravity-cache/sessions"),
        ])
    }

    fn read_turns(roots: &[PathBuf], cutoff: DateTime<Local>) -> ScanOutcome {
        let mut out = Vec::new();
        for root in roots {
            for file in parsing::files_under(root, &["db"], None, cutoff) {
                out.extend(turns_in_db(&file, cutoff));
            }
        }
        ScanOutcome::complete(out)
    }

    fn open_db(path: &Path) -> Option<rusqlite::Connection> {
        if let Ok(db) =
            rusqlite::Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)
        {
            return Some(db);
        }
        let uri = format!("file:{}?immutable=1", path.to_string_lossy());
        rusqlite::Connection::open_with_flags(
            &uri,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_URI,
        )
        .ok()
    }

    fn turns_in_db(path: &Path, cutoff: DateTime<Local>) -> Vec<LocalTurnRecord> {
        let session = path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or_default()
            .to_string();
        let Some(db) = open_db(path) else {
            return vec![];
        };
        let has_table = db
            .query_row(
                "SELECT 1 FROM main.sqlite_master WHERE type='table' AND name='gen_metadata' LIMIT 1",
                [],
                |_| Ok(()),
            )
            .is_ok();
        if !has_table {
            return vec![];
        }
        let Ok(mut stmt) =
            db.prepare("SELECT idx, data FROM main.gen_metadata ORDER BY idx DESC LIMIT 10000")
        else {
            return vec![];
        };
        let Ok(rows) = stmt.query_map([], |row| {
            Ok((
                row.get::<_, i64>(0).unwrap_or(0),
                row.get::<_, Vec<u8>>(1).unwrap_or_default(),
            ))
        }) else {
            return vec![];
        };
        let mut out = Vec::new();
        for row in rows.flatten() {
            let (idx, blob) = row;
            let Some(turn) = proto::parse_turn(&blob) else {
                continue;
            };
            let (Some(usage), Some(timestamp_ms)) = (turn.usage, turn.timestamp_ms) else {
                continue;
            };
            let Some(date) = Local.timestamp_millis_opt(timestamp_ms).single() else {
                continue;
            };
            if date < cutoff {
                continue;
            }
            let input = usage.system_prompt + usage.new_input;
            let total = input + usage.output + usage.cache_read + usage.reasoning;
            if total <= 0 {
                continue;
            }
            let model = turn.model.unwrap_or_else(|| "unknown".into());
            out.push(LocalTurnRecord {
                date,
                usd: cost(
                    &model,
                    input,
                    usage.cache_read,
                    usage.output + usage.reasoning,
                ),
                dedupe_key: format!("agv:{}:{}", session, idx),
                model,
                tokens: total,
            });
        }
        out
    }

    fn cost(model: &str, input: i64, cache_read: i64, output: i64) -> f64 {
        let m = model.to_lowercase();
        if m.contains("claude") {
            if let Some(p) = pricing::ClaudeModelPrice::price_for(&m, input) {
                return (input as f64 * p.input_per_m
                    + cache_read as f64 * p.cache_read_per_m
                    + output as f64 * p.output_per_m)
                    / 1_000_000.0;
            }
        }
        if m.contains("gemini") {
            if let Some(p) = pricing::GeminiModelPrice::price_for(&m) {
                return (input as f64 * p.input_per_m
                    + cache_read as f64 * p.cached_per_m
                    + output as f64 * p.output_per_m)
                    / 1_000_000.0;
            }
        }
        0.0
    }

    /// Minimal protobuf wire decoder for Antigravity's gen_metadata.data
    /// generation records. Layout (from upstream AntigravityProtoReader):
    /// root {1: chat}; chat {4: usage, 9: generation, 19: model};
    /// usage {1: systemPrompt, 2: newInput, 5: cacheRead, 9: output,
    /// 10: reasoning}; generation {4: timestamp {1: sec, 2: ns}}.
    mod proto {
        #[derive(Default)]
        pub struct ParsedUsage {
            pub system_prompt: i64,
            pub new_input: i64,
            pub cache_read: i64,
            pub output: i64,
            pub reasoning: i64,
        }

        #[derive(Default)]
        pub struct ParsedTurn {
            pub usage: Option<ParsedUsage>,
            pub timestamp_ms: Option<i64>,
            pub model: Option<String>,
        }

        struct Reader<'a> {
            bytes: &'a [u8],
            offset: usize,
            malformed: bool,
        }

        impl<'a> Reader<'a> {
            fn read_varint(&mut self) -> Option<u64> {
                let mut result: u64 = 0;
                for index in 0..10 {
                    let Some(&byte) = self.bytes.get(self.offset) else {
                        break;
                    };
                    self.offset += 1;
                    if index == 9 && byte > 1 {
                        break;
                    }
                    result |= u64::from(byte & 0x7F) << (index * 7);
                    if byte & 0x80 == 0 {
                        return Some(result);
                    }
                }
                self.malformed = true;
                None
            }

            fn next_field(&mut self) -> Option<(u32, u32, Option<&'a [u8]>, Option<u64>)> {
                if self.offset >= self.bytes.len() {
                    return None;
                }
                let tag = self.read_varint()?;
                if tag >> 3 == 0 || tag >> 3 > 536_870_911 {
                    self.malformed = true;
                    return None;
                }
                let number = (tag >> 3) as u32;
                let wire = (tag & 7) as u32;
                if wire == 0 {
                    let value = self.read_varint()?;
                    return Some((number, wire, None, Some(value)));
                }
                let count: usize = match wire {
                    1 => 8,
                    2 => usize::try_from(self.read_varint()?).ok()?,
                    5 => 4,
                    _ => {
                        self.malformed = true;
                        return None;
                    }
                };
                if count > self.bytes.len() - self.offset {
                    self.malformed = true;
                    return None;
                }
                let data = &self.bytes[self.offset..self.offset + count];
                self.offset += count;
                Some((number, wire, Some(data), None))
            }
        }

        fn each_field(
            bytes: &[u8],
            visit: &mut dyn FnMut(u32, u32, Option<&[u8]>, Option<u64>),
        ) -> bool {
            let mut reader = Reader {
                bytes,
                offset: 0,
                malformed: false,
            };
            while reader.offset < reader.bytes.len() {
                let Some(field) = reader.next_field() else {
                    break;
                };
                visit(field.0, field.1, field.2, field.3);
            }
            !reader.malformed
        }

        fn message(wire: u32, data: Option<&[u8]>) -> Option<&[u8]> {
            if wire == 2 {
                data
            } else {
                None
            }
        }

        fn string(wire: u32, data: Option<&[u8]>) -> Option<String> {
            std::str::from_utf8(message(wire, data)?)
                .ok()
                .map(|s| s.to_string())
        }

        fn integer(wire: u32, value: Option<u64>) -> Option<i64> {
            if wire == 0 {
                value.and_then(|v| i64::try_from(v).ok())
            } else {
                None
            }
        }

        pub fn parse_turn(root: &[u8]) -> Option<ParsedTurn> {
            let mut turn = ParsedTurn::default();
            let mut seconds: Option<u64> = None;
            let mut nanos: u64 = 0;
            let mut found_chat = false;
            let valid = each_field(root, &mut |number, wire, data, _| {
                if number == 1 {
                    found_chat = true;
                    if let Some(chat) = message(wire, data) {
                        parse_chat(chat, &mut turn, &mut seconds, &mut nanos);
                    }
                }
            });
            if !valid || !found_chat {
                return None;
            }
            if let Some(s) = seconds {
                if s > 0 && s <= 253_402_300_799 && nanos <= 999_999_999 {
                    turn.timestamp_ms = Some(s as i64 * 1000 + nanos as i64 / 1_000_000);
                }
            }
            Some(turn)
        }

        fn parse_chat(
            bytes: &[u8],
            turn: &mut ParsedTurn,
            seconds: &mut Option<u64>,
            nanos: &mut u64,
        ) {
            let _ = each_field(bytes, &mut |number, wire, data, _| match number {
                4 => {
                    let mut usage = turn.usage.take().unwrap_or_default();
                    if let Some(body) = message(wire, data) {
                        parse_usage(body, &mut usage);
                    }
                    turn.usage = Some(usage);
                }
                9 => {
                    if let Some(generation) = message(wire, data) {
                        parse_generation(generation, seconds, nanos);
                    }
                }
                19 => turn.model = string(wire, data),
                _ => {}
            });
        }

        fn parse_usage(bytes: &[u8], usage: &mut ParsedUsage) {
            let _ = each_field(bytes, &mut |number, wire, _, value| {
                let Some(int) = integer(wire, value) else {
                    return;
                };
                match number {
                    1 => usage.system_prompt = int,
                    2 => usage.new_input = int,
                    5 => usage.cache_read = int,
                    9 => usage.output = int,
                    10 => usage.reasoning = int,
                    _ => {}
                }
            });
        }

        fn parse_generation(bytes: &[u8], seconds: &mut Option<u64>, nanos: &mut u64) {
            let _ = each_field(bytes, &mut |number, wire, data, _| {
                if number != 4 {
                    return;
                }
                if let Some(stamp) = message(wire, data) {
                    parse_timestamp(stamp, seconds, nanos);
                }
            });
        }

        fn parse_timestamp(bytes: &[u8], seconds: &mut Option<u64>, nanos: &mut u64) {
            let _ = each_field(bytes, &mut |number, wire, _, value| {
                let Some(int) = integer(wire, value) else {
                    return;
                };
                if int < 0 {
                    return;
                }
                match number {
                    1 => {
                        let s = int as u64;
                        if s > 0 && s <= 253_402_300_799 {
                            *seconds = Some(s);
                        }
                    }
                    2 => {
                        let n = int as u64;
                        if n <= 999_999_999 {
                            *nanos = n;
                        }
                    }
                    _ => {}
                }
            });
        }
    }
}

// MARK: - Goose

pub mod goose {
    use super::*;
    use rusqlite::OpenFlags;

    pub fn descriptor() -> LocalCostSource {
        LocalCostSource {
            counting_revision: GENERIC_REVISION,
            roots,
            read_turns,
        }
    }

    /// Roots are the directories that contain a sessions.db.
    fn roots() -> Vec<PathBuf> {
        let Some(home) = parsing::home() else {
            return vec![];
        };
        let candidates = [
            home.join(".local/share/goose/sessions"),
            home.join("Library/Application Support/goose/sessions"),
            home.join(".local/share/Block/goose/sessions"),
        ];
        candidates
            .into_iter()
            .filter(|dir| dir.join("sessions.db").is_file())
            .collect()
    }

    fn read_turns(roots: &[PathBuf], cutoff: DateTime<Local>) -> ScanOutcome {
        let mut out = Vec::new();
        for root in roots {
            out.extend(turns_in_db(&root.join("sessions.db"), cutoff));
        }
        ScanOutcome::complete(out)
    }

    fn open_db(path: &Path) -> Option<rusqlite::Connection> {
        let uri = format!("file:{}?mode=ro", path.to_string_lossy());
        rusqlite::Connection::open_with_flags(
            &uri,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_URI,
        )
        .ok()
    }

    /// First table whose columns mention tokens — normally sessions.
    fn sessions_table(db: &rusqlite::Connection) -> Option<String> {
        let mut stmt = db
            .prepare("SELECT name, sql FROM main.sqlite_master WHERE type='table'")
            .ok()?;
        let rows = stmt
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0).unwrap_or_default(),
                    row.get::<_, String>(1).unwrap_or_default(),
                ))
            })
            .ok()?;
        let mut fallback: Option<String> = None;
        for row in rows.flatten() {
            if row.0 == "sessions" {
                return Some(row.0);
            }
            if fallback.is_none() && row.1.to_lowercase().contains("token") {
                fallback = Some(row.0);
            }
        }
        fallback
    }

    /// Token columns mapped leniently: accumulated_* first, plain
    /// input/output/total aliases; any positive total - input - output
    /// remainder counts as output-priced usage (ccusage's reasoning
    /// convention). Session-cumulative totals attribute to the session's
    /// own start day — updated_at would shift the same tokens every scan.
    fn turns_in_db(path: &Path, cutoff: DateTime<Local>) -> Vec<LocalTurnRecord> {
        let Some(db) = open_db(path) else {
            return vec![];
        };
        let Some(table) = sessions_table(&db) else {
            return vec![];
        };
        let sql = format!(
            "SELECT rowid, * FROM main.\"{}\" ORDER BY rowid DESC LIMIT 5000",
            table
        );
        let Ok(mut stmt) = db.prepare(&sql) else {
            return vec![];
        };
        let column_names: Vec<String> = stmt.column_names().iter().map(|s| s.to_string()).collect();
        let Ok(rows) = stmt.query_map([], |row| {
            let rowid = row.get::<_, i64>(0).unwrap_or(0);
            let mut columns: Vec<(String, Value)> = Vec::new();
            for (index, name) in column_names.iter().enumerate().skip(1) {
                let value = match row.get_ref(index) {
                    Ok(rusqlite::types::ValueRef::Integer(i)) => Value::from(i),
                    Ok(rusqlite::types::ValueRef::Real(f)) => Value::from(f),
                    Ok(rusqlite::types::ValueRef::Text(t)) => {
                        Value::from(String::from_utf8_lossy(t).to_string())
                    }
                    Ok(rusqlite::types::ValueRef::Blob(b)) => {
                        Value::from(String::from_utf8_lossy(b).to_string())
                    }
                    _ => Value::Null,
                };
                columns.push((name.clone(), value));
            }
            Ok((rowid, columns))
        }) else {
            return vec![];
        };
        let mut out = Vec::new();
        for row in rows.flatten() {
            let (rowid, columns) = row;
            let get = |keys: &[&str]| -> Option<i64> {
                keys.iter().find_map(|k| {
                    columns
                        .iter()
                        .find(|(name, _)| name == k)
                        .and_then(|(_, v)| parsing::int(v))
                })
            };
            let input = get(&["accumulated_input_tokens", "input_tokens"]).unwrap_or(0);
            let output = get(&["accumulated_output_tokens", "output_tokens"]).unwrap_or(0);
            let explicit_total = get(&["accumulated_total_tokens", "total_tokens"]);
            let total = explicit_total.unwrap_or(input + output);
            if total <= 0 {
                continue;
            }
            // The remainder beyond input+output is output-priced reasoning.
            let extra = (total - input - output).max(0);
            let model = model_name(&columns);
            let date = session_start(&columns);
            let Some(date) = date else { continue };
            if date < cutoff {
                continue;
            }
            out.push(LocalTurnRecord {
                date,
                usd: pricing::estimate_local_cost(&model, input, 0, 0, output + extra),
                dedupe_key: format!("goose:{}:{}", path.display(), rowid),
                model,
                tokens: total,
            });
        }
        out
    }

    fn model_name(columns: &[(String, Value)]) -> String {
        let column = |name: &str| -> Option<&Value> {
            columns.iter().find(|(n, _)| n == name).map(|(_, v)| v)
        };
        if let Some(json) = column("model_config_json").and_then(|v| v.as_str()) {
            if let Ok(Value::Object(object)) = serde_json::from_str::<Value>(json) {
                if let Some(name) = object.get("model_name").and_then(|v| v.as_str()) {
                    return name.to_string();
                }
                if let Some(name) = object.get("model").and_then(|v| v.as_str()) {
                    return name.to_string();
                }
            }
        }
        if let Some(provider) = column("provider_name").and_then(|v| v.as_str()) {
            return provider.to_string();
        }
        column("model")
            .and_then(|v| v.as_str())
            .unwrap_or("unknown")
            .to_string()
    }

    fn session_start(columns: &[(String, Value)]) -> Option<DateTime<Local>> {
        for key in ["created_at", "start_timestamp", "timestamp"] {
            if let Some(date) = columns
                .iter()
                .find(|(name, _)| name == key)
                .and_then(|(_, v)| parsing::parse_timestamp(v))
            {
                return Some(date);
            }
        }
        None
    }
}

// MARK: - Devin CLI

pub mod devin {
    use super::*;
    use chrono::NaiveDate;

    const MAX_TRANSCRIPT_FILE_BYTES: u64 = 64 * 1024 * 1024;
    const MAX_SCAN_READ_BYTES: u64 = 256 * 1024 * 1024;
    const MAX_SCAN_DIRECTORY_ENTRIES: usize = 20_000;
    const MAX_SCAN_READ_FILES: usize = 10_000;
    const MAX_TRANSCRIPT_STEPS: usize = 100_000;
    const MAX_MODEL_NAME_SCALARS: usize = 64;

    pub fn descriptor() -> LocalCostSource {
        LocalCostSource {
            counting_revision: 2,
            roots,
            read_turns,
        }
    }

    /// ~/.local/share/devin/cli/transcripts — the CLI's session transcript
    /// directory. DEVIN_CLI_TRANSCRIPTS_DIR overrides for tests/tools.
    fn roots() -> Vec<PathBuf> {
        if let Ok(custom) = std::env::var("DEVIN_CLI_TRANSCRIPTS_DIR") {
            if !custom.trim().is_empty() {
                let dir = PathBuf::from(custom);
                return existing_dirs(vec![dir]);
            }
        }
        let Some(home) = parsing::home() else {
            return vec![];
        };
        existing_dirs(vec![home.join(".local/share/devin/cli/transcripts")])
    }

    fn read_turns(roots: &[PathBuf], cutoff: DateTime<Local>) -> ScanOutcome {
        let mut turns = Vec::new();
        let mut completed = true;
        for root in roots {
            let result = scan_root(root, cutoff);
            completed &= result.completed;
            turns.extend(result.turns);
        }
        ScanOutcome { turns, completed }
    }

    struct RootScan {
        turns: Vec<LocalTurnRecord>,
        completed: bool,
    }

    /// Top-level *.json transcripts only (macOS enumerator skips
    /// descendants of directories), with the same byte/file caps.
    fn scan_root(root: &Path, cutoff: DateTime<Local>) -> RootScan {
        let cutoff_day = cutoff.date_naive();
        let Ok(read_dir) = std::fs::read_dir(root) else {
            return RootScan {
                turns: vec![],
                completed: false,
            };
        };
        let mut names: Vec<String> = Vec::new();
        let mut visited = 0usize;
        let mut enumeration_failed = false;
        for entry in read_dir {
            visited += 1;
            if visited > MAX_SCAN_DIRECTORY_ENTRIES {
                enumeration_failed = true;
                break;
            }
            let Ok(entry) = entry else {
                enumeration_failed = true;
                continue;
            };
            let path = entry.path();
            if path.is_dir() {
                continue;
            }
            if path.extension().and_then(|e| e.to_str()) == Some("json") {
                if let Some(name) = entry.file_name().to_str().map(|s| s.to_string()) {
                    names.push(name);
                }
            }
        }
        names.sort();

        let mut out = Vec::new();
        let mut completed = !enumeration_failed;
        let mut read_files = 0usize;
        let mut read_bytes = 0u64;
        for name in names {
            if read_files >= MAX_SCAN_READ_FILES || read_bytes >= MAX_SCAN_READ_BYTES {
                completed = false;
                break;
            }
            read_files += 1;
            let path = root.join(&name);
            let Ok(meta) = path.symlink_metadata() else {
                completed = false;
                continue;
            };
            if !meta.is_file()
                || meta.len() > MAX_TRANSCRIPT_FILE_BYTES.min(MAX_SCAN_READ_BYTES - read_bytes)
            {
                completed = false;
                continue;
            }
            let Ok(data) = std::fs::read(&path) else {
                completed = false;
                continue;
            };
            read_bytes += data.len() as u64;
            let Some(parsed) = transcript_steps(&data) else {
                completed = false;
                continue;
            };
            if !parsed.completed {
                completed = false;
            }
            for step in parsed.steps {
                let Some(date) = step.date else { continue };
                if step.tokens <= 0 {
                    continue;
                }
                let day: NaiveDate = date.date_naive();
                if day < cutoff_day {
                    continue;
                }
                out.push(LocalTurnRecord {
                    date,
                    model: step.model,
                    tokens: step.tokens,
                    usd: step.usd,
                    dedupe_key: format!("devin:{}:{}", name, step.ordinal),
                });
            }
        }
        RootScan {
            turns: out,
            completed,
        }
    }

    struct Step {
        date: Option<DateTime<Local>>,
        model: String,
        tokens: i64,
        usd: f64,
        ordinal: usize,
    }

    struct TranscriptParse {
        steps: Vec<Step>,
        completed: bool,
    }

    /// Extracts metric-bearing steps: (timestamp, model_name, tokens, usd).
    /// Steps without metrics (sysprompt, user turns) carry no usage and are
    /// skipped.
    fn transcript_steps(data: &[u8]) -> Option<TranscriptParse> {
        let Ok(Value::Object(root)) = serde_json::from_slice::<Value>(data) else {
            return None;
        };
        let raw_steps = root.get("steps")?.as_array()?;
        if raw_steps.len() > MAX_TRANSCRIPT_STEPS {
            return None;
        }
        let agent_model = root
            .get("agent")
            .and_then(|a| a.get("model_name"))
            .and_then(|v| v.as_str())
            .map(|s| s.to_string());

        let mut steps = Vec::with_capacity(raw_steps.len());
        let mut completed = true;
        for (index, raw) in raw_steps.iter().enumerate() {
            let (Some(step), Some(metrics)) = (
                raw.as_object(),
                raw.get("metrics").and_then(|m| m.as_object()),
            ) else {
                continue;
            };
            let int_value = |key: &str| -> i64 {
                match metrics.get(key) {
                    Some(Value::Number(n)) => n
                        .as_i64()
                        .or_else(|| {
                            n.as_f64()
                                .filter(|d| d.is_finite() && *d > 0.0)
                                .map(|d| d as i64)
                        })
                        .unwrap_or(0)
                        .max(0),
                    _ => 0,
                }
            };
            let prompt = int_value("prompt_tokens");
            let completion = int_value("completion_tokens");
            let cached = int_value("cached_tokens").min(prompt);
            let Some(tokens) = prompt.checked_add(completion) else {
                completed = false;
                continue;
            };
            if tokens <= 0 {
                continue;
            }
            let date = step
                .get("timestamp")
                .and_then(|v| v.as_str())
                .and_then(|s| {
                    DateTime::parse_from_rfc3339(s)
                        .ok()
                        .map(|dt| dt.with_timezone(&Local))
                });
            let model = sanitized_model_name(
                step.get("model_name")
                    .and_then(|v| v.as_str())
                    .map(|s| s.to_string())
                    .or_else(|| agent_model.clone())
                    .unwrap_or_else(|| "devin".to_string()),
            );
            let usd = pricing::devin_usd_cost(&model, prompt, cached, completion);
            if !usd.is_finite() {
                completed = false;
                continue;
            }
            steps.push(Step {
                date,
                model,
                tokens,
                usd,
                ordinal: index,
            });
        }
        Some(TranscriptParse { steps, completed })
    }

    /// Model names come from local files — clamp so garbage in a transcript
    /// cannot push unbounded names into cost-history.json.
    fn sanitized_model_name(raw: String) -> String {
        let cleaned: String = raw
            .chars()
            .filter(|c| !c.is_control())
            .collect::<String>()
            .trim()
            .to_string();
        if cleaned.is_empty() {
            return "devin".to_string();
        }
        cleaned.chars().take(MAX_MODEL_NAME_SCALARS).collect()
    }
}
