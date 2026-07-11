//! MiniMax Token Plan quota provider — port of `MiniMaxProvider.swift`.
//! When no API token is configured, falls back to a browser session cookie
//! for the region's platform domain (mirrors Swift's `fetchWithCookie`).
//!
//! Endpoint: `GET https://<host>/v1/api/openplatform/coding_plan/remains`
//! (region `io` = `platform.minimax.io` default, `com` = `platform.minimaxi.com`
//! from `cfg.region`). Auth: `Authorization: Bearer <key>`.
//!
//! Response envelope:
//! ```json
//! {
//!   "base_resp": {"status_code": 0, "status_msg": "success"},
//!   "model_remains": [
//!     {"model_name": "general", "current_interval_remaining_percent": 69,
//!      "current_weekly_remaining_percent": 96, "end_time": 123, "weekly_end_time": 456},
//!     {"model_name": "video", "current_interval_remaining_percent": 100, "current_weekly_remaining_percent": 100}
//!   ]
//! }
//! ```
//! Each non-excluded model becomes two windows (interval + weekly). "video"
//! is filtered out — MiniMax's separate video-generation quota bucket that
//! BOSS does not want surfaced in the popover.

use serde_json::Value;

use crate::config;
use crate::providers::browser_cookies;
use crate::providers::{display_name, shared_client, ProviderStatus, QuotaWindow};

const EXCLUDED_MODELS: &[&str] = &["video"];

fn api_host(region: &str) -> &'static str {
    if region == "com" { "api.minimaxi.com" } else { "api.minimax.io" }
}
fn platform_host(region: &str) -> &'static str {
    if region == "com" { "platform.minimaxi.com" } else { "platform.minimax.io" }
}

/// Endpoint candidates in try-order, mirroring CodexBar/Swift's per-region
/// preference (platform endpoint first for `io` since it returns plan
/// metadata there; API host first for `com` since platform 404s there).
fn endpoint_candidates(region: &str) -> Vec<String> {
    let platform_ep = format!("https://{}/v1/api/openplatform/coding_plan/remains", platform_host(region));
    let api_host = api_host(region);
    let token_plan = format!("https://{api_host}/v1/token_plan/remains");
    let api_coding_plan = format!("https://{api_host}/v1/api/openplatform/coding_plan/remains");

    let ordered = if region == "com" {
        vec![token_plan, api_coding_plan, platform_ep]
    } else {
        vec![platform_ep, token_plan, api_coding_plan]
    };
    let mut seen = std::collections::HashSet::new();
    ordered.into_iter().filter(|u| seen.insert(u.clone())).collect()
}

fn should_try_next(status: u16) -> bool {
    matches!(status, 401 | 403 | 404 | 405)
}

fn should_try_next_after_parse_error(error: &str) -> bool {
    let normalized = error.trim().to_lowercase();
    normalized.contains("response thiếu trường") || normalized.contains("invalid api key") || normalized.contains("invalid credentials")
}

fn is_credential_error(error: &str) -> bool {
    let normalized = error.trim().to_lowercase();
    normalized.contains("invalid api key") || normalized.contains("invalid credentials") || normalized == "http 401" || normalized == "http 403"
}

/// Cookie-domain candidates in try-order, mirroring Swift's region-preference
/// fallback so users don't have to flip the region picker for cookie auth.
fn cookie_domains(region: &str) -> Vec<&'static str> {
    if region == "com" {
        vec!["platform.minimaxi.com", "platform.minimax.io"]
    } else {
        vec!["platform.minimax.io", "platform.minimaxi.com"]
    }
}

pub async fn fetch(cfg: &config::Provider) -> ProviderStatus {
    let name = display_name(cfg);
    let envtok = std::env::var("MINIMAX_CODING_API_KEY").ok().map(|s| s.trim().to_string()).filter(|s| !s.is_empty());
    let token = envtok.or_else(|| config::api_key(cfg));
    let Some(token) = token else {
        return fetch_with_cookie(cfg, &name).await;
    };
    let account_label = cfg
        .account_label
        .clone()
        .unwrap_or_else(|| token.chars().take(8).collect());

    let region = cfg.region.as_deref().unwrap_or("io");
    let endpoints = endpoint_candidates(region);
    let client = shared_client();

    let mut last_error: Option<String> = None;
    let mut credential_error: Option<String> = None;

    for (i, url) in endpoints.iter().enumerate() {
        let is_last = i == endpoints.len() - 1;
        let resp = client
            .get(url)
            .bearer_auth(&token)
            .header("Accept", "application/json")
            .header("Content-Type", "application/json")
            .header("MM-API-Source", "BirdNion")
            .send()
            .await;
        let resp = match resp {
            Ok(r) => r,
            Err(e) => {
                last_error = Some(format!("Network: {e}"));
                if is_last {
                    return ProviderStatus::failure(&cfg.id, &name, credential_error.or(last_error).unwrap());
                }
                continue;
            }
        };
        let status = resp.status().as_u16();
        if !(200..300).contains(&status) {
            let err = format!("HTTP {status}");
            if is_credential_error(&err) {
                credential_error = Some(err.clone());
            }
            if !should_try_next(status) || is_last {
                return ProviderStatus::failure(&cfg.id, &name, credential_error.unwrap_or(err));
            }
            last_error = Some(err);
            continue;
        }
        let body: Value = match resp.json().await {
            Ok(v) => v,
            Err(_) => {
                let err = "Response thiếu trường".to_string();
                if !is_last {
                    last_error = Some(err);
                    continue;
                }
                return ProviderStatus::failure(&cfg.id, &name, credential_error.unwrap_or(err));
            }
        };
        let status_result = parse_remains(&cfg.id, &name, &account_label, &body);
        if let Some(err) = &status_result.error {
            if is_credential_error(err) {
                credential_error = Some(err.clone());
            }
            if should_try_next_after_parse_error(err) && !is_last {
                last_error = Some(err.clone());
                continue;
            }
        }
        return status_result;
    }

    ProviderStatus::failure(&cfg.id, &name, credential_error.or(last_error).unwrap_or_else(|| "Không lấy được quota".to_string()))
}

