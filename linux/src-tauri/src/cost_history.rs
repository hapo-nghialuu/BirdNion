//! Persisted per-day cost history — port of macOS `CostHistoryStore`.
//!
//! File: sibling of settings.json → `cost-history.json`.
//! Merge rule: never-shrink (prefer higher tokens, then usd).

use chrono::{Local, NaiveDate, NaiveDateTime, TimeZone};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::io::{ErrorKind, Read};
use std::path::{Path, PathBuf};

use crate::config;
use crate::usage::{DailyModel, DailyUsage, UsageReport};

pub const RETAIN_DAYS: i64 = 400;
pub const WINDOW_DAYS: i64 = 120;
const DOCUMENT_VERSION: u32 = 1;
const MAX_HISTORY_BYTES: usize = 8 * 1024 * 1024;
const MODEL_NAME_MAX_CHARS: usize = 128;
const MAX_MODELS_PER_DAY: usize = 32;
const MAX_SCANNED_AT_FUTURE_MS: i64 = 5 * 60 * 1_000;
const KNOWN_SOURCES: [&str; 6] = ["claude", "codex", "grok", "kiro", "omp", "pi"];

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
    #[serde(
        default,
        alias = "scannedAt",
        deserialize_with = "deserialize_scanned_at"
    )]
    pub scanned_at: HashMap<String, i64>,
    /// source → revision của ngữ nghĩa đếm đã dùng để dựng các ngày đang lưu.
    /// Scanner bump số này khi đổi cách tính; chênh lệch buộc dựng lại một lần.
    #[serde(default, alias = "countingRevision")]
    pub counting_revision: HashMap<String, i64>,
    /// source → canonical trailing-window top model. Daily chart payloads can
    /// contain an aggregate bucket, so recomputing from them may pick a false
    /// winner after restart.
    #[serde(default, alias = "topModels")]
    pub top_models: HashMap<String, String>,
}

/// Accept the fractional JSON milliseconds written by older macOS builds, but
/// normalize once to integer milliseconds. Serialization remains canonical via
/// the `HashMap<String, i64>` field, matching all new macOS writes.
fn deserialize_scanned_at<'de, D>(deserializer: D) -> Result<HashMap<String, i64>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    use serde::de::Error as _;

    let raw = HashMap::<String, serde_json::Number>::deserialize(deserializer)?;
    raw.into_iter()
        .map(|(source, value)| {
            let millis = if let Some(integer) = value.as_i64() {
                integer
            } else {
                let float = value
                    .as_f64()
                    .ok_or_else(|| D::Error::custom("invalid epoch-millisecond number"))?;
                if !float.is_finite() || float < i64::MIN as f64 || float >= i64::MAX as f64 {
                    return Err(D::Error::custom("epoch milliseconds out of range"));
                }
                float.trunc() as i64
            };
            Ok((source, millis))
        })
        .collect()
}

/// Revision đã lưu cho một nguồn (0 nếu chưa từng ghi).
pub fn counting_revision(source: &str) -> i64 {
    read().counting_revision.get(source).copied().unwrap_or(0)
}

/// Ghi nhận nguồn đã được dựng lại theo revision mới.
pub fn set_counting_revision(source: &str, revision: i64) {
    let _guard = HISTORY_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    if revision < 0 {
        return;
    }
    let Ok(mut doc) = read_for_mutation(Local::now().timestamp_millis()) else {
        return;
    };
    doc.counting_revision.insert(source.to_string(), revision);
    let _ = write(&doc);
}

pub fn history_path() -> Option<PathBuf> {
    config::support_dir().map(|path| path.join("cost-history.json"))
}

pub fn read() -> Document {
    read_for_mutation(Local::now().timestamp_millis()).unwrap_or_default()
}

/// Mutation reads only default when the file is genuinely missing. Existing
/// unreadable, malformed, or semantically invalid history must fail closed so
/// a later write cannot replace it with a partial/default document.
fn read_for_mutation(now_ms: i64) -> Result<Document, String> {
    let path = history_path().ok_or_else(|| "Không xác định được thư mục cấu hình".to_string())?;
    read_path_for_mutation(&path, now_ms)
}

fn read_path_for_mutation(path: &Path, now_ms: i64) -> Result<Document, String> {
    let Some(file) = open_history_descriptor(path)? else {
        return Ok(Document::default());
    };
    let metadata = file.metadata().map_err(|error| error.to_string())?;
    if !metadata.is_file()
        || metadata.file_type().is_symlink()
        || metadata.len() > MAX_HISTORY_BYTES as u64
    {
        return Err("File lịch sử chi phí không phải file thường hoặc vượt giới hạn".to_string());
    }

    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    file.take((MAX_HISTORY_BYTES + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|error| error.to_string())?;
    if bytes.len() > MAX_HISTORY_BYTES {
        return Err("File lịch sử chi phí vượt giới hạn".to_string());
    }
    let document: Document = serde_json::from_slice(&bytes).map_err(|error| error.to_string())?;
    validate_document(&document, now_ms)
        .then_some(document)
        .ok_or_else(|| "Lịch sử chi phí chứa dữ liệu không hợp lệ".to_string())
}

/// Open the exact object that will be inspected. On Unix, `O_NOFOLLOW`
/// rejects both live and dangling symlinks before any bytes are read.
fn open_history_descriptor(path: &Path) -> Result<Option<File>, String> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x0020_0000;
        options.custom_flags(FILE_FLAG_OPEN_REPARSE_POINT);
    }

    match options.open(path) {
        Ok(file) => Ok(Some(file)),
        Err(error) if error.kind() == ErrorKind::NotFound => {
            match std::fs::symlink_metadata(path) {
                Err(metadata_error) if metadata_error.kind() == ErrorKind::NotFound => Ok(None),
                Ok(_) => Err("Đường dẫn lịch sử chi phí tồn tại nhưng không đọc được".to_string()),
                Err(metadata_error) => Err(metadata_error.to_string()),
            }
        }
        Err(error) => Err(error.to_string()),
    }
}

