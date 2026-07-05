//! Claude Admin API org dashboard — port of `ClaudeAdminAPIUsage.swift`.
//! Hits Anthropic's org-level Usage & Cost API with an Admin key (`x-api-key`)
//! and rolls the daily buckets into a 30-day org snapshot (cost + tokens +
//! per-model + per-cost-item breakdowns). Separate from the OAuth quota path
//! in `claude.rs` — surfaced as an extra card on the Claude tab when an
//! admin key is configured.
//!
//! Key resolution: `ANTHROPIC_ADMIN_KEY` / `ANTHROPIC_ADMIN_API_KEY` env vars,
//! then the Claude provider's `adminApiKey` config field (mirrors the Swift
//! Settings-UI-layered-on-env resolution, minus Keychain).

use serde::Serialize;
use serde_json::Value;

use crate::config;

const COST_REPORT_URL: &str = "https://api.anthropic.com/v1/organizations/cost_report";
const MESSAGES_USAGE_URL: &str = "https://api.anthropic.com/v1/organizations/usage_report/messages";
const ANTHROPIC_VERSION: &str = "2023-06-01";
const MAX_DAILY_BUCKETS: i64 = 31;

#[derive(Serialize, Clone, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub struct ModelBreakdown {
    pub name: String,
    pub input_tokens: i64,
    pub cache_creation_input_tokens: i64,
    pub cache_read_input_tokens: i64,
    pub output_tokens: i64,
    pub total_tokens: i64,
}

#[derive(Serialize, Clone, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub struct CostBreakdown {
    pub name: String,
    pub cost_usd: f64,
}

#[derive(Serialize, Clone, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub struct DailyBucket {
    pub day: String,
    pub start_time: i64,
    pub cost_usd: f64,
    pub input_tokens: i64,
    pub cache_creation_input_tokens: i64,
    pub cache_read_input_tokens: i64,
    pub output_tokens: i64,
    pub total_tokens: i64,
    pub cost_items: Vec<CostBreakdown>,
    pub models: Vec<ModelBreakdown>,
}

#[derive(Serialize, Clone, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub struct Summary {
    pub cost_usd: f64,
    pub input_tokens: i64,
    pub cache_creation_input_tokens: i64,
    pub cache_read_input_tokens: i64,
    pub output_tokens: i64,
    pub total_tokens: i64,
}

#[derive(Serialize, Clone, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeAdminSnapshot {
    pub daily: Vec<DailyBucket>,
    pub updated_at: i64,
    pub last30_days: Summary,
    pub last7_days: Summary,
    pub latest_day: Summary,
    pub top_models: Vec<ModelBreakdown>,
    pub top_cost_items: Vec<CostBreakdown>,
}

/// Admin key resolution: env vars first, then the provider config's
/// `adminApiKey` field (mirrors `ClaudeAdminAPISettingsReader.apiKey` + the
/// Settings-layer).
pub fn admin_api_key(cfg: &config::Provider) -> Option<String> {
    for key in ["ANTHROPIC_ADMIN_KEY", "ANTHROPIC_ADMIN_API_KEY"] {
        if let Ok(v) = std::env::var(key) {
            if let Some(cleaned) = clean_key(&v) {
                return Some(cleaned);
            }
        }
    }
    cfg.admin_api_key.as_deref().and_then(clean_key)
}

fn clean_key(raw: &str) -> Option<String> {
    let mut value = raw.trim().to_string();
    if value.is_empty() {
        return None;
    }
    if (value.starts_with('"') && value.ends_with('"') && value.len() >= 2)
        || (value.starts_with('\'') && value.ends_with('\'') && value.len() >= 2)
    {
        value = value[1..value.len() - 1].to_string();
    }
    let value = value.trim().to_string();
    if value.is_empty() {
        None
    } else {
        Some(value)
    }
}

/// Best-effort fetch. Returns None on any failure (missing key, network,
/// parse) — the caller must never let this break the primary OAuth status.
pub async fn fetch_snapshot(cfg: &config::Provider) -> Option<ClaudeAdminSnapshot> {
    let key = admin_api_key(cfg)?;
    let now = chrono::Utc::now();
    let (start, end) = daily_range(now.timestamp());

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(20))
        .build()
        .ok()?;

    let costs_url = build_url(COST_REPORT_URL, start, end, "description");
    let messages_url = build_url(MESSAGES_USAGE_URL, start, end, "model");

    let costs = fetch_json(&client, &costs_url, &key).await.ok()?;
    let messages = fetch_json(&client, &messages_url, &key).await.ok()?;

    Some(build_snapshot(&costs, &messages, now.timestamp()))
}

