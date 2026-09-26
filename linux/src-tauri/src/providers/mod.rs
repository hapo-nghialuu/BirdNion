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
pub mod codex_prime;
pub mod commandcode;
pub mod copilot;
pub mod copilot_oauth;
pub mod cursor;
pub mod deepgram;
pub mod deepseek;
pub mod devin;
pub mod elevenlabs;
pub mod error_classifier;
pub mod freemodel;
pub mod gemini;
pub mod grok;
pub mod groq;
pub mod hapo;
pub mod hiyo;
pub mod kilo;
pub mod kiro;
pub mod mimo;
pub mod minimax;
pub mod ollama;
pub mod openai;
pub mod opencode;
pub mod opencodego;
pub mod openrouter;
pub mod tryapi;
pub mod xai;
pub mod zai;

use crate::config;
use serde::{Deserialize, Serialize};

#[derive(Deserialize, Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct QuotaAllowance {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub used: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub remaining: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub limit: Option<f64>,
    pub unit: String,
}

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
    /// Exact source-native allowance values. Absent when the source exposes
    /// only a percentage or no authoritative amount/limit.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub allowance: Option<QuotaAllowance>,
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
    /// Codex manual rate-limit reset credits (best-effort OAuth side channel).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reset_credits_available: Option<i32>,
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
        "devin" => "Devin",
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

/// Tail budget for the extras/enrichment phase of the two-phase split
/// (task-08): version/status-page/cookie-extras/reset-credits probes run
/// after the core quota status has already shipped, so they get their own
/// bounded budget instead of holding the fetch hostage. Mirrors the macOS
/// 30s extras SLO.
pub const EXTRAS_DEADLINE: std::time::Duration = std::time::Duration::from_secs(30);

/// Tauri event emitted once per provider after its extras phase settles.
/// Payload is the core `ProviderStatus` with enrichment fields merged on top
/// (`merge_status_extras`) — the JS side applies it onto the same provider id.
pub const PROVIDER_EXTRAS_EVENT: &str = "birdnion-provider-extras";

/// Merge an extras-phase status onto an already-published core status.
/// Enrichment fields fill gaps only — core quota/windows/account/error/
/// source data always wins (parity with macOS `ProviderStatus.withEnrichment`).
pub fn merge_status_extras(core: &mut ProviderStatus, extras: ProviderStatus) {
    if core.version.is_none() {
        core.version = extras.version;
    }
    if core.service_status.is_none() {
        core.service_status = extras.service_status;
    }
    if core.service_status_level.is_none() {
        core.service_status_level = extras.service_status_level;
    }
    if core.reset_credits_available.is_none() {
        core.reset_credits_available = extras.reset_credits_available;
    }
    if core.signed_in_email.is_none() {
        core.signed_in_email = extras.signed_in_email;
    }
    if core.code_review_remaining_percent.is_none() {
        core.code_review_remaining_percent = extras.code_review_remaining_percent;
    }
    if core.credits_purchase_url.is_none() {
        core.credits_purchase_url = extras.credits_purchase_url;
    }
    if core.credits_history_count.is_none() {
        core.credits_history_count = extras.credits_history_count;
    }
    if core.credits_remaining.is_none() {
        core.credits_remaining = extras.credits_remaining;
    }
    if core.kiro_context_percent.is_none() {
        core.kiro_context_percent = extras.kiro_context_percent;
    }
    core.credits_unlimited |= extras.credits_unlimited;
}

/// True when an extras-phase status carries at least one enrichment field —
/// the emit gate for `PROVIDER_EXTRAS_EVENT`. An empty tail (non-split
/// provider, timed-out probe, dropped stale extras) must not emit a no-op.
fn extras_has_fields(status: &ProviderStatus) -> bool {
    status.version.is_some()
        || status.service_status.is_some()
        || status.service_status_level.is_some()
        || status.reset_credits_available.is_some()
        || status.signed_in_email.is_some()
        || status.code_review_remaining_percent.is_some()
        || status.credits_purchase_url.is_some()
        || status.credits_history_count.is_some()
        || status.credits_remaining.is_some()
        || status.kiro_context_percent.is_some()
        || status.credits_unlimited
}

