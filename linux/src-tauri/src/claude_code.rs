//! Claude Code "quick-apply" — points the Claude Code CLI at a provider
//! backend by writing env keys (`ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`,
//! model names…) into `~/.claude/settings.json` (global scope) or
//! `<project>/.claude/settings.json` (project scope).
//!
//! Port of the macOS `ClaudeCodeConfigWriter` + `ClaudeCodeBackend`: MERGE-in-
//! place semantics (patch only the managed `env`/`apiKeyHelper` keys, never
//! clobber the rest of the user's settings.json), `deactivate` clears only the
//! managed block, `sync_state` detects on/off/stale by comparing the file
//! against the provider's current values.
//!
//! Pure functions operate on JSON content (`&str` in, `String` out) so unit
//! tests never touch the real filesystem; file wrappers layer the actual
//! `~/.claude/settings.json` (or `CLAUDE_CONFIG_DIR` override) I/O on top.

use crate::config::{ClaudeCodeProfile, Provider};
use serde_json::{Map, Value};
use std::path::PathBuf;

// Env keys this writer owns. Other env keys in the file are left untouched.
pub const AUTH_TOKEN_KEY: &str = "ANTHROPIC_AUTH_TOKEN";
pub const BASE_URL_KEY: &str = "ANTHROPIC_BASE_URL";
pub const HAIKU_KEY: &str = "ANTHROPIC_DEFAULT_HAIKU_MODEL";
pub const SONNET_KEY: &str = "ANTHROPIC_DEFAULT_SONNET_MODEL";
pub const OPUS_KEY: &str = "ANTHROPIC_DEFAULT_OPUS_MODEL";
pub const MODEL_KEY: &str = "ANTHROPIC_MODEL";
pub const DISABLE_1M_KEY: &str = "CLAUDE_CODE_DISABLE_1M_CONTEXT";

/// Where the env block is written.
#[derive(Debug, Clone, PartialEq)]
pub enum Scope {
    Global,
    /// Per-project: writes to `<projectDir>/.claude/settings.json`.
    Project(PathBuf),
}

/// Whether the settings file for a scope points at this config and whether
/// the written values still match the current source (drift detection).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SyncState {
    /// File does not point here (base URL differs / absent).
    Off,
    /// File matches every managed value.
    Synced,
    /// File points here (base URL matches) but a managed value differs.
    Stale,
}

/// Popover/settings power-button state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PowerState {
    On,
    Off,
    Stale,
    NeedsSetup,
}

pub fn power_state(configured: bool, sync: SyncState) -> PowerState {
    if !configured {
        return PowerState::NeedsSetup;
    }
    match sync {
        SyncState::Synced => PowerState::On,
        SyncState::Stale => PowerState::Stale,
        SyncState::Off => PowerState::Off,
    }
}

/// A resolved set of Claude Code settings to write: the env keys/values this
/// config owns, plus an optional top-level `apiKeyHelper`.
#[derive(Debug, Clone, PartialEq)]
pub struct EnvSpec {
    pub env: Map<String, Value>,
    pub api_key_helper: Option<String>,
}

impl EnvSpec {
    pub fn base_url(&self) -> Option<&str> {
        self.env.get(BASE_URL_KEY).and_then(Value::as_str)
    }
}

fn cleaned(value: Option<&str>) -> Option<String> {
    let t = value?.trim();
    if t.is_empty() {
        None
    } else {
        Some(t.to_string())
    }
}

// MARK: - Provider backend mapping (mirrors Swift `ClaudeCodeBackend`)

/// Anthropic-compatible base URL for a provider id, or `None` if the provider
/// cannot back Claude Code.
pub fn base_url_for_provider(id: &str, provider: &Provider) -> Option<String> {
    match id {
        "hapo" => {
            // Full chain incl. the compile-time baked endpoint (dev-env.sh).
            let raw = crate::providers::hapo::resolved_base_url(provider)?;
            anthropic_origin(&raw)
        }
        "minimax" => {
            let region = provider.region.as_deref().unwrap_or("io");
            let host = if region == "com" { "api.minimaxi.com" } else { "api.minimax.io" };
            Some(format!("https://{host}/anthropic"))
        }
        "deepseek" => Some("https://api.deepseek.com/anthropic".to_string()),
        "zai" => {
            let region = provider.region.as_deref().unwrap_or("global");
            let host = if region == "cn" { "open.bigmodel.cn" } else { "api.z.ai" };
            Some(format!("https://{host}/api/anthropic"))
        }
        _ => None,
    }
}

