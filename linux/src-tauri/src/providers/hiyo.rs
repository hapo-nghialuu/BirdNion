//! Hiyo balance provider — port of `HiyoProvider.swift`.
//!
//! `GET https://codex.hiyo.top/v1/usage` (Bearer key) →
//! `{"balance":3.98,"remaining":3.98,"unit":"USD","isValid":true,...}`.
//! Hiyo is a prepaid balance (USD credits), not a rate-limited quota —
//! displayed like DeepSeek: single "Số dư" window + `credits_remaining`.
//!
//! Key resolution: env `HIYO_API_KEY` → multi-key store active → legacy
//! `providers.hiyo.apiKey` in settings.json.

use serde_json::Value;

use crate::config;
use crate::providers::{display_name, shared_client, ProviderStatus, QuotaWindow};

const ENDPOINT: &str = "https://codex.hiyo.top/v1/usage";

pub async fn fetch(cfg: &config::Provider) -> ProviderStatus {
    let name = display_name(cfg);
    // Resolution: env override → multi-key store active → legacy settings apiKey.
    let envtok = std::env::var("HIYO_API_KEY")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());
    let token = envtok
        .or_else(crate::hiyo_keys::active_api_key)
        .or_else(|| config::api_key(cfg));
    let Some(token) = token else {
        return ProviderStatus::failure(&cfg.id, &name, "Chưa cấu hình API key Hiyo");
    };
    // Prefer active multi-key label so switching keys updates the shown identity.
    let account_label = crate::hiyo_keys::active_display_label()
        .or_else(|| cfg.account_label.clone())
        .unwrap_or_else(|| token.chars().take(8).collect());

    let client = shared_client();
    let resp = client
        .get(ENDPOINT)
        .bearer_auth(&token)
        .header("Accept", "application/json")
        .header("Cache-Control", "no-cache")
        .send()
        .await;
    let resp = match resp {
        Ok(r) => r,
        Err(e) => return ProviderStatus::failure(&cfg.id, &name, format!("Network: {e}")),
    };
    match resp.status().as_u16() {
        200..=299 => {}
        401 | 403 => {
            return ProviderStatus::failure(&cfg.id, &name, "API key Hiyo không hợp lệ")
        }
        code => return ProviderStatus::failure(&cfg.id, &name, format!("HTTP {code}")),
    }
    let body: Value = match resp.json().await {
        Ok(v) => v,
        Err(_) => return ProviderStatus::failure(&cfg.id, &name, "Response thiếu trường"),
    };
    parse_balance(&cfg.id, &name, &account_label, &body)
}