/// Core-phase fetch — quota/account/plan data only, bounded by
/// `FETCH_DEADLINE` exactly like the pre-split `fetch`. Enrichment probes
/// live in `fetch_extras` so a slow status page can never delay the card.
pub async fn fetch_core(cfg: &config::Provider) -> ProviderStatus {
    with_deadline(cfg, FETCH_DEADLINE, dispatch_core(cfg)).await
}

/// Extras-phase fetch — enrichment-only status bounded by `EXTRAS_DEADLINE`.
/// A timeout yields a field-less status, which `extras_has_fields` then
/// filters out of the emit path.
pub async fn fetch_extras(cfg: &config::Provider) -> ProviderStatus {
    with_deadline(cfg, EXTRAS_DEADLINE, dispatch_extras(cfg)).await
}

/// Spawn one provider's detached extras tail: fetch extras, merge onto the
/// already-shipped core, hand the merged status to `emit_extras` only when
/// enrichment fields are actually present.
fn spawn_extras<F>(cfg: config::Provider, core: ProviderStatus, emit_extras: F)
where
    F: Fn(ProviderStatus) + Send + 'static,
{
    tauri::async_runtime::spawn(async move {
        let extras = fetch_extras(&cfg).await;
        if extras_has_fields(&extras) {
            let mut merged = core;
            merge_status_extras(&mut merged, extras);
            emit_extras(merged);
        }
    });
}

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
async fn fetch_with_deadline(
    cfg: &config::Provider,
    deadline: std::time::Duration,
) -> ProviderStatus {
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
async fn with_deadline<F>(
    cfg: &config::Provider,
    deadline: std::time::Duration,
    fut: F,
) -> ProviderStatus
where
    F: std::future::Future<Output = ProviderStatus>,
{
    match tokio::time::timeout(deadline, fut).await {
        Ok(status) => status,
        Err(_) => ProviderStatus::failure(
            &cfg.id,
            &display_name(cfg),
            format!(
                "Timeout: provider did not respond within {}s",
                deadline.as_secs()
            ),
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
        "devin" => devin::fetch(cfg).await,
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

/// Core-phase dispatch: providers with a real two-phase split return fast
/// here; every other provider runs its unchanged single-phase `fetch`.
async fn dispatch_core(cfg: &config::Provider) -> ProviderStatus {
    match cfg.id.as_str() {
        "codex" => codex::fetch_core(cfg).await,
        "claude" => claude::fetch_core(cfg).await,
        #[cfg(test)]
        "probe-two-phase" => ProviderStatus {
            id: cfg.id.clone(),
            display_name: display_name(cfg),
            windows: vec![QuotaWindow {
                label: "probe".to_string(),
                used_pct: 10,
                remaining_pct: 90,
                subtitle: None,
                resets_at: None,
                window_seconds: None,
                semantic_key: None,
                semantic_kind: None,
            }],
            last_updated: chrono::Utc::now().timestamp(),
            ..Default::default()
        },
        _ => dispatch(cfg).await,
    }
}

/// Extras-phase dispatch: only split providers produce enrichment fields;
/// everyone else returns a field-less status (`extras_has_fields` ⇒ no emit).
async fn dispatch_extras(cfg: &config::Provider) -> ProviderStatus {
    match cfg.id.as_str() {
        "codex" => codex::fetch_extras(cfg).await,
        "claude" => claude::fetch_extras(cfg).await,
        #[cfg(test)]
        "probe-two-phase" => {
            // Deliberately slow extras — ProbeTwoPhase asserts the core
            // result ships before this tail resolves.
            tokio::time::sleep(std::time::Duration::from_millis(300)).await;
            ProviderStatus {
                id: cfg.id.clone(),
                display_name: display_name(cfg),
                last_updated: chrono::Utc::now().timestamp(),
                version: Some("probe 1.0".to_string()),
                ..Default::default()
            }
        }
        _ => ProviderStatus {
            id: cfg.id.clone(),
            display_name: display_name(cfg),
            last_updated: chrono::Utc::now().timestamp(),
            ..Default::default()
        },
    }
}

/// Fetch enabled providers concurrently, optionally restricted to `ids`.
/// `None` fetches every enabled provider; `Some(ids)` only fetches providers
/// whose id is in the set, preserving config order. Used by the JS poller so
/// a provider with a longer refresh-interval override can be skipped on
/// cycles where it isn't due yet.
///
/// Two-phase contract (task-08): the returned statuses are *core* results.
/// Each provider's extras tail is spawned detached; when it produces
/// enrichment fields the merged status is handed to `emit_extras`
/// (`provider_statuses` maps that onto `app.emit(PROVIDER_EXTRAS_EVENT, _)`).
pub async fn fetch_filtered<F>(ids: Option<&[String]>, emit_extras: F) -> Vec<ProviderStatus>
where
    F: Fn(ProviderStatus) + Send + Sync + Clone + 'static,
{
    fetch_core_and_spawn_extras(&filter_enabled(config::enabled_providers(), ids), emit_extras)
        .await
}

/// The two-phase pipeline over an explicit provider list — split out so tests
/// can drive it without touching the global enabled-providers config. All
/// core fetches run concurrently; each settled core spawns its detached
/// extras tail and ships immediately — extras never gate the return.
async fn fetch_core_and_spawn_extras<F>(
    providers: &[config::Provider],
    emit_extras: F,
) -> Vec<ProviderStatus>
where
    F: Fn(ProviderStatus) + Send + Sync + Clone + 'static,
{
    let futures = providers.iter().map(|cfg| {
        let emit_extras = emit_extras.clone();
        async move {
            let core = fetch_core(cfg).await;
            spawn_extras(cfg.clone(), core.clone(), emit_extras);
            core
        }
    });
    futures::future::join_all(futures).await
}

/// Keep only providers whose id is in `ids`, or all of them when `ids` is
/// `None`. Extracted for unit testing without a network round-trip.
fn filter_enabled(
    providers: Vec<config::Provider>,
    ids: Option<&[String]>,
) -> Vec<config::Provider> {
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
        config::Provider {
            id: id.to_string(),
            ..Default::default()
        }
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
        let status = block_on(with_deadline(
            &cfg,
            std::time::Duration::from_millis(20),
            slow,
        ));
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

    /// Merge fills enrichment gaps only — core fields (windows/account/error/
    /// source/credits already set) always win.
    #[test]
    fn merge_status_extras_fills_gaps_never_overwrites_core() {
        let mut core = ProviderStatus {
            id: "x".into(),
            display_name: "X".into(),
            windows: vec![QuotaWindow {
                label: "w".into(),
                used_pct: 5,
                remaining_pct: 95,
                subtitle: None,
                resets_at: None,
                window_seconds: None,
                semantic_key: None,
                semantic_kind: None,
            }],
            last_updated: 1,
            error: Some("core err".into()),
            account_label: Some("core acct".into()),
            credits_remaining: Some(7.0),
            source_label: Some("OAuth".into()),
            ..Default::default()
        };
        let extras = ProviderStatus {
            id: "x".into(),
            display_name: "X".into(),
            last_updated: 2,
            version: Some("v1".into()),
            service_status: Some("Operational".into()),
            service_status_level: Some("none".into()),
            reset_credits_available: Some(3),
            signed_in_email: Some("a@b.c".into()),
            credits_remaining: Some(99.0),
            credits_unlimited: true,
            ..Default::default()
        };
        merge_status_extras(&mut core, extras);
        assert_eq!(core.version.as_deref(), Some("v1"));
        assert_eq!(core.service_status.as_deref(), Some("Operational"));
        assert_eq!(core.reset_credits_available, Some(3));
        assert_eq!(core.signed_in_email.as_deref(), Some("a@b.c"));
        assert!(core.credits_unlimited);
        assert_eq!(core.credits_remaining, Some(7.0), "core credits win");
        assert_eq!(core.error.as_deref(), Some("core err"));
        assert_eq!(core.account_label.as_deref(), Some("core acct"));
        assert_eq!(core.source_label.as_deref(), Some("OAuth"));
        assert_eq!(core.windows.len(), 1);
        assert_eq!(core.last_updated, 1, "extras never bumps lastUpdated");
    }

    /// `extras_has_fields` gates the emit path — an empty extras tail (e.g.
    /// a non-split provider or a timed-out probe) must not emit.
    #[test]
    fn extras_has_fields_gates_emit() {
        assert!(!extras_has_fields(&ProviderStatus {
            id: "x".into(),
            display_name: "X".into(),
            last_updated: 1,
            ..Default::default()
        }));
        assert!(extras_has_fields(&ProviderStatus {
            id: "x".into(),
            display_name: "X".into(),
            last_updated: 1,
            version: Some("v".into()),
            ..Default::default()
        }));
    }

    /// ProbeTwoPhase: a fixture provider whose extras sleep. The core result
    /// must resolve before the extras settle, and the spawned extras tail
    /// emits the merged status onto the same provider id.
    #[test]
    fn two_phase_core_ships_before_extras_and_emits_merged() {
        block_on(async {
            let cfg = provider("probe-two-phase");
            let core = fetch_core(&cfg).await;
            assert!(core.error.is_none(), "probe core failed: {:?}", core.error);
            assert_eq!(core.windows.len(), 1);
            assert!(core.version.is_none(), "core must not carry extras fields");

            let (tx, rx) = std::sync::mpsc::channel();
            spawn_extras(cfg, core.clone(), move |merged| {
                let _ = tx.send(merged);
            });

            // The extras tail sleeps 300ms — nothing may be emitted yet.
            assert!(
                rx.recv_timeout(std::time::Duration::from_millis(100)).is_err(),
                "extras emitted before its fetch resolved"
            );
            let merged = rx
                .recv_timeout(std::time::Duration::from_secs(3))
                .expect("extras emit must arrive after the tail settles");
            assert_eq!(merged.id, "probe-two-phase");
            assert_eq!(merged.version.as_deref(), Some("probe 1.0"));
            assert_eq!(merged.windows.len(), 1, "merge keeps core windows");
        });
    }

    /// Command-path counterexample: the pipeline must return core results
    /// *before* the 300ms extras sleep resolves. If `fetch_filtered` ever
    /// awaited the extras tail, this test fails on the elapsed check.
    #[test]
    fn pipeline_returns_core_before_extras_settle() {
        block_on(async {
            let cfg = provider("probe-two-phase");
            let (tx, rx) = std::sync::mpsc::channel();
            let start = std::time::Instant::now();
            let statuses =
                fetch_core_and_spawn_extras(&[cfg], move |merged| {
                    let _ = tx.send(merged);
                })
                .await;
            assert!(
                start.elapsed() < std::time::Duration::from_millis(250),
                "pipeline waited on the 300ms extras tail: {:?}",
                start.elapsed()
            );
            assert_eq!(statuses.len(), 1);
            assert!(statuses[0].version.is_none(), "core ships without extras");
            let merged = rx
                .recv_timeout(std::time::Duration::from_secs(3))
                .expect("extras emit must arrive after the tail settles");
            assert_eq!(merged.id, "probe-two-phase");
            assert_eq!(merged.version.as_deref(), Some("probe 1.0"));
            assert_eq!(merged.windows.len(), 1, "merge keeps core windows");
        });
    }

    /// Non-split providers emit a single phase: their extras tail resolves
    /// field-less, so `spawn_extras` never fires the emit callback.
    #[test]
    fn non_split_provider_never_emits_extras() {
        block_on(async {
            let cfg = provider("unsupported-thing");
            let core = fetch_core(&cfg).await;
            assert!(core.error.is_some(), "unknown id still reports its status");
            let (tx, rx) = std::sync::mpsc::channel();
            spawn_extras(cfg, core, move |merged| {
                let _ = tx.send(merged);
            });
            assert!(
                rx.recv_timeout(std::time::Duration::from_millis(500)).is_err(),
                "non-split provider must not emit an extras event"
            );
        });
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
                        extension.eq_ignore_ascii_case("cmd")
                            || extension.eq_ignore_ascii_case("bat")
                    }) {
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
