//! Xiaomi MiMo quota provider — port of `MiMoProvider.swift`.
//!
//! Cookies span two domains: `userId` lives on the apex domain
//! (`xiaomimimo.com`) while `api-platform_serviceToken` lives on the
//! subdomain (`platform.xiaomimimo.com`) — both are queried and merged.
//!
//! Endpoints (base `https://platform.xiaomimimo.com/api/v1`):
//!   GET /balance            (required)
//!   GET /tokenPlan/detail   (optional, concurrent)
//!   GET /tokenPlan/usage    (optional, concurrent)

use serde_json::Value;

use crate::providers::browser_cookies;
use crate::providers::{display_name, ProviderStatus, QuotaWindow};

const BALANCE_URL: &str = "https://platform.xiaomimimo.com/api/v1/balance";
const PLAN_DETAIL_URL: &str = "https://platform.xiaomimimo.com/api/v1/tokenPlan/detail";
const PLAN_USAGE_URL: &str = "https://platform.xiaomimimo.com/api/v1/tokenPlan/usage";
const REQUIRED_COOKIES: &[&str] = &["api-platform_serviceToken", "userId"];
const OPTIONAL_COOKIES: &[&str] = &["api-platform_ph", "api-platform_slh"];

pub async fn fetch(cfg: &crate::config::Provider) -> ProviderStatus {
    let name = display_name(cfg);
    let id = cfg.id.clone();
    let cfg_clone = cfg.clone();

    let raw_header = match tauri::async_runtime::spawn_blocking(move || {
        let platform = browser_cookies::cookie_header(&["platform.xiaomimimo.com"], &cfg_clone);
        let apex = browser_cookies::cookie_header(&["xiaomimimo.com"], &cfg_clone);
        match (platform, apex) {
            (Ok(a), Ok(b)) if !a.is_empty() && !b.is_empty() => Ok(format!("{a}; {b}")),
            (Ok(a), _) if !a.is_empty() => Ok(a),
            (_, Ok(b)) if !b.is_empty() => Ok(b),
            (Ok(a), Ok(_)) => Ok(a),
            (Err(e), Err(_)) => Err(e),
            (Ok(a), Err(_)) => Ok(a),
            (Err(_), Ok(b)) => Ok(b),
        }
    })
    .await
    {
        Ok(Ok(h)) => h,
        Ok(Err(e)) => return ProviderStatus::failure(&id, &name, e),
        Err(_) => return ProviderStatus::failure(&id, &name, "Lỗi nội bộ khi đọc cookie"),
    };

    let Some(cookie_header) = normalized_cookie_header(&raw_header) else {
        return ProviderStatus::failure(
            &id,
            &name,
            "Không tìm thấy session cookie của MiMo (cần api-platform_serviceToken + userId)",
        );
    };

    let client = crate::providers::shared_client();

    let balance_resp = client.get(BALANCE_URL).header("Cookie", &cookie_header).send().await;
    let balance_body = match balance_resp {
        Ok(resp) if resp.status().is_success() => match resp.text().await {
            Ok(t) => t,
            Err(e) => return ProviderStatus::failure(&id, &name, format!("Network: {e}")),
        },
        Ok(resp) => return ProviderStatus::failure(&id, &name, format!("Network: HTTP {}", resp.status().as_u16())),
        Err(e) => return ProviderStatus::failure(&id, &name, format!("Network: {e}")),
    };

    let detail_body = client.get(PLAN_DETAIL_URL).header("Cookie", &cookie_header).send().await.ok();
    let detail_text = match detail_body {
        Some(resp) if resp.status().is_success() => resp.text().await.ok(),
        _ => None,
    };

    let usage_body = client.get(PLAN_USAGE_URL).header("Cookie", &cookie_header).send().await.ok();
    let usage_text = match usage_body {
        Some(resp) if resp.status().is_success() => resp.text().await.ok(),
        _ => None,
    };

    match parse_status(&id, &name, &balance_body, detail_text.as_deref(), usage_text.as_deref()) {
        Ok(status) => status,
        Err(e) => ProviderStatus::failure(&id, &name, e),
    }
}

fn normalized_cookie_header(raw: &str) -> Option<String> {
    let mut pairs: Vec<(String, String)> = raw
        .split(';')
        .filter_map(|chunk| {
            let t = chunk.trim();
            let eq = t.find('=')?;
            let name = t[..eq].trim();
            let value = t[eq + 1..].trim();
            if name.is_empty() || value.is_empty() {
                return None;
            }
            let allowed = REQUIRED_COOKIES.contains(&name) || OPTIONAL_COOKIES.contains(&name);
            if allowed {
                Some((name.to_string(), value.to_string()))
            } else {
                None
            }
        })
        .collect();

    let has_all_required = REQUIRED_COOKIES.iter().all(|req| pairs.iter().any(|(n, _)| n == req));
    if !has_all_required {
        return None;
    }

    pairs.sort_by(|a, b| a.0.cmp(&b.0));
    Some(pairs.into_iter().map(|(n, v)| format!("{n}={v}")).collect::<Vec<_>>().join("; "))
}

