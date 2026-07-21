//! Reader for the shared BirdNion config file — the SAME schema and path
//! resolution as the macOS `BirdNionConfigStore`, so one settings.json works
//! on both OSes: `$BIRDNION_CONFIG` → `$XDG_CONFIG_HOME/birdnion/settings.json`
//! → `~/.config/birdnion/settings.json` → legacy `~/.birdnion/settings.json`.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Deserialize, Serialize, Clone, Debug, Default)]
pub struct Settings {
    #[serde(default)]
    pub version: u32,
    #[serde(default)]
    pub providers: Vec<Provider>,
    /// Active Codex account id ("system" or a managed account UUID). Linux
    /// equivalent of the macOS `UserDefaults` key `activeCodexAccount` — kept
    /// here since there is no UserDefaults on Linux.
    #[serde(default)]
    pub active_codex_account: Option<String>,
    /// Active FreeModel account id ("browser" or a managed account UUID) —
    /// Linux-only multi-account feature; cookies live in a separate
    /// `freemodel-accounts.json` sibling file.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub active_freemodel_account: Option<String>,
    /// Active ElevenLabs multi-key id — keys live in `elevenlabs-keys.json`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub active_elevenlabs_key: Option<String>,
    /// Active Hiyo multi-key id — keys live in `hiyo-keys.json`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub active_hiyo_key: Option<String>,
    /// Custom Claude Code backends (Settings → Claude Code → "TUỲ CHỈNH") —
    /// same schema and top-level key as macOS `BirdNionConfigStore`.
    #[serde(default, rename = "claudeCodeProfiles", skip_serializing_if = "Vec::is_empty")]
    pub claude_code_profiles: Vec<ClaudeCodeProfile>,
    /// Third-party Codex CLI backends — macOS `BirdNionConfigStore.codexProfiles`.
    /// Linked 1:1 with Claude Code profiles via `codexProfileID` ⇄ `claudeCodeProfileID`.
    #[serde(default, rename = "codexProfiles", skip_serializing_if = "Vec::is_empty")]
    pub codex_profiles: Vec<CodexProfile>,
    /// App appearance: "light" | "dark" | "auto". Linux equivalent of macOS
    /// UserDefaults `appAppearance` (Settings → General → Giao diện).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub appearance: Option<String>,
    /// Any top-level keys this build doesn't know about (e.g. written by a
    /// newer macOS version) must survive a Linux round-trip save.
    #[serde(flatten)]
    pub extra: serde_json::Map<String, serde_json::Value>,
}

/// One custom Claude Code profile — mirrors the macOS `ClaudeCodeProfile`
/// JSON exactly (`baseURL` capitalization included).
#[derive(Deserialize, Serialize, Clone, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeCodeProfile {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, rename = "baseURL", skip_serializing_if = "Option::is_none")]
    pub base_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub token: Option<String>,
    /// "ANTHROPIC_AUTH_TOKEN" (default) or "ANTHROPIC_API_KEY".
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub token_env_key: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub api_key_helper: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub haiku_model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sonnet_model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub opus_model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub claude_code_scope: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub claude_code_project_path: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub extra_env: Vec<ProfileEnvRow>,
    /// Nil preserves profiles created before protocol selection.
    /// Values: `"anthropic"` | `"openai"` (macOS `compatibilityMode`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub compatibility_mode: Option<String>,
    /// OpenAI-compatible upstream base — sent only to CLIProxyAPI, never to
    /// Claude Code settings. JSON key matches macOS: `openAIBaseURL`.
    #[serde(default, rename = "openAIBaseURL", skip_serializing_if = "Option::is_none")]
    pub open_ai_base_url: Option<String>,
    /// OpenAI-compatible upstream API key. JSON key: `openAIAPIKey`.
    #[serde(default, rename = "openAIAPIKey", skip_serializing_if = "Option::is_none")]
    pub open_ai_api_key: Option<String>,
    /// `"responses"` for OpenAI Responses; nil retains Chat Completions.
    /// JSON key: `openAIFormat`.
    #[serde(default, rename = "openAIFormat", skip_serializing_if = "Option::is_none")]
    pub open_ai_format: Option<String>,
    /// Explicit local-proxy mode (macOS `embeddedLocalProxy`). Nil keeps older
    /// Anthropic profiles on the direct path; OpenAI profiles default to proxy.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub embedded_local_proxy: Option<bool>,
    /// Loopback CLIProxyAPI base (typically `http://127.0.0.1:24323`).
    #[serde(default, rename = "cliProxyBaseURL", skip_serializing_if = "Option::is_none")]
    pub cli_proxy_base_url: Option<String>,
    /// Loopback API key written into Claude Code settings (not the upstream secret).
    #[serde(default, rename = "cliProxyAPIKey", skip_serializing_if = "Option::is_none")]
    pub cli_proxy_api_key: Option<String>,
    /// Management secret for CLIProxyAPI remote-management (stays in BirdNion config).
    #[serde(default, rename = "cliProxyManagementKey", skip_serializing_if = "Option::is_none")]
    pub cli_proxy_management_key: Option<String>,
    /// SHA-256 of the last successful CLIProxyAPI registration material.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cli_proxy_applied_signature: Option<String>,
    /// Optional link to the Codex configuration created from this upstream.
    #[serde(default, rename = "codexProfileID", skip_serializing_if = "Option::is_none")]
    pub codex_profile_id: Option<String>,
}

