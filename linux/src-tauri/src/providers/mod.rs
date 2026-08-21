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
pub mod grok;
pub mod groq;
pub mod hapo;
pub mod hiyo;
pub mod ollama;
pub mod openai;
pub mod kilo;
pub mod kiro;
pub mod mimo;
pub mod minimax;
pub mod opencode;
pub mod opencodego;
pub mod openrouter;
pub mod tryapi;
pub mod xai;
pub mod zai;

use serde::{Deserialize, Serialize};
use crate::config;

#[derive(Deserialize, Serialize, Clone, Debug)]
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
    /// Window length in seconds (5h = 18 000, week = 604 800) — with
    /// `resets_at`, drives the settings pace/reserve line (macOS WindowPace).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub window_seconds: Option<i64>,
    /// Stable provider-defined identity for future quota observations.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub semantic_key: Option<String>,
    /// Optional provider-defined semantic kind (for example `session`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub semantic_kind: Option<String>,
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
    /// Billing tier id (codex: "plus"/"pro") — settings grid "Gói" row.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub plan_type: Option<String>,
    /// Human plan label ("Claude Max", "Creator"…) — grid "Tên gói" row.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub plan_name: Option<String>,
    /// CLI version string ("codex-cli 0.144.1") — codex/claude only.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    /// statuspage.io description ("All Systems Operational") + indicator
    /// level ("none"|"minor"|"major"|"critical") — codex/claude only.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub service_status: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub service_status_level: Option<String>,
    /// Which data path produced this status ("OAuth"/"Web"/"Cookie"/"Admin API").
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_label: Option<String>,
    /// "∞ Unlimited" credits (codex plans without metered credits).
    #[serde(default)]
    pub credits_unlimited: bool,
    /// Kiro context-window usage % from `kiro-cli /context` (best-effort).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub kiro_context_percent: Option<f64>,
    /// Menu bar metric preference — wired from config so tray resolver
    /// can read it without a second settings fetch.
    #[serde(skip_serializing_if = "Option::is_none", rename = "menuBarMetric")]
    pub menu_bar_metric: Option<String>,
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
        "hiyo" => "Hiyo",
        "elevenlabs" => "ElevenLabs",
        "deepgram" => "Deepgram",
        "groq" => "Groq",
        "grok" => "Grok",
        "xai" => "xAI",
        "openai" => "OpenAI",
        "ollama" => "Ollama",
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
        "gemini" => "Gemini",
        "antigravity" => "Antigravity",
        "tryapi" => "TryAPI",
        other => other,
    }
    .to_string()
}

/// Hard outer deadline for a single provider fetch, shared by the JS refresh
/// poller (`provider_statuses`) AND the Settings self-test (`test_provider`)
/// — both funnel through `fetch()` below. Mirrors macOS
/// `ProviderFetchDeadline`: a pure backstop well above the slowest known
/// legitimate chain (e.g. Claude's cold CLI probe), not a replacement for
/// any provider's own internal timeouts.
pub const FETCH_DEADLINE: std::time::Duration = std::time::Duration::from_secs(200);

/// Fetch one provider's status by id, bounded by `FETCH_DEADLINE` so a
/// hung/misbehaving provider can never stall the caller — refresh pass or
/// self-test — forever. Unknown/not-yet-ported ids return a clear "chưa hỗ
/// trợ" status instead of failing the whole refresh.
pub async fn fetch(cfg: &config::Provider) -> ProviderStatus {
    fetch_with_deadline(cfg, FETCH_DEADLINE).await
}

/// Races `dispatch(cfg)` against `deadline` via `with_deadline`. Extracted
/// from `fetch()` so tests can pass a tiny deadline without waiting out the
/// real `FETCH_DEADLINE`.
async fn fetch_with_deadline(cfg: &config::Provider, deadline: std::time::Duration) -> ProviderStatus {
    with_deadline(cfg, deadline, dispatch(cfg)).await
}

/// Races an arbitrary fetch future against `deadline`. Whichever finishes
/// first wins; the loser is dropped (best-effort cancellation — a future
/// blocked on non-cooperative I/O may keep its underlying work running, but
/// this call never waits past `deadline`). The timeout status's error
/// message contains "Timeout" so `error_classifier::classify` resolves it to
/// `NetworkUnreachableOrTimeout`. Split out from `fetch_with_deadline` so
/// tests can race a deliberately slow fake future without depending on
/// `dispatch`'s real provider modules.
async fn with_deadline<F>(cfg: &config::Provider, deadline: std::time::Duration, fut: F) -> ProviderStatus
where
    F: std::future::Future<Output = ProviderStatus>,
{
    match tokio::time::timeout(deadline, fut).await {
        Ok(status) => status,
        Err(_) => ProviderStatus::failure(
            &cfg.id,
            &display_name(cfg),
            format!("Timeout: provider did not respond within {}s", deadline.as_secs()),
        ),
    }
}

