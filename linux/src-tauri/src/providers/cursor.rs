//! Cursor quota provider — port of `CursorProvider.swift`.
//!
//! Auth priority:
//!   1. Cursor's local SQLite state DB (`cursorAuth/accessToken` key in
//!      `ItemTable`), read-only. Linux path mirrors macOS's Electron layout:
//!      macOS:  ~/Library/Application Support/Cursor/User/globalStorage/state.vscdb
//!      Linux:  ~/.config/Cursor/User/globalStorage/state.vscdb
//!   2. Browser cookies for cursor.com (`WorkosCursorSessionToken`).
//!
//! Endpoints (base `https://cursor.com`):
//!   GET /api/usage-summary          (required)
//!   GET /api/auth/me                (best-effort, parallel)
//!   GET /api/usage?user=<sub>       (legacy, only if sub known)

use serde::Deserialize;
use serde_json::Value;

use crate::providers::browser_cookies;
use crate::providers::{display_name, ProviderStatus, QuotaWindow};

const USAGE_SUMMARY_URL: &str = "https://cursor.com/api/usage-summary";
const AUTH_ME_URL: &str = "https://cursor.com/api/auth/me";
const USAGE_URL: &str = "https://cursor.com/api/usage";

pub async fn fetch(cfg: &crate::config::Provider) -> ProviderStatus {
    let name = display_name(cfg);
    let id = cfg.id.clone();
    let cfg_clone = cfg.clone();

    let cookie_header = match tauri::async_runtime::spawn_blocking(move || resolve_cookie_header(&cfg_clone)).await {
        Ok(Ok(h)) => h,
        Ok(Err(e)) => return ProviderStatus::failure(&id, &name, e),
        Err(_) => return ProviderStatus::failure(&id, &name, "Lỗi nội bộ khi đọc cookie"),
    };

    let client = crate::providers::shared_client();

    let usage_summary_resp = client.get(USAGE_SUMMARY_URL).header("Cookie", &cookie_header).send().await;
    let usage_summary_text = match usage_summary_resp {
        Ok(resp) if resp.status().is_success() => match resp.text().await {
            Ok(t) => t,
            Err(e) => return ProviderStatus::failure(&id, &name, format!("Lỗi mạng Cursor: {e}")),
        },
        Ok(resp) if resp.status().as_u16() == 401 || resp.status().as_u16() == 403 => {
            return ProviderStatus::failure(&id, &name, "Chưa đăng nhập Cursor (mở app Cursor hoặc đăng nhập cursor.com)")
        }
        Ok(resp) => return ProviderStatus::failure(&id, &name, format!("Lỗi mạng Cursor: HTTP {}", resp.status().as_u16())),
        Err(e) => return ProviderStatus::failure(&id, &name, format!("Lỗi mạng Cursor: {e}")),
    };

    // Best-effort /auth/me for sub (drives the legacy /api/usage call).
    let auth_me_resp = client.get(AUTH_ME_URL).header("Cookie", &cookie_header).send().await.ok().filter(|r| r.status().is_success());
    let user_info: Option<CursorUserInfo> = match auth_me_resp {
        Some(resp) => resp.json::<CursorUserInfo>().await.ok(),
        None => None,
    };

    // Best-effort legacy request-based usage (only fetched when sub is known).
    let request_usage_text: Option<String> = if let Some(sub) = user_info.as_ref().and_then(|u| u.sub.as_deref()) {
        let url = format!("{USAGE_URL}?user={sub}");
        match client.get(&url).header("Cookie", &cookie_header).send().await {
            Ok(resp) if resp.status().is_success() => resp.text().await.ok(),
            _ => None,
        }
    } else {
        None
    };

    match parse_status(&id, &name, &usage_summary_text, request_usage_text.as_deref()) {
        Ok(status) => status,
        Err(e) => ProviderStatus::failure(&id, &name, format!("Lỗi phân tích dữ liệu Cursor: {e}")),
    }
}

fn resolve_cookie_header(cfg: &crate::config::Provider) -> Result<String, String> {
    if let Some(token) = read_token_from_sqlite() {
        if let Some(header) = build_session_cookie(&token) {
            return Ok(header);
        }
    }
    browser_cookies::cookie_header(&["cursor.com"], cfg)
        .map_err(|_| "Chưa đăng nhập Cursor (mở app Cursor hoặc đăng nhập cursor.com)".to_string())
}

