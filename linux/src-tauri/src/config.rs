//! Reader for the shared BirdNion config file — the SAME schema and path
//! resolution as the macOS `BirdNionConfigStore`, so one settings.json works
//! across supported OSes. Resolution starts with `$BIRDNION_CONFIG`, then uses
//! `%APPDATA%\\birdnion\\settings.json` on Windows or the XDG config path on
//! Unix, followed by the legacy user-home location.

use serde::{Deserialize, Serialize};
use std::{
    ffi::OsString,
    fs::File,
    path::{Path, PathBuf},
};

static SETTINGS_MUTATION_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
const MAX_SETTINGS_BYTES: usize = 8 * 1024 * 1024;

/// Stable sibling lock file shared by every BirdNion backend process. The
/// descriptor lock spans strict read, revision/content checks, and atomic
/// replacement; keeping the file in place avoids split-lock inode races.
struct SettingsInterprocessLock {
    _file: File,
}

impl SettingsInterprocessLock {
    fn acquire(settings: &BoundSettingsFile) -> Result<Self, String> {
        let mut lock_name = OsString::from(&settings.name);
        lock_name.push(".birdnion.lock");
        let file = settings
            .directory
            .open_private_lock_file_at(&lock_name)
            .map_err(|error| {
                format!(
                    "cannot open settings mutation lock at {}: {error}",
                    settings.display_path.display()
                )
            })?;
        file.lock().map_err(|error| {
            format!(
                "cannot acquire settings mutation lock at {}: {error}",
                settings.display_path.display()
            )
        })?;
        Ok(Self { _file: file })
    }
}

/// Stable parent-directory binding for one settings transaction. The config
/// pathname is resolved once; every recovery/read/commit then stays relative
/// to this descriptor even if an external process renames the parent path.
struct BoundSettingsFile {
    directory: crate::platform::atomic_file::BoundDirectory,
    name: OsString,
    display_path: PathBuf,
    parent_path: PathBuf,
}

impl BoundSettingsFile {
    fn open(path: &Path) -> Result<Self, String> {
        let parent = path
            .parent()
            .ok_or_else(|| "settings path has no parent directory".to_string())?;
        let name = path
            .file_name()
            .ok_or_else(|| "settings path has no file name".to_string())?
            .to_os_string();
        let directory =
            crate::platform::atomic_file::BoundDirectory::open(parent).map_err(|error| {
                format!(
                    "cannot bind settings directory at {}: {error}",
                    parent.display()
                )
            })?;
        Ok(Self {
            directory,
            name,
            display_path: path.to_path_buf(),
            parent_path: parent.to_path_buf(),
        })
    }

    fn ensure_current_route(&self) -> Result<(), String> {
        let current = crate::platform::atomic_file::BoundDirectory::open(&self.parent_path)
            .map_err(|error| {
                format!(
                    "settings directory route changed at {}: {error}",
                    self.parent_path.display()
                )
            })?;
        if current.identity() != self.directory.identity() {
            return Err(
                "settings directory route changed during operation; reload before saving"
                    .to_string(),
            );
        }
        Ok(())
    }
}

struct SettingsTransaction {
    file: BoundSettingsFile,
    _lock: SettingsInterprocessLock,
}

impl SettingsTransaction {
    fn acquire(path: &Path) -> Result<Self, String> {
        let parent = path
            .parent()
            .ok_or_else(|| "settings path has no parent directory".to_string())?;
        let parent_was_missing = match std::fs::symlink_metadata(parent) {
            Ok(metadata) if !metadata.is_dir() || metadata.file_type().is_symlink() => {
                return Err("settings parent is not a real directory".to_string())
            }
            Ok(_) => false,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => true,
            Err(error) => return Err(error.to_string()),
        };
        if parent_was_missing {
            #[cfg(unix)]
            {
                use std::os::unix::fs::DirBuilderExt;
                let mut builder = std::fs::DirBuilder::new();
                builder.recursive(true).mode(0o700);
                builder.create(parent).map_err(|error| error.to_string())?;
            }
            #[cfg(not(unix))]
            crate::platform::atomic_file::ensure_private_directory(parent)
                .map_err(|error| error.to_string())?;
        }
        let file = BoundSettingsFile::open(path)?;
        let lock = SettingsInterprocessLock::acquire(&file)?;
        file.ensure_current_route()?;
        Ok(Self { file, _lock: lock })
    }
}

