//! Alibaba / Qwen quota provider — port of `AlibabaProvider.swift`.
//!
//! Two independent quota sources, both best-effort (partial success allowed
//! if only one cookie/plan is available):
//!
//! **Coding Plan** (region-aware via `cfg.region`: "intl" (default) or "cn"):
//!   POST <gatewayBase>/data/api.json?action=<rpcAction>&product=sfm_bailian
//!        &api=zeldaEasy.broadscope-bailian.codingPlan.queryCodingPlanInstanceInfoV2&_v=undefined
//!   Produces windows "5 giờ", "Tuần", "Tháng".
//!
//! **Token Plan** (always aliyun.com / cn-beijing, regardless of region):
//!   POST https://bailian.console.aliyun.com/data/api.json
//!        ?action=GetSubscriptionSummary&product=BssOpenAPI-V3&_tag=
//!   Produces one window "Token Plan".
//!
//! Overall failure only if BOTH cookies are absent/both fetches fail.

use regex::Regex;
use serde_json::Value;

use crate::providers::browser_cookies;
use crate::providers::{display_name, ProviderStatus, QuotaWindow};

const USER_AGENT: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36";

struct RegionInfo {
    gateway_base: &'static str,
    rpc_action: &'static str,
    console_domain: &'static str,
    console_site: &'static str,
    commodity_code: &'static str,
    region_id: &'static str,
    cookie_domain: &'static str,
    dashboard_url: &'static str,
    referer_url: &'static str,
}

fn region_info(region: &str) -> RegionInfo {
    match region {
        "cn" => RegionInfo {
            gateway_base: "https://bailian-cs.console.aliyun.com",
            rpc_action: "BroadScopeAspnGateway",
            console_domain: "bailian.console.aliyun.com",
            console_site: "BAILIAN_ALIYUN",
            commodity_code: "sfm_codingplan_public_cn",
            region_id: "cn-beijing",
            cookie_domain: "aliyun.com",
            dashboard_url: "https://bailian.console.aliyun.com/cn-beijing/?tab=model#/efm/coding_plan",
            referer_url: "https://bailian.console.aliyun.com/cn-beijing/?tab=model",
        },
        _ => RegionInfo {
            gateway_base: "https://bailian-singapore-cs.alibabacloud.com",
            rpc_action: "IntlBroadScopeAspnGateway",
            console_domain: "modelstudio.console.alibabacloud.com",
            console_site: "MODELSTUDIO_ALIBABACLOUD",
            commodity_code: "sfm_codingplan_public_intl",
            region_id: "ap-southeast-1",
            cookie_domain: "alibabacloud.com",
            dashboard_url: "https://modelstudio.console.alibabacloud.com/ap-southeast-1/?tab=coding-plan#/efm/coding_plan",
            referer_url: "https://modelstudio.console.alibabacloud.com/ap-southeast-1/?tab=coding-plan",
        },
    }
}

const TOKEN_PLAN_COOKIE_DOMAIN: &str = "aliyun.com";
const TOKEN_PLAN_GATEWAY: &str = "https://bailian.console.aliyun.com";
const TOKEN_PLAN_REGION_ID: &str = "cn-beijing";
const TOKEN_PLAN_PRODUCT_CODE: &str = "sfm_tokenplanteams_dp_cn";
const TOKEN_PLAN_DASHBOARD_URL: &str = "https://bailian.console.aliyun.com/cn-beijing?tab=plan#/efm/subscription/token-plan";