async fn fetch_json(client: &reqwest::Client, url: &str, key: &str) -> Result<Value, String> {
    let resp = client
        .get(url)
        .header("anthropic-version", ANTHROPIC_VERSION)
        .header("x-api-key", key)
        .header("Accept", "application/json")
        .header("User-Agent", "BirdNion/1.0")
        .send()
        .await
        .map_err(|e| format!("Network: {e}"))?;
    if resp.status().as_u16() != 200 {
        return Err(format!("HTTP {}", resp.status().as_u16()));
    }
    resp.json::<Value>().await.map_err(|e| format!("JSON: {e}"))
}

/// Pure: `starting_at`/`ending_at`/`bucket_width=1d`/`limit` query builder,
/// mirroring `ClaudeAdminAPIUsageFetcher.url`.
fn build_url(base: &str, start: i64, end: i64, group_by: &str) -> String {
    let start_s = chrono::DateTime::from_timestamp(start, 0).unwrap_or_default().to_rfc3339();
    let end_s = chrono::DateTime::from_timestamp(end, 0).unwrap_or_default().to_rfc3339();
    format!(
        "{base}?starting_at={start_s}&ending_at={end_s}&bucket_width=1d&limit={MAX_DAILY_BUCKETS}&group_by[]={group_by}"
    )
}

/// Pure: 31-day UTC range ending tomorrow (today inclusive), mirroring
/// `ClaudeAdminAPIUsageFetcher.dailyRange`.
fn daily_range(now: i64) -> (i64, i64) {
    const DAY: i64 = 86_400;
    let today_start = (now / DAY) * DAY;
    let start = today_start - (MAX_DAILY_BUCKETS - 1) * DAY;
    let end = today_start + DAY;
    (start, end)
}

#[derive(Default, Clone)]
struct ModelAccumulator {
    input_tokens: i64,
    cache_creation_input_tokens: i64,
    cache_read_input_tokens: i64,
    output_tokens: i64,
    total_tokens: i64,
}

impl ModelAccumulator {
    fn add(&mut self, input: i64, cache_creation: i64, cache_read: i64, output: i64, total: i64) {
        self.input_tokens += input;
        self.cache_creation_input_tokens += cache_creation;
        self.cache_read_input_tokens += cache_read;
        self.output_tokens += output;
        self.total_tokens += total;
    }

    fn to_model(&self, name: &str) -> ModelBreakdown {
        ModelBreakdown {
            name: name.to_string(),
            input_tokens: self.input_tokens,
            cache_creation_input_tokens: self.cache_creation_input_tokens,
            cache_read_input_tokens: self.cache_read_input_tokens,
            output_tokens: self.output_tokens,
            total_tokens: self.total_tokens,
        }
    }
}

#[derive(Default)]
struct DailyAccumulator {
    starting_at: String,
    cost_usd: f64,
    input_tokens: i64,
    cache_creation_input_tokens: i64,
    cache_read_input_tokens: i64,
    output_tokens: i64,
    total_tokens: i64,
    cost_items: std::collections::HashMap<String, f64>,
    models: std::collections::HashMap<String, ModelAccumulator>,
}

fn display_name_or(raw: Option<&str>, fallback: &str) -> String {
    let trimmed = raw.map(str::trim).unwrap_or("");
    if trimmed.is_empty() {
        fallback.to_string()
    } else {
        trimmed.to_string()
    }
}

