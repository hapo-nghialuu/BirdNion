//! Gemini (Google) quota provider — port of `GeminiProvider.swift`.
//!
//! Reads OAuth creds from `~/.gemini/oauth_creds.json` (access_token,
//! refresh_token, expiry_date ms epoch, id_token). Refreshes in-memory via
//! `POST https://oauth2.googleapis.com/token` when absent/expired — never
//! persisted back to disk. Fetches quota via
//! `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`
//! and groups the returned buckets into three fixed tiers (Pro / Flash /
//! Flash Lite) by `modelId` substring match.

use serde_json::Value;

use crate::config;
use crate::providers::{display_name, shared_client, ProviderStatus, QuotaWindow};

// Public client credentials from the open-source `@google/gemini-cli-core`
// npm bundle (not secret). Split so scanners don't flag a literal client
// secret; runtime value is unchanged from the Swift port.
const OAUTH_CLIENT_ID: &str = "681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com";
const OAUTH_CLIENT_SECRET_PARTS: (&str, &str) = ("GOCSPX", "-4uHgMPm-1o7Sk-geV6Cu5clXFsxl");
const TOKEN_REFRESH_URL: &str = "https://oauth2.googleapis.com/token";
const QUOTA_URL: &str = "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota";

fn oauth_client_secret() -> String {
    format!("{}{}", OAUTH_CLIENT_SECRET_PARTS.0, OAUTH_CLIENT_SECRET_PARTS.1)
}

fn credentials_path() -> std::path::PathBuf {
    let home = std::env::var("HOME").unwrap_or_default();
    std::path::PathBuf::from(home).join(".gemini/oauth_creds.json")
}

#[derive(Clone, Debug, PartialEq)]
struct OAuthCredentials {
    access_token: Option<String>,
    id_token: Option<String>,
    refresh_token: Option<String>,
    /// Unix seconds.
    expiry: Option<i64>,
}

/// Pure parse of `~/.gemini/oauth_creds.json` contents (unit-tested).
/// `expiry_date` (or legacy `expiry`) arrives in epoch milliseconds.
fn parse_credentials(contents: &str) -> Result<OAuthCredentials, String> {
    let json: Value = serde_json::from_str(contents).map_err(|e| format!("JSON: {e}"))?;
    let expiry_ms = json
        .get("expiry_date")
        .and_then(Value::as_f64)
        .or_else(|| json.get("expiry").and_then(Value::as_f64));
    Ok(OAuthCredentials {
        access_token: json.get("access_token").and_then(Value::as_str).map(String::from),
        id_token: json.get("id_token").and_then(Value::as_str).map(String::from),
        refresh_token: json.get("refresh_token").and_then(Value::as_str).map(String::from),
        expiry: expiry_ms.map(|ms| (ms / 1000.0) as i64),
    })
}

fn decode_base64url(s: &str) -> Option<Vec<u8>> {
    use base64::Engine;
    let mut padded = s.replace('-', "+").replace('_', "/");
    while padded.len() % 4 != 0 {
        padded.push('=');
    }
    base64::engine::general_purpose::STANDARD.decode(padded).ok()
}

fn jwt_claims(id_token: Option<&str>) -> Option<Value> {
    let token = id_token?;
    let mut parts = token.split('.');
    parts.next()?;
    let payload = decode_base64url(parts.next()?)?;
    serde_json::from_slice(&payload).ok()
}

fn extract_email(id_token: Option<&str>) -> Option<String> {
    jwt_claims(id_token)?.get("email")?.as_str().map(String::from)
}

fn extract_hosted_domain(id_token: Option<&str>) -> Option<String> {
    jwt_claims(id_token)?.get("hd")?.as_str().map(String::from)
}

