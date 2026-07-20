//! Hapo AI Hub quota provider — port of `HapoHubProvider.swift` /
//! `HapoHubConfig.swift`.
//!
//! Up to two HTTP calls per fetch:
//!  - `GET <me_url>`   — best-effort identity (`{"email": ...}`), used for
//!                       `account_label` when available. A 404 disables this
//!                       optional lookup until the app restarts.
//!  - `GET <base_url>` — weekly budget quota:
//!    `{"usage_percentage":42.0,"remaining_budget_usd":5.8,
//!      "weekly_budget_usd":10.0,"budget_week_ends_at":"2026-07-06T00:00:00Z"}`.
//!
//! Endpoint values are supplied outside source control via env vars
//! (`HAPO_BASE_URL`, `HAPO_ME_URL`, `HAPO_AUTH_TEMPLATE`) or `cfg.base_url`
//! as a config-file override — the source tree carries no real hostnames.
//! Release builds bake the values at COMPILE time from the build shell's
//! environment (`source Scripts/dev-env.sh` before `cargo build`), mirroring
//! how macOS injects them into Info.plist — still nothing in source.

use serde_json::Value;
use std::sync::atomic::{AtomicBool, Ordering};

use crate::config;
use crate::providers::{shared_client, ProviderStatus, QuotaWindow};

/// Compile-time baked endpoints (from the gitignored dev-env.sh at build).
const BAKED_BASE_URL: Option<&str> = option_env!("HAPO_BASE_URL");
const BAKED_ME_URL: Option<&str> = option_env!("HAPO_ME_URL");
const BAKED_AUTH_TEMPLATE: Option<&str> = option_env!("HAPO_AUTH_TEMPLATE");

// A missing identity endpoint is a configuration mismatch, not a transient
// quota failure. Avoid sending one 404 per polling cycle until the app restarts.
static IDENTITY_ENDPOINT_MISSING: AtomicBool = AtomicBool::new(false);

enum EmailLookup {
    Found(String),
    EndpointMissing,
    Unavailable,
}

fn clean_value(s: &str) -> Option<String> {
    let s = s.trim();
    // "$(" guards against un-expanded Xcode-style placeholders leaking in.
    (!s.is_empty() && !s.starts_with("$(")).then(|| s.to_string())
}

fn env_or(key: &str) -> Option<String> {
    std::env::var(key).ok().as_deref().and_then(clean_value)
}

/// Base-URL resolution chain shared with the Claude Code backend mapping:
/// settings.json override → runtime env → compile-time baked value.
pub fn resolved_base_url(cfg: &config::Provider) -> Option<String> {
    cfg.base_url
        .as_deref()
        .and_then(clean_value)
        .or_else(|| env_or("HAPO_BASE_URL"))
        .or_else(|| BAKED_BASE_URL.and_then(clean_value))
}

pub async fn fetch(cfg: &config::Provider) -> ProviderStatus {
    let name = cfg.display_name.clone().unwrap_or_else(|| "AIHub".to_string());

    let Some(base_url) = resolved_base_url(cfg) else {
        return ProviderStatus::failure(&cfg.id, &name, "Hapo endpoint chưa được cấu hình trong bản build");
    };
    let me_url = env_or("HAPO_ME_URL").or_else(|| BAKED_ME_URL.and_then(clean_value));
    let auth_template = env_or("HAPO_AUTH_TEMPLATE")
        .or_else(|| BAKED_AUTH_TEMPLATE.and_then(clean_value))
        .unwrap_or_else(|| "Bearer {token}".to_string());

    let Some(token) = config::api_key(cfg) else {
        return ProviderStatus::failure(&cfg.id, &name, "Chưa cấu hình token");
    };
    if !token.chars().all(|c| c.is_alphanumeric() || c == '.' || c == '_' || c == '-') {
        return ProviderStatus::failure(&cfg.id, &name, "Token chứa ký tự không hợp lệ");
    }

    let auth_header = auth_template.replace("{token}", &token);
    let client = shared_client();

    let mut status = fetch_budget(&client, &cfg.id, &name, &base_url, &auth_header).await;

    // /me is best-effort identity enrichment, fired only when budget succeeded.
    let mut resolved_email = None;
    if status.error.is_none() && !IDENTITY_ENDPOINT_MISSING.load(Ordering::Relaxed) {
        if let Some(me_url) = &me_url {
            let lookup = fetch_email(&client, me_url, &auth_header).await;
            record_identity_lookup(&lookup);
            if let EmailLookup::Found(email) = lookup {
                resolved_email = Some(email);
            }
        }
    }
    let label = resolved_email
        .or_else(|| cfg.account_label.clone())
        .unwrap_or_else(|| token.chars().take(8).collect());
    status.account_label = Some(label);
    status
}

