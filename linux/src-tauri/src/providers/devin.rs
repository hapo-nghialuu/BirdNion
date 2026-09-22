//! Devin (Cognition) quota provider — port of `DevinProvider.swift` and the
//! vendored `DevinUsageFetcher`/`DevinUsageParser` (CodexBar parity).
//!
//! `GET https://app.devin.ai/api/<org>/billing/quota/usage` (Bearer) →
//! `DevinUsageSnapshot` = daily + weekly percentage windows and plan name.
//!
//! Browser-session import (Chrome localStorage) is macOS-only upstream, so
//! Linux auth is the manual path only:
//! - Token: env `DEVIN_BEARER_TOKEN`/`DEVIN_AUTHORIZATION` → `apiKey`
//!   (accepts a bare token or a full `Authorization: Bearer …` line).
//! - Organization: env `DEVIN_ORGANIZATION`/`DEVIN_ORG` → `devinOrganization`
//!   (slug, internal `org-…`/`org_…` id, or `app.devin.ai/org/<slug>` URL).

use reqwest::Url;
use serde_json::Value;

use crate::config;
use crate::providers::{display_name, shared_client, ProviderStatus, QuotaWindow};

const BASE: &str = "https://app.devin.ai";
const USER_AGENT: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) \
    AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36";

pub async fn fetch(cfg: &config::Provider) -> ProviderStatus {
    let name = display_name(cfg);
    let env = |key: &str| std::env::var(key).ok();
    let Some(token) = resolve_token(cfg, &env) else {
        return ProviderStatus::failure(
            &cfg.id,
            &name,
            "Chưa cấu hình Devin Bearer token — đặt DEVIN_BEARER_TOKEN/DEVIN_AUTHORIZATION hoặc dán token trong Settings",
        );
    };
    let Some(organization) = normalized_organization(resolve_organization(cfg, &env).as_deref())
    else {
        return ProviderStatus::failure(
            &cfg.id,
            &name,
            "Chưa cấu hình Devin Organization — nhập slug, org-… ID, hoặc URL app.devin.ai/org/<slug>; hoặc đặt DEVIN_ORGANIZATION",
        );
    };
    let internal_id = internal_org_id(&organization);

    let client = shared_client();
    let mut last_error = String::new();
    let mut saw_invalid_credentials = false;
    for path in candidate_paths(&organization, internal_id.as_deref()) {
        match get(&client, &path, &token, internal_id.as_deref()).await {
            Ok(body) => return materialize(cfg, &name, &organization, &body),
            Err(FetchError::InvalidCredentials) => {
                saw_invalid_credentials = true;
            }
            Err(FetchError::Other(message)) => last_error = message,
        }
    }
    if last_error.is_empty() && saw_invalid_credentials {
        return ProviderStatus::failure(
            &cfg.id,
            &name,
            "Devin session/token không hợp lệ hoặc đã hết hạn.",
        );
    }
    ProviderStatus::failure(
        &cfg.id,
        &name,
        if last_error.is_empty() {
            "Lỗi API Devin: no quota endpoint succeeded".to_string()
        } else {
            format!("Lỗi API Devin: {last_error}")
        },
    )
}

// --- auth/org resolution -----------------------------------------------------

/// Env → settings `apiKey`; strips an optional `Authorization:`/`Bearer `
/// prefix so a pasted header line still works (upstream `manualAuth`).
fn resolve_token(cfg: &config::Provider, env: &dyn Fn(&str) -> Option<String>) -> Option<String> {
    for key in ["DEVIN_BEARER_TOKEN", "DEVIN_AUTHORIZATION"] {
        if let Some(token) = env(key).and_then(|v| clean_token(&v)) {
            return Some(token);
        }
    }
    cfg.api_key.as_deref().and_then(clean_token)
}

fn clean_token(raw: &str) -> Option<String> {
    let mut token = raw.trim().to_string();
    if token.is_empty() {
        return None;
    }
    if token.to_lowercase().starts_with("authorization:") {
        token = token[token.find(':').unwrap() + 1..].trim().to_string();
    }
    if token.to_lowercase().starts_with("bearer ") {
        token = token[7..].trim().to_string();
    }
    (!token.is_empty()).then_some(token)
}

fn resolve_organization(
    cfg: &config::Provider,
    env: &dyn Fn(&str) -> Option<String>,
) -> Option<String> {
    for key in ["DEVIN_ORGANIZATION", "DEVIN_ORG"] {
        if let Some(value) = env(key)
            .map(|v| v.trim().to_string())
            .filter(|v| !v.is_empty())
        {
            return Some(value);
        }
    }
    cfg.devin_organization
        .as_deref()
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .map(String::from)
}