/// Whether a provider can be configured as a Claude Code backend.
pub fn is_supported(id: &str) -> bool {
    matches!(id, "hapo" | "minimax" | "deepseek" | "zai")
}

/// Extract `scheme://host[:port]` from a full URL string, without pulling in
/// a URL-parsing crate (only needs the origin).
fn anthropic_origin(url_string: &str) -> Option<String> {
    let (scheme, rest) = url_string.split_once("://")?;
    if scheme.is_empty() {
        return None;
    }
    let authority = rest.split(['/', '?', '#']).next().unwrap_or(rest);
    // Strip userinfo if present (user:pass@host).
    let host_port = authority.rsplit('@').next().unwrap_or(authority);
    if host_port.is_empty() {
        return None;
    }
    Some(format!("{scheme}://{host_port}"))
}

/// Extra provider-specific env vars documented for Claude Code.
fn static_env(id: &str) -> &'static [(&'static str, &'static str)] {
    match id {
        "minimax" => &[("CLAUDE_CODE_AUTO_COMPACT_WINDOW", "1000000")],
        "zai" => &[("API_TIMEOUT_MS", "3000000")],
        _ => &[],
    }
}

/// Providers whose docs set a top-level `ANTHROPIC_MODEL` (mirrored from the
/// Sonnet tier).
fn uses_primary_model_key(id: &str) -> bool {
    id == "minimax"
}

/// A provider is "fully configured" — eligible for one-click quick-apply —
/// when it is a supported backend, has an API key, and has all three models
/// chosen.
pub fn is_fully_configured(id: &str, provider: &Provider) -> bool {
    if !is_supported(id) {
        return false;
    }
    cleaned(provider.api_key.as_deref()).is_some()
        && cleaned(provider.claude_haiku_model.as_deref()).is_some()
        && cleaned(provider.claude_sonnet_model.as_deref()).is_some()
        && cleaned(provider.claude_opus_model.as_deref()).is_some()
}

/// Build the write spec for a provider, or `None` until it has a token +
/// base URL + all three models.
pub fn spec_for_provider(id: &str, provider: &Provider) -> Option<EnvSpec> {
    let base = base_url_for_provider(id, provider)?;
    let token = cleaned(provider.api_key.as_deref())?;
    let haiku = cleaned(provider.claude_haiku_model.as_deref())?;
    let sonnet = cleaned(provider.claude_sonnet_model.as_deref())?;
    let opus = cleaned(provider.claude_opus_model.as_deref())?;

    let mut env = Map::new();
    env.insert(AUTH_TOKEN_KEY.to_string(), Value::String(token));
    env.insert(BASE_URL_KEY.to_string(), Value::String(base));
    env.insert(HAIKU_KEY.to_string(), Value::String(haiku));
    env.insert(SONNET_KEY.to_string(), Value::String(sonnet.clone()));
    env.insert(OPUS_KEY.to_string(), Value::String(opus));
    for (k, v) in static_env(id) {
        env.insert((*k).to_string(), Value::String((*v).to_string()));
    }
    if uses_primary_model_key(id) {
        env.insert(MODEL_KEY.to_string(), Value::String(sonnet));
    }
    if provider.claude_disable_1m == Some(true) {
        env.insert(DISABLE_1M_KEY.to_string(), Value::String("1".to_string()));
    }
    Some(EnvSpec { env, api_key_helper: None })
}

/// Suggested model ids per preset backend — macOS `ClaudeCodeBackend.suggestedModels`.
pub fn suggested_models(id: &str) -> &'static [&'static str] {
    match id {
        "minimax" => &["MiniMax-M3[1m]", "MiniMax-M3", "MiniMax-M2"],
        "deepseek" => &["deepseek-v4-pro", "deepseek-v4-flash", "deepseek-chat", "deepseek-reasoner"],
        "zai" => &["GLM-4.7", "GLM-4.5-Air", "glm-4.6", "glm-4.5"],
        _ => &[],
    }
}

