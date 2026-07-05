//! OpenCode quota provider — port of `OpenCodeProvider.swift`.
//!
//! Authenticates via session cookies (`auth` / `__Host-auth`) scraped from
//! the user's browser for `opencode.ai`.
//!
//! Flow:
//!   1. GET  https://opencode.ai/_server?id=<workspacesServerID>
//!         -> parse workspace id ("wrk_...") from JS/JSON text
//!   2. GET  https://opencode.ai/_server?id=<subscriptionServerID>&args=[<workspaceID>]
//!         (fallback: POST with body `[<workspaceID>]`)
//!         -> text/JS containing `rollingUsage` + `weeklyUsage` objects with
//!            `usagePercent` (0-100 or 0-1) and `resetInSec` fields.
//!
//! Response shape (embedded JS object or JSON):
//! ```js
//! {
//!   rollingUsage: { usagePercent: 67.3, resetInSec: 12600 },
//!   weeklyUsage:  { usagePercent: 34.1, resetInSec: 345600 }
//! }
//! ```
//! Field names vary — the parser scans aliases for percent and reset values.

use regex::Regex;
use serde_json::Value;

use crate::providers::browser_cookies;
use crate::providers::{display_name, ProviderStatus, QuotaWindow};

const BASE_URL: &str = "https://opencode.ai";
const SERVER_URL: &str = "https://opencode.ai/_server";
const WORKSPACES_SERVER_ID: &str = "def39973159c7f0483d8793a822b8dbb10d067e12c65455fcb4608459ba0234f";
const SUBSCRIPTION_SERVER_ID: &str = "7abeebee372f304e050aaaf92be863f4a86490e382f8c79db68fd94040d691b4";
const USER_AGENT: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36";
const ALLOWED_COOKIE_NAMES: &[&str] = &["auth", "__Host-auth"];

pub async fn fetch(cfg: &crate::config::Provider) -> ProviderStatus {
    let name = display_name(cfg);
    let id = cfg.id.clone();
    let cfg_clone = cfg.clone();

    let raw_header = match tauri::async_runtime::spawn_blocking(move || {
        browser_cookies::cookie_header(&["opencode.ai"], &cfg_clone)
    })
    .await
    {
        Ok(Ok(h)) => h,
        Ok(Err(e)) => return ProviderStatus::failure(&id, &name, e),
        Err(_) => return ProviderStatus::failure(&id, &name, "Lỗi nội bộ khi đọc cookie"),
    };

    let Some(cookie_header) = filtered_cookie_header(&raw_header) else {
        return ProviderStatus::failure(
            &id,
            &name,
            "Không tìm thấy cookie đăng nhập OpenCode (cần auth hoặc __Host-auth)",
        );
    };

    let client = crate::providers::shared_client();

    let workspace_id = match fetch_workspace_id(&client, &cookie_header).await {
        Ok(w) => w,
        Err(e) => return ProviderStatus::failure(&id, &name, format!("Không lấy được workspace: {e}")),
    };

    let text = match fetch_subscription(&client, &workspace_id, &cookie_header).await {
        Ok(t) => t,
        Err(e) => return ProviderStatus::failure(&id, &name, format!("Không lấy được usage: {e}")),
    };

    match parse_subscription(&text) {
        Ok(snap) => build_status(&id, &name, &snap),
        Err(e) => ProviderStatus::failure(&id, &name, e),
    }
}

async fn fetch_workspace_id(client: &reqwest::Client, cookie_header: &str) -> Result<String, String> {
    let text = fetch_server_text(client, WORKSPACES_SERVER_ID, None, "GET", BASE_URL, cookie_header).await?;
    if looks_signed_out(&text) {
        return Err("chưa đăng nhập".to_string());
    }
    let mut ids = parse_workspace_ids(&text);
    if ids.is_empty() {
        let fallback = fetch_server_text(client, WORKSPACES_SERVER_ID, Some("[]"), "POST", BASE_URL, cookie_header).await?;
        if looks_signed_out(&fallback) {
            return Err("chưa đăng nhập".to_string());
        }
        ids = parse_workspace_ids(&fallback);
    }
    ids.into_iter().next().ok_or_else(|| "không tìm thấy workspace".to_string())
}

async fn fetch_subscription(client: &reqwest::Client, workspace_id: &str, cookie_header: &str) -> Result<String, String> {
    let referer = format!("{BASE_URL}/workspace/{workspace_id}/billing");
    let args = serde_json::to_string(&[workspace_id]).unwrap_or_default();

    let text = fetch_server_text(client, SUBSCRIPTION_SERVER_ID, Some(&args), "GET", &referer, cookie_header).await?;
    if looks_signed_out(&text) {
        return Err("chưa đăng nhập".to_string());
    }
    if !has_usage_fields(&text) {
        let fallback = fetch_server_text(client, SUBSCRIPTION_SERVER_ID, Some(&args), "POST", &referer, cookie_header).await?;
        if looks_signed_out(&fallback) {
            return Err("chưa đăng nhập".to_string());
        }
        return Ok(fallback);
    }
    Ok(text)
}