/// One third-party backend for Codex CLI. Codex only speaks OpenAI Responses
/// natively, so non-Responses upstreams use BirdNion's embedded CLIProxyAPI.
/// JSON keys match macOS `BirdNionConfigStore.CodexProfile` exactly.
#[derive(Deserialize, Serialize, Clone, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub struct CodexProfile {
    pub id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default, rename = "baseURL")]
    pub base_url: String,
    #[serde(default)]
    pub api_key: String,
    /// Single model id (Codex has no haiku/sonnet/opus tiers).
    #[serde(default)]
    pub model: String,
    /// `"responses"` | `"openai-chat"` | `"anthropic"`. Nil → responses.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub upstream_protocol_raw: Option<String>,
    /// `"direct"` | `"local-proxy"`. Non-Responses always resolve to local-proxy.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub connection_mode_raw: Option<String>,
    #[serde(default, rename = "cliProxyBaseURL", skip_serializing_if = "Option::is_none")]
    pub cli_proxy_base_url: Option<String>,
    #[serde(default, rename = "cliProxyAPIKey", skip_serializing_if = "Option::is_none")]
    pub cli_proxy_api_key: Option<String>,
    #[serde(default, rename = "cliProxyManagementKey", skip_serializing_if = "Option::is_none")]
    pub cli_proxy_management_key: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cli_proxy_applied_signature: Option<String>,
    /// Optional reverse link to the Claude Code profile sharing this upstream.
    #[serde(default, rename = "claudeCodeProfileID", skip_serializing_if = "Option::is_none")]
    pub claude_code_profile_id: Option<String>,
}

impl CodexProfile {
    pub const PROTOCOL_RESPONSES: &'static str = "responses";
    pub const PROTOCOL_OPENAI_CHAT: &'static str = "openai-chat";
    pub const PROTOCOL_ANTHROPIC: &'static str = "anthropic";
    pub const MODE_DIRECT: &'static str = "direct";
    pub const MODE_LOCAL_PROXY: &'static str = "local-proxy";

    pub fn upstream_protocol(&self) -> &str {
        match self.upstream_protocol_raw.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
            Some(Self::PROTOCOL_OPENAI_CHAT) => Self::PROTOCOL_OPENAI_CHAT,
            Some(Self::PROTOCOL_ANTHROPIC) => Self::PROTOCOL_ANTHROPIC,
            _ => Self::PROTOCOL_RESPONSES,
        }
    }

    pub fn requires_embedded_cli_proxy(&self) -> bool {
        self.upstream_protocol() != Self::PROTOCOL_RESPONSES
    }

    pub fn connection_mode(&self) -> &str {
        if self.requires_embedded_cli_proxy() {
            return Self::MODE_LOCAL_PROXY;
        }
        match self.connection_mode_raw.as_deref().map(str::trim) {
            Some(Self::MODE_LOCAL_PROXY) => Self::MODE_LOCAL_PROXY,
            _ => Self::MODE_DIRECT,
        }
    }

    pub fn uses_embedded_cli_proxy(&self) -> bool {
        self.connection_mode() == Self::MODE_LOCAL_PROXY
    }

    pub fn has_upstream_configuration(&self) -> bool {
        cleaned_str(&self.base_url).is_some()
            && cleaned_str(&self.api_key).is_some()
            && cleaned_str(&self.model).is_some()
    }

    /// macOS `cliProxyProviderName` → `birdnion-codex-<safe-id>`.
    pub fn cli_proxy_provider_name(&self) -> String {
        let safe: String = self
            .id
            .to_lowercase()
            .chars()
            .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
            .collect();
        format!("birdnion-codex-{safe}")
    }
}

