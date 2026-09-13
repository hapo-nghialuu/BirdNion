//! CommandCode quota provider — port of `CommandCodeProvider.swift`.
//!
//! Quirk: the real session cookie name is
//! `__Secure-commandcode_prod_.session_token` (custom prefix). We forward
//! ALL cookies for the domain and gate only on the presence of ANY cookie
//! whose name contains "session_token" (case-insensitive), matching Swift.
//!
//! Endpoints (base `https://api.commandcode.ai/internal/billing`):
//!   GET /credits       (required) -> { "credits": { "monthlyCredits": 25.0, ... } }
//!   GET /subscriptions (optional) -> { "success": true, "data": { "planId": "individual-pro", ... } }

use serde_json::Value;

use crate::providers::browser_cookies;
use crate::providers::{display_name, ProviderStatus, QuotaWindow};

const CREDITS_URL: &str = "https://api.commandcode.ai/internal/billing/credits";
const SUBSCRIPTIONS_URL: &str = "https://api.commandcode.ai/internal/billing/subscriptions";
const SUPPORTED_SESSION_COOKIE_NAMES: &[&str] = &[
    "__Host-better-auth.session_token",
    "__Secure-better-auth.session_token",
    "better-auth.session_token",
];

pub async fn fetch(cfg: &crate::config::Provider) -> ProviderStatus {
    let name = display_name(cfg);
    let id = cfg.id.clone();
    let cfg_clone = cfg.clone();

    let raw_header = match tauri::async_runtime::spawn_blocking(move || {
        browser_cookies::cookie_header(&["commandcode.ai"], &cfg_clone)
    })
    .await
    {
        Ok(Ok(h)) => h,
        Ok(Err(e)) => return ProviderStatus::failure(&id, &name, e),
        Err(_) => return ProviderStatus::failure(&id, &name, "Lỗi nội bộ khi đọc cookie"),
    };

    let Some(cookie_header) = filtered_cookie_header(&raw_header) else {
        return ProviderStatus::failure(&id, &name, "Không tìm thấy cookie đăng nhập Command Code");
    };

    let client = crate::providers::shared_client();

    let credits_result = client
        .get(CREDITS_URL)
        .header("Cookie", &cookie_header)
        .send()
        .await;

    let credits_body = match credits_result {
        Ok(resp) if resp.status().is_success() => match resp.text().await {
            Ok(t) => t,
            Err(e) => return ProviderStatus::failure(&id, &name, format!("Network: {e}")),
        },
        Ok(resp) => {
            return ProviderStatus::failure(
                &id,
                &name,
                format!("Network: HTTP {}", resp.status().as_u16()),
            )
        }
        Err(e) => return ProviderStatus::failure(&id, &name, format!("Network: {e}")),
    };

    let subscription_body = client
        .get(SUBSCRIPTIONS_URL)
        .header("Cookie", &cookie_header)
        .send()
        .await
        .ok();
    let subscription_text = match subscription_body {
        Some(resp) if resp.status().is_success() => resp.text().await.ok(),
        _ => None,
    };

    match parse_status(&id, &name, &credits_body, subscription_text.as_deref()) {
        Ok(status) => status,
        Err(e) => ProviderStatus::failure(&id, &name, e),
    }
}

/// Bare token (no `=`) wraps as the known session cookie name; otherwise
/// forwards ALL cookie pairs, gated on presence of any session_token cookie.
fn filtered_cookie_header(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    if !trimmed.contains('=') {
        return Some(format!(
            "__Secure-commandcode_prod_.session_token={trimmed}"
        ));
    }

    let has_session = trimmed.split(';').any(|chunk| {
        let t = chunk.trim();
        let Some(eq) = t.find('=') else { return false };
        let name = t[..eq].trim();
        name.to_lowercase().contains("session_token")
            || SUPPORTED_SESSION_COOKIE_NAMES
                .iter()
                .any(|n| n.eq_ignore_ascii_case(name))
    });

    if has_session {
        Some(trimmed.to_string())
    } else {
        None
    }
}

struct PlanInfo {
    display_name: &'static str,
    monthly_credits_usd: f64,
}

fn plan_catalog(plan_id: &str) -> Option<PlanInfo> {
    match plan_id {
        "individual-go" => Some(PlanInfo {
            display_name: "Go",
            monthly_credits_usd: 10.0,
        }),
        "individual-pro" => Some(PlanInfo {
            display_name: "Pro",
            monthly_credits_usd: 30.0,
        }),
        "individual-max" => Some(PlanInfo {
            display_name: "Max",
            monthly_credits_usd: 150.0,
        }),
        "individual-ultra" => Some(PlanInfo {
            display_name: "Ultra",
            monthly_credits_usd: 300.0,
        }),
        _ => None,
    }
}