#[derive(Deserialize, Serialize, Clone, Debug, Default)]
pub struct Settings {
    #[serde(default)]
    pub version: u32,
    /// Optimistic-concurrency token for whole-document Settings saves.
    /// Older macOS/Linux builds preserve this unknown top-level camelCase key;
    /// files created before the token existed decode as revision zero.
    #[serde(default, rename = "settingsRevision")]
    pub settings_revision: u64,
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
    #[serde(
        default,
        rename = "claudeCodeProfiles",
        skip_serializing_if = "Vec::is_empty"
    )]
    pub claude_code_profiles: Vec<ClaudeCodeProfile>,
    /// Third-party Codex CLI backends — macOS `BirdNionConfigStore.codexProfiles`.
    /// Linked 1:1 with Claude Code profiles via `codexProfileID` ⇄ `claudeCodeProfileID`.
    #[serde(
        default,
        rename = "codexProfiles",
        skip_serializing_if = "Vec::is_empty"
    )]
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
    #[serde(
        default,
        rename = "openAIBaseURL",
        skip_serializing_if = "Option::is_none"
    )]
    pub open_ai_base_url: Option<String>,
    /// OpenAI-compatible upstream API key. JSON key: `openAIAPIKey`.
    #[serde(
        default,
        rename = "openAIAPIKey",
        skip_serializing_if = "Option::is_none"
    )]
    pub open_ai_api_key: Option<String>,
    /// `"responses"` for OpenAI Responses; nil retains Chat Completions.
    /// JSON key: `openAIFormat`.
    #[serde(
        default,
        rename = "openAIFormat",
        skip_serializing_if = "Option::is_none"
    )]
    pub open_ai_format: Option<String>,
    /// Explicit local-proxy mode (macOS `embeddedLocalProxy`). Nil keeps older
    /// Anthropic profiles on the direct path; OpenAI profiles default to proxy.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub embedded_local_proxy: Option<bool>,
    /// Loopback CLIProxyAPI base (typically `http://127.0.0.1:24323`).
    #[serde(
        default,
        rename = "cliProxyBaseURL",
        skip_serializing_if = "Option::is_none"
    )]
    pub cli_proxy_base_url: Option<String>,
    /// Loopback API key written into Claude Code settings (not the upstream secret).
    #[serde(
        default,
        rename = "cliProxyAPIKey",
        skip_serializing_if = "Option::is_none"
    )]
    pub cli_proxy_api_key: Option<String>,
    /// Management secret for CLIProxyAPI remote-management (stays in BirdNion config).
    #[serde(
        default,
        rename = "cliProxyManagementKey",
        skip_serializing_if = "Option::is_none"
    )]
    pub cli_proxy_management_key: Option<String>,
    /// SHA-256 of the last successful CLIProxyAPI registration material.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cli_proxy_applied_signature: Option<String>,
    /// Optional link to the Codex configuration created from this upstream.
    #[serde(
        default,
        rename = "codexProfileID",
        skip_serializing_if = "Option::is_none"
    )]
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
    #[serde(
        default,
        rename = "cliProxyBaseURL",
        skip_serializing_if = "Option::is_none"
    )]
    pub cli_proxy_base_url: Option<String>,
    #[serde(
        default,
        rename = "cliProxyAPIKey",
        skip_serializing_if = "Option::is_none"
    )]
    pub cli_proxy_api_key: Option<String>,
    #[serde(
        default,
        rename = "cliProxyManagementKey",
        skip_serializing_if = "Option::is_none"
    )]
    pub cli_proxy_management_key: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cli_proxy_applied_signature: Option<String>,
    /// Optional reverse link to the Claude Code profile sharing this upstream.
    #[serde(
        default,
        rename = "claudeCodeProfileID",
        skip_serializing_if = "Option::is_none"
    )]
    pub claude_code_profile_id: Option<String>,
}

impl CodexProfile {
    pub const PROTOCOL_RESPONSES: &'static str = "responses";
    pub const PROTOCOL_OPENAI_CHAT: &'static str = "openai-chat";
    pub const PROTOCOL_ANTHROPIC: &'static str = "anthropic";
    pub const MODE_DIRECT: &'static str = "direct";
    pub const MODE_LOCAL_PROXY: &'static str = "local-proxy";

    pub fn upstream_protocol(&self) -> &str {
        match self
            .upstream_protocol_raw
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
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
    #[serde(
        default,
        rename = "codexProfileID",
        skip_serializing_if = "Option::is_none"
    )]
    pub codex_profile_id: Option<String>,
    /// Menu bar metric preference: "automatic" | "primary" | "secondary" | "primaryAndSecondary" | "tertiary" | "extraUsage" | "average" | "monthlyPlan"
    /// Mirrors macOS `MenuBarMetricPreference` enum stored in UserDefaults `menuBarMetric.<provider>`.
    #[serde(
        default,
        rename = "menuBarMetric",
        skip_serializing_if = "Option::is_none"
    )]
    pub menu_bar_metric: Option<String>,
    /// Any per-provider keys this build doesn't model yet (e.g. written by a
    /// newer macOS version) must survive a Linux round-trip save.
    #[serde(flatten)]
    pub extra: serde_json::Map<String, serde_json::Value>,
}