// MARK: - Custom profiles (macOS `claudeCodeProfiles`)

/// A profile can be applied once it has both a base URL and a token —
/// macOS `ClaudeCodeConfigWriter.isReady`.
pub fn profile_ready(p: &ClaudeCodeProfile) -> bool {
    cleaned(p.base_url.as_deref()).is_some() && cleaned(p.token.as_deref()).is_some()
}

/// Build the write spec for a custom profile: `env[tokenEnvKey] = token`,
/// base URL, optional per-tier models, extraEnv rows merged verbatim, and
/// `apiKeyHelper` as a TOP-LEVEL key — macOS `spec(for profile:)`.
pub fn spec_for_profile(p: &ClaudeCodeProfile) -> Option<EnvSpec> {
    let base = cleaned(p.base_url.as_deref())?;
    let token = cleaned(p.token.as_deref())?;
    let token_key = cleaned(p.token_env_key.as_deref()).unwrap_or_else(|| AUTH_TOKEN_KEY.to_string());

    let mut env = Map::new();
    env.insert(token_key, Value::String(token));
    env.insert(BASE_URL_KEY.to_string(), Value::String(base));
    if let Some(m) = cleaned(p.haiku_model.as_deref()) {
        env.insert(HAIKU_KEY.to_string(), Value::String(m));
    }
    if let Some(m) = cleaned(p.sonnet_model.as_deref()) {
        env.insert(SONNET_KEY.to_string(), Value::String(m));
    }
    if let Some(m) = cleaned(p.opus_model.as_deref()) {
        env.insert(OPUS_KEY.to_string(), Value::String(m));
    }
    for row in &p.extra_env {
        let key = row.key.trim();
        if !key.is_empty() {
            env.insert(key.to_string(), Value::String(row.value.clone()));
        }
    }
    Some(EnvSpec { env, api_key_helper: cleaned(p.api_key_helper.as_deref()) })
}

/// Scope a profile currently targets (same semantics as providers).
pub fn profile_scope(p: &ClaudeCodeProfile) -> Option<Scope> {
    if p.claude_code_scope.as_deref() != Some("project") {
        return Some(Scope::Global);
    }
    let path = cleaned(p.claude_code_project_path.as_deref())?;
    Some(Scope::Project(PathBuf::from(path)))
}

// MARK: - Models fetcher (macOS `ClaudeCodeModelsFetcher`)

/// `GET {base}/v1/models` URL, tolerating a trailing slash and a base that
/// already ends in `/v1`.
fn models_url(base: &str) -> String {
    let trimmed = base.trim_end_matches('/');
    if trimmed.ends_with("/v1") {
        format!("{trimmed}/models")
    } else {
        format!("{trimmed}/v1/models")
    }
}

/// Sort newest-first by `created_at` (ISO) / `created` (unix); entries with
/// no timestamp keep their API order after the dated ones.
fn parse_models(body: &Value) -> Vec<String> {
    let Some(data) = body.get("data").and_then(Value::as_array) else { return Vec::new() };
    let mut dated: Vec<(i64, String)> = Vec::new();
    let mut undated: Vec<String> = Vec::new();
    for entry in data {
        let Some(id) = entry.get("id").and_then(Value::as_str).filter(|s| !s.is_empty()) else {
            continue;
        };
        let ts = entry
            .get("created")
            .and_then(Value::as_i64)
            .or_else(|| {
                entry
                    .get("created_at")
                    .and_then(Value::as_str)
                    .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
                    .map(|d| d.timestamp())
            });
        match ts {
            Some(ts) => dated.push((ts, id.to_string())),
            None => undated.push(id.to_string()),
        }
    }
    dated.sort_by(|a, b| b.0.cmp(&a.0));
    dated.into_iter().map(|(_, id)| id).chain(undated).collect()
}

