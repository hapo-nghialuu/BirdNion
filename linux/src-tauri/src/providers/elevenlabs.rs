//! ElevenLabs (TTS) usage provider — port of `ElevenLabsProvider.swift`.
//!
//! `GET https://api.elevenlabs.io/v1/user/subscription` (header `xi-api-key`)
//! → character credits used/limit + optional voice slot counts.

use serde_json::Value;

use crate::config;
use crate::providers::{display_name, shared_client, ProviderStatus, QuotaWindow};

const ENDPOINT: &str = "https://api.elevenlabs.io/v1/user/subscription";

pub async fn fetch(cfg: &config::Provider) -> ProviderStatus {
    let name = display_name(cfg);
    let envtok = std::env::var("ELEVENLABS_API_KEY").ok().map(|s| s.trim().to_string()).filter(|s| !s.is_empty());
    let token = envtok.or_else(|| config::api_key(cfg));
    let Some(token) = token else {
        return ProviderStatus::failure(&cfg.id, &name, "Chưa cấu hình API key ElevenLabs");
    };
    let account_label = cfg
        .account_label
        .clone()
        .unwrap_or_else(|| token.chars().take(8).collect());

    let client = shared_client();
    let resp = client
        .get(ENDPOINT)
        .header("xi-api-key", &token)
        .header("Accept", "application/json")
        .send()
        .await;
    let resp = match resp {
        Ok(r) => r,
        Err(e) => return ProviderStatus::failure(&cfg.id, &name, format!("Network: {e}")),
    };
    match resp.status().as_u16() {
        200..=299 => {}
        401 | 403 => return ProviderStatus::failure(&cfg.id, &name, "API key ElevenLabs không hợp lệ"),
        code => return ProviderStatus::failure(&cfg.id, &name, format!("HTTP {code}")),
    }
    let body: Value = match resp.json().await {
        Ok(v) => v,
        Err(_) => return ProviderStatus::failure(&cfg.id, &name, "Response thiếu trường"),
    };
    parse_subscription(&cfg.id, &name, &account_label, &body)
}

fn fmt_num(n: i64) -> String {
    // Comma-group like the Swift NumberFormatter(en_US_POSIX, .decimal).
    let s = n.abs().to_string();
    let mut out = String::new();
    for (i, c) in s.chars().rev().enumerate() {
        if i > 0 && i % 3 == 0 {
            out.push(',');
        }
        out.push(c);
    }
    let grouped: String = out.chars().rev().collect();
    if n < 0 {
        format!("-{grouped}")
    } else {
        grouped
    }
}

/// Mirrors CodexBar's ElevenLabsUsageSnapshot.displayTier logic.
fn display_tier(tier: Option<&str>, status: Option<&str>) -> Option<String> {
    let tier = tier?.trim();
    if tier.is_empty() {
        return status.map(String::from);
    }
    let suffix = match status {
        Some(s) if !s.is_empty() && s.to_lowercase() != "active" => format!(" · {s}"),
        _ => String::new(),
    };
    let capitalized = tier
        .replace('_', " ")
        .split(' ')
        .map(|w| {
            let mut c = w.chars();
            match c.next() {
                Some(f) => f.to_uppercase().collect::<String>() + &c.as_str().to_lowercase(),
                None => String::new(),
            }
        })
        .collect::<Vec<_>>()
        .join(" ");
    Some(format!("{capitalized}{suffix}"))
}

/// Pure payload → status mapping (unit-tested).
pub fn parse_subscription(id: &str, name: &str, account_label: &str, body: &Value) -> ProviderStatus {
    let Some(char_limit) = body.get("character_limit").and_then(Value::as_i64) else {
        return ProviderStatus::failure(id, name, "Response thiếu trường");
    };
    let char_count = body.get("character_count").and_then(Value::as_i64).unwrap_or(0);

    let mut windows = Vec::new();
    let used = if char_limit > 0 {
        ((char_count as f64 / char_limit as f64) * 100.0).round().clamp(0.0, 100.0) as i32
    } else {
        0
    };
    let resets_at = body.get("next_character_count_reset_unix").and_then(Value::as_i64);
    windows.push(QuotaWindow {
        label: "Credits".into(),
        used_pct: used,
        remaining_pct: 100 - used,
        subtitle: Some(format!("{} / {}", fmt_num(char_count), fmt_num(char_limit))),
        resets_at,
    });

    if let (Some(u), Some(lim)) = (
        body.get("voice_slots_used").and_then(Value::as_i64),
        body.get("voice_limit").and_then(Value::as_i64).filter(|l| *l > 0),
    ) {
        let p = ((u as f64 / lim as f64) * 100.0).round().clamp(0.0, 100.0) as i32;
        windows.push(QuotaWindow {
            label: "Voice slots".into(),
            used_pct: p,
            remaining_pct: 100 - p,
            subtitle: Some(format!("{u} / {lim}")),
            resets_at: None,
        });
    }
    if let (Some(u), Some(lim)) = (
        body.get("professional_voice_slots_used").and_then(Value::as_i64),
        body.get("professional_voice_limit").and_then(Value::as_i64).filter(|l| *l > 0),
    ) {
        let p = ((u as f64 / lim as f64) * 100.0).round().clamp(0.0, 100.0) as i32;
        windows.push(QuotaWindow {
            label: "Professional voices".into(),
            used_pct: p,
            remaining_pct: 100 - p,
            subtitle: Some(format!("{u} / {lim}")),
            resets_at: None,
        });
    }

    let _plan = display_tier(
        body.get("tier").and_then(Value::as_str),
        body.get("status").and_then(Value::as_str),
    );

    ProviderStatus {
        id: id.to_string(),
        display_name: name.to_string(),
        windows,
        last_updated: chrono::Utc::now().timestamp(),
        account_label: Some(account_label.to_string()),
        ..Default::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parses_subscription_with_voice_slots() {
        let body = json!({
            "tier": "creator", "status": "active",
            "character_count": 5000, "character_limit": 10000,
            "voice_slots_used": 2, "voice_limit": 10,
            "next_character_count_reset_unix": 1_700_000_000i64
        });
        let s = parse_subscription("elevenlabs", "ElevenLabs", "sk-ab", &body);
        assert!(s.error.is_none());
        assert_eq!(s.windows.len(), 2);
        assert_eq!(s.windows[0].used_pct, 50);
        assert_eq!(s.windows[0].subtitle.as_deref(), Some("5,000 / 10,000"));
        assert_eq!(s.windows[1].used_pct, 20);
    }

    #[test]
    fn display_tier_appends_non_active_status() {
        assert_eq!(display_tier(Some("free_tier"), Some("past_due")).unwrap(), "Free Tier · past_due");
        assert_eq!(display_tier(Some("creator"), Some("active")).unwrap(), "Creator");
    }

    #[test]
    fn missing_character_limit_is_error() {
        let s = parse_subscription("elevenlabs", "ElevenLabs", "x", &json!({}));
        assert!(s.error.is_some());
    }
}