/// Upstream `normalizedOrganization`: `devin.ai/org/<slug>` URLs collapse to
/// `org/<slug>`; bare internal ids (`org-…`/`org_…`) become
/// `organizations/<id>`; anything else is treated as a slug (`org/<value>`).
fn normalized_organization(raw: Option<&str>) -> Option<String> {
    let mut value = raw?.trim().to_string();
    if value.is_empty() {
        return None;
    }
    if let Ok(url) = Url::parse(&value) {
        if let Some(host) = url.host_str().map(|h| h.to_lowercase()) {
            if host == "devin.ai" || host.ends_with(".devin.ai") {
                let segments: Vec<&str> =
                    url.path_segments().map(|s| s.collect()).unwrap_or_default();
                if segments.len() >= 2 && segments[0] == "org" {
                    value = format!("org/{}", segments[1]);
                } else if segments.len() >= 2 && segments[0] == "organizations" {
                    value = format!("organizations/{}", segments[1]);
                }
            }
        }
    }
    let value = value.trim_matches('/');
    if value.is_empty() {
        return None;
    }
    if value.starts_with("org/") || value.starts_with("organizations/") {
        return Some(value.to_string());
    }
    if is_internal_org_id(value) {
        return Some(format!("organizations/{value}"));
    }
    Some(format!("org/{value}"))
}

fn is_internal_org_id(value: &str) -> bool {
    value.starts_with("org-") || value.starts_with("org_")
}

fn internal_org_id(normalized: &str) -> Option<String> {
    normalized.strip_prefix("organizations/").map(String::from)
}

/// Upstream `candidatePaths` order: internal id first, then the normalized
/// org, then the bare slug, then `organizations/<id>`.
fn candidate_paths(organization: &str, internal_id: Option<&str>) -> Vec<String> {
    let mut paths: Vec<String> = Vec::new();
    if let Some(id) = internal_id {
        paths.push(format!("{id}/billing/quota/usage"));
    }
    paths.push(format!("{organization}/billing/quota/usage"));
    if let Some(slug) = organization.strip_prefix("org/") {
        paths.push(format!("{slug}/billing/quota/usage"));
    }
    if !organization.starts_with("org/") && !organization.starts_with("organizations/") {
        paths.push(format!("org/{organization}/billing/quota/usage"));
    }
    if let Some(id) = internal_id {
        paths.push(format!("organizations/{id}/billing/quota/usage"));
    }
    let mut seen = std::collections::HashSet::new();
    paths.retain(|p| seen.insert(p.clone()));
    paths
}

// --- HTTP -------------------------------------------------------------------

enum FetchError {
    InvalidCredentials,
    Other(String),
}

async fn get(
    client: &reqwest::Client,
    path: &str,
    token: &str,
    internal_id: Option<&str>,
) -> Result<Value, FetchError> {
    let mut request = client
        .get(format!("{BASE}/api/{path}"))
        .header("Accept", "application/json")
        .header("Accept-Language", "en-US,en;q=0.9")
        .header("User-Agent", USER_AGENT)
        .bearer_auth(token);
    if let Some(id) = internal_id {
        request = request.header("x-cog-org-id", id);
    }
    let response = request
        .send()
        .await
        .map_err(|e| FetchError::Other(format!("Network: {e}")))?;
    match response.status().as_u16() {
        200 => {}
        401 | 403 => return Err(FetchError::InvalidCredentials),
        code => return Err(FetchError::Other(format!("HTTP {code}"))),
    }
    response
        .json()
        .await
        .map_err(|_| FetchError::Other("Response thiếu trường".to_string()))
}

// --- parsing (port of DevinUsageParser) --------------------------------------

struct DevinQuota {
    used_percent: f64,
    resets_at: Option<i64>,
}

struct Snapshot {
    daily: Option<DevinQuota>,
    weekly: Option<DevinQuota>,
    plan_name: Option<String>,
}

