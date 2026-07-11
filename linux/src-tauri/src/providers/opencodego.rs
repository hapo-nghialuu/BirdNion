//! OpenCode Go quota provider — port of `OpenCodeGoProvider.swift`.
//!
//! Same cookie domain/auth as OpenCode (`auth` / `__Host-auth` on opencode.ai).
//!
//! Flow:
//!   1. GET  https://opencode.ai/_server?id=<workspacesServerID>
//!         -> parse workspace id ("wrk_...")
//!   2. GET  https://opencode.ai/workspace/<workspaceID>/go
//!         -> page HTML/JS containing usage objects
//!   3. (optional) billing server RPC + page parse for Zen balance (USD)
//!
//! Usage response shape (embedded in Go workspace page):
//! ```js
//! {
//!   rollingUsage: { usagePercent: 67.3, resetInSec: 12600 },
//!   weeklyUsage:  { usagePercent: 34.1, resetInSec: 345600 },
//!   monthlyUsage: { usagePercent: 18.0, resetInSec: 1296000 }  // optional
//! }
//! ```
//! Zen balance from billing RPC: `{ "customerID": "...", "balance": 543210000 }`
//! Raw balance / 100_000_000 = USD.

use regex::Regex;
use serde_json::Value;

use crate::providers::browser_cookies;
use crate::providers::{display_name, ProviderStatus, QuotaWindow};

