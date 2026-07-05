//! AWS Bedrock usage provider — port of `BedrockProvider.swift`.
//!
//! Auth chain (priority order):
//!   1. `cfg.api_key` + `cfg.secret_key` (config-file static keys)
//!   2. Env vars: AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY (+ AWS_SESSION_TOKEN)
//!   3. `~/.aws/credentials` / `~/.aws/config` for the resolved profile
//!      (`cfg.aws_auth_mode == "profile"` → `cfg.aws_profile`, else AWS_PROFILE
//!      or "default").
//! Region: `cfg.region` > AWS_REGION/AWS_DEFAULT_REGION > profile file region
//! > "us-east-1".
//!
//! Queries AWS Cost Explorer for the monthly Bedrock spend and CloudWatch
//! GetMetricData for 14-day Claude token activity; both are best-effort
//! (one failing doesn't block the other).

use chrono::Datelike;
use hmac::{Hmac, Mac};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

use crate::config;
use crate::providers::{shared_client, ProviderStatus, QuotaWindow};

type HmacSha256 = Hmac<Sha256>;

struct Credentials {
    access_key_id: String,
    secret_access_key: String,
    session_token: Option<String>,
}

fn sha256_hex(data: &[u8]) -> String {
    hex::encode(Sha256::digest(data))
}

fn hmac_bytes(key: &[u8], msg: &[u8]) -> Vec<u8> {
    let mut mac = HmacSha256::new_from_slice(key).expect("HMAC accepts any key length");
    mac.update(msg);
    mac.finalize().into_bytes().to_vec()
}

fn amz_date(now: chrono::DateTime<chrono::Utc>) -> String {
    now.format("%Y%m%dT%H%M%SZ").to_string()
}

fn date_stamp(now: chrono::DateTime<chrono::Utc>) -> String {
    now.format("%Y%m%d").to_string()
}

/// Signs a request and returns the headers to attach (Authorization,
/// X-Amz-Date, X-Amz-Security-Token, x-amz-content-sha256, Host).
fn sign_request(
    method: &str,
    host: &str,
    path: &str,
    body: &[u8],
    credentials: &Credentials,
    region: &str,
    service: &str,
    extra_headers: &[(&str, &str)],
) -> Vec<(String, String)> {
    let now = chrono::Utc::now();
    let amz_date_s = amz_date(now);
    let date_stamp_s = date_stamp(now);
    let body_hash = sha256_hex(body);

    let mut headers: Vec<(String, String)> = vec![
        ("host".to_string(), host.to_string()),
        ("x-amz-date".to_string(), amz_date_s.clone()),
        ("x-amz-content-sha256".to_string(), body_hash.clone()),
    ];
    if let Some(token) = &credentials.session_token {
        headers.push(("x-amz-security-token".to_string(), token.clone()));
    }
    for (k, v) in extra_headers {
        headers.push((k.to_lowercase(), v.trim().to_string()));
    }
    headers.sort_by(|a, b| a.0.cmp(&b.0));

    let signed_header_keys = headers.iter().map(|(k, _)| k.as_str()).collect::<Vec<_>>().join(";");
    let canonical_headers = headers.iter().map(|(k, v)| format!("{k}:{v}")).collect::<Vec<_>>().join("\n");
    let canonical_path = if path.is_empty() { "/".to_string() } else { path.to_string() };

    let canonical_request = [
        method,
        &canonical_path,
        "", // no query string for the POST APIs used here
        &(canonical_headers.clone() + "\n"),
        &signed_header_keys,
        &body_hash,
    ]
    .join("\n");

    let credential_scope = format!("{date_stamp_s}/{region}/{service}/aws4_request");
    let string_to_sign =
        ["AWS4-HMAC-SHA256", &amz_date_s, &credential_scope, &sha256_hex(canonical_request.as_bytes())].join("\n");

    let k_date = hmac_bytes(format!("AWS4{}", credentials.secret_access_key).as_bytes(), date_stamp_s.as_bytes());
    let k_region = hmac_bytes(&k_date, region.as_bytes());
    let k_service = hmac_bytes(&k_region, service.as_bytes());
    let k_signing = hmac_bytes(&k_service, b"aws4_request");
    let signature = hex::encode(hmac_bytes(&k_signing, string_to_sign.as_bytes()));

    let authorization = format!(
        "AWS4-HMAC-SHA256 Credential={}/{credential_scope}, SignedHeaders={signed_header_keys}, Signature={signature}",
        credentials.access_key_id
    );

    let mut result = headers;
    result.push(("Authorization".to_string(), authorization));
    result
}

