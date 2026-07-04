//! Shared usage-report shapes serialized to the web UI. Mirrors the macOS
//! app's `ClaudeUsageReport`/`CodexUsageReport` so both platforms speak the
//! same numbers (daily 90-day window, strict 30-day totals, 24 hour buckets).

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
    /// Per-model split for the day, highest token count first (top 5).
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
    /// 90 daily buckets, oldest → newest, one entry per calendar day.
    pub daily: Vec<DailyUsage>,
    /// 24 hour buckets for the trailing 24 h, oldest → newest.
    pub hourly: Vec<HourlyUsage>,
    /// Most-used model (by tokens) across the trailing 30 days.
    pub top_model: Option<String>,
}