fn cursor_state_db_path() -> Option<std::path::PathBuf> {
    let home = std::env::var("HOME").ok()?;
    let path = std::path::PathBuf::from(home).join(".config/Cursor/User/globalStorage/state.vscdb");
    if path.exists() {
        Some(path)
    } else {
        None
    }
}

fn read_token_from_sqlite() -> Option<String> {
    let path = cursor_state_db_path()?;
    let uri = format!("file:{}?immutable=1&mode=ro", path.to_string_lossy());
    let flags = rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_URI;
    let conn = rusqlite::Connection::open_with_flags(&uri, flags).ok()?;
    let _ = conn.busy_timeout(std::time::Duration::from_millis(200));
    conn.query_row("SELECT value FROM ItemTable WHERE key = ? LIMIT 1;", ["cursorAuth/accessToken"], |row| row.get::<_, String>(0))
        .ok()
}

/// Builds `WorkosCursorSessionToken=<userID>::<token>` (`::` percent-encoded
/// as `%3A%3A`) by decoding the JWT payload's `sub` claim.
fn build_session_cookie(token: &str) -> Option<String> {
    let user_id = extract_user_id(token)?;
    Some(format!("WorkosCursorSessionToken={user_id}%3A%3A{token}"))
}

fn extract_user_id(token: &str) -> Option<String> {
    let mut parts = token.split('.');
    parts.next()?;
    let payload_b64 = parts.next()?;
    let payload_json = decode_base64url(payload_b64)?;
    let v: Value = serde_json::from_slice(&payload_json).ok()?;
    let sub = v.get("sub")?.as_str()?;
    let user_id = sub.rsplit('|').next().unwrap_or(sub);
    let valid = user_id.chars().all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '_' || c == '-');
    if valid && !user_id.is_empty() {
        Some(user_id.to_string())
    } else {
        None
    }
}

fn decode_base64url(s: &str) -> Option<Vec<u8>> {
    use base64::Engine;
    let mut normalized = s.replace('-', "+").replace('_', "/");
    while normalized.len() % 4 != 0 {
        normalized.push('=');
    }
    base64::engine::general_purpose::STANDARD.decode(normalized).ok()
}

// Note: Swift's CursorUsageSummary also carries billingCycleStart/End, but
// Rust's ProviderStatus/QuotaWindow has no field to surface them in, so they
// are intentionally not deserialized here.
#[derive(Deserialize, Debug, Default)]
struct CursorUsageSummary {
    #[serde(rename = "membershipType")]
    membership_type: Option<String>,
    #[serde(rename = "individualUsage")]
    individual_usage: Option<CursorIndividualUsage>,
    #[serde(rename = "teamUsage")]
    team_usage: Option<CursorTeamUsage>,
}

#[derive(Deserialize, Debug, Default)]
struct CursorIndividualUsage {
    plan: Option<CursorPlanUsage>,
    #[serde(rename = "onDemand")]
    on_demand: Option<CursorOnDemandUsage>,
    overall: Option<CursorOverallUsage>,
}

#[derive(Deserialize, Debug, Default, Clone)]
struct CursorPlanUsage {
    used: Option<f64>,
    limit: Option<f64>,
    #[serde(rename = "autoPercentUsed")]
    auto_percent_used: Option<f64>,
    #[serde(rename = "apiPercentUsed")]
    api_percent_used: Option<f64>,
    #[serde(rename = "totalPercentUsed")]
    total_percent_used: Option<f64>,
}

#[derive(Deserialize, Debug, Default, Clone)]
struct CursorOnDemandUsage {
    used: Option<f64>,
    limit: Option<f64>,
}

#[derive(Deserialize, Debug, Default, Clone)]
struct CursorOverallUsage {
    used: Option<f64>,
    limit: Option<f64>,
}

#[derive(Deserialize, Debug, Default)]
struct CursorTeamUsage {
    #[serde(rename = "onDemand")]
    on_demand: Option<CursorOnDemandUsage>,
    pooled: Option<CursorPooledUsage>,
}

#[derive(Deserialize, Debug, Default, Clone)]
struct CursorPooledUsage {
    used: Option<f64>,
    limit: Option<f64>,
}

