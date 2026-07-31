//! xAI Platform billing provider — Management API prepaid balance and usage.
//!
//! Separate from `grok`, which reads consumer subscription credits. xAI uses a
//! management API key and team ID from environment or shared settings.json.

use chrono::{DateTime, Duration, Utc};
use reqwest::{RequestBuilder, Url};
use serde::Serialize;
use serde_json::Value;

use crate::config;
use crate::providers::{display_name, shared_client, ProviderStatus, QuotaWindow};

const BASE_URL: &str = "https://management-api.x.ai/v1/billing/teams/";
const HISTORY_DAYS: i64 = 30;

#[derive(Clone, Debug, PartialEq)]
pub struct DailySpend {
    pub date: String,
    pub usd: f64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct UsageData {
    pub daily: Vec<DailySpend>,
    pub total_usd: f64,
    pub limit_reached: bool,
}

#[derive(Serialize)]
struct UsageRequest<'a> {
    start_date: &'a str,
    end_date: &'a str,
    aggregation: &'a str,
    currency: &'a str,
}

pub async fn fetch(cfg: &config::Provider) -> ProviderStatus {
    let name = display_name(cfg);
    let Some(api_key) = resolve_api_key(cfg) else {
        return ProviderStatus::failure(
            &cfg.id,
            &name,
            "xAI Management API key is not configured. Set XAI_MANAGEMENT_API_KEY or add an API key in Settings.",
        );
    };
    let Some(team_id) = resolve_team_id(cfg) else {
        return ProviderStatus::failure(
            &cfg.id,
            &name,
            "xAI team ID is not configured. Set XAI_TEAM_ID or enter it in Settings.",
        );
    };
    if !valid_team_id(&team_id) {
        return ProviderStatus::failure(
            &cfg.id,
            &name,
            "xAI team ID is invalid. Check XAI_TEAM_ID or the Team ID in Settings.",
        );
    }

    let client = shared_client();
    let now = Utc::now();
    let balance_url = match endpoint(&team_id, "prepaid/balance") {
        Ok(url) => url,
        Err(message) => return ProviderStatus::failure(&cfg.id, &name, message),
    };
    let balance_request = client
        .get(balance_url)
        .bearer_auth(&api_key)
        .header("Accept", "application/json");
    let balance_body = match send_json(balance_request).await {
        Ok(body) => body,
        Err(message) => return ProviderStatus::failure(&cfg.id, &name, message),
    };
    let balance_usd = match parse_balance(&balance_body) {
        Ok(value) => value,
        Err(message) => return ProviderStatus::failure(&cfg.id, &name, message),
    };

    let usage_url = match endpoint(&team_id, "usage") {
        Ok(url) => url,
        Err(message) => return ProviderStatus::failure(&cfg.id, &name, message),
    };
    let usage_body = match usage_body(now) {
        Ok(body) => body,
        Err(message) => return ProviderStatus::failure(&cfg.id, &name, message),
    };
    let usage_request = client
        .post(usage_url)
        .bearer_auth(&api_key)
        .header("Accept", "application/json")
        .header("Content-Type", "application/json")
        .json(&usage_body);
    let usage_body = match send_json(usage_request).await {
        Ok(body) => body,
        Err(message) => return ProviderStatus::failure(&cfg.id, &name, message),
    };
    let usage = match parse_usage(&usage_body) {
        Ok(value) => value,
        Err(message) => return ProviderStatus::failure(&cfg.id, &name, message),
    };

    status_from_values(cfg, &name, &team_id, balance_usd, &usage)
}

fn resolve_api_key(cfg: &config::Provider) -> Option<String> {
    config::api_key(cfg)
}

fn resolve_team_id(cfg: &config::Provider) -> Option<String> {
    std::env::var("XAI_TEAM_ID")
        .ok()
        .and_then(|value| clean(&value))
        .or_else(|| cfg.region.as_deref().and_then(clean))
}