/// Fetch the model list for an Anthropic-compatible backend. Auth: try
/// `x-api-key` first, retry `Authorization: Bearer` on 401/403 — some
/// gateways only accept one of the two (macOS fetcher behavior).
pub async fn fetch_models(base_url: &str, token: &str) -> Result<Vec<String>, String> {
    let base = base_url.trim();
    if base.is_empty() || !base.contains("://") {
        return Err("Base URL không hợp lệ".to_string());
    }
    let url = models_url(base);
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(15))
        .build()
        .map_err(|e| format!("client: {e}"))?;
    let send = |auth_bearer: bool| {
        let client = client.clone();
        let url = url.clone();
        let token = token.to_string();
        async move {
            let mut req = client
                .get(&url)
                .header("anthropic-version", "2023-06-01")
                .header("Accept", "application/json");
            req = if auth_bearer {
                req.header("Authorization", format!("Bearer {token}"))
            } else {
                req.header("x-api-key", token)
            };
            req.send().await
        }
    };
    let mut resp = send(false).await.map_err(|e| format!("Lỗi mạng: {e}"))?;
    if matches!(resp.status().as_u16(), 401 | 403) {
        resp = send(true).await.map_err(|e| format!("Lỗi mạng: {e}"))?;
    }
    let code = resp.status().as_u16();
    if !(200..=299).contains(&code) {
        return Err(format!("HTTP {code}"));
    }
    let body: Value = resp.json().await.map_err(|_| "Không đọc được danh sách model".to_string())?;
    let models = parse_models(&body);
    if models.is_empty() {
        return Err("Không có model nào".to_string());
    }
    Ok(models)
}

// MARK: - Pure merge/deactivate/sync-state over JSON content

/// Parse settings.json content, tolerating a missing/empty file as `{}`.
fn parse_settings(content: &str) -> Result<Map<String, Value>, String> {
    let trimmed = content.trim();
    if trimmed.is_empty() {
        return Ok(Map::new());
    }
    match serde_json::from_str::<Value>(trimmed) {
        Ok(Value::Object(map)) => Ok(map),
        Ok(_) => Ok(Map::new()),
        Err(e) => Err(e.to_string()),
    }
}

fn serialize_settings(settings: &Map<String, Value>) -> String {
    // Pretty-print with sorted keys isn't guaranteed by serde_json's default
    // Map (BTreeMap when `preserve_order` is off); this matches Claude Code's
    // own formatting closely enough and stays byte-stable across writes.
    serde_json::to_string_pretty(&Value::Object(settings.clone())).unwrap_or_else(|_| "{}".to_string())
}

/// Merge this env spec into the settings JSON content: the `env` block
/// becomes EXACTLY `spec.env` (so switching configs never leaves a previous
/// config's keys behind), and `apiKeyHelper` is set/removed accordingly. All
/// other top-level keys (e.g. `permissions`) are preserved.
pub fn merge_content(content: &str, spec: &EnvSpec) -> Result<String, String> {
    let mut settings = parse_settings(content)?;
    settings.insert("env".to_string(), Value::Object(spec.env.clone()));
    match &spec.api_key_helper {
        Some(helper) => {
            settings.insert("apiKeyHelper".to_string(), Value::String(helper.clone()));
        }
        None => {
            settings.remove("apiKeyHelper");
        }
    }
    Ok(serialize_settings(&settings))
}

/// Turn Claude Code's backing OFF: clear the `env` block and remove
/// `apiKeyHelper`, reverting Claude Code to its default Anthropic backend.
/// Other top-level keys are left intact.
pub fn deactivate_content(content: &str) -> Result<String, String> {
    let mut settings = parse_settings(content)?;
    settings.insert("env".to_string(), Value::Object(Map::new()));
    settings.remove("apiKeyHelper");
    Ok(serialize_settings(&settings))
}

/// Remove the Claude Code env settings from the content without creating a
/// settings file when none exists. Returns `(new_content, changed)`.
pub fn remove_env_content(content: &str) -> Result<(String, bool), String> {
    let mut settings = parse_settings(content)?;
    let had_env = settings.remove("env").is_some();
    let had_helper = settings.remove("apiKeyHelper").is_some();
    if !had_env && !had_helper {
        return Ok((content.to_string(), false));
    }
    Ok((serialize_settings(&settings), true))
}

