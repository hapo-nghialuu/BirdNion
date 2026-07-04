//! Provider quota framework — Rust mirror of the macOS `QuotaProvider`
//! protocol + `ProviderStatus`/`QuotaWindow` models. Each provider module
//! exposes `async fn fetch(cfg: &config::Provider) -> ProviderStatus`; the
//! registry dispatches by id and runs all enabled providers concurrently.

pub mod bedrock;
pub mod deepgram;
pub mod deepseek;
pub mod elevenlabs;
pub mod groq;
pub mod hapo;
pub mod kiro;
pub mod minimax;
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

#[derive(Serialize, Clone, Debug)]
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
}

impl ProviderStatus {
    pub fn failure(id: &str, display_name: &str, message: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            display_name: display_name.into(),
            windows: Vec::new(),
            last_updated: chrono::Utc::now().timestamp(),
            error: Some(message.into()),
            account_label: None,
            credits_remaining: None,
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
        other => ProviderStatus::failure(
            other,
            &display_name(cfg),
            "Chưa hỗ trợ trên Linux (đang port)",
        ),
    }
}

/// Fetch every enabled provider concurrently, preserving config order.
pub async fn fetch_all() -> Vec<ProviderStatus> {
    let providers = config::enabled_providers();
    let futures = providers.iter().map(fetch);
    futures::future::join_all(futures).await
}

pub fn shared_client() -> reqwest::Client {
    reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(15))
        .user_agent("BirdNion-Linux")
        .build()
        .expect("reqwest client")
}
