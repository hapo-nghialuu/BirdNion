//! Kiro CLI cost scanner — port of macOS `KiroCostScanner.swift`.
//!
//! Ba thế hệ lưu trữ được quét, đúng thứ tự macOS (archive -> sqlite -> cli),
//! gộp theo id session/conversation và ưu tiên bản `updated_at` mới nhất:
//!   - `~/.kiro_sessions/*.json` — archive cũ (tùy chọn).
//!   - `~/.local/share/kiro-cli/data.sqlite3` (hoặc `$XDG_DATA_HOME/kiro-cli/...`)
//!     — CLI thế hệ cũ hơn, bảng `conversations_v2` + `conversations`.
//!   - `~/.kiro/sessions/cli/<id>.json` — TUI kiro-cli hiện tại (BẮT BUỘC).
//!     USD là số credit BỊ TÍNH PHÍ THẬT (`metering_usage`) × $0.04/credit.
//! Không có dữ liệu thật thì trả về báo cáo trống — không suy diễn số liệu.

use chrono::{DateTime, Duration, Local, NaiveDate, TimeZone};
use rusqlite::{Connection, OpenFlags};
use serde_json::Value;
use std::collections::HashMap;
use std::io::Read as _;
use std::path::{Path, PathBuf};

use crate::usage::{DailyModel, DailyUsage, UsageReport};

pub const HISTORY_DAYS: i64 = 120;
/// UTF-8 byte token estimation + full-window model conservation.
pub const COUNTING_REVISION: i64 = 2;
const CHARS_PER_TOKEN: i64 = 4;
/// Kiro bills in credits; add-on/overage credits are $0.04 each
/// (kiro.dev/pricing) — chuyển credit bị tính phí thật sang USD.
const USD_PER_CREDIT: f64 = 0.04;
const DEFAULT_CONTEXT_WINDOW_TOKENS: i64 = 200_000;
const MAX_TOKENS_PER_FIELD: i64 = 10_000_000_000;
const MAX_CONTEXT_WINDOW_TOKENS: i64 = 10_000_000_000;
const MAX_CREDITS_PER_TURN: f64 = 1_000_000_000.0;
const MAX_JSON_FILE_BYTES: u64 = 64 * 1024 * 1024;
const MAX_SCAN_JSON_BYTES: u64 = 256 * 1024 * 1024;
const MAX_SOURCE_ENTRIES: usize = 20_000;
const MAX_JSON_STRUCTURE_UNITS: usize = 100_000;
const MAX_JSON_NESTING_DEPTH: usize = 64;
const MAX_SEMANTIC_LABEL_BYTES: usize = 512;
const AGGREGATE_MODEL_NAME: &str = "Other";
const MAX_FUTURE_CLOCK_SKEW_MINUTES: i64 = 5;
const CLI_INTEGER_TURN_KEYS: &[&str] = &["input_token_count", "output_token_count"];
const UNSUPPORTED_CLI_INTEGER_TURN_KEYS: &[&str] = &[
    "input_tokens_count",
    "output_tokens_count",
    "cache_read_input_token_count",
    "cache_creation_input_token_count",
    "cache_read_input_tokens_count",
    "cache_creation_input_tokens_count",
];
const CONVERSATION_TURN_IDENTITY_KEYS: &[&str] = &["user", "assistant", "request_metadata"];

pub struct KiroUsageScan {
    pub usage: UsageReport,
    /// True only when at least one storage generation was available and every
    /// available generation was read and validated to completion.
    pub completed: bool,
}

#[derive(Clone, Copy)]
struct SourceLoad {
    available: bool,
    completed: bool,
}

impl SourceLoad {
    const fn missing() -> Self {
        Self {
            available: false,
            completed: true,
        }
    }

    const fn available(completed: bool) -> Self {
        Self {
            available: true,
            completed,
        }
    }
}

/// Bảng giá theo $/MTok (write/read/output) cho các model Kiro hay host,
/// dùng cho thế hệ SQLite/archive (ước lượng chars÷4, không phải credit thật).
struct KiroModelPrice {
    write_per_m: f64,
    read_per_m: f64,
    output_per_m: f64,
}

impl KiroModelPrice {
    fn for_model(model: &str) -> Self {
        let m = model.to_lowercase();
        if m.contains("opus-4.6")
            || m.contains("opus-4-6")
            || m.contains("opus-4.5")
            || m.contains("opus-4-5")
        {
            return Self {
                write_per_m: 6.25,
                read_per_m: 0.50,
                output_per_m: 25.0,
            };
        }
        if m.contains("opus") {
            return Self {
                write_per_m: 18.75,
                read_per_m: 1.50,
                output_per_m: 75.0,
            };
        }
        if m.contains("sonnet") {
            return Self {
                write_per_m: 3.75,
                read_per_m: 0.30,
                output_per_m: 15.0,
            };
        }
        if m.contains("haiku") {
            return Self {
                write_per_m: 1.25,
                read_per_m: 0.10,
                output_per_m: 5.0,
            };
        }
        // Model không rõ / free tier: mặc định theo giá Opus 4.5 để vẫn hiển thị chi phí.
        Self {
            write_per_m: 6.25,
            read_per_m: 0.50,
            output_per_m: 25.0,
        }
    }

    fn estimate_usd(cache_write: i64, cache_read: i64, output: i64, model: &str) -> f64 {
        let p = Self::for_model(model);
        (cache_write as f64 * p.write_per_m
            + cache_read as f64 * p.read_per_m
            + output as f64 * p.output_per_m)
            / 1_000_000.0
    }
}

struct SessionPoint {
    day: NaiveDate,
    tokens: i64,
    usd: f64,
    model: String,
}

/// Full scan using the real `$HOME`. Returns an empty report (never
/// fabricated numbers) when `$HOME` is unset or no storage generation is
/// readable.
pub fn scan_kiro_usage(now: DateTime<Local>) -> KiroUsageScan {
    let Ok(home) = std::env::var("HOME") else {
        return KiroUsageScan {
            usage: UsageReport::default(),
            completed: false,
        };
    };
    if home.trim().is_empty() {
        return KiroUsageScan {
            usage: UsageReport::default(),
            completed: false,
        };
    }
    scan_kiro_usage_at(Path::new(&home), now)
}

/// Path-injectable core scan — unit-testable without touching real `$HOME`.
fn scan_kiro_usage_at(home: &Path, now: DateTime<Local>) -> KiroUsageScan {
    let db_path = cli_db_path(home);
    scan_kiro_usage_at_paths(home, &db_path, now)
}

fn history_cutoff_date(now: &DateTime<Local>) -> NaiveDate {
    now.date_naive() - Duration::days(HISTORY_DAYS - 1)
}

fn scan_kiro_usage_at_paths(home: &Path, db_path: &Path, now: DateTime<Local>) -> KiroUsageScan {
    let cutoff_days = HISTORY_DAYS - 1;
    let cutoff_date = history_cutoff_date(&now);
    let latest_accepted_ms =
        (now + Duration::minutes(MAX_FUTURE_CLOCK_SKEW_MINUTES)).timestamp_millis();
    let cutoff_ms = cutoff_date
        .and_hms_opt(0, 0, 0)
        .and_then(|dt| Local.from_local_datetime(&dt).single())
        .map(|dt| dt.timestamp_millis())
        .unwrap_or_else(|| now.timestamp_millis() - cutoff_days * 86_400_000);

    // Gộp theo session/conversation id: id -> (updated_at ms, points). Nguồn
    // xử lý sau chỉ thắng nguồn trước khi updated_at THỰC SỰ mới hơn, giống
    // `loadPointsResult` bên Swift.
    let mut by_id: HashMap<String, (i64, Vec<SessionPoint>)> = HashMap::new();
    let mut scan_bytes = 0;
    let mut structure_units = 0;

    let archive = load_archive(
        home,
        cutoff_ms,
        cutoff_date,
        latest_accepted_ms,
        &mut by_id,
        &mut scan_bytes,
        &mut structure_units,
    );
    let sqlite = load_sqlite(
        db_path,
        cutoff_ms,
        cutoff_date,
        latest_accepted_ms,
        &mut by_id,
        &mut scan_bytes,
        &mut structure_units,
    );
    let cli = load_cli_sessions(
        home,
        cutoff_ms,
        cutoff_date,
        latest_accepted_ms,
        &mut by_id,
        &mut scan_bytes,
        &mut structure_units,
    );
    let sources = [archive, sqlite, cli];
    let completed = sources.iter().any(|source| source.available)
        && sources
            .iter()
            .filter(|source| source.available)
            .all(|source| source.completed);

    let points: Vec<SessionPoint> = by_id.into_values().flat_map(|(_, pts)| pts).collect();
    let Some(usage) = build_report(points, now) else {
        return KiroUsageScan {
            usage: UsageReport::default(),
            completed: false,
        };
    };
    KiroUsageScan { usage, completed }
}

fn merge_points(
    by_id: &mut HashMap<String, (i64, Vec<SessionPoint>)>,
    id: String,
    updated_ms: i64,
    points: Vec<SessionPoint>,
) {
    if let Some((existing_updated, _)) = by_id.get(&id) {
        if *existing_updated >= updated_ms {
            return;
        }
    }
    by_id.insert(id, (updated_ms, points));
}

fn admit_source_entry(count: &mut usize, maximum: usize) -> bool {
    if *count >= maximum {
        return false;
    }
    *count += 1;
    true
}

fn admit_source_bytes(consumed: &mut u64, length: u64, maximum: u64) -> bool {
    let Some(remaining) = maximum.checked_sub(*consumed) else {
        return false;
    };
    if length > remaining {
        return false;
    }
    *consumed += length;
    true
}

fn bounded_semantic_label(value: &str) -> Option<&str> {
    let normalized = value.trim();
    (!normalized.is_empty()
        && normalized.len() <= MAX_SEMANTIC_LABEL_BYTES
        && !normalized.chars().any(char::is_control))
    .then_some(normalized)
}

fn normalized_model_id(value: Option<&Value>) -> Option<&str> {
    match value {
        None => Some("kiro"),
        Some(value) => {
            let raw = value.as_str()?;
            if raw.trim().is_empty() {
                Some("kiro")
            } else if raw.trim() == AGGREGATE_MODEL_NAME {
                None
            } else {
                bounded_semantic_label(raw)
            }
        }
    }
}

fn payload_length_within_limit(length: i64, maximum: u64) -> bool {
    u64::try_from(length).is_ok_and(|length| length <= maximum)
}

fn read_utf8_file_bounded(path: &Path, maximum: u64) -> Option<String> {
    #[cfg(unix)]
    let file = {
        use std::os::unix::fs::OpenOptionsExt as _;
        std::fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
            .open(path)
            .ok()?
    };
    #[cfg(not(unix))]
    let file = std::fs::File::open(path).ok()?;
    let metadata = file.metadata().ok()?;
    if !metadata.is_file() || metadata.len() > maximum {
        return None;
    }
    let mut bytes = Vec::new();
    file.take(maximum.saturating_add(1))
        .read_to_end(&mut bytes)
        .ok()?;
    if bytes.len() as u64 > maximum {
        return None;
    }
    String::from_utf8(bytes).ok()
}

/// Bounds decoded JSON cardinality and depth before serde builds its object
/// graph. Structural bytes inside strings are ignored.
fn admit_json_structure(bytes: &[u8], consumed: &mut usize) -> bool {
    if *consumed > MAX_JSON_STRUCTURE_UNITS {
        return false;
    }
    let mut units = 0_usize;
    let mut depth = 0_usize;
    let mut in_string = false;
    let mut escaped = false;
    for byte in bytes {
        if in_string {
            if escaped {
                escaped = false;
            } else if *byte == b'\\' {
                escaped = true;
            } else if *byte == b'"' {
                in_string = false;
            }
            continue;
        }
        if *byte == b'"' {
            in_string = true;
            continue;
        }
        match *byte {
            b'{' | b'[' => {
                depth += 1;
                if depth > MAX_JSON_NESTING_DEPTH {
                    return false;
                }
                units += 1;
            }
            b'}' | b']' => {
                let Some(next_depth) = depth.checked_sub(1) else {
                    return false;
                };
                depth = next_depth;
            }
            b',' => units += 1,
            _ => {}
        }
        if units > MAX_JSON_STRUCTURE_UNITS - *consumed {
            return false;
        }
    }
    if in_string || depth != 0 {
        return false;
    }
    *consumed += units;
    true
}

// --- Generation: ~/.kiro/sessions/cli/<id>.json (MANDATORY) ---------------

fn cli_sessions_dir(home: &Path) -> PathBuf {
    home.join(".kiro").join("sessions").join("cli")
}

