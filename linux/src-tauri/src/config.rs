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