/// One KEY=value row of a custom profile's extra env.
#[derive(Deserialize, Serialize, Clone, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub struct ProfileEnvRow {
    pub id: String,
    #[serde(default)]
    pub key: String,
    #[serde(default)]
    pub value: String,
}

/// Find a custom Claude Code profile by id.
pub fn find_profile(id: &str) -> Option<ClaudeCodeProfile> {
    load().claude_code_profiles.into_iter().find(|p| p.id == id)
}

/// Process-wide lock for tests that mutate `BIRDNION_CONFIG`/env vars —
/// every test module touching the config env MUST hold this one lock, or
/// parallel `cargo test` runs clobber each other's temp dirs.
#[cfg(test)]
pub(crate) static TEST_ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// One provider entry. All fields except `id` are optional in the file —
/// mirrors the Swift `BirdNionConfigStore.Provider`.
#[derive(Deserialize, Serialize, Clone, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub struct Provider {
    pub id: String,
    #[serde(default)]
    pub api_key: Option<String>,
    #[serde(default)]
    pub enabled: Option<bool>,
    #[serde(default)]
    pub region: Option<String>,
    /// Per-provider refresh cadence override in seconds. 0/None = use the
    /// global interval (mirrors macOS `refreshInterval.<id>` UserDefaults).
    #[serde(default)]
    pub refresh_interval: Option<u64>,
    /// Whether this provider is included in the tray tooltip rotation.
    /// Default true (mirrors macOS `menuBarVisibility.<id>`, default shown).
    #[serde(default)]
    pub show_in_tray: Option<bool>,
    #[serde(default)]
    pub base_url: Option<String>,
    #[serde(default)]
    pub display_name: Option<String>,
    #[serde(default)]
    pub account_label: Option<String>,
    /// Deepgram: optional project filter; blank = aggregate every project.
    #[serde(default)]
    pub project_id: Option<String>,
    /// Bedrock: secret key (paired with `api_key` as the access key id).
    #[serde(default)]
    pub secret_key: Option<String>,
    /// Bedrock: "keys" (default) or "profile".
    #[serde(default)]
    pub aws_auth_mode: Option<String>,
    /// Bedrock: named ~/.aws profile, used when `aws_auth_mode == "profile"`.
    #[serde(default)]
    pub aws_profile: Option<String>,
    /// Bedrock: optional monthly budget (USD) for the spend window.
    #[serde(default)]
    pub budget: Option<f64>,
    /// Cookie-based providers: "auto" (default, read browser cookie stores),
    /// "manual" (use `manual_cookie`), or "off".
    #[serde(default)]
    pub cookie_source: Option<String>,
    /// Cookie-based providers: raw Cookie header value pasted by the user.
    #[serde(default)]
    pub manual_cookie: Option<String>,
    /// Claude: Anthropic Admin API key for the org usage/cost dashboard
    /// (`/v1/organizations/...`). Separate from `api_key` (OAuth token file).
    #[serde(default)]
    pub admin_api_key: Option<String>,
    /// Claude: primary data source — "auto" (default), "oauth", "web"
    /// (claude.ai cookie), "cli" (not ported on Linux), or "api" (Admin API).
    /// Mirrors macOS `ClaudeUsageDataSource` / `UserDefaults` key
    /// `claudeUsageDataSource`.
    #[serde(default)]
    pub source: Option<String>,

    /// Claude Code env config (Settings → "Claude Code"). Chosen model ids per
    /// tier are written to `ANTHROPIC_DEFAULT_*_MODEL` in the Claude Code
    /// `settings.json`. Mirrors the macOS `BirdNionConfigStore.Provider` field
    /// names exactly so the shared settings.json stays compatible both ways.
    #[serde(default)]
    pub claude_haiku_model: Option<String>,
    #[serde(default)]
    pub claude_sonnet_model: Option<String>,
    #[serde(default)]
    pub claude_opus_model: Option<String>,
    /// Maps to `CLAUDE_CODE_DISABLE_1M_CONTEXT` ("1" when true). Nil/false = unset.
    #[serde(default, rename = "claudeDisable1M")]
    pub claude_disable_1m: Option<bool>,
    /// Last selected Claude Code target for this provider: "global" or "project".
    #[serde(default)]
    pub claude_code_scope: Option<String>,
    /// Last selected project directory path for this provider.
    #[serde(default)]
    pub claude_code_project_path: Option<String>,
    /// Derived Codex record for this preset (Anthropic → local proxy).
    #[serde(default, rename = "codexProfileID", skip_serializing_if = "Option::is_none")]
    pub codex_profile_id: Option<String>,
}