const BASE_URL: &str = "https://opencode.ai";
const SERVER_URL: &str = "https://opencode.ai/_server";
const WORKSPACES_SERVER_ID: &str = "def39973159c7f0483d8793a822b8dbb10d067e12c65455fcb4608459ba0234f";
const BILLING_SERVER_ID: &str = "c83b78a614689c38ebee981f9b39a8b377716db85c1fd7dbab604adc02d3313d";
const BILLING_SCALE: f64 = 100_000_000.0;
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
            "Không tìm thấy cookie đăng nhập OpenCode Go (cần auth hoặc __Host-auth)",
        );
    };

    let client = crate::providers::shared_client();

    let workspace_id = match fetch_workspace_id(&client, &cookie_header).await {
        Ok(w) => w,
        Err(e) => return ProviderStatus::failure(&id, &name, format!("Không lấy được workspace: {e}")),
    };

    let page_result = fetch_go_page(&client, &workspace_id, &cookie_header).await;
    let zen_balance = fetch_zen_balance(&client, &workspace_id, &cookie_header, page_result.as_deref().ok()).await;

    match page_result {
        Ok(text) => match parse_page(&text, zen_balance) {
            Some(status) => ProviderStatus { id, display_name: name, ..status },
            None if zen_balance.is_some() => zen_only_status(&id, &name, zen_balance.unwrap()),
            None => ProviderStatus::failure(&id, &name, "Không thể phân tích dữ liệu usage OpenCode Go"),
        },
        Err(e) => match zen_balance {
            Some(z) => zen_only_status(&id, &name, z),
            None => ProviderStatus::failure(&id, &name, format!("Không lấy được usage: {e}")),
        },
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

async fn fetch_go_page(client: &reqwest::Client, workspace_id: &str, cookie_header: &str) -> Result<String, String> {
    let url = format!("{BASE_URL}/workspace/{workspace_id}/go");
    let resp = client
        .get(&url)
        .header("Cookie", cookie_header)
        .header("User-Agent", USER_AGENT)
        .header("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
        .send()
        .await
        .map_err(|e| format!("network: {e}"))?;
    let status = resp.status();
    if status.as_u16() == 401 || status.as_u16() == 403 {
        return Err("chưa đăng nhập".to_string());
    }
    if !status.is_success() {
        return Err(format!("HTTP {}", status.as_u16()));
    }
    let text = resp.text().await.map_err(|e| format!("network: {e}"))?;
    if looks_signed_out(&text) {
        return Err("chưa đăng nhập".to_string());
    }
    Ok(text)
}

/// Best-effort zen balance: first from the already-fetched page text, else
/// via the billing server RPC. Never propagates an error — returns `None`.
async fn fetch_zen_balance(
    client: &reqwest::Client,
    workspace_id: &str,
    cookie_header: &str,
    page_text: Option<&str>,
) -> Option<f64> {
    if let Some(text) = page_text {
        if let Some(balance) = parse_zen_balance_from_page(text) {
            return Some(balance);
        }
    }

    let referer = format!("{BASE_URL}/workspace/{workspace_id}");
    let args = serde_json::to_string(&[workspace_id]).ok()?;
    let billing_text = fetch_server_text(client, BILLING_SERVER_ID, Some(&args), "GET", &referer, cookie_header)
        .await
        .ok()?;
    parse_billing_balance(&billing_text)
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

    let builder = if is_get { client.get(&url) } else { client.post(&url) };
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
    lower.contains("login") || lower.contains("sign in") || lower.contains("auth/authorize") || lower.contains("actor of type \"public\"")
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

struct WindowResult {
    percent: f64,
    reset_sec: i64,
}

const PERCENT_KEYS: &[&str] = &["usagePercent", "usedPercent", "percentUsed", "percent", "usage_percent", "utilization"];
const RESET_IN_KEYS: &[&str] = &["resetInSec", "resetInSeconds", "resetSec", "reset_sec", "resetsInSec"];
const RESET_AT_KEYS: &[&str] = &["resetAt", "resetsAt", "reset_at", "nextReset", "renewAt"];
const RENEW_KEYS: &[&str] = &["renewAt", "renewsAt", "renew_at", "renews_at"];
const ROLLING_KEYS: &[&str] = &["rollingUsage", "rolling", "rolling_usage", "rollingWindow"];
const WEEKLY_KEYS: &[&str] = &["weeklyUsage", "weekly", "weekly_usage", "weeklyWindow"];
const MONTHLY_KEYS: &[&str] = &["monthlyUsage", "monthly", "monthly_usage", "monthlyWindow"];

/// Pure text → ProviderStatus parser (unit-tested). `id`/`display_name` are
/// filled by the caller; this function stamps placeholders that get
/// overwritten in `fetch()`.
fn parse_page(text: &str, zen_balance: Option<f64>) -> Option<ProviderStatus> {
    let (mut windows, renews_at) = parse_json_usage(text)
        .or_else(|| parse_regex_usage(text).map(|w| (w, extract_renew_from_text(text))))?;

    if windows.is_empty() && zen_balance.is_none() {
        return None;
    }

    if let Some(renew) = renews_at {
        windows.push(QuotaWindow {
            label: "Gia hạn".into(),
            used_pct: 0,
            remaining_pct: 100,
            subtitle: None,
            resets_at: Some(renew),
            window_seconds: None,
        });
    }

    Some(ProviderStatus {
        id: String::new(),
        display_name: String::new(),
        windows,
        last_updated: chrono::Utc::now().timestamp(),
        credits_remaining: zen_balance,
        ..Default::default()
    })
}

fn zen_only_status(id: &str, name: &str, zen_usd: f64) -> ProviderStatus {
    ProviderStatus {
        id: id.to_string(),
        display_name: name.to_string(),
        windows: Vec::new(),
        last_updated: chrono::Utc::now().timestamp(),
        credits_remaining: Some(zen_usd),
        ..Default::default()
    }
}

fn extract_renew_from_text(text: &str) -> Option<i64> {
    for alias in RENEW_KEYS {
        let pattern = format!(r#""{alias}"\s*:\s*"([^"]+)""#);
        if let Some(cap) = Regex::new(&pattern).ok().and_then(|re| re.captures(text)) {
            if let Some(m) = cap.get(1) {
                if let Ok(dt) = chrono::DateTime::parse_from_rfc3339(m.as_str()) {
                    return Some(dt.timestamp());
                }
            }
        }
    }
    None
}

fn parse_json_usage(text: &str) -> Option<(Vec<QuotaWindow>, Option<i64>)> {
    let v: Value = serde_json::from_str(text).ok()?;
    let dict = v.as_object()?;
    if let Some(result) = build_windows_from_dict(dict) {
        return Some(result);
    }
    for key in ["data", "result", "usage", "billing", "payload"] {
        if let Some(nested) = dict.get(key).and_then(Value::as_object) {
            if let Some(result) = build_windows_from_dict(nested) {
                return Some(result);
            }
        }
    }
    None
}

fn build_windows_from_dict(dict: &serde_json::Map<String, Value>) -> Option<(Vec<QuotaWindow>, Option<i64>)> {
    let rolling = first_dict(dict, ROLLING_KEYS)?;
    let weekly = first_dict(dict, WEEKLY_KEYS)?;
    let rolling_win = parse_window(rolling)?;
    let weekly_win = parse_window(weekly)?;
    let monthly_win = first_dict(dict, MONTHLY_KEYS).and_then(parse_window);

    let now = chrono::Utc::now().timestamp();
    let mut windows = vec![
        make_window("Rolling", &rolling_win, now),
        make_window("Tuần", &weekly_win, now),
    ];
    if let Some(m) = monthly_win {
        windows.push(make_window("Tháng", &m, now));
    }

    let renews_at = RENEW_KEYS.iter().find_map(|k| dict.get(*k).and_then(date_value));
    Some((windows, renews_at))
}

fn parse_regex_usage(text: &str) -> Option<Vec<QuotaWindow>> {
    let rolling_pct = extract_double(text, r"rollingUsage[^}]*?usagePercent\s*:\s*([0-9]+(?:\.[0-9]+)?)")?;
    let rolling_reset = extract_int(text, r"rollingUsage[^}]*?resetInSec\s*:\s*([0-9]+)")?;
    let weekly_pct = extract_double(text, r"weeklyUsage[^}]*?usagePercent\s*:\s*([0-9]+(?:\.[0-9]+)?)")?;
    let weekly_reset = extract_int(text, r"weeklyUsage[^}]*?resetInSec\s*:\s*([0-9]+)")?;

    let now = chrono::Utc::now().timestamp();
    let mut windows = vec![
        make_window("Rolling", &WindowResult { percent: normalize_percent(rolling_pct), reset_sec: rolling_reset }, now),
        make_window("Tuần", &WindowResult { percent: normalize_percent(weekly_pct), reset_sec: weekly_reset }, now),
    ];

    let monthly_pct = extract_double(text, r"monthlyUsage[^}]*?usagePercent\s*:\s*([0-9]+(?:\.[0-9]+)?)");
    let monthly_reset = extract_int(text, r"monthlyUsage[^}]*?resetInSec\s*:\s*([0-9]+)");
    if let (Some(p), Some(r)) = (monthly_pct, monthly_reset) {
        windows.push(make_window("Tháng", &WindowResult { percent: normalize_percent(p), reset_sec: r }, now));
    }

    Some(windows)
}

fn make_window(label: &str, result: &WindowResult, now: i64) -> QuotaWindow {
    let used = (result.percent.round() as i32).clamp(0, 100);
    QuotaWindow {
        label: label.to_string(),
        used_pct: used,
        remaining_pct: 100 - used,
        subtitle: Some(format!("{used}%")),
        resets_at: Some(now + result.reset_sec),
        window_seconds: None,
    }
}

fn first_dict<'a>(dict: &'a serde_json::Map<String, Value>, keys: &[&str]) -> Option<&'a serde_json::Map<String, Value>> {
    keys.iter().find_map(|k| dict.get(*k).and_then(Value::as_object))
}

fn parse_window(dict: &serde_json::Map<String, Value>) -> Option<WindowResult> {
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
        reset_sec = RESET_AT_KEYS.iter().find_map(|k| date_value(dict.get(*k)?).map(|d| (d - chrono::Utc::now().timestamp()).max(0)));
    }
    Some(WindowResult { percent: resolved_pct, reset_sec: reset_sec.unwrap_or(0).max(0) })
}

fn normalize_percent(v: f64) -> f64 {
    let scaled = if (0.0..=1.0).contains(&v) { v * 100.0 } else { v };
    scaled.clamp(0.0, 100.0)
}

fn double_value(v: &Value) -> Option<f64> {
    match v {
        Value::Number(n) => n.as_f64(),
        Value::String(s) => s.trim().replace(',', "").parse().ok(),
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

/// Parses a zen balance embedded directly in the workspace Go page.
fn parse_zen_balance_from_page(text: &str) -> Option<f64> {
    if let Ok(v) = serde_json::from_str::<Value>(text) {
        if let Some(b) = find_explicit_balance(&v) {
            return Some(b);
        }
    }
    let re = Regex::new(r"(?i)(?:balance)[\s\S]{0,120}?\$\s*([0-9][0-9,]*(?:\.[0-9]+)?)").ok()?;
    let cap = re.captures(text)?;
    cap.get(1)?.as_str().replace(',', "").parse().ok()
}

fn find_explicit_balance(v: &Value) -> Option<f64> {
    const EXPLICIT_KEYS: &[&str] = &["zenbalance", "zencurrentbalance", "currentbalance", "currentbalanceusd", "balanceusd", "usdbalance"];
    match v {
        Value::Object(map) => {
            for (key, val) in map {
                let norm: String = key.to_lowercase().chars().filter(|c| c.is_alphanumeric()).collect();
                if EXPLICIT_KEYS.contains(&norm.as_str()) {
                    if let Some(d) = double_value(val) {
                        return Some(d);
                    }
                }
                if let Some(found) = find_explicit_balance(val) {
                    return Some(found);
                }
            }
            None
        }
        Value::Array(arr) => arr.iter().find_map(find_explicit_balance),
        _ => None,
    }
}

/// Parses the billing server RPC response; raw balance / 100_000_000 = USD.
fn parse_billing_balance(text: &str) -> Option<f64> {
    if let Ok(v) = serde_json::from_str::<Value>(text) {
        if let Some(raw) = find_billing_balance(&v) {
            return Some(raw / BILLING_SCALE);
        }
    }
    let customer_re = Regex::new(r#"(?:"customerID"|customerID)\s*:\s*"[^"]+"#).ok()?;
    if !customer_re.is_match(text) {
        return None;
    }
    let balance_re = Regex::new(r#"(?:"balance"|balance)\s*:\s*(-?[0-9]+(?:\.[0-9]+)?)"#).ok()?;
    let raw: f64 = balance_re.captures(text)?.get(1)?.as_str().parse().ok()?;
    Some(raw / BILLING_SCALE)
}

fn find_billing_balance(v: &Value) -> Option<f64> {
    match v {
        Value::Object(map) => {
            if let Some(balance) = map.get("balance") {
                let has_customer = map.get("customerID").and_then(Value::as_str).map(|s| !s.is_empty()).unwrap_or(false);
                if has_customer {
                    return double_value(balance);
                }
                return None;
            }
            map.values().find_map(find_billing_balance)
        }
        Value::Array(arr) => arr.iter().find_map(find_billing_balance),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_json_page_with_monthly_window() {
        let text = r#"{"rollingUsage":{"usagePercent":67.3,"resetInSec":12600},"weeklyUsage":{"usagePercent":34.1,"resetInSec":345600},"monthlyUsage":{"usagePercent":18.0,"resetInSec":1296000}}"#;
        let status = parse_page(text, None).unwrap();
        assert_eq!(status.windows.len(), 3);
        assert_eq!(status.windows[2].label, "Tháng");
    }

    #[test]
    fn parses_regex_fallback_page() {
        let text = "rollingUsage: { usagePercent: 67.3, resetInSec: 12600 }, weeklyUsage: { usagePercent: 34.1, resetInSec: 345600 }";
        let status = parse_page(text, None).unwrap();
        assert_eq!(status.windows.len(), 2);
    }

    #[test]
    fn zen_balance_parsed_from_page_text() {
        let text = r#"{"zenBalance": 12.5}"#;
        let balance = parse_zen_balance_from_page(text).unwrap();
        assert!((balance - 12.5).abs() < 0.001);
    }

    #[test]
    fn billing_balance_scaled_from_raw_units() {
        let text = r#"{"customerID": "cus_123", "balance": 543210000}"#;
        let balance = parse_billing_balance(text).unwrap();
        assert!((balance - 5.4321).abs() < 0.001);
    }

    #[test]
    fn empty_payload_with_no_zen_balance_returns_none() {
        assert!(parse_page("{}", None).is_none());
    }

    #[test]
    fn zen_only_status_has_no_windows() {
        let status = zen_only_status("opencodego", "OpenCode Go", 5.0);
        assert!(status.windows.is_empty());
        assert_eq!(status.credits_remaining, Some(5.0));
    }
}