fn parse(body: &Value) -> Result<Snapshot, String> {
    let (mut daily, mut weekly) = (None, None);
    if let Value::Object(map) = body {
        daily = current_quota_window(map.get("daily_percentage"), map.get("daily_reset_at"));
        weekly = current_quota_window(map.get("weekly_percentage"), map.get("weekly_reset_at"));
    }
    if daily.is_none() {
        daily = find_window(body, is_daily_key);
    }
    if weekly.is_none() {
        weekly = find_window(body, is_weekly_key);
    }
    if daily.is_none() && weekly.is_none() {
        return Err("missing Devin quota windows".to_string());
    }
    Ok(Snapshot {
        daily,
        weekly,
        plan_name: find_plan_name(body),
    })
}

fn current_quota_window(percent: Option<&Value>, resets_at: Option<&Value>) -> Option<DevinQuota> {
    let used = double(percent?)?;
    Some(DevinQuota {
        used_percent: normalize_percent(used),
        resets_at: resets_at.and_then(date_value),
    })
}

fn is_daily_key(key: &str) -> bool {
    let key = key.to_lowercase();
    !key.contains("hide") && (key.contains("daily") || key.contains("day"))
}

fn is_weekly_key(key: &str) -> bool {
    let key = key.to_lowercase();
    !key.contains("hide") && (key.contains("weekly") || key.contains("week"))
}

fn find_window(value: &Value, key_matches: fn(&str) -> bool) -> Option<DevinQuota> {
    match value {
        Value::Object(map) => {
            for (key, v) in map {
                if key_matches(key) {
                    if let Some(window) = window_from(v) {
                        return Some(window);
                    }
                }
            }
            map.values().find_map(|v| find_window(v, key_matches))
        }
        Value::Array(items) => items.iter().find_map(|v| find_window(v, key_matches)),
        _ => None,
    }
}

fn window_from(value: &Value) -> Option<DevinQuota> {
    let Value::Object(map) = value else {
        return double(value).map(|v| DevinQuota {
            used_percent: normalize_percent(v),
            resets_at: None,
        });
    };
    if let Some(percent) = percent_from(value) {
        return Some(DevinQuota {
            used_percent: percent,
            resets_at: find_reset_date(map),
        });
    }
    map.values().find_map(window_from)
}

fn percent_from(value: &Value) -> Option<f64> {
    if let Some(v) = double(value) {
        return Some(normalize_percent(v));
    }
    let Value::Object(map) = value else {
        return None;
    };

    for key in [
        "used_percent",
        "usedPercent",
        "usage_percent",
        "usagePercent",
        "percent_used",
        "percentUsed",
        "percent",
    ] {
        if let Some(v) = map.get(key).and_then(double) {
            return Some(normalize_percent(v));
        }
    }
    for key in [
        "remaining_percent",
        "remainingPercent",
        "percent_remaining",
        "percentRemaining",
    ] {
        if let Some(v) = map.get(key).and_then(double) {
            return Some(100.0 - normalize_percent(v));
        }
    }

    let used = first_double(
        map,
        &["used", "usage", "used_count", "usedCount", "consumed"],
    );
    let limit = first_double(map, &["limit", "quota", "total", "max", "available"]);
    if let (Some(used), Some(limit)) = (used, limit) {
        if limit > 0.0 {
            return Some(used / limit * 100.0);
        }
    }
    let remaining = first_double(map, &["remaining", "left", "available"]);
    if let (Some(remaining), Some(limit)) = (remaining, limit) {
        if limit > 0.0 {
            return Some((limit - remaining) / limit * 100.0);
        }
    }
    None
}

fn find_plan_name(value: &Value) -> Option<String> {
    match value {
        Value::Object(map) => {
            for key in [
                "plan_name",
                "planName",
                "plan",
                "tier",
                "subscription_tier",
                "subscriptionTier",
            ] {
                if let Some(raw) = map.get(key).and_then(Value::as_str) {
                    if let Some(cleaned) = clean_display(raw) {
                        return Some(cleaned);
                    }
                }
            }
            map.values().find_map(find_plan_name)
        }
        Value::Array(items) => items.iter().find_map(find_plan_name),
        _ => None,
    }
}

fn find_reset_date(map: &serde_json::Map<String, Value>) -> Option<i64> {
    for (key, value) in map {
        if key.to_lowercase().contains("reset") {
            if let Some(date) = date_value(value) {
                return Some(date);
            }
        }
    }
    None
}

fn date_value(value: &Value) -> Option<i64> {
    match value {
        Value::String(raw) => {
            if let Ok(date) = chrono::DateTime::parse_from_rfc3339(raw.trim()) {
                return Some(date.timestamp());
            }
            raw.trim().parse::<f64>().ok().and_then(date_from_number)
        }
        _ => double(value).and_then(date_from_number),
    }
}