pub fn write(doc: &Document) -> Result<(), String> {
    let path = history_path().ok_or_else(|| "Không xác định được thư mục cấu hình".to_string())?;
    let now_ms = Local::now().timestamp_millis();
    if !validate_document(doc, now_ms) {
        return Err("Lịch sử chi phí chứa dữ liệu không hợp lệ".to_string());
    }
    // Keep the same fail-closed contract for direct callers of this public
    // helper, not only the read-modify-write paths below.
    let _ = read_path_for_mutation(&path, now_ms)?;
    let mut out = doc.clone();
    out.version = DOCUMENT_VERSION;
    let json = serde_json::to_string_pretty(&out).map_err(|e| e.to_string())?;
    if json.len() > MAX_HISTORY_BYTES {
        return Err("File lịch sử chi phí vượt giới hạn".to_string());
    }
    crate::platform::atomic_file::write_private_atomic(&path, json.as_bytes())
        .map_err(|error| error.to_string())
}

fn valid_usd(value: f64) -> bool {
    value.is_finite() && value >= 0.0
}

fn valid_model_name(name: &str) -> bool {
    !name.trim().is_empty()
        && name.chars().count() <= MODEL_NAME_MAX_CHARS
        && !name.chars().any(|character| character.is_control())
}

fn canonical_day_key(key: &str, today: NaiveDate) -> bool {
    NaiveDate::parse_from_str(key, "%Y-%m-%d")
        .is_ok_and(|date| date <= today && date.format("%Y-%m-%d").to_string() == key)
}

fn canonical_hour_key(key: &str) -> bool {
    NaiveDateTime::parse_from_str(key, "%Y-%m-%dT%H:%M")
        .is_ok_and(|date| date.format("%Y-%m-%dT%H:00").to_string() == key)
}

fn add_usd(total: &mut f64, value: f64) -> bool {
    if !valid_usd(value) {
        return false;
    }
    let next = *total + value;
    if !next.is_finite() {
        return false;
    }
    *total = next;
    true
}

fn add_tokens(total: &mut i64, value: i64) -> bool {
    if value < 0 {
        return false;
    }
    let Some(next) = total.checked_add(value) else {
        return false;
    };
    *total = next;
    true
}

fn validate_models(models: &[HistoryModel], total_usd: &mut f64, total_tokens: &mut i64) -> bool {
    models.len() <= MAX_MODELS_PER_DAY
        && models.iter().all(|model| {
            valid_model_name(&model.name)
                && add_usd(total_usd, model.usd)
                && add_tokens(total_tokens, model.tokens)
        })
}

fn known_source(source: &str) -> bool {
    KNOWN_SOURCES.contains(&source)
}

fn valid_source_map<T>(map: &HashMap<String, T>) -> bool {
    map.len() <= KNOWN_SOURCES.len() && map.keys().all(|source| known_source(source))
}

fn validate_document(document: &Document, now_ms: i64) -> bool {
    let latest_safe_scan = now_ms.saturating_add(MAX_SCANNED_AT_FUTURE_MS);
    let Some(today) = Local
        .timestamp_millis_opt(now_ms)
        .single()
        .map(|date| date.date_naive())
    else {
        return false;
    };
    if document.version > DOCUMENT_VERSION
        || !valid_source_map(&document.sources)
        || !valid_source_map(&document.scanned_at)
        || !valid_source_map(&document.counting_revision)
        || !valid_source_map(&document.top_models)
        || document
            .scanned_at
            .values()
            .any(|timestamp| *timestamp < 0 || *timestamp > latest_safe_scan)
        || document
            .counting_revision
            .values()
            .any(|revision| *revision < 0)
        || document
            .top_models
            .values()
            .any(|name| !valid_model_name(name))
    {
        return false;
    }

    document.sources.values().all(|days| {
        if days.len() > RETAIN_DAYS as usize {
            return false;
        }
        let mut day_usd = 0.0;
        let mut day_tokens = 0;
        let mut model_usd = 0.0;
        let mut model_tokens = 0;
        days.iter().all(|(key, day)| {
            canonical_day_key(key, today)
                && add_usd(&mut day_usd, day.usd)
                && add_tokens(&mut day_tokens, day.tokens)
                && validate_models(&day.models, &mut model_usd, &mut model_tokens)
        })
    })
}