fn cleaned_str(value: &str) -> Option<String> {
    let t = value.trim();
    if t.is_empty() {
        None
    } else {
        Some(t.to_string())
    }
}

fn cleaned_opt(value: Option<&str>) -> Option<String> {
    value.and_then(|v| cleaned_str(v))
}

/// Claude upstream base — OpenAI-compatible profiles prefer `openAIBaseURL`.
pub fn claude_upstream_base_url(p: &ClaudeCodeProfile) -> Option<String> {
    let openai = cleaned_opt(p.compatibility_mode.as_deref()).as_deref() == Some("openai");
    if openai {
        cleaned_opt(p.open_ai_base_url.as_deref()).or_else(|| cleaned_opt(p.base_url.as_deref()))
    } else {
        cleaned_opt(p.base_url.as_deref())
    }
}

/// Claude upstream API key — OpenAI-compatible profiles prefer `openAIAPIKey`.
pub fn claude_upstream_api_key(p: &ClaudeCodeProfile) -> Option<String> {
    let openai = cleaned_opt(p.compatibility_mode.as_deref()).as_deref() == Some("openai");
    if openai {
        cleaned_opt(p.open_ai_api_key.as_deref()).or_else(|| cleaned_opt(p.token.as_deref()))
    } else {
        cleaned_opt(p.token.as_deref())
    }
}

fn claude_is_openai(p: &ClaudeCodeProfile) -> bool {
    cleaned_opt(p.compatibility_mode.as_deref()).as_deref() == Some("openai")
}

/// Create a Codex mirror from a custom Claude Code profile (macOS `makeCodexProfile`).
pub fn make_codex_profile_from_claude(claude: &ClaudeCodeProfile, id: String) -> CodexProfile {
    let protocol = if claude_is_openai(claude) {
        if cleaned_opt(claude.open_ai_format.as_deref()).as_deref() == Some("responses") {
            CodexProfile::PROTOCOL_RESPONSES
        } else {
            CodexProfile::PROTOCOL_OPENAI_CHAT
        }
    } else {
        CodexProfile::PROTOCOL_ANTHROPIC
    };
    let model = cleaned_opt(claude.sonnet_model.as_deref())
        .or_else(|| cleaned_opt(claude.haiku_model.as_deref()))
        .or_else(|| cleaned_opt(claude.opus_model.as_deref()))
        .unwrap_or_default();
    CodexProfile {
        id,
        name: cleaned_opt(claude.name.as_deref()).unwrap_or_default(),
        base_url: claude_upstream_base_url(claude).unwrap_or_default(),
        api_key: claude_upstream_api_key(claude).unwrap_or_default(),
        model,
        upstream_protocol_raw: Some(protocol.to_string()),
        connection_mode_raw: Some(
            if protocol == CodexProfile::PROTOCOL_RESPONSES {
                CodexProfile::MODE_DIRECT
            } else {
                CodexProfile::MODE_LOCAL_PROXY
            }
            .to_string(),
        ),
        claude_code_profile_id: Some(claude.id.clone()),
        ..Default::default()
    }
}

