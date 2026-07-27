//! TryAPI wallet/usage provider — port of `TryAPIProvider.swift`.
//!
//! `GET https://tryapi.tryai.chat/v1/usage` (Bearer key) →
//! wallet balance + usage totals. Primary window "Số dư" from used+remaining;
//! optional "Hôm nay" when today has traffic; optional Ngày/Tuần/Tháng when
//! `mode == "quota_limited"` and subscription limits are finite.

use serde_json::Value;

use crate::config;
use crate::providers::{display_name, shared_client, ProviderStatus, QuotaWindow};

const ENDPOINT: &str = "https://tryapi.tryai.chat/v1/usage";

pub async fn fetch(cfg: &config::Provider) -> ProviderStatus {
    let name = display_name(cfg);
    let Some(token) = config::api_key(cfg) else {
        return ProviderStatus::failure(&cfg.id, &name, "Chưa cấu hình token");
    };
    let account_label = cfg
        .account_label
        .clone()
        .unwrap_or_else(|| token.chars().take(8).collect());

    let client = shared_client();
    let resp = client
        .get(ENDPOINT)
        .bearer_auth(&token)
        .header("Accept", "application/json")
        .send()
        .await;
    let resp = match resp {
        Ok(r) => r,
        Err(e) => return ProviderStatus::failure(&cfg.id, &name, format!("Network: {e}")),
    };
    if !resp.status().is_success() {
        return ProviderStatus::failure(&cfg.id, &name, format!("HTTP {}", resp.status().as_u16()));
    }
    let body: Value = match resp.json().await {
        Ok(v) => v,
        Err(e) => return ProviderStatus::failure(&cfg.id, &name, format!("JSON: {e}")),
    };
    parse(&cfg.id, &name, &account_label, &body)
}

/// Pure payload → status mapping (unit-tested).
pub fn parse(id: &str, name: &str, account_label: &str, body: &Value) -> ProviderStatus {
    if body.get("isValid").and_then(Value::as_bool) == Some(false) {
        return ProviderStatus::failure(id, name, "API key không hợp lệ");
    }

    let total_usage = body.get("usage").and_then(|u| u.get("total"));
    let used = total_usage
        .and_then(|t| t.get("actual_cost").and_then(Value::as_f64))
        .or_else(|| total_usage.and_then(|t| t.get("cost").and_then(Value::as_f64)))
        .unwrap_or(0.0);
    let remaining = body
        .get("remaining")
        .and_then(Value::as_f64)
        .or_else(|| body.get("balance").and_then(Value::as_f64))
        .unwrap_or(0.0);
    let total = used + remaining;
    let used_pct = if total > 0.0 {
        ((used / total) * 100.0).round().clamp(0.0, 100.0) as i32
    } else {
        0
    };

    let mut windows = vec![QuotaWindow {
        semantic_key: None,
        semantic_kind: None,
        label: "Số dư".into(),
        used_pct,
        remaining_pct: 100 - used_pct,
        subtitle: Some(format!("${used:.2} / ${total:.2}")),
        resets_at: None,
        window_seconds: None,
    }];

    if let Some(today) = body.get("usage").and_then(|u| u.get("today")) {
        let today_cost = today
            .get("actual_cost")
            .and_then(Value::as_f64)
            .or_else(|| today.get("cost").and_then(Value::as_f64))
            .unwrap_or(0.0);
        let today_requests = today
            .get("requests")
            .and_then(Value::as_i64)
            .unwrap_or(0);
        if today_cost > 0.0 || today_requests > 0 {
            let subtitle = if today_requests > 0 {
                format!("${today_cost:.2} · {today_requests} req")
            } else {
                format!("${today_cost:.2}")
            };
            windows.push(QuotaWindow {
                semantic_key: None,
                semantic_kind: None,
                label: "Hôm nay".into(),
                used_pct: 0,
                remaining_pct: 100,
                subtitle: Some(subtitle),
                resets_at: None,
                window_seconds: None,
            });
        }
    }

    let mode = body
        .get("mode")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_ascii_lowercase();
    if mode == "quota_limited" {
        if let Some(sub) = body.get("subscription") {
            if let Some(w) = subscription_window(
                "Ngày",
                sub.get("daily_usage_usd").and_then(Value::as_f64),
                sub.get("daily_limit_usd").and_then(Value::as_f64),
            ) {
                windows.push(w);
            }
            if let Some(w) = subscription_window(
                "Tuần",
                sub.get("weekly_usage_usd").and_then(Value::as_f64),
                sub.get("weekly_limit_usd").and_then(Value::as_f64),
            ) {
                windows.push(w);
            }
            if let Some(w) = subscription_window(
                "Tháng",
                sub.get("monthly_usage_usd").and_then(Value::as_f64),
                sub.get("monthly_limit_usd").and_then(Value::as_f64),
            ) {
                windows.push(w);
            }
        }
    }

    let plan_name = body
        .get("planName")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(String::from);

    ProviderStatus {
        id: id.to_string(),
        display_name: name.to_string(),
        windows,
        last_updated: chrono::Utc::now().timestamp(),
        account_label: Some(account_label.to_string()),
        credits_remaining: Some(remaining),
        plan_name,
        ..Default::default()
    }
}