/// No API token configured → try a browser session cookie for the region's
/// platform domain (mirrors Swift's `fetchWithCookie`). The same
/// `coding_plan/remains` JSON envelope is hit with the cookie header. Only
/// the original "no token/no cookie" error is surfaced when cookies also fail.
async fn fetch_with_cookie(cfg: &config::Provider, name: &str) -> ProviderStatus {
    let region = cfg.region.as_deref().unwrap_or("io").to_string();
    let domains = cookie_domains(&region);
    let cfg_clone = cfg.clone();
    let cookie_header = match tauri::async_runtime::spawn_blocking(move || browser_cookies::cookie_header(&domains, &cfg_clone)).await {
        Ok(Ok(h)) if !h.trim().is_empty() => h,
        _ => return ProviderStatus::failure(&cfg.id, name, "Chưa cấu hình token và không tìm thấy cookie trình duyệt"),
    };

    let url = endpoint_url(&region);
    let client = shared_client();
    let resp = client
        .get(&url)
        .header("Cookie", &cookie_header)
        .header("Accept", "application/json, text/plain, */*")
        .header("User-Agent", "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36")
        .header("X-Requested-With", "XMLHttpRequest")
        .header("Origin", format!("https://{}", platform_host(&region)))
        .send()
        .await;
    let resp = match resp {
        Ok(r) => r,
        Err(e) => return ProviderStatus::failure(&cfg.id, name, format!("Network (cookie): {e}")),
    };
    if !resp.status().is_success() {
        return ProviderStatus::failure(&cfg.id, name, format!("HTTP {} (cookie)", resp.status().as_u16()));
    }
    let body: Value = match resp.json().await {
        Ok(v) => v,
        Err(_) => return ProviderStatus::failure(&cfg.id, name, "Response thiếu trường"),
    };
    let label = cfg.account_label.clone().unwrap_or_else(|| "cookie".to_string());
    parse_remains(&cfg.id, name, &label, &body)
}

/// Same endpoint the API-token path prefers first for the region — cookie
/// auth only needs the one canonical `coding_plan/remains` URL.
fn endpoint_url(region: &str) -> String {
    format!("https://{}/v1/api/openplatform/coding_plan/remains", platform_host(region))
}