/// Minimal INI parser: [section] -> {key: value}. Ignores comments/blank
/// lines; good enough for `~/.aws/credentials` and `~/.aws/config`.
fn parse_ini(content: &str) -> std::collections::HashMap<String, std::collections::HashMap<String, String>> {
    let mut result = std::collections::HashMap::new();
    let mut section = String::new();
    for raw_line in content.lines() {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') || line.starts_with(';') {
            continue;
        }
        if line.starts_with('[') && line.ends_with(']') {
            section = line[1..line.len() - 1].trim().to_string();
            continue;
        }
        if section.is_empty() {
            continue;
        }
        if let Some(eq) = line.find('=') {
            let key = line[..eq].trim().to_lowercase();
            let value = line[eq + 1..].trim().to_string();
            result.entry(section.clone()).or_insert_with(std::collections::HashMap::new).insert(key, value);
        }
    }
    result
}

fn cleaned(s: Option<&str>) -> Option<String> {
    let v = s?.trim();
    if v.is_empty() {
        return None;
    }
    if (v.starts_with('"') && v.ends_with('"')) || (v.starts_with('\'') && v.ends_with('\'')) {
        let stripped = v[1..v.len() - 1].trim();
        return if stripped.is_empty() { None } else { Some(stripped.to_string()) };
    }
    Some(v.to_string())
}

struct Resolved {
    credentials: Credentials,
    region: String,
}

fn env_region() -> Option<String> {
    cleaned(std::env::var("AWS_REGION").ok().as_deref()).or_else(|| cleaned(std::env::var("AWS_DEFAULT_REGION").ok().as_deref()))
}

fn resolve_from_profile(profile: &str, config_region: Option<&str>) -> Result<Resolved, String> {
    let home = std::env::var("HOME").unwrap_or_default();
    let cred_map = std::fs::read_to_string(format!("{home}/.aws/credentials"))
        .ok()
        .map(|s| parse_ini(&s))
        .unwrap_or_default();
    let config_map = std::fs::read_to_string(format!("{home}/.aws/config"))
        .ok()
        .map(|s| parse_ini(&s))
        .unwrap_or_default();
    let config_section = if profile == "default" { "default".to_string() } else { format!("profile {profile}") };
    let empty = std::collections::HashMap::new();
    let cred = cred_map.get(profile).unwrap_or(&empty);
    let cfgm = config_map.get(&config_section).unwrap_or(&empty);

    let key_id = cleaned(cred.get("aws_access_key_id").or_else(|| cfgm.get("aws_access_key_id")).map(|s| s.as_str()));
    let secret = cleaned(cred.get("aws_secret_access_key").or_else(|| cfgm.get("aws_secret_access_key")).map(|s| s.as_str()));
    let session_token = cleaned(cred.get("aws_session_token").or_else(|| cfgm.get("aws_session_token")).map(|s| s.as_str()));
    let region = config_region
        .map(String::from)
        .or_else(env_region)
        .or_else(|| cleaned(cfgm.get("region").map(|s| s.as_str())))
        .unwrap_or_else(|| "us-east-1".to_string());

    match (key_id, secret) {
        (Some(access_key_id), Some(secret_access_key)) => {
            Ok(Resolved { credentials: Credentials { access_key_id, secret_access_key, session_token }, region })
        }
        _ => Err("Chưa cấu hình AWS credentials (~/.aws/credentials)".to_string()),
    }
}