pub async fn fetch(cfg: &crate::config::Provider) -> ProviderStatus {
    let name = display_name(cfg);
    let id = cfg.id.clone();
    let region = cfg.region.as_deref().unwrap_or("intl").to_string();
    let info = region_info(&region);

    let cfg_clone1 = cfg.clone();
    let coding_domain = info.cookie_domain.to_string();
    let cfg_clone2 = cfg.clone();

    let (coding_cookie, token_cookie) = match tauri::async_runtime::spawn_blocking(move || {
        let coding = browser_cookies::cookie_header(&[&coding_domain], &cfg_clone1).ok();
        let token = browser_cookies::cookie_header(&[TOKEN_PLAN_COOKIE_DOMAIN], &cfg_clone2).ok();
        (coding, token)
    })
    .await
    {
        Ok(pair) => pair,
        Err(_) => return ProviderStatus::failure(&id, &name, "Lỗi nội bộ khi đọc cookie"),
    };

    let coding_cookie = coding_cookie.filter(|c| !c.is_empty());
    let token_cookie = token_cookie.filter(|c| !c.is_empty());

    if coding_cookie.is_none() && token_cookie.is_none() {
        return ProviderStatus::failure(&id, &name, "Chưa đăng nhập Alibaba / Qwen trên trình duyệt");
    }

    let client = crate::providers::shared_client();
    let mut windows = Vec::new();
    let mut last_error: Option<String> = None;

    if let Some(cookie) = &coding_cookie {
        match fetch_coding_plan(&client, &info, cookie).await {
            Ok(body) => windows.extend(parse_coding_plan_windows(&body)),
            Err(e) => last_error = Some(format!("Coding Plan: {e}")),
        }
    }

    if let Some(cookie) = &token_cookie {
        match fetch_token_plan(&client, cookie).await {
            Ok(body) => {
                if let Some(w) = parse_token_plan_window(&body) {
                    windows.push(w);
                }
            }
            Err(e) => {
                if last_error.is_none() {
                    last_error = Some(format!("Token Plan: {e}"));
                }
            }
        }
    }

    if windows.is_empty() {
        return ProviderStatus::failure(&id, &name, last_error.unwrap_or_else(|| "Không lấy được dữ liệu quota".to_string()));
    }

    ProviderStatus {
        id,
        display_name: name,
        windows,
        last_updated: chrono::Utc::now().timestamp(),
        ..Default::default()
    }
}

async fn fetch_coding_plan(client: &reqwest::Client, info: &RegionInfo, cookie_header: &str) -> Result<String, String> {
    let sec_token = resolve_sec_token(client, info, cookie_header).await;
    let body = coding_plan_request_body(info, sec_token.as_deref());
    let url = format!(
        "{}/data/api.json?action={}&product=sfm_bailian&api=zeldaEasy.broadscope-bailian.codingPlan.queryCodingPlanInstanceInfoV2&_v=undefined",
        info.gateway_base, info.rpc_action
    );

    let mut req = client
        .post(&url)
        .header("Content-Type", "application/x-www-form-urlencoded")
        .header("Accept", "*/*")
        .header("Cookie", cookie_header)
        .header("User-Agent", USER_AGENT)
        .header("Origin", info.gateway_base)
        .header("Referer", info.referer_url)
        .header("X-Requested-With", "XMLHttpRequest")
        .body(body);
    if let Some(csrf) = extract_cookie_value("login_aliyunid_csrf", cookie_header).or_else(|| extract_cookie_value("csrf", cookie_header)) {
        req = req.header("x-xsrf-token", csrf.clone()).header("x-csrf-token", csrf);
    }

    let resp = req.send().await.map_err(|e| e.to_string())?;
    let status = resp.status();
    if status.as_u16() == 401 || status.as_u16() == 403 {
        return Err("chưa đăng nhập".to_string());
    }
    if !status.is_success() {
        return Err(format!("HTTP {}", status.as_u16()));
    }
    resp.text().await.map_err(|e| e.to_string())
}