/// Whether the settings content points at this spec and whether the written
/// values still match the current source.
pub fn sync_state_content(content: &str, spec: &EnvSpec) -> SyncState {
    let Some(base) = spec.base_url() else { return SyncState::Off };
    let Ok(settings) = parse_settings(content) else { return SyncState::Off };
    let Some(Value::Object(env)) = settings.get("env") else { return SyncState::Off };
    let Some(current_base) = env.get(BASE_URL_KEY).and_then(Value::as_str) else {
        return SyncState::Off;
    };
    if current_base != base {
        return SyncState::Off;
    }
    // Active (base URL matches). Synced only if the whole env block equals
    // the spec exactly (no missing keys AND no leftover keys from another
    // config) and apiKeyHelper matches; otherwise stale.
    if env != &spec.env {
        return SyncState::Stale;
    }
    let file_helper = settings.get("apiKeyHelper").and_then(Value::as_str);
    if file_helper != spec.api_key_helper.as_deref() {
        return SyncState::Stale;
    }
    SyncState::Synced
}

// MARK: - File wrappers

/// Claude Code global settings.json path. Respects `CLAUDE_CONFIG_DIR` like
/// the Claude Code CLI itself; falls back to `~/.claude`.
pub fn global_settings_path() -> PathBuf {
    if let Ok(dir) = std::env::var("CLAUDE_CONFIG_DIR") {
        let dir = dir.trim();
        if !dir.is_empty() {
            return PathBuf::from(dir).join("settings.json");
        }
    }
    let home = PathBuf::from(std::env::var("HOME").unwrap_or_default());
    home.join(".claude/settings.json")
}

/// Per-project Claude Code settings path: `<projectDir>/.claude/settings.json`.
pub fn project_settings_path(project_dir: &std::path::Path) -> PathBuf {
    project_dir.join(".claude/settings.json")
}

pub fn target_path(scope: &Scope) -> PathBuf {
    match scope {
        Scope::Global => global_settings_path(),
        Scope::Project(dir) => project_settings_path(dir),
    }
}

fn read_target(scope: &Scope) -> Result<String, String> {
    let path = target_path(scope);
    match std::fs::read_to_string(&path) {
        Ok(s) => Ok(s),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(String::new()),
        Err(e) => Err(e.to_string()),
    }
}

fn write_target(scope: &Scope, content: &str) -> Result<(), String> {
    let path = target_path(scope);
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, content).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, &path).map_err(|e| e.to_string())
}

/// Merge `spec` into the settings file for `scope` (global or project).
pub fn apply(spec: &EnvSpec, scope: &Scope) -> Result<(), String> {
    let content = read_target(scope)?;
    let updated = merge_content(&content, spec)?;
    write_target(scope, &updated)
}

/// Clear the managed env/apiKeyHelper block for `scope`.
pub fn deactivate(scope: &Scope) -> Result<(), String> {
    let content = read_target(scope)?;
    let updated = deactivate_content(&content)?;
    write_target(scope, &updated)
}

/// Remove the Claude Code env settings from `scope` without creating a
/// settings file when none exists. Returns whether anything was removed.
pub fn remove_env_settings(scope: &Scope) -> Result<bool, String> {
    if !target_path(scope).exists() {
        return Ok(false);
    }
    let content = read_target(scope)?;
    let (updated, changed) = remove_env_content(&content)?;
    if changed {
        write_target(scope, &updated)?;
    }
    Ok(changed)
}

pub fn sync_state(spec: &EnvSpec, scope: &Scope) -> SyncState {
    match read_target(scope) {
        Ok(content) => sync_state_content(&content, spec),
        Err(_) => SyncState::Off,
    }
}