fn clean(value: &str) -> Option<String> {
    let mut value = value.trim().to_string();
    if value.len() >= 2
        && ((value.starts_with('"') && value.ends_with('"'))
            || (value.starts_with('\'') && value.ends_with('\'')))
    {
        value = value[1..value.len() - 1].to_string();
    }
    let value = value.trim();
    (!value.is_empty()).then(|| value.to_string())
}

/// Team IDs are path components. Reject separators, URL delimiters, and
/// control/whitespace characters before constructing the endpoint.
pub fn valid_team_id(value: &str) -> bool {
    let value = value.trim();
    !value.is_empty()
        && value != "."
        && value != ".."
        && !value.chars().any(|c| {
            c.is_ascii_control() || c.is_whitespace() || matches!(c, '/' | '\\' | '?' | '#' | '%')
        })
}

fn endpoint(team_id: &str, suffix: &str) -> Result<Url, String> {
    if !valid_team_id(team_id) {
        return Err("xAI team ID is invalid. Check the Team ID in Settings.".to_string());
    }
    let mut url =
        Url::parse(BASE_URL).map_err(|_| "xAI billing endpoint is invalid.".to_string())?;
    {
        let mut segments = url
            .path_segments_mut()
            .map_err(|_| "xAI billing endpoint is invalid.".to_string())?;
        segments.push(team_id);
        for segment in suffix.split('/') {
            segments.push(segment);
        }
    }
    Ok(url)
}

fn usage_body(now: DateTime<Utc>) -> Result<Value, String> {
    let end = now.date_naive();
    let start = end
        .checked_sub_signed(Duration::days(HISTORY_DAYS - 1))
        .ok_or_else(|| "xAI usage date range is invalid.".to_string())?;
    let start_date = start.format("%Y-%m-%d").to_string();
    let end_date = end.format("%Y-%m-%d").to_string();
    let request = UsageRequest {
        start_date: &start_date,
        end_date: &end_date,
        aggregation: "day",
        currency: "USD",
    };
    serde_json::to_value(request).map_err(|_| "xAI usage request is invalid.".to_string())
}

fn http_error(status: u16) -> String {
    match status {
        401 | 403 => format!("xAI Management API key rejected (HTTP {status}). Check the API key."),
        404 => "xAI team not found (HTTP 404). Check the Team ID.".to_string(),
        429 => "xAI billing rate limited (HTTP 429). Try again later.".to_string(),
        _ => format!("xAI billing returned HTTP {status}."),
    }
}

async fn send_json(request: RequestBuilder) -> Result<Value, String> {
    let response = match request.send().await {
        Ok(response) => response,
        Err(error) => return Err(format!("xAI billing network error: {error}")),
    };
    let status = response.status().as_u16();
    if !(200..300).contains(&status) {
        return Err(http_error(status));
    }
    match response.json::<Value>().await {
        Ok(body) => Ok(body),
        Err(_) => Err("xAI billing returned invalid JSON response.".to_string()),
    }
}

/// Parse required `{ "total": "-1000" }`, plus the Swift API's
/// `{ "total": { "val": "-1000" } }` envelope.
pub fn parse_balance(body: &Value) -> Result<f64, String> {
    let total = body
        .get("total")
        .and_then(Value::as_str)
        .or_else(|| body.pointer("/total/val").and_then(Value::as_str))
        .ok_or_else(|| "xAI billing returned invalid balance response.".to_string())?;
    let cents = total
        .parse::<f64>()
        .ok()
        .filter(|value| value.is_finite())
        .ok_or_else(|| "xAI billing returned invalid balance response.".to_string())?;
    let remaining = -cents / 100.0;
    remaining
        .is_finite()
        .then_some(remaining)
        .ok_or_else(|| "xAI billing returned invalid balance response.".to_string())
}

