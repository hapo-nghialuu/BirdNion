//! Provider quota framework — Rust mirror of the macOS `QuotaProvider`
//! protocol + `ProviderStatus`/`QuotaWindow` models. Each provider module
//! exposes `async fn fetch(cfg: &config::Provider) -> ProviderStatus`; the
//! registry dispatches by id and runs all enabled providers concurrently.

pub mod alibaba;
pub mod antigravity;
pub mod bedrock;
pub mod browser_cookies;
pub mod claude;
pub mod claude_admin;
pub mod codex;
pub mod commandcode;
pub mod copilot;
pub mod copilot_oauth;
pub mod cursor;
pub mod deepgram;
pub mod deepseek;
pub mod elevenlabs;
pub mod error_classifier;
pub mod freemodel;
pub mod gemini;
pub mod groq;
pub mod hapo;
pub mod kilo;
pub mod kiro;
pub mod mimo;
pub mod minimax;
pub mod opencode;
pub mod opencodego;
pub mod openrouter;
pub mod zai;

use serde::Serialize;
use crate::config;

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct QuotaWindow {
    pub label: String,
    pub used_pct: i32,
    pub remaining_pct: i32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub subtitle: Option<String>,
    /// Unix seconds; None when the API gives no reset time.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub resets_at: Option<i64>,
}

#[derive(Serialize, Clone, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub struct ProviderStatus {
    pub id: String,
    pub display_name: String,
    pub windows: Vec<QuotaWindow>,
    /// Unix seconds of the fetch.
    pub last_updated: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub account_label: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub credits_remaining: Option<f64>,
    /// Codex web-dashboard extras (best-effort cookie enrichment) — port of
    /// `CodexWebExtras`. `code_review_remaining_percent` is intentionally
    /// never populated on Linux: Swift parses it from a *rendered* dashboard
    /// page via regex-over-DOM (WKWebView), which has no headless/JSON
    /// equivalent here.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub signed_in_email: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub code_review_remaining_percent: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub credits_purchase_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub credits_history_count: Option<i32>,
}

impl ProviderStatus {
    pub fn failure(id: &str, display_name: &str, message: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            display_name: display_name.into(),
            windows: Vec::new(),
            last_updated: chrono::Utc::now().timestamp(),
            error: Some(message.into()),
            ..Default::default()
        }
    }
}

/// Display name for a provider id (config displayName overrides).
pub fn display_name(cfg: &config::Provider) -> String {
    if let Some(name) = cfg.display_name.as_deref().map(str::trim) {
        if !name.is_empty() {
            return name.to_string();
        }
    }
    match cfg.id.as_str() {
        "openrouter" => "OpenRouter",
        "deepseek" => "DeepSeek",
        "zai" => "z.ai",
        "minimax" => "MiniMax",
        "hapo" => "Hapo AI Hub",
        "elevenlabs" => "ElevenLabs",
        "deepgram" => "Deepgram",
        "groq" => "Groq",
        "kiro" => "Kiro",
        "bedrock" => "Bedrock",
        "claude" => "Claude",
        "codex" => "Codex",
        "copilot" => "Copilot",
        "kilo" => "Kilo",
        "opencode" => "OpenCode",
        "opencodego" => "OpenCode Go",
        "commandcode" => "Command Code",
        "cursor" => "Cursor",
        "mimo" => "Xiaomi MiMo",
        "alibaba" => "Alibaba / Qwen",
        "freemodel" => "FreeModel",
        other => other,
    }
    .to_string()
}

/// Fetch one provider's status by id. Unknown/not-yet-ported ids return a
/// clear "chưa hỗ trợ" status instead of failing the whole refresh.
pub async fn fetch(cfg: &config::Provider) -> ProviderStatus {
    match cfg.id.as_str() {
        "openrouter" => openrouter::fetch(cfg).await,
        "deepseek" => deepseek::fetch(cfg).await,
        "zai" => zai::fetch(cfg).await,
        "minimax" => minimax::fetch(cfg).await,
        "hapo" => hapo::fetch(cfg).await,
        "elevenlabs" => elevenlabs::fetch(cfg).await,
        "deepgram" => deepgram::fetch(cfg).await,
        "groq" => groq::fetch(cfg).await,
        "kiro" => kiro::fetch(cfg).await,
        "bedrock" => bedrock::fetch(cfg).await,
        "codex" => codex::fetch(cfg).await,
        "claude" => claude::fetch(cfg).await,
        "gemini" => gemini::fetch(cfg).await,
        "kilo" => kilo::fetch(cfg).await,
        "antigravity" => antigravity::fetch(cfg).await,
        "opencode" => opencode::fetch(cfg).await,
        "opencodego" => opencodego::fetch(cfg).await,
        "commandcode" => commandcode::fetch(cfg).await,
        "cursor" => cursor::fetch(cfg).await,
        "mimo" => mimo::fetch(cfg).await,
        "alibaba" => alibaba::fetch(cfg).await,
        "freemodel" => freemodel::fetch(cfg).await,
        "copilot" => copilot::fetch(cfg).await,
        other => ProviderStatus::failure(
            other,
            &display_name(cfg),
            "Chưa hỗ trợ trên Linux (đang port)",
        ),
    }
}

/// Fetch enabled providers concurrently, optionally restricted to `ids`.
/// `None` fetches every enabled provider; `Some(ids)` only fetches providers
/// whose id is in the set, preserving config order. Used by the JS poller so
/// a provider with a longer refresh-interval override can be skipped on
/// cycles where it isn't due yet.
pub async fn fetch_filtered(ids: Option<&[String]>) -> Vec<ProviderStatus> {
    let providers = filter_enabled(config::enabled_providers(), ids);
    let futures = providers.iter().map(fetch);
    futures::future::join_all(futures).await
}

/// Keep only providers whose id is in `ids`, or all of them when `ids` is
/// `None`. Extracted for unit testing without a network round-trip.
fn filter_enabled(providers: Vec<config::Provider>, ids: Option<&[String]>) -> Vec<config::Provider> {
    match ids {
        None => providers,
        Some(ids) => providers
            .into_iter()
            .filter(|p| ids.iter().any(|id| id == &p.id))
            .collect(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn provider(id: &str) -> config::Provider {
        config::Provider { id: id.to_string(), ..Default::default() }
    }

    #[test]
    fn filter_enabled_none_keeps_all() {
        let providers = vec![provider("claude"), provider("codex"), provider("zai")];
        let result = filter_enabled(providers, None);
        assert_eq!(result.len(), 3);
    }

    #[test]
    fn filter_enabled_some_keeps_only_matching_ids_in_order() {
        let providers = vec![provider("claude"), provider("codex"), provider("zai")];
        let ids = vec!["zai".to_string(), "claude".to_string()];
        let result = filter_enabled(providers, Some(&ids));
        let got: Vec<&str> = result.iter().map(|p| p.id.as_str()).collect();
        assert_eq!(got, vec!["claude", "zai"]);
    }

    #[test]
    fn filter_enabled_empty_ids_keeps_none() {
        let providers = vec![provider("claude"), provider("codex")];
        let ids: Vec<String> = vec![];
        let result = filter_enabled(providers, Some(&ids));
        assert!(result.is_empty());
    }
}

pub fn shared_client() -> reqwest::Client {
    reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(15))
        .user_agent("BirdNion-Linux")
        .build()
        .expect("reqwest client")
}