fn parse_status(
    id: &str,
    name: &str,
    credits_body: &str,
    subscription_body: Option<&str>,
) -> Result<ProviderStatus, String> {
    let credits_json: Value =
        serde_json::from_str(credits_body).map_err(|e| format!("Network: {e}"))?;
    let credits = credits_json
        .get("credits")
        .ok_or_else(|| "Response thiếu trường credits".to_string())?;

    let monthly = credits
        .get("monthlyCredits")
        .and_then(Value::as_f64)
        .ok_or_else(|| "Thiếu monthlyCredits".to_string())?;
    let purchased = credits
        .get("purchasedCredits")
        .and_then(Value::as_f64)
        .unwrap_or(0.0);
    let premium = credits
        .get("premiumMonthlyCredits")
        .and_then(Value::as_f64)
        .unwrap_or(0.0);

    let plan_id = subscription_body
        .and_then(|t| serde_json::from_str::<Value>(t).ok())
        .and_then(|v| {
            v.get("data")
                .and_then(|d| d.get("planId"))
                .and_then(Value::as_str)
                .map(str::to_string)
        });

    let plan = plan_id.as_deref().and_then(plan_catalog);

    // A window carries a percentage, so one may only be built when the plan
    // total is known — that is the denominator. `/credits` reports the
    // REMAINING dollars and nothing else, so without a plan there is no
    // percentage to compute, and anything left over is a balance rather than a
    // quota: it goes to `credits_remaining` instead of a full-looking bar.
    // Mirrors the Swift provider.
    let mut windows = Vec::new();
    let mut spendable_balance = 0.0;

    if let Some(p) = &plan {
        let total = p.monthly_credits_usd;
        let used = (total - monthly).max(0.0);
        let used_pct = if total > 0.0 {
            ((used / total) * 100.0).round().clamp(0.0, 100.0) as i32
        } else {
            0
        };
        windows.push(QuotaWindow {
            semantic_key: None,
            semantic_kind: None,
            label: "Tháng".to_string(),
            used_pct,
            remaining_pct: 100 - used_pct,
            subtitle: Some(format!(
                "{p_name} · ${monthly:.2} còn lại",
                p_name = p.display_name
            )),
            resets_at: None,
            window_seconds: None,
        });
    } else if monthly > 0.0 {
        spendable_balance += monthly;
    }

    // Top-ups never have an allowance to divide by, so they stay a balance even
    // when the monthly plan IS known.
    spendable_balance += purchased.max(0.0) + premium.max(0.0);

    Ok(ProviderStatus {
        id: id.to_string(),
        display_name: name.to_string(),
        windows,
        last_updated: chrono::Utc::now().timestamp(),
        credits_remaining: (spendable_balance > 0.0).then_some(spendable_balance),
        ..Default::default()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_credits_with_known_plan() {
        let credits = r#"{"credits":{"monthlyCredits":25.0,"purchasedCredits":0.0,"premiumMonthlyCredits":0.0,"opensourceMonthlyCredits":0.0}}"#;
        let subscriptions = r#"{"success":true,"data":{"planId":"individual-pro","status":"active","currentPeriodEnd":"2025-08-01T00:00:00.000Z"}}"#;
        let status =
            parse_status("commandcode", "Command Code", credits, Some(subscriptions)).unwrap();
        assert_eq!(status.windows[0].label, "Tháng");
        assert!(status.windows[0]
            .subtitle
            .as_deref()
            .unwrap()
            .contains("Pro"));
    }

    /// The plan lookup supplies the denominator; without it there is no
    /// percentage, so the balance must not be dressed up as a full window.
    #[test]
    fn parses_credits_without_plan_publishes_balance_not_full_window() {
        let credits = r#"{"credits":{"monthlyCredits":5.0,"purchasedCredits":0.0,"premiumMonthlyCredits":0.0}}"#;
        let subscriptions = r#"{"success":true,"data":null}"#;
        let status =
            parse_status("commandcode", "Command Code", credits, Some(subscriptions)).unwrap();
        assert!(status.windows.is_empty(), "a balance has no percentage to chart");
        assert_eq!(status.credits_remaining, Some(5.0));
    }

    #[test]
    fn missing_credits_field_is_error() {
        assert!(parse_status("commandcode", "Command Code", "{}", None).is_err());
    }

    #[test]
    fn every_balance_without_a_plan_is_summed() {
        let credits = r#"{"credits":{"monthlyCredits":5.0,"purchasedCredits":10.0,"premiumMonthlyCredits":3.0}}"#;
        let status = parse_status("commandcode", "Command Code", credits, None).unwrap();
        assert!(status.windows.is_empty());
        assert_eq!(status.credits_remaining, Some(18.0));
    }

    /// A known plan still charts the monthly grant — top-ups stay a balance
    /// because they have no allowance of their own to divide by.
    #[test]
    fn known_plan_charts_grant_and_keeps_top_ups_as_balance() {
        let credits = r#"{"credits":{"monthlyCredits":12.0,"purchasedCredits":7.0,"premiumMonthlyCredits":0.0}}"#;
        let subscriptions = r#"{"success":true,"data":{"planId":"individual-pro","status":"active"}}"#;
        let status =
            parse_status("commandcode", "Command Code", credits, Some(subscriptions)).unwrap();
        assert_eq!(status.windows.len(), 1);
        assert_eq!(status.windows[0].label, "Tháng");
        // $12 left of the $30 Pro grant -> 60% spent.
        assert_eq!(status.windows[0].used_pct, 60);
        assert_eq!(status.credits_remaining, Some(7.0));
    }

    #[test]
    fn bare_token_wraps_with_known_cookie_name() {
        let header = filtered_cookie_header("abc123").unwrap();
        assert_eq!(header, "__Secure-commandcode_prod_.session_token=abc123");
    }

    #[test]
    fn forwards_all_cookies_when_session_token_present() {
        let header =
            filtered_cookie_header("foo=bar; __Secure-commandcode_prod_.session_token=xyz")
                .unwrap();
        assert!(header.contains("foo=bar"));
        assert!(header.contains("session_token"));
    }

    #[test]
    fn no_session_cookie_returns_none() {
        assert!(filtered_cookie_header("foo=bar; baz=qux").is_none());
    }
}