/// Parse required `{ "data": [{"date": ..., "cost_cents": ...}], ... }`.
/// Also accepts Swift's `timeSeries.dataPoints` response, whose values are USD.
pub fn parse_usage(body: &Value) -> Result<UsageData, String> {
    if let Some(data) = body.get("data") {
        let entries = data
            .as_array()
            .ok_or_else(|| "xAI billing returned invalid usage response.".to_string())?;
        let mut daily = Vec::with_capacity(entries.len());
        let mut total_usd = 0.0;
        for entry in entries {
            let date = entry
                .get("date")
                .and_then(Value::as_str)
                .filter(|date| !date.trim().is_empty())
                .ok_or_else(|| "xAI billing returned invalid usage response.".to_string())?;
            let cents = entry
                .get("cost_cents")
                .and_then(Value::as_i64)
                .ok_or_else(|| "xAI billing returned invalid usage response.".to_string())?;
            let usd = cents as f64 / 100.0;
            total_usd += usd;
            if !total_usd.is_finite() {
                return Err("xAI billing returned invalid usage response.".to_string());
            }
            daily.push(DailySpend {
                date: date.to_string(),
                usd,
            });
        }
        return Ok(UsageData {
            daily,
            total_usd,
            limit_reached: body
                .get("limitReached")
                .and_then(Value::as_bool)
                .unwrap_or(false),
        });
    }

    parse_swift_usage(body)
}

fn parse_swift_usage(body: &Value) -> Result<UsageData, String> {
    let series = body
        .get("timeSeries")
        .and_then(Value::as_array)
        .ok_or_else(|| "xAI billing returned invalid usage response.".to_string())?;
    let mut daily = Vec::new();
    let mut total_usd = 0.0;
    for item in series {
        let points = item
            .get("dataPoints")
            .and_then(Value::as_array)
            .ok_or_else(|| "xAI billing returned invalid usage response.".to_string())?;
        for point in points {
            let timestamp = point
                .get("timestamp")
                .and_then(Value::as_str)
                .ok_or_else(|| "xAI billing returned invalid usage response.".to_string())?;
            let date = timestamp
                .get(..10)
                .filter(|date| {
                    date.as_bytes().get(4) == Some(&b'-') && date.as_bytes().get(7) == Some(&b'-')
                })
                .ok_or_else(|| "xAI billing returned invalid usage response.".to_string())?;
            let usd = point
                .get("values")
                .and_then(Value::as_array)
                .and_then(|values| values.first())
                .and_then(Value::as_f64)
                .filter(|value| value.is_finite())
                .ok_or_else(|| "xAI billing returned invalid usage response.".to_string())?;
            total_usd += usd;
            if !total_usd.is_finite() {
                return Err("xAI billing returned invalid usage response.".to_string());
            }
            daily.push(DailySpend {
                date: date.to_string(),
                usd,
            });
        }
    }
    Ok(UsageData {
        daily,
        total_usd,
        limit_reached: body
            .get("limitReached")
            .and_then(Value::as_bool)
            .unwrap_or(false),
    })
}