async fn resolve_sec_token(client: &reqwest::Client, info: &RegionInfo, cookie_header: &str) -> Option<String> {
    if let Some(t) = extract_cookie_value("sec_token", cookie_header) {
        if !t.is_empty() {
            return Some(t);
        }
    }

    if let Ok(resp) = client
        .get(info.dashboard_url)
        .header("Cookie", cookie_header)
        .header("User-Agent", USER_AGENT)
        .header("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
        .send()
        .await
    {
        if resp.status().is_success() {
            if let Ok(html) = resp.text().await {
                if let Some(t) = extract_sec_token_from_html(&html) {
                    return Some(t);
                }
            }
        }
    }

    let info_url = format!("{}/tool/user/info.json", info.gateway_base);
    if let Ok(resp) = client
        .get(&info_url)
        .header("Cookie", cookie_header)
        .header("User-Agent", USER_AGENT)
        .header("Accept", "application/json, text/plain, */*")
        .header("Referer", format!("{}/", info.gateway_base))
        .send()
        .await
    {
        if resp.status().is_success() {
            if let Ok(v) = resp.json::<Value>().await {
                if let Some(t) = find_first_string(&["secToken", "sec_token"], &v) {
                    return Some(t);
                }
            }
        }
    }

    None
}

fn coding_plan_request_body(info: &RegionInfo, sec_token: Option<&str>) -> String {
    let trace_id = uuid_like();
    let cornerstone = serde_json::json!({
        "feTraceId": trace_id,
        "feURL": info.dashboard_url,
        "protocol": "V2",
        "console": "ONE_CONSOLE",
        "productCode": "p_efm",
        "domain": info.console_domain,
        "consoleSite": info.console_site,
        "userNickName": "",
        "userPrincipalName": "",
        "xsp_lang": "en-US",
    });
    let params = serde_json::json!({
        "Api": "zeldaEasy.broadscope-bailian.codingPlan.queryCodingPlanInstanceInfoV2",
        "V": "1.0",
        "Data": {
            "queryCodingPlanInstanceInfoRequest": {
                "commodityCode": info.commodity_code,
                "onlyLatestOne": true,
            },
            "cornerstoneParam": cornerstone,
        },
    });
    let params_str = params.to_string();

    let mut form = vec![
        ("params".to_string(), params_str),
        ("region".to_string(), info.region_id.to_string()),
    ];
    if let Some(t) = sec_token.filter(|t| !t.is_empty()) {
        form.push(("sec_token".to_string(), t.to_string()));
    }
    encode_form(&form)
}

async fn fetch_token_plan(client: &reqwest::Client, cookie_header: &str) -> Result<String, String> {
    let sec_token = extract_cookie_value("sec_token", cookie_header);
    let body = token_plan_request_body(sec_token.as_deref());
    let url = format!("{TOKEN_PLAN_GATEWAY}/data/api.json?action=GetSubscriptionSummary&product=BssOpenAPI-V3&_tag=");

    let mut req = client
        .post(&url)
        .header("Content-Type", "application/x-www-form-urlencoded")
        .header("Accept", "*/*")
        .header("Cookie", cookie_header)
        .header("User-Agent", USER_AGENT)
        .header("Origin", TOKEN_PLAN_GATEWAY)
        .header("Referer", TOKEN_PLAN_DASHBOARD_URL)
        .header("X-Requested-With", "XMLHttpRequest")
        .body(body);
    if let Some(csrf) = extract_cookie_value("login_aliyunid_csrf", cookie_header).or_else(|| extract_cookie_value("csrf", cookie_header)) {
        req = req.header("x-xsrf-token", csrf.clone()).header("x-csrf-token", csrf);
    }

    let resp = req.send().await.map_err(|e| e.to_string())?;
    let status = resp.status();
    if status.as_u16() == 401 || status.as_u16() == 403 {
        return Err("chưa đăng nhập".to_string());
    }
    if !status.is_success() {
        return Err(format!("HTTP {}", status.as_u16()));
    }
    resp.text().await.map_err(|e| e.to_string())
}

fn token_plan_request_body(sec_token: Option<&str>) -> String {
    let params = serde_json::json!({ "ProductCode": TOKEN_PLAN_PRODUCT_CODE }).to_string();
    let mut form = vec![
        ("product".to_string(), "BssOpenAPI-V3".to_string()),
        ("action".to_string(), "GetSubscriptionSummary".to_string()),
        ("params".to_string(), params),
        ("region".to_string(), TOKEN_PLAN_REGION_ID.to_string()),
    ];
    if let Some(t) = sec_token.filter(|t| !t.is_empty()) {
        form.push(("sec_token".to_string(), t.to_string()));
    }
    encode_form(&form)
}

fn encode_form(pairs: &[(String, String)]) -> String {
    pairs.iter().map(|(k, v)| format!("{}={}", percent_encode(k), percent_encode(v))).collect::<Vec<_>>().join("&")
}

fn percent_encode(s: &str) -> String {
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

const SEC_TOKEN_PATTERNS: &[&str] = &[
    r#"SEC_TOKEN\s*:\s*"([^"]+)""#,
    r#"SEC_TOKEN\s*:\s*'([^']+)'"#,
    r#"secToken\s*:\s*"([^"]+)""#,
    r#"sec_token\s*:\s*"([^"]+)""#,
    r#"sec_token\s*:\s*'([^']+)'"#,
    r#""SEC_TOKEN"\s*:\s*"([^"]+)""#,
    r#""sec_token"\s*:\s*"([^"]+)""#,
    r#""secToken"\s*:\s*"([^"]+)""#,
];

fn extract_sec_token_from_html(html: &str) -> Option<String> {
    for pattern in SEC_TOKEN_PATTERNS {
        if let Ok(re) = Regex::new(pattern) {
            if let Some(cap) = re.captures(html) {
                if let Some(m) = cap.get(1) {
                    let t = m.as_str().trim();
                    if !t.is_empty() {
                        return Some(t.to_string());
                    }
                }
            }
        }
    }
    None
}

fn extract_cookie_value(name: &str, header: &str) -> Option<String> {
    header.split(';').find_map(|chunk| {
        let t = chunk.trim();
        let eq = t.find('=')?;
        let n = t[..eq].trim();
        if n == name {
            Some(t[eq + 1..].trim().to_string())
        } else {
            None
        }
    })
}

const QUOTA_KEYS: &[&str] = &[
    "per5HourUsedQuota", "per5HourTotalQuota", "perWeekUsedQuota", "perWeekTotalQuota", "perBillMonthUsedQuota", "perBillMonthTotalQuota",
];

/// Pure parser for the (possibly double-JSON-encoded) coding-plan RPC body.
fn parse_coding_plan_windows(text: &str) -> Vec<QuotaWindow> {
    let Ok(raw) = serde_json::from_str::<Value>(text) else { return Vec::new() };
    let expanded = expanded_json(&raw);
    let Some(quota) = find_first_dict_matching_any_key(QUOTA_KEYS, &expanded) else { return Vec::new() };

    let mut windows = Vec::new();

    if let Some(total) = any_int(&["per5HourTotalQuota", "perFiveHourTotalQuota"], quota).filter(|&t| t > 0) {
        let used = any_int(&["per5HourUsedQuota", "perFiveHourUsedQuota"], quota).unwrap_or(0);
        let reset = any_date(&["per5HourQuotaNextRefreshTime", "perFiveHourQuotaNextRefreshTime"], quota);
        windows.push(quota_window("5 giờ", used, total, reset));
    }

    if let Some(total) = any_int(&["perWeekTotalQuota"], quota).filter(|&t| t > 0) {
        let used = any_int(&["perWeekUsedQuota"], quota).unwrap_or(0);
        let reset = any_date(&["perWeekQuotaNextRefreshTime"], quota);
        windows.push(quota_window("Tuần", used, total, reset));
    }

    if let Some(total) = any_int(&["perBillMonthTotalQuota", "perMonthTotalQuota"], quota).filter(|&t| t > 0) {
        let used = any_int(&["perBillMonthUsedQuota", "perMonthUsedQuota"], quota).unwrap_or(0);
        let reset = any_date(&["perBillMonthQuotaNextRefreshTime", "perMonthQuotaNextRefreshTime"], quota);
        windows.push(quota_window("Tháng", used, total, reset));
    }

    windows
}

fn quota_window(label: &str, used: i64, total: i64, reset: Option<i64>) -> QuotaWindow {
    let used_pct = ((used as f64 / total as f64) * 100.0).round().clamp(0.0, 100.0) as i32;
    QuotaWindow { semantic_key: None, semantic_kind: None,
        label: label.to_string(),
        used_pct,
        remaining_pct: 100 - used_pct,
        subtitle: Some(format!("{} / {} requests còn lại", format_number((total - used).max(0) as f64), format_number(total as f64))),
        resets_at: reset,
        window_seconds: None,
    }
}

const TOTAL_QUOTA_KEYS: &[&str] = &["totalQuota", "total_quota", "totalCredits", "quota", "amount", "TotalValue", "monthlyTotalQuota"];
const USED_QUOTA_KEYS: &[&str] = &["usedQuota", "used_quota", "usedCredits", "usage", "used", "consumeAmount", "UsedValue", "ConsumedValue"];
const REMAINING_QUOTA_KEYS: &[&str] = &["remainingQuota", "remainQuota", "remainingCredits", "balance", "TotalSurplusValue", "SurplusValue"];
const RESET_DATE_KEYS: &[&str] = &["nextRefreshTime", "resetTime", "periodEndTime", "billCycleEndTime", "expireTime", "endTime", "NearestExpireDate"];

/// Pure parser for the Token Plan RPC body.
fn parse_token_plan_window(text: &str) -> Option<QuotaWindow> {
    if text.is_empty() {
        return None;
    }
    let raw: Value = serde_json::from_str(text).ok()?;
    if text.to_lowercase().contains("<html") {
        return None;
    }

    let empty_map = serde_json::Map::new();
    let root = raw.as_object().unwrap_or(&empty_map);
    let summary = find_summary(root).unwrap_or(root);

    let total = any_double(TOTAL_QUOTA_KEYS, summary);
    let remaining = any_double(REMAINING_QUOTA_KEYS, summary);
    let used_raw = any_double(USED_QUOTA_KEYS, summary);
    let used = used_raw.or_else(|| match (total, remaining) {
        (Some(t), Some(r)) => Some((t - r).max(0.0)),
        _ => None,
    });
    let resets_at = any_date(RESET_DATE_KEYS, summary);

    let total = total.filter(|&t| t > 0.0)?;
    let used = used?;

    let used_pct = ((used / total) * 100.0).round().clamp(0.0, 100.0) as i32;
    let rem = remaining.unwrap_or((total - used).max(0.0));

    Some(QuotaWindow { semantic_key: None, semantic_kind: None,
        label: "Token Plan".to_string(),
        used_pct,
        remaining_pct: 100 - used_pct,
        subtitle: Some(format!("{} / {} credits còn lại", format_number(rem), format_number(total))),
        resets_at,
        window_seconds: None,
    })
}

fn find_summary<'a>(dict: &'a serde_json::Map<String, Value>) -> Option<&'a serde_json::Map<String, Value>> {
    for key in ["Data", "data", "successResponse", "success_response"] {
        if let Some(nested) = dict.get(key).and_then(Value::as_object) {
            let all_keys = [TOTAL_QUOTA_KEYS, USED_QUOTA_KEYS, REMAINING_QUOTA_KEYS].concat();
            if all_keys.iter().any(|k| nested.contains_key(*k)) {
                return Some(nested);
            }
        }
    }
    for v in dict.values() {
        if let Some(nested) = v.as_object().and_then(find_summary) {
            return Some(nested);
        }
    }
    None
}