/// Pure payload → snapshot mapping (unit-tested). Mirrors
/// `ClaudeAdminAPIUsageFetcher.makeSnapshot`: joins cost_report + messages
/// usage_report by `starting_at` day-bucket key.
fn build_snapshot(costs: &Value, messages: &Value, now: i64) -> ClaudeAdminSnapshot {
    let mut accumulators: std::collections::HashMap<String, DailyAccumulator> = std::collections::HashMap::new();

    if let Some(data) = costs.get("data").and_then(Value::as_array) {
        for bucket in data {
            let starting_at = bucket.get("starting_at").and_then(Value::as_str).unwrap_or("").to_string();
            if starting_at.is_empty() {
                continue;
            }
            let acc = accumulators.entry(starting_at.clone()).or_insert_with(|| DailyAccumulator {
                starting_at: starting_at.clone(),
                ..Default::default()
            });
            if let Some(results) = bucket.get("results").and_then(Value::as_array) {
                for result in results {
                    let amount_cents: f64 = result
                        .get("amount")
                        .and_then(Value::as_str)
                        .and_then(|s| s.parse::<f64>().ok())
                        .unwrap_or(0.0);
                    let value = amount_cents / 100.0;
                    acc.cost_usd += value;
                    let item = display_name_or(
                        result.get("description").and_then(Value::as_str).or_else(|| result.get("cost_type").and_then(Value::as_str)),
                        "Claude API",
                    );
                    *acc.cost_items.entry(item).or_insert(0.0) += value;
                }
            }
        }
    }

    if let Some(data) = messages.get("data").and_then(Value::as_array) {
        for bucket in data {
            let starting_at = bucket.get("starting_at").and_then(Value::as_str).unwrap_or("").to_string();
            if starting_at.is_empty() {
                continue;
            }
            let acc = accumulators.entry(starting_at.clone()).or_insert_with(|| DailyAccumulator {
                starting_at: starting_at.clone(),
                ..Default::default()
            });
            if let Some(results) = bucket.get("results").and_then(Value::as_array) {
                for result in results {
                    let input = result.get("uncached_input_tokens").and_then(Value::as_i64).unwrap_or(0);
                    let cache_creation = result
                        .get("cache_creation")
                        .map(|c| {
                            c.get("ephemeral_1h_input_tokens").and_then(Value::as_i64).unwrap_or(0)
                                + c.get("ephemeral_5m_input_tokens").and_then(Value::as_i64).unwrap_or(0)
                        })
                        .unwrap_or(0);
                    let cache_read = result.get("cache_read_input_tokens").and_then(Value::as_i64).unwrap_or(0);
                    let output = result.get("output_tokens").and_then(Value::as_i64).unwrap_or(0);
                    let total = input + cache_creation + cache_read + output;
                    acc.input_tokens += input;
                    acc.cache_creation_input_tokens += cache_creation;
                    acc.cache_read_input_tokens += cache_read;
                    acc.output_tokens += output;
                    acc.total_tokens += total;
                    let model_name = display_name_or(result.get("model").and_then(Value::as_str), "Claude API");
                    acc.models.entry(model_name).or_default().add(input, cache_creation, cache_read, output, total);
                }
            }
        }
    }

    let mut daily: Vec<DailyBucket> = accumulators
        .into_values()
        .filter_map(|acc| {
            let start = chrono::DateTime::parse_from_rfc3339(&acc.starting_at).ok()?.timestamp();
            if start > now {
                return None;
            }
            let day = chrono::DateTime::from_timestamp(start, 0)?.format("%Y-%m-%d").to_string();
            let mut cost_items: Vec<CostBreakdown> =
                acc.cost_items.into_iter().map(|(name, cost_usd)| CostBreakdown { name, cost_usd }).collect();
            cost_items.sort_by(|a, b| b.cost_usd.partial_cmp(&a.cost_usd).unwrap_or(std::cmp::Ordering::Equal).then_with(|| a.name.cmp(&b.name)));
            let mut models: Vec<ModelBreakdown> = acc.models.iter().map(|(name, m)| m.to_model(name)).collect();
            models.sort_by(|a, b| b.total_tokens.cmp(&a.total_tokens).then_with(|| a.name.cmp(&b.name)));
            Some(DailyBucket {
                day,
                start_time: start,
                cost_usd: acc.cost_usd,
                input_tokens: acc.input_tokens,
                cache_creation_input_tokens: acc.cache_creation_input_tokens,
                cache_read_input_tokens: acc.cache_read_input_tokens,
                output_tokens: acc.output_tokens,
                total_tokens: acc.total_tokens,
                cost_items,
                models,
            })
        })
        .collect();
    daily.sort_by_key(|d| d.start_time);

    make_snapshot(daily, now)
}

fn summarize(daily: &[DailyBucket], days: usize) -> Summary {
    let take = days.max(1);
    let selected = if daily.len() > take { &daily[daily.len() - take..] } else { daily };
    let mut s = Summary::default();
    for d in selected {
        s.cost_usd += d.cost_usd;
        s.input_tokens += d.input_tokens;
        s.cache_creation_input_tokens += d.cache_creation_input_tokens;
        s.cache_read_input_tokens += d.cache_read_input_tokens;
        s.output_tokens += d.output_tokens;
        s.total_tokens += d.total_tokens;
    }
    s
}

