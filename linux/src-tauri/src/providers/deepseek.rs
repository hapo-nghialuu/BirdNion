//! DeepSeek balance provider — port of `DeepSeekProvider.swift`.
//!
//! `GET https://api.deepseek.com/user/balance` (Bearer key) →
//! `{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"12.34",...}]}`.
//! DeepSeek is a prepaid balance, not a rate-limited quota — there is no
//! percentage to show. Surfaced as `credits_remaining` + a subtitle window.

use serde_json::Value;

use crate::config;
use crate::providers::{display_name, shared_client, ProviderStatus, QuotaWindow};

const ENDPOINT: &str = "https://api.deepseek.com/user/balance";

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
        Err(_) => return ProviderStatus::failure(&cfg.id, &name, "Response thiếu trường"),
    };
    parse_balance(&cfg.id, &name, &account_label, &body)
}

/// Pure payload → status mapping (unit-tested).
pub fn parse_balance(id: &str, name: &str, account_label: &str, body: &Value) -> ProviderStatus {
    let Some(infos) = body.get("balance_infos").and_then(Value::as_array) else {
        return ProviderStatus::failure(id, name, "Response thiếu trường");
    };
    // Prefer USD-funded entry when multiple currencies are present.
    let Some(info) = infos
        .iter()
        .find(|i| i.get("currency").and_then(Value::as_str) == Some("USD"))
        .or_else(|| infos.first())
    else {
        return ProviderStatus::failure(id, name, "Không có thông tin số dư");
    };

    let currency = info.get("currency").and_then(Value::as_str).unwrap_or("USD");
    let total_str = info.get("total_balance").and_then(Value::as_str).unwrap_or("0");
    let amount: f64 = total_str.parse().unwrap_or(0.0);
    let symbol = if currency == "CNY" { "¥" } else { "$" };

    let low_balance = amount <= 0.0;
    let topped_up = info.get("topped_up_balance").and_then(Value::as_str);
    let granted = info.get("granted_balance").and_then(Value::as_str);
    let subtitle = if low_balance {
        "Hết số dư — cần nạp thêm".to_string()
    } else if let (Some(t), Some(g)) = (topped_up, granted) {
        format!("{symbol}{total_str} · Trả: {symbol}{t} · Tặng: {symbol}{g}")
    } else {
        format!("{symbol}{total_str}")
    };

    let window = QuotaWindow {
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
        credits_remaining: Some(amount),
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
            "is_available": true,
            "balance_infos": [
                {"currency": "USD", "total_balance": "12.34", "granted_balance": "2.00", "topped_up_balance": "10.34"}
            ]
        });
        let s = parse_balance("deepseek", "DeepSeek", "sk-abc123", &body);
        assert!(s.error.is_none());
        assert_eq!(s.windows.len(), 1);
        assert_eq!(s.windows[0].used_pct, 0);
        assert!((s.credits_remaining.unwrap() - 12.34).abs() < 0.001);
        assert!(s.windows[0].subtitle.as_deref().unwrap().contains("Trả"));
    }

    #[test]
    fn zero_balance_flags_red() {
        let body = json!({"is_available": true, "balance_infos": [{"currency": "USD", "total_balance": "0.00"}]});
        let s = parse_balance("deepseek", "DeepSeek", "x", &body);
        assert_eq!(s.windows[0].used_pct, 100);
        assert_eq!(s.windows[0].subtitle.as_deref(), Some("Hết số dư — cần nạp thêm"));
    }

    #[test]
    fn missing_balance_infos_is_error() {
        let s = parse_balance("deepseek", "DeepSeek", "x", &json!({}));
        assert!(s.error.is_some());
    }
}
