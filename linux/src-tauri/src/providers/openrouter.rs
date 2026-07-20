//! OpenRouter credits provider — port of `OpenRouterProvider.swift`.
//!
//! `GET https://openrouter.ai/api/v1/credits` (Bearer key) →
//! `{"data":{"total_credits":10.0,"total_usage":3.2}}`. Prepaid credits, no
//! reset cadence. Best-effort second window from `GET /api/v1/key` when the
//! key carries a finite spending limit.

use serde_json::Value;

use crate::config;
use crate::providers::{display_name, shared_client, ProviderStatus, QuotaWindow};

const CREDITS_URL: &str = "https://openrouter.ai/api/v1/credits";
const KEY_URL: &str = "https://openrouter.ai/api/v1/key";

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
        .get(CREDITS_URL)
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

    let mut status = match parse_credits(&cfg.id, &name, &account_label, &body) {
        Some(s) => s,
        None => return ProviderStatus::failure(&cfg.id, &name, "Payload thiếu total_credits"),
    };

    // Non-fatal enrichment: per-key spending-limit window.
    if let Some(window) = fetch_key_window(&client, &token).await {
        status.windows.push(window);
    }
    status
}

/// Pure payload → status mapping (unit-tested).
pub fn parse_credits(
    id: &str,
    name: &str,
    account_label: &str,
    body: &Value,
) -> Option<ProviderStatus> {
    let data = body.get("data")?;
    let total = data.get("total_credits").and_then(Value::as_f64)?;
    let usage = data.get("total_usage").and_then(Value::as_f64).unwrap_or(0.0);
    let remaining = (total - usage).max(0.0);
    let used_pct = if total > 0.0 {
        ((usage / total) * 100.0).round().clamp(0.0, 100.0) as i32
    } else {
        0
    };
    Some(ProviderStatus {
        id: id.to_string(),
        display_name: name.to_string(),
        windows: vec![QuotaWindow { semantic_key: None, semantic_kind: None,
            label: "Credits".into(),
            used_pct,
            remaining_pct: 100 - used_pct,
            subtitle: Some(format!("Còn ${remaining:.2} / ${total:.2}")),
            resets_at: None,
            window_seconds: None,
        }],
        last_updated: chrono::Utc::now().timestamp(),
        account_label: Some(account_label.to_string()),
        credits_remaining: Some(remaining),
        ..Default::default()
    })
}

async fn fetch_key_window(client: &reqwest::Client, token: &str) -> Option<QuotaWindow> {
    let body: Value = client
        .get(KEY_URL)
        .bearer_auth(token)
        .header("Accept", "application/json")
        .header("HTTP-Referer", "https://birdnion.app")
        .header("X-Title", "BirdNion")
        .send()
        .await
        .ok()?
        .error_for_status()
        .ok()?
        .json()
        .await
        .ok()?;
    parse_key_window(&body)
}

/// `{"data":{"limit":25.0,"usage":3.2}}` → key-limit window; None for
/// unlimited keys (limit null/0) or malformed payloads.
pub fn parse_key_window(body: &Value) -> Option<QuotaWindow> {
    let data = body.get("data")?;
    let limit = data.get("limit").and_then(Value::as_f64).filter(|l| *l > 0.0)?;
    let usage = data.get("usage").and_then(Value::as_f64).unwrap_or(0.0);
    let used_pct = ((usage / limit) * 100.0).round().clamp(0.0, 100.0) as i32;
    Some(QuotaWindow { semantic_key: None, semantic_kind: None,
        label: "Hạn mức key".into(),
        used_pct,
        remaining_pct: 100 - used_pct,
        subtitle: Some(format!("${usage:.2} / ${limit:.2}")),
        resets_at: None,
        window_seconds: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parses_credits_payload() {
        let body = json!({"data": {"total_credits": 10.0, "total_usage": 3.2}});
        let s = parse_credits("openrouter", "OpenRouter", "sk-or-12", &body).unwrap();
        assert_eq!(s.windows.len(), 1);
        assert_eq!(s.windows[0].used_pct, 32);
        assert_eq!(s.windows[0].remaining_pct, 68);
        assert!((s.credits_remaining.unwrap() - 6.8).abs() < 0.001);
        assert!(s.error.is_none());
    }

    #[test]
    fn key_window_only_for_finite_limits() {
        assert!(parse_key_window(&json!({"data": {"limit": null, "usage": 1.0}})).is_none());
        let w = parse_key_window(&json!({"data": {"limit": 25.0, "usage": 5.0}})).unwrap();
        assert_eq!(w.used_pct, 20);
    }

    #[test]
    fn missing_data_is_error() {
        assert!(parse_credits("openrouter", "OpenRouter", "x", &json!({})).is_none());
    }
}
