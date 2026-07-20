//! Z.ai / GLM coding-plan quota provider — port of `ZaiProvider.swift`.
//!
//! `GET https://<host>/api/monitor/usage/quota/limit` (Bearer key). Host is
//! `api.z.ai` (global, default) or `open.bigmodel.cn` (`cfg.region == "cn"`).
//!
//! Response: `{ code, success, data: { limits: [ { type, unit, number,
//! percentage, remaining, next_reset_time } ], plan_name } }`. Each limit
//! entry maps to one `QuotaWindow` (percentage is the % already used).

use serde_json::Value;

use crate::config;
use crate::providers::{display_name, shared_client, ProviderStatus, QuotaWindow};

fn endpoint(region: &str) -> String {
    let host = if region == "cn" { "open.bigmodel.cn" } else { "api.z.ai" };
    format!("https://{host}/api/monitor/usage/quota/limit")
}

pub async fn fetch(cfg: &config::Provider) -> ProviderStatus {
    let name = display_name(cfg);
    let Some(token) = config::api_key(cfg) else {
        return ProviderStatus::failure(&cfg.id, &name, "Chưa cấu hình token");
    };
    let account_label = cfg
        .account_label
        .clone()
        .unwrap_or_else(|| token.chars().take(8).collect());

    let region = cfg.region.as_deref().unwrap_or("global");
    let client = shared_client();
    let resp = client
        .get(endpoint(region))
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
    parse_quota(&cfg.id, &name, &account_label, &body)
}

/// Human label from the raw limit type/unit/number.
/// unit codes (z.ai): 1=days, 3=hours, 5=minutes, 6=weeks.
fn label(kind: &str, unit: i64, number: i64, is_primary_tokens: bool) -> String {
    if kind == "TOKENS_LIMIT" {
        if is_primary_tokens {
            return "Tokens".to_string();
        }
        return unit_label(unit, number);
    }
    if unit == 5 && number == 1 {
        return "MCP".to_string();
    }
    if unit == 1 && number >= 28 {
        return "Monthly".to_string();
    }
    unit_label(unit, number)
}

fn unit_label(unit: i64, number: i64) -> String {
    match unit {
        3 => format!("{number} giờ"),
        1 => format!("{number} ngày"),
        5 => format!("{number} phút"),
        6 => {
            if number == 1 {
                "Tuần".to_string()
            } else {
                format!("{number} tuần")
            }
        }
        _ => "Giới hạn".to_string(),
    }
}

/// Window length in minutes (used for sorting token limits long vs short).
fn window_minutes(unit: i64, number: i64) -> i64 {
    if number <= 0 {
        return 0;
    }
    match unit {
        5 => number,
        3 => number * 60,
        1 => number * 24 * 60,
        6 => number * 7 * 24 * 60,
        _ => 0,
    }
}

/// Derives used% from usage(limit)/remaining/current_value fields when
/// available, falling back to the raw `percentage` field.
fn computed_used_percent(entry: &Value) -> f64 {
    let percentage = entry.get("percentage").and_then(Value::as_f64).unwrap_or(0.0);
    let Some(limit) = entry.get("usage").and_then(Value::as_i64).filter(|l| *l > 0) else {
        return percentage;
    };
    let remaining = entry.get("remaining").and_then(Value::as_i64);
    let current_value = entry.get("current_value").and_then(Value::as_i64);
    let used_raw = match (remaining, current_value) {
        (Some(r), Some(c)) => Some((limit - r).max(c)),
        (Some(r), None) => Some(limit - r),
        (None, Some(c)) => Some(c),
        (None, None) => None,
    };
    let Some(used_raw) = used_raw else { return percentage };
    let used = used_raw.clamp(0, limit);
    ((used as f64 / limit as f64) * 100.0).clamp(0.0, 100.0)
}