#[derive(Deserialize, Debug, Default)]
struct CursorUsageResponse {
    #[serde(rename = "gpt-4")]
    gpt4: Option<CursorModelUsage>,
}

#[derive(Deserialize, Debug, Default)]
struct CursorModelUsage {
    #[serde(rename = "maxRequestUsage")]
    max_request_usage: Option<f64>,
    #[serde(rename = "numRequests")]
    num_requests: Option<f64>,
}

#[derive(Deserialize, Debug, Default)]
struct CursorUserInfo {
    #[allow(dead_code)]
    email: Option<String>,
    sub: Option<String>,
}

fn membership_label(membership_type: Option<&str>) -> String {
    match membership_type.map(str::to_lowercase).as_deref() {
        Some("enterprise") => "Cursor Enterprise".to_string(),
        Some("pro") => "Cursor Pro".to_string(),
        Some("hobby") => "Cursor Hobby".to_string(),
        Some("team") => "Cursor Team".to_string(),
        Some(other) if !other.is_empty() => {
            let mut chars = other.chars();
            let cap = match chars.next() {
                Some(c) => c.to_uppercase().collect::<String>() + chars.as_str(),
                None => other.to_string(),
            };
            format!("Cursor {cap}")
        }
        _ => "Cursor".to_string(),
    }
}

fn parse_status(id: &str, name: &str, usage_summary_json: &str, request_usage_json: Option<&str>) -> Result<ProviderStatus, String> {
    let summary: CursorUsageSummary = serde_json::from_str(usage_summary_json).map_err(|e| e.to_string())?;
    let mut windows = Vec::new();

    let plan = summary.individual_usage.as_ref().and_then(|u| u.plan.clone());
    let overall = summary.individual_usage.as_ref().and_then(|u| u.overall.clone());
    let pooled = summary.team_usage.as_ref().and_then(|t| t.pooled.clone());

    // Primary window: Total (when auto/api percent present) else Plan.
    if let Some(p) = &plan {
        let has_auto_api = p.auto_percent_used.is_some() || p.api_percent_used.is_some();
        let label = if has_auto_api { "Total" } else { "Plan" };
        let pct = p.total_percent_used.or(p.auto_percent_used).or(p.api_percent_used).unwrap_or_else(|| {
            match (p.used, p.limit) {
                (Some(u), Some(l)) if l > 0.0 => (u / l * 100.0).clamp(0.0, 100.0),
                _ => 0.0,
            }
        });
        windows.push(pct_window(label, pct, subtitle_used_limit(p.used, p.limit)));
    } else if let Some(o) = &overall {
        let pct = match (o.used, o.limit) {
            (Some(u), Some(l)) if l > 0.0 => (u / l * 100.0).clamp(0.0, 100.0),
            _ => 0.0,
        };
        windows.push(pct_window("Plan", pct, subtitle_used_limit(o.used, o.limit)));
    } else if let Some(pool) = &pooled {
        let pct = match (pool.used, pool.limit) {
            (Some(u), Some(l)) if l > 0.0 => (u / l * 100.0).clamp(0.0, 100.0),
            _ => 0.0,
        };
        windows.push(pct_window("Plan", pct, subtitle_used_limit(pool.used, pool.limit)));
    }

    if let Some(p) = &plan {
        if let Some(auto) = p.auto_percent_used {
            windows.push(pct_window("Auto", auto, None));
        }
        if let Some(api) = p.api_percent_used {
            windows.push(pct_window("API", api, None));
        }
    }

    // On-demand: prefer individual over team pooled.
    let od = summary.individual_usage.as_ref().and_then(|u| u.on_demand.clone())
        .or_else(|| summary.team_usage.as_ref().and_then(|t| t.on_demand.clone()));
    if let Some(od) = od {
        let used = od.used.unwrap_or(0.0);
        let limit = od.limit.unwrap_or(0.0);
        if used > 0.0 || limit > 0.0 {
            let pct = if limit > 0.0 { (used / limit * 100.0).clamp(0.0, 100.0) } else { 0.0 };
            windows.push(pct_window("On-demand", pct, subtitle_used_limit(Some(used), Some(limit))));
        }
    }

    if let Some(text) = request_usage_json {
        if let Ok(usage) = serde_json::from_str::<CursorUsageResponse>(text) {
            if let Some(gpt4) = usage.gpt4 {
                let max_req = gpt4.max_request_usage.unwrap_or(0.0);
                if max_req > 0.0 {
                    let used = gpt4.num_requests.unwrap_or(0.0);
                    let pct = (used / max_req * 100.0).clamp(0.0, 100.0);
                    windows.push(pct_window("Yêu cầu", pct, Some(format!("{used:.0} / {max_req:.0} requests"))));
                }
            }
        }
    }

    Ok(ProviderStatus {
        id: id.to_string(),
        display_name: name.to_string(),
        windows,
        last_updated: chrono::Utc::now().timestamp(),
        error: None,
        account_label: Some(membership_label(summary.membership_type.as_deref())),
        credits_remaining: None,
    })
}