fn make_snapshot(daily: Vec<DailyBucket>, now: i64) -> ClaudeAdminSnapshot {
    let last30_days = summarize(&daily, 30);
    let last7_days = summarize(&daily, 7);
    let latest_day = summarize(&daily, 1);

    let mut model_totals: std::collections::HashMap<String, ModelAccumulator> = std::collections::HashMap::new();
    let mut cost_totals: std::collections::HashMap<String, f64> = std::collections::HashMap::new();
    for d in &daily {
        for m in &d.models {
            model_totals.entry(m.name.clone()).or_default().add(
                m.input_tokens,
                m.cache_creation_input_tokens,
                m.cache_read_input_tokens,
                m.output_tokens,
                m.total_tokens,
            );
        }
        for c in &d.cost_items {
            *cost_totals.entry(c.name.clone()).or_insert(0.0) += c.cost_usd;
        }
    }
    let mut top_models: Vec<ModelBreakdown> = model_totals.iter().map(|(name, m)| m.to_model(name)).collect();
    top_models.sort_by(|a, b| b.total_tokens.cmp(&a.total_tokens).then_with(|| a.name.cmp(&b.name)));
    let mut top_cost_items: Vec<CostBreakdown> =
        cost_totals.into_iter().map(|(name, cost_usd)| CostBreakdown { name, cost_usd }).collect();
    top_cost_items.sort_by(|a, b| b.cost_usd.partial_cmp(&a.cost_usd).unwrap_or(std::cmp::Ordering::Equal).then_with(|| a.name.cmp(&b.name)));

    ClaudeAdminSnapshot { daily, updated_at: now, last30_days, last7_days, latest_day, top_models, top_cost_items }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn cleans_quoted_and_whitespace_keys() {
        assert_eq!(clean_key("  \"sk-ant-admin-1\"  "), Some("sk-ant-admin-1".to_string()));
        assert_eq!(clean_key("'sk-2'"), Some("sk-2".to_string()));
        assert_eq!(clean_key(""), None);
        assert_eq!(clean_key("   "), None);
    }

    #[test]
    fn admin_api_key_prefers_provider_field_when_no_env() {
        let cfg = config::Provider { id: "claude".into(), admin_api_key: Some("sk-ant-admin-cfg".into()), ..Default::default() };
        assert_eq!(admin_api_key(&cfg), Some("sk-ant-admin-cfg".to_string()));
    }

    #[test]
    fn daily_range_spans_31_days_ending_tomorrow() {
        let now = chrono::DateTime::parse_from_rfc3339("2026-06-15T12:00:00Z").unwrap().timestamp();
        let (start, end) = daily_range(now);
        let start_day = chrono::DateTime::from_timestamp(start, 0).unwrap().format("%Y-%m-%d").to_string();
        let end_day = chrono::DateTime::from_timestamp(end, 0).unwrap().format("%Y-%m-%d").to_string();
        assert_eq!(start_day, "2026-05-16");
        assert_eq!(end_day, "2026-06-16");
    }

    #[test]
    fn builds_snapshot_joining_costs_and_messages_by_day() {
        let costs = json!({
            "data": [
                {"starting_at": "2026-06-01T00:00:00Z", "ending_at": "2026-06-02T00:00:00Z",
                 "results": [{"amount": "150", "description": "Claude Sonnet"}]}
            ]
        });
        let messages = json!({
            "data": [
                {"starting_at": "2026-06-01T00:00:00Z", "ending_at": "2026-06-02T00:00:00Z",
                 "results": [{"uncached_input_tokens": 100, "output_tokens": 50, "model": "claude-sonnet-4"}]}
            ]
        });
        let now = chrono::DateTime::parse_from_rfc3339("2026-06-15T00:00:00Z").unwrap().timestamp();
        let snap = build_snapshot(&costs, &messages, now);
        assert_eq!(snap.daily.len(), 1);
        assert_eq!(snap.daily[0].day, "2026-06-01");
        assert!((snap.daily[0].cost_usd - 1.5).abs() < 0.001);
        assert_eq!(snap.daily[0].total_tokens, 150);
        assert_eq!(snap.daily[0].models.len(), 1);
        assert_eq!(snap.daily[0].models[0].name, "claude-sonnet-4");
        assert_eq!(snap.top_models.len(), 1);
        assert_eq!(snap.top_cost_items.len(), 1);
        assert_eq!(snap.top_cost_items[0].name, "Claude Sonnet");
    }

    #[test]
    fn future_buckets_are_excluded() {
        let costs = json!({"data": []});
        let messages = json!({
            "data": [
                {"starting_at": "2099-01-01T00:00:00Z", "ending_at": "2099-01-02T00:00:00Z",
                 "results": [{"uncached_input_tokens": 5, "model": "x"}]}
            ]
        });
        let now = chrono::DateTime::parse_from_rfc3339("2026-06-15T00:00:00Z").unwrap().timestamp();
        let snap = build_snapshot(&costs, &messages, now);
        assert!(snap.daily.is_empty());
    }

    #[test]
    fn summaries_use_the_tail_window() {
        let mut daily = Vec::new();
        for i in 0..10 {
            daily.push(DailyBucket { day: format!("d{i}"), start_time: i, cost_usd: 1.0, total_tokens: 10, ..Default::default() });
        }
        let s7 = summarize(&daily, 7);
        assert!((s7.cost_usd - 7.0).abs() < 0.001);
        assert_eq!(s7.total_tokens, 70);
        let s1 = summarize(&daily, 1);
        assert!((s1.cost_usd - 1.0).abs() < 0.001);
    }

    #[test]
    fn missing_env_and_provider_key_returns_none() {
        std::env::remove_var("ANTHROPIC_ADMIN_KEY");
        std::env::remove_var("ANTHROPIC_ADMIN_API_KEY");
        let cfg = config::Provider { id: "claude".into(), ..Default::default() };
        assert_eq!(admin_api_key(&cfg), None);
    }
}