fn any_double(keys: &[&str], dict: &serde_json::Map<String, Value>) -> Option<f64> {
    keys.iter().find_map(|k| dict.get(*k).and_then(parse_double))
}

fn any_int(keys: &[&str], dict: &serde_json::Map<String, Value>) -> Option<i64> {
    keys.iter().find_map(|k| dict.get(*k).and_then(parse_double)).map(|d| d as i64)
}

fn any_date(keys: &[&str], dict: &serde_json::Map<String, Value>) -> Option<i64> {
    keys.iter().find_map(|k| dict.get(*k).and_then(parse_date))
}

fn parse_double(v: &Value) -> Option<f64> {
    match v {
        Value::Number(n) => n.as_f64().filter(|d| d.is_finite()),
        Value::String(s) => s.trim().replace(',', "").parse().ok(),
        _ => None,
    }
}

fn parse_date(v: &Value) -> Option<i64> {
    if let Some(d) = parse_double(v) {
        if d > 1_000_000_000_000.0 {
            return Some((d / 1000.0) as i64);
        }
        if d > 1_000_000_000.0 {
            return Some(d as i64);
        }
    }
    let s = v.as_str()?;
    let trimmed = s.trim();
    if let Ok(dt) = chrono::DateTime::parse_from_rfc3339(trimmed) {
        return Some(dt.timestamp());
    }
    for fmt in ["%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M", "%Y-%m-%d"] {
        if let Ok(naive) = chrono::NaiveDateTime::parse_from_str(trimmed, fmt) {
            return Some(naive.and_utc().timestamp());
        }
        if let Ok(date) = chrono::NaiveDate::parse_from_str(trimmed, fmt) {
            return Some(date.and_hms_opt(0, 0, 0)?.and_utc().timestamp());
        }
    }
    None
}