fn validate_live_report(report: &UsageReport, today: NaiveDate) -> bool {
    if report.daily.len() > RETAIN_DAYS as usize
        || report.hourly.len() > 24
        || !valid_usd(report.today_usd)
        || report.today_tokens < 0
        || !valid_usd(report.last30_usd)
        || report.last30_tokens < 0
        || report
            .top_model
            .as_deref()
            .is_some_and(|name| !valid_model_name(name))
    {
        return false;
    }

    let mut daily_usd = 0.0;
    let mut daily_tokens = 0;
    let mut model_usd = 0.0;
    let mut model_tokens = 0;
    let valid_daily = report.daily.iter().all(|day| {
        canonical_day_key(&day.date, today)
            && add_usd(&mut daily_usd, day.usd)
            && add_tokens(&mut daily_tokens, day.tokens)
            && day.models.len() <= MAX_MODELS_PER_DAY
            && day.models.iter().all(|model| {
                valid_model_name(&model.name)
                    && add_usd(&mut model_usd, model.usd)
                    && add_tokens(&mut model_tokens, model.tokens)
            })
    });
    if !valid_daily {
        return false;
    }

    let mut hourly_usd = 0.0;
    let mut hourly_tokens = 0;
    report.hourly.iter().all(|hour| {
        canonical_hour_key(&hour.hour)
            && add_usd(&mut hourly_usd, hour.usd)
            && add_tokens(&mut hourly_tokens, hour.tokens)
    })
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

/// Merge live daily buckets for `source`, persist, return 120-day window as UsageReport.
pub fn apply_and_report(source: &str, live: Option<&UsageReport>) -> UsageReport {
    apply_and_report_inner(source, live, false, None)
}

/// Read-only seed used by the Linux Codex background scanner. It never
/// rewrites history or advances freshness while a live generation is pending.
pub fn report(source: &str) -> UsageReport {
    let _guard = HISTORY_LOCK
        .lock()
        .unwrap_or_else(|error| error.into_inner());
    let now = Local::now();
    let document = read_for_mutation(now.timestamp_millis()).unwrap_or_default();
    build_report(source, &document, None, false, now.date_naive())
}

/// Như `apply_and_report` nhưng THAY THẾ hẳn chuỗi ngày của nguồn thay vì gộp
/// không-bao-giờ-giảm.
///
/// Chỉ dùng khi ngữ nghĩa đếm của một nguồn thay đổi: lúc đó các giá trị
/// high-water cũ được tính bằng công thức khác, giữ lại là sai. Bình thường
/// vẫn phải gộp, vì không-bao-giờ-giảm chính là thứ giữ lại lịch sử của
/// session đã bị xoá khỏi đĩa (macOS `applyWithReceipt(replacingSource:)`).
pub fn apply_and_report_replacing(source: &str, live: Option<&UsageReport>) -> UsageReport {
    apply_and_report_inner(source, live, true, None)
}

/// Atomically migrates one source to a newer counting revision. An older
/// stored revision replaces that source only when a valid live report is
/// available; a future stored revision stays history-only and untouched. The
/// replacement, revision stamp, freshness stamp, and all other sources are
/// persisted in the same write. Equal revisions resume normal high-water merge.
pub fn apply_and_report_at_counting_revision(
    source: &str,
    live: Option<&UsageReport>,
    target_revision: i64,
) -> UsageReport {
    apply_and_report_inner(source, live, false, Some(target_revision))
}

fn apply_and_report_inner(
    source: &str,
    live: Option<&UsageReport>,
    replacing: bool,
    target_revision: Option<i64>,
) -> UsageReport {
    apply_and_report_with_writer(source, live, replacing, target_revision, write)
}

fn apply_and_report_with_writer<F>(
    source: &str,
    live: Option<&UsageReport>,
    replacing: bool,
    target_revision: Option<i64>,
    persist: F,
) -> UsageReport
where
    F: FnOnce(&Document) -> Result<(), String>,
{
    let _guard = HISTORY_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let now = Local::now();
    let today = now.date_naive();
    let previous = match read_for_mutation(now.timestamp_millis()) {
        Ok(document) => document,
        Err(_) => return build_report(source, &Document::default(), None, false, today),
    };
    if live.is_some_and(|report| !validate_live_report(report, today)) {
        return build_report(source, &previous, None, false, today);
    }
    let revision_needs_replace = match target_revision {
        Some(target) if target < 0 => return build_report(source, &previous, None, false, today),
        Some(target) => {
            let stored = previous.counting_revision.get(source).copied().unwrap_or(0);
            if stored > target {
                return build_report(source, &previous, None, false, today);
            }
            stored < target
        }
        None => false,
    };
    if revision_needs_replace && live.is_none() {
        return build_report(source, &previous, None, false, today);
    }
    let replace_source = replacing || revision_needs_replace;
    let mut doc = previous.clone();
    {
        let by_day = doc.sources.entry(source.to_string()).or_default();

        // Chỉ xoá khi CÓ dữ liệu quét mới thay thế — quét hỏng mà xoá trước là
        // mất trắng lịch sử.
        if replace_source && live.is_some() {
            by_day.clear();
        }

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

    let resulting_source_has_data = doc
        .sources
        .get(source)
        .is_some_and(|days| days.values().any(|day| day.tokens > 0 || day.usd > 0.0));
    let resulting_top_model = doc
        .sources
        .get(source)
        .and_then(|days| trailing_top_model(source, days, today));

    // Data Confidence Pass: stamp the last successful live-scan time so a
    // later history-only cycle (live == None) can still report freshness.
    if live.is_some() {
        doc.scanned_at
            .insert(source.to_string(), now.timestamp_millis());
        match resulting_top_model {
            Some(top_model) => {
                doc.top_models.insert(source.to_string(), top_model);
            }
            None if replace_source => {
                doc.top_models.remove(source);
            }
            None => {}
        }
    }
    if !resulting_source_has_data {
        doc.top_models.remove(source);
    }
    if revision_needs_replace {
        if let Some(target) = target_revision {
            doc.counting_revision.insert(source.to_string(), target);
        }
    }

    let persisted_live = if persist(&doc).is_ok() {
        live.is_some()
    } else {
        doc = previous;
        false
    };
    build_report(source, &doc, live, persisted_live, today)
}

/// Winner across the resulting merged trailing-30 history. The aggregate
/// `Other` chart bucket is not a real model. Equal totals resolve by USD and
/// then lexicographically smallest label so HashMap iteration cannot matter.
fn trailing_top_model(
    source: &str,
    source_days: &HashMap<String, HistoryDay>,
    today: NaiveDate,
) -> Option<String> {
    let start = today - chrono::Duration::days(29);
    let mut totals: HashMap<String, (i64, f64)> = HashMap::new();
    for (key, day) in source_days {
        let Some(date) = NaiveDate::parse_from_str(key, "%Y-%m-%d").ok() else {
            continue;
        };
        if date < start || date > today {
            continue;
        }
        for model in &day.models {
            if source == "kiro" && model.name == "Other" {
                continue;
            }
            let total = totals.entry(model.name.clone()).or_insert((0, 0.0));
            let Some(tokens) = total.0.checked_add(model.tokens) else {
                continue;
            };
            let usd = total.1 + model.usd;
            if !usd.is_finite() {
                continue;
            }
            *total = (tokens, usd);
        }
    }
    totals
        .into_iter()
        .max_by(|(left_name, left), (right_name, right)| {
            left.0
                .cmp(&right.0)
                .then_with(|| left.1.total_cmp(&right.1))
                .then_with(|| right_name.cmp(left_name))
        })
        .map(|(name, _)| name)
}

fn build_report(
    source: &str,
    document: &Document,
    live: Option<&UsageReport>,
    persisted_live: bool,
    today: NaiveDate,
) -> UsageReport {
    let by_day = document.sources.get(source).cloned().unwrap_or_default();
    let history_has_data = by_day.values().any(|d| d.tokens > 0 || d.usd > 0.0);
    let scanned_at = document.scanned_at.get(source).copied();

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

    let top = document
        .top_models
        .get(source)
        .filter(|name| source != "kiro" || name.as_str() != "Other")
        .cloned()
        .or_else(|| trailing_top_model(source, &by_day, today));

    UsageReport {
        today_usd: today_u.map(|d| d.usd).unwrap_or(0.0),
        today_tokens: today_u.map(|d| d.tokens).unwrap_or(0),
        last30_usd,
        last30_tokens,
        daily,
        hourly: live
            .filter(|_| persisted_live)
            .map(|report| report.hourly.clone())
            .unwrap_or_default(),
        top_model: top,
        included: is_included(persisted_live, history_has_data),
        live: persisted_live,
        scanned_at,
        scan_pending: None,
        scan_progress: None,
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

    fn valid_document_for_today() -> Document {
        let today = Local::now().date_naive().to_string();
        Document {
            version: 1,
            sources: HashMap::from([(
                "codex".to_string(),
                HashMap::from([(
                    today,
                    HistoryDay {
                        usd: 1.0,
                        tokens: 100,
                        models: vec![HistoryModel {
                            name: "gpt-5".to_string(),
                            usd: 1.0,
                            tokens: 100,
                        }],
                    },
                )]),
            )]),
            scanned_at: HashMap::from([("codex".to_string(), 1)]),
            counting_revision: HashMap::from([("grok".to_string(), 3)]),
            top_models: HashMap::from([("codex".to_string(), "gpt-5".to_string())]),
        }
    }

    fn stored_today_tokens(document: &Document, source: &str) -> i64 {
        let today = Local::now().date_naive().to_string();
        document.sources[source][&today].tokens
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
    fn apply_and_report_returns_full_120_day_window() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config("full-window");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));

        let old_day = Local::now().date_naive() - chrono::Duration::days(100);
        let live = UsageReport {
            daily: vec![DailyUsage {
                date: old_day.to_string(),
                usd: 1.25,
                tokens: 125,
                models: vec![],
            }],
            ..Default::default()
        };
        let report = apply_and_report("kiro", Some(&live));

        assert_eq!(WINDOW_DAYS, 120);
        assert_eq!(report.daily.len(), 120);
        let expected_first = (Local::now().date_naive() - chrono::Duration::days(119)).to_string();
        assert_eq!(
            report.daily.first().map(|day| day.date.as_str()),
            Some(expected_first.as_str())
        );
        let retained = report
            .daily
            .iter()
            .find(|day| day.date == old_day.to_string())
            .expect("day 100 must remain visible in the 120-day response");
        assert_eq!(retained.tokens, 125);
        assert_eq!(retained.usd, 1.25);
        assert_eq!(report.last30_tokens, 0);

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
    fn canonical_top_model_survives_aggregate_bucket_and_history_only_reload() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config("top-model-persistence");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));
        let mut live = live_report_for_today(280);
        live.daily[0].models = vec![
            DailyModel {
                name: "real-top".to_string(),
                usd: 0.01,
                tokens: 100,
            },
            DailyModel {
                name: "Other".to_string(),
                usd: 0.02,
                tokens: 180,
            },
        ];
        live.top_model = Some("real-top".to_string());

        let current = apply_and_report("kiro", Some(&live));
        let history_only = apply_and_report("kiro", None);

        assert_eq!(current.top_model.as_deref(), Some("real-top"));
        assert_eq!(history_only.top_model.as_deref(), Some("real-top"));
        assert_eq!(
            read().top_models.get("kiro").map(String::as_str),
            Some("real-top")
        );
        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn synthetic_other_metadata_never_wins_kiro_history_only_report() {
        let today = Local::now().date_naive();
        let document = Document {
            version: DOCUMENT_VERSION,
            sources: HashMap::from([(
                "kiro".to_string(),
                HashMap::from([(
                    today.to_string(),
                    HistoryDay {
                        usd: 2.8,
                        tokens: 280,
                        models: vec![
                            HistoryModel {
                                name: "real-model".to_string(),
                                usd: 1.0,
                                tokens: 100,
                            },
                            HistoryModel {
                                name: "Other".to_string(),
                                usd: 1.8,
                                tokens: 180,
                            },
                        ],
                    },
                )]),
            )]),
            top_models: HashMap::from([("kiro".to_string(), "Other".to_string())]),
            ..Default::default()
        };

        let report = build_report("kiro", &document, None, false, today);

        assert_eq!(report.top_model.as_deref(), Some("real-model"));
        assert!(!report.live);
    }

    #[test]
    fn non_kiro_other_model_remains_top_and_persists() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config("non-kiro-other-top-model");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));
        let mut live = live_report_for_today(280);
        live.daily[0].models = vec![
            DailyModel {
                name: "Other".to_string(),
                usd: 1.8,
                tokens: 180,
            },
            DailyModel {
                name: "named-model".to_string(),
                usd: 1.0,
                tokens: 100,
            },
        ];

        for source in ["codex", "grok"] {
            assert_eq!(
                apply_and_report(source, Some(&live)).top_model.as_deref(),
                Some("Other")
            );
            assert_eq!(
                apply_and_report(source, None).top_model.as_deref(),
                Some("Other")
            );
            assert_eq!(
                read().top_models.get(source).map(String::as_str),
                Some("Other")
            );
        }

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn merged_trailing_top_model_survives_incremental_and_empty_live_reports() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config("top-model-merged-history");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));
        let today = Local::now().date_naive();
        let initial = UsageReport {
            daily: vec![DailyUsage {
                date: (today - chrono::Duration::days(1)).to_string(),
                usd: 1.0,
                tokens: 100,
                models: vec![DailyModel {
                    name: "A".to_string(),
                    usd: 1.0,
                    tokens: 100,
                }],
            }],
            top_model: Some("A".to_string()),
            ..Default::default()
        };
        let incremental = UsageReport {
            daily: vec![DailyUsage {
                date: today.to_string(),
                usd: 0.9,
                tokens: 90,
                models: vec![DailyModel {
                    name: "B".to_string(),
                    usd: 0.9,
                    tokens: 90,
                }],
            }],
            top_model: Some("B".to_string()),
            ..Default::default()
        };

        assert_eq!(
            apply_and_report("kiro", Some(&initial))
                .top_model
                .as_deref(),
            Some("A")
        );
        assert_eq!(
            apply_and_report("kiro", Some(&incremental))
                .top_model
                .as_deref(),
            Some("A"),
            "winner must come from merged trailing history, not the live subset"
        );
        assert_eq!(
            apply_and_report("kiro", Some(&UsageReport::default()))
                .top_model
                .as_deref(),
            Some("A"),
            "an empty completed scan must not erase a high-water winner"
        );
        assert_eq!(
            apply_and_report("kiro", None).top_model.as_deref(),
            Some("A")
        );
        assert_eq!(read().top_models.get("kiro").map(String::as_str), Some("A"));

        let replaced = apply_and_report_replacing("kiro", Some(&UsageReport::default()));
        assert_eq!(replaced.top_model, None);
        assert!(!read().top_models.contains_key("kiro"));

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn trailing_top_model_ties_are_deterministic() {
        let today = Local::now().date_naive();
        let tied = HashMap::from([(
            today.to_string(),
            HistoryDay {
                usd: 3.0,
                tokens: 300,
                models: vec![
                    HistoryModel {
                        name: "zeta".to_string(),
                        usd: 1.0,
                        tokens: 100,
                    },
                    HistoryModel {
                        name: "alpha".to_string(),
                        usd: 1.0,
                        tokens: 100,
                    },
                    HistoryModel {
                        name: "Other".to_string(),
                        usd: 10.0,
                        tokens: 1_000,
                    },
                ],
            },
        )]);

        assert_eq!(
            trailing_top_model("kiro", &tied, today).as_deref(),
            Some("alpha")
        );
    }

    #[test]
    fn history_only_prune_clears_top_model_when_source_becomes_empty() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config("top-model-pruned-empty");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));
        let old_day = Local::now().date_naive() - chrono::Duration::days(RETAIN_DAYS + 1);
        let document = Document {
            version: DOCUMENT_VERSION,
            sources: HashMap::from([(
                "kiro".to_string(),
                HashMap::from([(
                    old_day.to_string(),
                    HistoryDay {
                        usd: 1.0,
                        tokens: 100,
                        models: vec![HistoryModel {
                            name: "A".to_string(),
                            usd: 1.0,
                            tokens: 100,
                        }],
                    },
                )]),
            )]),
            top_models: HashMap::from([("kiro".to_string(), "A".to_string())]),
            ..Default::default()
        };
        std::fs::write(
            history_path().unwrap(),
            serde_json::to_vec_pretty(&document).unwrap(),
        )
        .unwrap();

        let pruned = apply_and_report("kiro", None);

        assert!(!pruned.included);
        assert_eq!(pruned.top_model, None);
        let persisted = read();
        assert!(!persisted.top_models.contains_key("kiro"));
        assert!(persisted.sources["kiro"].is_empty());

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[cfg(unix)]
    #[test]
    fn dangling_symlink_is_not_treated_as_genuinely_missing_history() {
        use std::os::unix::fs::symlink;

        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config("dangling-symlink");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));
        let path = history_path().unwrap();
        let missing_target = base.join("missing-target.json");
        symlink(&missing_target, &path).unwrap();

        let report = apply_and_report("kiro", Some(&live_report_for_today(25)));

        assert!(!report.live);
        assert!(!report.included);
        assert!(std::fs::symlink_metadata(&path)
            .unwrap()
            .file_type()
            .is_symlink());
        assert!(!missing_target.exists());
        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[cfg(unix)]
    #[test]
    fn fifo_history_path_fails_without_blocking() {
        use std::ffi::CString;
        use std::os::unix::ffi::OsStrExt;
        use std::sync::mpsc;
        use std::time::Duration;

        let base = temp_config("fifo");
        let path = base.join("cost-history.json");
        let raw_path = CString::new(path.as_os_str().as_bytes()).unwrap();
        // SAFETY: `raw_path` is NUL-terminated and valid for this call.
        assert_eq!(unsafe { libc::mkfifo(raw_path.as_ptr(), 0o600) }, 0);
        let (sender, receiver) = mpsc::channel();
        let handle = std::thread::spawn(move || {
            let _ = sender
                .send(read_path_for_mutation(&path, Local::now().timestamp_millis()).is_err());
        });

        assert_eq!(
            receiver.recv_timeout(Duration::from_secs(2)),
            Ok(true),
            "opening a FIFO must fail closed instead of waiting for a writer"
        );
        handle.join().unwrap();
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
    fn malformed_existing_history_is_unchanged_after_apply() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config("malformed-existing");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));
        let path = history_path().unwrap();
        let malformed = b"{not-json";
        std::fs::write(&path, malformed).unwrap();

        let report = apply_and_report("claude", Some(&live_report_for_today(500)));

        assert!(!report.live);
        assert!(!report.included);
        assert!(report
            .daily
            .iter()
            .all(|day| day.tokens == 0 && day.usd == 0.0));
        assert_eq!(std::fs::read(&path).unwrap(), malformed);
        set_counting_revision("grok", 9);
        assert_eq!(std::fs::read(&path).unwrap(), malformed);
        let migration =
            apply_and_report_at_counting_revision("kiro", Some(&live_report_for_today(25)), 2);
        assert!(!migration.live);
        assert_eq!(std::fs::read(&path).unwrap(), malformed);

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn future_version_is_not_published_or_overwritten() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config("future-version");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));
        let path = history_path().unwrap();
        let mut future = valid_document_for_today();
        future.version = 2;
        let original = serde_json::to_vec_pretty(&future).unwrap();
        std::fs::write(&path, &original).unwrap();

        assert!(read_path_for_mutation(&path, Local::now().timestamp_millis()).is_err());
        let report = apply_and_report("kiro", Some(&live_report_for_today(25)));
        assert!(!report.live);
        assert!(!report.included);
        assert_eq!(std::fs::read(&path).unwrap(), original);

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn future_day_is_not_published_or_overwritten() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config("future-day");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));
        let path = history_path().unwrap();
        let mut future = valid_document_for_today();
        let days = future.sources.get_mut("codex").unwrap();
        let value = days.values().next().unwrap().clone();
        days.clear();
        days.insert("9999-12-31".to_string(), value);
        let original = serde_json::to_vec_pretty(&future).unwrap();
        std::fs::write(&path, &original).unwrap();

        assert!(read_path_for_mutation(&path, Local::now().timestamp_millis()).is_err());
        let report = apply_and_report("kiro", Some(&live_report_for_today(25)));
        assert!(!report.live);
        assert!(!report.included);
        assert_eq!(std::fs::read(&path).unwrap(), original);

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn oversized_sparse_history_is_not_read_or_overwritten() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config("oversized-sparse");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));
        let path = history_path().unwrap();
        let file = std::fs::File::create(&path).unwrap();
        file.set_len((MAX_HISTORY_BYTES + 1) as u64).unwrap();
        drop(file);

        assert!(read_path_for_mutation(&path, Local::now().timestamp_millis()).is_err());
        let report = apply_and_report("kiro", Some(&live_report_for_today(25)));
        assert!(!report.live);
        assert!(!report.included);
        assert_eq!(
            std::fs::metadata(&path).unwrap().len(),
            (MAX_HISTORY_BYTES + 1) as u64
        );

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn oversized_persisted_cardinality_is_not_published_or_overwritten() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config("oversized-cardinality");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));
        let path = history_path().unwrap();
        let today = Local::now().date_naive();
        let days = (0..=RETAIN_DAYS)
            .map(|offset| {
                (
                    (today - chrono::Duration::days(offset)).to_string(),
                    HistoryDay {
                        usd: 0.0,
                        tokens: 1,
                        models: vec![],
                    },
                )
            })
            .collect();
        let oversized = Document {
            version: 1,
            sources: HashMap::from([("codex".to_string(), days)]),
            ..Default::default()
        };
        let original = serde_json::to_vec_pretty(&oversized).unwrap();
        std::fs::write(&path, &original).unwrap();

        assert!(read_path_for_mutation(&path, Local::now().timestamp_millis()).is_err());
        let report = apply_and_report("kiro", Some(&live_report_for_today(25)));
        assert!(!report.live);
        assert!(!report.included);
        assert_eq!(std::fs::read(&path).unwrap(), original);

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn semantic_poison_is_not_published_or_overwritten() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config("semantic-poison");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));
        let path = history_path().unwrap();
        let today = Local::now().date_naive().to_string();
        let poisoned = serde_json::json!({
            "version": 1,
            "sources": {
                "claude": {
                    today.clone(): { "usd": -1.0, "tokens": 50, "models": [] }
                },
                "codex": {
                    today.clone(): { "usd": 1.0, "tokens": 100, "models": [] }
                }
            },
            "scanned_at": { "codex": 1 },
            "counting_revision": { "grok": 3 }
        });
        let original = serde_json::to_vec_pretty(&poisoned).unwrap();
        std::fs::write(&path, &original).unwrap();

        let report = apply_and_report("codex", Some(&live_report_for_today(500)));

        assert!(!report.live, "semantic poison must fail the whole mutation");
        assert!(
            !report.included,
            "invalid persisted data must not be published"
        );
        assert!(report
            .daily
            .iter()
            .all(|day| day.tokens == 0 && day.usd == 0.0));
        assert_eq!(std::fs::read(&path).unwrap(), original);
        set_counting_revision("grok", 9);
        assert_eq!(std::fs::read(&path).unwrap(), original);

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn metadata_accepts_legacy_camel_case_and_serializes_shared_snake_case() {
        let legacy = serde_json::json!({
            "version": 1,
            "sources": {},
            "scannedAt": { "kiro": 1 },
            "countingRevision": { "kiro": 2 },
            "topModels": { "kiro": "real-model" }
        });
        let document: Document = serde_json::from_value(legacy).unwrap();
        assert_eq!(document.scanned_at.get("kiro"), Some(&1));
        assert_eq!(document.counting_revision.get("kiro"), Some(&2));
        assert_eq!(
            document.top_models.get("kiro").map(String::as_str),
            Some("real-model")
        );

        let canonical = serde_json::to_value(document).unwrap();
        assert!(canonical.get("scanned_at").is_some());
        assert!(canonical.get("counting_revision").is_some());
        assert!(canonical.get("top_models").is_some());
        assert!(canonical.get("scannedAt").is_none());
        assert!(canonical.get("countingRevision").is_none());
        assert!(canonical.get("topModels").is_none());

        let conflicting = serde_json::json!({
            "version": 1,
            "sources": {},
            "scanned_at": { "kiro": 1 },
            "scannedAt": { "kiro": 2 }
        });
        assert!(serde_json::from_value::<Document>(conflicting).is_err());
    }

    #[test]
    fn fractional_macos_timestamp_migrates_to_shared_integer_schema() {
        let macos = serde_json::json!({
            "version": 1,
            "sources": {},
            "scanned_at": { "kiro": 1787651040100.229_f64 }
        });
        let document: Document = serde_json::from_value(macos).unwrap();
        assert_eq!(document.scanned_at.get("kiro"), Some(&1_787_651_040_100));

        let canonical = serde_json::to_string(&document).unwrap();
        assert!(canonical.contains("1787651040100"));
        assert!(!canonical.contains("1787651040100.229"));
        let round_trip: Document = serde_json::from_str(&canonical).unwrap();
        assert_eq!(round_trip.scanned_at, document.scanned_at);
    }

    #[test]
    fn macos_non_gregorian_user_calendar_fixture_uses_shared_gregorian_day_key() {
        let document: Document = serde_json::from_value(serde_json::json!({
            "version": 1,
            "sources": {
                "kiro": {
                    "2026-08-25": {
                        "usd": 1.0,
                        "tokens": 10,
                        "models": [{ "name": "kiro-model", "usd": 1.0, "tokens": 10 }]
                    }
                }
            }
        }))
        .unwrap();
        let now_ms = Local
            .with_ymd_and_hms(2026, 8, 25, 12, 0, 0)
            .single()
            .unwrap()
            .timestamp_millis();

        assert!(validate_document(&document, now_ms));
        assert!(document.sources["kiro"].contains_key("2026-08-25"));
        assert!(!document.sources["kiro"].contains_key("2569-08-25"));
        assert!(!document.sources["kiro"].contains_key("1448-03-11"));
    }

    #[test]
    fn invalid_live_values_do_not_replace_persisted_history() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config("invalid-live");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));
        let path = history_path().unwrap();
        assert!(apply_and_report("claude", Some(&live_report_for_today(50))).live);
        let seeded = apply_and_report("codex", Some(&live_report_for_today(100)));
        assert!(seeded.live);
        let other_source = read().sources["claude"].clone();
        let original = std::fs::read(&path).unwrap();

        let mut negative = live_report_for_today(900);
        negative.daily[0].usd = -1.0;
        let mut nan_like = live_report_for_today(900);
        nan_like.daily[0].usd = f64::NAN;
        let mut bad_model = live_report_for_today(900);
        bad_model.daily[0].models.push(DailyModel {
            name: "bad\nmodel".to_string(),
            usd: 1.0,
            tokens: 1,
        });
        let mut bad_day = live_report_for_today(900);
        bad_day.daily[0].date = "2026-8-1".to_string();
        let mut future_day = live_report_for_today(900);
        future_day.daily[0].date = "9999-12-31".to_string();

        for invalid in [negative, nan_like, bad_model, bad_day, future_day] {
            let report = apply_and_report_replacing("codex", Some(&invalid));
            assert!(!report.live);
            assert!(report.included);
            assert_eq!(report.today_tokens, 100);
            assert_eq!(report.today_usd, 0.01);
            assert_eq!(std::fs::read(&path).unwrap(), original);
            assert_eq!(read().sources["claude"].len(), other_source.len());
            assert_eq!(read().sources["claude"].values().next().unwrap().tokens, 50);
        }

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn counting_revision_migration_replaces_and_preserves_other_sources() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config("counting-revision-success");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));
        assert!(apply_and_report("kiro", Some(&live_report_for_today(999))).live);
        assert!(apply_and_report("claude", Some(&live_report_for_today(50))).live);

        let migrated =
            apply_and_report_at_counting_revision("kiro", Some(&live_report_for_today(25)), 2);

        assert!(migrated.live);
        assert_eq!(migrated.today_tokens, 25);
        let document = read();
        assert_eq!(document.counting_revision["kiro"], 2);
        assert_eq!(stored_today_tokens(&document, "kiro"), 25);
        assert_eq!(stored_today_tokens(&document, "claude"), 50);

        let high_water =
            apply_and_report_at_counting_revision("kiro", Some(&live_report_for_today(10)), 2);
        assert!(high_water.live);
        assert_eq!(high_water.today_tokens, 25);
        assert_eq!(stored_today_tokens(&read(), "claude"), 50);

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn future_counting_revision_is_history_only_and_never_downgraded() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config("counting-revision-future");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));
        let path = history_path().unwrap();
        let seeded =
            apply_and_report_at_counting_revision("kiro", Some(&live_report_for_today(999)), 3);
        assert!(seeded.live);
        let original = std::fs::read(&path).unwrap();

        let report =
            apply_and_report_at_counting_revision("kiro", Some(&live_report_for_today(25)), 2);

        assert!(!report.live, "a future stored revision must fail closed");
        assert!(
            report.included,
            "valid persisted history remains reportable"
        );
        assert_eq!(report.today_tokens, 999);
        let document = read();
        assert_eq!(document.counting_revision.get("kiro"), Some(&3));
        assert_eq!(stored_today_tokens(&document, "kiro"), 999);
        assert_eq!(std::fs::read(&path).unwrap(), original);

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn counting_revision_migration_waits_for_valid_live_data() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config("counting-revision-deferred");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));
        let path = history_path().unwrap();
        assert!(apply_and_report("kiro", Some(&live_report_for_today(999))).live);
        let original = std::fs::read(&path).unwrap();

        let history_only = apply_and_report_at_counting_revision("kiro", None, 2);
        assert!(!history_only.live);
        assert_eq!(history_only.today_tokens, 999);
        assert_eq!(read().counting_revision.get("kiro"), None);
        assert_eq!(std::fs::read(&path).unwrap(), original);

        let mut invalid = live_report_for_today(25);
        invalid.daily[0].usd = -1.0;
        let rejected = apply_and_report_at_counting_revision("kiro", Some(&invalid), 2);
        assert!(!rejected.live);
        assert_eq!(rejected.today_tokens, 999);
        assert_eq!(read().counting_revision.get("kiro"), None);
        assert_eq!(std::fs::read(&path).unwrap(), original);

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn counting_revision_is_not_stamped_when_persist_fails() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config("counting-revision-write-failure");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));
        let path = history_path().unwrap();
        assert!(apply_and_report("kiro", Some(&live_report_for_today(999))).live);
        assert!(apply_and_report("claude", Some(&live_report_for_today(50))).live);
        let original = std::fs::read(&path).unwrap();

        let report = apply_and_report_with_writer(
            "kiro",
            Some(&live_report_for_today(25)),
            false,
            Some(2),
            |_| Err("injected persist failure".to_string()),
        );

        assert!(!report.live);
        assert_eq!(report.today_tokens, 999);
        let document = read();
        assert_eq!(document.counting_revision.get("kiro"), None);
        assert_eq!(stored_today_tokens(&document, "kiro"), 999);
        assert_eq!(stored_today_tokens(&document, "claude"), 50);
        assert_eq!(std::fs::read(&path).unwrap(), original);

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn semantic_validator_rejects_each_persisted_poison_class() {
        let now_ms = Local::now().timestamp_millis();
        let valid = valid_document_for_today();
        assert!(validate_document(&valid, now_ms));

        let mut legacy = valid.clone();
        legacy.version = 0;
        assert!(validate_document(&legacy, now_ms));

        let mut future_version = valid.clone();
        future_version.version = 2;
        assert!(!validate_document(&future_version, now_ms));

        let mut nine_real_models = valid.clone();
        nine_real_models
            .sources
            .get_mut("codex")
            .unwrap()
            .values_mut()
            .next()
            .unwrap()
            .models = (0..9)
            .map(|index| HistoryModel {
                name: format!("model-{index}"),
                usd: 0.0,
                tokens: 1,
            })
            .collect();
        assert!(validate_document(&nine_real_models, now_ms));

        let mut too_many_models = valid.clone();
        too_many_models
            .sources
            .get_mut("codex")
            .unwrap()
            .values_mut()
            .next()
            .unwrap()
            .models = (0..=MAX_MODELS_PER_DAY)
            .map(|index| HistoryModel {
                name: format!("model-{index}"),
                usd: 0.0,
                tokens: 0,
            })
            .collect();
        assert!(!validate_document(&too_many_models, now_ms));

        let mut unknown_source = valid.clone();
        unknown_source
            .sources
            .insert("unknown".to_string(), HashMap::new());
        assert!(!validate_document(&unknown_source, now_ms));

        let mut oversized_top_models = valid.clone();
        for source in ["claude", "grok", "kiro", "omp", "pi", "unknown"] {
            oversized_top_models
                .top_models
                .insert(source.to_string(), "model".to_string());
        }
        assert!(!validate_document(&oversized_top_models, now_ms));

        let mut invalid_day = valid.clone();
        let day = invalid_day.sources.get_mut("codex").unwrap();
        let value = day.values_mut().next().unwrap();
        value.tokens = -1;
        assert!(!validate_document(&invalid_day, now_ms));

        let mut invalid_usd = valid.clone();
        invalid_usd
            .sources
            .get_mut("codex")
            .unwrap()
            .values_mut()
            .next()
            .unwrap()
            .usd = f64::NAN;
        assert!(!validate_document(&invalid_usd, now_ms));

        let mut invalid_model = valid.clone();
        invalid_model
            .sources
            .get_mut("codex")
            .unwrap()
            .values_mut()
            .next()
            .unwrap()
            .models[0]
            .name = " \u{0000}".to_string();
        assert!(!validate_document(&invalid_model, now_ms));

        let mut empty_model = valid.clone();
        empty_model
            .sources
            .get_mut("codex")
            .unwrap()
            .values_mut()
            .next()
            .unwrap()
            .models[0]
            .name = "   ".to_string();
        assert!(!validate_document(&empty_model, now_ms));

        let mut oversized_model = valid.clone();
        oversized_model
            .sources
            .get_mut("codex")
            .unwrap()
            .values_mut()
            .next()
            .unwrap()
            .models[0]
            .name = "x".repeat(MODEL_NAME_MAX_CHARS + 1);
        assert!(!validate_document(&oversized_model, now_ms));

        let mut trailing_control_model = valid.clone();
        trailing_control_model
            .sources
            .get_mut("codex")
            .unwrap()
            .values_mut()
            .next()
            .unwrap()
            .models[0]
            .name = "model\n".to_string();
        assert!(!validate_document(&trailing_control_model, now_ms));

        let mut oversized_decomposed_model = valid.clone();
        oversized_decomposed_model
            .sources
            .get_mut("codex")
            .unwrap()
            .values_mut()
            .next()
            .unwrap()
            .models[0]
            .name = "e\u{0301}".repeat(MODEL_NAME_MAX_CHARS);
        assert!(!validate_document(&oversized_decomposed_model, now_ms));

        let mut invalid_model_amount = valid.clone();
        invalid_model_amount
            .sources
            .get_mut("codex")
            .unwrap()
            .values_mut()
            .next()
            .unwrap()
            .models[0]
            .tokens = -1;
        assert!(!validate_document(&invalid_model_amount, now_ms));

        let mut invalid_model_usd = valid.clone();
        invalid_model_usd
            .sources
            .get_mut("codex")
            .unwrap()
            .values_mut()
            .next()
            .unwrap()
            .models[0]
            .usd = f64::NAN;
        assert!(!validate_document(&invalid_model_usd, now_ms));

        let mut invalid_key = valid.clone();
        let day = invalid_key.sources.get_mut("codex").unwrap();
        let value = day.values().next().unwrap().clone();
        day.clear();
        day.insert("2026-8-1".to_string(), value);
        assert!(!validate_document(&invalid_key, now_ms));

        let mut future_day = valid.clone();
        let day = future_day.sources.get_mut("codex").unwrap();
        let value = day.values().next().unwrap().clone();
        day.clear();
        day.insert("9999-12-31".to_string(), value);
        assert!(!validate_document(&future_day, now_ms));

        let mut invalid_scan = valid.clone();
        invalid_scan.scanned_at.insert(
            "codex".to_string(),
            now_ms.saturating_add(MAX_SCANNED_AT_FUTURE_MS + 1),
        );
        assert!(!validate_document(&invalid_scan, now_ms));

        let mut negative_scan = valid.clone();
        negative_scan.scanned_at.insert("codex".to_string(), -1);
        assert!(!validate_document(&negative_scan, now_ms));
    }

    #[test]
    fn usage_report_default_confidence_fields() {
        let report = UsageReport::default();
        assert!(!report.included);
        assert!(!report.live);
        assert_eq!(report.scanned_at, None);
    }
}