/// TUI kiro-cli hiện tại lưu mỗi session thành `cli/<id>.json` (metadata +
/// metering theo turn); các bảng SQLite cũ vẫn trống trên bản build này.
fn load_cli_sessions(
    home: &Path,
    cutoff_ms: i64,
    cutoff_date: NaiveDate,
    latest_accepted_ms: i64,
    by_id: &mut HashMap<String, (i64, Vec<SessionPoint>)>,
    scan_bytes: &mut u64,
    structure_units: &mut usize,
) -> SourceLoad {
    let dir = cli_sessions_dir(home);
    match std::fs::symlink_metadata(&dir) {
        Ok(metadata) if metadata.file_type().is_dir() => {}
        Ok(_) => return SourceLoad::available(false),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return SourceLoad::missing(),
        Err(_) => return SourceLoad::available(false),
    }
    let Ok(entries) = std::fs::read_dir(&dir) else {
        return SourceLoad::available(false);
    };
    let mut completed = true;
    let mut entry_count = 0;
    let mut saw_candidate = false;
    for entry in entries {
        let Ok(entry) = entry else {
            completed = false;
            continue;
        };
        let path = entry.path();
        if !admit_source_entry(&mut entry_count, MAX_SOURCE_ENTRIES) {
            completed = false;
            break;
        }
        if path.extension().and_then(|s| s.to_str()) != Some("json") {
            continue;
        }
        saw_candidate = true;
        let Ok(metadata) = entry.metadata() else {
            completed = false;
            continue;
        };
        if !metadata.is_file() || metadata.len() > MAX_JSON_FILE_BYTES {
            completed = false;
            continue;
        }
        if !admit_source_bytes(scan_bytes, metadata.len(), MAX_SCAN_JSON_BYTES) {
            completed = false;
            break;
        }
        let Some(text) = read_utf8_file_bounded(&path, MAX_JSON_FILE_BYTES) else {
            completed = false;
            continue;
        };
        let actual_length = text.len() as u64;
        if actual_length > metadata.len()
            && !admit_source_bytes(
                scan_bytes,
                actual_length - metadata.len(),
                MAX_SCAN_JSON_BYTES,
            )
        {
            completed = false;
            break;
        }
        if !admit_json_structure(text.as_bytes(), structure_units) {
            completed = false;
            break;
        }
        let Ok(json) = serde_json::from_str::<Value>(&text) else {
            completed = false;
            continue;
        };
        if !has_cli_session_schema(&json, latest_accepted_ms) {
            completed = false;
            continue;
        }
        let sid = match json.get("session_id") {
            Some(value) => value
                .as_str()
                .and_then(bounded_semantic_label)
                .map(str::to_string),
            None => path
                .file_stem()
                .and_then(|value| value.to_str())
                .and_then(bounded_semantic_label)
                .map(str::to_string),
        };
        let Some(sid) = sid else {
            completed = false;
            continue;
        };

        let Some(updated_ms) = cli_session_activity_ms(&json, latest_accepted_ms) else {
            completed = false;
            continue;
        };
        if updated_ms > 0 && updated_ms < cutoff_ms {
            continue;
        }

        let Some(points) = parse_cli_session_sidecar(&json, cutoff_date, latest_accepted_ms) else {
            completed = false;
            continue;
        };
        if points.is_empty() {
            continue;
        }
        merge_points(by_id, sid, updated_ms, points);
    }
    if saw_candidate {
        SourceLoad::available(completed)
    } else {
        SourceLoad::missing()
    }
}

fn cli_session_activity_ms(json: &Value, latest_accepted_ms: i64) -> Option<i64> {
    if let Some(updated) = optional_iso_date(json, "updated_at", latest_accepted_ms)? {
        return Some(updated.timestamp_millis());
    }

    let mut latest = optional_iso_date(json, "created_at", latest_accepted_ms)?;
    let turns = json
        .pointer("/session_state/conversation_metadata/user_turn_metadatas")
        .and_then(Value::as_array)?;
    for turn in turns {
        if let Some(activity) = optional_iso_date(turn, "end_timestamp", latest_accepted_ms)? {
            if latest
                .as_ref()
                .map_or(true, |existing| &activity > existing)
            {
                latest = Some(activity);
            }
        }
    }
    Some(latest.map_or(0, |activity| activity.timestamp_millis()))
}

/// One sidecar -> per-day SessionPoints. USD là REAL (credit `metering_usage`
/// mỗi turn × $0.04); token ưu tiên số đếm chính xác của CLI, fallback sang
/// tăng trưởng context-window (delta `context_usage_percentage` × cửa sổ)
/// khi CLI trả về 0.
fn parse_cli_session_sidecar(
    json: &Value,
    cutoff_date: NaiveDate,
    latest_accepted_ms: i64,
) -> Option<Vec<SessionPoint>> {
    let Some(turns) = json
        .pointer("/session_state/conversation_metadata/user_turn_metadatas")
        .and_then(Value::as_array)
    else {
        return Some(Vec::new());
    };
    if turns.is_empty() {
        return Some(Vec::new());
    }

    let model =
        normalized_model_id(json.pointer("/session_state/rts_model_state/model_info/model_id"))?
            .to_string();
    let context_window =
        match json.pointer("/session_state/rts_model_state/model_info/context_window_tokens") {
            Some(value) => match bounded_nonnegative_integer(value, MAX_CONTEXT_WINDOW_TOKENS)? {
                0 => DEFAULT_CONTEXT_WINDOW_TOKENS,
                window => window,
            },
            None => DEFAULT_CONTEXT_WINDOW_TOKENS,
        };

    let session_created = optional_iso_date(json, "created_at", latest_accepted_ms)?;

    let mut prev_pct = 0.0_f64;
    let mut buckets: HashMap<NaiveDate, (i64, f64)> = HashMap::new();

    for turn in turns {
        if UNSUPPORTED_CLI_INTEGER_TURN_KEYS
            .iter()
            .any(|key| turn.get(*key).is_some())
        {
            return None;
        }
        // Real billed credits for the turn (one entry per request).
        let mut credits = 0.0_f64;
        if let Some(raw_entries) = turn.get("metering_usage") {
            let entries = raw_entries.as_array()?;
            for e in entries {
                let entry = e.as_object()?;
                let unit = entry.get("unit").and_then(Value::as_str)?.trim();
                if unit.is_empty() {
                    return None;
                }
                let value = entry
                    .get("value")
                    .and_then(|value| bounded_nonnegative_number(value, MAX_CREDITS_PER_TURN))?;
                if !unit.to_ascii_lowercase().contains("credit") {
                    continue;
                }
                credits = checked_bounded_float_add(credits, value, MAX_CREDITS_PER_TURN)?;
            }
        }
        let usd = checked_nonnegative_float_product(credits, USD_PER_CREDIT)?;

        // Exact token counts when the CLI populates them; else grow-of-context
        // estimate (context_usage_percentage là lũy tiến, nên delta theo turn
        // mới là phần turn này thêm vào; kẹp về 0 vì compaction có thể giảm nó).
        let input_tokens = optional_token_count(turn, "input_token_count")?;
        let output_tokens = optional_token_count(turn, "output_token_count")?;
        let mut tokens = input_tokens.checked_add(output_tokens)?;
        let pct = optional_percentage(turn, "context_usage_percentage")?;
        if tokens == 0 && pct > 0.0 {
            let delta = (pct - prev_pct).max(0.0);
            let estimate = checked_nonnegative_float_product(delta / 100.0, context_window as f64)?;
            if estimate > MAX_CONTEXT_WINDOW_TOKENS as f64 {
                return None;
            }
            tokens = estimate.round() as i64;
        }
        if pct > 0.0 {
            prev_pct = pct;
        }

        let turn_timestamp = optional_iso_date(turn, "end_timestamp", latest_accepted_ms)?;
        if tokens <= 0 && usd <= 0.0 {
            continue;
        }
        let active_at = turn_timestamp.or_else(|| session_created.clone())?;
        let day = active_at.date_naive();
        if day < cutoff_date {
            continue;
        }

        let acc = buckets.entry(day).or_insert((0, 0.0));
        acc.0 = acc.0.checked_add(tokens)?;
        acc.1 = checked_nonnegative_float_add(acc.1, usd)?;
    }

    Some(
        buckets
            .into_iter()
            .map(|(day, (tokens, usd))| SessionPoint {
                day,
                tokens,
                usd,
                model: model.clone(),
            })
            .collect(),
    )
}

/// ISO8601 with or without fractional seconds ("2026-07-15T06:20:44.636576Z").
fn parse_iso_date(raw: &str) -> Option<DateTime<Local>> {
    if raw.is_empty() {
        return None;
    }
    DateTime::parse_from_rfc3339(raw)
        .ok()
        .map(|dt| dt.with_timezone(&Local))
}

// --- Generation: ~/.local/share/kiro-cli/data.sqlite3 ----------------------

fn cli_db_path(home: &Path) -> PathBuf {
    let xdg_data_home = std::env::var_os("XDG_DATA_HOME")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from);
    cli_db_path_with_xdg(home, xdg_data_home.as_deref())
}

fn cli_db_path_with_xdg(home: &Path, xdg_data_home: Option<&Path>) -> PathBuf {
    let default = home
        .join(".local")
        .join("share")
        .join("kiro-cli")
        .join("data.sqlite3");
    xdg_data_home
        .filter(|root| root.is_absolute())
        .map(|root| root.join("kiro-cli").join("data.sqlite3"))
        .filter(|path| path.is_file())
        .unwrap_or(default)
}

#[derive(Clone)]
struct SqliteFileSnapshot {
    role: SqliteFileRole,
    #[cfg(not(unix))]
    path: PathBuf,
    #[cfg(unix)]
    device: u64,
    #[cfg(unix)]
    inode: u64,
}

#[derive(Clone, Copy, Eq, PartialEq)]
enum SqliteFileRole {
    Database,
    Wal,
    Shm,
}

impl SqliteFileSnapshot {
    fn same_identity(&self, other: &Self) -> bool {
        if self.role != other.role {
            return false;
        }
        #[cfg(unix)]
        {
            self.device == other.device && self.inode == other.inode
        }
        #[cfg(not(unix))]
        {
            self.path == other.path
        }
    }
}

struct SqliteStorageSnapshot {
    files: Vec<SqliteFileSnapshot>,
    total: u64,
}

impl SqliteStorageSnapshot {
    fn preserves_identities_from(&self, previous: &Self) -> bool {
        previous
            .files
            .iter()
            .all(|old| self.files.iter().any(|current| old.same_identity(current)))
    }
}

fn sqlite_storage_snapshot(db_path: &Path) -> Option<SqliteStorageSnapshot> {
    #[cfg(unix)]
    use std::os::unix::fs::MetadataExt as _;

    let mut paths = vec![(SqliteFileRole::Database, db_path.to_path_buf())];
    for (role, suffix) in [(SqliteFileRole::Wal, "-wal"), (SqliteFileRole::Shm, "-shm")] {
        let mut sidecar = db_path.as_os_str().to_os_string();
        sidecar.push(suffix);
        paths.push((role, PathBuf::from(sidecar)));
    }

    let mut total = 0_u64;
    let mut files = Vec::with_capacity(paths.len());
    for (index, (role, path)) in paths.iter().enumerate() {
        let metadata = match std::fs::symlink_metadata(path) {
            Ok(metadata) => metadata,
            Err(error) if index > 0 && error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(_) => return None,
        };
        if !metadata.file_type().is_file() {
            return None;
        }
        let Some(next) = total.checked_add(metadata.len()) else {
            return None;
        };
        total = next;
        files.push(SqliteFileSnapshot {
            role: *role,
            #[cfg(not(unix))]
            path: path.clone(),
            #[cfg(unix)]
            device: metadata.dev(),
            #[cfg(unix)]
            inode: metadata.ino(),
        });
    }
    Some(SqliteStorageSnapshot { files, total })
}

fn reconcile_sqlite_storage(
    previous: &SqliteStorageSnapshot,
    current: &SqliteStorageSnapshot,
    charged_bytes: &mut u64,
    scan_bytes: &mut u64,
) -> bool {
    if !current.preserves_identities_from(previous) {
        return false;
    }
    let additional = current.total.saturating_sub(*charged_bytes);
    if additional > 0 && !admit_source_bytes(scan_bytes, additional, MAX_SCAN_JSON_BYTES) {
        return false;
    }
    *charged_bytes = (*charged_bytes).max(current.total);
    true
}