fn find_first_string(keys: &[&str], v: &Value) -> Option<String> {
    match v {
        Value::Object(map) => {
            for key in keys {
                if let Some(s) = map.get(*key).and_then(Value::as_str) {
                    let t = s.trim();
                    if !t.is_empty() {
                        return Some(t.to_string());
                    }
                }
            }
            map.values().find_map(|v| find_first_string(keys, v))
        }
        Value::Array(arr) => arr.iter().find_map(|v| find_first_string(keys, v)),
        _ => None,
    }
}

fn find_first_dict_matching_any_key<'a>(keys: &[&str], v: &'a Value) -> Option<&'a serde_json::Map<String, Value>> {
    match v {
        Value::Object(map) => {
            if keys.iter().any(|k| map.contains_key(*k)) {
                return Some(map);
            }
            map.values().find_map(|v| find_first_dict_matching_any_key(keys, v))
        }
        Value::Array(arr) => arr.iter().find_map(|v| find_first_dict_matching_any_key(keys, v)),
        _ => None,
    }
}

/// Recursively re-parses string values that look like nested JSON (mirrors
/// Swift's `expandedJSON`, which handles the API's double-encoding quirk).
fn expanded_json(v: &Value) -> Value {
    match v {
        Value::Object(map) => Value::Object(map.iter().map(|(k, val)| (k.clone(), expanded_json(val))).collect()),
        Value::Array(arr) => Value::Array(arr.iter().map(expanded_json).collect()),
        Value::String(s) => {
            if let Ok(nested) = serde_json::from_str::<Value>(s) {
                if nested.is_object() || nested.is_array() {
                    return expanded_json(&nested);
                }
            }
            v.clone()
        }
        _ => v.clone(),
    }
}