async fn fetch_server_text(
    client: &reqwest::Client,
    server_id: &str,
    args: Option<&str>,
    method: &str,
    referer: &str,
    cookie_header: &str,
) -> Result<String, String> {
    let is_get = method.eq_ignore_ascii_case("GET");
    let url = server_url(server_id, args, is_get);

    let builder = if is_get {
        client.get(&url)
    } else {
        client.post(&url)
    };
    let mut builder = builder
        .header("Cookie", cookie_header)
        .header("X-Server-Id", server_id)
        .header("X-Server-Instance", format!("server-fn:{}", uuid_like()))
        .header("User-Agent", USER_AGENT)
        .header("Origin", BASE_URL)
        .header("Referer", referer)
        .header("Accept", "text/javascript, application/json;q=0.9, */*;q=0.8");
    if !is_get {
        if let Some(a) = args {
            builder = builder.header("Content-Type", "application/json").body(a.to_string());
        }
    }

    let resp = builder.send().await.map_err(|e| format!("network: {e}"))?;
    let status = resp.status();
    if status.as_u16() == 401 || status.as_u16() == 403 {
        return Err("chưa đăng nhập".to_string());
    }
    if !status.is_success() {
        return Err(format!("HTTP {}", status.as_u16()));
    }
    resp.text().await.map_err(|e| format!("network: {e}"))
}

fn server_url(server_id: &str, args: Option<&str>, is_get: bool) -> String {
    if !is_get {
        return SERVER_URL.to_string();
    }
    let mut url = format!("{SERVER_URL}?id={}", urlencoding_encode(server_id));
    if let Some(a) = args {
        if !a.is_empty() {
            url.push_str(&format!("&args={}", urlencoding_encode(a)));
        }
    }
    url
}

/// Minimal percent-encoder for query values (no external dep needed for the
/// narrow character set our args/ids ever contain).
fn urlencoding_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => out.push(b as char),
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

fn uuid_like() -> String {
    format!("{:x}-{:x}", chrono::Utc::now().timestamp_nanos_opt().unwrap_or(0), std::process::id())
}

fn looks_signed_out(text: &str) -> bool {
    let lower = text.to_lowercase();
    lower.contains("login")
        || lower.contains("sign in")
        || lower.contains("auth/authorize")
        || lower.contains("actor of type \"public\"")
}

fn has_usage_fields(text: &str) -> bool {
    text.contains("rollingUsage") || text.contains("rolling_usage") || text.contains("weeklyUsage") || text.contains("weekly_usage")
}

