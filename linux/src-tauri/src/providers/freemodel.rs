//! FreeModel quota provider — port of `FreemodelProvider.swift`.
//!
//! Session cookie is Akamai's `bm_session`. Endpoints (base
//! `https://freemodel.dev`):
//!   GET /api/usage    (required) -> { "window5h": {...}, "windowWeek": {...} }
//!   GET /api/auth/me  (best-effort, not required for the quota windows)

use serde_json::Value;

use crate::providers::browser_cookies;
use crate::providers::{display_name, ProviderStatus, QuotaWindow};

const USAGE_URL: &str = "https://freemodel.dev/api/usage";
const ME_URL: &str = "https://freemodel.dev/api/auth/me";
/// Akamai bot-manager session cookie the budgets are gated on. Passed as the
/// REQUIRED cookie so the browser scan skips browsers that only hold stale
/// analytics/Stripe cookies and keeps looking for the signed-in one (macOS
/// `ProviderCookieReader.resolvedCookieHeader(requiredCookie:)` parity).
const SESSION_COOKIE: &str = "bm_session";
/// freemodel.dev sits behind Akamai — send browser-like headers or the
/// session cookie is rejected (macOS sends the same set).
const USER_AGENT: &str = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 \
    (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36";
const ORIGIN: &str = "https://freemodel.dev";
const REFERER: &str = "https://freemodel.dev/dashboard/usage";

pub async fn fetch(cfg: &crate::config::Provider) -> ProviderStatus {
    let name = display_name(cfg);
    let id = cfg.id.clone();
    let cfg_clone = cfg.clone();

    let raw_header = match tauri::async_runtime::spawn_blocking(move || {
        browser_cookies::cookie_header_required(&["freemodel.dev"], &cfg_clone, Some(SESSION_COOKIE))
    })
    .await
    {
        Ok(Ok(h)) => h,
        Ok(Err(_)) => return ProviderStatus::failure(&id, &name, "Chưa đăng nhập FreeModel trên trình duyệt"),
        Err(_) => return ProviderStatus::failure(&id, &name, "Lỗi nội bộ khi đọc cookie"),
    };

    let Some(cookie_header) = filtered_cookie_header(&raw_header) else {
        return ProviderStatus::failure(&id, &name, "Chưa đăng nhập FreeModel trên trình duyệt");
    };

    let client = crate::providers::shared_client();
    let resp = browser_get(&client, USAGE_URL, &cookie_header).send().await;

    let body = match resp {
        Ok(r) if r.status().is_success() => match r.text().await {
            Ok(t) => t,
            Err(e) => return ProviderStatus::failure(&id, &name, format!("Network: {e}")),
        },
        Ok(r) => return ProviderStatus::failure(&id, &name, format!("Network: HTTP {}", r.status().as_u16())),
        Err(e) => return ProviderStatus::failure(&id, &name, format!("Network: {e}")),
    };

    let mut status = match parse_status(&id, &name, &body) {
        Ok(status) => status,
        Err(e) => return ProviderStatus::failure(&id, &name, e),
    };
    // Account email — best-effort enrichment, never blocks the budgets.
    status.account_label = match cfg.account_label.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
        Some(explicit) => Some(explicit.to_string()),
        None => fetch_email(&client, &cookie_header).await,
    };
    status
}

/// GET with the browser-like header set freemodel/Akamai expects.
fn browser_get(client: &reqwest::Client, url: &str, cookie_header: &str) -> reqwest::RequestBuilder {
    client
        .get(url)
        .header("Cookie", cookie_header)
        .header("Accept", "application/json, text/plain, */*")
        .header("Accept-Language", "en-US,en;q=0.9")
        .header("User-Agent", USER_AGENT)
        .header("Origin", ORIGIN)
        .header("Referer", REFERER)
}

/// `/api/auth/me` → `{ "user": { "email": … } }` — 5s budget like macOS.
async fn fetch_email(client: &reqwest::Client, cookie_header: &str) -> Option<String> {
    let resp = browser_get(client, ME_URL, cookie_header)
        .timeout(std::time::Duration::from_secs(5))
        .send()
        .await
        .ok()?;
    if !resp.status().is_success() {
        return None;
    }
    let body: Value = resp.json().await.ok()?;
    body.get("user")
        .and_then(|u| u.get("email"))
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(String::from)
}

