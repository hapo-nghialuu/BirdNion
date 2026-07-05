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
}

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
        "minimax" => Some("MINIMAX_CODING_API_KEY"),
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
