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

pub async fn fetch(cfg: &crate::config::Provider) -> ProviderStatus {
    let name = display_name(cfg);
    let id = cfg.id.clone();
    let cfg_clone = cfg.clone();

    let raw_header = match tauri::async_runtime::spawn_blocking(move || {
        browser_cookies::cookie_header(&["freemodel.dev"], &cfg_clone)
    })
    .await
    {
        Ok(Ok(h)) => h,
        Ok(Err(e)) => return ProviderStatus::failure(&id, &name, e),
        Err(_) => return ProviderStatus::failure(&id, &name, "Lỗi nội bộ khi đọc cookie"),
    };

    let Some(cookie_header) = filtered_cookie_header(&raw_header) else {
        return ProviderStatus::failure(&id, &name, "Chưa đăng nhập FreeModel trên trình duyệt");
    };

    let client = crate::providers::shared_client();
    let resp = client.get(USAGE_URL).header("Cookie", &cookie_header).send().await;

    let body = match resp {
        Ok(r) if r.status().is_success() => match r.text().await {
            Ok(t) => t,
            Err(e) => return ProviderStatus::failure(&id, &name, format!("Network: {e}")),
        },
        Ok(r) => return ProviderStatus::failure(&id, &name, format!("Network: HTTP {}", r.status().as_u16())),
        Err(e) => return ProviderStatus::failure(&id, &name, format!("Network: {e}")),
    };

    match parse_status(&id, &name, &body) {
        Ok(status) => status,
        Err(e) => ProviderStatus::failure(&id, &name, e),
    }
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

    Ok(QuotaWindow {
        label: label.to_string(),
        used_pct: pct,
        remaining_pct: 100 - pct,
        subtitle: Some(format!("${used_usd:.2} / ${limit_usd:.2}")),
        resets_at,
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