fn load_sqlite(
    db_path: &Path,
    cutoff_ms: i64,
    cutoff_date: NaiveDate,
    latest_accepted_ms: i64,
    by_id: &mut HashMap<String, (i64, Vec<SessionPoint>)>,
    scan_bytes: &mut u64,
    structure_units: &mut usize,
) -> SourceLoad {
    match std::fs::symlink_metadata(db_path) {
        Ok(metadata) if metadata.file_type().is_file() => {}
        Ok(_) => return SourceLoad::available(false),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return SourceLoad::missing(),
        Err(_) => return SourceLoad::available(false),
    }
    // A WHERE scan can traverse every page even when it returns no rows.
    // Bound the physical DB + WAL/SHM before SQLite starts that work.
    let Some(initial_storage) = sqlite_storage_snapshot(db_path) else {
        return SourceLoad::available(false);
    };
    if !admit_source_bytes(scan_bytes, initial_storage.total, MAX_SCAN_JSON_BYTES) {
        return SourceLoad::available(false);
    }
    let mut charged_storage_bytes = initial_storage.total;
    // NOFOLLOW rejects symlinks in any path component (macOS `/var` included).
    // Resolve the existing regular entry, then prove its role/inode still
    // matches the lstat snapshot before SQLite receives the canonical path.
    let Ok(open_path) = std::fs::canonicalize(db_path) else {
        return SourceLoad::available(false);
    };
    let Some(resolved_storage) = sqlite_storage_snapshot(&open_path) else {
        return SourceLoad::available(false);
    };
    if !reconcile_sqlite_storage(
        &initial_storage,
        &resolved_storage,
        &mut charged_storage_bytes,
        scan_bytes,
    ) {
        return SourceLoad::available(false);
    }
    // Read-only vẫn quan sát WAL đã commit; BUSY/error được fail-closed.
    let flags = OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NOFOLLOW;
    let Ok(conn) = Connection::open_with_flags(&open_path, flags) else {
        return SourceLoad::available(false);
    };
    let Some(opened_storage) = sqlite_storage_snapshot(&open_path) else {
        return SourceLoad::available(false);
    };
    if !reconcile_sqlite_storage(
        &resolved_storage,
        &opened_storage,
        &mut charged_storage_bytes,
        scan_bytes,
    ) {
        return SourceLoad::available(false);
    }
    let _ = conn.busy_timeout(std::time::Duration::from_millis(200));
    let recognized_schema = match (
        sqlite_table_exists(&conn, "conversations_v2"),
        sqlite_table_exists(&conn, "conversations"),
    ) {
        (Ok(v2), Ok(v1)) => v2 || v1,
        _ => return SourceLoad::available(false),
    };
    if !recognized_schema {
        return SourceLoad::available(false);
    }

    // Physical storage is charged to the shared source budget above. Keep a
    // separate decoded-payload guard so the same DB pages are not counted
    // twice while materialized JSON remains bounded.
    let mut sqlite_payload_bytes = 0;
    let mut sqlite_by_id = HashMap::new();
    let v2 = query_conversations_v2(
        &conn,
        cutoff_ms,
        cutoff_date,
        latest_accepted_ms,
        MAX_SOURCE_ENTRIES,
        MAX_JSON_FILE_BYTES,
        &mut sqlite_payload_bytes,
        MAX_SCAN_JSON_BYTES,
        structure_units,
        &mut sqlite_by_id,
    );
    let v1 = query_conversations_v1(
        &conn,
        cutoff_ms,
        cutoff_date,
        latest_accepted_ms,
        MAX_SOURCE_ENTRIES,
        MAX_JSON_FILE_BYTES,
        &mut sqlite_payload_bytes,
        MAX_SCAN_JSON_BYTES,
        structure_units,
        &mut sqlite_by_id,
    );
    let Some(final_storage) = sqlite_storage_snapshot(&open_path) else {
        return SourceLoad::available(false);
    };
    // Do not publish rows if the DB identity changed or physical storage grew
    // beyond the shared scan budget while SQLite was reading it.
    if !reconcile_sqlite_storage(
        &opened_storage,
        &final_storage,
        &mut charged_storage_bytes,
        scan_bytes,
    ) {
        return SourceLoad::available(false);
    }
    for (id, (updated_ms, points)) in sqlite_by_id {
        merge_points(by_id, id, updated_ms, points);
    }
    if !v2.available && !v1.available && v2.completed && v1.completed {
        SourceLoad::missing()
    } else {
        SourceLoad::available(v2.completed && v1.completed)
    }
}

/// `conversations_v2` (kiro-cli cũ hơn).
fn query_conversations_v2(
    conn: &Connection,
    cutoff_ms: i64,
    cutoff_date: NaiveDate,
    latest_accepted_ms: i64,
    max_rows: usize,
    max_payload_bytes: u64,
    source_bytes: &mut u64,
    max_source_bytes: u64,
    structure_units: &mut usize,
    by_id: &mut HashMap<String, (i64, Vec<SessionPoint>)>,
) -> SourceLoad {
    match sqlite_table_exists(conn, "conversations_v2") {
        Ok(true) => {}
        Ok(false) => return SourceLoad::missing(),
        Err(_) => return SourceLoad::available(false),
    }
    let sql = "SELECT conversation_id, created_at, updated_at, length(CAST(value AS BLOB)), value FROM conversations_v2 WHERE updated_at >= ?";
    let Ok(mut stmt) = conn.prepare(sql) else {
        return SourceLoad::available(false);
    };
    let Ok(mut rows) = stmt.query([cutoff_ms]) else {
        return SourceLoad::available(false);
    };
    let mut completed = true;
    let mut row_count = 0;
    loop {
        let row = match rows.next() {
            Ok(Some(row)) => row,
            Ok(None) => break,
            Err(_) => {
                completed = false;
                break;
            }
        };
        if !admit_source_entry(&mut row_count, max_rows) {
            completed = false;
            break;
        }
        let cid: Option<String> = row
            .get::<_, String>(0)
            .ok()
            .and_then(|value| bounded_semantic_label(&value).map(str::to_string));
        let Some(cid) = cid else {
            completed = false;
            continue;
        };
        let Ok(created) = row.get::<_, i64>(1) else {
            completed = false;
            continue;
        };
        let Ok(updated) = row.get::<_, i64>(2) else {
            completed = false;
            continue;
        };
        if created <= 0
            || updated <= 0
            || timestamp_ms_date(created, latest_accepted_ms).is_none()
            || timestamp_ms_date(updated, latest_accepted_ms).is_none()
        {
            completed = false;
            continue;
        }
        let Ok(payload_length) = row.get::<_, i64>(3) else {
            completed = false;
            continue;
        };
        if !payload_length_within_limit(payload_length, max_payload_bytes) {
            completed = false;
            continue;
        }
        let payload_length = payload_length as u64;
        if !admit_source_bytes(source_bytes, payload_length, max_source_bytes) {
            completed = false;
            break;
        }
        let Ok(raw) = row.get::<_, String>(4) else {
            completed = false;
            continue;
        };
        if !admit_json_structure(raw.as_bytes(), structure_units) {
            completed = false;
            break;
        }
        let Ok(value) = serde_json::from_str::<Value>(&raw) else {
            completed = false;
            continue;
        };
        if !has_conversation_schema(&value, created, latest_accepted_ms) {
            completed = false;
            continue;
        }
        let Some(points) = parse_conversation(&value, created, cutoff_date, latest_accepted_ms)
        else {
            completed = false;
            continue;
        };
        if points.is_empty() {
            continue;
        }
        merge_points(by_id, cid, updated, points);
    }
    if row_count == 0 && completed {
        SourceLoad::missing()
    } else {
        SourceLoad::available(completed)
    }
}

/// `conversations` (kiro-cli 2.0.1+, không có cột updated_at riêng — lấy mốc
/// thời gian từ `request_metadata` của lượt đầu/cuối trong `history`).
fn query_conversations_v1(
    conn: &Connection,
    cutoff_ms: i64,
    cutoff_date: NaiveDate,
    latest_accepted_ms: i64,
    max_rows: usize,
    max_payload_bytes: u64,
    source_bytes: &mut u64,
    max_source_bytes: u64,
    structure_units: &mut usize,
    by_id: &mut HashMap<String, (i64, Vec<SessionPoint>)>,
) -> SourceLoad {
    match sqlite_table_exists(conn, "conversations") {
        Ok(true) => {}
        Ok(false) => return SourceLoad::missing(),
        Err(_) => return SourceLoad::available(false),
    }
    let sql = "SELECT length(CAST(value AS BLOB)), value FROM conversations";
    let Ok(mut stmt) = conn.prepare(sql) else {
        return SourceLoad::available(false);
    };
    let Ok(mut rows) = stmt.query([]) else {
        return SourceLoad::available(false);
    };
    let mut completed = true;
    let mut row_count = 0;
    loop {
        let row = match rows.next() {
            Ok(Some(row)) => row,
            Ok(None) => break,
            Err(_) => {
                completed = false;
                break;
            }
        };
        if !admit_source_entry(&mut row_count, max_rows) {
            completed = false;
            break;
        }
        let Ok(payload_length) = row.get::<_, i64>(0) else {
            completed = false;
            continue;
        };
        if !payload_length_within_limit(payload_length, max_payload_bytes) {
            completed = false;
            continue;
        }
        let payload_length = payload_length as u64;
        if !admit_source_bytes(source_bytes, payload_length, max_source_bytes) {
            completed = false;
            break;
        }
        let Ok(raw) = row.get::<_, String>(1) else {
            completed = false;
            continue;
        };
        if !admit_json_structure(raw.as_bytes(), structure_units) {
            completed = false;
            break;
        }
        let Ok(value) = serde_json::from_str::<Value>(&raw) else {
            completed = false;
            continue;
        };
        let Some(cid) = value
            .get("conversation_id")
            .and_then(Value::as_str)
            .and_then(bounded_semantic_label)
            .map(str::to_string)
        else {
            completed = false;
            continue;
        };
        let Some(history) = value.get("history").and_then(Value::as_array) else {
            completed = false;
            continue;
        };
        if history.is_empty() {
            completed = false;
            continue;
        }
        let first = history
            .first()
            .and_then(|t| t.pointer("/request_metadata/request_start_timestamp_ms"))
            .and_then(positive_timestamp_ms)
            .unwrap_or(0);
        let last = history
            .last()
            .and_then(|t| t.pointer("/request_metadata/request_start_timestamp_ms"))
            .and_then(positive_timestamp_ms)
            .unwrap_or(first);
        if !has_conversation_schema(&value, first, latest_accepted_ms) {
            completed = false;
            continue;
        }
        let Some(points) = parse_conversation(&value, first, cutoff_date, latest_accepted_ms)
        else {
            completed = false;
            continue;
        };
        if last < cutoff_ms {
            continue;
        }
        if points.is_empty() {
            continue;
        }
        merge_points(by_id, cid, last, points);
    }
    if row_count == 0 && completed {
        SourceLoad::missing()
    } else {
        SourceLoad::available(completed)
    }
}

fn sqlite_table_exists(conn: &Connection, name: &str) -> rusqlite::Result<bool> {
    conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1)",
        [name],
        |row| row.get::<_, bool>(0),
    )
}

// --- Generation: ~/.kiro_sessions/*.json archives ---------------------------

fn archive_dir(home: &Path) -> PathBuf {
    home.join(".kiro_sessions")
}

fn load_archive(
    home: &Path,
    cutoff_ms: i64,
    cutoff_date: NaiveDate,
    latest_accepted_ms: i64,
    by_id: &mut HashMap<String, (i64, Vec<SessionPoint>)>,
    scan_bytes: &mut u64,
    structure_units: &mut usize,
) -> SourceLoad {
    let dir = archive_dir(home);
    match std::fs::symlink_metadata(&dir) {
        Ok(metadata) if metadata.file_type().is_dir() => {}
        Ok(_) => return SourceLoad::available(false),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return SourceLoad::missing(),
        Err(_) => return SourceLoad::available(false),
    }
    let Ok(entries) = std::fs::read_dir(&dir) else {
        return SourceLoad::available(false);
    };
    let mut completed = true;
    let mut entry_count = 0;
    let mut saw_candidate = false;
    for entry in entries {
        let Ok(entry) = entry else {
            completed = false;
            continue;
        };
        let path = entry.path();
        if !admit_source_entry(&mut entry_count, MAX_SOURCE_ENTRIES) {
            completed = false;
            break;
        }
        if path.extension().and_then(|s| s.to_str()) != Some("json") {
            continue;
        }
        saw_candidate = true;
        let Ok(metadata) = entry.metadata() else {
            completed = false;
            continue;
        };
        if !metadata.is_file() || metadata.len() > MAX_JSON_FILE_BYTES {
            completed = false;
            continue;
        }
        if !admit_source_bytes(scan_bytes, metadata.len(), MAX_SCAN_JSON_BYTES) {
            completed = false;
            break;
        }
        let Some(text) = read_utf8_file_bounded(&path, MAX_JSON_FILE_BYTES) else {
            completed = false;
            continue;
        };
        let actual_length = text.len() as u64;
        if actual_length > metadata.len()
            && !admit_source_bytes(
                scan_bytes,
                actual_length - metadata.len(),
                MAX_SCAN_JSON_BYTES,
            )
        {
            completed = false;
            break;
        }
        if !admit_json_structure(text.as_bytes(), structure_units) {
            completed = false;
            break;
        }
        let Ok(json) = serde_json::from_str::<Value>(&text) else {
            completed = false;
            continue;
        };

        let created = match json.get("created_at") {
            Some(timestamp) => {
                let Some(timestamp) = positive_timestamp_ms(timestamp) else {
                    completed = false;
                    continue;
                };
                if timestamp_ms_date(timestamp, latest_accepted_ms).is_none() {
                    completed = false;
                    continue;
                }
                timestamp
            }
            None => 0,
        };
        let updated = match json.get("updated_at") {
            Some(timestamp) => {
                let Some(timestamp) = positive_timestamp_ms(timestamp) else {
                    completed = false;
                    continue;
                };
                if timestamp_ms_date(timestamp, latest_accepted_ms).is_none() {
                    completed = false;
                    continue;
                }
                timestamp
            }
            None => {
                completed = false;
                continue;
            }
        };
        let nested = json.get("value").filter(|v| v.is_object());
        let value = nested.unwrap_or(&json);
        let resolved_id = json
            .get("conversation_id")
            .and_then(Value::as_str)
            .or_else(|| value.get("conversation_id").and_then(Value::as_str))
            .and_then(bounded_semantic_label)
            .map(str::to_string);
        let Some(resolved_id) = resolved_id else {
            completed = false;
            continue;
        };
        if !has_conversation_schema(value, created, latest_accepted_ms) {
            completed = false;
            continue;
        }
        // Strict: archive thiếu updated_at (0) bị loại — khác thế hệ cli.
        if updated < cutoff_ms {
            continue;
        }

        let Some(points) = parse_conversation(value, created, cutoff_date, latest_accepted_ms)
        else {
            completed = false;
            continue;
        };
        if points.is_empty() {
            continue;
        }
        merge_points(by_id, resolved_id, updated, points);
    }
    if saw_candidate {
        SourceLoad::available(completed)
    } else {
        SourceLoad::missing()
    }
}