/// Pure upstream sync Claude → linked Codex. Never touches `model` (per-agent).
/// Returns the updated profile and whether any upstream field changed.
pub fn synced_codex_profile(claude: &ClaudeCodeProfile, codex: &CodexProfile) -> (CodexProfile, bool) {
    let mut updated = codex.clone();
    let new_base = claude_upstream_base_url(claude).unwrap_or_default();
    let new_key = claude_upstream_api_key(claude).unwrap_or_default();
    let new_protocol = if claude_is_openai(claude) {
        if cleaned_opt(claude.open_ai_format.as_deref()).as_deref() == Some("responses") {
            CodexProfile::PROTOCOL_RESPONSES
        } else {
            CodexProfile::PROTOCOL_OPENAI_CHAT
        }
    } else {
        CodexProfile::PROTOCOL_ANTHROPIC
    };

    let protocol_changed = updated.upstream_protocol() != new_protocol;
    updated.base_url = new_base;
    updated.api_key = new_key;
    updated.upstream_protocol_raw = Some(new_protocol.to_string());
    if protocol_changed {
        updated.connection_mode_raw = Some(
            if new_protocol == CodexProfile::PROTOCOL_RESPONSES {
                CodexProfile::MODE_DIRECT
            } else {
                CodexProfile::MODE_LOCAL_PROXY
            }
            .to_string(),
        );
    }

    let changed = updated.base_url != codex.base_url
        || updated.api_key != codex.api_key
        || updated.upstream_protocol() != codex.upstream_protocol()
        || updated.connection_mode_raw != codex.connection_mode_raw;
    if !changed {
        return (codex.clone(), false);
    }
    updated.cli_proxy_applied_signature = None;
    (updated, true)
}

/// Mirror Claude upstream → linked Codex records in one write (idempotent).
pub fn mirror_claude_to_codex(settings: &mut Settings) {
    for claude in settings.claude_code_profiles.clone() {
        let Some(codex_id) = cleaned_opt(claude.codex_profile_id.as_deref()) else {
            continue;
        };
        if let Some(idx) = settings.codex_profiles.iter().position(|c| c.id == codex_id) {
            let (synced, changed) = synced_codex_profile(&claude, &settings.codex_profiles[idx]);
            if changed {
                settings.codex_profiles[idx] = synced;
            }
        }
    }
}

/// macOS `migrateStandaloneCodexProfiles` — link orphan Codex records that have
/// a Claude counterpart. Preset-derived records (no claude link, linked only
/// via Provider.codexProfileID) are left alone. Safe no-op when empty.
pub fn migrate_standalone_codex_profiles(settings: &mut Settings) -> bool {
    let mut changed = false;
    let claude_ids: std::collections::HashSet<String> = settings
        .claude_code_profiles
        .iter()
        .map(|p| p.id.clone())
        .collect();

    for codex in &mut settings.codex_profiles {
        // Already linked or derived from a preset (no claudeCodeProfileID and
        // not matching any Claude name/id heuristics) → skip.
        if cleaned_opt(codex.claude_code_profile_id.as_deref()).is_some() {
            continue;
        }
        // If some Claude already points at this codex, restore reverse link.
        if let Some(claude) = settings
            .claude_code_profiles
            .iter()
            .find(|c| cleaned_opt(c.codex_profile_id.as_deref()).as_deref() == Some(codex.id.as_str()))
        {
            codex.claude_code_profile_id = Some(claude.id.clone());
            changed = true;
            continue;
        }
        // Orphan with matching Claude id in reverse field history — rare on Linux.
        let _ = &claude_ids;
    }
    changed
}

/// Find a Codex profile by id.
pub fn find_codex_profile(id: &str) -> Option<CodexProfile> {
    load().codex_profiles.into_iter().find(|p| p.id == id)
}

/// Upsert one Codex profile (does NOT mirror back to Claude).
pub fn save_codex_profile(profile: CodexProfile) -> Result<(), String> {
    let mut settings = load();
    if let Some(idx) = settings.codex_profiles.iter().position(|p| p.id == profile.id) {
        settings.codex_profiles[idx] = profile;
    } else {
        settings.codex_profiles.push(profile);
    }
    save(&settings)
}

/// Remove one Codex profile by id.
#[allow(dead_code)]
pub fn remove_codex_profile(id: &str) -> Result<(), String> {
    let mut settings = load();
    settings.codex_profiles.retain(|p| p.id != id);
    save(&settings)
}

/// Persist settings atomically with owner-only permissions (0600), matching
/// the macOS store — the file holds API keys in plaintext by design.
pub fn save(settings: &Settings) -> Result<(), String> {
    let path = config_path();
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    let json = serde_json::to_string_pretty(settings).map_err(|e| e.to_string())?;
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, json).map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600));
    }
    std::fs::rename(&tmp, &path).map_err(|e| e.to_string())
}