fn status_from_values(
    cfg: &config::Provider,
    name: &str,
    team_id: &str,
    balance_usd: f64,
    usage: &UsageData,
) -> ProviderStatus {
    let spend_label = "30-day spend";
    ProviderStatus {
        id: cfg.id.clone(),
        display_name: name.to_string(),
        windows: vec![
            QuotaWindow {
                semantic_key: None,
                semantic_kind: None,
                label: "Balance".to_string(),
                used_pct: 0,
                remaining_pct: 100,
                subtitle: Some(format!("${balance_usd:.2} USD")),
                resets_at: None,
                window_seconds: None,
            },
            QuotaWindow {
                semantic_key: None,
                semantic_kind: None,
                label: spend_label.to_string(),
                used_pct: 0,
                remaining_pct: 100,
                subtitle: Some(format!("${:.2}", usage.total_usd)),
                resets_at: None,
                window_seconds: None,
            },
        ],
        last_updated: Utc::now().timestamp(),
        account_label: Some(
            cfg.account_label
                .as_deref()
                .and_then(clean)
                .unwrap_or_else(|| team_id.to_string()),
        ),
        credits_remaining: Some(balance_usd),
        plan_name: Some("xAI Platform".to_string()),
        source_label: Some("xai-api".to_string()),
        menu_bar_metric: cfg.menu_bar_metric.clone(),
        ..Default::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parses_flat_balance_and_inverts_cents() {
        assert!((parse_balance(&json!({"total": "-1000"})).unwrap() - 10.0).abs() < 0.001);
    }

    #[test]
    fn parses_swift_balance_envelope() {
        assert!((parse_balance(&json!({"total": {"val": "-250"}})).unwrap() - 2.5).abs() < 0.001);
    }

    #[test]
    fn parses_usage_and_sums_cents() {
        let usage = parse_usage(&json!({
            "data": [
                {"date": "2026-07-01", "cost_cents": 125},
                {"date": "2026-07-02", "cost_cents": 75}
            ],
            "limitReached": true
        }))
        .unwrap();
        assert_eq!(usage.daily.len(), 2);
        assert!((usage.total_usd - 2.0).abs() < 0.001);
        assert!(usage.limit_reached);
    }

    #[test]
    fn usage_request_has_required_shape_and_utc_dates() {
        let now = DateTime::parse_from_rfc3339("2026-07-30T23:30:00-05:00")
            .unwrap()
            .with_timezone(&Utc);
        let body = usage_body(now).unwrap();
        assert_eq!(body["start_date"], "2026-07-02");
        assert_eq!(body["end_date"], "2026-07-31");
        assert_eq!(body["aggregation"], "day");
        assert_eq!(body["currency"], "USD");
        assert_eq!(body.as_object().unwrap().len(), 4);
    }

    #[test]
    fn rejects_invalid_payloads_without_secrets() {
        let error = parse_balance(&json!({"total": "not-cents"})).unwrap_err();
        assert!(error.contains("invalid balance"));
        assert!(!error.contains("not-cents"));
        assert!(parse_usage(&json!({"data": [{"date": "2026-07-01"}]})).is_err());
    }

    #[test]
    fn validates_team_path_component() {
        assert!(valid_team_id("team_abc123"));
        assert!(!valid_team_id("team/abc"));
        assert!(!valid_team_id("team?x=secret"));
    }

    #[test]
    fn maps_http_auth_errors_to_token_classification() {
        let error = http_error(401);
        assert!(error.contains("API key"));
        assert_eq!(
            crate::providers::error_classifier::classify(Some(&error)),
            Some(crate::providers::error_classifier::ProviderErrorKind::TokenInvalidOrMissing)
        );
        assert_eq!(
            http_error(403),
            "xAI Management API key rejected (HTTP 403). Check the API key."
        );
    }

    #[test]
    fn maps_missing_team_without_exposing_credentials() {
        let error = http_error(404);
        assert_eq!(error, "xAI team not found (HTTP 404). Check the Team ID.");
        assert!(!error.contains("secret"));
    }

    #[test]
    fn maps_balance_spend_and_metadata() {
        let cfg = config::Provider {
            id: "xai".into(),
            account_label: Some("Platform".into()),
            menu_bar_metric: Some("primary".into()),
            ..Default::default()
        };
        let usage = UsageData {
            daily: vec![],
            total_usd: 3.25,
            limit_reached: false,
        };
        let status = status_from_values(&cfg, "xAI", "team_123", 10.0, &usage);
        assert_eq!(status.id, "xai");
        assert_eq!(status.windows.len(), 2);
        assert_eq!(status.windows[0].label, "Balance");
        assert_eq!(status.windows[1].label, "30-day spend");
        assert_eq!(status.windows[1].subtitle.as_deref(), Some("$3.25"));
        assert_eq!(status.credits_remaining, Some(10.0));
        assert_eq!(status.source_label.as_deref(), Some("xai-api"));
    }
}