fn parse_workspace_ids(text: &str) -> Vec<String> {
    let re = Regex::new(r#"id\s*:\s*"(wrk_[^"]+)""#).unwrap();
    let mut ids: Vec<String> = re.captures_iter(text).filter_map(|c| c.get(1).map(|m| m.as_str().to_string())).collect();
    if ids.is_empty() {
        if let Ok(v) = serde_json::from_str::<Value>(text) {
            let mut collected = Vec::new();
            collect_workspace_ids(&v, &mut collected);
            ids = collected;
        }
    }
    ids
}

fn collect_workspace_ids(v: &Value, out: &mut Vec<String>) {
    match v {
        Value::Object(map) => {
            for val in map.values() {
                collect_workspace_ids(val, out);
            }
        }
        Value::Array(arr) => {
            for val in arr {
                collect_workspace_ids(val, out);
            }
        }
        Value::String(s) if s.starts_with("wrk_") && !out.contains(s) => out.push(s.clone()),
        _ => {}
    }
}

fn filtered_cookie_header(raw: &str) -> Option<String> {
    let pairs: Vec<String> = raw
        .split(';')
        .filter_map(|chunk| {
            let t = chunk.trim();
            let eq = t.find('=')?;
            let name = t[..eq].trim();
            let value = t[eq + 1..].trim();
            if name.is_empty() || value.is_empty() || !ALLOWED_COOKIE_NAMES.contains(&name) {
                return None;
            }
            Some(format!("{name}={value}"))
        })
        .collect();
    if pairs.is_empty() {
        None
    } else {
        Some(pairs.join("; "))
    }
}

struct Snapshot {
    rolling_percent: f64,
    weekly_percent: f64,
    rolling_reset_sec: i64,
    weekly_reset_sec: i64,
    renews_at: Option<i64>,
}

const PERCENT_KEYS: &[&str] = &["usagePercent", "usedPercent", "percentUsed", "percent", "usage_percent", "utilization"];
const RESET_IN_KEYS: &[&str] = &["resetInSec", "resetInSeconds", "resetSec", "reset_sec", "resetsInSec", "resetIn"];
const RESET_AT_KEYS: &[&str] = &["resetAt", "resetsAt", "reset_at", "nextReset", "renewAt"];
const RENEW_KEYS: &[&str] = &["renewAt", "renewsAt", "renew_at", "renews_at"];
const ROLLING_KEYS: &[&str] = &["rollingUsage", "rolling", "rolling_usage", "rollingWindow"];
const WEEKLY_KEYS: &[&str] = &["weeklyUsage", "weekly", "weekly_usage", "weeklyWindow"];

/// Pure text → Snapshot parser (unit-tested). Mirrors Swift's JSON-first,
/// regex-fallback strategy.
fn parse_subscription(text: &str) -> Result<Snapshot, String> {
    if let Some(snap) = parse_json_usage(text) {
        return Ok(snap);
    }

    let rolling_pct = extract_double(text, r"rollingUsage[^}]*?usagePercent\s*:\s*([0-9]+(?:\.[0-9]+)?)")
        .ok_or_else(|| "Không thể phân tích dữ liệu usage OpenCode".to_string())?;
    let rolling_reset = extract_int(text, r"rollingUsage[^}]*?resetInSec\s*:\s*([0-9]+)")
        .ok_or_else(|| "Không thể phân tích dữ liệu usage OpenCode".to_string())?;
    let weekly_pct = extract_double(text, r"weeklyUsage[^}]*?usagePercent\s*:\s*([0-9]+(?:\.[0-9]+)?)")
        .ok_or_else(|| "Không thể phân tích dữ liệu usage OpenCode".to_string())?;
    let weekly_reset = extract_int(text, r"weeklyUsage[^}]*?resetInSec\s*:\s*([0-9]+)")
        .ok_or_else(|| "Không thể phân tích dữ liệu usage OpenCode".to_string())?;

    Ok(Snapshot {
        rolling_percent: normalize_percent(rolling_pct),
        weekly_percent: normalize_percent(weekly_pct),
        rolling_reset_sec: rolling_reset,
        weekly_reset_sec: weekly_reset,
        renews_at: None,
    })
}

fn parse_json_usage(text: &str) -> Option<Snapshot> {
    let v: Value = serde_json::from_str(text).ok()?;
    let dict = v.as_object()?;
    if let Some(snap) = parse_usage_dict(dict) {
        return Some(snap);
    }
    for key in ["data", "result", "usage", "billing", "payload"] {
        if let Some(nested) = dict.get(key).and_then(Value::as_object) {
            if let Some(snap) = parse_usage_dict(nested) {
                return Some(snap);
            }
        }
    }
    None
}

fn parse_usage_dict(dict: &serde_json::Map<String, Value>) -> Option<Snapshot> {
    let rolling = first_dict(dict, ROLLING_KEYS)?;
    let weekly = first_dict(dict, WEEKLY_KEYS)?;
    let rolling_win = parse_window(rolling)?;
    let weekly_win = parse_window(weekly)?;
    let renews_at = RENEW_KEYS.iter().find_map(|k| dict.get(*k).and_then(date_value));
    Some(Snapshot {
        rolling_percent: rolling_win.0,
        weekly_percent: weekly_win.0,
        rolling_reset_sec: rolling_win.1,
        weekly_reset_sec: weekly_win.1,
        renews_at,
    })
}

fn first_dict<'a>(dict: &'a serde_json::Map<String, Value>, keys: &[&str]) -> Option<&'a serde_json::Map<String, Value>> {
    keys.iter().find_map(|k| dict.get(*k).and_then(Value::as_object))
}

fn parse_window(dict: &serde_json::Map<String, Value>) -> Option<(f64, i64)> {
    let mut pct = PERCENT_KEYS.iter().find_map(|k| dict.get(*k).and_then(double_value));
    if pct.is_none() {
        let used = dict.get("used").or_else(|| dict.get("usage")).and_then(double_value);
        let limit = dict.get("limit").or_else(|| dict.get("total")).and_then(double_value);
        if let (Some(u), Some(l)) = (used, limit) {
            if l > 0.0 {
                pct = Some(u / l * 100.0);
            }
        }
    }
    let resolved_pct = normalize_percent(pct?);

    let mut reset_sec = RESET_IN_KEYS.iter().find_map(|k| dict.get(*k).and_then(int_value));
    if reset_sec.is_none() {
        reset_sec = RESET_AT_KEYS.iter().find_map(|k| {
            date_value(dict.get(*k)?).map(|d| (d - chrono::Utc::now().timestamp()).max(0))
        });
    }
    Some((resolved_pct, reset_sec.unwrap_or(0).max(0)))
}