fn date_from_number(number: f64) -> Option<i64> {
    if number <= 0.0 {
        return None;
    }
    let seconds = if number > 10_000_000_000.0 {
        number / 1000.0
    } else {
        number
    };
    Some(seconds as i64)
}

fn first_double(map: &serde_json::Map<String, Value>, keys: &[&str]) -> Option<f64> {
    keys.iter().find_map(|key| map.get(*key).and_then(double))
}

fn double(value: &Value) -> Option<f64> {
    match value {
        Value::Number(n) => n.as_f64(),
        Value::String(s) => s.trim().parse::<f64>().ok(),
        _ => None,
    }
}

fn normalize_percent(value: f64) -> f64 {
    if value <= 1.0 {
        value * 100.0
    } else {
        value
    }
}

/// Upstream `cleanDisplay`: "core_plan" → "Core Plan".
fn clean_display(raw: &str) -> Option<String> {
    let cleaned = raw.trim();
    if cleaned.is_empty() {
        return None;
    }
    Some(
        cleaned
            .split(['_', '-'])
            .filter(|part| !part.is_empty())
            .map(|part| {
                let mut chars = part.chars();
                match chars.next() {
                    Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
                    None => String::new(),
                }
            })
            .collect::<Vec<_>>()
            .join(" "),
    )
}

/// Display form of the normalized org: `org/<slug>` → `<slug>`,
/// `organizations/<id>` → `<id>`.
fn display_organization(normalized: &str) -> String {
    normalized
        .strip_prefix("organizations/")
        .or_else(|| normalized.strip_prefix("org/"))
        .unwrap_or(normalized)
        .to_string()
}

// --- mapping -----------------------------------------------------------------

fn window(quota: &DevinQuota, label: &str, window_seconds: i64) -> QuotaWindow {
    let used = quota.used_percent.round().clamp(0.0, 100.0) as i32;
    QuotaWindow {
        label: label.to_string(),
        used_pct: used,
        remaining_pct: 100 - used,
        subtitle: None,
        resets_at: quota.resets_at,
        window_seconds: Some(window_seconds),
        semantic_key: None,
        semantic_kind: None,
    }
}

