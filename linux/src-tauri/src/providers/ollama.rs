//! Ollama Cloud provider — port of macOS `OllamaProvider.swift`.
//!
//! Web: browser/manual cookies → GET https://ollama.com/settings → Session/Weekly %.
//! API: OLLAMA_API_KEY / config verifies tags endpoint (model count only).

use regex::Regex;
use serde_json::Value;

use crate::config;
use crate::providers::browser_cookies;
use crate::providers::{display_name, shared_client, ProviderStatus, QuotaWindow};

const SETTINGS_URL: &str = "https://ollama.com/settings";
const TAGS_URL: &str = "https://ollama.com/api/tags";

pub async fn fetch(cfg: &config::Provider) -> ProviderStatus {
    let name = display_name(cfg);
    let id = cfg.id.clone();
    let mut last_err = String::new();

    // 1) Cookie / HTML scrape
    if cfg.cookie_source.as_deref() != Some("off") {
        let cfg_clone = cfg.clone();
        let cookie = match tauri::async_runtime::spawn_blocking(move || {
            browser_cookies::cookie_header(&["ollama.com", "www.ollama.com"], &cfg_clone)
        })
        .await
        {
            Ok(Ok(h)) => Some(h),
            Ok(Err(e)) => {
                last_err = e;
                None
            }
            Err(_) => {
                last_err = "Lỗi đọc cookie".into();
                None
            }
        };

        if let Some(cookie) = cookie {
            match fetch_settings_html(&cookie).await {
                Ok(html) => match parse_settings_html(&html) {
                    Ok(status) => {
                        let mut s = status;
                        s.id = id;
                        s.display_name = name;
                        if let Some(label) = &cfg.account_label {
                            s.account_label = Some(label.clone());
                        }
                        return s;
                    }
                    Err(e) => last_err = e,
                },
                Err(e) => last_err = e,
            }
        }
    }

    // 2) API key path
    if let Some(token) = resolve_token(cfg) {
        match fetch_api_tags(&token).await {
            Ok(status) => {
                let mut s = status;
                s.id = id;
                s.display_name = name;
                s.account_label = cfg
                    .account_label
                    .clone()
                    .or_else(|| Some(token.chars().take(8).collect()));
                return s;
            }
            Err(e) => last_err = e,
        }
    }

    if last_err.is_empty() {
        last_err =
            "Chưa đăng nhập Ollama (cookie ollama.com) hoặc API key. Login + cookie Auto/Manual."
                .into();
    }
    ProviderStatus::failure(&id, &name, last_err)
}

fn resolve_token(cfg: &config::Provider) -> Option<String> {
    if let Ok(v) = std::env::var("OLLAMA_API_KEY") {
        let v = v.trim().to_string();
        if !v.is_empty() {
            return Some(v);
        }
    }
    config::api_key(cfg)
}

async fn fetch_settings_html(cookie: &str) -> Result<String, String> {
    let client = shared_client();
    let resp = client
        .get(SETTINGS_URL)
        .header("Cookie", cookie)
        .header("Accept", "text/html")
        .header("User-Agent", "BirdNion/1.0")
        .send()
        .await
        .map_err(|e| format!("Network: {e}"))?;
    let status = resp.status();
    let url = resp.url().to_string();
    let body = resp.text().await.map_err(|e| format!("Network: {e}"))?;
    if url.contains("signin") || url.contains("authkit") {
        return Err("Ollama session cookie hết hạn — login lại ollama.com".into());
    }
    if !status.is_success() {
        return Err(format!("HTTP {}", status.as_u16()));
    }
    Ok(body)
}

/// Pure HTML → status (unit-tested).
pub fn parse_settings_html(html: &str) -> Result<ProviderStatus, String> {
    let session = percent_after(html, "Session usage").or_else(|| percent_after(html, "Hourly usage"));
    let weekly = percent_after(html, "Weekly usage");
    if session.is_none() && weekly.is_none() {
        if html.contains("signin") || html.to_lowercase().contains("sign in") {
            return Err("Not logged in to Ollama".into());
        }
        return Err("Could not parse Ollama usage".into());
    }

    let mut windows = Vec::new();
    if let Some(pct) = session {
        let used = pct.round().clamp(0.0, 100.0) as i32;
        windows.push(QuotaWindow { semantic_key: None, semantic_kind: None,
            label: "Session".into(),
            used_pct: used,
            remaining_pct: 100 - used,
            subtitle: None,
            resets_at: None,
            window_seconds: None,
        });
    }
    if let Some(pct) = weekly {
        let used = pct.round().clamp(0.0, 100.0) as i32;
        windows.push(QuotaWindow { semantic_key: None, semantic_kind: None,
            label: "Tuần".into(),
            used_pct: used,
            remaining_pct: 100 - used,
            subtitle: None,
            resets_at: None,
            window_seconds: None,
        });
    }

    Ok(ProviderStatus {
        id: "ollama".into(),
        display_name: "Ollama".into(),
        windows,
        last_updated: chrono::Utc::now().timestamp(),
        ..Default::default()
    })
}

fn percent_after(html: &str, label: &str) -> Option<f64> {
    let idx = html.find(label)?;
    let tail = &html[idx..html.len().min(idx + 2500)];
    let re = Regex::new(r"(?i)([0-9]+(?:\.[0-9]+)?)\s*%\s*used").ok()?;
    let caps = re.captures(tail)?;
    caps.get(1)?.as_str().parse().ok()
}

async fn fetch_api_tags(token: &str) -> Result<ProviderStatus, String> {
    let client = shared_client();
    let resp = client
        .get(TAGS_URL)
        .bearer_auth(token)
        .header("Accept", "application/json")
        .send()
        .await
        .map_err(|e| format!("Network: {e}"))?;
    let status = resp.status();
    if status.as_u16() == 401 || status.as_u16() == 403 {
        return Err("Ollama API key invalid".into());
    }
    if !status.is_success() {
        return Err(format!("HTTP {}", status.as_u16()));
    }
    let body: Value = resp.json().await.map_err(|e| format!("JSON: {e}"))?;
    let count = body
        .get("models")
        .and_then(Value::as_array)
        .map(|a| a.len())
        .unwrap_or(0);
    Ok(ProviderStatus {
        id: "ollama".into(),
        display_name: "Ollama".into(),
        windows: vec![QuotaWindow { semantic_key: None, semantic_kind: None,
            label: "Cloud API".into(),
            used_pct: 0,
            remaining_pct: 100,
            subtitle: Some(format!("{count} models · key OK")),
            resets_at: None,
            window_seconds: None,
        }],
        last_updated: chrono::Utc::now().timestamp(),
        ..Default::default()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_session_weekly() {
        let html = r#"
        <div>Cloud Usage</div>
        <div>Session usage <span>42% used</span></div>
        <div>Weekly usage <span>10% used</span></div>
        "#;
        let s = parse_settings_html(html).unwrap();
        assert_eq!(s.windows.len(), 2);
        assert_eq!(s.windows[0].used_pct, 42);
        assert_eq!(s.windows[1].used_pct, 10);
    }
}