async fn fetch_budget(
    client: &reqwest::Client,
    id: &str,
    name: &str,
    base_url: &str,
    auth_header: &str,
) -> ProviderStatus {
    let resp = client
        .get(base_url)
        .header("Accept", "application/json")
        .header("Authorization", auth_header)
        .send()
        .await;
    let resp = match resp {
        Ok(r) => r,
        Err(e) => return ProviderStatus::failure(id, name, format!("Network: {e}")),
    };
    if !resp.status().is_success() {
        return ProviderStatus::failure(id, name, format!("HTTP {}", resp.status().as_u16()));
    }
    let content_type = resp
        .headers()
        .get("content-type")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_string();
    if !content_type.starts_with("application/json") {
        return ProviderStatus::failure(id, name, format!("Endpoint trả về non-JSON (Content-Type: {content_type})"));
    }
    let body: Value = match resp.json().await {
        Ok(v) => v,
        Err(_) => return ProviderStatus::failure(id, name, "Response thiếu trường"),
    };
    parse_budget(id, name, &body)
}

/// Pure payload → status mapping (unit-tested).
pub fn parse_budget(id: &str, name: &str, body: &Value) -> ProviderStatus {
    let (Some(usage_pct), Some(remaining_usd), Some(weekly_usd), Some(week_ends_at)) = (
        body.get("usage_percentage").and_then(Value::as_f64),
        body.get("remaining_budget_usd").and_then(Value::as_f64),
        body.get("weekly_budget_usd").and_then(Value::as_f64),
        body.get("budget_week_ends_at").and_then(Value::as_str),
    ) else {
        return ProviderStatus::failure(id, name, "Response thiếu trường");
    };
    let remaining_pct = (100.0 - usage_pct).round().clamp(0.0, 100.0) as i32;
    let used_pct = 100 - remaining_pct;
    let resets_at = chrono::DateTime::parse_from_rfc3339(week_ends_at).ok().map(|d| d.timestamp());
    ProviderStatus {
        id: id.to_string(),
        display_name: name.to_string(),
        windows: vec![QuotaWindow { semantic_key: None, semantic_kind: None,
            label: "Tuần".into(),
            used_pct,
            remaining_pct,
            subtitle: Some(format!("${remaining_usd:.2} / ${weekly_usd:.2}")),
            resets_at,
            window_seconds: None,
        }],
        last_updated: chrono::Utc::now().timestamp(),
        ..Default::default()
    }
}

async fn fetch_email(client: &reqwest::Client, me_url: &str, auth_header: &str) -> EmailLookup {
    let resp = match client
        .get(me_url)
        .header("Accept", "application/json")
        .header("Authorization", auth_header)
        .send()
        .await
    {
        Ok(resp) => resp,
        Err(_) => return EmailLookup::Unavailable,
    };
    if resp.status() == reqwest::StatusCode::NOT_FOUND {
        return EmailLookup::EndpointMissing;
    }
    if !resp.status().is_success() {
        return EmailLookup::Unavailable;
    }
    let body: Value = match resp.json().await {
        Ok(body) => body,
        Err(_) => return EmailLookup::Unavailable,
    };
    body.get("email")
        .and_then(Value::as_str)
        .map(|email| EmailLookup::Found(email.to_string()))
        .unwrap_or(EmailLookup::Unavailable)
}

fn record_identity_lookup(result: &EmailLookup) {
    if matches!(result, EmailLookup::EndpointMissing) {
        IDENTITY_ENDPOINT_MISSING.store(true, Ordering::Relaxed);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parses_weekly_budget() {
        let body = json!({
            "usage_percentage": 42.0,
            "remaining_budget_usd": 5.8,
            "used_budget_usd": 4.2,
            "weekly_budget_usd": 10.0,
            "budget_week_ends_at": "2026-07-06T00:00:00Z",
            "budget_week_start_at": "2026-06-29T00:00:00Z",
            "timezone": "UTC"
        });
        let s = parse_budget("hapo", "AIHub", &body);
        assert!(s.error.is_none());
        assert_eq!(s.windows.len(), 1);
        assert_eq!(s.windows[0].used_pct, 42);
        assert_eq!(s.windows[0].remaining_pct, 58);
        assert_eq!(s.windows[0].subtitle.as_deref(), Some("$5.80 / $10.00"));
        assert!(s.windows[0].resets_at.is_some());
    }

    #[test]
    fn missing_fields_is_error() {
        let s = parse_budget("hapo", "AIHub", &json!({"usage_percentage": 1.0}));
        assert!(s.error.is_some());
    }

    #[test]
    fn identity_404_disables_future_identity_lookups() {
        IDENTITY_ENDPOINT_MISSING.store(false, Ordering::Relaxed);

        record_identity_lookup(&EmailLookup::Unavailable);
        assert!(!IDENTITY_ENDPOINT_MISSING.load(Ordering::Relaxed));

        record_identity_lookup(&EmailLookup::EndpointMissing);
        assert!(IDENTITY_ENDPOINT_MISSING.load(Ordering::Relaxed));

        IDENTITY_ENDPOINT_MISSING.store(false, Ordering::Relaxed);
    }
}