/// Provider id -> concrete fetch dispatch. Never call directly outside of
/// `fetch()` / `fetch_with_deadline()` — that's what applies the shared
/// deadline.
async fn dispatch(cfg: &config::Provider) -> ProviderStatus {
    match cfg.id.as_str() {
        "openrouter" => openrouter::fetch(cfg).await,
        "deepseek" => deepseek::fetch(cfg).await,
        "zai" => zai::fetch(cfg).await,
        "minimax" => minimax::fetch(cfg).await,
        "hapo" => hapo::fetch(cfg).await,
        "hiyo" => hiyo::fetch(cfg).await,
        "elevenlabs" => elevenlabs::fetch(cfg).await,
        "deepgram" => deepgram::fetch(cfg).await,
        "groq" => groq::fetch(cfg).await,
        "grok" => grok::fetch(cfg).await,
        "xai" => xai::fetch(cfg).await,
        "openai" => openai::fetch(cfg).await,
        "ollama" => ollama::fetch(cfg).await,
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
        "tryapi" => tryapi::fetch(cfg).await,
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

    /// Throwaway current-thread runtime — avoids the `#[tokio::test]` macro
    /// (which needs tokio's "macros" feature; this crate only enables
    /// "time" + "rt", matching the antigravity.rs sleep-only precedent).
    fn block_on<F: std::future::Future>(fut: F) -> F::Output {
        tokio::runtime::Builder::new_current_thread()
            .enable_time()
            .build()
            .unwrap()
            .block_on(fut)
    }

    #[test]
    fn with_deadline_times_out_a_slow_future() {
        let cfg = provider("slow");
        let slow = async {
            tokio::time::sleep(std::time::Duration::from_secs(2)).await;
            ProviderStatus::failure("slow", "Slow", "should never be seen")
        };
        let status = block_on(with_deadline(&cfg, std::time::Duration::from_millis(20), slow));
        let err = status.error.expect("timeout must set an error");
        assert!(err.contains("Timeout"), "unexpected error: {err}");
        assert!(status.windows.is_empty());
        assert_eq!(
            error_classifier::classify(Some(&err)),
            Some(error_classifier::ProviderErrorKind::NetworkUnreachableOrTimeout)
        );
    }

    #[test]
    fn with_deadline_returns_fast_future_result_unchanged() {
        let cfg = provider("fast");
        let fast = async {
            ProviderStatus {
                id: "fast".into(),
                display_name: "Fast".into(),
                ..Default::default()
            }
        };
        let status = block_on(with_deadline(&cfg, std::time::Duration::from_secs(5), fast));
        assert!(status.error.is_none());
        assert_eq!(status.id, "fast");
    }
}

pub fn shared_client() -> reqwest::Client {
    reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(15))
        .user_agent(concat!("BirdNion/", env!("CARGO_PKG_VERSION")))
        .build()
        .expect("reqwest client")
}

/// Best-effort statuspage.io probe — port of macOS `OpenAIStatusProbe` /
/// `ClaudeProvider.fetchServiceStatus`. Returns `(description, indicator)`
/// like ("All Systems Operational", "none"); `None` on any failure so it can
/// never break the primary quota fetch it runs alongside.
pub async fn fetch_service_status(url: &str) -> Option<(String, String)> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(8))
        .user_agent(concat!("BirdNion/", env!("CARGO_PKG_VERSION")))
        .build()
        .ok()?;
    let json: serde_json::Value = client.get(url).send().await.ok()?.json().await.ok()?;
    let status = json.get("status")?;
    let description = status.get("description")?.as_str()?.to_string();
    let indicator = status.get("indicator")?.as_str()?.to_string();
    Some((description, indicator))
}

/// Memoized `<cli> --version` output (first line, trimmed) — port of macOS
/// `ClaudeCLIVersionDetector` / `CodexProvider` version detection. Runs the
/// binary at most once per process; call from a blocking thread.
pub fn cli_version_blocking(
    cache: &'static std::sync::OnceLock<Option<String>>,
    binary: &str,
) -> Option<String> {
    cache
        .get_or_init(|| {
            let executable = crate::platform::executable::resolve_executable(binary)?;
            let mut command = if cfg!(windows)
                && executable
                .extension()
                .and_then(|extension| extension.to_str())
                .is_some_and(|extension| {
                    extension.eq_ignore_ascii_case("cmd") || extension.eq_ignore_ascii_case("bat")
                })
            {
                let script = executable.to_str()?;
                if script.contains(['"', '&', '|', '<', '>', '^', '%', '!', '(', ')']) {
                    return None;
                }
                let shell = std::env::var_os("COMSPEC")
                    .filter(|value| !value.is_empty())
                    .unwrap_or_else(|| "cmd.exe".into());
                let mut command = std::process::Command::new(shell);
                command
                    .args(["/D", "/E:ON", "/V:OFF", "/S", "/C"])
                    .arg(format!("\"\"{script}\" --version\""));
                command
            } else {
                let mut command = std::process::Command::new(executable);
                command.arg("--version");
                command
            };
            command
                .output()
                .ok()
                .filter(|out| out.status.success())
                .and_then(|out| String::from_utf8(out.stdout).ok())
                .and_then(|s| s.lines().next().map(|l| l.trim().to_string()))
                .filter(|s| !s.is_empty())
        })
        .clone()
}