fn subscription_window(label: &str, used: Option<f64>, limit: Option<f64>) -> Option<QuotaWindow> {
    let limit = limit.filter(|l| *l > 0.0 && l.is_finite())?;
    let spent = used.unwrap_or(0.0).max(0.0);
    let used_pct = ((spent / limit) * 100.0).round().clamp(0.0, 100.0) as i32;
    Some(QuotaWindow {
        semantic_key: None,
        semantic_kind: None,
        label: label.into(),
        used_pct,
        remaining_pct: 100 - used_pct,
        subtitle: Some(format!("${spent:.2} / ${limit:.2}")),
        resets_at: None,
        window_seconds: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parses_unrestricted_wallet() {
        let body = json!({
            "balance": 290.6,
            "remaining": 290.6,
            "unit": "USD",
            "planName": "钱包余额",
            "isValid": true,
            "mode": "unrestricted",
            "usage": {
                "today": {
                    "requests": 0,
                    "cost": 0,
                    "actual_cost": 0
                },
                "total": {
                    "requests": 89,
                    "cost": 8.85,
                    "actual_cost": 10.14
                }
            }
        });
        let s = parse("tryapi", "TryAPI", "sk-try12", &body);
        assert!(s.error.is_none());
        assert_eq!(s.windows.len(), 1);
        assert_eq!(s.windows[0].label, "Số dư");
        // used=10.14, remaining=290.6, total=300.74 → ~3%
        assert_eq!(s.windows[0].used_pct, 3);
        assert_eq!(s.windows[0].remaining_pct, 97);
        assert_eq!(
            s.windows[0].subtitle.as_deref(),
            Some("$10.14 / $300.74")
        );
        assert!((s.credits_remaining.unwrap() - 290.6).abs() < 0.001);
        assert_eq!(s.plan_name.as_deref(), Some("钱包余额"));
        assert_eq!(s.account_label.as_deref(), Some("sk-try12"));
    }

    #[test]
    fn prefers_actual_cost_over_cost() {
        let body = json!({
            "remaining": 90.0,
            "isValid": true,
            "usage": { "total": { "cost": 5.0, "actual_cost": 10.0 } }
        });
        let s = parse("tryapi", "TryAPI", "x", &body);
        // used=10, remaining=90, total=100 → 10%
        assert_eq!(s.windows[0].used_pct, 10);
        assert_eq!(s.windows[0].subtitle.as_deref(), Some("$10.00 / $100.00"));
    }

    #[test]
    fn falls_back_to_cost_when_actual_missing() {
        let body = json!({
            "balance": 50.0,
            "isValid": true,
            "usage": { "total": { "cost": 10.0 } }
        });
        let s = parse("tryapi", "TryAPI", "x", &body);
        // used=10, remaining=50, total=60 → 17%
        assert_eq!(s.windows[0].used_pct, 17);
        assert_eq!(s.windows[0].subtitle.as_deref(), Some("$10.00 / $60.00"));
    }

    #[test]
    fn today_window_when_traffic() {
        let body = json!({
            "remaining": 100.0,
            "isValid": true,
            "usage": {
                "today": { "requests": 3, "actual_cost": 1.25 },
                "total": { "actual_cost": 5.0 }
            }
        });
        let s = parse("tryapi", "TryAPI", "x", &body);
        assert_eq!(s.windows.len(), 2);
        assert_eq!(s.windows[1].label, "Hôm nay");
        assert_eq!(
            s.windows[1].subtitle.as_deref(),
            Some("$1.25 · 3 req")
        );
    }

    #[test]
    fn no_today_window_when_idle() {
        let body = json!({
            "remaining": 100.0,
            "isValid": true,
            "usage": {
                "today": { "requests": 0, "cost": 0, "actual_cost": 0 },
                "total": { "actual_cost": 0 }
            }
        });
        let s = parse("tryapi", "TryAPI", "x", &body);
        assert_eq!(s.windows.len(), 1);
        assert_eq!(s.windows[0].label, "Số dư");
    }

    #[test]
    fn quota_limited_subscription_windows() {
        let body = json!({
            "remaining": 10.0,
            "isValid": true,
            "mode": "quota_limited",
            "usage": { "total": { "actual_cost": 2.0 } },
            "subscription": {
                "daily_usage_usd": 1.0,
                "daily_limit_usd": 5.0,
                "weekly_usage_usd": 3.0,
                "weekly_limit_usd": 20.0,
                "monthly_usage_usd": 8.0,
                "monthly_limit_usd": 50.0
            }
        });
        let s = parse("tryapi", "TryAPI", "x", &body);
        let labels: Vec<_> = s.windows.iter().map(|w| w.label.as_str()).collect();
        assert_eq!(labels, vec!["Số dư", "Ngày", "Tuần", "Tháng"]);
        assert_eq!(s.windows[1].used_pct, 20); // 1/5
        assert_eq!(s.windows[2].used_pct, 15); // 3/20
        assert_eq!(s.windows[3].used_pct, 16); // 8/50
    }

    #[test]
    fn invalid_key_is_error() {
        let body = json!({ "isValid": false, "remaining": 0 });
        let s = parse("tryapi", "TryAPI", "x", &body);
        assert_eq!(s.error.as_deref(), Some("API key không hợp lệ"));
        assert!(s.windows.is_empty());
    }

    #[test]
    fn missing_fields_zero_not_error() {
        let s = parse("tryapi", "TryAPI", "x", &json!({ "isValid": true }));
        assert!(s.error.is_none());
        assert_eq!(s.windows.len(), 1);
        assert_eq!(s.windows[0].used_pct, 0);
        assert!((s.credits_remaining.unwrap() - 0.0).abs() < 0.001);
    }

    #[test]
    fn infinite_or_zero_limits_skipped() {
        let body = json!({
            "remaining": 1.0,
            "isValid": true,
            "mode": "quota_limited",
            "subscription": {
                "daily_usage_usd": 1.0,
                "daily_limit_usd": 0.0,
                "weekly_limit_usd": null
            }
        });
        let s = parse("tryapi", "TryAPI", "x", &body);
        assert_eq!(s.windows.len(), 1);
        assert_eq!(s.windows[0].label, "Số dư");
    }
}