fn resolve_credentials(cfg: &config::Provider) -> Result<Resolved, String> {
    let config_region = cfg.region.as_deref().and_then(|r| cleaned(Some(r)));
    let auth_mode = cfg.aws_auth_mode.as_deref().unwrap_or("keys");

    if auth_mode == "profile" {
        let profile = cleaned(cfg.aws_profile.as_deref())
            .or_else(|| cleaned(std::env::var("AWS_PROFILE").ok().as_deref()))
            .unwrap_or_else(|| "default".to_string());
        return resolve_from_profile(&profile, config_region.as_deref());
    }

    if let (Some(key_id), Some(secret)) = (cleaned(cfg.api_key.as_deref()), cleaned(cfg.secret_key.as_deref())) {
        let region = config_region.or_else(env_region).unwrap_or_else(|| "us-east-1".to_string());
        return Ok(Resolved { credentials: Credentials { access_key_id: key_id, secret_access_key: secret, session_token: None }, region });
    }
    if let (Ok(key_id), Ok(secret)) = (std::env::var("AWS_ACCESS_KEY_ID"), std::env::var("AWS_SECRET_ACCESS_KEY")) {
        let region = config_region.or_else(env_region).unwrap_or_else(|| "us-east-1".to_string());
        let session_token = cleaned(std::env::var("AWS_SESSION_TOKEN").ok().as_deref());
        return Ok(Resolved { credentials: Credentials { access_key_id: key_id, secret_access_key: secret, session_token }, region });
    }
    let profile = cleaned(std::env::var("AWS_PROFILE").ok().as_deref()).unwrap_or_else(|| "default".to_string());
    resolve_from_profile(&profile, config_region.as_deref())
}

fn cloudwatch_host(region: &str) -> Result<String, String> {
    let valid = regex_ok(region);
    if !valid {
        return Err(format!("Invalid region: {region}"));
    }
    let suffix = if region.starts_with("cn-") {
        "amazonaws.com.cn"
    } else if region.starts_with("us-iso-") {
        "c2s.ic.gov"
    } else if region.starts_with("us-isob-") {
        "sc2s.sgov.gov"
    } else {
        "amazonaws.com"
    };
    Ok(format!("monitoring.{region}.{suffix}"))
}

/// `^[a-z0-9]+(?:-[a-z0-9]+)+-[0-9]+$` without pulling in regex just for this
/// one check — hand-rolled to keep bedrock's own dep footprint minimal
/// (regex is already a dep for kiro, but this check is trivial enough to
/// avoid the extra compile-time query overhead).
fn regex_ok(region: &str) -> bool {
    let parts: Vec<&str> = region.split('-').collect();
    if parts.len() < 3 {
        return false;
    }
    let is_alnum_lower = |s: &str| !s.is_empty() && s.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit());
    let last_is_digits = |s: &str| !s.is_empty() && s.chars().all(|c| c.is_ascii_digit());
    parts[..parts.len() - 1].iter().all(|p| is_alnum_lower(p)) && last_is_digits(parts[parts.len() - 1])
}

async fn fetch_cloudwatch_activity(
    client: &reqwest::Client,
    credentials: &Credentials,
    region: &str,
) -> Result<(i64, i64, i64), String> {
    let host = cloudwatch_host(region)?;
    let now = chrono::Utc::now();
    let start = now - chrono::Duration::days(14);

    let metrics = [("inputTokens", "InputTokenCount"), ("outputTokens", "OutputTokenCount"), ("requests", "Invocations")];
    let queries: Vec<Value> = metrics
        .iter()
        .map(|(id, metric_name)| {
            let search = format!("SEARCH('{{AWS/Bedrock,ModelId}} MetricName=\"{metric_name}\" claude', 'Sum', 86400)");
            json!({"Id": id, "Expression": format!("SUM({search})"), "ReturnData": true})
        })
        .collect();
    let payload = json!({
        "StartTime": start.timestamp() as f64,
        "EndTime": now.timestamp() as f64,
        "ScanBy": "TimestampAscending",
        "MetricDataQueries": queries,
    });
    let body = serde_json::to_vec(&payload).map_err(|e| e.to_string())?;

    let extra_headers = [
        ("content-type", "application/x-amz-json-1.0"),
        ("x-amz-target", "GraniteServiceVersion20100801.GetMetricData"),
    ];
    let signed = sign_request("POST", &host, "/", &body, credentials, region, "monitoring", &extra_headers);

    let mut req = client.post(format!("https://{host}")).body(body);
    for (k, v) in &signed {
        if k.eq_ignore_ascii_case("host") {
            continue; // reqwest sets Host automatically from the URL
        }
        req = req.header(k.as_str(), v.as_str());
    }
    req = req.header("Content-Type", "application/x-amz-json-1.0");
    req = req.header("X-Amz-Target", "GraniteServiceVersion20100801.GetMetricData");

    let resp = req.send().await.map_err(|e| format!("CloudWatch: {e}"))?;
    if resp.status().as_u16() != 200 {
        return Err(format!("CloudWatch: HTTP {}", resp.status().as_u16()));
    }
    let json: Value = resp.json().await.map_err(|e| format!("CloudWatch: {e}"))?;
    parse_cloudwatch_page(&json)
}