fn materialize(
    cfg: &config::Provider,
    name: &str,
    organization: &str,
    body: &Value,
) -> ProviderStatus {
    let snap = match parse(body) {
        Ok(snap) => snap,
        Err(message) => {
            return ProviderStatus::failure(
                &cfg.id,
                name,
                format!("Không parse được Devin usage: {message}"),
            )
        }
    };

    let mut windows = Vec::new();
    if let Some(daily) = &snap.daily {
        windows.push(window(daily, "Ngày", 24 * 3600));
    }
    if let Some(weekly) = &snap.weekly {
        windows.push(window(weekly, "Tuần", 7 * 24 * 3600));
    }

    let account_label = cfg
        .account_label
        .clone()
        .unwrap_or_else(|| display_organization(organization));
    if windows.is_empty() {
        return ProviderStatus {
            id: cfg.id.clone(),
            display_name: name.to_string(),
            windows,
            last_updated: chrono::Utc::now().timestamp(),
            error: Some("Devin: không có dữ liệu quota".to_string()),
            account_label: Some(account_label),
            plan_name: snap.plan_name,
            ..Default::default()
        };
    }
    ProviderStatus {
        id: cfg.id.clone(),
        display_name: name.to_string(),
        windows,
        last_updated: chrono::Utc::now().timestamp(),
        account_label: Some(account_label),
        plan_name: snap.plan_name,
        source_label: Some("manual".to_string()),
        menu_bar_metric: cfg.menu_bar_metric.clone(),
        ..Default::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn cfg() -> config::Provider {
        config::Provider {
            id: "devin".into(),
            ..Default::default()
        }
    }

    #[test]
    fn clean_token_strips_header_prefixes() {
        assert_eq!(clean_token("abc123").as_deref(), Some("abc123"));
        assert_eq!(clean_token("Bearer abc123").as_deref(), Some("abc123"));
        assert_eq!(
            clean_token("Authorization: Bearer abc123").as_deref(),
            Some("abc123")
        );
        assert_eq!(clean_token("  "), None);
    }

    #[test]
    fn resolve_token_prefers_env_then_settings() {
        let no_env = |_: &str| None;
        let mut c = cfg();
        c.api_key = Some("cfg-token".into());
        assert_eq!(resolve_token(&c, &no_env).as_deref(), Some("cfg-token"));
        let with_env = |key: &str| (key == "DEVIN_BEARER_TOKEN").then(|| "env-token".to_string());
        assert_eq!(resolve_token(&c, &with_env).as_deref(), Some("env-token"));
    }

    #[test]
    fn normalizes_organization_forms() {
        assert_eq!(
            normalized_organization(Some("my-org")).as_deref(),
            Some("org/my-org")
        );
        assert_eq!(
            normalized_organization(Some("org-123abc")).as_deref(),
            Some("organizations/org-123abc")
        );
        assert_eq!(
            normalized_organization(Some("org_xyz")).as_deref(),
            Some("organizations/org_xyz")
        );
        assert_eq!(
            normalized_organization(Some("https://app.devin.ai/org/acme")).as_deref(),
            Some("org/acme")
        );
        assert_eq!(
            normalized_organization(Some("org/acme")).as_deref(),
            Some("org/acme")
        );
        assert_eq!(
            normalized_organization(Some("organizations/org-1")).as_deref(),
            Some("organizations/org-1")
        );
        assert_eq!(normalized_organization(Some("  ")), None);
        assert_eq!(normalized_organization(None), None);
    }

    #[test]
    fn candidate_paths_dedupes_and_prefers_internal_id() {
        let paths = candidate_paths("organizations/org-9", Some("org-9"));
        assert_eq!(paths[0], "org-9/billing/quota/usage");
        assert_eq!(paths[1], "organizations/org-9/billing/quota/usage");
        assert_eq!(paths.len(), 2);

        let paths = candidate_paths("org/acme", None);
        assert_eq!(
            paths,
            vec![
                "org/acme/billing/quota/usage".to_string(),
                "acme/billing/quota/usage".to_string()
            ]
        );
    }

    #[test]
    fn parses_current_quota_shape() {
        let body = json!({
            "daily_percentage": 0.424,
            "daily_reset_at": "2026-09-23T00:00:00Z",
            "weekly_percentage": 7.6,
            "plan_name": "core"
        });
        let snap = parse(&body).unwrap();
        let daily = snap.daily.as_ref().unwrap();
        assert!((daily.used_percent - 42.4).abs() < 0.001);
        assert_eq!(
            daily.resets_at,
            Some(
                chrono::DateTime::parse_from_rfc3339("2026-09-23T00:00:00Z")
                    .unwrap()
                    .timestamp()
            )
        );
        assert!((snap.weekly.unwrap().used_percent - 7.6).abs() < 0.001);
        assert_eq!(snap.plan_name.as_deref(), Some("Core"));
    }

    #[test]
    fn parses_nested_window_fallback() {
        let body = json!({
            "quota": {
                "dailyUsage": { "usedPercent": 55, "resetsAt": 1_800_000_000 },
                "weekly": { "used": 3, "limit": 10 }
            },
            "subscription": { "tier": "pro_plan" }
        });
        let snap = parse(&body).unwrap();
        assert_eq!(snap.daily.unwrap().used_percent, 55.0);
        assert_eq!(snap.weekly.unwrap().used_percent, 30.0);
        assert_eq!(snap.plan_name.as_deref(), Some("Pro Plan"));
    }

    #[test]
    fn parse_fails_without_windows() {
        assert!(parse(&json!({"plan": "core"})).is_err());
    }

    #[test]
    fn materializes_daily_weekly_windows() {
        let body = json!({
            "daily_percentage": 42.4,
            "daily_reset_at": "2026-09-23T00:00:00Z",
            "weekly_percentage": 7.6,
            "plan_name": "core"
        });
        let status = materialize(&cfg(), "Devin", "org/acme", &body);
        assert!(status.error.is_none());
        assert_eq!(status.id, "devin");
        assert_eq!(status.windows.len(), 2);
        assert_eq!(status.windows[0].label, "Ngày");
        assert_eq!(status.windows[0].used_pct, 42);
        assert_eq!(status.windows[0].remaining_pct, 58);
        assert_eq!(status.windows[0].window_seconds, Some(24 * 3600));
        assert_eq!(status.windows[1].label, "Tuần");
        assert_eq!(status.windows[1].window_seconds, Some(7 * 24 * 3600));
        assert_eq!(status.account_label.as_deref(), Some("acme"));
        assert_eq!(status.plan_name.as_deref(), Some("Core"));
        assert_eq!(status.source_label.as_deref(), Some("manual"));
    }
}