fn has_semantic_turn_array<F>(value: Option<&Value>, validator: F) -> bool
where
    F: Fn(&Value) -> bool,
{
    match value.and_then(Value::as_array) {
        Some(turns) => !turns.is_empty() && turns.iter().all(validator),
        None => false,
    }
}

fn has_cli_session_schema(value: &Value, latest_accepted_ms: i64) -> bool {
    if normalized_model_id(value.pointer("/session_state/rts_model_state/model_info/model_id"))
        .is_none()
    {
        return false;
    }
    if let Some(context_window) =
        value.pointer("/session_state/rts_model_state/model_info/context_window_tokens")
    {
        if bounded_nonnegative_integer(context_window, MAX_CONTEXT_WINDOW_TOKENS).is_none() {
            return false;
        }
    }
    let Some(session_created) = optional_iso_date(value, "created_at", latest_accepted_ms) else {
        return false;
    };
    has_semantic_turn_array(
        value.pointer("/session_state/conversation_metadata/user_turn_metadatas"),
        |turn| has_semantic_cli_turn(turn, session_created.as_ref(), latest_accepted_ms),
    )
}

fn has_conversation_schema(
    value: &Value,
    fallback_created_ms: i64,
    latest_accepted_ms: i64,
) -> bool {
    if fallback_created_ms > 0
        && timestamp_ms_date(fallback_created_ms, latest_accepted_ms).is_none()
    {
        return false;
    }
    has_semantic_turn_array(value.get("history"), |turn| {
        has_semantic_conversation_turn(turn, latest_accepted_ms)
    })
}

fn has_semantic_cli_turn(
    turn: &Value,
    session_created: Option<&DateTime<Local>>,
    latest_accepted_ms: i64,
) -> bool {
    let Some(object) = turn.as_object() else {
        return false;
    };
    let mut recognized = false;

    if UNSUPPORTED_CLI_INTEGER_TURN_KEYS
        .iter()
        .any(|key| object.contains_key(*key))
    {
        return false;
    }

    let Some(turn_timestamp) = optional_iso_date(turn, "end_timestamp", latest_accepted_ms) else {
        return false;
    };
    if turn_timestamp.is_some() {
        recognized = true;
    }
    let mut usage_bearing = false;
    for key in CLI_INTEGER_TURN_KEYS {
        if let Some(value) = object.get(*key) {
            recognized = true;
            let Some(number) = nonnegative_integer(value) else {
                return false;
            };
            usage_bearing = usage_bearing || number > 0;
        }
    }
    if let Some(value) = object.get("context_usage_percentage") {
        recognized = true;
        let Some(number) = bounded_nonnegative_number(value, 100.0) else {
            return false;
        };
        usage_bearing = usage_bearing || number > 0.0;
    }
    if let Some(value) = object.get("metering_usage") {
        recognized = true;
        let Some(entries) = value.as_array() else {
            return false;
        };
        let mut credits = 0.0;
        if !entries.iter().all(|entry| {
            let Some(entry) = entry.as_object() else {
                return false;
            };
            let Some(unit) = entry
                .get("unit")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|unit| !unit.is_empty())
            else {
                return false;
            };
            let Some(number) = entry
                .get("value")
                .and_then(|value| bounded_nonnegative_number(value, MAX_CREDITS_PER_TURN))
            else {
                return false;
            };
            if unit.to_ascii_lowercase().contains("credit") {
                let Some(total) = checked_bounded_float_add(credits, number, MAX_CREDITS_PER_TURN)
                else {
                    return false;
                };
                credits = total;
                usage_bearing = usage_bearing || number > 0.0;
            }
            true
        }) {
            return false;
        }
    }
    recognized && (!usage_bearing || turn_timestamp.is_some() || session_created.is_some())
}

fn optional_iso_date(
    value: &Value,
    key: &str,
    latest_accepted_ms: i64,
) -> Option<Option<DateTime<Local>>> {
    match value.get(key) {
        Some(raw) => {
            let parsed = raw.as_str().and_then(parse_iso_date)?;
            (parsed.timestamp_millis() <= latest_accepted_ms).then_some(Some(parsed))
        }
        None => Some(None),
    }
}

fn positive_timestamp_ms(value: &Value) -> Option<i64> {
    if let Some(number) = value.as_str().and_then(|raw| raw.parse::<i64>().ok()) {
        return (number > 0).then_some(number);
    }
    let number = value.as_f64()?;
    if number.is_finite() && number > 0.0 && number < i64::MAX as f64 && number.fract() == 0.0 {
        Some(number as i64)
    } else {
        None
    }
}

fn timestamp_ms_date(timestamp_ms: i64, latest_accepted_ms: i64) -> Option<NaiveDate> {
    if timestamp_ms > latest_accepted_ms {
        return None;
    }
    Some(
        DateTime::from_timestamp_millis(timestamp_ms)?
            .with_timezone(&Local)
            .date_naive(),
    )
}

fn nonnegative_integer(value: &Value) -> Option<i64> {
    bounded_nonnegative_integer(value, MAX_TOKENS_PER_FIELD)
}

fn bounded_nonnegative_integer(value: &Value, maximum: i64) -> Option<i64> {
    let number = value.as_f64()?;
    if number.is_finite() && number >= 0.0 && number <= maximum as f64 && number.fract() == 0.0 {
        Some(number as i64)
    } else {
        None
    }
}

fn nonnegative_number(value: &Value) -> Option<f64> {
    let number = value.as_f64()?;
    (number.is_finite() && number >= 0.0).then_some(number)
}

fn bounded_nonnegative_number(value: &Value, maximum: f64) -> Option<f64> {
    let number = nonnegative_number(value)?;
    (number <= maximum).then_some(number)
}

fn checked_nonnegative_float_add(lhs: f64, rhs: f64) -> Option<f64> {
    if !lhs.is_finite() || lhs < 0.0 || !rhs.is_finite() || rhs < 0.0 {
        return None;
    }
    let total = lhs + rhs;
    total.is_finite().then_some(total)
}

fn checked_bounded_float_add(lhs: f64, rhs: f64, maximum: f64) -> Option<f64> {
    let total = checked_nonnegative_float_add(lhs, rhs)?;
    (total <= maximum).then_some(total)
}

fn checked_nonnegative_float_product(lhs: f64, rhs: f64) -> Option<f64> {
    if !lhs.is_finite() || lhs < 0.0 || !rhs.is_finite() || rhs < 0.0 {
        return None;
    }
    let product = lhs * rhs;
    product.is_finite().then_some(product)
}

fn optional_token_count(turn: &Value, key: &str) -> Option<i64> {
    match turn.get(key) {
        Some(value) => nonnegative_integer(value),
        None => Some(0),
    }
}

fn optional_percentage(turn: &Value, key: &str) -> Option<f64> {
    match turn.get(key) {
        Some(value) => bounded_nonnegative_number(value, 100.0),
        None => Some(0.0),
    }
}

fn has_semantic_conversation_turn(turn: &Value, latest_accepted_ms: i64) -> bool {
    let Some(object) = turn.as_object() else {
        return false;
    };
    let mut recognized = false;
    for key in CONVERSATION_TURN_IDENTITY_KEYS {
        let Some(value) = object.get(*key) else {
            continue;
        };
        if *key == "request_metadata" {
            let Some(metadata) = value.as_object() else {
                return false;
            };
            if let Some(timestamp) = metadata.get("request_start_timestamp_ms") {
                let Some(timestamp) = positive_timestamp_ms(timestamp) else {
                    return false;
                };
                if timestamp_ms_date(timestamp, latest_accepted_ms).is_none() {
                    return false;
                }
            }
            if let Some(model) = metadata.get("model_id") {
                if normalized_model_id(Some(model)).is_none() {
                    return false;
                }
            }
            if let Some(chunks) = metadata.get("time_between_chunks") {
                let Some(chunks) = chunks.as_array() else {
                    return false;
                };
                recognized = recognized || !chunks.is_empty();
            }
        } else {
            if !is_conversation_content_container(value) {
                return false;
            }
            recognized = recognized || has_meaningful_conversation_content(value);
        }
    }
    recognized
}

fn is_conversation_content_container(value: &Value) -> bool {
    matches!(value, Value::String(_) | Value::Array(_) | Value::Object(_))
}

fn has_meaningful_conversation_content(value: &Value) -> bool {
    match value {
        Value::String(text) => !text.trim().is_empty(),
        Value::Array(values) => values.iter().any(has_meaningful_conversation_content),
        Value::Object(values) => values.values().any(has_meaningful_conversation_content),
        _ => false,
    }
}

/// Expand one conversation into per-day SessionPoints (one per model/day).
/// Dùng cho sqlite + archive — ước lượng token (chars÷4), USD qua bảng giá
/// (không phải credit thật, khác thế hệ CLI hiện tại).
fn parse_conversation(
    value: &Value,
    fallback_created_ms: i64,
    cutoff_date: NaiveDate,
    latest_accepted_ms: i64,
) -> Option<Vec<SessionPoint>> {
    let Some(turns) = value.get("history").and_then(Value::as_array) else {
        return Some(Vec::new());
    };
    if turns.is_empty() {
        return Some(Vec::new());
    }
    if fallback_created_ms > 0
        && timestamp_ms_date(fallback_created_ms, latest_accepted_ms).is_none()
    {
        return None;
    }

    // Compact summary được gửi lại sau compaction — seed cache lũy tiến.
    let mut cumulative = match value.get("latest_summary") {
        Some(summary) => text_token_estimate(summary)?,
        None => 0,
    };
    let mut prev_asst: i64 = 0;

    // day -> model -> (tokens, usd)
    let mut buckets: HashMap<NaiveDate, HashMap<String, (i64, f64)>> = HashMap::new();

    for (i, turn) in turns.iter().enumerate() {
        let meta = turn.get("request_metadata");
        let model = normalized_model_id(meta.and_then(|m| m.get("model_id")))?.to_string();

        let user_text_tok = match turn.get("user") {
            Some(user) => text_token_estimate(user)?,
            None => 0,
        };
        let user_image_tok = match turn.get("user") {
            Some(user) => image_token_estimate(user)?,
            None => 0,
        };
        let user_tok = user_text_tok.checked_add(user_image_tok)?;
        let asst_tok = match turn.get("assistant") {
            Some(assistant) => text_token_estimate(assistant)?,
            None => 0,
        };
        // Output tokens: accurate chunk count when present.
        let out_tok = match meta
            .and_then(|m| m.get("time_between_chunks"))
            .and_then(Value::as_array)
        {
            Some(chunks) => i64::try_from(chunks.len()).ok()?,
            None => asst_tok,
        };

        let cr = if i > 0 { cumulative } else { 0 };
        let cw = user_tok.checked_add(if i > 0 { prev_asst } else { 0 })?;
        let total_tokens = cw.checked_add(cr)?.checked_add(out_tok)?;
        let usd = KiroModelPrice::estimate_usd(cw, cr, out_tok, &model);
        if !usd.is_finite() || usd < 0.0 {
            return None;
        }

        cumulative = cumulative.checked_add(user_tok)?.checked_add(asst_tok)?;
        prev_asst = asst_tok;

        let ts_ms = match meta.and_then(|m| m.get("request_start_timestamp_ms")) {
            Some(timestamp) => positive_timestamp_ms(timestamp)?,
            None => 0,
        };
        if total_tokens <= 0 && usd <= 0.0 {
            continue;
        }
        let active_at_ms = if ts_ms > 0 {
            ts_ms
        } else if fallback_created_ms > 0 {
            fallback_created_ms
        } else {
            return None;
        };
        let day = timestamp_ms_date(active_at_ms, latest_accepted_ms)?;
        if day < cutoff_date {
            continue;
        }

        let day_models = buckets.entry(day).or_default();
        let acc = day_models.entry(model).or_insert((0, 0.0));
        acc.0 = acc.0.checked_add(total_tokens)?;
        acc.1 = checked_nonnegative_float_add(acc.1, usd)?;
    }

    let mut points = Vec::new();
    for (day, models) in buckets {
        for (model, (tokens, usd)) in models {
            if tokens > 0 || usd > 0.0 {
                points.push(SessionPoint {
                    day,
                    tokens,
                    usd,
                    model,
                });
            }
        }
    }
    Some(points)
}

/// Approximate tokens from textual content (UTF-8 bytes ÷ 4), excluding base64 images.
fn text_token_estimate(field: &Value) -> Option<i64> {
    match field {
        Value::String(s) => i64::try_from(s.len()).ok()?.checked_div(CHARS_PER_TOKEN),
        Value::Object(map) => map
            .iter()
            .filter(|(k, _)| k.as_str() != "images")
            .try_fold(0_i64, |total, (_, value)| {
                total.checked_add(text_token_estimate(value)?)
            }),
        Value::Array(arr) => arr.iter().try_fold(0_i64, |total, value| {
            total.checked_add(text_token_estimate(value)?)
        }),
        _ => Some(0),
    }
}

/// Rough vision tokens for images (~1600 each when dimensions unknown).
fn image_token_estimate(field: &Value) -> Option<i64> {
    let Some(images) = field.get("images").and_then(Value::as_array) else {
        return Some(0);
    };
    if images.is_empty() {
        return Some(0);
    }
    i64::try_from(images.len()).ok()?.checked_mul(1600)
}

// --- Report build ------------------------------------------------------------