/// Pure CloudWatch GetMetricData response → (input, output, request) totals.
pub fn parse_cloudwatch_page(json: &Value) -> Result<(i64, i64, i64), String> {
    if json.get("Messages").and_then(Value::as_array).is_some_and(|m| !m.is_empty()) {
        return Err("CloudWatch: incomplete results".to_string());
    }
    let results = json.get("MetricDataResults").and_then(Value::as_array).cloned().unwrap_or_default();
    let mut totals: std::collections::HashMap<String, f64> = std::collections::HashMap::new();
    for r in &results {
        let (Some(id), Some(values)) = (r.get("Id").and_then(Value::as_str), r.get("Values").and_then(Value::as_array)) else {
            continue;
        };
        if r.get("StatusCode").and_then(Value::as_str) != Some("Complete") {
            continue;
        }
        let sum: f64 = values.iter().filter_map(Value::as_f64).sum();
        *totals.entry(id.to_string()).or_insert(0.0) += sum;
    }
    Ok((
        totals.get("inputTokens").copied().unwrap_or(0.0).round() as i64,
        totals.get("outputTokens").copied().unwrap_or(0.0).round() as i64,
        totals.get("requests").copied().unwrap_or(0.0).round() as i64,
    ))
}

fn current_month_range(now: chrono::DateTime<chrono::Utc>) -> (String, String) {
    let start_of_month = now.date_naive().with_day(1).unwrap();
    let tomorrow = now.date_naive() + chrono::Duration::days(1);
    (start_of_month.format("%Y-%m-%d").to_string(), tomorrow.format("%Y-%m-%d").to_string())
}

async fn fetch_monthly_cost(client: &reqwest::Client, credentials: &Credentials) -> Result<f64, String> {
    let host = "ce.us-east-1.amazonaws.com";
    let (start, end) = current_month_range(chrono::Utc::now());
    let mut total = 0.0;
    let mut next_token: Option<String> = None;
    let mut seen = std::collections::HashSet::new();
    loop {
        let mut body_val = json!({
            "TimePeriod": {"Start": start, "End": end},
            "Granularity": "MONTHLY",
            "Metrics": ["UnblendedCost"],
            "GroupBy": [{"Type": "DIMENSION", "Key": "SERVICE"}],
        });
        if let Some(t) = &next_token {
            body_val["NextPageToken"] = json!(t);
        }
        let body = serde_json::to_vec(&body_val).map_err(|e| e.to_string())?;
        let extra_headers = [("content-type", "application/x-amz-json-1.1"), ("x-amz-target", "AWSInsightsIndexService.GetCostAndUsage")];
        let signed = sign_request("POST", host, "/", &body, credentials, "us-east-1", "ce", &extra_headers);
        let mut req = client.post(format!("https://{host}")).body(body);
        for (k, v) in &signed {
            if k.eq_ignore_ascii_case("host") {
                continue;
            }
            req = req.header(k.as_str(), v.as_str());
        }
        req = req.header("Content-Type", "application/x-amz-json-1.1");
        req = req.header("X-Amz-Target", "AWSInsightsIndexService.GetCostAndUsage");

        let resp = req.send().await.map_err(|e| format!("Cost Explorer: {e}"))?;
        let status = resp.status().as_u16();
        let json: Value = resp.json().await.unwrap_or(Value::Null);
        if status == 400 && is_data_unavailable(&json) {
            break;
        }
        if status != 200 {
            return Err(format!("Cost Explorer: HTTP {status}"));
        }
        total += parse_total_cost(&json);
        next_token = json.get("NextPageToken").and_then(Value::as_str).map(String::from).filter(|t| !t.trim().is_empty());
        if let Some(t) = &next_token {
            if !seen.insert(t.clone()) {
                return Err("Cost Explorer: Repeated NextPageToken".to_string());
            }
        } else {
            break;
        }
    }
    Ok(total)
}