fn normalize_percent(v: f64) -> f64 {
    let scaled = if (0.0..=1.0).contains(&v) { v * 100.0 } else { v };
    scaled.clamp(0.0, 100.0)
}

fn double_value(v: &Value) -> Option<f64> {
    match v {
        Value::Number(n) => n.as_f64(),
        Value::String(s) => s.trim().parse().ok(),
        _ => None,
    }
}

fn int_value(v: &Value) -> Option<i64> {
    match v {
        Value::Number(n) => n.as_i64(),
        Value::String(s) => s.trim().parse().ok(),
        _ => None,
    }
}

fn date_value(v: &Value) -> Option<i64> {
    if let Some(d) = double_value(v) {
        if d > 1_000_000_000_000.0 {
            return Some((d / 1000.0) as i64);
        }
        if d > 1_000_000_000.0 {
            return Some(d as i64);
        }
    }
    if let Value::String(s) = v {
        if let Ok(dt) = chrono::DateTime::parse_from_rfc3339(s) {
            return Some(dt.timestamp());
        }
    }
    None
}

fn extract_double(text: &str, pattern: &str) -> Option<f64> {
    Regex::new(pattern).ok()?.captures(text)?.get(1)?.as_str().parse().ok()
}

fn extract_int(text: &str, pattern: &str) -> Option<i64> {
    Regex::new(pattern).ok()?.captures(text)?.get(1)?.as_str().parse().ok()
}

fn build_status(id: &str, name: &str, snap: &Snapshot) -> ProviderStatus {
    let now = chrono::Utc::now().timestamp();
    let rolling_used = (snap.rolling_percent.round() as i32).clamp(0, 100);
    let weekly_used = (snap.weekly_percent.round() as i32).clamp(0, 100);

    let mut windows = vec![
        QuotaWindow {
            label: "Rolling".into(),
            used_pct: rolling_used,
            remaining_pct: 100 - rolling_used,
            subtitle: Some(format!("{rolling_used}%")),
            resets_at: Some(now + snap.rolling_reset_sec),
        },
        QuotaWindow {
            label: "Tuần".into(),
            used_pct: weekly_used,
            remaining_pct: 100 - weekly_used,
            subtitle: Some(format!("{weekly_used}%")),
            resets_at: Some(now + snap.weekly_reset_sec),
        },
    ];

    if let Some(renew) = snap.renews_at {
        windows.push(QuotaWindow {
            label: "Gia hạn".into(),
            used_pct: 0,
            remaining_pct: 100,
            subtitle: None,
            resets_at: Some(renew),
        });
    }

    ProviderStatus {
        id: id.to_string(),
        display_name: name.to_string(),
        windows,
        last_updated: now,
        ..Default::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_json_subscription() {
        let text = r#"{"rollingUsage":{"usagePercent":67.3,"resetInSec":12600},"weeklyUsage":{"usagePercent":34.1,"resetInSec":345600}}"#;
        let snap = parse_subscription(text).unwrap();
        assert!((snap.rolling_percent - 67.3).abs() < 0.01);
        assert_eq!(snap.weekly_reset_sec, 345600);
    }

    #[test]
    fn parses_regex_fallback_js_object() {
        let text = "const x = { rollingUsage: { usagePercent: 67.3, resetInSec: 12600 }, weeklyUsage: { usagePercent: 34.1, resetInSec: 345600 } }";
        let snap = parse_subscription(text).unwrap();
        assert!((snap.weekly_percent - 34.1).abs() < 0.01);
        assert_eq!(snap.rolling_reset_sec, 12600);
    }

    #[test]
    fn missing_fields_is_error() {
        assert!(parse_subscription("{}").is_err());
    }

    #[test]
    fn workspace_ids_parsed_from_js_text() {
        let text = r#"const w = { id: "wrk_abc123", name: "test" }"#;
        let ids = parse_workspace_ids(text);
        assert_eq!(ids, vec!["wrk_abc123".to_string()]);
    }

    #[test]
    fn filters_cookie_header_to_allowed_names() {
        let raw = "auth=abc123; unrelated=xyz; __Host-auth=def456";
        let header = filtered_cookie_header(raw).unwrap();
        assert!(header.contains("auth=abc123"));
        assert!(!header.contains("unrelated"));
    }

    #[test]
    fn no_allowed_cookie_returns_none() {
        assert!(filtered_cookie_header("unrelated=xyz").is_none());
    }
}