/// Pure payload → status mapping (unit-tested).
pub fn parse_quota(id: &str, name: &str, account_label: &str, body: &Value) -> ProviderStatus {
    let success = body.get("success").and_then(Value::as_bool).unwrap_or(false);
    let code = body.get("code").and_then(Value::as_i64).unwrap_or(0);
    let msg = body.get("msg").and_then(Value::as_str).unwrap_or("");
    let limits = body
        .get("data")
        .and_then(|d| d.get("limits"))
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();

    if !success || code != 200 || limits.is_empty() {
        let err = if msg.is_empty() { "Không có dữ liệu quota" } else { msg };
        return ProviderStatus::failure(id, name, err);
    }

    // Longest TOKENS_LIMIT window is the primary "Tokens" entry; the rest are
    // session windows (e.g. "5 giờ").
    let mut token_limit_idxs: Vec<usize> = limits
        .iter()
        .enumerate()
        .filter(|(_, e)| e.get("type").and_then(Value::as_str) == Some("TOKENS_LIMIT"))
        .map(|(i, _)| i)
        .collect();
    token_limit_idxs.sort_by_key(|&i| {
        let e = &limits[i];
        let unit = e.get("unit").and_then(Value::as_i64).unwrap_or(0);
        let number = e.get("number").and_then(Value::as_i64).unwrap_or(0);
        std::cmp::Reverse(window_minutes(unit, number))
    });
    let primary_idx = token_limit_idxs.first().copied();

    let windows: Vec<QuotaWindow> = limits
        .iter()
        .enumerate()
        .map(|(i, e)| {
            let kind = e.get("type").and_then(Value::as_str).unwrap_or("");
            let unit = e.get("unit").and_then(Value::as_i64).unwrap_or(0);
            let number = e.get("number").and_then(Value::as_i64).unwrap_or(0);
            let is_primary = kind == "TOKENS_LIMIT" && Some(i) == primary_idx;
            let used_pct = computed_used_percent(e).round().clamp(0.0, 100.0) as i32;
            let resets_at = e.get("next_reset_time").and_then(Value::as_i64).map(|ms| ms / 1000);
            QuotaWindow { semantic_key: None, semantic_kind: None,
                label: label(kind, unit, number, is_primary),
                used_pct,
                remaining_pct: 100 - used_pct,
                subtitle: None,
                resets_at,
                window_seconds: None,
            }
        })
        .collect();

    ProviderStatus {
        id: id.to_string(),
        display_name: name.to_string(),
        windows,
        last_updated: chrono::Utc::now().timestamp(),
        account_label: Some(account_label.to_string()),
        ..Default::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parses_multiple_limits() {
        let body = json!({
            "code": 200, "success": true, "msg": "",
            "data": {
                "plan_name": "Lite",
                "limits": [
                    {"type": "TOKENS_LIMIT", "unit": 1, "number": 30, "percentage": 40, "usage": 1000, "remaining": 600, "next_reset_time": 1_700_000_000_000i64},
                    {"type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 10, "usage": 100, "remaining": 90}
                ]
            }
        });
        let s = parse_quota("zai", "z.ai", "sk-12", &body);
        assert!(s.error.is_none());
        assert_eq!(s.windows.len(), 2);
        assert_eq!(s.windows[0].label, "Tokens");
        assert_eq!(s.windows[0].used_pct, 40);
        assert_eq!(s.windows[0].resets_at, Some(1_700_000_000));
        assert_eq!(s.windows[1].label, "5 giờ");
        assert_eq!(s.windows[1].used_pct, 10);
    }

    #[test]
    fn logical_failure_returns_msg() {
        let body = json!({"code": 401, "success": false, "msg": "invalid key", "data": null});
        let s = parse_quota("zai", "z.ai", "x", &body);
        assert_eq!(s.error.as_deref(), Some("invalid key"));
    }

    #[test]
    fn malformed_payload_is_error() {
        let s = parse_quota("zai", "z.ai", "x", &json!({}));
        assert!(s.error.is_some());
    }
}