fn is_data_unavailable(json: &Value) -> bool {
    let candidates = [
        json.get("__type").and_then(Value::as_str),
        json.get("code").and_then(Value::as_str),
        json.get("Code").and_then(Value::as_str),
        json.get("Error").and_then(|e| e.get("Code")).and_then(Value::as_str),
    ];
    candidates.iter().flatten().any(|c| c.split('#').last() == Some("DataUnavailableException"))
}

/// Pure Cost Explorer page → total Bedrock spend (unit-tested).
pub fn parse_total_cost(json: &Value) -> f64 {
    let Some(results) = json.get("ResultsByTime").and_then(Value::as_array) else { return 0.0 };
    let mut total = 0.0;
    for r in results {
        let Some(groups) = r.get("Groups").and_then(Value::as_array) else { continue };
        for g in groups {
            let Some(svc) = g.get("Keys").and_then(Value::as_array).and_then(|k| k.first()).and_then(Value::as_str) else { continue };
            if !svc.to_lowercase().contains("bedrock") {
                continue;
            }
            let Some(amount_str) = g.get("Metrics").and_then(|m| m.get("UnblendedCost")).and_then(|c| c.get("Amount")).and_then(Value::as_str) else {
                continue;
            };
            if let Ok(amount) = amount_str.parse::<f64>() {
                total += amount;
            }
        }
    }
    total
}

fn end_of_current_month(now: chrono::DateTime<chrono::Utc>) -> Option<i64> {
    let year = now.year();
    let month = now.month();
    let (next_year, next_month) = if month == 12 { (year + 1, 1) } else { (year, month + 1) };
    let first_of_next = chrono::NaiveDate::from_ymd_opt(next_year, next_month, 1)?;
    Some(first_of_next.and_hms_opt(0, 0, 0)?.and_utc().timestamp())
}

fn compact_count(n: i64) -> String {
    match n {
        0 => "0".to_string(),
        _ if n < 1_000 => n.to_string(),
        _ if n < 1_000_000 => format!("{:.1}K", n as f64 / 1_000.0),
        _ => format!("{:.1}M", n as f64 / 1_000_000.0),
    }
}

pub async fn fetch(cfg: &config::Provider) -> ProviderStatus {
    let name = cfg.display_name.clone().unwrap_or_else(|| "AWS Bedrock".to_string());
    let resolved = match resolve_credentials(cfg) {
        Ok(r) => r,
        Err(e) => return ProviderStatus::failure(&cfg.id, &name, e),
    };
    let region = resolved.region.clone();
    let account_label = cfg.account_label.clone().unwrap_or_else(|| {
        cfg.aws_profile.clone().unwrap_or_else(|| std::env::var("AWS_PROFILE").unwrap_or_else(|_| "default".to_string()))
    });

    let client = shared_client();
    let monthly_spend = fetch_monthly_cost(&client, &resolved.credentials).await.ok();
    let activity = fetch_cloudwatch_activity(&client, &resolved.credentials, &region).await.ok();

    if monthly_spend.is_none() && activity.is_none() {
        return ProviderStatus::failure(&cfg.id, &name, "Không lấy được dữ liệu từ Cost Explorer và CloudWatch");
    }

    build_status(&cfg.id, &name, &account_label, monthly_spend, cfg.budget, activity, &region)
}