fn parse_status(
    id: &str,
    name: &str,
    balance_body: &str,
    detail_body: Option<&str>,
    usage_body: Option<&str>,
) -> Result<ProviderStatus, String> {
    let balance_json: Value = serde_json::from_str(balance_body).map_err(|_| "Không thể đọc dữ liệu số dư MiMo".to_string())?;
    let data = balance_json.get("data").ok_or_else(|| "Không thể đọc dữ liệu số dư MiMo".to_string())?;

    let balance = string_as_f64(data.get("balance")).ok_or_else(|| "Không thể đọc dữ liệu số dư MiMo".to_string())?;
    let currency = data.get("currency").and_then(Value::as_str).unwrap_or("CNY");
    let cash_balance = string_as_f64(data.get("cashBalance"));
    let gift_balance = string_as_f64(data.get("giftBalance"));

    let symbol = match currency {
        "USD" => "$",
        "CNY" => "¥",
        other => other,
    };

    let mut subtitle = format!("{symbol}{balance:.2}");
    if let (Some(cash), Some(gift)) = (cash_balance, gift_balance) {
        subtitle.push_str(&format!(" ({symbol}{cash:.2} tiền mặt + {symbol}{gift:.2} quà tặng)"));
    }

    let mut windows = vec![QuotaWindow {
        label: "Số dư".to_string(),
        used_pct: 0,
        remaining_pct: 100,
        subtitle: Some(subtitle),
        resets_at: None,
    }];

    let plan_name = detail_body
        .and_then(|t| serde_json::from_str::<Value>(t).ok())
        .and_then(|v| v.get("data").and_then(|d| d.get("planCode")).and_then(Value::as_str).map(capitalize));

    if let Some(usage_text) = usage_body {
        if let Ok(usage_json) = serde_json::from_str::<Value>(usage_text) {
            if let Some(item) = usage_json
                .get("data")
                .and_then(|d| d.get("monthUsage"))
                .and_then(|m| m.get("items"))
                .and_then(Value::as_array)
                .and_then(|arr| arr.first())
            {
                let used = item.get("used").and_then(Value::as_f64).unwrap_or(0.0);
                let limit = item.get("limit").and_then(Value::as_f64).unwrap_or(0.0);
                if limit > 0.0 {
                    let pct = (used / limit * 100.0).round().clamp(0.0, 100.0) as i32;
                    let label = plan_name.clone().map(|p| format!("Token Plan · {p}")).unwrap_or_else(|| "Token Plan".to_string());
                    windows.push(QuotaWindow {
                        label,
                        used_pct: pct,
                        remaining_pct: 100 - pct,
                        subtitle: Some(format!("{} / {} tokens", format_thousands(used), format_thousands(limit))),
                        resets_at: None,
                    });
                }
            }
        }
    }

    Ok(ProviderStatus {
        id: id.to_string(),
        display_name: name.to_string(),
        windows,
        last_updated: chrono::Utc::now().timestamp(),
        credits_remaining: Some(balance),
        ..Default::default()
    })
}

fn string_as_f64(v: Option<&Value>) -> Option<f64> {
    match v {
        Some(Value::String(s)) => s.trim().parse().ok(),
        Some(Value::Number(n)) => n.as_f64(),
        _ => None,
    }
}

fn capitalize(s: &str) -> String {
    let mut chars = s.chars();
    match chars.next() {
        Some(c) => c.to_uppercase().collect::<String>() + chars.as_str(),
        None => s.to_string(),
    }
}

fn format_thousands(v: f64) -> String {
    let n = v.round() as i64;
    let s = n.abs().to_string();
    let mut out = String::new();
    for (i, c) in s.chars().rev().enumerate() {
        if i > 0 && i % 3 == 0 {
            out.push(',');
        }
        out.push(c);
    }
    let rev: String = out.chars().rev().collect();
    if n < 0 {
        format!("-{rev}")
    } else {
        rev
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_balance_only() {
        let balance = r#"{"code":0,"data":{"balance":"12.50","currency":"CNY","cashBalance":"10.00","giftBalance":"2.50"}}"#;
        let status = parse_status("mimo", "Xiaomi MiMo", balance, None, None).unwrap();
        assert_eq!(status.windows.len(), 1);
        assert_eq!(status.credits_remaining, Some(12.5));
    }

    #[test]
    fn parses_balance_with_token_plan_usage() {
        let balance = r#"{"code":0,"data":{"balance":"12.50","currency":"CNY"}}"#;
        let detail = r#"{"code":0,"data":{"planCode":"pro","currentPeriodEnd":"2025-08-01 00:00:00","expired":false}}"#;
        let usage = r#"{"code":0,"data":{"monthUsage":{"percent":0.45,"items":[{"name":"x","used":450000,"limit":1000000,"percent":0.45}]}}}"#;
        let status = parse_status("mimo", "Xiaomi MiMo", balance, Some(detail), Some(usage)).unwrap();
        assert_eq!(status.windows.len(), 2);
        assert_eq!(status.windows[1].used_pct, 45);
        assert!(status.windows[1].label.contains("Pro"));
    }

    #[test]
    fn missing_data_field_is_error() {
        assert!(parse_status("mimo", "Xiaomi MiMo", "{}", None, None).is_err());
    }

    #[test]
    fn requires_both_required_cookies() {
        assert!(normalized_cookie_header("api-platform_serviceToken=abc").is_none());
        let header = normalized_cookie_header("api-platform_serviceToken=abc; userId=123").unwrap();
        assert!(header.contains("api-platform_serviceToken=abc"));
        assert!(header.contains("userId=123"));
    }

    #[test]
    fn drops_unrelated_cookies() {
        let header = normalized_cookie_header("api-platform_serviceToken=abc; userId=123; unrelated=xyz").unwrap();
        assert!(!header.contains("unrelated"));
    }
}