/// Pure payload → status mapping (unit-tested).
/// Prefer `balance` then `remaining`. Missing both → 0 credits (not an error
/// unless `isValid == false`).
pub fn parse_balance(id: &str, name: &str, account_label: &str, body: &Value) -> ProviderStatus {
    if body.get("isValid").and_then(Value::as_bool) == Some(false) {
        return ProviderStatus::failure(id, name, "API key Hiyo không hợp lệ");
    }

    let balance = body
        .get("balance")
        .and_then(Value::as_f64)
        .or_else(|| body.get("remaining").and_then(Value::as_f64))
        .unwrap_or(0.0);
    let unit = body
        .get("unit")
        .and_then(Value::as_str)
        .unwrap_or("USD");
    let symbol = if unit.eq_ignore_ascii_case("USD") {
        "$".to_string()
    } else {
        format!("{unit} ")
    };

    let low_balance = balance <= 0.0;
    let subtitle = if low_balance {
        "Hết số dư — cần nạp thêm".to_string()
    } else {
        format!("{symbol}{balance:.2}")
    };

    let plan_name = body
        .get("planName")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(String::from);

    let window = QuotaWindow {
        semantic_key: None,
        semantic_kind: None,
        label: "Số dư".into(),
        used_pct: if low_balance { 100 } else { 0 },
        remaining_pct: if low_balance { 0 } else { 100 },
        subtitle: Some(subtitle),
        resets_at: None,
        window_seconds: None,
    };
    ProviderStatus {
        id: id.to_string(),
        display_name: name.to_string(),
        windows: vec![window],
        last_updated: chrono::Utc::now().timestamp(),
        account_label: Some(account_label.to_string()),
        credits_remaining: Some(balance),
        plan_name,
        ..Default::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parses_usd_balance() {
        let body = json!({
            "balance": 3.98917248,
            "remaining": 3.98917248,
            "unit": "USD",
            "isValid": true,
            "mode": "unrestricted",
            "planName": null
        });
        let s = parse_balance("hiyo", "Hiyo", "sk-abc123", &body);
        assert!(s.error.is_none());
        assert_eq!(s.windows.len(), 1);
        assert_eq!(s.windows[0].used_pct, 0);
        assert_eq!(s.windows[0].label, "Số dư");
        assert!((s.credits_remaining.unwrap() - 3.98917248).abs() < 0.001);
        assert_eq!(s.windows[0].subtitle.as_deref(), Some("$3.99"));
        assert!(s.plan_name.is_none());
    }

    #[test]
    fn zero_balance_flags_red() {
        let body = json!({
            "balance": 0.0,
            "unit": "USD",
            "isValid": true
        });
        let s = parse_balance("hiyo", "Hiyo", "x", &body);
        assert_eq!(s.windows[0].used_pct, 100);
        assert_eq!(
            s.windows[0].subtitle.as_deref(),
            Some("Hết số dư — cần nạp thêm")
        );
        assert!((s.credits_remaining.unwrap() - 0.0).abs() < 0.001);
    }

    #[test]
    fn missing_balance_still_zero_not_error() {
        // Missing balance/remaining → 0 credits, NOT an error (unless isValid=false).
        let s = parse_balance("hiyo", "Hiyo", "x", &json!({ "isValid": true }));
        assert!(s.error.is_none());
        assert_eq!(s.windows.len(), 1);
        assert_eq!(s.windows[0].used_pct, 100);
        assert!((s.credits_remaining.unwrap() - 0.0).abs() < 0.001);
    }

    #[test]
    fn prefers_balance_over_remaining() {
        let body = json!({
            "balance": 1.5,
            "remaining": 9.9,
            "unit": "USD",
            "isValid": true
        });
        let s = parse_balance("hiyo", "Hiyo", "x", &body);
        assert!((s.credits_remaining.unwrap() - 1.5).abs() < 0.001);
    }

    #[test]
    fn falls_back_to_remaining() {
        let body = json!({
            "remaining": 2.25,
            "unit": "USD",
            "isValid": true
        });
        let s = parse_balance("hiyo", "Hiyo", "x", &body);
        assert!((s.credits_remaining.unwrap() - 2.25).abs() < 0.001);
        assert_eq!(s.windows[0].subtitle.as_deref(), Some("$2.25"));
    }

    #[test]
    fn is_valid_false_is_error() {
        let body = json!({
            "balance": 10.0,
            "isValid": false
        });
        let s = parse_balance("hiyo", "Hiyo", "x", &body);
        assert!(s.error.is_some());
        assert!(s.error.as_deref().unwrap().contains("không hợp lệ"));
        assert!(s.windows.is_empty());
    }

    #[test]
    fn plan_name_when_present() {
        let body = json!({
            "balance": 5.0,
            "unit": "USD",
            "isValid": true,
            "planName": "Pro"
        });
        let s = parse_balance("hiyo", "Hiyo", "x", &body);
        assert_eq!(s.plan_name.as_deref(), Some("Pro"));
    }

    #[test]
    fn non_usd_unit_prefix() {
        let body = json!({
            "balance": 1.0,
            "unit": "CNY",
            "isValid": true
        });
        let s = parse_balance("hiyo", "Hiyo", "x", &body);
        assert_eq!(s.windows[0].subtitle.as_deref(), Some("CNY 1.00"));
    }
}