/// Pure spend/activity → status mapping (unit-tested).
fn build_status(
    id: &str,
    name: &str,
    account_label: &str,
    monthly_spend: Option<f64>,
    budget: Option<f64>,
    activity: Option<(i64, i64, i64)>,
    region: &str,
) -> ProviderStatus {
    let mut windows = Vec::new();
    let now = chrono::Utc::now();
    let resets_at = end_of_current_month(now);

    if let Some(spend) = monthly_spend {
        if let Some(b) = budget.filter(|b| *b > 0.0) {
            let used_pct = ((spend / b) * 100.0).round().clamp(0.0, 100.0) as i32;
            windows.push(QuotaWindow {
                label: "Ngân sách tháng".into(),
                used_pct,
                remaining_pct: 100 - used_pct,
                subtitle: Some(format!("${spend:.2} / ${b:.2}")),
                resets_at,
            });
        } else {
            windows.push(QuotaWindow {
                label: "Ngân sách tháng".into(),
                used_pct: 0,
                remaining_pct: 100,
                subtitle: Some(format!("Đã dùng ${spend:.2} tháng này")),
                resets_at,
            });
        }
    }

    if let Some((input_tokens, output_tokens, request_count)) = activity {
        let total_tokens = input_tokens + output_tokens;
        let subtitle = format!(
            "{} tokens · ↑{} ↓{} · {request_count} req",
            compact_count(total_tokens),
            compact_count(input_tokens),
            compact_count(output_tokens)
        );
        windows.push(QuotaWindow {
            label: format!("14 ngày ({region})"),
            used_pct: 0,
            remaining_pct: 100,
            subtitle: Some(subtitle),
            resets_at: None,
        });
    }

    ProviderStatus {
        id: id.to_string(),
        display_name: name.to_string(),
        windows,
        last_updated: now.timestamp(),
        account_label: Some(account_label.to_string()),
        ..Default::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parses_cloudwatch_totals() {
        let body = json!({
            "MetricDataResults": [
                {"Id": "inputTokens", "StatusCode": "Complete", "Values": [100.0, 50.0]},
                {"Id": "outputTokens", "StatusCode": "Complete", "Values": [20.0]},
                {"Id": "requests", "StatusCode": "Complete", "Values": [5.0]}
            ]
        });
        let (input, output, requests) = parse_cloudwatch_page(&body).unwrap();
        assert_eq!(input, 150);
        assert_eq!(output, 20);
        assert_eq!(requests, 5);
    }

    #[test]
    fn cloudwatch_incomplete_results_is_error() {
        let body = json!({"Messages": [{"Code": "PartialData"}]});
        assert!(parse_cloudwatch_page(&body).is_err());
    }

    #[test]
    fn parses_bedrock_only_cost() {
        let body = json!({"ResultsByTime": [{"Groups": [
            {"Keys": ["Amazon Bedrock"], "Metrics": {"UnblendedCost": {"Amount": "12.50"}}},
            {"Keys": ["Amazon S3"], "Metrics": {"UnblendedCost": {"Amount": "1.00"}}}
        ]}]});
        assert!((parse_total_cost(&body) - 12.50).abs() < 0.001);
    }

    #[test]
    fn build_status_with_budget_shows_used_pct() {
        let s = build_status("bedrock", "AWS Bedrock", "default", Some(50.0), Some(100.0), Some((1000, 500, 10)), "us-east-1");
        assert_eq!(s.windows.len(), 2);
        assert_eq!(s.windows[0].used_pct, 50);
        assert_eq!(s.windows[1].label, "14 ngày (us-east-1)");
    }

    #[test]
    fn build_status_without_budget_is_informational() {
        let s = build_status("bedrock", "AWS Bedrock", "default", Some(50.0), None, None, "us-east-1");
        assert_eq!(s.windows.len(), 1);
        assert_eq!(s.windows[0].used_pct, 0);
    }
}