fn pct_window(label: &str, pct: f64, subtitle: Option<String>) -> QuotaWindow {
    let used = pct.round().clamp(0.0, 100.0) as i32;
    QuotaWindow {
        label: label.to_string(),
        used_pct: used,
        remaining_pct: 100 - used,
        subtitle,
        resets_at: None,
    }
}

fn subtitle_used_limit(used: Option<f64>, limit: Option<f64>) -> Option<String> {
    match (used, limit) {
        (Some(u), Some(l)) => Some(format!("${u:.2} / ${l:.2}")),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_plan_usage_with_total_label() {
        let summary = r#"{"membershipType":"pro","individualUsage":{"plan":{"used":10.0,"limit":20.0,"totalPercentUsed":50.0}}}"#;
        let status = parse_status("cursor", "Cursor", summary, None).unwrap();
        assert_eq!(status.windows[0].label, "Plan");
        assert_eq!(status.windows[0].used_pct, 50);
    }

    #[test]
    fn total_label_used_when_auto_or_api_present() {
        let summary = r#"{"membershipType":"pro","individualUsage":{"plan":{"used":10.0,"limit":20.0,"autoPercentUsed":30.0,"apiPercentUsed":10.0}}}"#;
        let status = parse_status("cursor", "Cursor", summary, None).unwrap();
        assert_eq!(status.windows[0].label, "Total");
        assert!(status.windows.iter().any(|w| w.label == "Auto"));
        assert!(status.windows.iter().any(|w| w.label == "API"));
    }

    #[test]
    fn on_demand_window_added_when_used_positive() {
        let summary = r#"{"individualUsage":{"plan":{"used":1.0,"limit":10.0},"onDemand":{"used":5.0,"limit":50.0}}}"#;
        let status = parse_status("cursor", "Cursor", summary, None).unwrap();
        assert!(status.windows.iter().any(|w| w.label == "On-demand"));
    }

    #[test]
    fn legacy_request_window_added_when_max_positive() {
        let summary = r#"{"individualUsage":{"plan":{"used":1.0,"limit":10.0}}}"#;
        let request = r#"{"gpt-4":{"maxRequestUsage":100.0,"numRequests":42.0}}"#;
        let status = parse_status("cursor", "Cursor", summary, Some(request)).unwrap();
        assert!(status.windows.iter().any(|w| w.label == "Yêu cầu"));
    }

    #[test]
    fn membership_label_formats_known_types() {
        assert_eq!(membership_label(Some("pro")), "Cursor Pro");
        assert_eq!(membership_label(Some("enterprise")), "Cursor Enterprise");
        assert_eq!(membership_label(Some("custom")), "Cursor Custom");
    }

    #[test]
    fn extract_user_id_from_jwt_sub_claim() {
        // header {"alg":"none"} . payload {"sub":"org|user_abc123"} . (no sig needed for decode)
        let payload = base64_url_encode(br#"{"sub":"org|user_abc123"}"#);
        let token = format!("eyJhbGciOiJub25lIn0.{payload}.sig");
        let id = extract_user_id(&token).unwrap();
        assert_eq!(id, "user_abc123");
    }

    fn base64_url_encode(bytes: &[u8]) -> String {
        use base64::Engine;
        base64::engine::general_purpose::STANDARD
            .encode(bytes)
            .replace('+', "-")
            .replace('/', "_")
            .trim_end_matches('=')
            .to_string()
    }
}