pub fn config_path() -> PathBuf {
    if let Ok(p) = std::env::var("BIRDNION_CONFIG") {
        if !p.trim().is_empty() {
            return PathBuf::from(p);
        }
    }
    let home = PathBuf::from(std::env::var("HOME").unwrap_or_default());
    let xdg = std::env::var("XDG_CONFIG_HOME")
        .ok()
        .filter(|s| !s.trim().is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join(".config"));
    let primary = xdg.join("birdnion/settings.json");
    if primary.exists() {
        return primary;
    }
    let legacy = home.join(".birdnion/settings.json");
    if legacy.exists() {
        return legacy;
    }
    primary
}

pub fn load() -> Settings {
    std::fs::read_to_string(config_path())
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

/// Enabled provider entries, in file order (drives the tab order).
pub fn enabled_providers() -> Vec<Provider> {
    load()
        .providers
        .into_iter()
        .filter(|p| p.enabled.unwrap_or(false))
        .collect()
}

/// Find a single provider entry by id, or a blank default when not present
/// (mirrors macOS's "nil = not yet configured" fallback).
pub fn find_provider(id: &str) -> Provider {
    load()
        .providers
        .into_iter()
        .find(|p| p.id == id)
        .unwrap_or_else(|| Provider { id: id.to_string(), ..Default::default() })
}


/// API key resolution: env override first (same variable names as macOS),
/// then the config file.
pub fn api_key(provider: &Provider) -> Option<String> {
    let env_var = match provider.id.as_str() {
        "openrouter" => Some("OPENROUTER_API_KEY"),
        "deepseek" => Some("DEEPSEEK_API_KEY"),
        "elevenlabs" => Some("ELEVENLABS_API_KEY"),
        "hiyo" => Some("HIYO_API_KEY"),
        "minimax" => Some("MINIMAX_CODING_API_KEY"),
        "openai" => Some("OPENAI_ADMIN_KEY"),
        "ollama" => Some("OLLAMA_API_KEY"),
        _ => None,
    };
    if let Some(var) = env_var {
        if let Ok(v) = std::env::var(var) {
            let v = v.trim().to_string();
            if !v.is_empty() {
                return Some(v);
            }
        }
    }
    provider
        .api_key
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(String::from)
}

#[cfg(test)]
mod codex_sync_tests {
    use super::*;

    fn sample_claude(compat: &str, format: Option<&str>) -> ClaudeCodeProfile {
        ClaudeCodeProfile {
            id: "claude-1".into(),
            name: Some("My Backend".into()),
            base_url: Some("https://api.anthropic.example".into()),
            token: Some("sk-anthropic".into()),
            sonnet_model: Some("sonnet-x".into()),
            haiku_model: Some("haiku-x".into()),
            compatibility_mode: Some(compat.into()),
            open_ai_base_url: Some("https://api.openai.example/v1".into()),
            open_ai_api_key: Some("sk-openai".into()),
            open_ai_format: format.map(str::to_string),
            ..Default::default()
        }
    }

    #[test]
    fn make_codex_from_anthropic_uses_local_proxy() {
        let claude = sample_claude("anthropic", None);
        let codex = make_codex_profile_from_claude(&claude, "cx-1".into());
        assert_eq!(codex.upstream_protocol(), CodexProfile::PROTOCOL_ANTHROPIC);
        assert_eq!(codex.connection_mode(), CodexProfile::MODE_LOCAL_PROXY);
        assert_eq!(codex.base_url, "https://api.anthropic.example");
        assert_eq!(codex.api_key, "sk-anthropic");
        assert_eq!(codex.model, "sonnet-x");
        assert_eq!(codex.claude_code_profile_id.as_deref(), Some("claude-1"));
    }

    #[test]
    fn make_codex_from_responses_defaults_direct() {
        let claude = sample_claude("openai", Some("responses"));
        let codex = make_codex_profile_from_claude(&claude, "cx-2".into());
        assert_eq!(codex.upstream_protocol(), CodexProfile::PROTOCOL_RESPONSES);
        assert_eq!(codex.connection_mode(), CodexProfile::MODE_DIRECT);
        assert_eq!(codex.base_url, "https://api.openai.example/v1");
        assert_eq!(codex.api_key, "sk-openai");
    }

    #[test]
    fn sync_mirrors_upstream_but_not_model() {
        let claude = sample_claude("openai", Some("responses"));
        let mut codex = make_codex_profile_from_claude(&claude, "cx-3".into());
        codex.model = "gpt-keep".into();
        let mut claude2 = claude.clone();
        claude2.open_ai_base_url = Some("https://new.example/v1".into());
        claude2.open_ai_api_key = Some("sk-new".into());
        let (synced, changed) = synced_codex_profile(&claude2, &codex);
        assert!(changed);
        assert_eq!(synced.base_url, "https://new.example/v1");
        assert_eq!(synced.api_key, "sk-new");
        assert_eq!(synced.model, "gpt-keep");
        assert!(synced.cli_proxy_applied_signature.is_none());
    }

    #[test]
    fn sync_only_resets_connection_on_protocol_change() {
        let claude = sample_claude("openai", Some("responses"));
        let mut codex = make_codex_profile_from_claude(&claude, "cx-4".into());
        // User explicitly chose proxy while staying on responses.
        codex.connection_mode_raw = Some(CodexProfile::MODE_LOCAL_PROXY.into());
        let (same_proto, changed_mode) = synced_codex_profile(&claude, &codex);
        // Upstream unchanged → no rewrite of connection.
        assert!(!changed_mode || same_proto.connection_mode_raw == codex.connection_mode_raw);

        let mut claude_chat = claude.clone();
        claude_chat.open_ai_format = None; // chat
        let (synced, changed) = synced_codex_profile(&claude_chat, &codex);
        assert!(changed);
        assert_eq!(synced.upstream_protocol(), CodexProfile::PROTOCOL_OPENAI_CHAT);
        assert_eq!(synced.connection_mode(), CodexProfile::MODE_LOCAL_PROXY);
    }

    #[test]
    fn mirror_is_idempotent() {
        let mut claude = sample_claude("anthropic", None);
        let codex = make_codex_profile_from_claude(&claude, "cx-5".into());
        claude.codex_profile_id = Some(codex.id.clone());
        let mut settings = Settings {
            claude_code_profiles: vec![claude],
            codex_profiles: vec![codex.clone()],
            ..Default::default()
        };
        mirror_claude_to_codex(&mut settings);
        let after1 = settings.codex_profiles[0].clone();
        mirror_claude_to_codex(&mut settings);
        assert_eq!(settings.codex_profiles[0].base_url, after1.base_url);
        assert_eq!(settings.codex_profiles[0].api_key, after1.api_key);
        assert_eq!(settings.codex_profiles[0].model, codex.model);
    }

    #[test]
    fn migrate_standalone_restores_reverse_link() {
        let mut claude = sample_claude("anthropic", None);
        claude.codex_profile_id = Some("cx-orphan".into());
        let codex = CodexProfile {
            id: "cx-orphan".into(),
            name: "My Backend".into(),
            claude_code_profile_id: None,
            ..Default::default()
        };
        let mut settings = Settings {
            claude_code_profiles: vec![claude],
            codex_profiles: vec![codex],
            ..Default::default()
        };
        assert!(migrate_standalone_codex_profiles(&mut settings));
        assert_eq!(
            settings.codex_profiles[0].claude_code_profile_id.as_deref(),
            Some("claude-1")
        );
    }

    #[test]
    fn codex_profile_json_roundtrip_camel_case() {
        let p = CodexProfile {
            id: "id-1".into(),
            name: "N".into(),
            base_url: "https://x".into(),
            api_key: "k".into(),
            model: "m".into(),
            upstream_protocol_raw: Some("responses".into()),
            connection_mode_raw: Some("direct".into()),
            cli_proxy_base_url: Some("http://127.0.0.1:24323".into()),
            cli_proxy_api_key: Some("local".into()),
            cli_proxy_management_key: Some("mgmt".into()),
            cli_proxy_applied_signature: Some("sig".into()),
            claude_code_profile_id: Some("cc-1".into()),
        };
        let v = serde_json::to_value(&p).unwrap();
        assert!(v.get("baseURL").is_some());
        assert!(v.get("apiKey").is_some());
        assert!(v.get("upstreamProtocolRaw").is_some());
        assert!(v.get("connectionModeRaw").is_some());
        assert!(v.get("cliProxyBaseURL").is_some());
        assert!(v.get("cliProxyAPIKey").is_some());
        assert!(v.get("claudeCodeProfileID").is_some());
        let back: CodexProfile = serde_json::from_value(v).unwrap();
        assert_eq!(back.id, "id-1");
        assert_eq!(back.cli_proxy_provider_name(), "birdnion-codex-id-1");
    }
}
