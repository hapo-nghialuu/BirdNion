use rusqlite::types::ValueRef;
use rusqlite::{params, Connection, OpenFlags, Row, Transaction};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;
use std::time::{Duration, Instant};

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct PriorityCursor {
    pub db_identity: String,
    pub coverage_since_epoch: i64,
    pub last_rowid: i64,
    pub target_rowid: i64,
    #[serde(default)]
    pub validation_rowid: i64,
    #[serde(default)]
    pub validation_target_rowid: i64,
    #[serde(default)]
    pub source_digests: BTreeMap<i64, String>,
    #[serde(default)]
    pub anchors: Vec<PriorityAnchor>,
    #[serde(default)]
    pub turns: BTreeMap<String, Option<String>>,
    #[serde(default)]
    pub request_sources: BTreeMap<String, BTreeMap<i64, PriorityRequest>>,
    #[serde(default)]
    pub priority_completions: BTreeMap<String, BTreeMap<i64, String>>,
    #[serde(default)]
    pub pending_completions: BTreeMap<String, BTreeMap<i64, String>>,
    #[serde(default)]
    pub pending_order: Vec<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct PriorityAnchor {
    pub rowid: i64,
    pub digest: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct PriorityRequest {
    pub timestamp: i64,
    pub model: Option<String>,
}

impl PriorityCursor {
    pub fn validate(&self) -> bool {
        let hex64 = |value: &str| value.len() == 64 && value.chars().all(|c| c.is_ascii_hexdigit());
        let request_turns: BTreeSet<_> = self.request_sources.keys().collect();
        let derived_turns: BTreeSet<_> = self.turns.keys().collect();
        let pending_turns: BTreeSet<_> = self.pending_completions.keys().collect();
        let order: BTreeSet<_> = self.pending_order.iter().collect();
        let retained_rowids = self
            .request_sources
            .values()
            .flat_map(|rows| rows.keys())
            .chain(
                self.priority_completions
                    .values()
                    .flat_map(|rows| rows.keys()),
            )
            .chain(
                self.pending_completions
                    .values()
                    .flat_map(|rows| rows.keys()),
            )
            .copied()
            .collect::<BTreeSet<_>>();
        self.coverage_since_epoch >= 0
            && self.last_rowid >= 0
            && self.target_rowid >= self.last_rowid
            && self.validation_rowid >= 0
            && self.validation_target_rowid >= self.validation_rowid
            && self.validation_target_rowid <= self.last_rowid
            && hex64(&self.db_identity)
            && self.pending_completions.len() <= 4096
            && self.pending_order.len() == self.pending_completions.len()
            && order.len() == self.pending_order.len()
            && order == pending_turns
            && request_turns == derived_turns
            && request_turns.is_disjoint(&pending_turns)
            && self.anchors.len() <= 4
            && self
                .source_digests
                .iter()
                .all(|(rowid, digest)| *rowid > 0 && *rowid <= self.last_rowid && hex64(digest))
            && self.source_digests.keys().copied().collect::<BTreeSet<_>>() == retained_rowids
            && self
                .anchors
                .windows(2)
                .all(|pair| pair[0].rowid < pair[1].rowid)
            && self.anchors.iter().all(|anchor| {
                anchor.rowid > 0 && anchor.rowid <= self.last_rowid && hex64(&anchor.digest)
            })
            && self.turns.iter().all(|(turn, model)| {
                hex64(turn) && model.as_ref().is_none_or(|value| valid_model(value))
            })
            && self.request_sources.iter().all(|(turn, rows)| {
                hex64(turn)
                    && !rows.is_empty()
                    && rows.iter().all(|(rowid, request)| {
                        *rowid > 0
                            && *rowid <= self.last_rowid
                            && request.timestamp >= self.coverage_since_epoch
                            && request
                                .model
                                .as_ref()
                                .is_none_or(|value| valid_model(value))
                    })
            })
            && self.priority_completions.iter().all(|(turn, rows)| {
                request_turns.contains(turn)
                    && rows.iter().all(|(rowid, model)| {
                        *rowid > 0 && *rowid <= self.last_rowid && valid_model(model)
                    })
            })
            && self.pending_completions.iter().all(|(turn, rows)| {
                hex64(turn)
                    && rows.iter().all(|(rowid, model)| {
                        *rowid > 0 && *rowid <= self.last_rowid && valid_model(model)
                    })
            })
            && self.derived_models_match()
    }

    fn derived_models_match(&self) -> bool {
        self.turns.iter().all(|(turn, model)| {
            let expected = self
                .priority_completions
                .get(turn)
                .and_then(|rows| rows.last_key_value().map(|(_, value)| value.clone()))
                .or_else(|| {
                    self.request_sources.get(turn).and_then(|rows| {
                        rows.iter()
                            .rev()
                            .find_map(|(_, request)| request.model.clone())
                    })
                });
            *model == expected
        })
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PriorityTurn {
    pub turn_hash: String,
    pub model: Option<String>,
    pub priority_request: bool,
}

pub enum ReadOutcome {
    Absent,
    Partial(PriorityCursor, Vec<PriorityTurn>),
    Complete(PriorityCursor, Vec<PriorityTurn>),
    Incomplete,
}

const ROW_BUDGET: usize = 4096;
const BYTE_BUDGET: usize = 16 * 1024 * 1024;
const BODY_BUDGET: usize = 1024 * 1024;
const TIME_BUDGET: Duration = Duration::from_millis(500);

struct LogRow {
    rowid: i64,
    timestamp: Option<i64>,
    body: Option<String>,
    body_oversized: bool,
}

fn parse_timestamp(value: ValueRef<'_>) -> Option<i64> {
    match value {
        ValueRef::Integer(value) => Some(value),
        ValueRef::Text(value) => {
            let text = std::str::from_utf8(value).ok()?.trim();
            text.parse().ok().or_else(|| {
                chrono::DateTime::parse_from_rfc3339(text)
                    .ok()
                    .map(|value| value.timestamp())
            })
        }
        _ => None,
    }
}

fn read_log_row(row: &Row<'_>) -> rusqlite::Result<LogRow> {
    let body = match row.get_ref(2)? {
        ValueRef::Text(value) if value.len() <= BODY_BUDGET => {
            std::str::from_utf8(value).ok().map(str::to_owned)
        }
        _ => None,
    };
    Ok(LogRow {
        rowid: row.get(0)?,
        timestamp: parse_timestamp(row.get_ref(1)?),
        body,
        body_oversized: row.get::<_, Option<i64>>(3)?.unwrap_or(0) > BODY_BUDGET as i64,
    })
}

fn digest(parts: &[&[u8]]) -> String {
    let mut hash = Sha256::new();
    for part in parts {
        hash.update(part);
        hash.update([0]);
    }
    hex::encode(hash.finalize())
}

pub fn turn_digest(id: &str) -> String {
    digest(&[b"codex-priority-turn-v1", id.as_bytes()])
}

fn prefix_value(prefix: &str, name: &str) -> Option<String> {
    let tail = prefix.split_once(&format!("{name}="))?.1;
    let value = tail
        .split(|char: char| char.is_whitespace() || [',', ']', ')'].contains(&char))
        .next()?;
    (!value.is_empty()).then(|| value.to_owned())
}

fn parse_request(body: &str) -> Option<(String, Option<String>)> {
    let marker = "websocket request:";
    let json = body.split_once(marker)?.1.trim();
    let value: Value = serde_json::from_str(json).ok()?;
    if value.get("type").and_then(Value::as_str) != Some("response.create")
        || value.get("service_tier").and_then(Value::as_str) != Some("priority")
    {
        return None;
    }
    let prefix = body.split_once(marker)?.0;
    let turn = prefix_value(prefix, "turn.id")
        .or_else(|| prefix_value(prefix, "turn_id"))
        .or_else(|| {
            value
                .get("turn_id")
                .and_then(Value::as_str)
                .map(str::to_owned)
        })?;
    let model = value
        .get("model")
        .and_then(Value::as_str)
        .filter(|value| valid_model(value))
        .map(str::to_owned);
    Some((turn_digest(&turn), model))
}

fn parse_completion(body: &str) -> Option<(String, String)> {
    let marker = "websocket event:";
    let (prefix, json) = body.split_once(marker)?;
    let value: Value = serde_json::from_str(json.trim()).ok()?;
    if value.get("type").and_then(Value::as_str) != Some("response.completed") {
        return None;
    }
    let response = value.get("response").unwrap_or(&value);
    let model = response
        .get("model")?
        .as_str()
        .filter(|value| valid_model(value))?
        .to_owned();
    let id = prefix_value(prefix, "turn.id").or_else(|| prefix_value(prefix, "turn_id"))?;
    Some((turn_digest(&id), model))
}

fn valid_model(value: &str) -> bool {
    !value.is_empty() && value.len() <= 128 && !value.chars().any(char::is_control)
}

fn database_identity(path: &Path) -> Option<String> {
    let metadata = std::fs::metadata(path).ok()?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        Some(digest(&[
            metadata.dev().to_string().as_bytes(),
            metadata.ino().to_string().as_bytes(),
        ]))
    }
    #[cfg(not(unix))]
    {
        Some(digest(&[
            b"codex-logs-2",
            metadata.len().to_string().as_bytes(),
        ]))
    }
}

fn row_digest(timestamp: i64, body: &str) -> String {
    let mut hash = Sha256::new();
    hash.update(timestamp.to_string().as_bytes());
    hash.update(b"\n");
    hash.update(body.as_bytes());
    hex::encode(hash.finalize())
}

fn empty_cursor(identity: String, coverage_since_epoch: i64) -> PriorityCursor {
    PriorityCursor {
        db_identity: identity,
        coverage_since_epoch,
        last_rowid: 0,
        target_rowid: 0,
        validation_rowid: 0,
        validation_target_rowid: 0,
        source_digests: BTreeMap::new(),
        anchors: Vec::new(),
        turns: BTreeMap::new(),
        request_sources: BTreeMap::new(),
        priority_completions: BTreeMap::new(),
        pending_completions: BTreeMap::new(),
        pending_order: Vec::new(),
    }
}

fn rebuild_turns(cursor: &mut PriorityCursor) {
    cursor.turns = cursor
        .request_sources
        .keys()
        .map(|turn| {
            let model = cursor
                .priority_completions
                .get(turn)
                .and_then(|rows| rows.last_key_value().map(|(_, model)| model.clone()))
                .or_else(|| {
                    cursor.request_sources.get(turn).and_then(|rows| {
                        rows.iter()
                            .rev()
                            .find_map(|(_, request)| request.model.clone())
                    })
                });
            (turn.clone(), model)
        })
        .collect();
}

fn add_pending(cursor: &mut PriorityCursor, turn: String, rows: BTreeMap<i64, String>) {
    if rows.is_empty() || cursor.pending_completions.contains_key(&turn) {
        return;
    }
    cursor.pending_order.push(turn.clone());
    cursor.pending_completions.insert(turn, rows);
    while cursor.pending_order.len() > 4096 {
        let oldest = cursor.pending_order.remove(0);
        if let Some(rows) = cursor.pending_completions.remove(&oldest) {
            for rowid in rows.keys() {
                cursor.source_digests.remove(rowid);
            }
        }
    }
}

fn prune_to(cursor: &mut PriorityCursor, coverage_since_epoch: i64) {
    if coverage_since_epoch <= cursor.coverage_since_epoch {
        return;
    }
    let mut removed = Vec::new();
    cursor.request_sources.retain(|turn, rows| {
        rows.retain(|rowid, request| {
            let keep = request.timestamp >= coverage_since_epoch;
            if !keep {
                cursor.source_digests.remove(rowid);
            }
            keep
        });
        if rows.is_empty() {
            removed.push(turn.clone());
            false
        } else {
            true
        }
    });
    for turn in removed {
        if let Some(rows) = cursor.priority_completions.remove(&turn) {
            add_pending(cursor, turn, rows);
        }
    }
    cursor.coverage_since_epoch = coverage_since_epoch;
    rebuild_turns(cursor);
}

fn validate_rows(transaction: &Transaction<'_>, cursor: &PriorityCursor) -> rusqlite::Result<bool> {
    for anchor in &cursor.anchors {
        let row = transaction.query_row(
            "SELECT rowid, ts, CASE WHEN typeof(feedback_log_body) = 'text' AND length(CAST(feedback_log_body AS blob)) <= 1048576 THEN feedback_log_body END, CASE WHEN typeof(feedback_log_body) = 'text' THEN length(CAST(feedback_log_body AS blob)) ELSE 0 END FROM logs WHERE rowid = ?1",
            [anchor.rowid],
            read_log_row,
        );
        let Ok(LogRow {
            timestamp: Some(timestamp),
            body: Some(body),
            ..
        }) = row
        else {
            return Ok(false);
        };
        if row_digest(timestamp, &body) != anchor.digest {
            return Ok(false);
        }
    }
    Ok(true)
}

fn capture_anchors(
    transaction: &Transaction<'_>,
    through_rowid: i64,
) -> rusqlite::Result<Vec<PriorityAnchor>> {
    if through_rowid == 0 {
        return Ok(Vec::new());
    }
    let mut rowids = BTreeSet::new();
    for numerator in [1_i64, 2, 3, 4] {
        rowids.insert((through_rowid * numerator + 3) / 4);
    }
    let mut anchors = Vec::with_capacity(rowids.len());
    for target in rowids {
        let row = transaction.query_row(
            "SELECT rowid, ts, CASE WHEN typeof(feedback_log_body) = 'text' AND length(CAST(feedback_log_body AS blob)) <= 1048576 THEN feedback_log_body END, CASE WHEN typeof(feedback_log_body) = 'text' THEN length(CAST(feedback_log_body AS blob)) ELSE 0 END FROM logs WHERE rowid >= ?1 AND rowid <= ?2 ORDER BY rowid LIMIT 1",
            params![target, through_rowid],
            read_log_row,
        );
        if let Ok(LogRow {
            rowid,
            timestamp: Some(timestamp),
            body: Some(body),
            ..
        }) = row
        {
            anchors.push(PriorityAnchor {
                rowid,
                digest: row_digest(timestamp, &body),
            });
        }
    }
    anchors.dedup_by_key(|anchor| anchor.rowid);
    Ok(anchors)
}

enum SourceValidation {
    Complete,
    Partial,
    Mismatch,
}

fn validate_sources(
    transaction: &Transaction<'_>,
    cursor: &mut PriorityCursor,
) -> rusqlite::Result<SourceValidation> {
    let started = Instant::now();
    let batch = cursor
        .source_digests
        .range((cursor.validation_rowid + 1)..=cursor.validation_target_rowid)
        .take(ROW_BUDGET + 1)
        .map(|(rowid, digest)| (*rowid, digest.clone()))
        .collect::<Vec<_>>();
    let mut consumed_bytes = 0usize;
    for chunk in batch[..batch.len().min(ROW_BUDGET)].chunks(512) {
        if started.elapsed() >= TIME_BUDGET {
            return Ok(SourceValidation::Partial);
        }
        let placeholders = std::iter::repeat_n("?", chunk.len())
            .collect::<Vec<_>>()
            .join(",");
        let sql = format!(
            "SELECT rowid, ts, CASE WHEN typeof(feedback_log_body) = 'text' \
             AND length(CAST(feedback_log_body AS blob)) <= 1048576 \
             THEN feedback_log_body END, CASE WHEN typeof(feedback_log_body) = 'text' \
             THEN length(CAST(feedback_log_body AS blob)) ELSE 0 END \
             FROM logs WHERE rowid IN ({placeholders}) ORDER BY rowid"
        );
        let expected = chunk.iter().cloned().collect::<BTreeMap<_, _>>();
        let mut seen = BTreeSet::new();
        let mut statement = transaction.prepare(&sql)?;
        let rows = statement.query_map(
            rusqlite::params_from_iter(chunk.iter().map(|(rowid, _)| rowid)),
            read_log_row,
        )?;
        for row in rows {
            if started.elapsed() >= TIME_BUDGET {
                return Ok(SourceValidation::Partial);
            }
            let LogRow {
                rowid,
                timestamp: Some(timestamp),
                body: Some(body),
                body_oversized: false,
            } = row?
            else {
                return Ok(SourceValidation::Mismatch);
            };
            if consumed_bytes.saturating_add(body.len()) > BYTE_BUDGET {
                return Ok(SourceValidation::Partial);
            }
            consumed_bytes += body.len();
            if expected.get(&rowid) != Some(&row_digest(timestamp, &body)) {
                return Ok(SourceValidation::Mismatch);
            }
            seen.insert(rowid);
            cursor.validation_rowid = rowid;
        }
        if seen.len() != expected.len() {
            return Ok(SourceValidation::Mismatch);
        }
    }
    if batch.len() > ROW_BUDGET {
        return Ok(SourceValidation::Partial);
    }
    if cursor.validation_rowid < cursor.validation_target_rowid
        && cursor
            .source_digests
            .range((cursor.validation_rowid + 1)..=cursor.validation_target_rowid)
            .next()
            .is_some()
    {
        Ok(SourceValidation::Partial)
    } else {
        cursor.validation_rowid = cursor.validation_target_rowid;
        Ok(SourceValidation::Complete)
    }
}

fn consume_rows(
    transaction: &Transaction<'_>,
    cursor: &mut PriorityCursor,
    start_rowid: i64,
    through_rowid: i64,
) -> rusqlite::Result<(Vec<PriorityTurn>, bool)> {
    // Page by rowid before filtering. A query that LIMITs only matching rows
    // can still scan an arbitrarily large SQLite tail when the optional ts
    // index is absent. This makes every call advance across at most 4096 DB
    // rows, including old or unrelated diagnostics.
    let mut statement = transaction.prepare(
        "SELECT rowid, ts, CASE WHEN typeof(feedback_log_body) = 'text' AND length(CAST(feedback_log_body AS blob)) <= 1048576 THEN feedback_log_body END, CASE WHEN typeof(feedback_log_body) = 'text' THEN length(CAST(feedback_log_body AS blob)) ELSE 0 END FROM logs \
         WHERE rowid > ?1 AND rowid <= ?2 \
         ORDER BY rowid ASC LIMIT 4097",
    )?;
    let rows = statement.query_map(params![start_rowid, through_rowid], read_log_row)?;
    let mut events = Vec::new();
    let mut last_processed_rowid = start_rowid;
    let mut has_more = false;
    let mut consumed_bytes = 0usize;
    let started = Instant::now();
    for (index, row) in rows.enumerate() {
        let row = row?;
        let body_bytes = row.body.as_ref().map_or(0, |body| body.len());
        if index == ROW_BUDGET
            || started.elapsed() >= TIME_BUDGET
            || consumed_bytes.saturating_add(body_bytes) > BYTE_BUDGET
        {
            has_more = true;
            break;
        }
        consumed_bytes += body_bytes;
        last_processed_rowid = row.rowid;
        if row.body_oversized
            && row
                .timestamp
                .is_some_and(|timestamp| timestamp >= cursor.coverage_since_epoch)
        {
            // The bounded reader cannot prove whether a current oversized row
            // carries a Priority request/completion. Do not advance and publish
            // base pricing as if the row were unrelated.
            return Err(rusqlite::Error::InvalidQuery);
        }
        let (Some(timestamp), Some(body)) = (row.timestamp, row.body) else {
            continue;
        };
        if timestamp < cursor.coverage_since_epoch {
            continue;
        }
        if let Some((turn, model)) = parse_request(&body) {
            if let Some(old) = cursor.request_sources.get(&turn) {
                for rowid in old.keys() {
                    cursor.source_digests.remove(rowid);
                }
            }
            cursor
                .source_digests
                .insert(row.rowid, row_digest(timestamp, &body));
            cursor.request_sources.insert(
                turn.clone(),
                BTreeMap::from([(row.rowid, PriorityRequest { timestamp, model })]),
            );
            if let Some(pending) = cursor.pending_completions.remove(&turn) {
                cursor.pending_order.retain(|value| value != &turn);
                cursor.priority_completions.insert(turn.clone(), pending);
            }
            events.push(PriorityTurn {
                turn_hash: turn,
                model: None,
                priority_request: true,
            });
        } else if let Some((turn, model)) = parse_completion(&body) {
            let existing = if cursor.request_sources.contains_key(&turn) {
                cursor.priority_completions.get(&turn)
            } else {
                cursor.pending_completions.get(&turn)
            };
            if let Some(old) = existing {
                for rowid in old.keys() {
                    cursor.source_digests.remove(rowid);
                }
            }
            cursor
                .source_digests
                .insert(row.rowid, row_digest(timestamp, &body));
            let target = if cursor.request_sources.contains_key(&turn) {
                &mut cursor.priority_completions
            } else {
                if !cursor.pending_completions.contains_key(&turn) {
                    cursor.pending_order.push(turn.clone());
                }
                &mut cursor.pending_completions
            };
            target.insert(turn.clone(), BTreeMap::from([(row.rowid, model.clone())]));
            while cursor.pending_order.len() > 4096 {
                let oldest = cursor.pending_order.remove(0);
                if let Some(rows) = cursor.pending_completions.remove(&oldest) {
                    for rowid in rows.keys() {
                        cursor.source_digests.remove(rowid);
                    }
                }
            }
            events.push(PriorityTurn {
                turn_hash: turn,
                model: Some(model),
                priority_request: false,
            });
        }
    }
    cursor.last_rowid = if has_more {
        last_processed_rowid
    } else {
        through_rowid
    };
    rebuild_turns(cursor);
    Ok((events, !has_more))
}

fn read_impl<F, G, H>(
    path: &Path,
    previous: Option<&PriorityCursor>,
    coverage_since_epoch: i64,
    after_open: F,
    after_high_water: G,
    after_query: H,
) -> ReadOutcome
where
    F: FnOnce(),
    G: FnOnce(),
    H: FnOnce(),
{
    if !path.exists() {
        return if previous.is_some() {
            ReadOutcome::Incomplete
        } else {
            ReadOutcome::Absent
        };
    }
    let Some(identity_before_open) = database_identity(path) else {
        return ReadOutcome::Incomplete;
    };
    let mut connection = match Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    ) {
        Ok(value) => value,
        Err(_) => return ReadOutcome::Incomplete,
    };
    if connection.busy_timeout(Duration::from_millis(250)).is_err() {
        return ReadOutcome::Incomplete;
    }
    after_open();
    if database_identity(path).as_deref() != Some(identity_before_open.as_str()) {
        return ReadOutcome::Incomplete;
    }
    let transaction = match connection.transaction() {
        Ok(value) => value,
        Err(_) => return ReadOutcome::Incomplete,
    };
    let observed_high_water =
        match transaction.query_row("SELECT coalesce(max(rowid), 0) FROM logs", [], |row| {
            row.get::<_, i64>(0)
        }) {
            Ok(value) => value,
            Err(_) => return ReadOutcome::Incomplete,
        };
    after_high_water();
    let through_rowid = previous
        .filter(|cursor| {
            cursor.validation_target_rowid > 0 || cursor.last_rowid < cursor.target_rowid
        })
        .map_or(observed_high_water, |cursor| cursor.target_rowid);
    let reusable = if let Some(cursor) = previous {
        if cursor.validate()
            && cursor.db_identity == identity_before_open
            && cursor.coverage_since_epoch <= coverage_since_epoch
            && cursor.last_rowid <= through_rowid
        {
            match validate_rows(&transaction, cursor) {
                Ok(value) => value,
                Err(_) => return ReadOutcome::Incomplete,
            }
        } else {
            false
        }
    } else {
        false
    };
    let mut cursor = if reusable {
        previous.cloned().unwrap()
    } else {
        empty_cursor(identity_before_open.clone(), coverage_since_epoch)
    };
    if reusable && cursor.validation_target_rowid > 0 {
        match validate_sources(&transaction, &mut cursor) {
            Ok(SourceValidation::Partial) => {
                if !cursor.validate() || transaction.commit().is_err() {
                    return ReadOutcome::Incomplete;
                }
                return ReadOutcome::Partial(cursor, Vec::new());
            }
            Ok(SourceValidation::Mismatch) => {
                cursor = empty_cursor(identity_before_open.clone(), coverage_since_epoch);
            }
            Ok(SourceValidation::Complete) => {
                cursor.validation_rowid = 0;
                cursor.validation_target_rowid = 0;
                after_query();
                if database_identity(path).as_deref() != Some(identity_before_open.as_str())
                    || !cursor.validate()
                    || transaction.commit().is_err()
                {
                    return ReadOutcome::Incomplete;
                }
                return ReadOutcome::Complete(cursor, Vec::new());
            }
            Err(_) => return ReadOutcome::Incomplete,
        }
    }
    cursor.validation_rowid = 0;
    cursor.validation_target_rowid = 0;
    cursor.target_rowid = through_rowid;
    prune_to(&mut cursor, coverage_since_epoch);
    let start_rowid = cursor.last_rowid;
    let (events, complete) =
        match consume_rows(&transaction, &mut cursor, start_rowid, through_rowid) {
            Ok(value) => value,
            Err(_) => return ReadOutcome::Incomplete,
        };
    cursor.anchors = match capture_anchors(&transaction, cursor.last_rowid) {
        Ok(value) => value,
        Err(_) => return ReadOutcome::Incomplete,
    };
    after_query();
    if database_identity(path).as_deref() != Some(identity_before_open.as_str()) {
        return ReadOutcome::Incomplete;
    }
    if complete {
        cursor.validation_target_rowid = cursor
            .source_digests
            .last_key_value()
            .map_or(0, |(rowid, _)| *rowid);
    }
    if !cursor.validate() || transaction.commit().is_err() {
        return ReadOutcome::Incomplete;
    }
    if complete && cursor.validation_target_rowid == 0 {
        ReadOutcome::Complete(cursor, events)
    } else {
        ReadOutcome::Partial(cursor, events)
    }
}

pub fn read(
    path: &Path,
    previous: Option<&PriorityCursor>,
    coverage_since_epoch: i64,
) -> ReadOutcome {
    read_impl(path, previous, coverage_since_epoch, || {}, || {}, || {})
}

#[cfg(test)]
fn read_with_hooks<F, G, H>(
    path: &Path,
    previous: Option<&PriorityCursor>,
    coverage_since_epoch: i64,
    after_open: F,
    after_high_water: G,
    after_query: H,
) -> ReadOutcome
where
    F: FnOnce(),
    G: FnOnce(),
    H: FnOnce(),
{
    read_impl(
        path,
        previous,
        coverage_since_epoch,
        after_open,
        after_high_water,
        after_query,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT_DB: AtomicU64 = AtomicU64::new(1);

    fn db_path(label: &str) -> std::path::PathBuf {
        std::env::temp_dir().join(format!(
            "birdnion-priority-{}-{label}-{}.sqlite",
            std::process::id(),
            NEXT_DB.fetch_add(1, Ordering::Relaxed)
        ))
    }

    fn create_db(path: &Path) -> Connection {
        let _ = std::fs::remove_file(path);
        let db = Connection::open(path).unwrap();
        db.execute("CREATE TABLE logs(ts INTEGER, feedback_log_body TEXT)", [])
            .unwrap();
        db
    }

    fn request(turn: &str, model: &str) -> String {
        format!(
            r#"turn.id={turn} websocket request: {{"type":"response.create","service_tier":"priority","model":"{model}"}}"#
        )
    }

    fn completion(turn: &str, model: &str) -> String {
        format!(
            r#"turn.id={turn} websocket event: {{"type":"response.completed","response":{{"model":"{model}"}}}}"#
        )
    }

    fn read_complete(
        path: &Path,
        previous: Option<&PriorityCursor>,
        cutoff: i64,
    ) -> (PriorityCursor, Vec<PriorityTurn>) {
        let mut cursor = previous.cloned();
        let mut events = Vec::new();
        for _ in 0..100_000 {
            match read(path, cursor.as_ref(), cutoff) {
                ReadOutcome::Partial(next, page) => {
                    cursor = Some(next);
                    events.extend(page);
                }
                ReadOutcome::Complete(next, page) => {
                    events.extend(page);
                    return (next, events);
                }
                ReadOutcome::Absent | ReadOutcome::Incomplete => {
                    panic!("Priority scan did not complete")
                }
            }
        }
        panic!("Priority scan exceeded bounded test iterations")
    }

    #[test]
    fn parses_priority_request_without_persisting_raw_turn() {
        let raw = r#"turn.id=private prefix websocket request: {"type":"response.create","service_tier":"priority"}"#;
        let id = parse_request(raw).unwrap().0;
        assert_eq!(id.len(), 64);
        assert!(!id.contains("response.create"));
    }

    #[test]
    fn cursor_survives_append_and_anchor_rejects_rewrite() {
        let path = db_path("append-rewrite");
        let db = create_db(&path);
        db.execute(
            "INSERT INTO logs VALUES(1788220800, ?1)",
            [r#"turn.id=secret websocket request: {"type":"response.create","service_tier":"priority"}"#],
        )
        .unwrap();
        drop(db);
        let cutoff = 1_700_000_000;
        let (first, _) = read_complete(&path, None, cutoff);
        assert_eq!(first.turns.len(), 1);
        assert!(!serde_json::to_string(&first).unwrap().contains("secret"));

        let db = Connection::open(&path).unwrap();
        db.execute("INSERT INTO logs VALUES(1788220801, 'unrelated')", [])
            .unwrap();
        drop(db);
        let _ = read_complete(&path, Some(&first), cutoff);

        let db = Connection::open(&path).unwrap();
        db.execute(
            "UPDATE logs SET feedback_log_body='rewritten' WHERE rowid=1",
            [],
        )
        .unwrap();
        drop(db);
        let _ = read_complete(&path, Some(&first), cutoff);
        std::fs::remove_file(path).ok();
    }

    #[test]
    fn completion_model_wins_and_warm_scan_reads_only_delta() {
        let path = db_path("delta");
        let db = create_db(&path);
        db.execute(
            "INSERT INTO logs VALUES(1788220800, ?1)",
            [request("private-turn", "gpt-5.4")],
        )
        .unwrap();
        drop(db);
        let cutoff = 1_700_000_000;
        let (first, first_events) = read_complete(&path, None, cutoff);
        assert_eq!(first_events.len(), 1);

        let db = Connection::open(&path).unwrap();
        db.execute(
            "INSERT INTO logs VALUES(1788220801, ?1)",
            [completion("private-turn", "gpt-5.5")],
        )
        .unwrap();
        drop(db);
        let (second, delta) = read_complete(&path, Some(&first), cutoff);
        assert_eq!(delta.len(), 1);
        assert_eq!(
            second.turns.get(&turn_digest("private-turn")),
            Some(&Some("gpt-5.5".into()))
        );
        assert!(!serde_json::to_string(&second)
            .unwrap()
            .contains("private-turn"));
        std::fs::remove_file(path).ok();
    }

    #[test]
    fn advancing_cutoff_prunes_old_requests_without_full_rebuild() {
        let path = db_path("prune");
        let db = create_db(&path);
        db.execute(
            "INSERT INTO logs VALUES(1767225600, ?1)",
            [request("old", "gpt-5.4")],
        )
        .unwrap();
        db.execute(
            "INSERT INTO logs VALUES(1788220800, ?1)",
            [request("recent", "gpt-5.4")],
        )
        .unwrap();
        drop(db);
        let (first, _) = read_complete(&path, None, 1_700_000_000);
        let september_cutoff = 1_780_000_000;
        let (second, delta) = read_complete(&path, Some(&first), september_cutoff);
        assert!(delta.is_empty());
        assert!(!second.turns.contains_key(&turn_digest("old")));
        assert!(second.turns.contains_key(&turn_digest("recent")));
        assert_eq!(second.last_rowid, first.last_rowid);
        std::fs::remove_file(path).ok();
    }

    #[test]
    fn pending_completion_retention_is_capped_at_4096() {
        let mut cursor = empty_cursor("a".repeat(64), 0);
        for index in 0..4097 {
            add_pending(
                &mut cursor,
                turn_digest(&format!("turn-{index}")),
                BTreeMap::from([(index + 1, "gpt-5.4".into())]),
            );
        }
        assert_eq!(cursor.pending_order.len(), 4096);
        assert_eq!(cursor.pending_completions.len(), 4096);
        assert!(!cursor
            .pending_completions
            .contains_key(&turn_digest("turn-0")));
    }

    #[test]
    fn row_budget_resumes_without_losing_partial_state() {
        let path = db_path("budget");
        let mut db = create_db(&path);
        let transaction = db.transaction().unwrap();
        for index in 0..=ROW_BUDGET {
            transaction
                .execute(
                    "INSERT INTO logs VALUES(1788220800, ?1)",
                    [request(&format!("turn-{index}"), "gpt-5.4")],
                )
                .unwrap();
        }
        transaction.commit().unwrap();
        drop(db);
        let ReadOutcome::Partial(first, events) = read(&path, None, 1_700_000_000) else {
            panic!()
        };
        assert!(!events.is_empty());
        assert!(events.len() <= ROW_BUDGET);
        assert_eq!(first.turns.len(), events.len());
        let db = Connection::open(&path).unwrap();
        db.execute(
            "INSERT INTO logs VALUES(1788220801, ?1)",
            [request("concurrent-append", "gpt-5.4")],
        )
        .unwrap();
        drop(db);
        let (second, delta) = read_complete(&path, Some(&first), 1_700_000_000);
        assert_eq!(delta.len(), ROW_BUDGET + 1 - events.len());
        assert_eq!(second.turns.len(), ROW_BUDGET + 1);
        assert!(!second.turns.contains_key(&turn_digest("concurrent-append")));
        let (third, delta) = read_complete(&path, Some(&second), 1_700_000_000);
        assert_eq!(delta.len(), 1);
        assert!(third.turns.contains_key(&turn_digest("concurrent-append")));
        std::fs::remove_file(path).ok();
    }

    #[test]
    fn cold_scan_revalidates_rows_changed_between_ingest_and_publish() {
        let path = db_path("cold-validation-race");
        let mut db = create_db(&path);
        let transaction = db.transaction().unwrap();
        for index in 0..=ROW_BUDGET {
            transaction
                .execute(
                    "INSERT INTO logs VALUES(1788220800, ?1)",
                    [request(&format!("turn-{index}"), "gpt-5.4")],
                )
                .unwrap();
        }
        transaction.commit().unwrap();
        drop(db);

        let cutoff = 1_700_000_000;
        let mut cursor = None;
        let awaiting_validation = loop {
            let ReadOutcome::Partial(next, _) = read(&path, cursor.as_ref(), cutoff) else {
                panic!("cold scan should validate retained sources before publish")
            };
            if next.validation_target_rowid > 0 {
                break next;
            }
            cursor = Some(next);
        };
        assert!(awaiting_validation.validation_target_rowid > 0);

        let anchor_rows = awaiting_validation
            .anchors
            .iter()
            .map(|anchor| anchor.rowid)
            .collect::<BTreeSet<_>>();
        let changed_row = (1..=ROW_BUDGET as i64)
            .find(|rowid| !anchor_rows.contains(rowid))
            .unwrap();
        let replaced_turn = format!("turn-{}", changed_row - 1);
        let db = Connection::open(&path).unwrap();
        db.execute(
            "UPDATE logs SET feedback_log_body=?1 WHERE rowid=?2",
            params![request("replacement", "gpt-5.6"), changed_row],
        )
        .unwrap();
        drop(db);

        let (rebuilt, _) = read_complete(&path, Some(&awaiting_validation), cutoff);
        assert!(rebuilt.turns.contains_key(&turn_digest("replacement")));
        assert!(!rebuilt.turns.contains_key(&turn_digest(&replaced_turn)));
        std::fs::remove_file(path).ok();
    }

    #[test]
    fn distributed_anchor_rewrite_forces_correct_rebuild() {
        let path = db_path("anchors");
        let db = create_db(&path);
        for index in 0..8 {
            db.execute(
                "INSERT INTO logs VALUES(1788220800, ?1)",
                [request(&format!("turn-{index}"), "gpt-5.4")],
            )
            .unwrap();
        }
        drop(db);
        let cutoff = 1_700_000_000;
        let (first, _) = read_complete(&path, None, cutoff);
        assert_eq!(first.anchors.len(), 4);
        let changed_row = first.anchors[0].rowid;
        let db = Connection::open(&path).unwrap();
        db.execute(
            "UPDATE logs SET feedback_log_body=?1 WHERE rowid=?2",
            params![request("replacement", "gpt-5.5"), changed_row],
        )
        .unwrap();
        drop(db);
        let (second, _) = read_complete(&path, Some(&first), cutoff);
        assert!(!second
            .turns
            .contains_key(&turn_digest(&format!("turn-{}", changed_row - 1))));
        assert!(second.turns.contains_key(&turn_digest("replacement")));
        std::fs::remove_file(path).ok();
    }

    #[test]
    fn frozen_high_water_defers_concurrent_append() {
        let path = db_path("frozen");
        let db = create_db(&path);
        db.pragma_update(None, "journal_mode", "WAL").unwrap();
        db.execute(
            "INSERT INTO logs VALUES(1788220800, ?1)",
            [request("first", "gpt-5.4")],
        )
        .unwrap();
        drop(db);
        let append_path = path.clone();
        let outcome = read_with_hooks(
            &path,
            None,
            1_700_000_000,
            || {},
            move || {
                let db = Connection::open(append_path).unwrap();
                db.execute(
                    "INSERT INTO logs VALUES(1788220801, ?1)",
                    [request("second", "gpt-5.4")],
                )
                .unwrap();
            },
            || {},
        );
        let ReadOutcome::Partial(partial, events) = outcome else {
            panic!()
        };
        assert_eq!(events.len(), 1);
        assert_eq!(partial.last_rowid, 1);
        let (cursor, _) = read_complete(&path, Some(&partial), 1_700_000_000);
        assert_eq!(cursor.last_rowid, 1);
        std::fs::remove_file(path).ok();
    }

    #[cfg(unix)]
    #[test]
    fn identity_changes_after_open_or_query_fail_closed() {
        for replace_after_query in [false, true] {
            let path = db_path("identity");
            let db = create_db(&path);
            db.execute(
                "INSERT INTO logs VALUES(1788220800, ?1)",
                [request("first", "gpt-5.4")],
            )
            .unwrap();
            drop(db);
            let replacement = db_path("replacement");
            drop(create_db(&replacement));
            let target = path.clone();
            let replace = move || std::fs::rename(replacement, target).unwrap();
            let outcome = if replace_after_query {
                read_with_hooks(&path, None, 1_700_000_000, || {}, || {}, replace)
            } else {
                read_with_hooks(&path, None, 1_700_000_000, replace, || {}, || {})
            };
            assert!(matches!(outcome, ReadOutcome::Incomplete));
            std::fs::remove_file(path).ok();
        }
    }

    #[test]
    fn validate_rejects_invalid_completion_entries() {
        let mut cursor = PriorityCursor {
            db_identity: "a".repeat(64),
            coverage_since_epoch: 0,
            last_rowid: 1,
            target_rowid: 1,
            validation_rowid: 0,
            validation_target_rowid: 0,
            source_digests: BTreeMap::new(),
            anchors: vec![PriorityAnchor {
                rowid: 1,
                digest: "b".repeat(64),
            }],
            turns: BTreeMap::new(),
            request_sources: BTreeMap::new(),
            priority_completions: BTreeMap::from([(
                "short".into(),
                BTreeMap::from([(1, "gpt-5".into())]),
            )]),
            pending_completions: BTreeMap::new(),
            pending_order: Vec::new(),
        };
        assert!(!cursor.validate());
        cursor.priority_completions =
            BTreeMap::from([("c".repeat(64), BTreeMap::from([(1, "bad\nmodel".into())]))]);
        assert!(!cursor.validate());
    }

    #[test]
    fn non_anchor_request_rewrite_and_completion_delete_rebuild_state() {
        let path = db_path("all-sources");
        let db = create_db(&path);
        for index in 0..8 {
            db.execute(
                "INSERT INTO logs VALUES(1788220800, ?1)",
                [request(&format!("turn-{index}"), "gpt-5.4")],
            )
            .unwrap();
        }
        db.execute(
            "INSERT INTO logs VALUES(1788220801, ?1)",
            [completion("turn-0", "gpt-5.5")],
        )
        .unwrap();
        drop(db);
        let cutoff = 1_700_000_000;
        let (first, _) = read_complete(&path, None, cutoff);
        let anchor_rows = first
            .anchors
            .iter()
            .map(|anchor| anchor.rowid)
            .collect::<BTreeSet<_>>();
        let request_row = (1..=8).find(|rowid| !anchor_rows.contains(rowid)).unwrap();
        let replaced_turn = format!("turn-{}", request_row - 1);
        let db = Connection::open(&path).unwrap();
        db.execute(
            "UPDATE logs SET feedback_log_body=?1 WHERE rowid=?2",
            params![request("replacement", "gpt-5.6"), request_row],
        )
        .unwrap();
        db.execute("DELETE FROM logs WHERE rowid=9", []).unwrap();
        drop(db);
        let (second, _) = read_complete(&path, Some(&first), cutoff);
        assert!(second.turns.contains_key(&turn_digest("replacement")));
        assert!(!second.turns.contains_key(&turn_digest(&replaced_turn)));
        assert_ne!(
            second.turns.get(&turn_digest("turn-0")),
            Some(&Some("gpt-5.5".into()))
        );
        std::fs::remove_file(path).ok();
    }

    #[test]
    fn text_timestamp_and_malformed_cells_are_skipped_with_progress() {
        let path = db_path("cell-types");
        let db = create_db(&path);
        db.execute(
            "INSERT INTO logs(ts, feedback_log_body) VALUES(?1, ?2)",
            params!["1788220800", request("text-ts", "gpt-5.4")],
        )
        .unwrap();
        db.execute(
            "INSERT INTO logs(ts, feedback_log_body) VALUES(NULL, ?1)",
            [request("null-ts", "gpt-5.4")],
        )
        .unwrap();
        db.execute(
            "INSERT INTO logs(ts, feedback_log_body) VALUES(1788220800, NULL)",
            [],
        )
        .unwrap();
        db.execute(
            "INSERT INTO logs(ts, feedback_log_body) VALUES(1788220800, ?1)",
            params![vec![0xff_u8, 0x00]],
        )
        .unwrap();
        db.execute(
            "INSERT INTO logs(ts, feedback_log_body) VALUES('not-a-time', 'malformed')",
            [],
        )
        .unwrap();
        db.execute(
            "INSERT INTO logs(ts, feedback_log_body) VALUES(1788220800, ?1)",
            [r#"turn.id=bad-model websocket event: {"type":"response.completed","response":{"model":"bad\nmodel"}}"#],
        )
        .unwrap();
        db.execute(
            "INSERT INTO logs(ts, feedback_log_body) VALUES(1788220801, ?1)",
            [request("after-malformed", "gpt-5.5")],
        )
        .unwrap();
        drop(db);
        let (cursor, events) = read_complete(&path, None, 1_700_000_000);
        assert_eq!(cursor.last_rowid, 7);
        assert_eq!(events.len(), 2);
        assert!(cursor.turns.contains_key(&turn_digest("text-ts")));
        assert!(cursor.turns.contains_key(&turn_digest("after-malformed")));
        std::fs::remove_file(path).ok();
    }

    #[test]
    fn current_huge_body_fails_closed_instead_of_publishing_base_pricing() {
        let path = db_path("huge-body");
        let db = create_db(&path);
        let oversized_priority = format!(
            r#"turn.id=huge websocket request: {{"type":"response.create","service_tier":"priority","model":"gpt-5.4","context":"{}"}}"#,
            "x".repeat(BODY_BUDGET)
        );
        db.execute(
            "INSERT INTO logs VALUES(1788220800, ?1)",
            [oversized_priority],
        )
        .unwrap();
        db.execute(
            "INSERT INTO logs VALUES(1788220801, ?1)",
            [request("after-huge", "gpt-5.4")],
        )
        .unwrap();
        drop(db);
        assert!(matches!(
            read(&path, None, 1_700_000_000),
            ReadOutcome::Incomplete
        ));
        std::fs::remove_file(path).ok();
    }

    #[test]
    fn expired_huge_body_is_skipped_and_later_rows_converge() {
        let path = db_path("expired-huge-body");
        let db = create_db(&path);
        db.execute(
            "INSERT INTO logs VALUES(1600000000, ?1)",
            ["x".repeat(BODY_BUDGET + 1)],
        )
        .unwrap();
        db.execute(
            "INSERT INTO logs VALUES(1788220801, ?1)",
            [request("after-huge", "gpt-5.4")],
        )
        .unwrap();
        drop(db);
        let (cursor, events) = read_complete(&path, None, 1_700_000_000);
        assert_eq!(cursor.last_rowid, 2);
        assert_eq!(events.len(), 1);
        std::fs::remove_file(path).ok();
    }

    #[test]
    fn byte_budget_yields_partial_and_resumes() {
        let path = db_path("byte-budget");
        let mut db = create_db(&path);
        let transaction = db.transaction().unwrap();
        let body = "x".repeat(900 * 1024);
        for _ in 0..20 {
            transaction
                .execute("INSERT INTO logs VALUES(1788220800, ?1)", [&body])
                .unwrap();
        }
        transaction
            .execute(
                "INSERT INTO logs VALUES(1788220801, ?1)",
                [request("after-pages", "gpt-5.4")],
            )
            .unwrap();
        transaction.commit().unwrap();
        drop(db);
        let ReadOutcome::Partial(first, _) = read(&path, None, 1_700_000_000) else {
            panic!()
        };
        assert!(first.last_rowid < first.target_rowid);
        let (second, events) = read_complete(&path, Some(&first), 1_700_000_000);
        assert_eq!(events.len(), 1);
        assert!(second.turns.contains_key(&turn_digest("after-pages")));
        std::fs::remove_file(path).ok();
    }
}