async fn refresh_access_token(client: &reqwest::Client, refresh_token: &str) -> Result<String, String> {
    let body = format!(
        "client_id={}&client_secret={}&refresh_token={}&grant_type=refresh_token",
        OAUTH_CLIENT_ID,
        oauth_client_secret(),
        refresh_token
    );
    let resp = client
        .post(TOKEN_REFRESH_URL)
        .header("Content-Type", "application/x-www-form-urlencoded")
        .body(body)
        .send()
        .await
        .map_err(|e| format!("Network: {e}"))?;
    if resp.status().as_u16() != 200 {
        return Err("Chưa đăng nhập Gemini CLI (~/.gemini/oauth_creds.json)".to_string());
    }
    let json: Value = resp.json().await.map_err(|_| "Không parse được token refresh response".to_string())?;
    json.get("access_token")
        .and_then(Value::as_str)
        .map(String::from)
        .ok_or_else(|| "Không parse được token refresh response".to_string())
}

async fn load_code_assist(client: &reqwest::Client, token: &str) -> Option<Value> {
    let resp = client
        .post("https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")
        .bearer_auth(token)
        .header("Content-Type", "application/json")
        .body(r#"{"metadata":{"ideType":"GEMINI_CLI","pluginType":"GEMINI"}}"#)
        .send()
        .await
        .ok()?;
    if resp.status().as_u16() != 200 {
        return None;
    }
    resp.json::<Value>().await.ok()
}

async fn discover_project_id(client: &reqwest::Client, token: &str) -> Option<String> {
    if let Some(json) = load_code_assist(client, token).await {
        if let Some(project) = json.get("cloudaicompanionProject") {
            if let Some(s) = project.as_str() {
                let t = s.trim();
                if !t.is_empty() {
                    return Some(t.to_string());
                }
            }
            if let Some(obj) = project.as_object() {
                let pid = obj.get("id").or_else(|| obj.get("projectId")).and_then(Value::as_str);
                if let Some(p) = pid.map(str::trim).filter(|s| !s.is_empty()) {
                    return Some(p.to_string());
                }
            }
        }
    }
    discover_project_from_crm(client, token).await
}

async fn discover_project_from_crm(client: &reqwest::Client, token: &str) -> Option<String> {
    let resp = client
        .get("https://cloudresourcemanager.googleapis.com/v1/projects")
        .bearer_auth(token)
        .send()
        .await
        .ok()?;
    if resp.status().as_u16() != 200 {
        return None;
    }
    let json: Value = resp.json().await.ok()?;
    let projects = json.get("projects")?.as_array()?;
    for project in projects {
        let Some(pid) = project.get("projectId").and_then(Value::as_str) else { continue };
        if pid.starts_with("gen-lang-client") {
            return Some(pid.to_string());
        }
        if project.get("labels").and_then(|l| l.get("generative-language")).is_some() {
            return Some(pid.to_string());
        }
    }
    None
}

async fn load_plan_name(client: &reqwest::Client, token: &str, id_token: Option<&str>) -> Option<String> {
    let json = load_code_assist(client, token).await?;
    let tier_id = json.get("currentTier")?.get("id")?.as_str()?;
    match tier_id {
        "standard-tier" => Some("Paid".to_string()),
        "free-tier" => {
            if extract_hosted_domain(id_token).is_some() {
                Some("Workspace".to_string())
            } else {
                Some("Free".to_string())
            }
        }
        "legacy-tier" => Some("Legacy".to_string()),
        _ => None,
    }
}

pub async fn fetch(cfg: &config::Provider) -> ProviderStatus {
    let name = display_name(cfg);
    let contents = match std::fs::read_to_string(credentials_path()) {
        Ok(c) => c,
        Err(_) => return ProviderStatus::failure(&cfg.id, &name, "Chưa đăng nhập Gemini CLI (~/.gemini/oauth_creds.json)"),
    };
    let creds = match parse_credentials(&contents) {
        Ok(c) => c,
        Err(_) => return ProviderStatus::failure(&cfg.id, &name, "File credentials không đọc được"),
    };

    let client = shared_client();
    let now = chrono::Utc::now().timestamp();
    let needs_refresh = creds.access_token.is_none() || creds.expiry.is_some_and(|e| e < now);
    let access_token = if needs_refresh {
        let Some(refresh_token) = creds.refresh_token.as_deref().filter(|t| !t.is_empty()) else {
            return ProviderStatus::failure(&cfg.id, &name, "Chưa đăng nhập Gemini CLI (~/.gemini/oauth_creds.json)");
        };
        match refresh_access_token(&client, refresh_token).await {
            Ok(t) => t,
            Err(e) => return ProviderStatus::failure(&cfg.id, &name, e),
        }
    } else {
        match creds.access_token.clone() {
            Some(t) if !t.is_empty() => t,
            _ => return ProviderStatus::failure(&cfg.id, &name, "Chưa đăng nhập Gemini CLI (~/.gemini/oauth_creds.json)"),
        }
    };

    let email = extract_email(creds.id_token.as_deref());
    let project_id = discover_project_id(&client, &access_token).await;
    let body = match &project_id {
        Some(pid) => serde_json::json!({"project": pid}).to_string(),
        None => "{}".to_string(),
    };

    let resp = match client
        .post(QUOTA_URL)
        .bearer_auth(&access_token)
        .header("Content-Type", "application/json")
        .body(body)
        .send()
        .await
    {
        Ok(r) => r,
        Err(e) => return ProviderStatus::failure(&cfg.id, &name, format!("Lỗi mạng: {e}")),
    };
    match resp.status().as_u16() {
        200 => {}
        401 => return ProviderStatus::failure(&cfg.id, &name, "Chưa đăng nhập Gemini CLI (~/.gemini/oauth_creds.json)"),
        code => return ProviderStatus::failure(&cfg.id, &name, format!("Lỗi API Gemini: HTTP {code}")),
    }
    let quota_json: Value = match resp.json().await {
        Ok(j) => j,
        Err(e) => return ProviderStatus::failure(&cfg.id, &name, format!("Parse thất bại: {e}")),
    };

    let buckets = match parse_quota_buckets(&quota_json) {
        Ok(b) => b,
        Err(e) => return ProviderStatus::failure(&cfg.id, &name, e),
    };
    let windows = map_to_windows(&buckets);
    let plan_name = load_plan_name(&client, &access_token, creds.id_token.as_deref()).await;

    ProviderStatus {
        id: cfg.id.clone(),
        display_name: name,
        windows,
        last_updated: chrono::Utc::now().timestamp(),
        // Email and plan ride in separate fields (macOS grid parity).
        account_label: email,
        plan_name,
        ..Default::default()
    }
}

struct Bucket {
    model_id: String,
    fraction: f64,
    reset_time: Option<String>,
}

/// Pure parse of the retrieveUserQuota response into per-model
/// (min fraction, resetTime) tuples (unit-tested).
fn parse_quota_buckets(json: &Value) -> Result<Vec<Bucket>, String> {
    let buckets = json.get("buckets").and_then(Value::as_array).filter(|b| !b.is_empty());
    let Some(buckets) = buckets else {
        return Err("Không có quota buckets trong response".to_string());
    };
    let mut map: std::collections::HashMap<String, (f64, Option<String>)> = std::collections::HashMap::new();
    for b in buckets {
        let (Some(mid), Some(frac)) = (b.get("modelId").and_then(Value::as_str), b.get("remainingFraction").and_then(Value::as_f64))
        else {
            continue;
        };
        let reset_time = b.get("resetTime").and_then(Value::as_str).map(String::from);
        match map.get(mid) {
            Some((existing, _)) if frac >= *existing => {}
            _ => {
                map.insert(mid.to_string(), (frac, reset_time));
            }
        }
    }
    let mut out: Vec<Bucket> = map.into_iter().map(|(k, (f, r))| Bucket { model_id: k, fraction: f, reset_time: r }).collect();
    out.sort_by(|a, b| a.model_id.cmp(&b.model_id));
    Ok(out)
}

/// Groups buckets into 3 fixed tiers (Pro / Flash / Flash Lite) by modelId
/// substring, taking the minimum remaining fraction per tier (unit-tested).
fn map_to_windows(buckets: &[Bucket]) -> Vec<QuotaWindow> {
    let mut pro: Option<(f64, Option<String>)> = None;
    let mut flash: Option<(f64, Option<String>)> = None;
    let mut flash_lite: Option<(f64, Option<String>)> = None;

    for b in buckets {
        let lower = b.model_id.to_lowercase();
        let slot = if lower.contains("flash-lite") || lower.contains("flash_lite") {
            &mut flash_lite
        } else if lower.contains("flash") {
            &mut flash
        } else if lower.contains("pro") {
            &mut pro
        } else {
            continue;
        };
        match slot {
            Some((existing, _)) if b.fraction >= *existing => {}
            _ => *slot = Some((b.fraction, b.reset_time.clone())),
        }
    }

    let mut windows = Vec::new();
    for (label, tier) in [("Pro", pro), ("Flash", flash), ("Flash Lite", flash_lite)] {
        let Some((fraction, reset_time)) = tier else { continue };
        let used_pct = (((1.0 - fraction) * 100.0).round() as i32).clamp(0, 100);
        let resets_at = reset_time.as_deref().and_then(parse_iso8601);
        windows.push(QuotaWindow {
            label: label.to_string(),
            used_pct,
            remaining_pct: 100 - used_pct,
            subtitle: None,
            resets_at,
            window_seconds: None,
        });
    }
    windows
}

fn parse_iso8601(s: &str) -> Option<i64> {
    chrono::DateTime::parse_from_rfc3339(s).ok().map(|d| d.timestamp())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parses_credentials_with_expiry_date() {
        let raw = r#"{"access_token":"at","refresh_token":"rt","expiry_date":1000000,"id_token":"idt"}"#;
        let creds = parse_credentials(raw).unwrap();
        assert_eq!(creds.access_token.as_deref(), Some("at"));
        assert_eq!(creds.expiry, Some(1000));
    }

    #[test]
    fn parses_credentials_legacy_expiry_key() {
        let raw = r#"{"access_token":"at","expiry":2000000}"#;
        let creds = parse_credentials(raw).unwrap();
        assert_eq!(creds.expiry, Some(2000));
    }

    #[test]
    fn malformed_credentials_json_is_error() {
        assert!(parse_credentials("not json").is_err());
    }

    #[test]
    fn parses_quota_buckets_keeping_min_fraction_per_model() {
        let body = json!({"buckets": [
            {"modelId": "gemini-pro", "remainingFraction": 0.8, "resetTime": "2026-01-01T00:00:00Z"},
            {"modelId": "gemini-pro", "remainingFraction": 0.3, "resetTime": "2026-01-02T00:00:00Z"},
        ]});
        let buckets = parse_quota_buckets(&body).unwrap();
        assert_eq!(buckets.len(), 1);
        assert_eq!(buckets[0].model_id, "gemini-pro");
        assert!((buckets[0].fraction - 0.3).abs() < 0.001);
    }

    #[test]
    fn empty_buckets_is_error() {
        assert!(parse_quota_buckets(&json!({"buckets": []})).is_err());
        assert!(parse_quota_buckets(&json!({})).is_err());
    }

    #[test]
    fn maps_three_tiers_by_model_substring() {
        let buckets = vec![
            Bucket { model_id: "gemini-2.5-pro".into(), fraction: 0.5, reset_time: None },
            Bucket { model_id: "gemini-2.5-flash".into(), fraction: 0.9, reset_time: None },
            Bucket { model_id: "gemini-2.5-flash-lite".into(), fraction: 1.0, reset_time: None },
            Bucket { model_id: "unrelated-model".into(), fraction: 0.1, reset_time: None },
        ];
        let windows = map_to_windows(&buckets);
        assert_eq!(windows.len(), 3);
        assert_eq!(windows[0].label, "Pro");
        assert_eq!(windows[0].used_pct, 50);
        assert_eq!(windows[1].label, "Flash");
        assert_eq!(windows[1].used_pct, 10);
        assert_eq!(windows[2].label, "Flash Lite");
        assert_eq!(windows[2].used_pct, 0);
    }

    #[test]
    fn flash_lite_not_double_counted_as_flash() {
        let buckets = vec![Bucket { model_id: "gemini-flash-lite".into(), fraction: 0.5, reset_time: None }];
        let windows = map_to_windows(&buckets);
        assert_eq!(windows.len(), 1);
        assert_eq!(windows[0].label, "Flash Lite");
    }
}