fn build_report(points: Vec<SessionPoint>, now: DateTime<Local>) -> Option<UsageReport> {
    let today_date = now.date_naive();
    let mut daily_map: HashMap<NaiveDate, (f64, i64, HashMap<String, (f64, i64)>)> = HashMap::new();
    for p in points {
        if !p.usd.is_finite() || p.usd < 0.0 || p.tokens < 0 {
            return None;
        }
        let entry = daily_map
            .entry(p.day)
            .or_insert_with(|| (0.0, 0, HashMap::new()));
        entry.0 = checked_nonnegative_float_add(entry.0, p.usd)?;
        entry.1 = entry.1.checked_add(p.tokens)?;
        let m_entry = entry.2.entry(p.model).or_insert((0.0, 0));
        m_entry.0 = checked_nonnegative_float_add(m_entry.0, p.usd)?;
        m_entry.1 = m_entry.1.checked_add(p.tokens)?;
    }

    let mut daily_list = Vec::with_capacity(HISTORY_DAYS as usize);
    let mut last30_usd = 0.0;
    let mut last30_tokens: i64 = 0;
    let last30_cutoff = today_date - Duration::days(30);

    // Rank against the full 30-day model set before bounding the daily chart
    // payload. A steady sixth-place model can still be the true monthly top.
    let mut model_totals: HashMap<String, (i64, f64)> = HashMap::new();
    for (day, (_, _, models)) in &daily_map {
        if *day <= last30_cutoff || *day > today_date {
            continue;
        }
        for (name, (usd, tokens)) in models {
            if *tokens <= 0 && *usd <= 0.0 {
                continue;
            }
            let total = model_totals.entry(name.clone()).or_insert((0, 0.0));
            total.0 = total.0.checked_add(*tokens)?;
            total.1 = checked_nonnegative_float_add(total.1, *usd)?;
        }
    }
    let top_model = model_totals
        .iter()
        .max_by(|a, b| {
            a.1 .0
                .cmp(&b.1 .0)
                .then_with(|| {
                    a.1 .1
                        .partial_cmp(&b.1 .1)
                        .unwrap_or(std::cmp::Ordering::Equal)
                })
                .then_with(|| b.0.cmp(a.0))
        })
        .map(|(name, _)| name.clone());

    for i in (0..HISTORY_DAYS).rev() {
        let d = today_date - Duration::days(i);
        if let Some((usd, tokens, model_map)) = daily_map.get(&d) {
            let mut all_models: Vec<DailyModel> = model_map
                .iter()
                .map(|(name, (m_usd, m_tok))| DailyModel {
                    name: name.clone(),
                    usd: *m_usd,
                    tokens: *m_tok,
                })
                .collect();
            // Token-first ranking (matches the All chart preference).
            all_models.sort_by(|a, b| {
                b.tokens
                    .cmp(&a.tokens)
                    .then_with(|| {
                        b.usd
                            .partial_cmp(&a.usd)
                            .unwrap_or(std::cmp::Ordering::Equal)
                    })
                    .then_with(|| a.name.cmp(&b.name))
            });
            let mut models: Vec<DailyModel> = all_models.iter().take(5).cloned().collect();
            if let Some(global_top) = top_model.as_ref() {
                if !models.iter().any(|model| &model.name == global_top) {
                    if let Some(model) = all_models.iter().find(|model| &model.name == global_top) {
                        models.push(model.clone());
                    }
                }
            }

            let mut other_tokens = 0_i64;
            let mut other_usd = 0.0;
            for model in &all_models {
                if models.iter().any(|selected| selected.name == model.name) {
                    continue;
                }
                other_tokens = other_tokens.checked_add(model.tokens)?;
                other_usd = checked_nonnegative_float_add(other_usd, model.usd)?;
            }
            if other_tokens > 0 || other_usd > 0.0 {
                models.push(DailyModel {
                    name: AGGREGATE_MODEL_NAME.to_string(),
                    usd: other_usd,
                    tokens: other_tokens,
                });
            }

            if d > last30_cutoff {
                last30_usd = checked_nonnegative_float_add(last30_usd, *usd)?;
                last30_tokens = last30_tokens.checked_add(*tokens)?;
            }

            daily_list.push(DailyUsage {
                date: d.format("%Y-%m-%d").to_string(),
                usd: *usd,
                tokens: *tokens,
                models,
            });
        } else {
            daily_list.push(DailyUsage {
                date: d.format("%Y-%m-%d").to_string(),
                usd: 0.0,
                tokens: 0,
                models: Vec::new(),
            });
        }
    }

    let today_entry = daily_map.get(&today_date);
    let today_usd = today_entry.map(|e| e.0).unwrap_or(0.0);
    let today_tokens = today_entry.map(|e| e.1).unwrap_or(0);

    Some(UsageReport {
        today_usd,
        today_tokens,
        last30_usd,
        last30_tokens,
        daily: daily_list,
        hourly: Vec::new(),
        top_model,
        included: true,
        live: true,
        scanned_at: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write as _;
    use std::sync::atomic::{AtomicU64, Ordering};

    fn temp_home(label: &str) -> PathBuf {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        std::env::temp_dir().join(format!(
            "birdnion-kiro-{label}-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ))
    }

    fn scan_with_missing_db(home: &Path, now: DateTime<Local>) -> KiroUsageScan {
        scan_kiro_usage_at_paths(home, &home.join("missing.sqlite3"), now)
    }

    #[test]
    fn pricing_table_maps_models_to_expected_rates() {
        let opus45 = KiroModelPrice::for_model("claude-opus-4-5-20260101");
        assert_eq!(
            (opus45.write_per_m, opus45.read_per_m, opus45.output_per_m),
            (6.25, 0.50, 25.0)
        );

        let opus_legacy = KiroModelPrice::for_model("claude-opus-4-20250101");
        assert_eq!(
            (
                opus_legacy.write_per_m,
                opus_legacy.read_per_m,
                opus_legacy.output_per_m
            ),
            (18.75, 1.50, 75.0)
        );

        let sonnet = KiroModelPrice::for_model("claude-sonnet-4-5");
        assert_eq!(
            (sonnet.write_per_m, sonnet.read_per_m, sonnet.output_per_m),
            (3.75, 0.30, 15.0)
        );

        let haiku = KiroModelPrice::for_model("claude-haiku-4-5");
        assert_eq!(
            (haiku.write_per_m, haiku.read_per_m, haiku.output_per_m),
            (1.25, 0.10, 5.0)
        );

        // Unknown/free-tier models default to Opus 4.5 rates so they stay visible.
        let unknown = KiroModelPrice::for_model("");
        assert_eq!(
            (
                unknown.write_per_m,
                unknown.read_per_m,
                unknown.output_per_m
            ),
            (6.25, 0.50, 25.0)
        );
    }

    fn write_json(path: &Path, value: &Value) {
        let mut f = std::fs::File::create(path).unwrap();
        f.write_all(serde_json::to_string(value).unwrap().as_bytes())
            .unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn bounded_reader_rejects_fifo_without_blocking() {
        let root = temp_home("fifo-bounded-reader");
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let fifo = root.join("hang.json");
        let path = std::ffi::CString::new(fifo.as_os_str().as_encoded_bytes()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0);

        let started = std::time::Instant::now();
        assert_eq!(read_utf8_file_bounded(&fifo, 1024), None);
        assert!(started.elapsed() < std::time::Duration::from_secs(1));

        let _ = std::fs::remove_dir_all(&root);
    }

    #[cfg(unix)]
    #[test]
    fn sqlite_symlink_is_rejected_before_query() {
        let root = temp_home("sqlite-symlink");
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let target = root.join("outside.sqlite3");
        let db_path = root.join("data.sqlite3");
        let now = Local::now();
        let payload = serde_json::json!({
            "conversation_id": "redirected-sqlite",
            "history": [{
                "user": "usage reached through a redirected database",
                "request_metadata": {
                    "request_start_timestamp_ms": now.timestamp_millis()
                }
            }]
        })
        .to_string();
        let conn = Connection::open(&target).unwrap();
        conn.execute("CREATE TABLE conversations (value TEXT NOT NULL)", [])
            .unwrap();
        conn.execute("INSERT INTO conversations (value) VALUES (?1)", [&payload])
            .unwrap();
        drop(conn);
        std::os::unix::fs::symlink(&target, &db_path).unwrap();

        let scan = scan_kiro_usage_at_paths(&root, &db_path, now);

        assert!(!scan.completed);
        assert_eq!(scan.usage.last30_tokens, 0);
        assert_eq!(scan.usage.last30_usd, 0.0);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[cfg(unix)]
    #[test]
    fn archive_and_cli_root_symlinks_are_rejected() {
        let root = temp_home("source-root-symlinks");
        let _ = std::fs::remove_dir_all(&root);
        let archive_target = root.join("outside-archive");
        let cli_target = root.join("outside-cli");
        std::fs::create_dir_all(&archive_target).unwrap();
        std::fs::create_dir_all(&cli_target).unwrap();
        std::fs::create_dir_all(root.join(".kiro/sessions")).unwrap();
        let now = Local::now();
        write_json(
            &archive_target.join("redirected.json"),
            &serde_json::json!({
                "conversation_id": "redirected-archive",
                "created_at": now.timestamp_millis(),
                "updated_at": now.timestamp_millis(),
                "history": [{
                    "user": "usage reached through a redirected archive",
                    "request_metadata": {
                        "request_start_timestamp_ms": now.timestamp_millis()
                    }
                }]
            }),
        );
        write_json(
            &cli_target.join("redirected.json"),
            &serde_json::json!({
                "session_id": "redirected-cli",
                "created_at": now.to_rfc3339(),
                "updated_at": now.to_rfc3339(),
                "session_state": {
                    "conversation_metadata": {
                        "user_turn_metadatas": [{
                            "metering_usage": [{ "unit": "credit", "value": 1.0 }],
                            "input_token_count": 10,
                            "output_token_count": 5,
                            "end_timestamp": now.to_rfc3339()
                        }]
                    }
                }
            }),
        );
        std::os::unix::fs::symlink(&archive_target, root.join(".kiro_sessions")).unwrap();
        std::os::unix::fs::symlink(&cli_target, root.join(".kiro/sessions/cli")).unwrap();

        let scan = scan_with_missing_db(&root, now);

        assert!(!scan.completed);
        assert_eq!(scan.usage.last30_tokens, 0);
        assert_eq!(scan.usage.last30_usd, 0.0);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn scan_over_temp_home_reads_cli_session_and_totals_usd_tokens() {
        let tmp = temp_home("scanner");
        let _ = std::fs::remove_dir_all(&tmp);
        let cli_dir = tmp.join(".kiro").join("sessions").join("cli");
        std::fs::create_dir_all(&cli_dir).unwrap();

        let now = Local::now();
        let end_ts = now.to_rfc3339();
        let session = serde_json::json!({
            "session_id": "sess-1",
            "created_at": end_ts,
            "updated_at": end_ts,
            "session_state": {
                "rts_model_state": {
                    "model_info": { "model_id": "claude-sonnet-4-5", "context_window_tokens": 200000 }
                },
                "conversation_metadata": {
                    "user_turn_metadatas": [
                        {
                            "metering_usage": [ { "unit": "credit", "value": 2.5 } ],
                            "input_token_count": 100,
                            "output_token_count": 50,
                            "end_timestamp": end_ts
                        },
                        {
                            "metering_usage": [ { "unit": "credit", "value": 1.5 } ],
                            "input_token_count": 30,
                            "output_token_count": 20,
                            "end_timestamp": end_ts
                        }
                    ]
                }
            }
        });
        write_json(&cli_dir.join("sess-1.json"), &session);

        let scan = scan_with_missing_db(&tmp, now);
        assert!(scan.completed);
        // credits: 2.5 + 1.5 = 4.0 -> USD = 4.0 * 0.04 = 0.16
        assert!(
            (scan.usage.today_usd - 0.16).abs() < 1e-9,
            "unexpected today_usd: {}",
            scan.usage.today_usd
        );
        assert_eq!(scan.usage.today_tokens, 200);
        assert!((scan.usage.last30_usd - 0.16).abs() < 1e-9);
        assert_eq!(scan.usage.last30_tokens, 200);
        assert_eq!(scan.usage.top_model.as_deref(), Some("claude-sonnet-4-5"));

        // Days without sessions must not carry fabricated numbers.
        let yesterday_key = (now - Duration::days(1))
            .date_naive()
            .format("%Y-%m-%d")
            .to_string();
        let yesterday = scan
            .usage
            .daily
            .iter()
            .find(|d| d.date == yesterday_key)
            .unwrap();
        assert_eq!(yesterday.tokens, 0);
        assert_eq!(yesterday.usd, 0.0);
        assert!(yesterday.models.is_empty());

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn current_cli_session_without_updated_at_wins_legacy_duplicate() {
        let tmp = temp_home("cross-generation-dedup");
        let _ = std::fs::remove_dir_all(&tmp);
        let archive = tmp.join(".kiro_sessions");
        let cli = tmp.join(".kiro").join("sessions").join("cli");
        std::fs::create_dir_all(&archive).unwrap();
        std::fs::create_dir_all(&cli).unwrap();
        let now = Local::now();
        let legacy = now - Duration::days(1);
        write_json(
            &archive.join("shared-session.json"),
            &serde_json::json!({
                "conversation_id": "shared-session",
                "created_at": legacy.timestamp_millis(),
                "updated_at": legacy.timestamp_millis(),
                "history": [{
                    "user": "stale legacy estimate",
                    "request_metadata": {
                        "request_start_timestamp_ms": legacy.timestamp_millis()
                    }
                }]
            }),
        );
        let current_timestamp = (now - Duration::seconds(1)).to_rfc3339();
        write_json(
            &cli.join("shared-session.json"),
            &serde_json::json!({
                "session_id": "shared-session",
                "created_at": current_timestamp,
                "session_state": {
                    "rts_model_state": {
                        "model_info": { "model_id": "claude-sonnet-4-5" }
                    },
                    "conversation_metadata": {
                        "user_turn_metadatas": [{
                            "metering_usage": [{ "unit": "credit", "value": 10.0 }],
                            "input_token_count": 100,
                            "output_token_count": 50,
                            "end_timestamp": current_timestamp
                        }]
                    }
                }
            }),
        );

        let scan = scan_with_missing_db(&tmp, now);

        assert!(scan.completed);
        assert_eq!(scan.usage.today_tokens, 150);
        assert!((scan.usage.today_usd - 0.4).abs() < 1e-9);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn scan_over_missing_home_dir_is_empty_not_fabricated() {
        let tmp = temp_home("missing");
        let _ = std::fs::remove_dir_all(&tmp);
        let now = Local::now();
        let scan = scan_with_missing_db(&tmp, now);
        assert!(!scan.completed);
        assert_eq!(scan.usage.today_tokens, 0);
        assert_eq!(scan.usage.last30_tokens, 0);
        assert!(scan
            .usage
            .daily
            .iter()
            .all(|d| d.tokens == 0 && d.usd == 0.0));
    }

    #[test]
    fn readable_empty_archive_does_not_mint_completed_scan() {
        let tmp = temp_home("empty-archive");
        let archive = tmp.join(".kiro_sessions");
        std::fs::create_dir_all(&archive).unwrap();

        let scan = scan_with_missing_db(&tmp, Local::now());

        assert!(!scan.completed);
        assert_eq!(scan.usage.today_tokens, 0);
        assert_eq!(scan.usage.today_usd, 0.0);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn empty_semantic_arrays_are_not_live_evidence() {
        let tmp = temp_home("empty-semantic-arrays");
        let archive = tmp.join(".kiro_sessions");
        let cli = tmp.join(".kiro").join("sessions").join("cli");
        std::fs::create_dir_all(&archive).unwrap();
        std::fs::create_dir_all(&cli).unwrap();
        let now = Local::now();
        write_json(
            &archive.join("empty.json"),
            &serde_json::json!({
                "conversation_id": "empty-archive",
                "updated_at": now.timestamp_millis(),
                "history": []
            }),
        );
        write_json(
            &cli.join("empty.json"),
            &serde_json::json!({
                "session_id": "empty-cli",
                "session_state": {
                    "conversation_metadata": { "user_turn_metadatas": [] }
                }
            }),
        );

        let scan = scan_with_missing_db(&tmp, now);

        assert!(!scan.completed);
        assert_eq!(scan.usage.last30_tokens, 0);
        assert_eq!(scan.usage.last30_usd, 0.0);
        assert!(scan
            .usage
            .daily
            .iter()
            .all(|day| day.tokens == 0 && day.usd == 0.0 && day.models.is_empty()));
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn empty_session_state_downgrades_completion_without_usage() {
        let tmp = temp_home("empty-session-state");
        let cli = tmp.join(".kiro").join("sessions").join("cli");
        std::fs::create_dir_all(&cli).unwrap();
        write_json(
            &cli.join("bad.json"),
            &serde_json::json!({
                "session_id": "empty-session-state",
                "session_state": {}
            }),
        );

        let scan = scan_with_missing_db(&tmp, Local::now());

        assert!(!scan.completed);
        assert_eq!(scan.usage.last30_tokens, 0);
        assert_eq!(scan.usage.last30_usd, 0.0);
        assert!(scan
            .usage
            .daily
            .iter()
            .all(|day| day.tokens == 0 && day.usd == 0.0 && day.models.is_empty()));
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn empty_history_turn_downgrades_archive_completion_without_usage() {
        let tmp = temp_home("empty-history-turn-archive");
        let archive = tmp.join(".kiro_sessions");
        std::fs::create_dir_all(&archive).unwrap();
        let now = Local::now();
        let empty_turns = [
            serde_json::json!({}),
            serde_json::json!({ "request_metadata": {} }),
            serde_json::json!({ "request_metadata": { "time_between_chunks": [] } }),
            serde_json::json!({ "request_metadata": { "model_id": "" } }),
            serde_json::json!({
                "request_metadata": { "request_start_timestamp_ms": now.timestamp_millis() }
            }),
            serde_json::json!({ "user": "" }),
            serde_json::json!({ "assistant": [] }),
            serde_json::json!({ "user": {} }),
        ];
        for (index, turn) in empty_turns.into_iter().enumerate() {
            write_json(
                &archive.join("bad.json"),
                &serde_json::json!({
                    "conversation_id": format!("empty-turn-{index}"),
                    "updated_at": now.timestamp_millis(),
                    "history": [turn]
                }),
            );

            let scan = scan_with_missing_db(&tmp, now);
            assert!(!scan.completed, "empty turn {index}");
            assert_eq!(scan.usage.last30_tokens, 0, "empty turn {index}");
            assert_eq!(scan.usage.last30_usd, 0.0, "empty turn {index}");
            assert!(scan
                .usage
                .daily
                .iter()
                .all(|day| day.tokens == 0 && day.usd == 0.0 && day.models.is_empty()));
        }

        for (index, turn) in [
            serde_json::json!({
                "user": "meaningful user request",
                "assistant": [],
                "request_metadata": { "request_start_timestamp_ms": now.timestamp_millis() }
            }),
            serde_json::json!({
                "user": [],
                "assistant": "meaningful assistant response",
                "request_metadata": { "request_start_timestamp_ms": now.timestamp_millis() }
            }),
        ]
        .into_iter()
        .enumerate()
        {
            write_json(
                &archive.join("bad.json"),
                &serde_json::json!({
                    "conversation_id": format!("mixed-turn-{index}"),
                    "updated_at": now.timestamp_millis(),
                    "history": [turn]
                }),
            );
            let scan = scan_with_missing_db(&tmp, now);
            assert!(scan.completed, "mixed turn {index}");
            assert!(scan.usage.last30_tokens > 0, "mixed turn {index}");
        }
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn empty_history_turn_downgrades_sqlite_completion_without_usage() {
        let tmp = temp_home("empty-history-turn-sqlite");
        std::fs::create_dir_all(&tmp).unwrap();
        let db_path = tmp.join("data.sqlite3");
        let conn = Connection::open(&db_path).unwrap();
        conn.execute("CREATE TABLE conversations (value TEXT NOT NULL)", [])
            .unwrap();
        let invalid = serde_json::json!({
            "conversation_id": "empty-turn",
            "history": [{}]
        })
        .to_string();
        conn.execute("INSERT INTO conversations (value) VALUES (?1)", [&invalid])
            .unwrap();
        drop(conn);

        let scan = scan_kiro_usage_at_paths(&tmp, &db_path, Local::now());

        assert!(!scan.completed);
        assert_eq!(scan.usage.last30_tokens, 0);
        assert_eq!(scan.usage.last30_usd, 0.0);
        assert!(scan
            .usage
            .daily
            .iter()
            .all(|day| day.tokens == 0 && day.usd == 0.0 && day.models.is_empty()));
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn semantic_field_types_match_parser_contract() {
        let archive_home = temp_home("wrong-metadata-type");
        let archive = archive_home.join(".kiro_sessions");
        std::fs::create_dir_all(&archive).unwrap();
        let now = Local::now();
        write_json(
            &archive.join("bad.json"),
            &serde_json::json!({
                "conversation_id": "wrong-metadata-type",
                "updated_at": now.timestamp_millis(),
                "history": [{ "request_metadata": 1 }]
            }),
        );
        let archive_scan = scan_with_missing_db(&archive_home, now);
        assert!(!archive_scan.completed);
        assert_eq!(archive_scan.usage.last30_tokens, 0);
        let _ = std::fs::remove_dir_all(&archive_home);

        let cli_home = temp_home("wrong-timestamp-type");
        let cli = cli_home.join(".kiro").join("sessions").join("cli");
        std::fs::create_dir_all(&cli).unwrap();
        write_json(
            &cli.join("bad.json"),
            &serde_json::json!({
                "session_id": "wrong-timestamp-type",
                "session_state": {
                    "conversation_metadata": {
                        "user_turn_metadatas": [{ "end_timestamp": 123 }]
                    }
                }
            }),
        );
        let cli_scan = scan_with_missing_db(&cli_home, Local::now());
        assert!(!cli_scan.completed);
        assert_eq!(cli_scan.usage.last30_tokens, 0);

        std::fs::remove_file(cli.join("bad.json")).unwrap();
        let valid_now = Local::now();
        let integral_float = serde_json::json!({
            "session_id": "integral-float",
            "session_state": {
                "conversation_metadata": {
                    "user_turn_metadatas": [{
                        "end_timestamp": valid_now.to_rfc3339(),
                        "input_token_count": 1.0,
                        "output_token_count": 0
                    }]
                }
            }
        });
        assert!(integral_float
            .pointer("/session_state/conversation_metadata/user_turn_metadatas/0/input_token_count")
            .and_then(Value::as_i64)
            .is_none());
        write_json(&cli.join("valid.json"), &integral_float);
        let valid_scan = scan_with_missing_db(&cli_home, valid_now);
        assert!(valid_scan.completed);
        assert_eq!(valid_scan.usage.today_tokens, 1);

        std::fs::remove_file(cli.join("valid.json")).unwrap();
        let oversized_label = "x".repeat(MAX_SEMANTIC_LABEL_BYTES + 1);
        let oversized_model = serde_json::json!({
            "session_id": "oversized-model",
            "session_state": {
                "rts_model_state": {
                    "model_info": { "model_id": oversized_label }
                },
                "conversation_metadata": {
                    "user_turn_metadatas": [{
                        "end_timestamp": valid_now.to_rfc3339(),
                        "input_token_count": 1
                    }]
                }
            }
        });
        assert!(!has_cli_session_schema(
            &oversized_model,
            valid_now.timestamp_millis()
        ));
        write_json(&cli.join("oversized-model.json"), &oversized_model);
        let oversized_scan = scan_with_missing_db(&cli_home, valid_now);
        assert!(!oversized_scan.completed);
        assert_eq!(oversized_scan.usage.today_tokens, 0);

        assert!(bounded_semantic_label(&"x".repeat(MAX_SEMANTIC_LABEL_BYTES + 1)).is_none());
        assert!(bounded_semantic_label("line\nbreak").is_none());

        let legacy_oversized_model = serde_json::json!({
            "history": [{
                "user": "reportable usage",
                "request_metadata": {
                    "model_id": "x".repeat(MAX_SEMANTIC_LABEL_BYTES + 1),
                    "request_start_timestamp_ms": valid_now.timestamp_millis()
                }
            }]
        });
        assert!(!has_conversation_schema(
            &legacy_oversized_model,
            valid_now.timestamp_millis(),
            valid_now.timestamp_millis()
        ));
        assert!(parse_conversation(
            &legacy_oversized_model,
            valid_now.timestamp_millis(),
            valid_now.date_naive(),
            valid_now.timestamp_millis()
        )
        .is_none());
        let _ = std::fs::remove_dir_all(&cli_home);
    }

    #[test]
    fn cli_token_counts_above_contract_fail_closed() {
        let now = Local::now();
        let session = serde_json::json!({
            "session_id": "oversized-token-count",
            "session_state": {
                "conversation_metadata": {
                    "user_turn_metadatas": [{
                        "end_timestamp": now.to_rfc3339(),
                        "input_token_count": MAX_TOKENS_PER_FIELD + 1,
                        "output_token_count": 0
                    }]
                }
            }
        });

        assert!(!has_cli_session_schema(&session, now.timestamp_millis()));
        assert!(
            parse_cli_session_sidecar(&session, now.date_naive(), now.timestamp_millis()).is_none()
        );
    }

    #[test]
    fn cli_context_contract_rejects_extremes_and_keeps_zero_fallback() {
        let now = Local::now();
        let excessive_percentage = serde_json::json!({
            "session_id": "excessive-percentage",
            "session_state": {
                "conversation_metadata": {
                    "user_turn_metadatas": [{
                        "end_timestamp": now.to_rfc3339(),
                        "context_usage_percentage": 100.000_001
                    }]
                }
            }
        });
        assert!(!has_cli_session_schema(
            &excessive_percentage,
            now.timestamp_millis()
        ));
        assert!(parse_cli_session_sidecar(
            &excessive_percentage,
            now.date_naive(),
            now.timestamp_millis()
        )
        .is_none());

        let excessive_window = serde_json::json!({
            "session_id": "excessive-window",
            "session_state": {
                "rts_model_state": {
                    "model_info": { "context_window_tokens": MAX_CONTEXT_WINDOW_TOKENS + 1 }
                },
                "conversation_metadata": {
                    "user_turn_metadatas": [{
                        "end_timestamp": now.to_rfc3339(),
                        "context_usage_percentage": 50
                    }]
                }
            }
        });
        assert!(!has_cli_session_schema(
            &excessive_window,
            now.timestamp_millis()
        ));
        assert!(parse_cli_session_sidecar(
            &excessive_window,
            now.date_naive(),
            now.timestamp_millis()
        )
        .is_none());

        let zero_window = serde_json::json!({
            "session_id": "zero-window-fallback",
            "session_state": {
                "rts_model_state": {
                    "model_info": { "context_window_tokens": 0 }
                },
                "conversation_metadata": {
                    "user_turn_metadatas": [{
                        "end_timestamp": now.to_rfc3339(),
                        "context_usage_percentage": 50
                    }]
                }
            }
        });
        assert!(has_cli_session_schema(&zero_window, now.timestamp_millis()));
        let points =
            parse_cli_session_sidecar(&zero_window, now.date_naive(), now.timestamp_millis())
                .unwrap();
        assert_eq!(points.len(), 1);
        assert_eq!(points[0].tokens, DEFAULT_CONTEXT_WINDOW_TOKENS / 2);
    }

    #[test]
    fn cli_credit_sum_and_float_overflow_fail_closed() {
        let now = Local::now();
        let excessive_credits = serde_json::json!({
            "session_id": "excessive-credit-total",
            "session_state": {
                "conversation_metadata": {
                    "user_turn_metadatas": [{
                        "end_timestamp": now.to_rfc3339(),
                        "metering_usage": [
                            { "unit": "credit", "value": 600_000_000.0 },
                            { "unit": "credit", "value": 600_000_000.0 }
                        ]
                    }]
                }
            }
        });
        assert!(!has_cli_session_schema(
            &excessive_credits,
            now.timestamp_millis()
        ));
        assert!(parse_cli_session_sidecar(
            &excessive_credits,
            now.date_naive(),
            now.timestamp_millis()
        )
        .is_none());

        let overflowing_credits = serde_json::json!({
            "session_id": "overflowing-credit-total",
            "session_state": {
                "conversation_metadata": {
                    "user_turn_metadatas": [{
                        "end_timestamp": now.to_rfc3339(),
                        "metering_usage": [
                            { "unit": "credit", "value": f64::MAX },
                            { "unit": "credit", "value": f64::MAX }
                        ]
                    }]
                }
            }
        });
        assert!(!has_cli_session_schema(
            &overflowing_credits,
            now.timestamp_millis()
        ));
        assert!(parse_cli_session_sidecar(
            &overflowing_credits,
            now.date_naive(),
            now.timestamp_millis()
        )
        .is_none());
        assert!(checked_nonnegative_float_add(f64::MAX, f64::MAX).is_none());
    }

    #[test]
    fn unsupported_cli_token_alias_with_valid_timestamp_marks_scan_incomplete() {
        let tmp = temp_home("unsupported-token-alias");
        let cli = tmp.join(".kiro").join("sessions").join("cli");
        std::fs::create_dir_all(&cli).unwrap();
        let now = Local::now();
        write_json(
            &cli.join("bad.json"),
            &serde_json::json!({
                "session_id": "unsupported-token-alias",
                "session_state": {
                    "conversation_metadata": {
                        "user_turn_metadatas": [{
                            "end_timestamp": now.to_rfc3339(),
                            "input_tokens_count": 100
                        }]
                    }
                }
            }),
        );

        let scan = scan_with_missing_db(&tmp, now);

        assert!(!scan.completed);
        assert_eq!(scan.usage.last30_tokens, 0);
        assert_eq!(scan.usage.last30_usd, 0.0);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn cli_usage_without_resolvable_timestamp_marks_scan_incomplete() {
        let tmp = temp_home("cli-missing-usage-timestamp");
        let cli = tmp.join(".kiro").join("sessions").join("cli");
        std::fs::create_dir_all(&cli).unwrap();
        write_json(
            &cli.join("bad.json"),
            &serde_json::json!({
                "session_id": "missing-usage-timestamp",
                "session_state": {
                    "conversation_metadata": {
                        "user_turn_metadatas": [{ "input_token_count": 100 }]
                    }
                }
            }),
        );

        let scan = scan_with_missing_db(&tmp, Local::now());

        assert!(!scan.completed);
        assert_eq!(scan.usage.last30_tokens, 0);
        assert_eq!(scan.usage.last30_usd, 0.0);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn cli_usage_after_scan_day_marks_scan_incomplete() {
        let tmp = temp_home("cli-future-usage-timestamp");
        let cli = tmp.join(".kiro").join("sessions").join("cli");
        std::fs::create_dir_all(&cli).unwrap();
        write_json(
            &cli.join("bad.json"),
            &serde_json::json!({
                "session_id": "future-usage-timestamp",
                "session_state": {
                    "conversation_metadata": {
                        "user_turn_metadatas": [{
                            "input_token_count": 100,
                            "end_timestamp": "9999-12-31T23:59:59Z"
                        }]
                    }
                }
            }),
        );

        let scan = scan_with_missing_db(&tmp, Local::now());

        assert!(!scan.completed);
        assert_eq!(scan.usage.last30_tokens, 0);
        assert_eq!(scan.usage.last30_usd, 0.0);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn cli_usage_accepts_valid_session_created_at_fallback() {
        let tmp = temp_home("cli-created-fallback");
        let cli = tmp.join(".kiro").join("sessions").join("cli");
        std::fs::create_dir_all(&cli).unwrap();
        let now = Local::now();
        write_json(
            &cli.join("valid.json"),
            &serde_json::json!({
                "session_id": "created-fallback",
                "created_at": now.to_rfc3339(),
                "session_state": {
                    "conversation_metadata": {
                        "user_turn_metadatas": [{ "input_token_count": 100 }]
                    }
                }
            }),
        );

        let scan = scan_with_missing_db(&tmp, now);

        assert!(scan.completed);
        assert_eq!(scan.usage.today_tokens, 100);
        assert_eq!(scan.usage.last30_tokens, 100);

        for (label, updated_at) in [
            ("malformed-updated-at", "broken".to_string()),
            ("future-updated-at", "9999-12-31T23:59:59Z".to_string()),
        ] {
            write_json(
                &cli.join("valid.json"),
                &serde_json::json!({
                    "session_id": label,
                    "created_at": now.to_rfc3339(),
                    "updated_at": updated_at,
                    "session_state": {
                        "conversation_metadata": {
                            "user_turn_metadatas": [{ "input_token_count": 100 }]
                        }
                    }
                }),
            );
            let invalid_scan = scan_with_missing_db(&tmp, now);
            assert!(!invalid_scan.completed, "{label}");
            assert_eq!(invalid_scan.usage.last30_tokens, 0, "{label}");
        }
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn conversation_usage_without_timestamp_marks_archive_and_sqlite_incomplete() {
        let now = Local::now();
        let missing_timestamp = serde_json::json!({
            "conversation_id": "missing-conversation-timestamp",
            "history": [{
                "user": "content long enough to produce reportable token usage"
            }]
        });

        let archive_home = temp_home("archive-missing-usage-timestamp");
        let archive = archive_home.join(".kiro_sessions");
        std::fs::create_dir_all(&archive).unwrap();
        let mut archived = missing_timestamp.clone();
        archived["updated_at"] = Value::from(now.timestamp_millis());
        write_json(&archive.join("bad.json"), &archived);
        let archive_scan = scan_with_missing_db(&archive_home, now);
        assert!(!archive_scan.completed);
        assert_eq!(archive_scan.usage.last30_tokens, 0);
        let _ = std::fs::remove_dir_all(&archive_home);

        let sqlite_home = temp_home("sqlite-missing-usage-timestamp");
        std::fs::create_dir_all(&sqlite_home).unwrap();
        let db_path = sqlite_home.join("data.sqlite3");
        let conn = Connection::open(&db_path).unwrap();
        conn.execute("CREATE TABLE conversations (value TEXT NOT NULL)", [])
            .unwrap();
        conn.execute(
            "INSERT INTO conversations (value) VALUES (?1)",
            [missing_timestamp.to_string()],
        )
        .unwrap();
        drop(conn);
        let sqlite_scan = scan_kiro_usage_at_paths(&sqlite_home, &db_path, now);
        assert!(!sqlite_scan.completed);
        assert_eq!(sqlite_scan.usage.last30_tokens, 0);
        let _ = std::fs::remove_dir_all(&sqlite_home);
    }

    #[test]
    fn archive_usage_accepts_valid_outer_created_at_fallback() {
        let tmp = temp_home("archive-created-fallback");
        let archive = tmp.join(".kiro_sessions");
        std::fs::create_dir_all(&archive).unwrap();
        let now = Local::now();
        write_json(
            &archive.join("valid.json"),
            &serde_json::json!({
                "conversation_id": "archive-created-fallback",
                "created_at": now.timestamp_millis(),
                "updated_at": now.timestamp_millis(),
                "history": [{
                    "user": "content long enough to produce reportable token usage"
                }]
            }),
        );

        let scan = scan_with_missing_db(&tmp, now);

        assert!(scan.completed);
        assert!(scan.usage.today_tokens > 0);
        assert!(scan.usage.today_usd > 0.0);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn archive_missing_or_invalid_updated_at_marks_source_incomplete() {
        let tmp = temp_home("archive-invalid-updated-at");
        let archive = tmp.join(".kiro_sessions");
        std::fs::create_dir_all(&archive).unwrap();
        let now = Local::now();
        let path = archive.join("invalid.json");
        let fixture = serde_json::json!({
            "conversation_id": "archive-invalid-updated-at",
            "created_at": now.timestamp_millis(),
            "history": [{
                "user": "content long enough to produce reportable token usage",
                "request_metadata": { "request_start_timestamp_ms": now.timestamp_millis() }
            }]
        });

        write_json(&path, &fixture);
        let missing_scan = scan_with_missing_db(&tmp, now);
        assert!(!missing_scan.completed);
        assert_eq!(missing_scan.usage.last30_tokens, 0);

        let mut invalid = fixture;
        invalid["updated_at"] = Value::from("broken");
        write_json(&path, &invalid);
        let invalid_scan = scan_with_missing_db(&tmp, now);
        assert!(!invalid_scan.completed);
        assert_eq!(invalid_scan.usage.last30_tokens, 0);

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn invalid_present_conversation_timestamp_does_not_use_outer_fallback() {
        let tmp = temp_home("archive-invalid-present-timestamp");
        let archive = tmp.join(".kiro_sessions");
        std::fs::create_dir_all(&archive).unwrap();
        let now = Local::now();
        write_json(
            &archive.join("invalid.json"),
            &serde_json::json!({
                "conversation_id": "invalid-present-timestamp",
                "created_at": now.timestamp_millis(),
                "updated_at": now.timestamp_millis(),
                "history": [{
                    "user": "content long enough to produce reportable token usage",
                    "request_metadata": { "request_start_timestamp_ms": "broken" }
                }]
            }),
        );

        let scan = scan_with_missing_db(&tmp, now);

        assert!(!scan.completed);
        assert_eq!(scan.usage.last30_tokens, 0);
        assert_eq!(scan.usage.last30_usd, 0.0);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn report_aggregation_overflow_fails_closed() {
        let now = Local::now();
        let day = now.date_naive();
        let overflowing_tokens = vec![
            SessionPoint {
                day,
                tokens: i64::MAX,
                usd: 0.0,
                model: "kiro".into(),
            },
            SessionPoint {
                day,
                tokens: 1,
                usd: 0.0,
                model: "kiro".into(),
            },
        ];
        assert!(build_report(overflowing_tokens, now).is_none());

        let overflowing_usd = vec![
            SessionPoint {
                day,
                tokens: 0,
                usd: f64::MAX,
                model: "kiro".into(),
            },
            SessionPoint {
                day,
                tokens: 0,
                usd: f64::MAX,
                model: "kiro".into(),
            },
        ];
        assert!(build_report(overflowing_usd, now).is_none());
    }

    #[test]
    fn empty_sqlite_is_not_evidence_but_committed_wal_row_is_completed() {
        let tmp = temp_home("empty-sqlite");
        std::fs::create_dir_all(&tmp).unwrap();
        let db_path = tmp.join("data.sqlite3");
        let conn = Connection::open(&db_path).unwrap();
        conn.execute("CREATE TABLE conversations (value TEXT NOT NULL)", [])
            .unwrap();
        drop(conn);

        let scan = scan_kiro_usage_at_paths(&tmp, &db_path, Local::now());

        assert!(!scan.completed);
        assert_eq!(scan.usage.last30_tokens, 0);

        let conn = Connection::open(&db_path).unwrap();
        conn.execute_batch("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;")
            .unwrap();
        conn.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);")
            .unwrap();
        let now = Local::now();
        let wal_payload = serde_json::json!({
            "conversation_id": "wal-row",
            "history": [{
                "user": "content committed only in the WAL",
                "request_metadata": {
                    "request_start_timestamp_ms": now.timestamp_millis()
                }
            }]
        })
        .to_string();
        conn.execute(
            "INSERT INTO conversations (value) VALUES (?1)",
            [&wal_payload],
        )
        .unwrap();
        assert!(db_path.with_extension("sqlite3-wal").is_file());

        let wal_scan = scan_kiro_usage_at_paths(&tmp, &db_path, now);
        assert!(wal_scan.completed);
        assert!(wal_scan.usage.today_tokens > 0);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn cli_db_path_falls_back_when_xdg_database_is_missing() {
        let tmp = temp_home("xdg-db-fallback");
        let home = tmp.join("home");
        let xdg = tmp.join("xdg-data");
        let default_db = home.join(".local/share/kiro-cli/data.sqlite3");
        std::fs::create_dir_all(default_db.parent().unwrap()).unwrap();
        std::fs::write(&default_db, b"sqlite marker").unwrap();

        assert_eq!(cli_db_path_with_xdg(&home, Some(&xdg)), default_db);

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn source_entry_budget_rejects_entries_after_limit() {
        let mut count = 0;
        assert!(admit_source_entry(&mut count, 2));
        assert!(admit_source_entry(&mut count, 2));
        assert!(!admit_source_entry(&mut count, 2));
        assert_eq!(count, 2);

        let mut bytes = 0;
        assert!(admit_source_bytes(&mut bytes, 3, 5));
        assert!(admit_source_bytes(&mut bytes, 2, 5));
        assert!(!admit_source_bytes(&mut bytes, 1, 5));
        assert_eq!(bytes, 5);
    }

    #[test]
    fn oversized_json_sources_mark_scan_incomplete_before_deserialize() {
        let tmp = temp_home("oversized-json-sources");
        let cli = tmp.join(".kiro/sessions/cli");
        let archive = tmp.join(".kiro_sessions");
        std::fs::create_dir_all(&cli).unwrap();
        std::fs::create_dir_all(&archive).unwrap();
        for path in [cli.join("oversized.json"), archive.join("oversized.json")] {
            let file = std::fs::File::create(path).unwrap();
            file.set_len(MAX_JSON_FILE_BYTES + 1).unwrap();
        }

        let scan = scan_with_missing_db(&tmp, Local::now());

        assert!(!scan.completed);
        assert_eq!(scan.usage.last30_tokens, 0);
        assert_eq!(scan.usage.last30_usd, 0.0);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn oversized_sqlite_storage_fails_before_query() {
        let tmp = temp_home("oversized-sqlite-storage");
        std::fs::create_dir_all(&tmp).unwrap();
        let db_path = tmp.join("data.sqlite3");
        let file = std::fs::File::create(&db_path).unwrap();
        file.set_len(MAX_SCAN_JSON_BYTES + 1).unwrap();

        let scan = scan_kiro_usage_at_paths(&tmp, &db_path, Local::now());

        assert!(!scan.completed);
        assert_eq!(scan.usage.last30_tokens, 0);
        assert_eq!(scan.usage.last30_usd, 0.0);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn excessive_nested_json_structure_fails_closed_before_decode() {
        let tmp = temp_home("excessive-json-structure");
        let cli = tmp.join(".kiro/sessions/cli");
        std::fs::create_dir_all(&cli).unwrap();
        let now = Local::now();
        let turns: Vec<Value> = (0..30_001)
            .map(|_| {
                serde_json::json!({
                    "end_timestamp": now.to_rfc3339(),
                    "input_token_count": 1,
                    "output_token_count": 0
                })
            })
            .collect();
        let payload = serde_json::json!({
            "session_id": "excessive-structure",
            "session_state": {
                "conversation_metadata": {"user_turn_metadatas": turns}
            }
        });
        std::fs::write(
            cli.join("excessive-structure.json"),
            serde_json::to_vec(&payload).unwrap(),
        )
        .unwrap();

        let scan = scan_kiro_usage_at(&tmp, now);

        assert!(!scan.completed);
        assert_eq!(scan.usage.last30_tokens, 0);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn empty_containers_and_empty_turn_arrays_cannot_mint_completed_scan() {
        let tmp = temp_home("empty-semantic-evidence");
        std::fs::create_dir_all(tmp.join(".kiro_sessions")).unwrap();
        std::fs::create_dir_all(tmp.join(".kiro/sessions/cli")).unwrap();
        let now = Local::now();

        let empty = scan_kiro_usage_at(&tmp, now);
        assert!(!empty.completed);

        let payload = serde_json::json!({
            "conversation_id": "empty-history",
            "created_at": now.timestamp_millis(),
            "updated_at": now.timestamp_millis(),
            "history": []
        });
        std::fs::write(
            tmp.join(".kiro_sessions/empty.json"),
            serde_json::to_vec(&payload).unwrap(),
        )
        .unwrap();
        let empty_history = scan_kiro_usage_at(&tmp, now);
        assert!(!empty_history.completed);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn large_valid_turn_workload_stays_within_structure_budget() {
        let tmp = temp_home("large-valid-turn-workload");
        let cli = tmp.join(".kiro/sessions/cli");
        std::fs::create_dir_all(&cli).unwrap();
        let now = Local::now();
        let turns: Vec<Value> = (0..5_000)
            .map(|_| {
                serde_json::json!({
                    "end_timestamp": now.to_rfc3339(),
                    "input_token_count": 1,
                    "output_token_count": 0
                })
            })
            .collect();
        let payload = serde_json::json!({
            "session_id": "large-valid-workload",
            "session_state": {
                "conversation_metadata": {"user_turn_metadatas": turns}
            }
        });
        std::fs::write(
            cli.join("large.json"),
            serde_json::to_vec(&payload).unwrap(),
        )
        .unwrap();

        let scan = scan_kiro_usage_at(&tmp, now);

        assert!(scan.completed);
        assert_eq!(scan.usage.today_tokens, 5_000);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn synthetic_other_model_name_is_reserved_at_ingress() {
        let value = serde_json::json!(AGGREGATE_MODEL_NAME);
        assert!(normalized_model_id(Some(&value)).is_none());
    }

    #[test]
    fn sqlite_row_and_utf8_byte_limits_mark_source_incomplete() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute("CREATE TABLE conversations (value TEXT NOT NULL)", [])
            .unwrap();
        for id in ["one", "two"] {
            let raw = serde_json::json!({
                "conversation_id": id,
                "history": []
            })
            .to_string();
            conn.execute("INSERT INTO conversations (value) VALUES (?1)", [&raw])
                .unwrap();
        }
        let now = Local::now();
        let cutoff = (now - Duration::days(HISTORY_DAYS - 1)).date_naive();
        let mut by_id = HashMap::new();
        let mut source_bytes = 0;
        let mut structure_units = 0;
        let row_limited = query_conversations_v1(
            &conn,
            0,
            cutoff,
            now.timestamp_millis(),
            1,
            MAX_JSON_FILE_BYTES,
            &mut source_bytes,
            MAX_SCAN_JSON_BYTES,
            &mut structure_units,
            &mut by_id,
        );
        assert!(row_limited.available);
        assert!(!row_limited.completed);

        conn.execute("DELETE FROM conversations", []).unwrap();
        let utf8_payload = serde_json::json!({
            "conversation_id": "utf8-bytes",
            "history": [],
            "label": "éééé"
        })
        .to_string();
        assert!(utf8_payload.len() > utf8_payload.chars().count());
        conn.execute(
            "INSERT INTO conversations (value) VALUES (?1)",
            [&utf8_payload],
        )
        .unwrap();
        let mut by_id = HashMap::new();
        let mut source_bytes = 0;
        let mut structure_units = 0;
        let byte_limited = query_conversations_v1(
            &conn,
            0,
            cutoff,
            now.timestamp_millis(),
            MAX_SOURCE_ENTRIES,
            utf8_payload.chars().count() as u64,
            &mut source_bytes,
            MAX_SCAN_JSON_BYTES,
            &mut structure_units,
            &mut by_id,
        );
        assert!(byte_limited.available);
        assert!(!byte_limited.completed);
        assert!(by_id.is_empty());
    }

    #[test]
    fn sqlite_v2_future_metadata_marks_source_incomplete() {
        let tmp = temp_home("sqlite-v2-future-metadata");
        std::fs::create_dir_all(&tmp).unwrap();
        let db_path = tmp.join("data.sqlite3");
        let now = Local::now();
        let future = (now + Duration::days(2)).timestamp_millis();
        let payload = serde_json::json!({
            "history": [{
                "user": "content long enough to produce reportable token usage",
                "request_metadata": { "request_start_timestamp_ms": now.timestamp_millis() }
            }]
        })
        .to_string();

        for (id, created, updated) in [
            ("future-updated", now.timestamp_millis(), future),
            ("future-created", future, now.timestamp_millis()),
        ] {
            let _ = std::fs::remove_file(&db_path);
            let conn = Connection::open(&db_path).unwrap();
            conn.execute(
                "CREATE TABLE conversations_v2 (conversation_id TEXT, created_at INTEGER, updated_at INTEGER, value TEXT)",
                [],
            )
            .unwrap();
            conn.execute(
                "INSERT INTO conversations_v2 VALUES (?1, ?2, ?3, ?4)",
                rusqlite::params![id, created, updated, payload],
            )
            .unwrap();
            drop(conn);

            let scan = scan_kiro_usage_at_paths(&tmp, &db_path, now);
            assert!(!scan.completed, "{id}");
            assert_eq!(scan.usage.last30_tokens, 0, "{id}");
        }
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn present_drifted_v2_table_is_not_hidden_by_valid_v1_table() {
        let tmp = temp_home("sqlite-v2-schema-drift");
        std::fs::create_dir_all(&tmp).unwrap();
        let db_path = tmp.join("data.sqlite3");
        let conn = Connection::open(&db_path).unwrap();
        conn.execute("CREATE TABLE conversations (value TEXT NOT NULL)", [])
            .unwrap();
        conn.execute(
            "CREATE TABLE conversations_v2 (conversation_id TEXT, created_at INTEGER, value TEXT)",
            [],
        )
        .unwrap();
        drop(conn);

        let scan = scan_kiro_usage_at_paths(&tmp, &db_path, Local::now());
        assert!(!scan.completed);
        assert_eq!(scan.usage.last30_tokens, 0);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn malformed_available_archive_downgrades_completion() {
        let tmp = temp_home("malformed-archive");
        let archive = tmp.join(".kiro_sessions");
        std::fs::create_dir_all(&archive).unwrap();
        std::fs::write(archive.join("bad.json"), b"not-json").unwrap();

        let scan = scan_with_missing_db(&tmp, Local::now());

        assert!(!scan.completed);
        assert_eq!(scan.usage.last30_tokens, 0);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn malformed_sqlite_downgrades_completion() {
        let tmp = temp_home("malformed-sqlite");
        std::fs::create_dir_all(&tmp).unwrap();
        let db_path = tmp.join("data.sqlite3");
        std::fs::write(&db_path, b"not a sqlite database").unwrap();

        let scan = scan_kiro_usage_at_paths(&tmp, &db_path, Local::now());

        assert!(!scan.completed);
        assert_eq!(scan.usage.last30_tokens, 0);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn report_preserves_global_top_model_and_daily_model_totals() {
        let today = Local::now().date_naive();
        let now = Local
            .from_local_datetime(&today.and_hms_opt(9, 0, 0).unwrap())
            .single()
            .unwrap();
        let mut points = Vec::new();
        for offset in 0_i64..30 {
            let day = today - Duration::days(offset);
            for rank in 0..7 {
                points.push(SessionPoint {
                    day,
                    tokens: 100,
                    usd: 0.01,
                    model: format!("burst-{offset}-{rank}"),
                });
            }
            points.push(SessionPoint {
                day,
                tokens: 90,
                usd: 0.009,
                model: "steady".to_string(),
            });
        }

        let report = build_report(points, now).unwrap();

        assert_eq!(report.top_model.as_deref(), Some("steady"));
        for day in report.daily.iter().rev().take(30) {
            assert_eq!(day.tokens, 790);
            assert_eq!(
                day.models.iter().map(|model| model.tokens).sum::<i64>(),
                790
            );
            assert!((day.models.iter().map(|model| model.usd).sum::<f64>() - day.usd).abs() < 1e-9);
            assert!(day.models.iter().any(|model| model.name == "steady"));
            assert!(day.models.iter().any(|model| model.name == "Other"));
        }
    }

    #[test]
    fn same_day_future_usage_beyond_clock_skew_fails_closed() {
        let tmp = temp_home("same-day-future");
        let cli = tmp.join(".kiro").join("sessions").join("cli");
        std::fs::create_dir_all(&cli).unwrap();
        let today = Local::now().date_naive();
        let now = Local
            .from_local_datetime(&today.and_hms_opt(9, 0, 0).unwrap())
            .single()
            .unwrap();
        let future = now + Duration::hours(2);
        assert_eq!(future.date_naive(), now.date_naive());
        write_json(
            &cli.join("future.json"),
            &serde_json::json!({
                "session_id": "same-day-future",
                "created_at": now.to_rfc3339(),
                "updated_at": now.to_rfc3339(),
                "session_state": {
                    "rts_model_state": {
                        "model_info": { "model_id": "claude-sonnet-4-5" }
                    },
                    "conversation_metadata": {
                        "user_turn_metadatas": [{
                            "metering_usage": [{ "unit": "credit", "value": 1.0 }],
                            "input_token_count": 10,
                            "output_token_count": 5,
                            "end_timestamp": future.to_rfc3339()
                        }]
                    }
                }
            }),
        );

        let scan = scan_with_missing_db(&tmp, now);

        assert!(!scan.completed);
        assert_eq!(scan.usage.today_tokens, 0);
        assert_eq!(scan.usage.today_usd, 0.0);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn parse_conversation_estimates_tokens_and_usd_from_char_counts() {
        let now = Local::now();
        let value = serde_json::json!({
            "history": [
                {
                    "request_metadata": { "model_id": "claude-sonnet-4-5", "request_start_timestamp_ms": now.timestamp_millis() },
                    "user": "hello world this is a test message with enough characters",
                    "assistant": "this is the assistant reply text with several words in it too"
                }
            ]
        });
        let cutoff = (now - Duration::days(1)).date_naive();
        let points = parse_conversation(&value, 0, cutoff, now.timestamp_millis()).unwrap();
        assert_eq!(points.len(), 1);
        assert!(points[0].tokens > 0);
        assert!(points[0].usd > 0.0);
        assert_eq!(points[0].model, "claude-sonnet-4-5");
        assert_eq!(
            text_token_estimate(&Value::String("👨‍👩‍👧‍👦".repeat(4))).unwrap(),
            25
        );
    }
}