/// Tolerates a full `"Cookie: ..."` line prefix (case-insensitive); a bare
/// token (no `=`) wraps as `bm_session=<token>`; otherwise forwards ALL
/// cookie pairs, gated on `bm_session` being present.
fn filtered_cookie_header(raw: &str) -> Option<String> {
    let stripped = strip_cookie_prefix(raw.trim());
    if stripped.is_empty() {
        return None;
    }
    if !stripped.contains('=') {
        return Some(format!("bm_session={stripped}"));
    }

    let has_session = stripped.split(';').any(|chunk| {
        let t = chunk.trim();
        t.split('=').next().map(|n| n.trim().eq_ignore_ascii_case("bm_session")).unwrap_or(false)
    });

    if has_session {
        Some(stripped.to_string())
    } else {
        None
    }
}

fn strip_cookie_prefix(s: &str) -> &str {
    let lower = s.to_lowercase();
    if let Some(rest) = lower.strip_prefix("cookie:") {
        s[s.len() - rest.len()..].trim()
    } else {
        s
    }
}

fn parse_status(id: &str, name: &str, body: &str) -> Result<ProviderStatus, String> {
    let v: Value = serde_json::from_str(body).map_err(|_| "Response /api/usage không hợp lệ".to_string())?;

    let mut windows = Vec::new();
    if let Some(w5h) = v.get("window5h") {
        windows.push(cents_window("5 giờ", w5h)?);
    }
    if let Some(week) = v.get("windowWeek") {
        windows.push(cents_window("Tuần", week)?);
    }

    if windows.is_empty() {
        return Err("Response /api/usage không hợp lệ".to_string());
    }

    Ok(ProviderStatus {
        id: id.to_string(),
        display_name: name.to_string(),
        windows,
        last_updated: chrono::Utc::now().timestamp(),
        ..Default::default()
    })
}

fn cents_window(label: &str, window: &Value) -> Result<QuotaWindow, String> {
    let used_cents = window.get("usedCents").and_then(Value::as_f64).ok_or_else(|| "Response /api/usage không hợp lệ".to_string())?;
    let limit_cents = window.get("limitCents").and_then(Value::as_f64).ok_or_else(|| "Response /api/usage không hợp lệ".to_string())?;
    let resets_at = window.get("resetsAt").and_then(Value::as_i64).filter(|&t| t != 0);

    let used_usd = used_cents / 100.0;
    let limit_usd = limit_cents / 100.0;
    let pct = if limit_usd > 0.0 { (used_usd / limit_usd * 100.0).round().clamp(0.0, 100.0) as i32 } else { 0 };

    // Window lengths are fixed by the product (5h + weekly) — drives the
    // settings pace line, macOS windowSeconds parity.
    let window_seconds = match label {
        "5 giờ" => Some(5 * 3600),
        "Tuần" => Some(7 * 24 * 3600),
        _ => None,
    };
    Ok(QuotaWindow {
        label: label.to_string(),
        used_pct: pct,
        remaining_pct: 100 - pct,
        subtitle: Some(format!("${used_usd:.2} / ${limit_usd:.2}")),
        resets_at,
        window_seconds,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_both_windows() {
        let body = r#"{"window5h":{"usedCents":2250,"limitCents":20000,"resetsAt":1782724407},"windowWeek":{"usedCents":8,"limitCents":132000,"resetsAt":1783321795}}"#;
        let status = parse_status("freemodel", "FreeModel", body).unwrap();
        assert_eq!(status.windows.len(), 2);
        assert_eq!(status.windows[0].label, "5 giờ");
        assert_eq!(status.windows[1].label, "Tuần");
    }

    #[test]
    fn zero_resets_at_becomes_none() {
        let body = r#"{"window5h":{"usedCents":100,"limitCents":1000,"resetsAt":0}}"#;
        let status = parse_status("freemodel", "FreeModel", body).unwrap();
        assert!(status.windows[0].resets_at.is_none());
    }

    #[test]
    fn invalid_json_is_error() {
        assert!(parse_status("freemodel", "FreeModel", "not json").is_err());
    }

    #[test]
    fn bare_token_wraps_as_bm_session() {
        assert_eq!(filtered_cookie_header("abc123").unwrap(), "bm_session=abc123");
    }

    #[test]
    fn strips_cookie_prefix_line() {
        let header = filtered_cookie_header("Cookie: bm_session=xyz; other=1").unwrap();
        assert!(header.starts_with("bm_session=xyz"));
    }

    #[test]
    fn missing_bm_session_returns_none() {
        assert!(filtered_cookie_header("foo=bar; baz=qux").is_none());
    }
}