/// Resolve menu bar metric preference from provider config.
/// Returns the preference string if valid, None for missing/invalid (fallback to automatic).
pub fn resolve_menu_bar_metric(provider: &Provider) -> Option<&str> {
    match provider.menu_bar_metric.as_deref() {
        Some(m) if !m.trim().is_empty() => Some(m.trim()),
        _ => None,
    }
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
pub fn synced_codex_profile(
    claude: &ClaudeCodeProfile,
    codex: &CodexProfile,
) -> (CodexProfile, bool) {
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
        if let Some(idx) = settings
            .codex_profiles
            .iter()
            .position(|c| c.id == codex_id)
        {
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
        if let Some(claude) = settings.claude_code_profiles.iter().find(|c| {
            cleaned_opt(c.codex_profile_id.as_deref()).as_deref() == Some(codex.id.as_str())
        }) {
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
    update(|settings| {
        if let Some(idx) = settings
            .codex_profiles
            .iter()
            .position(|p| p.id == profile.id)
        {
            settings.codex_profiles[idx] = profile;
        } else {
            settings.codex_profiles.push(profile);
        }
        Ok(())
    })
}

/// Remove one Codex profile by id.
#[allow(dead_code)]
pub fn remove_codex_profile(id: &str) -> Result<(), String> {
    update(|settings| {
        settings.codex_profiles.retain(|p| p.id != id);
        Ok(())
    })
}

/// Persist settings atomically with owner-only permissions (0600), matching
/// the macOS store — the file holds API keys in plaintext by design.
///
/// Fail-closed: every write path performs a strict read under the mutation
/// lock. If an existing file cannot be read or decoded, no fallback/default
/// document is allowed to overwrite it.
pub fn save(settings: &Settings) -> Result<(), String> {
    let _guard = SETTINGS_MUTATION_LOCK
        .lock()
        .unwrap_or_else(|error| error.into_inner());
    let path = config_path().ok_or_else(config_path_error)?;
    let transaction = SettingsTransaction::acquire(&path)?;
    save_snapshot_unlocked(&transaction.file, settings.clone()).map(|_| ())
}

pub fn update<R>(mutate: impl FnOnce(&mut Settings) -> Result<R, String>) -> Result<R, String> {
    let _guard = SETTINGS_MUTATION_LOCK
        .lock()
        .unwrap_or_else(|error| error.into_inner());
    let path = config_path().ok_or_else(config_path_error)?;
    let transaction = SettingsTransaction::acquire(&path)?;
    let (mut settings, expected_bytes) = read_for_mutation_unlocked(&transaction.file)?;
    let current_revision = settings.settings_revision;
    let result = mutate(&mut settings)?;
    settings.settings_revision = next_settings_revision(current_revision)?;
    write_unlocked(&transaction.file, &settings, expected_bytes.as_deref())?;
    Ok(result)
}

/// Persist a whole-document snapshot received from the frontend. The snapshot
/// must match the latest revision returned by `get_settings`; otherwise a
/// newer frontend save or dedicated backend mutation happened while the pane
/// was open, and the UI must reload instead of overwriting that newer state.
pub fn save_frontend_snapshot(incoming: Settings) -> Result<u64, String> {
    let _guard = SETTINGS_MUTATION_LOCK
        .lock()
        .unwrap_or_else(|error| error.into_inner());
    let path = config_path().ok_or_else(config_path_error)?;
    let transaction = SettingsTransaction::acquire(&path)?;
    save_snapshot_unlocked(&transaction.file, incoming)
}

fn save_snapshot_unlocked(file: &BoundSettingsFile, mut incoming: Settings) -> Result<u64, String> {
    let (current, expected_bytes) = read_for_mutation_unlocked(file)?;
    if incoming.settings_revision != current.settings_revision {
        return Err(format!(
            "stale settings snapshot: expected revision {}, received {}; reload settings before saving",
            current.settings_revision, incoming.settings_revision
        ));
    }

    preserve_unknown_fields(&mut incoming, &current);
    incoming.settings_revision = next_settings_revision(current.settings_revision)?;
    write_unlocked(file, &incoming, expected_bytes.as_deref())?;
    Ok(incoming.settings_revision)
}

fn preserve_unknown_fields(incoming: &mut Settings, current: &Settings) {
    for (key, value) in &current.extra {
        incoming
            .extra
            .entry(key.clone())
            .or_insert_with(|| value.clone());
    }
    for provider in &mut incoming.providers {
        let Some(current_provider) = current.providers.iter().find(|item| item.id == provider.id)
        else {
            continue;
        };
        for (key, value) in &current_provider.extra {
            provider
                .extra
                .entry(key.clone())
                .or_insert_with(|| value.clone());
        }
    }
}

fn next_settings_revision(current: u64) -> Result<u64, String> {
    current
        .checked_add(1)
        .ok_or_else(|| "settings revision overflow; refusing to overwrite config".to_string())
}

fn read_for_mutation_unlocked(
    file: &BoundSettingsFile,
) -> Result<(Settings, Option<Vec<u8>>), String> {
    file.ensure_current_route()?;
    crate::platform::atomic_file::recover_private_json_atomic_at::<Settings>(
        &file.directory,
        &file.name,
    )
    .map_err(|error| {
        format!(
            "refusing to recover unreadable config at {}: {error}",
            file.display_path.display()
        )
    })?;
    let existing = crate::platform::atomic_file::read_regular_file_bounded_at(
        &file.directory,
        &file.name,
        MAX_SETTINGS_BYTES,
    )
    .map_err(|error| {
        format!(
            "refusing to overwrite unreadable config at {}: {error}",
            file.display_path.display()
        )
    })?;
    let settings = match existing.as_deref() {
        Some(bytes) => serde_json::from_slice::<Settings>(bytes).map_err(|_| {
            format!(
                "refusing to overwrite unreadable config at {}: existing file is not valid JSON",
                file.display_path.display()
            )
        })?,
        None => Settings::default(),
    };
    file.ensure_current_route()?;
    Ok((settings, existing))
}

fn read_settings_file(file: &BoundSettingsFile) -> Result<Option<Settings>, String> {
    read_settings_file_with_hook(file, || {})
}

fn read_settings_file_with_hook(
    file: &BoundSettingsFile,
    after_route_check: impl FnOnce(),
) -> Result<Option<Settings>, String> {
    file.ensure_current_route()?;
    crate::platform::atomic_file::recover_private_json_atomic_at::<Settings>(
        &file.directory,
        &file.name,
    )
    .map_err(|error| error.to_string())?;
    after_route_check();
    let existing = crate::platform::atomic_file::read_regular_file_bounded_at(
        &file.directory,
        &file.name,
        MAX_SETTINGS_BYTES,
    )
    .map_err(|error| error.to_string())?;
    let settings = existing
        .as_deref()
        .map(serde_json::from_slice::<Settings>)
        .transpose()
        .map_err(|_| "existing file is not valid JSON".to_string())?;
    file.ensure_current_route()?;
    Ok(settings)
}

fn write_unlocked(
    file: &BoundSettingsFile,
    settings: &Settings,
    expected_bytes: Option<&[u8]>,
) -> Result<(), String> {
    file.ensure_current_route()?;
    let json = serde_json::to_string_pretty(settings).map_err(|e| e.to_string())?;
    if json.len() > MAX_SETTINGS_BYTES {
        return Err(format!(
            "settings document exceeds {MAX_SETTINGS_BYTES} byte limit; refusing to write"
        ));
    }
    let outcome =
        crate::platform::atomic_file::write_private_json_atomic_if_matches_at::<Settings>(
            &file.directory,
            &file.name,
            json.as_bytes(),
            expected_bytes,
        )
        .map_err(|error| error.to_string())?;
    file.ensure_current_route()?;
    match outcome {
        crate::platform::atomic_file::ConditionalWriteOutcome::Written => Ok(()),
        crate::platform::atomic_file::ConditionalWriteOutcome::Conflict => {
            Err("settings changed outside this mutation; reload before saving".to_string())
        }
    }
}

#[cfg(test)]
fn write_unlocked_with_hook(
    file: &BoundSettingsFile,
    settings: &Settings,
    expected_bytes: Option<&[u8]>,
    before_claim: impl FnOnce(),
) -> Result<(), String> {
    file.ensure_current_route()?;
    let json = serde_json::to_string_pretty(settings).map_err(|error| error.to_string())?;
    let outcome =
        crate::platform::atomic_file::write_private_json_atomic_if_matches_at_with_hook::<Settings>(
            &file.directory,
            &file.name,
            json.as_bytes(),
            expected_bytes,
            before_claim,
        )
        .map_err(|error| error.to_string())?;
    file.ensure_current_route()?;
    match outcome {
        crate::platform::atomic_file::ConditionalWriteOutcome::Written => Ok(()),
        crate::platform::atomic_file::ConditionalWriteOutcome::Conflict => {
            Err("settings changed outside this mutation; reload before saving".to_string())
        }
    }
}

pub fn config_path() -> Option<PathBuf> {
    crate::platform::paths::birdnion_config_path()
}

pub fn support_dir() -> Option<PathBuf> {
    config_path()?.parent().map(std::path::Path::to_path_buf)
}

fn config_path_error() -> String {
    "BirdNion config path unavailable: no platform config or user-home root".to_string()
}

pub fn load_checked() -> Result<Settings, String> {
    let path = config_path().ok_or_else(config_path_error)?;
    let _guard = SETTINGS_MUTATION_LOCK
        .lock()
        .unwrap_or_else(|error| error.into_inner());
    SettingsTransaction::acquire(&path)
        .and_then(|transaction| read_settings_file(&transaction.file))
        .map(|settings| settings.unwrap_or_default())
}

/// Non-authoritative backend reads preserve historical fallback behavior.
/// Frontend snapshots must use `load_checked()` so a transient read failure
/// can never masquerade as an authoritative empty revision-zero document.
pub fn load() -> Settings {
    load_checked().unwrap_or_default()
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
        .unwrap_or_else(|| Provider {
            id: id.to_string(),
            ..Default::default()
        })
}

/// API key resolution: env override first (same variable names as macOS),
/// then the config file.
pub fn api_key(provider: &Provider) -> Option<String> {
    let env_var = match provider.id.as_str() {
        "openrouter" => Some("OPENROUTER_API_KEY"),
        "deepseek" => Some("DEEPSEEK_API_KEY"),
        "elevenlabs" => Some("ELEVENLABS_API_KEY"),
        "hiyo" => Some("HIYO_API_KEY"),
        "tryapi" => Some("TRYAPI_API_KEY"),
        "minimax" => Some("MINIMAX_CODING_API_KEY"),
        "openai" => Some("OPENAI_ADMIN_KEY"),
        "xai" => Some("XAI_MANAGEMENT_API_KEY"),
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
        assert_eq!(
            synced.upstream_protocol(),
            CodexProfile::PROTOCOL_OPENAI_CHAT
        );
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

/// Regression coverage for the fail-closed + lossless-save invariant: `save()`
/// must never silently overwrite an existing-but-unreadable config file, and
/// must round-trip unknown top-level / per-provider keys untouched.
#[cfg(test)]
mod fail_closed_and_lossless_tests {
    use super::*;

    fn temp_config(tag: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("birdnion-config-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[cfg(unix)]
    #[test]
    fn settings_transactions_preserve_existing_parent_mode() {
        use std::os::unix::fs::PermissionsExt;

        let _guard = TEST_ENV_LOCK.lock().unwrap();
        let base = temp_config("existing-parent-mode");
        let path = base.join("settings.json");
        std::fs::set_permissions(&base, std::fs::Permissions::from_mode(0o750)).unwrap();
        std::fs::write(
            &path,
            br#"{"version":1,"settingsRevision":0,"providers":[]}"#,
        )
        .unwrap();
        std::env::set_var("BIRDNION_CONFIG", &path);

        assert_eq!(load_checked().unwrap().version, 1);
        assert_eq!(
            std::fs::metadata(&base).unwrap().permissions().mode() & 0o777,
            0o750
        );
        update(|settings| {
            settings.version = 2;
            Ok(())
        })
        .unwrap();
        assert_eq!(
            std::fs::metadata(&base).unwrap().permissions().mode() & 0o777,
            0o750
        );

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(base);
    }

    #[test]
    fn settings_file_lock_serializes_independent_descriptors() {
        use std::sync::mpsc;
        use std::time::Duration;

        let base = temp_config("interprocess-lock");
        let path = base.join("settings.json");
        let first_file = BoundSettingsFile::open(&path).unwrap();
        let first = SettingsInterprocessLock::acquire(&first_file).unwrap();
        let (started_tx, started_rx) = mpsc::channel();
        let (acquired_tx, acquired_rx) = mpsc::channel();
        let second_path = path.clone();
        let handle = std::thread::spawn(move || {
            started_tx.send(()).unwrap();
            let second_file = BoundSettingsFile::open(&second_path).unwrap();
            let result = SettingsInterprocessLock::acquire(&second_file);
            acquired_tx.send(result.is_ok()).unwrap();
        });

        started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(matches!(
            acquired_rx.recv_timeout(Duration::from_millis(100)),
            Err(mpsc::RecvTimeoutError::Timeout)
        ));
        drop(first);
        assert_eq!(acquired_rx.recv_timeout(Duration::from_secs(2)), Ok(true));
        handle.join().unwrap();
        let _ = std::fs::remove_dir_all(base);
    }

    #[test]
    fn load_waits_for_claim_then_recovers_valid_settings() {
        use std::sync::mpsc;
        use std::time::Duration;

        let _guard = TEST_ENV_LOCK.lock().unwrap();
        let base = temp_config("reader-claim-gap");
        let path = base.join("settings.json");
        let backup = base.join("settings.json.birdnion-cas-backup");
        std::fs::write(
            &path,
            br#"{"version":7,"settingsRevision":3,"providers":[]}"#,
        )
        .unwrap();
        std::env::set_var("BIRDNION_CONFIG", &path);

        let (claimed_tx, claimed_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let writer_path = path.clone();
        let writer_backup = backup.clone();
        let writer = std::thread::spawn(move || {
            let transaction = SettingsTransaction::acquire(&writer_path).unwrap();
            std::fs::rename(&writer_path, &writer_backup).unwrap();
            claimed_tx.send(()).unwrap();
            release_rx.recv_timeout(Duration::from_secs(2)).unwrap();
            drop(transaction);
        });
        claimed_rx.recv_timeout(Duration::from_secs(1)).unwrap();

        let (started_tx, started_rx) = mpsc::channel();
        let (loaded_tx, loaded_rx) = mpsc::channel();
        let reader = std::thread::spawn(move || {
            started_tx.send(()).unwrap();
            loaded_tx.send(load()).unwrap();
        });
        started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(matches!(
            loaded_rx.recv_timeout(Duration::from_millis(100)),
            Err(mpsc::RecvTimeoutError::Timeout)
        ));

        release_tx.send(()).unwrap();
        let loaded = loaded_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        assert_eq!(loaded.version, 7);
        assert_eq!(loaded.settings_revision, 3);
        writer.join().unwrap();
        reader.join().unwrap();
        assert!(path.exists());
        assert!(!backup.exists());

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(base);
    }

    #[test]
    fn save_refuses_to_overwrite_malformed_existing_file() {
        let _guard = TEST_ENV_LOCK.lock().unwrap();
        let base = temp_config("malformed");
        let path = base.join("settings.json");
        std::fs::write(&path, "{ this is not valid json").unwrap();
        std::env::set_var("BIRDNION_CONFIG", &path);

        let result = save(&Settings {
            version: 1,
            ..Default::default()
        });
        assert!(result.is_err());
        // The file on disk must be byte-for-byte untouched.
        assert_eq!(
            std::fs::read_to_string(&path).unwrap(),
            "{ this is not valid json"
        );

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn save_refuses_to_overwrite_empty_existing_file() {
        let _guard = TEST_ENV_LOCK.lock().unwrap();
        let base = temp_config("empty");
        let path = base.join("settings.json");
        std::fs::write(&path, "").unwrap();
        std::env::set_var("BIRDNION_CONFIG", &path);

        assert!(save(&Settings::default()).is_err());

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn save_refuses_to_overwrite_non_utf8_existing_file() {
        let _guard = TEST_ENV_LOCK.lock().unwrap();
        let base = temp_config("non-utf8");
        let path = base.join("settings.json");
        let original = [0xff, 0xfe, 0xfd];
        std::fs::write(&path, original).unwrap();
        std::env::set_var("BIRDNION_CONFIG", &path);

        assert!(save(&Settings::default()).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), original);

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[cfg(unix)]
    #[test]
    fn fifo_settings_path_fails_without_blocking_or_replacement() {
        use std::ffi::CString;
        use std::os::unix::ffi::OsStrExt;
        use std::os::unix::fs::FileTypeExt;
        use std::sync::mpsc;
        use std::time::Duration;

        let _guard = TEST_ENV_LOCK.lock().unwrap();
        let base = temp_config("fifo");
        let path = base.join("settings.json");
        let raw_path = CString::new(path.as_os_str().as_bytes()).unwrap();
        // SAFETY: `raw_path` is NUL-terminated and valid for this call.
        assert_eq!(unsafe { libc::mkfifo(raw_path.as_ptr(), 0o600) }, 0);
        std::env::set_var("BIRDNION_CONFIG", &path);
        let (sender, receiver) = mpsc::channel();
        let handle = std::thread::spawn(move || {
            let settings_path = config_path().unwrap();
            let settings_file = BoundSettingsFile::open(&settings_path).unwrap();
            let _ = sender.send((
                load().version,
                read_for_mutation_unlocked(&settings_file).is_err(),
            ));
        });

        let result = receiver.recv_timeout(Duration::from_secs(2));
        std::env::remove_var("BIRDNION_CONFIG");
        if result != Ok((0, true)) {
            let _ = std::fs::remove_dir_all(&base);
            panic!("opening a FIFO must fail closed instead of waiting for a writer: {result:?}");
        }
        handle.join().unwrap();
        assert!(std::fs::symlink_metadata(&path)
            .unwrap()
            .file_type()
            .is_fifo());
        let _ = std::fs::remove_dir_all(&base);
    }

    #[cfg(unix)]
    #[test]
    fn symlink_settings_path_is_not_followed_or_replaced() {
        use std::os::unix::fs::symlink;

        let _guard = TEST_ENV_LOCK.lock().unwrap();
        let base = temp_config("symlink");
        let path = base.join("settings.json");
        let target = base.join("target.json");
        let original = br#"{"version":7,"providers":[]}"#;
        std::fs::write(&target, original).unwrap();
        symlink(&target, &path).unwrap();
        std::env::set_var("BIRDNION_CONFIG", &path);

        assert_eq!(load().version, 0);
        assert!(save(&Settings {
            version: 8,
            ..Default::default()
        })
        .is_err());
        assert!(std::fs::symlink_metadata(&path)
            .unwrap()
            .file_type()
            .is_symlink());
        assert_eq!(std::fs::read(&target).unwrap(), original);

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn oversized_sparse_settings_is_not_read_or_overwritten() {
        let _guard = TEST_ENV_LOCK.lock().unwrap();
        let base = temp_config("oversized-sparse");
        let path = base.join("settings.json");
        let file = std::fs::File::create(&path).unwrap();
        file.set_len((MAX_SETTINGS_BYTES + 1) as u64).unwrap();
        drop(file);
        std::env::set_var("BIRDNION_CONFIG", &path);

        assert_eq!(load().version, 0);
        assert!(save(&Settings {
            version: 9,
            ..Default::default()
        })
        .is_err());
        assert_eq!(
            std::fs::metadata(&path).unwrap().len(),
            (MAX_SETTINGS_BYTES + 1) as u64
        );

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn save_fails_closed_when_no_config_root_is_available() {
        let _guard = TEST_ENV_LOCK.lock().unwrap();
        let keys = ["BIRDNION_CONFIG", "XDG_CONFIG_HOME", "HOME"];
        let previous: Vec<_> = keys
            .iter()
            .map(|key| (*key, std::env::var_os(key)))
            .collect();
        for key in keys {
            std::env::set_var(key, "");
        }

        assert!(config_path().is_none());
        assert!(support_dir().is_none());
        let result = save(&Settings::default());

        for (key, value) in previous {
            if let Some(value) = value {
                std::env::set_var(key, value);
            } else {
                std::env::remove_var(key);
            }
        }
        assert!(result.is_err());
    }

    #[test]
    fn save_allows_first_write_when_file_absent() {
        let _guard = TEST_ENV_LOCK.lock().unwrap();
        let base = temp_config("absent");
        let path = base.join("settings.json");
        std::env::set_var("BIRDNION_CONFIG", &path);

        assert!(save(&Settings {
            version: 1,
            ..Default::default()
        })
        .is_ok());
        assert!(path.exists());

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn save_preserves_unknown_top_level_key() {
        let _guard = TEST_ENV_LOCK.lock().unwrap();
        let base = temp_config("top-level");
        let path = base.join("settings.json");
        std::fs::write(
            &path,
            r#"{"version":1,"providers":[],"futureFeatureFlag":true}"#,
        )
        .unwrap();
        std::env::set_var("BIRDNION_CONFIG", &path);

        let mut settings = load();
        settings.version = 2;
        save(&settings).unwrap();

        let raw: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(
            raw.get("futureFeatureFlag"),
            Some(&serde_json::Value::Bool(true))
        );
        assert_eq!(raw.get("version"), Some(&serde_json::Value::from(2)));

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn save_preserves_unknown_per_provider_key() {
        let _guard = TEST_ENV_LOCK.lock().unwrap();
        let base = temp_config("per-provider");
        let path = base.join("settings.json");
        std::fs::write(
            &path,
            r#"{"version":1,"providers":[{"id":"claude","enabled":true,"futureProviderField":"keep-me"}]}"#,
        )
        .unwrap();
        std::env::set_var("BIRDNION_CONFIG", &path);

        let mut settings = load();
        settings.providers[0].account_label = Some("My Account".into());
        save(&settings).unwrap();

        let raw: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        let provider = &raw["providers"][0];
        assert_eq!(
            provider.get("futureProviderField"),
            Some(&serde_json::Value::from("keep-me"))
        );
        assert_eq!(
            provider.get("accountLabel"),
            Some(&serde_json::Value::from("My Account"))
        );

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn save_clears_known_optional_field() {
        let _guard = TEST_ENV_LOCK.lock().unwrap();
        let base = temp_config("clear-field");
        let path = base.join("settings.json");
        std::fs::write(
            &path,
            r#"{"version":1,"providers":[{"id":"claude","enabled":true,"accountLabel":"Old Label"}]}"#,
        )
        .unwrap();
        std::env::set_var("BIRDNION_CONFIG", &path);

        let mut settings = load();
        settings.providers[0].account_label = None;
        save(&settings).unwrap();

        let raw: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        let provider = &raw["providers"][0];
        // Cleared, not resurrected by the unknown-key merge (which only ever
        // applies to keys this build doesn't model).
        assert_eq!(provider.get("accountLabel"), Some(&serde_json::Value::Null));

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn stale_frontend_snapshot_is_rejected_after_dedicated_update() {
        let _guard = TEST_ENV_LOCK.lock().unwrap();
        let base = temp_config("frontend-snapshot-account-race");
        let path = base.join("settings.json");
        std::env::set_var("BIRDNION_CONFIG", &path);

        let initial = Settings {
            version: 1,
            active_codex_account: Some("account-a".into()),
            ..Default::default()
        };
        save(&initial).unwrap();
        let mut stale_frontend = load();
        assert_eq!(stale_frontend.settings_revision, 1);
        update(|current| {
            current.active_codex_account = Some("account-b".into());
            Ok(())
        })
        .unwrap();
        stale_frontend.version = 2;

        let error = save_frontend_snapshot(stale_frontend).unwrap_err();
        assert!(error.contains("stale settings snapshot"));
        let stored = load();
        assert_eq!(stored.version, 1);
        assert_eq!(stored.settings_revision, 2);
        assert_eq!(stored.active_codex_account.as_deref(), Some("account-b"));

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn stale_frontend_snapshot_is_rejected_after_newer_frontend_save() {
        let _guard = TEST_ENV_LOCK.lock().unwrap();
        let base = temp_config("frontend-snapshot-race");
        let path = base.join("settings.json");
        std::env::set_var("BIRDNION_CONFIG", &path);

        save(&Settings {
            version: 1,
            ..Default::default()
        })
        .unwrap();
        let mut stale_a = load();
        let mut fresh_b = stale_a.clone();
        fresh_b.version = 2;
        assert_eq!(save_frontend_snapshot(fresh_b).unwrap(), 2);

        stale_a.version = 3;
        let error = save_frontend_snapshot(stale_a).unwrap_err();
        assert!(error.contains("expected revision 2, received 1"));
        let stored = load();
        assert_eq!(stored.version, 2);
        assert_eq!(stored.settings_revision, 2);

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn fresh_frontend_snapshot_succeeds_and_returns_next_revision() {
        let _guard = TEST_ENV_LOCK.lock().unwrap();
        let base = temp_config("fresh-frontend-snapshot");
        let path = base.join("settings.json");
        std::env::set_var("BIRDNION_CONFIG", &path);

        save(&Settings {
            version: 1,
            ..Default::default()
        })
        .unwrap();
        let mut fresh = load();
        assert_eq!(fresh.settings_revision, 1);
        fresh.version = 2;

        assert_eq!(save_frontend_snapshot(fresh).unwrap(), 2);
        let stored = load();
        assert_eq!(stored.version, 2);
        assert_eq!(stored.settings_revision, 2);

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn external_content_change_after_mutation_read_is_not_overwritten() {
        let _guard = TEST_ENV_LOCK.lock().unwrap();
        let base = temp_config("external-content-cas");
        let path = base.join("settings.json");
        std::env::set_var("BIRDNION_CONFIG", &path);
        save(&Settings {
            version: 1,
            ..Default::default()
        })
        .unwrap();

        let file = BoundSettingsFile::open(&path).unwrap();
        let (mut local, expected_bytes) = read_for_mutation_unlocked(&file).unwrap();
        let mut external = local.clone();
        external.version = 9;
        external.settings_revision = local.settings_revision + 1;
        let external_bytes = serde_json::to_vec_pretty(&external).unwrap();
        crate::platform::atomic_file::write_private_atomic(&path, &external_bytes).unwrap();

        local.version = 2;
        local.settings_revision += 1;
        let error = write_unlocked(&file, &local, expected_bytes.as_deref()).unwrap_err();
        assert!(error.contains("settings changed outside this mutation"));
        assert_eq!(std::fs::read(&path).unwrap(), external_bytes);

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(base);
    }

    #[test]
    fn external_content_change_after_staging_is_not_overwritten() {
        let _guard = TEST_ENV_LOCK.lock().unwrap();
        let base = temp_config("external-staging-cas");
        let path = base.join("settings.json");
        std::env::set_var("BIRDNION_CONFIG", &path);
        save(&Settings {
            version: 1,
            ..Default::default()
        })
        .unwrap();

        let transaction = SettingsTransaction::acquire(&path).unwrap();
        let (mut local, expected_bytes) = read_for_mutation_unlocked(&transaction.file).unwrap();
        let mut external = local.clone();
        external.version = 9;
        external.settings_revision += 1;
        let external_bytes = serde_json::to_vec_pretty(&external).unwrap();
        local.version = 2;
        local.settings_revision += 1;

        let error =
            write_unlocked_with_hook(&transaction.file, &local, expected_bytes.as_deref(), || {
                crate::platform::atomic_file::write_private_atomic(&path, &external_bytes).unwrap();
            })
            .unwrap_err();
        assert!(error.contains("settings changed outside this mutation"));
        assert_eq!(std::fs::read(&path).unwrap(), external_bytes);
        drop(transaction);

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(base);
    }

    #[test]
    fn parent_swap_after_binding_never_reports_write_success() {
        let _guard = TEST_ENV_LOCK.lock().unwrap();
        let base = temp_config("settings-parent-swap-write");
        let current = base.join("current");
        let detached = base.join("detached");
        std::fs::create_dir(&current).unwrap();
        let path = current.join("settings.json");
        std::env::set_var("BIRDNION_CONFIG", &path);
        save(&Settings {
            version: 1,
            ..Default::default()
        })
        .unwrap();

        let transaction = SettingsTransaction::acquire(&path).unwrap();
        let (mut local, expected_bytes) = read_for_mutation_unlocked(&transaction.file).unwrap();
        local.version = 2;
        local.settings_revision += 1;
        let replacement = br#"{"version":9,"settingsRevision":9,"providers":[]}"#.to_vec();

        let error =
            write_unlocked_with_hook(&transaction.file, &local, expected_bytes.as_deref(), || {
                std::fs::rename(&current, &detached).unwrap();
                std::fs::create_dir(&current).unwrap();
                std::fs::write(&path, &replacement).unwrap();
            })
            .unwrap_err();
        assert!(error.contains("settings directory route changed"));
        assert_eq!(std::fs::read(&path).unwrap(), replacement);
        drop(transaction);

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(base);
    }

    #[test]
    fn parent_swap_after_read_precheck_never_returns_detached_default() {
        let _guard = TEST_ENV_LOCK.lock().unwrap();
        let base = temp_config("settings-parent-swap-read");
        let current = base.join("current");
        let detached = base.join("detached");
        std::fs::create_dir(&current).unwrap();
        let path = current.join("settings.json");
        let transaction = SettingsTransaction::acquire(&path).unwrap();
        let replacement =
            br#"{"version":9,"settingsRevision":0,"providers":[{"id":"claude","apiKey":"keep"}]}"#;

        let result = read_settings_file_with_hook(&transaction.file, || {
            std::fs::rename(&current, &detached).unwrap();
            std::fs::create_dir(&current).unwrap();
            std::fs::write(&path, replacement).unwrap();
        });
        assert!(result
            .unwrap_err()
            .contains("settings directory route changed"));
        assert_eq!(std::fs::read(&path).unwrap(), replacement);
        drop(transaction);

        let _ = std::fs::remove_dir_all(base);
    }

    #[test]
    fn revision_overflow_fails_without_mutating_existing_file() {
        let _guard = TEST_ENV_LOCK.lock().unwrap();
        let base = temp_config("revision-overflow");
        let path = base.join("settings.json");
        let original = format!(
            r#"{{"version":1,"settingsRevision":{},"providers":[]}}"#,
            u64::MAX
        );
        std::fs::write(&path, &original).unwrap();
        std::env::set_var("BIRDNION_CONFIG", &path);

        let error = save_frontend_snapshot(load()).unwrap_err();
        assert!(error.contains("settings revision overflow"));
        assert_eq!(std::fs::read_to_string(&path).unwrap(), original);

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn legacy_revision_zero_migrates_on_first_successful_update() {
        let _guard = TEST_ENV_LOCK.lock().unwrap();
        let base = temp_config("legacy-revision-zero");
        let path = base.join("settings.json");
        std::fs::write(&path, r#"{"version":1,"providers":[]}"#).unwrap();
        std::env::set_var("BIRDNION_CONFIG", &path);

        assert_eq!(load().settings_revision, 0);
        update(|settings| {
            settings.version = 2;
            Ok(())
        })
        .unwrap();

        let stored = load();
        assert_eq!(stored.version, 2);
        assert_eq!(stored.settings_revision, 1);
        let raw: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(
            raw.get("settingsRevision"),
            Some(&serde_json::Value::from(1))
        );

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn settings_revision_uses_frontend_camel_case_and_is_never_omitted() {
        let raw = serde_json::to_value(Settings::default()).unwrap();
        assert_eq!(
            raw.get("settingsRevision"),
            Some(&serde_json::Value::from(0))
        );
        assert!(raw.get("settings_revision").is_none());
    }

    #[test]
    fn frontend_snapshot_preserves_unknown_top_level_and_provider_keys() {
        let _guard = TEST_ENV_LOCK.lock().unwrap();
        let base = temp_config("frontend-unknown-fields");
        let path = base.join("settings.json");
        std::fs::write(
            &path,
            r#"{"version":1,"providers":[{"id":"claude","enabled":true,"futureProviderField":"keep-provider"}],"futureFeatureFlag":"keep-top"}"#,
        )
        .unwrap();
        std::env::set_var("BIRDNION_CONFIG", &path);

        let mut incoming = load();
        incoming.version = 2;
        // Frontend projections may omit fields they do not model. The backend
        // still owns lossless preservation for keys from newer app versions.
        incoming.extra.clear();
        incoming.providers[0].extra.clear();
        save_frontend_snapshot(incoming).unwrap();

        let raw: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(raw["futureFeatureFlag"], "keep-top");
        assert_eq!(raw["providers"][0]["futureProviderField"], "keep-provider");
        assert_eq!(raw["settingsRevision"], 1);

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn frontend_snapshot_refuses_malformed_existing_file_without_mutation() {
        let _guard = TEST_ENV_LOCK.lock().unwrap();
        let base = temp_config("frontend-malformed");
        let path = base.join("settings.json");
        let original = b"{ definitely not settings json";
        std::fs::write(&path, original).unwrap();
        std::env::set_var("BIRDNION_CONFIG", &path);

        let error = save_frontend_snapshot(Settings::default()).unwrap_err();
        assert!(error.contains("refusing to overwrite unreadable config"));
        assert_eq!(std::fs::read(&path).unwrap(), original);

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(&base);
    }
}