fn format_number(v: f64) -> String {
    if v.fract() == 0.0 {
        format_thousands(v as i64)
    } else {
        format!("{v:.2}")
    }
}

fn format_thousands(n: i64) -> String {
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
    fn parses_coding_plan_windows_from_flat_json() {
        let body = serde_json::json!({
            "per5HourUsedQuota": 30, "per5HourTotalQuota": 100,
            "perWeekUsedQuota": 200, "perWeekTotalQuota": 500,
            "perBillMonthUsedQuota": 800, "perBillMonthTotalQuota": 2000,
        })
        .to_string();
        let windows = parse_coding_plan_windows(&body);
        assert_eq!(windows.len(), 3);
        assert_eq!(windows[0].label, "5 giờ");
        assert_eq!(windows[0].used_pct, 30);
        assert_eq!(windows[2].label, "Tháng");
    }

    #[test]
    fn parses_coding_plan_windows_from_double_encoded_json() {
        let inner = serde_json::json!({ "per5HourUsedQuota": 50, "per5HourTotalQuota": 100 }).to_string();
        let outer = serde_json::json!({ "data": inner }).to_string();
        let windows = parse_coding_plan_windows(&outer);
        assert_eq!(windows.len(), 1);
        assert_eq!(windows[0].used_pct, 50);
    }

    #[test]
    fn parses_token_plan_window_with_data_wrapper() {
        let body = serde_json::json!({
            "Data": { "totalQuota": 1000, "usedQuota": 250 }
        })
        .to_string();
        let window = parse_token_plan_window(&body).unwrap();
        assert_eq!(window.label, "Token Plan");
        assert_eq!(window.used_pct, 25);
    }

    #[test]
    fn token_plan_computes_used_from_remaining_when_used_missing() {
        let body = serde_json::json!({ "totalQuota": 100, "remainingQuota": 40 }).to_string();
        let window = parse_token_plan_window(&body).unwrap();
        assert_eq!(window.used_pct, 60);
    }

    #[test]
    fn html_response_is_not_a_valid_token_plan() {
        assert!(parse_token_plan_window("<html>error</html>").is_none());
    }

    #[test]
    fn no_quota_keys_returns_empty_windows() {
        let body = serde_json::json!({ "unrelated": true }).to_string();
        assert!(parse_coding_plan_windows(&body).is_empty());
    }

    #[test]
    fn extracts_cookie_value_by_name() {
        let header = "foo=bar; sec_token=abc123; baz=qux";
        assert_eq!(extract_cookie_value("sec_token", header), Some("abc123".to_string()));
        assert_eq!(extract_cookie_value("missing", header), None);
    }
}
