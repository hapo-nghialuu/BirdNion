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

use chrono::{DateTime, Duration, Local, NaiveDate, TimeZone, Timelike};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::path::{Component, Path, PathBuf};
use walkdir::WalkDir;

use crate::project_cost_history::{ProjectContribution, ProjectModel, ProjectRetraction};
use crate::usage::{DailyModel, DailyUsage, HourlyUsage, UsageReport};

mod coordinator;
mod incremental;
mod incremental_spool;
mod journal;
mod priority;
mod schema;

pub use coordinator::{
    current as current_scan, try_begin as try_begin_scan, update as update_scan_progress,
    ActiveScan,
};

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

fn normalized_model(model: &str) -> &str {
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
    key
}

fn price_for(model: &str) -> Option<Price> {
    let p = match normalized_model(model) {
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
    let Some(p) = price_for(model) else {
        return 0.0;
    };
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

fn priority_cost_usd(model: &str, input: i64, cached: i64, output: i64) -> f64 {
    let rates = match normalized_model(model) {
        "gpt-5.4" => Some((5e-6, 5e-7, 3e-5)),
        "gpt-5.4-mini" => Some((1.5e-6, 1.5e-7, 9e-6)),
        "gpt-5.5" => Some((1.25e-5, 1.25e-6, 7.5e-5)),
        _ => None,
    };
    let Some((input_rate, cache_rate, output_rate)) = rates else {
        return cost_usd(model, input, cached, output);
    };
    if input.max(0) > 272_000 {
        return cost_usd(model, input, cached, output);
    }
    let cached = cached.clamp(0, input.max(0));
    let priority = (input - cached).max(0) as f64 * input_rate
        + cached as f64 * cache_rate
        + output.max(0) as f64 * output_rate;
    priority.max(cost_usd(model, input, cached, output))
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
#[derive(Clone)]
struct CodexTokenEvent {
    ts: DateTime<Local>,
    model: String,
    last: CodexTotals,
    total: Option<CodexTotals>,
    turn_hash: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
struct ProjectIdentity {
    key: String,
    display_name: String,
}

pub struct CodexUsageScan {
    pub usage: UsageReport,
    pub projects: Vec<ProjectContribution>,
    pub retractions: Vec<ProjectRetraction>,
    pub progress_fingerprint: Option<String>,
}

pub enum GenerationOutcome {
    Pending,
    Complete(CodexUsageScan),
    Failed,
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
    project: Option<ProjectIdentity>,
    project_ambiguous: bool,
    retraction_project: Option<ProjectIdentity>,
    retraction_events: Vec<CodexTokenEvent>,
    events: Vec<CodexTokenEvent>,
    precomputed_retraction_id: Option<String>,
}

fn scan_from_safe_records(records: &[incremental::SafeRecord]) -> CodexFileScan {
    let mut scan = CodexFileScan::default();
    let mut model = String::from("gpt-5");
    let mut current_turn = None;
    for record in records {
        apply_safe_record(&mut scan, &mut model, &mut current_turn, record);
    }
    scan
}

fn apply_safe_record(
    scan: &mut CodexFileScan,
    model: &mut String,
    current_turn: &mut Option<String>,
    record: &incremental::SafeRecord,
) {
    match record {
        incremental::SafeRecord::Meta {
            session,
            parent,
            timestamp_ms,
            project_key,
            project_name,
            retraction_id,
        } => {
            if scan.session_id.is_none() {
                scan.session_id = session.clone();
            }
            if scan.forked_from_id.is_none() && parent.is_some() {
                scan.forked_from_id = parent.clone();
                scan.fork_ts = timestamp_ms.and_then(|v| Local.timestamp_millis_opt(v).single());
            }
            let project = project_key
                .as_ref()
                .zip(project_name.as_ref())
                .map(|(key, name)| ProjectIdentity {
                    key: key.clone(),
                    display_name: name.clone(),
                });
            if project.is_some() {
                update_file_project(scan, project);
            }
            if scan.precomputed_retraction_id.is_none() {
                scan.precomputed_retraction_id = retraction_id.clone();
            }
        }
        incremental::SafeRecord::ProjectInvalid => update_file_project(scan, None),
        incremental::SafeRecord::Model(value) => *model = value.clone(),
        incremental::SafeRecord::CurrentTurn(value) => *current_turn = Some(value.clone()),
        incremental::SafeRecord::Token {
            timestamp_ms,
            input,
            cached,
            output,
            total,
            cumulative,
            turn,
        } => {
            let Some(ts) = Local.timestamp_millis_opt(*timestamp_ms).single() else {
                return;
            };
            scan.events.push(CodexTokenEvent {
                ts,
                model: model.clone(),
                last: CodexTotals {
                    input: *input,
                    cached: *cached,
                    output: *output,
                    total: *total,
                },
                total: cumulative.map(|v| CodexTotals {
                    input: v.0,
                    cached: v.1,
                    output: v.2,
                    total: v.3,
                }),
                turn_hash: turn.clone().or_else(|| current_turn.clone()),
            });
        }
    }
}

fn ingest_file_scan(
    mut file_scan: CodexFileScan,
    scans: &mut Vec<CodexFileScan>,
    id_index: &mut HashMap<String, usize>,
) {
    if let Some(id) = file_scan.session_id.clone() {
        if let Some(existing_index) = id_index.get(&id).copied() {
            let existing = &scans[existing_index];
            let invalid = existing.project_ambiguous || file_scan.project_ambiguous;
            let conflicts = matches!((existing.project.as_ref(), file_scan.project.as_ref()), (Some(a),Some(b)) if a.key != b.key);
            let retraction_project = existing
                .retraction_project
                .clone()
                .or_else(|| {
                    (invalid || conflicts)
                        .then(|| existing.project.clone())
                        .flatten()
                })
                .or_else(|| file_scan.retraction_project.clone());
            let retraction_events = if existing.retraction_project.is_some() {
                existing.retraction_events.clone()
            } else if (invalid || conflicts) && existing.project.is_some() {
                existing.events.clone()
            } else {
                file_scan.retraction_events.clone()
            };
            let (project, ambiguous) = reconcile_project_identity(
                existing.project.as_ref(),
                file_scan.project.clone(),
                invalid,
            );
            if file_scan.events.len() > existing.events.len() {
                file_scan.project = project;
                file_scan.project_ambiguous = ambiguous;
                file_scan.retraction_project = retraction_project;
                file_scan.retraction_events = retraction_events;
                scans[existing_index] = file_scan;
            } else {
                scans[existing_index].project = project;
                scans[existing_index].project_ambiguous = ambiguous;
                scans[existing_index].retraction_project = retraction_project;
                scans[existing_index].retraction_events = retraction_events;
            }
            return;
        }
        id_index.insert(id, scans.len());
    }
    scans.push(file_scan);
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
fn parse_codex_session_meta(
    obj: &Value,
) -> Option<(
    Option<String>,
    Option<String>,
    Option<String>,
    Option<String>,
)> {
    if obj.get("type").and_then(Value::as_str) != Some("session_meta") {
        return None;
    }
    let payload = obj.get("payload")?;
    let field = |v: &Value, keys: &[&str]| -> Option<String> {
        keys.iter()
            .find_map(|k| v.get(*k).and_then(Value::as_str))
            .map(String::from)
    };
    let id = field(payload, &["id", "session_id", "sessionId"]);
    let forked_from_id = field(payload, &["forked_from_id", "forkedFromId"]);
    let timestamp = field(payload, &["timestamp"]).or_else(|| field(obj, &["timestamp"]));
    let cwd = field(payload, &["cwd"]);
    Some((id, forked_from_id, timestamp, cwd))
}

fn normalized_absolute_path(raw: &str) -> Option<PathBuf> {
    if raw.chars().any(char::is_control) {
        return None;
    }
    let path = Path::new(raw);
    if !path.is_absolute() {
        return None;
    }
    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            Component::Prefix(prefix) => normalized.push(prefix.as_os_str()),
            Component::RootDir => normalized.push(component.as_os_str()),
            Component::CurDir => {}
            Component::ParentDir => {
                if !normalized.pop() {
                    return None;
                }
            }
            Component::Normal(part) => normalized.push(part),
        }
    }
    Some(normalized)
}

fn safe_basename(path: &Path) -> Option<String> {
    let raw = path.file_name()?.to_str()?;
    let name: String = raw
        .chars()
        .filter(|char| !char.is_control() && *char != '/' && *char != '\\')
        .take(80)
        .collect::<String>()
        .trim()
        .to_string();
    (!name.is_empty() && name != "." && name != "..").then_some(name)
}

fn codex_project_identity(raw_cwd: &str) -> Option<ProjectIdentity> {
    let normalized = normalized_absolute_path(raw_cwd)?;
    let display_name = safe_basename(&normalized)?;
    let identity = normalized.to_str()?;
    let mut hasher = Sha256::new();
    hasher.update(b"codex:cwd-v1\0");
    hasher.update(identity.as_bytes());
    Some(ProjectIdentity {
        key: hex::encode(hasher.finalize()),
        display_name,
    })
}

fn reconcile_project_identity(
    current: Option<&ProjectIdentity>,
    incoming: Option<ProjectIdentity>,
    ambiguous: bool,
) -> (Option<ProjectIdentity>, bool) {
    if ambiguous {
        return (None, true);
    }
    match (current, incoming) {
        (None, None) => (None, false),
        (Some(value), None) => (Some(value.clone()), false),
        (None, Some(value)) => (Some(value), false),
        (Some(current), Some(incoming)) if current.key == incoming.key => {
            (Some(current.clone()), false)
        }
        (Some(_), Some(_)) => (None, true),
    }
}

fn update_file_project(scan: &mut CodexFileScan, incoming: Option<ProjectIdentity>) {
    let invalid = incoming.is_none();
    let conflicts = match (scan.project.as_ref(), incoming.as_ref()) {
        (Some(current), Some(next)) => current.key != next.key,
        (Some(_), None) => true,
        _ => false,
    };
    if !scan.project_ambiguous && (invalid || conflicts) && scan.retraction_project.is_none() {
        scan.retraction_project = scan.project.clone();
        scan.retraction_events = scan.events.clone();
    }
    let (project, ambiguous) = reconcile_project_identity(
        scan.project.as_ref(),
        incoming,
        scan.project_ambiguous || invalid,
    );
    scan.project = project;
    scan.project_ambiguous = ambiguous;
}

fn codex_retraction_id(session_id: &str, project_key: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(b"codex:project-retraction-v1\0");
    hasher.update(session_id.as_bytes());
    hasher.update(b"\0");
    hasher.update(project_key.as_bytes());
    hex::encode(hasher.finalize())
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

/// Session roots under the system Codex home. Managed BirdNion account homes
/// only contain copied auth state; the CLI keeps writing rollout logs to its
/// system `$CODEX_HOME`/`~/.codex` home regardless of the selected account.
pub fn default_roots() -> Vec<PathBuf> {
    crate::platform::paths::codex_home()
        .map(|home| vec![home.join("sessions"), home.join("archived_sessions")])
        .unwrap_or_default()
}

pub fn usage_scan() -> Option<CodexUsageScan> {
    scan_with_projects(&default_roots(), Local::now())
}

fn save_compact_scan_marker(state: &schema::ScanJournal) -> bool {
    let compact = schema::ScanJournal {
        version: state.version,
        producer: state.producer.clone(),
        timezone: state.timezone.clone(),
        committed: state
            .committed
            .as_ref()
            .map(|committed| schema::CommittedGeneration {
                id: committed.id,
                completed_at_ms: committed.completed_at_ms,
                priority: None,
                engine: None,
            }),
        pending: None,
    };
    // Dropping reusable cursors is safe: persisted cost history stays the
    // last-good report and the next generation performs a clean rebuild.
    journal::save(&compact).is_ok()
}

/// Runs one finite background generation. The manifest is frozen before the
/// existing exact aggregator runs, so files appended during this generation
/// are picked up by the next one instead of extending the current tail.
pub fn usage_scan_generation(generation: u64) -> GenerationOutcome {
    let mut pending = false;
    match usage_scan_generation_inner(generation, &mut pending) {
        Some(scan) => GenerationOutcome::Complete(scan),
        None if pending => GenerationOutcome::Pending,
        None => GenerationOutcome::Failed,
    }
}

fn usage_scan_generation_inner(
    generation: u64,
    pending_episode: &mut bool,
) -> Option<CodexUsageScan> {
    use schema::{CommittedGeneration, PendingGeneration, ScanJournal};

    let roots = default_roots();
    let episode_started = std::time::Instant::now();
    let episode_budget = std::time::Duration::from_secs(2);
    let mut spool = incremental_spool::Spool::open_default().ok()?;
    let now = Local::now();
    let fresh_modified_since = now - Duration::days(HISTORY_DAYS);
    let previous = journal::load();
    let committed = previous.as_ref().and_then(|value| value.committed.clone());
    let resumed_priority = previous
        .as_ref()
        .and_then(|value| value.pending.as_ref())
        .and_then(|pending| pending.priority.clone());
    let resumed_cutoff = previous
        .as_ref()
        .and_then(|value| value.pending.as_ref())
        .and_then(|pending| pending.engine.as_ref())
        .and_then(|engine| engine.modified_since_ms)
        .and_then(|millis| Local.timestamp_millis_opt(millis).single());
    let resumed = previous
        .as_ref()
        .and_then(|value| value.pending.as_ref())
        .and_then(|pending| pending.engine.clone())
        .and_then(|mut saved| {
            incremental::hydrate(&mut saved, &roots, resumed_cutoff).then_some(saved)
        });
    let mut engine = if let Some(saved) = resumed {
        saved
    } else if let Some(committed_engine) =
        committed.as_ref().and_then(|value| value.engine.as_ref())
    {
        incremental::refresh(
            generation,
            &roots,
            committed_engine,
            Some(fresh_modified_since),
        )
        .ok()?
    } else {
        incremental::discover(generation, &roots, Some(fresh_modified_since)).ok()?
    };
    engine.generation = generation;
    let modified_since = engine
        .modified_since_ms
        .and_then(|millis| Local.timestamp_millis_opt(millis).single())
        .unwrap_or(fresh_modified_since);
    // Pending owns the complete resumable engine. Keeping a second full copy
    // under committed doubles large journals and can make every checkpoint
    // exceed the 64 MiB privacy/safety bound. The persisted cost history is
    // the last-good user-facing commit while this generation is pending.
    let mut checkpoint_committed = committed.clone();
    if let Some(entry) = checkpoint_committed.as_mut() {
        entry.engine = None;
    }
    let mut state = ScanJournal {
        version: schema::JOURNAL_VERSION,
        producer: schema::JOURNAL_PRODUCER.into(),
        timezone: Local::now().offset().to_string(),
        committed: checkpoint_committed,
        pending: Some(PendingGeneration {
            id: generation,
            completed: 0,
            progress_fingerprint: engine.fingerprint.clone(),
            priority: resumed_priority,
            engine: Some(engine),
        }),
    };
    let engine = state.pending.as_ref()?.engine.as_ref()?;
    update_scan_progress(
        generation,
        engine.completed.len(),
        engine.completed.len() + engine.queue.len(),
        engine.fingerprint.clone(),
    );
    // Checkpoint once at an episode boundary, not after every 500 ms pass.
    // SQLite batches are idempotent, so a crash before the boundary safely
    // replays work without repeatedly serializing the whole manifest.
    loop {
        let outcome = {
            let engine = state.pending.as_mut()?.engine.as_mut()?;
            incremental::run_pass(engine, &roots, &mut spool)
        };
        match outcome {
            incremental::PassOutcome::Incomplete => {
                state.pending = None;
                state.committed = committed.clone();
                if journal::save(&state).is_err() {
                    let _ = save_compact_scan_marker(&state);
                }
                return None;
            }
            outcome => {
                let engine = state.pending.as_ref()?.engine.as_ref()?;
                let completed = engine.completed.len();
                let total = completed + engine.queue.len();
                let fingerprint = engine.fingerprint.clone();
                let pending = state.pending.as_mut()?;
                pending.completed = completed.min(u32::MAX as usize) as u32;
                pending.progress_fingerprint = fingerprint.clone();
                update_scan_progress(generation, completed, total, fingerprint);
                if episode_started.elapsed() >= episode_budget {
                    if journal::save(&state).is_ok() {
                        // Pending journal + SQLite rows are durable. The next
                        // episode resumes instead of monopolizing a worker.
                        *pending_episode = true;
                        return None;
                    }
                    let _ = save_compact_scan_marker(&state);
                    // A failed checkpoint must never turn a bounded episode
                    // into an unbounded worker. Keep last-good and fail closed.
                    return None;
                }
                if outcome == incremental::PassOutcome::Complete {
                    break;
                }
                std::thread::yield_now();
            }
        }
    }
    let priority_path = crate::platform::paths::codex_home().map(|home| home.join("logs_2.sqlite"));
    let mut priority_cursor = state
        .pending
        .as_ref()
        .and_then(|value| value.priority.clone())
        .or_else(|| {
            state
                .committed
                .as_ref()
                .and_then(|value| value.priority.clone())
        });
    let mut priority_turns: HashMap<String, Option<String>> = HashMap::new();
    let priority = match priority_path {
        Some(path) => loop {
            match priority::read(&path, priority_cursor.as_ref(), modified_since.timestamp()) {
                priority::ReadOutcome::Partial(cursor, _) => {
                    if let Some(pending) = state.pending.as_mut() {
                        pending.priority = Some(cursor.clone());
                    }
                    let priority_progress =
                        format!("priority-{}-{}", cursor.last_rowid, cursor.target_rowid);
                    update_scan_progress(
                        generation,
                        cursor.last_rowid.max(0) as usize,
                        cursor.target_rowid.max(0) as usize,
                        priority_progress,
                    );
                    priority_cursor = Some(cursor);
                    if episode_started.elapsed() >= episode_budget {
                        if journal::save(&state).is_ok() {
                            *pending_episode = true;
                            return None;
                        }
                        let _ = save_compact_scan_marker(&state);
                        return None;
                    }
                    std::thread::yield_now();
                }
                priority::ReadOutcome::Complete(cursor, _) => {
                    priority_turns.extend(cursor.turns.clone());
                    if let Some(pending) = state.pending.as_mut() {
                        pending.priority = Some(cursor.clone());
                    }
                    if episode_started.elapsed() >= episode_budget {
                        if journal::save(&state).is_ok() {
                            *pending_episode = true;
                            return None;
                        }
                        let _ = save_compact_scan_marker(&state);
                        return None;
                    }
                    break Some(cursor);
                }
                priority::ReadOutcome::Absent => {
                    if episode_started.elapsed() >= episode_budget {
                        if journal::save(&state).is_ok() {
                            *pending_episode = true;
                            return None;
                        }
                        let _ = save_compact_scan_marker(&state);
                        return None;
                    }
                    break None;
                }
                priority::ReadOutcome::Incomplete => {
                    state.pending = None;
                    state.committed = committed.clone();
                    if journal::save(&state).is_err() {
                        let _ = save_compact_scan_marker(&state);
                    }
                    return None;
                }
            }
        },
        None => None,
    };
    let engine = state.pending.as_ref()?.engine.as_ref()?;
    let aggregation_deadline = episode_started + episode_budget;
    let scan = scan_with_spool(
        &roots,
        Local::now(),
        &priority_turns,
        engine,
        &spool,
        aggregation_deadline,
    )?;
    let progress_fingerprint = engine.fingerprint.clone();
    let engine = state.pending.as_mut()?.engine.take()?;
    state.pending = None;
    state.committed = Some(CommittedGeneration {
        id: generation,
        completed_at_ms: Local::now().timestamp_millis(),
        priority,
        engine: Some(engine),
    });
    let committed_durable = if journal::save(&state).is_ok() {
        true
    } else {
        // Preserve generation/priority metadata even when the reusable JSONL
        // cache cannot fit the bounded journal. The completed report is still
        // valid and must be published; the next generation will rediscover.
        if let Some(committed) = state.committed.as_mut() {
            committed.engine = None;
        }
        journal::save(&state).is_ok() || save_compact_scan_marker(&state)
    };
    if !committed_durable {
        // The prior pending journal may still reference spool rows. Never
        // prune or publish a generation whose commit marker is not durable.
        return None;
    }
    let retained_generations = state
        .committed
        .as_ref()
        .and_then(|committed| committed.engine.as_ref())
        .map(|engine| {
            engine
                .files
                .iter()
                .map(|file| (file.record_generation, incremental::file_key(file)))
                .collect::<std::collections::HashSet<_>>()
        })
        .unwrap_or_default();
    if spool.prune_unreferenced(&retained_generations).is_err() {
        // Retention cleanup is part of the privacy contract. The durable
        // journal can be retried, but this generation is not published.
        return None;
    }
    Some(CodexUsageScan {
        progress_fingerprint: Some(progress_fingerprint),
        ..scan
    })
}

fn scan_with_spool(
    roots: &[PathBuf],
    now: DateTime<Local>,
    priority_turns: &HashMap<String, Option<String>>,
    engine: &incremental::State,
    spool: &incremental_spool::Spool,
    deadline: std::time::Instant,
) -> Option<CodexUsageScan> {
    let mut scans: Vec<incremental_spool::FileSummary> = Vec::new();
    let mut id_index = HashMap::new();
    let mut files = engine
        .files
        .iter()
        .map(|file| incremental::resolved_path(file, roots).map(|path| (path, file)))
        .collect::<Result<Vec<_>, _>>()
        .ok()?;
    files.sort_by(|left, right| left.0.cmp(&right.0));
    for (_, file) in files {
        if std::time::Instant::now() >= deadline {
            return None;
        }
        let key = incremental::file_key(file);
        let scan = spool
            .summarize_file(file.record_generation, key, deadline)
            .ok()?;
        ingest_spool_summary(scan, &mut scans, &mut id_index);
    }
    if !roots.iter().any(|root| root.is_dir()) {
        return None;
    }
    aggregate_spool(scans, now, priority_turns, spool, deadline).ok()
}

fn ingest_spool_summary(
    mut incoming: incremental_spool::FileSummary,
    scans: &mut Vec<incremental_spool::FileSummary>,
    id_index: &mut HashMap<String, usize>,
) {
    let Some(id) = incoming.session_id.clone() else {
        scans.push(incoming);
        return;
    };
    let Some(index) = id_index.get(&id).copied() else {
        id_index.insert(id, scans.len());
        scans.push(incoming);
        return;
    };
    let existing = &mut scans[index];
    let invalid = existing.project_ambiguous || incoming.project_ambiguous;
    let conflicts = matches!(
        (existing.project.as_ref(), incoming.project.as_ref()),
        (Some(left), Some(right)) if left.key != right.key
    );
    let retraction_project = existing
        .retraction_project
        .clone()
        .or_else(|| {
            (invalid || conflicts)
                .then(|| existing.project.clone())
                .flatten()
        })
        .or_else(|| incoming.retraction_project.clone());
    let retraction_source = if existing.retraction_project.is_some() {
        existing.retraction_source.take()
    } else if (invalid || conflicts) && existing.project.is_some() {
        Some(incremental_spool::RetractionSource {
            generation: existing.generation,
            file_key: existing.file_key.clone(),
            token_limit: existing.token_count,
            retraction_id: existing.precomputed_retraction_id.clone(),
        })
    } else {
        incoming.retraction_source.take()
    };
    let (project, ambiguous) =
        reconcile_project_identity(existing.project.as_ref(), incoming.project.clone(), invalid);
    if incoming.token_count > existing.token_count {
        incoming.project = project;
        incoming.project_ambiguous = ambiguous;
        incoming.retraction_project = retraction_project;
        incoming.retraction_source = retraction_source;
        *existing = incoming;
    } else {
        existing.project = project;
        existing.project_ambiguous = ambiguous;
        existing.retraction_project = retraction_project;
        existing.retraction_source = retraction_source;
    }
}

#[derive(Default)]
struct StreamingDay {
    usd: f64,
    tokens: i64,
    models: HashMap<String, (f64, i64)>,
}

#[derive(Default)]
struct StreamingProjectDay {
    display_name: String,
    usd: f64,
    tokens: i64,
    models: HashMap<String, (f64, i64)>,
}

struct StreamingAggregate {
    now: DateTime<Local>,
    buckets: HashMap<NaiveDate, StreamingDay>,
    hours: HashMap<(NaiveDate, u32), (f64, i64)>,
    models: HashMap<String, (f64, i64)>,
    projects: HashMap<(String, NaiveDate), StreamingProjectDay>,
    retractions: HashMap<(String, NaiveDate), StreamingProjectDay>,
    today_usd: f64,
    today_tokens: i64,
    month_usd: f64,
    month_tokens: i64,
}

impl StreamingAggregate {
    fn new(now: DateTime<Local>) -> Self {
        Self {
            now,
            buckets: HashMap::new(),
            hours: HashMap::new(),
            models: HashMap::new(),
            projects: HashMap::new(),
            retractions: HashMap::new(),
            today_usd: 0.0,
            today_tokens: 0,
            month_usd: 0.0,
            month_tokens: 0,
        }
    }

    fn add(
        &mut self,
        event: &CodexTokenEvent,
        counted: CodexTotals,
        project: Option<&ProjectIdentity>,
        retraction: Option<(&str, &ProjectIdentity)>,
        priority_turns: &HashMap<String, Option<String>>,
    ) {
        let cutoff = self.now - Duration::days(HISTORY_DAYS);
        if event.ts < cutoff || event.ts > self.now {
            return;
        }
        let priced_model = event
            .turn_hash
            .as_ref()
            .and_then(|turn| priority_turns.get(turn))
            .and_then(|model| model.as_deref())
            .filter(|model| price_for(model).is_some())
            .unwrap_or(&event.model);
        let usd = if event
            .turn_hash
            .as_ref()
            .is_some_and(|turn| priority_turns.contains_key(turn))
        {
            priority_cost_usd(priced_model, counted.input, counted.cached, counted.output)
        } else {
            cost_usd(&event.model, counted.input, counted.cached, counted.output)
        };
        if usd == 0.0 && counted.total == 0 {
            return;
        }
        let day = event.ts.date_naive();
        if let Some((id, project)) = retraction {
            Self::add_project(
                &mut self.retractions,
                Some(id),
                project,
                day,
                event,
                usd,
                counted.total,
            );
            return;
        }
        let daily = self.buckets.entry(day).or_default();
        daily.usd += usd;
        daily.tokens += counted.total;
        let model = daily.models.entry(event.model.clone()).or_default();
        model.0 += usd;
        model.1 += counted.total;
        if let Some(project) = project {
            Self::add_project(
                &mut self.projects,
                None,
                project,
                day,
                event,
                usd,
                counted.total,
            );
        }
        if event.ts >= self.now - Duration::days(30) {
            self.month_usd += usd;
            self.month_tokens += counted.total;
            let model = self.models.entry(event.model.clone()).or_default();
            model.0 += usd;
            model.1 += counted.total;
        }
        if day >= self.now.date_naive() {
            self.today_usd += usd;
            self.today_tokens += counted.total;
        }
        if event.ts >= self.now - Duration::hours(24) {
            let hour = self.hours.entry((day, event.ts.hour())).or_default();
            hour.0 += usd;
            hour.1 += counted.total;
        }
    }

    fn add_project(
        target: &mut HashMap<(String, NaiveDate), StreamingProjectDay>,
        retraction_id: Option<&str>,
        project: &ProjectIdentity,
        day: NaiveDate,
        event: &CodexTokenEvent,
        usd: f64,
        tokens: i64,
    ) {
        let key = retraction_id
            .map(|id| format!("{id}\0{}", project.key))
            .unwrap_or_else(|| project.key.clone());
        let value = target.entry((key, day)).or_default();
        value.display_name = project.display_name.clone();
        value.usd += usd;
        value.tokens += tokens;
        let model = value.models.entry(event.model.clone()).or_default();
        model.0 += usd;
        model.1 += tokens;
    }

    fn finish(self) -> CodexUsageScan {
        let mut daily = Vec::with_capacity(HISTORY_DAYS as usize);
        for offset in (0..HISTORY_DAYS).rev() {
            let date = self.now.date_naive() - Duration::days(offset);
            let (usd, tokens, mut models) = self.buckets.get(&date).map_or_else(
                || (0.0, 0, Vec::new()),
                |day| {
                    (
                        day.usd,
                        day.tokens,
                        day.models
                            .iter()
                            .map(|(name, value)| DailyModel {
                                name: name.clone(),
                                usd: value.0,
                                tokens: value.1,
                            })
                            .collect(),
                    )
                },
            );
            models.sort_by(|a, b| b.usd.total_cmp(&a.usd));
            models.truncate(5);
            daily.push(DailyUsage {
                date: date.to_string(),
                usd,
                tokens,
                models,
            });
        }
        let mut hourly = Vec::with_capacity(24);
        for offset in (0..24).rev() {
            let time = self.now - Duration::hours(offset);
            let (usd, tokens) = self
                .hours
                .get(&(time.date_naive(), time.hour()))
                .copied()
                .unwrap_or_default();
            hourly.push(HourlyUsage {
                hour: format!("{}T{:02}:00", time.date_naive(), time.hour()),
                usd,
                tokens,
            });
        }
        let top_model = self
            .models
            .into_iter()
            .max_by(|a, b| a.1 .0.total_cmp(&b.1 .0).then_with(|| a.1 .1.cmp(&b.1 .1)))
            .map(|row| row.0);
        let projects = streaming_projects(self.projects);
        let mut grouped: HashMap<(String, String), Vec<ProjectContribution>> = HashMap::new();
        for ((combined, date), day) in self.retractions {
            let Some((id, key)) = combined.split_once('\0') else {
                continue;
            };
            grouped
                .entry((id.into(), key.into()))
                .or_default()
                .push(streaming_project(key.into(), date, day));
        }
        let mut retractions = grouped
            .into_iter()
            .map(|((retraction_id, project_key), mut contributions)| {
                contributions.sort_by(|a, b| a.date.cmp(&b.date));
                ProjectRetraction {
                    retraction_id,
                    project_key,
                    contributions,
                }
            })
            .collect::<Vec<_>>();
        retractions.sort_by(|a, b| a.retraction_id.cmp(&b.retraction_id));
        CodexUsageScan {
            usage: UsageReport {
                today_usd: self.today_usd,
                today_tokens: self.today_tokens,
                last30_usd: self.month_usd,
                last30_tokens: self.month_tokens,
                daily,
                hourly,
                top_model,
                ..Default::default()
            },
            projects,
            retractions,
            progress_fingerprint: None,
        }
    }
}

fn streaming_project(
    key: String,
    date: NaiveDate,
    day: StreamingProjectDay,
) -> ProjectContribution {
    let mut models = day
        .models
        .into_iter()
        .map(|(name, value)| ProjectModel {
            name,
            usd: value.0,
            tokens: value.1,
        })
        .collect::<Vec<_>>();
    models.sort_by(|a, b| {
        b.usd
            .total_cmp(&a.usd)
            .then_with(|| b.tokens.cmp(&a.tokens))
            .then_with(|| a.name.cmp(&b.name))
    });
    models.truncate(5);
    ProjectContribution {
        project_key: key,
        display_name: day.display_name,
        capability: "exact".into(),
        date: date.to_string(),
        usd: day.usd,
        tokens: day.tokens,
        models,
    }
}

fn streaming_projects(
    source: HashMap<(String, NaiveDate), StreamingProjectDay>,
) -> Vec<ProjectContribution> {
    let mut values = source
        .into_iter()
        .filter(|(_, day)| day.usd > 0.0 || day.tokens > 0)
        .map(|((key, date), day)| streaming_project(key, date, day))
        .collect::<Vec<_>>();
    values.sort_by(|a, b| {
        a.date
            .cmp(&b.date)
            .then_with(|| a.project_key.cmp(&b.project_key))
    });
    values
}

fn aggregate_spool(
    scans: Vec<incremental_spool::FileSummary>,
    now: DateTime<Local>,
    priority_turns: &HashMap<String, Option<String>>,
    spool: &incremental_spool::Spool,
    deadline: std::time::Instant,
) -> Result<CodexUsageScan, String> {
    let mut index = HashMap::new();
    for (position, scan) in scans.iter().enumerate() {
        if let Some(id) = scan.session_id.as_ref() {
            index.insert(id.clone(), position);
        }
    }
    let baselines = fork_baselines(&scans, &index, spool, deadline)?;
    let mut output = StreamingAggregate::new(now);
    for (scan_index, scan) in scans.iter().enumerate() {
        if std::time::Instant::now() >= deadline {
            return Err("Codex aggregation deadline exceeded".into());
        }
        let baseline = baselines[scan_index];
        let mut previous = CodexTotals::default();
        spool.stream_file(scan.generation, &scan.file_key, deadline, |event| {
            let counted = adjusted_tokens(&event, baseline, &mut previous);
            output.add(&event, counted, scan.project.as_ref(), None, priority_turns);
            Ok(())
        })?;
        if let Some(project) = scan.retraction_project.as_ref() {
            let id = scan
                .retraction_source
                .as_ref()
                .and_then(|source| source.retraction_id.clone());
            if let (Some(id), Some(source)) = (id, scan.retraction_source.as_ref()) {
                let mut seen = 0_u64;
                let mut previous = CodexTotals::default();
                spool.stream_file(source.generation, &source.file_key, deadline, |event| {
                    if seen < source.token_limit {
                        let counted = adjusted_tokens(&event, baseline, &mut previous);
                        output.add(&event, counted, None, Some((&id, project)), priority_turns);
                    }
                    seen += 1;
                    Ok(())
                })?;
            }
        }
    }
    Ok(output.finish())
}

fn fork_baselines(
    scans: &[incremental_spool::FileSummary],
    index: &HashMap<String, usize>,
    spool: &incremental_spool::Spool,
    deadline: std::time::Instant,
) -> Result<Vec<Option<CodexTotals>>, String> {
    let mut requests: HashMap<usize, Vec<(DateTime<Local>, usize)>> = HashMap::new();
    for (child_index, scan) in scans.iter().enumerate() {
        if let Some((parent_index, fork_ts)) = scan
            .forked_from_id
            .as_ref()
            .and_then(|id| index.get(id).copied())
            .zip(scan.fork_ts)
        {
            requests
                .entry(parent_index)
                .or_default()
                .push((fork_ts, child_index));
        }
    }
    let mut baselines = vec![None; scans.len()];
    for (parent_index, mut children) in requests {
        children.sort_by_key(|(timestamp, _)| *timestamp);
        let parent = &scans[parent_index];
        let mut next_child = 0;
        let mut latest = None;
        spool.stream_file(parent.generation, &parent.file_key, deadline, |event| {
            while next_child < children.len() && children[next_child].0 < event.ts {
                baselines[children[next_child].1] = latest;
                next_child += 1;
            }
            if let Some(total) = event.total {
                latest = Some(total);
            }
            Ok(())
        })?;
        while next_child < children.len() {
            baselines[children[next_child].1] = latest;
            next_child += 1;
        }
    }
    Ok(baselines)
}

fn adjusted_tokens(
    event: &CodexTokenEvent,
    baseline: Option<CodexTotals>,
    previous: &mut CodexTotals,
) -> CodexTotals {
    match (baseline, event.total) {
        (Some(base), Some(total)) => {
            let adjusted = total.saturating_sub(&base);
            let delta = adjusted.saturating_sub(previous);
            *previous = adjusted;
            delta
        }
        _ => event.last,
    }
}

/// Returns None only when no sessions root is readable.
pub fn scan_with_projects(roots: &[PathBuf], now: DateTime<Local>) -> Option<CodexUsageScan> {
    scan_with_projects_and_priority(roots, now, &HashMap::new())
}

fn scan_with_projects_and_priority(
    roots: &[PathBuf],
    now: DateTime<Local>,
    priority_turns: &HashMap<String, Option<String>>,
) -> Option<CodexUsageScan> {
    scan_with_inputs(roots, now, priority_turns, None)
}

fn scan_with_inputs(
    roots: &[PathBuf],
    now: DateTime<Local>,
    priority_turns: &HashMap<String, Option<String>>,
    preloaded: Option<&HashMap<PathBuf, Vec<incremental::SafeRecord>>>,
) -> Option<CodexUsageScan> {
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

    #[derive(Default)]
    struct ProjectAcc {
        display_name: String,
        usd: f64,
        tokens: i64,
        models: HashMap<String, (f64, i64)>,
    }
    let mut project_buckets: HashMap<(String, NaiveDate), ProjectAcc> = HashMap::new();
    let mut retraction_buckets: HashMap<(String, String, NaiveDate), ProjectAcc> = HashMap::new();

    // Pass 1: read every file once, capturing its identity/fork lineage and
    // full event stream (not yet bucketed — a forked file's events need its
    // parent's baseline resolved first, and that parent may be discovered
    // later in this same loop).
    let mut scans: Vec<CodexFileScan> = Vec::new();
    let mut id_index: HashMap<String, usize> = HashMap::new();

    if let Some(preloaded) = preloaded {
        any_root = roots.iter().any(|root| root.is_dir());
        let mut entries: Vec<_> = preloaded.iter().collect();
        entries.sort_by(|left, right| left.0.cmp(right.0));
        for (_, records) in entries {
            ingest_file_scan(scan_from_safe_records(records), &mut scans, &mut id_index);
        }
    } else {
        for root in roots {
            if !root.is_dir() {
                continue;
            }
            any_root = true;
            let mut files: Vec<PathBuf> = WalkDir::new(root)
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
                .map(|e| e.into_path())
                .collect();
            files.sort();

            for file in files {
                let owned = std::fs::read_to_string(&file).ok();
                let Some(content) = owned.as_deref() else {
                    continue;
                };
                let mut file_scan = CodexFileScan::default();
                // Model comes from the most recent turn_context line in the file.
                let mut model = String::from("gpt-5");
                for line in content.lines() {
                    let Ok(obj) = serde_json::from_str::<Value>(line) else {
                        continue;
                    };
                    if let Some((id, forked_from_id, ts_str, cwd)) = parse_codex_session_meta(&obj)
                    {
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
                        if let Some(raw_cwd) = cwd {
                            let incoming = codex_project_identity(&raw_cwd);
                            update_file_project(&mut file_scan, incoming);
                        }
                        continue;
                    }
                    let payload = obj.get("payload");
                    match obj.get("type").and_then(Value::as_str) {
                        Some("turn_context") => {
                            if let Some(m) =
                                payload.and_then(|p| p.get("model")).and_then(Value::as_str)
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
                            let Some(last) = info.get("last_token_usage") else {
                                continue;
                            };
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
                                turn_hash: p
                                    .get("turn_id")
                                    .or_else(|| p.get("turnId"))
                                    .or_else(|| p.get("id"))
                                    .or_else(|| info.get("turn_id"))
                                    .or_else(|| info.get("turnId"))
                                    .or_else(|| info.get("id"))
                                    .and_then(Value::as_str)
                                    .map(priority::turn_digest),
                            });
                        }
                        _ => {}
                    }
                }
                ingest_file_scan(file_scan, &mut scans, &mut id_index);
            }
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
        let retraction = scans[scan_index]
            .session_id
            .as_deref()
            .zip(scans[scan_index].retraction_project.as_ref())
            .map(|(session_id, project)| {
                (
                    scans[scan_index]
                        .precomputed_retraction_id
                        .clone()
                        .unwrap_or_else(|| codex_retraction_id(session_id, &project.key)),
                    project,
                )
            });
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
            let priced_model = ev
                .turn_hash
                .as_ref()
                .and_then(|turn| priority_turns.get(turn))
                .and_then(|model| model.as_deref())
                .filter(|model| price_for(model).is_some())
                .unwrap_or(&ev.model);
            let usd = if ev
                .turn_hash
                .as_ref()
                .is_some_and(|turn| priority_turns.contains_key(turn))
            {
                priority_cost_usd(priced_model, counted.input, counted.cached, counted.output)
            } else {
                cost_usd(&ev.model, counted.input, counted.cached, counted.output)
            };
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

            if let Some(project) = &scans[scan_index].project {
                let project_day = project_buckets
                    .entry((project.key.clone(), day))
                    .or_default();
                project_day.display_name = project.display_name.clone();
                project_day.usd += usd;
                project_day.tokens += tokens;
                let model = project_day
                    .models
                    .entry(ev.model.clone())
                    .or_insert((0.0, 0));
                model.0 += usd;
                model.1 += tokens;
            }
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

        if let Some((retraction_id, project)) = retraction {
            let mut previous_adjusted = CodexTotals::default();
            for ev in &scans[scan_index].retraction_events {
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
                let priced_model = ev
                    .turn_hash
                    .as_ref()
                    .and_then(|turn| priority_turns.get(turn))
                    .and_then(|model| model.as_deref())
                    .filter(|model| price_for(model).is_some())
                    .unwrap_or(&ev.model);
                let usd = if ev
                    .turn_hash
                    .as_ref()
                    .is_some_and(|turn| priority_turns.contains_key(turn))
                {
                    priority_cost_usd(priced_model, counted.input, counted.cached, counted.output)
                } else {
                    cost_usd(&ev.model, counted.input, counted.cached, counted.output)
                };
                let tokens = counted.total;
                if usd == 0.0 && tokens == 0 {
                    continue;
                }
                let day = ev.ts.date_naive();
                let project_day = retraction_buckets
                    .entry((retraction_id.clone(), project.key.clone(), day))
                    .or_default();
                project_day.display_name = project.display_name.clone();
                project_day.usd += usd;
                project_day.tokens += tokens;
                let model = project_day
                    .models
                    .entry(ev.model.clone())
                    .or_insert((0.0, 0));
                model.0 += usd;
                model.1 += tokens;
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
        daily.push(DailyUsage {
            date: day.to_string(),
            usd,
            tokens,
            models,
        });
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
        .max_by(|a, b| a.1 .0.total_cmp(&b.1 .0).then_with(|| a.1 .1.cmp(&b.1 .1)))
        .map(|(name, _)| name);

    let usage = UsageReport {
        today_usd,
        today_tokens,
        last30_usd: month_usd,
        last30_tokens: month_tokens,
        daily,
        hourly,
        top_model,
        // Confidence metadata (included/live/scanned_at) is decided by
        // `cost_history::apply_and_report`, which owns the merge; this
        // intermediate "live" report is only ever consumed there.
        ..Default::default()
    };
    let mut projects: Vec<ProjectContribution> = project_buckets
        .into_iter()
        .filter(|(_, day)| day.usd > 0.0 || day.tokens > 0)
        .map(|((project_key, date), day)| {
            let mut models: Vec<ProjectModel> = day
                .models
                .into_iter()
                .filter(|(_, (usd, tokens))| *usd > 0.0 || *tokens > 0)
                .map(|(name, (usd, tokens))| ProjectModel { name, usd, tokens })
                .collect();
            models.sort_by(|a, b| {
                b.usd
                    .total_cmp(&a.usd)
                    .then_with(|| b.tokens.cmp(&a.tokens))
                    .then_with(|| a.name.cmp(&b.name))
            });
            models.truncate(5);
            ProjectContribution {
                project_key,
                display_name: day.display_name,
                capability: "exact".into(),
                date: date.to_string(),
                usd: day.usd,
                tokens: day.tokens,
                models,
            }
        })
        .collect();
    projects.sort_by(|a, b| {
        a.date
            .cmp(&b.date)
            .then_with(|| a.project_key.cmp(&b.project_key))
    });
    let mut retractions_by_id: HashMap<(String, String), Vec<ProjectContribution>> = HashMap::new();
    for ((retraction_id, project_key, date), day) in retraction_buckets {
        if day.usd <= 0.0 && day.tokens <= 0 {
            continue;
        }
        let mut models: Vec<ProjectModel> = day
            .models
            .into_iter()
            .filter(|(_, (usd, tokens))| *usd > 0.0 || *tokens > 0)
            .map(|(name, (usd, tokens))| ProjectModel { name, usd, tokens })
            .collect();
        models.sort_by(|a, b| a.name.cmp(&b.name));
        retractions_by_id
            .entry((retraction_id, project_key.clone()))
            .or_default()
            .push(ProjectContribution {
                project_key,
                display_name: day.display_name,
                capability: "exact".into(),
                date: date.to_string(),
                usd: day.usd,
                tokens: day.tokens,
                models,
            });
    }
    let mut retractions: Vec<ProjectRetraction> = retractions_by_id
        .into_iter()
        .map(|((retraction_id, project_key), mut contributions)| {
            contributions.sort_by(|a, b| a.date.cmp(&b.date));
            ProjectRetraction {
                retraction_id,
                project_key,
                contributions,
            }
        })
        .collect();
    retractions.sort_by(|a, b| a.retraction_id.cmp(&b.retraction_id));
    Some(CodexUsageScan {
        usage,
        projects,
        retractions,
        progress_fingerprint: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::Path;

    fn scan(roots: &[PathBuf], now: DateTime<Local>) -> Option<UsageReport> {
        scan_with_projects(roots, now).map(|scan| scan.usage)
    }

    fn temp_base(tag: &str) -> PathBuf {
        let base =
            std::env::temp_dir().join(format!("birdnion-codex-test-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&base);
        base
    }

    fn write_lines(dir: &Path, name: &str, lines: &[String]) {
        fs::create_dir_all(dir).unwrap();
        fs::write(dir.join(name), lines.join("\n")).unwrap();
    }

    fn turn_context(model: &str) -> String {
        format!(
            r#"{{"timestamp":"2026-01-01T00:00:00Z","type":"turn_context","payload":{{"model":"{model}"}}}}"#
        )
    }

    fn token_count(ts: &str, input: i64, cached: i64, output: i64, total: i64) -> String {
        format!(
            r#"{{"timestamp":"{ts}","type":"event_msg","payload":{{"type":"token_count","info":{{"total_token_usage":{{"total_tokens":0}},"last_token_usage":{{"input_tokens":{input},"cached_input_tokens":{cached},"output_tokens":{output},"total_tokens":{total}}}}}}}}}"#
        )
    }

    fn session_meta(ts: &str, id: &str, forked_from_id: Option<&str>) -> String {
        session_meta_with_cwd(ts, id, forked_from_id, None)
    }

    fn session_meta_with_cwd(
        ts: &str,
        id: &str,
        forked_from_id: Option<&str>,
        cwd: Option<&str>,
    ) -> String {
        let fork_field = forked_from_id
            .map(|p| format!(r#","forked_from_id":"{p}""#))
            .unwrap_or_default();
        let cwd_field = cwd
            .map(|value| format!(r#","cwd":"{value}""#))
            .unwrap_or_default();
        format!(
            r#"{{"timestamp":"{ts}","type":"session_meta","payload":{{"id":"{id}","timestamp":"{ts}"{fork_field}{cwd_field}}}}}"#
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
            li = last.0,
            lc = last.1,
            lo = last.2,
            lt = last.3,
            ti = total.0,
            tc = total.1,
            to = total.2,
            tt = total.3,
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
    fn priority_pricing_uses_exact_models_rates_and_272k_ceiling() {
        assert!((priority_cost_usd("gpt-5.4", 272_000, 0, 0) - 1.36).abs() < 1e-9);
        assert!((priority_cost_usd("gpt-5.4", 272_001, 0, 0) - 1.360_005).abs() < 1e-9);
        assert!(
            (priority_cost_usd("openai/gpt-5.5-2026-01-01", 100_000, 0, 0) - 1.25).abs() < 1e-9
        );
        assert_eq!(
            priority_cost_usd("gpt-5.6-sol", 100_000, 0, 0),
            cost_usd("gpt-5.6-sol", 100_000, 0, 0)
        );
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
                token_count(&old, 1_000_000, 0, 0, 1_000_000), // $1.25, outside 30d
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

    #[test]
    fn default_roots_always_use_system_codex_home() {
        let _guard = crate::config::TEST_ENV_LOCK.lock().unwrap();
        let home = temp_base("system-home");
        std::env::set_var("CODEX_HOME", &home);

        let roots = default_roots();

        std::env::remove_var("CODEX_HOME");
        assert_eq!(
            roots,
            vec![home.join("sessions"), home.join("archived_sessions")]
        );
    }

    #[test]
    fn codex_project_key_is_domain_separated_normalized_and_private() {
        let identity = codex_project_identity("/Users/alice/private/../repo/").unwrap();

        assert_eq!(
            identity.key,
            "ad1f4957b96b2e55d2ae919d1d5d901cd9d763fe5beab90da12c5d361fb00f07"
        );
        assert_eq!(identity.display_name, "repo");
        assert!(!identity.key.contains("alice"));
        assert!(codex_project_identity("relative/repo").is_none());
        assert!(codex_project_identity("/Users/alice/secret\nrepo").is_none());
    }

    #[test]
    fn own_session_id_wins_over_root_session_id_for_subagents() {
        let value = serde_json::json!({
            "type": "session_meta",
            "payload": { "id": "subagent-id", "session_id": "root-id" }
        });

        let parsed = parse_codex_session_meta(&value).unwrap();

        assert_eq!(parsed.0.as_deref(), Some("subagent-id"));
    }

    #[test]
    fn duplicate_session_is_counted_once_and_project_matches_aggregate() {
        let base = temp_base("duplicate");
        let now = Local::now();
        let ts = now.to_rfc3339();
        let lines = [
            session_meta_with_cwd(&ts, "same-id", None, Some("/Users/alice/repo")),
            turn_context("gpt-5"),
            token_count(&ts, 100_000, 0, 0, 100_000),
        ];
        write_lines(&base.join("sessions"), "rollout-live.jsonl", &lines);
        write_lines(
            &base.join("archived_sessions"),
            "rollout-archived.jsonl",
            &lines,
        );

        let scan = scan_with_projects(
            &[base.join("sessions"), base.join("archived_sessions")],
            now,
        )
        .unwrap();

        assert_eq!(scan.usage.today_tokens, 100_000);
        assert_eq!(scan.projects.len(), 1);
        assert_eq!(scan.projects[0].tokens, scan.usage.today_tokens);
        assert_eq!(scan.projects[0].display_name, "repo");
        fs::remove_dir_all(&base).ok();
    }

    #[test]
    fn conflicting_duplicate_cwd_stays_in_unknown_residual() {
        let base = temp_base("conflicting-cwd");
        let now = Local::now();
        let ts = now.to_rfc3339();
        write_lines(
            &base.join("sessions"),
            "rollout-live.jsonl",
            &[
                session_meta_with_cwd(&ts, "same-id", None, Some("/Users/alice/one")),
                turn_context("gpt-5"),
                token_count(&ts, 100_000, 0, 0, 100_000),
            ],
        );
        write_lines(
            &base.join("archived_sessions"),
            "rollout-archived.jsonl",
            &[
                session_meta_with_cwd(&ts, "same-id", None, Some("/Users/alice/two")),
                turn_context("gpt-5"),
                token_count(&ts, 100_000, 0, 0, 100_000),
            ],
        );

        let scan = scan_with_projects(
            &[base.join("sessions"), base.join("archived_sessions")],
            now,
        )
        .unwrap();

        assert_eq!(scan.usage.today_tokens, 100_000);
        assert!(scan.projects.is_empty());
        assert_eq!(scan.retractions.len(), 1);
        let retraction = &scan.retractions[0];
        let old_project = codex_project_identity("/Users/alice/one").unwrap();
        assert_eq!(retraction.project_key, old_project.key);
        assert_eq!(retraction.retraction_id.len(), 64);
        assert!(!retraction.retraction_id.contains("same-id"));
        assert_eq!(retraction.contributions.len(), 1);
        assert_eq!(retraction.contributions[0].tokens, 100_000);
        assert_eq!(retraction.contributions[0].models[0].tokens, 100_000);
        fs::remove_dir_all(&base).ok();
    }

    #[test]
    fn later_duplicate_ambiguity_emits_stable_exact_retraction() {
        let base = temp_base("later-ambiguity");
        let now = Local::now();
        let ts = now.to_rfc3339();
        let session_lines = [
            session_meta_with_cwd(&ts, "private-session-id", None, Some("/work/a")),
            turn_context("gpt-5"),
            token_count(&ts, 80_000, 20_000, 20_000, 100_000),
        ];
        write_lines(&base.join("sessions"), "rollout-live.jsonl", &session_lines);

        let first = scan_with_projects(&[base.join("sessions")], now).unwrap();
        assert_eq!(first.projects.len(), 1);
        assert!(first.retractions.is_empty());

        let conflicting_lines = [
            session_meta_with_cwd(&ts, "private-session-id", None, Some("/work/b")),
            turn_context("gpt-5"),
            token_count(&ts, 80_000, 20_000, 20_000, 100_000),
            token_count(&ts, 20_000, 0, 0, 20_000),
        ];
        write_lines(
            &base.join("archived_sessions"),
            "rollout-archived.jsonl",
            &conflicting_lines,
        );
        let roots = [base.join("sessions"), base.join("archived_sessions")];
        let second = scan_with_projects(&roots, now).unwrap();
        let repeated = scan_with_projects(&roots, now).unwrap();

        assert!(second.projects.is_empty());
        assert_eq!(second.usage.today_tokens, 120_000);
        assert_eq!(second.retractions, repeated.retractions);
        assert_eq!(second.retractions.len(), 1);
        let retraction = &second.retractions[0];
        assert_eq!(
            retraction.retraction_id,
            codex_retraction_id("private-session-id", &first.projects[0].project_key)
        );
        assert_eq!(retraction.project_key, first.projects[0].project_key);
        assert_eq!(
            retraction.contributions[0].date,
            now.date_naive().to_string()
        );
        assert_eq!(retraction.contributions[0].tokens, 100_000);
        assert_eq!(retraction.contributions[0].models[0].name, "gpt-5");
        assert_eq!(retraction.contributions[0].models[0].tokens, 100_000);
        fs::remove_dir_all(&base).ok();
    }

    #[test]
    fn usage_without_valid_cwd_remains_unattributed() {
        let base = temp_base("missing-cwd");
        let now = Local::now();
        let ts = now.to_rfc3339();
        write_lines(
            &base.join("sessions"),
            "rollout-a.jsonl",
            &[
                session_meta_with_cwd(&ts, "relative-id", None, Some("relative/repo")),
                turn_context("gpt-5"),
                token_count(&ts, 100_000, 0, 0, 100_000),
            ],
        );
        write_lines(
            &base.join("sessions"),
            "rollout-no-meta.jsonl",
            &[
                turn_context("gpt-5"),
                token_count(&ts, 50_000, 0, 0, 50_000),
            ],
        );
        write_lines(
            &base.join("sessions"),
            "rollout-control.jsonl",
            &[
                session_meta_with_cwd(&ts, "control-id", None, Some("/Users/alice/secret\\nrepo")),
                turn_context("gpt-5"),
                token_count(&ts, 25_000, 0, 0, 25_000),
            ],
        );

        let scan = scan_with_projects(&[base.join("sessions")], now).unwrap();

        assert_eq!(scan.usage.today_tokens, 175_000);
        assert!(scan.projects.is_empty());
        fs::remove_dir_all(&base).ok();
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

    #[test]
    fn incremental_generation_preserves_exact_fork_and_project_math() {
        let base = temp_base("incremental-parity");
        let root = base.join("sessions");
        let now = Local::now();
        let ts = now.to_rfc3339();
        write_lines(
            &root,
            "rollout-parent.jsonl",
            &[
                session_meta_with_cwd(&ts, "parent", None, Some("/work/repo")),
                turn_context("gpt-5"),
                token_count_cumulative(&ts, (100_000, 0, 0, 100_000), (100_000, 0, 0, 100_000)),
            ],
        );
        write_lines(
            &root,
            "rollout-fork.jsonl",
            &[
                session_meta_with_cwd(&ts, "fork", Some("parent"), Some("/work/repo")),
                turn_context("gpt-5"),
                token_count_cumulative(&ts, (100_000, 0, 0, 100_000), (100_000, 0, 0, 100_000)),
                token_count_cumulative(&ts, (10_000, 0, 0, 10_000), (110_000, 0, 0, 110_000)),
            ],
        );
        write_lines(
            &root,
            "rollout-duplicate-a.jsonl",
            &[
                session_meta_with_cwd(&ts, "duplicate", None, Some("/work/alpha")),
                token_count(&ts, 20, 0, 0, 20),
            ],
        );
        write_lines(
            &root,
            "rollout-duplicate-b.jsonl",
            &[
                session_meta_with_cwd(&ts, "duplicate", None, Some("/work/beta")),
                token_count(&ts, 20, 0, 0, 20),
                token_count(&ts, 30, 0, 0, 30),
            ],
        );
        for name in [
            "rollout-parent.jsonl",
            "rollout-fork.jsonl",
            "rollout-duplicate-a.jsonl",
            "rollout-duplicate-b.jsonl",
        ] {
            let path = root.join(name);
            let mut content = fs::read_to_string(&path).unwrap();
            content.push('\n');
            fs::write(path, content).unwrap();
        }
        let exact = scan_with_projects(std::slice::from_ref(&root), now).unwrap();
        let mut state = incremental::discover(1, std::slice::from_ref(&root), None).unwrap();
        let mut spool = incremental_spool::Spool::open_memory().unwrap();
        while incremental::run_pass(&mut state, std::slice::from_ref(&root), &mut spool)
            == incremental::PassOutcome::Progress
        {}
        let bounded = scan_with_spool(
            std::slice::from_ref(&root),
            now,
            &HashMap::new(),
            &state,
            &spool,
            std::time::Instant::now() + std::time::Duration::from_secs(2),
        )
        .unwrap();
        assert_eq!(bounded.usage, exact.usage);
        assert_eq!(bounded.projects, exact.projects);
        assert_eq!(bounded.retractions, exact.retractions);
        fs::remove_dir_all(base).ok();
    }

    #[test]
    fn priority_completion_model_changes_cost_but_preserves_rollout_labels() {
        let base = temp_base("priority-rate");
        let root = base.join("sessions");
        fs::create_dir_all(&root).unwrap();
        let now = Local::now();
        let turn = priority::turn_digest("turn-1");
        let project = codex_project_identity("/work/repo").unwrap();
        let records = vec![
            incremental::SafeRecord::Meta {
                session: Some("safe-session-hash".into()),
                parent: None,
                timestamp_ms: Some(now.timestamp_millis()),
                project_key: Some(project.key),
                project_name: Some(project.display_name),
                retraction_id: Some("safe-retraction-hash".into()),
            },
            incremental::SafeRecord::Model("gpt-5".into()),
            incremental::SafeRecord::CurrentTurn(turn.clone()),
            incremental::SafeRecord::Token {
                timestamp_ms: now.timestamp_millis(),
                input: 100_000,
                cached: 0,
                output: 0,
                total: 100_000,
                cumulative: None,
                turn: None,
            },
        ];
        let loaded = HashMap::from([(root.join("rollout.jsonl"), records)]);
        let priority_turns = HashMap::from([(turn, Some("gpt-5.4".into()))]);
        let scan = scan_with_inputs(
            std::slice::from_ref(&root),
            now,
            &priority_turns,
            Some(&loaded),
        )
        .unwrap();
        assert!((scan.usage.today_usd - 0.5).abs() < 1e-9);
        assert_eq!(scan.usage.today_tokens, 100_000);
        // Vendored macOS semantics: completion model chooses the Priority
        // rate, while UI buckets retain the rollout model label.
        assert_eq!(scan.usage.top_model.as_deref(), Some("gpt-5"));
        assert_eq!(scan.usage.daily.last().unwrap().models[0].name, "gpt-5");
        assert_eq!(scan.projects[0].models[0].name, "gpt-5");
        fs::remove_dir_all(base).ok();
    }

    #[test]
    fn unknown_priority_completion_model_falls_back_to_rollout_price() {
        let base = temp_base("priority-unknown-model");
        let root = base.join("sessions");
        fs::create_dir_all(&root).unwrap();
        let now = Local::now();
        let turn = priority::turn_digest("turn-unknown");
        let records = vec![
            incremental::SafeRecord::Model("gpt-5".into()),
            incremental::SafeRecord::CurrentTurn(turn.clone()),
            incremental::SafeRecord::Token {
                timestamp_ms: now.timestamp_millis(),
                input: 100_000,
                cached: 0,
                output: 0,
                total: 100_000,
                cumulative: None,
                turn: None,
            },
        ];
        let loaded = HashMap::from([(root.join("rollout.jsonl"), records)]);
        let priority_turns = HashMap::from([(turn, Some("future-unknown-model".into()))]);
        let scan = scan_with_inputs(
            std::slice::from_ref(&root),
            now,
            &priority_turns,
            Some(&loaded),
        )
        .unwrap();
        assert!((scan.usage.today_usd - 0.125).abs() < 1e-9);
        assert_eq!(scan.usage.today_tokens, 100_000);
        fs::remove_dir_all(base).ok();
    }
}
