//! Shared usage-report shapes serialized to the web UI. Mirrors the macOS
//! app's `ClaudeUsageReport`/`CodexUsageReport` so both platforms speak the
//! same numbers (daily 120-day window, strict 30-day totals, 24 hour buckets).

use serde::Serialize;

#[derive(Serialize, Clone, Debug, PartialEq)]
pub struct DailyModel {
    pub name: String,
    pub usd: f64,
    pub tokens: i64,
}

#[derive(Serialize, Clone, Debug, PartialEq)]
pub struct DailyUsage {
    /// Local calendar day, "YYYY-MM-DD".
    pub date: String,
    pub usd: f64,
    pub tokens: i64,
    /// Bounded per-model split: top 5, the monthly top when needed, then an
    /// aggregate `Other` bucket so the split still equals the daily total.
    pub models: Vec<DailyModel>,
}

#[derive(Serialize, Clone, Debug, PartialEq)]
pub struct HourlyUsage {
    /// Local clock hour, "YYYY-MM-DDTHH:00".
    pub hour: String,
    pub usd: f64,
    pub tokens: i64,
}

#[derive(Serialize, Clone, Debug, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct UsageReport {
    pub today_usd: f64,
    pub today_tokens: i64,
    /// Strict 30-day totals — independent of the wider daily window.
    pub last30_usd: f64,
    pub last30_tokens: i64,
    /// 120 daily buckets, oldest → newest, one entry per calendar day.
    pub daily: Vec<DailyUsage>,
    /// 24 hour buckets for the trailing 24 h, oldest → newest.
    pub hourly: Vec<HourlyUsage>,
    /// Most-used model (by tokens) across the trailing 30 days.
    pub top_model: Option<String>,
    /// Data Confidence Pass metadata (all three fields below): `true` once
    /// this source has ever produced evidence — a live scan found a
    /// readable root, or cost-history already holds a day for it — `false`
    /// means the source has no data on this machine at all.
    pub included: bool,
    /// `true` when THIS refresh cycle re-scanned the source live and merged
    /// it into history; `false` means the numbers are a history-only
    /// carry-forward (the live scan found nothing readable this cycle).
    pub live: bool,
    /// Epoch millis of the most recent successful live scan for this
    /// source, persisted so a history-only cycle can still report when the
    /// data was last fresh. `None` when no live scan has ever succeeded.
    pub scanned_at: Option<i64>,
}