/// Resolve the scope a provider is currently configured to target. `None`
/// when scope is "project" but no project path has been chosen yet.
pub fn current_scope(provider: &Provider) -> Option<Scope> {
    if provider.claude_code_scope.as_deref() != Some("project") {
        return Some(Scope::Global);
    }
    let path = cleaned(provider.claude_code_project_path.as_deref())?;
    Some(Scope::Project(PathBuf::from(path)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn provider(id: &str) -> Provider {
        Provider { id: id.to_string(), ..Default::default() }
    }

    fn configured_minimax() -> Provider {
        let mut p = provider("minimax");
        p.api_key = Some("sk-test".to_string());
        p.claude_haiku_model = Some("MiniMax-M2".to_string());
        p.claude_sonnet_model = Some("MiniMax-M3".to_string());
        p.claude_opus_model = Some("MiniMax-M3[1m]".to_string());
        p.region = Some("io".to_string());
        p
    }

    #[test]
    fn merge_preserves_unrelated_keys() {
        let existing = r#"{"permissions": {"allow": ["Bash"]}, "otherTopLevel": 42}"#;
        let spec = spec_for_provider("minimax", &configured_minimax()).unwrap();
        let merged = merge_content(existing, &spec).unwrap();
        let parsed: Value = serde_json::from_str(&merged).unwrap();
        assert_eq!(parsed["permissions"]["allow"][0], "Bash");
        assert_eq!(parsed["otherTopLevel"], 42);
        assert_eq!(parsed["env"][BASE_URL_KEY], "https://api.minimax.io/anthropic");
        assert_eq!(parsed["env"][AUTH_TOKEN_KEY], "sk-test");
        assert_eq!(parsed["env"]["ANTHROPIC_MODEL"], "MiniMax-M3");
    }

    #[test]
    fn merge_replaces_env_block_entirely_when_switching_providers() {
        let existing = r#"{"env": {"ANTHROPIC_BASE_URL": "https://old.example.com", "LEFTOVER_KEY": "x"}}"#;
        let spec = spec_for_provider("minimax", &configured_minimax()).unwrap();
        let merged = merge_content(existing, &spec).unwrap();
        let parsed: Value = serde_json::from_str(&merged).unwrap();
        assert!(parsed["env"].get("LEFTOVER_KEY").is_none());
        assert_eq!(parsed["env"][BASE_URL_KEY], "https://api.minimax.io/anthropic");
    }

    #[test]
    fn deactivate_removes_only_managed_keys() {
        let existing = r#"{"env": {"ANTHROPIC_BASE_URL": "https://api.minimax.io/anthropic"}, "apiKeyHelper": "echo hi", "permissions": {"allow": []}}"#;
        let updated = deactivate_content(existing).unwrap();
        let parsed: Value = serde_json::from_str(&updated).unwrap();
        assert_eq!(parsed["env"], serde_json::json!({}));
        assert!(parsed.get("apiKeyHelper").is_none());
        assert_eq!(parsed["permissions"]["allow"], serde_json::json!([]));
    }

    #[test]
    fn sync_state_off_when_base_url_differs() {
        let content = r#"{"env": {"ANTHROPIC_BASE_URL": "https://different.example.com"}}"#;
        let spec = spec_for_provider("minimax", &configured_minimax()).unwrap();
        assert_eq!(sync_state_content(content, &spec), SyncState::Off);
    }

    #[test]
    fn sync_state_stale_when_base_matches_but_value_differs() {
        let spec = spec_for_provider("minimax", &configured_minimax()).unwrap();
        let mut stale_env = spec.env.clone();
        stale_env.insert(AUTH_TOKEN_KEY.to_string(), Value::String("sk-old-token".to_string()));
        let content = serde_json::to_string(&serde_json::json!({"env": stale_env})).unwrap();
        assert_eq!(sync_state_content(&content, &spec), SyncState::Stale);
    }

    #[test]
    fn sync_state_synced_when_everything_matches() {
        let spec = spec_for_provider("minimax", &configured_minimax()).unwrap();
        let content = serde_json::to_string(&serde_json::json!({"env": spec.env})).unwrap();
        assert_eq!(sync_state_content(&content, &spec), SyncState::Synced);
    }

    #[test]
    fn unconfigured_provider_yields_needs_setup() {
        let p = provider("minimax"); // no api key / models
        assert!(!is_fully_configured("minimax", &p));
        assert!(spec_for_provider("minimax", &p).is_none());
        let state = power_state(false, SyncState::Off);
        assert_eq!(state, PowerState::NeedsSetup);
    }

    #[test]
    fn project_scope_path_differs_from_global() {
        let global = target_path(&Scope::Global);
        let project = target_path(&Scope::Project(PathBuf::from("/tmp/my-project")));
        assert_ne!(global, project);
        assert!(project.ends_with(".claude/settings.json"));
        assert!(project.starts_with("/tmp/my-project"));
    }

    #[test]
    fn current_scope_none_when_project_selected_without_path() {
        let mut p = provider("minimax");
        p.claude_code_scope = Some("project".to_string());
        p.claude_code_project_path = None;
        assert_eq!(current_scope(&p), None);
    }

    #[test]
    fn unsupported_provider_has_no_base_url() {
        let p = provider("claude");
        assert!(!is_supported("claude"));
        assert_eq!(base_url_for_provider("claude", &p), None);
    }

    #[test]
    fn zai_region_selects_correct_host() {
        let mut p = provider("zai");
        p.region = Some("cn".to_string());
        assert_eq!(base_url_for_provider("zai", &p).unwrap(), "https://open.bigmodel.cn/api/anthropic");
        p.region = Some("global".to_string());
        assert_eq!(base_url_for_provider("zai", &p).unwrap(), "https://api.z.ai/api/anthropic");
    }

    #[test]
    fn remove_env_content_reports_no_change_when_absent() {
        let (content, changed) = remove_env_content(r#"{"foo": 1}"#).unwrap();
        assert!(!changed);
        assert_eq!(content, r#"{"foo": 1}"#);
    }

    fn profile() -> ClaudeCodeProfile {
        ClaudeCodeProfile {
            id: "p1".into(),
            name: Some("Main".into()),
            base_url: Some("https://api.example.com".into()),
            token: Some("sk-custom".into()),
            token_env_key: Some("ANTHROPIC_API_KEY".into()),
            api_key_helper: Some("echo hi".into()),
            sonnet_model: Some("model-s".into()),
            extra_env: vec![crate::config::ProfileEnvRow {
                id: "e1".into(),
                key: "API_TIMEOUT_MS".into(),
                value: "60000".into(),
            }],
            ..Default::default()
        }
    }

    #[test]
    fn profile_spec_uses_token_env_key_and_extra_env() {
        let spec = spec_for_profile(&profile()).unwrap();
        assert_eq!(spec.env["ANTHROPIC_API_KEY"], "sk-custom");
        assert!(spec.env.get(AUTH_TOKEN_KEY).is_none());
        assert_eq!(spec.env[BASE_URL_KEY], "https://api.example.com");
        assert_eq!(spec.env[SONNET_KEY], "model-s");
        assert!(spec.env.get(HAIKU_KEY).is_none()); // optional tier omitted
        assert_eq!(spec.env["API_TIMEOUT_MS"], "60000");
        assert_eq!(spec.api_key_helper.as_deref(), Some("echo hi"));
    }

    #[test]
    fn profile_ready_needs_base_and_token() {
        assert!(profile_ready(&profile()));
        let mut p = profile();
        p.token = None;
        assert!(!profile_ready(&p));
    }

    #[test]
    fn models_url_tolerates_v1_and_trailing_slash() {
        assert_eq!(models_url("https://api.x.com"), "https://api.x.com/v1/models");
        assert_eq!(models_url("https://api.x.com/"), "https://api.x.com/v1/models");
        assert_eq!(models_url("https://api.x.com/v1"), "https://api.x.com/v1/models");
        assert_eq!(models_url("https://api.x.com/anthropic"), "https://api.x.com/anthropic/v1/models");
    }

    #[test]
    fn parse_models_sorts_newest_first_undated_last() {
        let body = serde_json::json!({"data": [
            {"id": "old", "created": 100},
            {"id": "undated"},
            {"id": "new", "created_at": "2026-01-01T00:00:00Z"},
        ]});
        let models = parse_models(&body);
        assert_eq!(models, vec!["new", "old", "undated"]);
    }

    #[test]
    fn remove_env_content_strips_env_and_helper() {
        let existing = r#"{"env": {"ANTHROPIC_BASE_URL": "x"}, "apiKeyHelper": "echo", "keep": true}"#;
        let (content, changed) = remove_env_content(existing).unwrap();
        assert!(changed);
        let parsed: Value = serde_json::from_str(&content).unwrap();
        assert!(parsed.get("env").is_none());
        assert!(parsed.get("apiKeyHelper").is_none());
        assert_eq!(parsed["keep"], true);
    }
}