/// Pure payload → status mapping (unit-tested).
pub fn parse_remains(id: &str, name: &str, account_label: &str, body: &Value) -> ProviderStatus {
    let Some(base_resp) = body.get("base_resp") else {
        return ProviderStatus::failure(id, name, "Response thiếu trường");
    };
    let status_code = base_resp.get("status_code").and_then(Value::as_i64).unwrap_or(-1);
    if status_code != 0 {
        let msg = base_resp.get("status_msg").and_then(Value::as_str).unwrap_or("MiniMax error");
        return ProviderStatus::failure(id, name, msg);
    }
    let Some(model_remains) = body.get("model_remains").and_then(Value::as_array) else {
        return ProviderStatus::failure(id, name, "Không có model nào trong response");
    };
    if model_remains.is_empty() {
        return ProviderStatus::failure(id, name, "Không có model nào trong response");
    }
    let visible: Vec<&Value> = model_remains
        .iter()
        .filter(|m| {
            let name = m.get("model_name").and_then(Value::as_str).unwrap_or("").to_lowercase();
            !EXCLUDED_MODELS.contains(&name.as_str())
        })
        .collect();
    if visible.is_empty() {
        return ProviderStatus::failure(id, name, "Tất cả model đều nằm trong danh sách loại trừ");
    }

    let multiple = visible.len() > 1;
    let mut windows = Vec::new();
    for m in &visible {
        let model_name = m.get("model_name").and_then(Value::as_str).unwrap_or("");
        let prefix = if multiple { format!("{model_name} ") } else { String::new() };
        let interval_remaining = m.get("current_interval_remaining_percent").and_then(Value::as_i64).unwrap_or(0) as i32;
        let weekly_remaining = m.get("current_weekly_remaining_percent").and_then(Value::as_i64).unwrap_or(0) as i32;
        let interval_reset = m.get("end_time").and_then(Value::as_i64).filter(|ms| *ms > 0).map(|ms| ms / 1000);
        let weekly_reset = m.get("weekly_end_time").and_then(Value::as_i64).filter(|ms| *ms > 0).map(|ms| ms / 1000);
        windows.push(QuotaWindow {
            label: format!("{prefix}5 giờ"),
            used_pct: 100 - interval_remaining,
            remaining_pct: interval_remaining,
            subtitle: None,
            resets_at: interval_reset,
            window_seconds: None,
        });
        windows.push(QuotaWindow {
            label: format!("{prefix}Tuần"),
            used_pct: 100 - weekly_remaining,
            remaining_pct: weekly_remaining,
            subtitle: None,
            resets_at: weekly_reset,
            window_seconds: None,
        });
    }

    // Best-effort subscription expiry/renewal window.
    if let Some(expires_ms) = body.get("current_subscribe_end_time_ts").and_then(Value::as_i64).filter(|ms| *ms > 0) {
        let renews_ms = body.get("renewal_trigger_time_ts").and_then(Value::as_i64).filter(|ms| *ms > 0);
        let sub_label = if renews_ms.is_some() { "Gia hạn" } else { "Hết hạn" };
        let resets_at = renews_ms.unwrap_or(expires_ms) / 1000;
        windows.push(QuotaWindow {
            label: sub_label.into(),
            used_pct: 0,
            remaining_pct: 100,
            subtitle: None,
            resets_at: Some(resets_at),
            window_seconds: None,
        });
    }

    ProviderStatus {
        id: id.to_string(),
        display_name: name.to_string(),
        windows,
        last_updated: chrono::Utc::now().timestamp(),
        account_label: Some(account_label.to_string()),
        // Subscription title when the platform endpoint returns it
        // (macOS `current_subscribe_title` plan-name parity).
        plan_name: body
            .get("current_subscribe_title")
            .and_then(Value::as_str)
            .filter(|s| !s.trim().is_empty())
            .map(String::from),
        ..Default::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn single_model_uses_compact_labels() {
        let body = json!({
            "base_resp": {"status_code": 0, "status_msg": "success"},
            "model_remains": [
                {"model_name": "general", "current_interval_remaining_percent": 69, "current_weekly_remaining_percent": 96,
                 "end_time": 1_700_000_000_000i64, "weekly_end_time": 1_700_500_000_000i64}
            ]
        });
        let s = parse_remains("minimax", "MiniMax", "sk-cp-abc", &body);
        assert!(s.error.is_none());
        assert_eq!(s.windows.len(), 2);
        assert_eq!(s.windows[0].label, "5 giờ");
        assert_eq!(s.windows[0].used_pct, 31);
        assert_eq!(s.windows[1].label, "Tuần");
        assert_eq!(s.windows[1].used_pct, 4);
    }

    #[test]
    fn multiple_models_prefix_labels_and_exclude_video() {
        let body = json!({
            "base_resp": {"status_code": 0, "status_msg": "success"},
            "model_remains": [
                {"model_name": "general", "current_interval_remaining_percent": 50, "current_weekly_remaining_percent": 50},
                {"model_name": "chat", "current_interval_remaining_percent": 80, "current_weekly_remaining_percent": 90},
                {"model_name": "video", "current_interval_remaining_percent": 100, "current_weekly_remaining_percent": 100}
            ]
        });
        let s = parse_remains("minimax", "MiniMax", "sk-cp-abc", &body);
        assert_eq!(s.windows.len(), 4);
        assert_eq!(s.windows[0].label, "general 5 giờ");
        assert_eq!(s.windows[2].label, "chat 5 giờ");
    }

    #[test]
    fn nonzero_status_code_is_error() {
        let body = json!({"base_resp": {"status_code": 1004, "status_msg": "invalid api key"}, "model_remains": []});
        let s = parse_remains("minimax", "MiniMax", "x", &body);
        assert_eq!(s.error.as_deref(), Some("invalid api key"));
    }

    #[test]
    fn missing_base_resp_is_error() {
        let s = parse_remains("minimax", "MiniMax", "x", &json!({}));
        assert!(s.error.is_some());
    }

    #[test]
    fn cookie_domains_prefers_region_specific_domain_first() {
        assert_eq!(cookie_domains("io"), vec!["platform.minimax.io", "platform.minimaxi.com"]);
        assert_eq!(cookie_domains("com"), vec!["platform.minimaxi.com", "platform.minimax.io"]);
    }

    #[test]
    fn endpoint_url_uses_platform_host_for_region() {
        assert_eq!(endpoint_url("io"), "https://platform.minimax.io/v1/api/openplatform/coding_plan/remains");
        assert_eq!(endpoint_url("com"), "https://platform.minimaxi.com/v1/api/openplatform/coding_plan/remains");
    }
}
