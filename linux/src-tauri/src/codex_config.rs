//! Codex CLI config writer — port of macOS `CodexConfigDocument` + `CodexConfigWriter`.
//!
//! Edits `~/.codex/config.toml` (or `$CODEX_HOME/config.toml`) with comment-marked
//! managed blocks, preserving user content/comments. Side-car state files track
//! the previous root selection and per-project overlay filenames.

use crate::cli_proxy;
use crate::config::{self, CodexProfile};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};

const SELECTION_START: &str = "# >>> BirdNion Codex selection >>>";
const SELECTION_END: &str = "# <<< BirdNion Codex selection <<<";
const PROVIDER_START: &str = "# >>> BirdNion Codex provider >>>";
const PROVIDER_END: &str = "# <<< BirdNion Codex provider <<<";

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

/// Resolve Codex home: `$CODEX_HOME` if set, else `~/.codex`.
pub fn codex_home() -> PathBuf {
    if let Ok(p) = std::env::var("CODEX_HOME") {
        let t = p.trim();
        if !t.is_empty() {
            return PathBuf::from(t);
        }
    }
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
    PathBuf::from(home).join(".codex")
}

pub fn target_config_path() -> PathBuf {
    codex_home().join("config.toml")
}

fn state_path(config_url: &Path) -> PathBuf {
    config_url
        .parent()
        .unwrap_or_else(|| Path::new("."))
        .join("birdnion-provider-state.json")
}

fn profile_files_state_path(config_url: &Path) -> PathBuf {
    config_url
        .parent()
        .unwrap_or_else(|| Path::new("."))
        .join("birdnion-profile-files.json")
}

// ---------------------------------------------------------------------------
// Provider configuration + signatures
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CodexProviderConfiguration {
    pub profile_id: String,
    pub provider_id: String,
    pub provider_name: String,
    pub model: String,
    pub base_url: String,
    pub bearer_token: String,
    pub signature: String,
}

fn cleaned(value: &str) -> Option<String> {
    let t = value.trim();
    if t.is_empty() {
        None
    } else {
        Some(t.to_string())
    }
}

fn cleaned_opt(value: Option<&str>) -> Option<String> {
    value.and_then(cleaned)
}

/// SHA-256 hex of Codex config material (macOS `codexConfigurationSignature`).
pub fn codex_configuration_signature(profile: &CodexProfile) -> Option<String> {
    let model = cleaned(&profile.model)?;
    let (endpoint, token) = if profile.uses_embedded_cli_proxy() {
        let base = cli_proxy::normalized_cli_proxy_base_url(profile.cli_proxy_base_url.as_deref())?;
        let key = cleaned_opt(profile.cli_proxy_api_key.as_deref())?;
        (format!("{base}/v1"), key)
    } else {
        let base = cleaned(&profile.base_url)?;
        let key = cleaned(&profile.api_key)?;
        (base, key)
    };
    let material = [
        "codex-config-v1",
        &profile.cli_proxy_provider_name(),
        &model,
        &endpoint,
        &token,
    ]
    .iter()
    .map(|s| format!("{}:{}", s.len(), s))
    .collect::<Vec<_>>()
    .join("|");
    Some(hex::encode(Sha256::digest(material.as_bytes())))
}

/// SHA-256 of proxy registration material (macOS `cliProxyConfigurationSignature`).
pub fn codex_cli_proxy_configuration_signature(profile: &CodexProfile) -> Option<String> {
    if !profile.uses_embedded_cli_proxy() {
        return None;
    }
    let proxy_base = cli_proxy::normalized_cli_proxy_base_url(profile.cli_proxy_base_url.as_deref())?;
    let base = cleaned(&profile.base_url)?;
    let api_key = cleaned(&profile.api_key)?;
    let model = cleaned(&profile.model)?;
    let proxy_key = cleaned_opt(profile.cli_proxy_api_key.as_deref())?;
    let management = cleaned_opt(profile.cli_proxy_management_key.as_deref())?;
    let material = [
        "codex-proxy-v1",
        &profile.cli_proxy_provider_name(),
        profile.upstream_protocol(),
        &proxy_base,
        &base,
        &api_key,
        &model,
        &proxy_key,
        &management,
    ]
    .iter()
    .map(|s| format!("{}:{}", s.len(), s))
    .collect::<Vec<_>>()
    .join("|");
    Some(hex::encode(Sha256::digest(material.as_bytes())))
}

pub fn is_cli_proxy_configuration_current(profile: &CodexProfile) -> bool {
    match (
        codex_cli_proxy_configuration_signature(profile),
        cleaned_opt(profile.cli_proxy_applied_signature.as_deref()),
    ) {
        (Some(sig), Some(applied)) => sig == applied,
        _ => false,
    }
}

pub fn is_embedded_cli_proxy_ready(profile: &CodexProfile) -> bool {
    cli_proxy::normalized_cli_proxy_base_url(profile.cli_proxy_base_url.as_deref()).is_some()
        && cleaned(&profile.base_url).is_some()
        && cleaned(&profile.api_key).is_some()
        && cleaned(&profile.model).is_some()
        && cleaned_opt(profile.cli_proxy_api_key.as_deref()).is_some()
        && cleaned_opt(profile.cli_proxy_management_key.as_deref()).is_some()
}

pub fn provider_configuration(profile: &CodexProfile) -> Result<CodexProviderConfiguration, String> {
    let model = cleaned(&profile.model).ok_or_else(|| incomplete_err())?;
    let signature = codex_configuration_signature(profile).ok_or_else(|| incomplete_err())?;
    let (endpoint, bearer) = if profile.uses_embedded_cli_proxy() {
        let base = cli_proxy::normalized_cli_proxy_base_url(profile.cli_proxy_base_url.as_deref())
            .ok_or_else(|| incomplete_err())?;
        let key = cleaned_opt(profile.cli_proxy_api_key.as_deref()).ok_or_else(|| incomplete_err())?;
        (format!("{base}/v1"), key)
    } else {
        let base = cleaned(&profile.base_url).ok_or_else(|| incomplete_err())?;
        let key = cleaned(&profile.api_key).ok_or_else(|| incomplete_err())?;
        (base, key)
    };
    let name = cleaned(&profile.name).unwrap_or_else(|| "BirdNion provider".into());
    Ok(CodexProviderConfiguration {
        profile_id: profile.id.clone(),
        provider_id: profile.cli_proxy_provider_name(),
        provider_name: name,
        model,
        base_url: endpoint,
        bearer_token: bearer,
        signature,
    })
}

fn incomplete_err() -> String {
    "Thiếu Base URL, API key hoặc model cho Codex".into()
}

// ---------------------------------------------------------------------------
// TOML document editor (macOS CodexConfigDocument)
// ---------------------------------------------------------------------------

pub mod document {
    use super::*;

    pub fn root_assignments(contents: &str) -> (Option<String>, Option<String>) {
        let mut model = None;
        let mut provider = None;
        let mut inside_table = false;
        for line in lines(contents) {
            let trimmed = line.trim();
            if is_table_header(trimmed) {
                inside_table = true;
            }
            if inside_table {
                continue;
            }
            if let Some(key) = assignment_key(&line) {
                if key == "model" && model.is_none() {
                    model = Some(line.clone());
                }
                if key == "model_provider" && provider.is_none() {
                    provider = Some(line);
                }
            }
        }
        (model, provider)
    }

    pub fn remove_root_assignments(contents: &str) -> String {
        let mut inside_table = false;
        let kept: Vec<String> = lines(contents)
            .into_iter()
            .filter(|line| {
                let trimmed = line.trim();
                if is_table_header(trimmed) {
                    inside_table = true;
                }
                if inside_table {
                    return true;
                }
                match assignment_key(line) {
                    Some(k) if k == "model" || k == "model_provider" => false,
                    _ => true,
                }
            })
            .collect();
        joined(&kept)
    }

    pub fn remove_managed_sections(contents: &str) -> String {
        let without = removing_block(SELECTION_START, SELECTION_END, contents);
        removing_block(PROVIDER_START, PROVIDER_END, &without)
    }

    pub fn has_managed_sections(contents: &str) -> bool {
        has_block(SELECTION_START, SELECTION_END, contents)
            && has_block(PROVIDER_START, PROVIDER_END, contents)
    }

    pub fn applying(configuration: &CodexProviderConfiguration, contents: &str) -> String {
        let selection = [
            SELECTION_START.to_string(),
            format!("model = {}", toml_string(&configuration.model)),
            format!(
                "model_provider = {}",
                toml_string(&configuration.provider_id)
            ),
            SELECTION_END.to_string(),
            String::new(),
        ];
        let with_selection = inserting_at_root(&selection, contents);
        let provider = [
            PROVIDER_START,
            &format!("[model_providers.{}]", configuration.provider_id),
            &format!("name = {}", toml_string(&configuration.provider_name)),
            &format!("base_url = {}", toml_string(&configuration.base_url)),
            &format!(
                "experimental_bearer_token = {}",
                toml_string(&configuration.bearer_token)
            ),
            "wire_api = \"responses\"",
            PROVIDER_END,
        ]
        .join("\n");
        let body = with_selection.trim_matches('\n');
        if body.is_empty() {
            format!("{provider}\n")
        } else {
            format!("{body}\n\n{provider}\n")
        }
    }

    pub fn inserting_root_assignments(
        model_line: Option<&str>,
        provider_line: Option<&str>,
        contents: &str,
    ) -> String {
        let mut assignments = Vec::new();
        if let Some(m) = model_line {
            assignments.push(m.to_string());
        }
        if let Some(p) = provider_line {
            assignments.push(p.to_string());
        }
        if assignments.is_empty() {
            return contents.to_string();
        }
        assignments.push(String::new());
        inserting_at_root(&assignments, contents)
    }

    pub fn contains_managed_configuration(
        contents: &str,
        configuration: &CodexProviderConfiguration,
    ) -> bool {
        let selection = [
            SELECTION_START,
            &format!("model = {}", toml_string(&configuration.model)),
            &format!(
                "model_provider = {}",
                toml_string(&configuration.provider_id)
            ),
            SELECTION_END,
        ]
        .join("\n");
        let provider_parts = [
            PROVIDER_START.to_string(),
            format!("[model_providers.{}]", configuration.provider_id),
            format!("base_url = {}", toml_string(&configuration.base_url)),
            format!(
                "experimental_bearer_token = {}",
                toml_string(&configuration.bearer_token)
            ),
            "wire_api = \"responses\"".into(),
            PROVIDER_END.into(),
        ];
        contents.contains(&selection) && provider_parts.iter().all(|p| contents.contains(p))
    }

    fn removing_block(start: &str, end: &str, contents: &str) -> String {
        let mut output = lines(contents);
        let start_idx = output.iter().position(|l| l.trim() == start);
        let Some(start_idx) = start_idx else {
            return contents.to_string();
        };
        let end_idx = output[start_idx..]
            .iter()
            .position(|l| l.trim() == end)
            .map(|i| start_idx + i);
        let Some(end_idx) = end_idx else {
            // Damaged marker — never discard the rest of the file.
            return contents.to_string();
        };
        output.drain(start_idx..=end_idx);
        joined(&output)
    }

    fn has_block(start: &str, end: &str, contents: &str) -> bool {
        let source = lines(contents);
        let Some(start_idx) = source.iter().position(|l| l.trim() == start) else {
            return false;
        };
        source[start_idx..].iter().any(|l| l.trim() == end)
    }

    fn inserting_at_root(insertion: &[String], contents: &str) -> String {
        let mut output = lines(contents);
        let index = output
            .iter()
            .position(|l| is_table_header(l.trim()))
            .unwrap_or(output.len());
        for (i, line) in insertion.iter().enumerate() {
            output.insert(index + i, line.clone());
        }
        joined(&output)
    }

    fn assignment_key(line: &str) -> Option<String> {
        let trimmed = line.trim();
        if trimmed.starts_with('#') {
            return None;
        }
        let eq = trimmed.find('=')?;
        let key = trimmed[..eq].trim();
        if key.is_empty() {
            None
        } else {
            Some(key.to_string())
        }
    }

    fn is_table_header(line: &str) -> bool {
        line.starts_with('[') && line.ends_with(']')
    }

    fn lines(contents: &str) -> Vec<String> {
        contents.split('\n').map(|s| s.to_string()).collect()
    }

    fn joined(lines: &[String]) -> String {
        lines.join("\n")
    }

    pub fn toml_string(value: &str) -> String {
        // JSON-string quoting matches macOS (handles escapes correctly).
        serde_json::to_string(value)
            .unwrap_or_else(|_| "\"\"".into())
            .replace("\\/", "/")
    }
}

// ---------------------------------------------------------------------------
// Managed state sidecar
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ManagedState {
    pub profile_id: String,
    pub config_path: String,
    pub signature: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub original_model_line: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub original_model_provider_line: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq, Eq)]
struct ProfileFilesState {
    #[serde(default)]
    files: std::collections::BTreeMap<String, String>,
}

fn load_state(config_url: &Path) -> Option<ManagedState> {
    let data = std::fs::read(state_path(config_url)).ok()?;
    let state: ManagedState = serde_json::from_slice(&data).ok()?;
    if state.config_path != config_url.to_string_lossy() {
        return None;
    }
    Some(state)
}

fn write_state(state: &ManagedState, config_url: &Path) -> Result<(), String> {
    write_data(
        &serde_json::to_vec(state).map_err(|e| e.to_string())?,
        &state_path(config_url),
    )
}

fn load_profile_files_state(config_url: &Path) -> ProfileFilesState {
    std::fs::read(profile_files_state_path(config_url))
        .ok()
        .and_then(|d| serde_json::from_slice(&d).ok())
        .unwrap_or_default()
}

fn write_profile_files_state(state: &ProfileFilesState, config_url: &Path) -> Result<(), String> {
    write_data(
        &serde_json::to_vec(state).map_err(|e| e.to_string())?,
        &profile_files_state_path(config_url),
    )
}

fn write_string(contents: &str, path: &Path) -> Result<(), String> {
    write_data(contents.as_bytes(), path)
}

fn write_data(data: &[u8], path: &Path) -> Result<(), String> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    let tmp = path.with_extension("tmp");
    std::fs::write(&tmp, data).map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600));
    }
    std::fs::rename(&tmp, path).map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

pub fn active_profile_id(config_url: Option<&Path>) -> Option<String> {
    let path = config_url
        .map(Path::to_path_buf)
        .unwrap_or_else(target_config_path);
    load_state(&path).map(|s| s.profile_id)
}

pub fn is_applied(profile: &CodexProfile, config_url: Option<&Path>) -> bool {
    let path = config_url
        .map(Path::to_path_buf)
        .unwrap_or_else(target_config_path);
    let Ok(configuration) = provider_configuration(profile) else {
        return false;
    };
    let Some(state) = load_state(&path) else {
        return false;
    };
    if state.profile_id != profile.id || state.signature != configuration.signature {
        return false;
    }
    let Ok(contents) = std::fs::read_to_string(&path) else {
        return false;
    };
    document::contains_managed_configuration(&contents, &configuration)
}

pub fn apply(profile: &CodexProfile, config_url: Option<&Path>) -> Result<(), String> {
    let path = config_url
        .map(Path::to_path_buf)
        .unwrap_or_else(target_config_path);
    let configuration = provider_configuration(profile)?;
    let contents = std::fs::read_to_string(&path).unwrap_or_default();
    let previous = load_state(&path);
    let clean = document::remove_managed_sections(&contents);
    let (orig_model, orig_provider) = previous
        .as_ref()
        .map(|s| (s.original_model_line.clone(), s.original_model_provider_line.clone()))
        .unwrap_or_else(|| {
            let (m, p) = document::root_assignments(&clean);
            (m, p)
        });
    let without_root = document::remove_root_assignments(&clean);
    let updated = document::applying(&configuration, &without_root);
    write_string(&updated, &path)?;
    let state = ManagedState {
        profile_id: profile.id.clone(),
        config_path: path.to_string_lossy().to_string(),
        signature: configuration.signature,
        original_model_line: orig_model,
        original_model_provider_line: orig_provider,
    };
    write_state(&state, &path)?;
    Ok(())
}

/// Restore user root selection and remove managed blocks. Returns true if a
/// previously managed config was deactivated.
pub fn deactivate(config_url: Option<&Path>) -> Result<bool, String> {
    let path = config_url
        .map(Path::to_path_buf)
        .unwrap_or_else(target_config_path);
    let Some(state) = load_state(&path) else {
        return Ok(false);
    };
    let contents = std::fs::read_to_string(&path).unwrap_or_default();
    if !document::has_managed_sections(&contents) {
        let _ = std::fs::remove_file(state_path(&path));
        return Ok(false);
    }
    let mut restored = document::remove_managed_sections(&contents);
    restored = document::remove_root_assignments(&restored);
    restored = document::inserting_root_assignments(
        state.original_model_line.as_deref(),
        state.original_model_provider_line.as_deref(),
        &restored,
    );
    if restored.trim().is_empty() {
        let _ = std::fs::remove_file(&path);
    } else {
        write_string(&restored, &path)?;
    }
    let _ = std::fs::remove_file(state_path(&path));
    Ok(true)
}

/// Codex profile flag name: `bn-<slug>` from display name.
pub fn profile_flag_name(profile: &CodexProfile) -> String {
    let slug: String = profile
        .name
        .to_lowercase()
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() {
                ch
            } else {
                '-'
            }
        })
        .collect();
    let mut collapsed = String::new();
    for ch in slug.chars() {
        if ch == '-' && collapsed.ends_with('-') {
            continue;
        }
        collapsed.push(ch);
    }
    let trimmed = collapsed.trim_matches('-');
    let base = if trimmed.is_empty() {
        profile.id.chars().take(8).collect::<String>().to_lowercase()
    } else {
        trimmed.to_string()
    };
    format!("bn-{base}")
}

/// Write/refresh `~/.codex/bn-<slug>.config.toml`. Returns the `--profile` flag.
pub fn write_profile_file(profile: &CodexProfile, config_url: Option<&Path>) -> Result<String, String> {
    let path = config_url
        .map(Path::to_path_buf)
        .unwrap_or_else(target_config_path);
    let configuration = provider_configuration(profile)?;
    let directory = path.parent().unwrap_or_else(|| Path::new("."));
    let mut state = load_profile_files_state(&path);

    let mut flag = profile_flag_name(profile);
    let file_candidate = format!("{flag}.config.toml");
    if state
        .files
        .iter()
        .any(|(k, v)| k != &profile.id && v == &file_candidate)
    {
        let suffix: String = profile.id.chars().take(4).collect::<String>().to_lowercase();
        flag = format!("{flag}-{suffix}");
    }
    let file_name = format!("{flag}.config.toml");

    if let Some(previous) = state.files.get(&profile.id) {
        if previous != &file_name {
            let _ = std::fs::remove_file(directory.join(previous));
        }
    }
    write_string(
        &document::applying(&configuration, ""),
        &directory.join(&file_name),
    )?;
    state.files.insert(profile.id.clone(), file_name);
    write_profile_files_state(&state, &path)?;
    Ok(flag)
}

pub fn profile_flag(profile_id: &str, config_url: Option<&Path>) -> Option<String> {
    let path = config_url
        .map(Path::to_path_buf)
        .unwrap_or_else(target_config_path);
    let name = load_profile_files_state(&path).files.get(profile_id)?.clone();
    name.strip_suffix(".config.toml").map(|s| s.to_string())
}

pub fn remove_profile_file(profile_id: &str, config_url: Option<&Path>) {
    let path = config_url
        .map(Path::to_path_buf)
        .unwrap_or_else(target_config_path);
    let mut state = load_profile_files_state(&path);
    let Some(name) = state.files.remove(profile_id) else {
        return;
    };
    let directory = path.parent().unwrap_or_else(|| Path::new("."));
    let _ = std::fs::remove_file(directory.join(name));
    let _ = write_profile_files_state(&state, &path);
}

// ---------------------------------------------------------------------------
// Activation state for UI
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexProfileState {
    /// active | stale | ready | setup
    pub state: String,
    pub active: bool,
    pub current: bool,
    pub target_path: String,
    pub uses_proxy: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub profile_flag: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub connection_label: Option<String>,
}

pub fn profile_state(profile_id: &str) -> CodexProfileState {
    let target = target_config_path();
    let target_display = format_home_path(&target);
    let Some(profile) = config::find_codex_profile(profile_id) else {
        return CodexProfileState {
            state: "setup".into(),
            active: false,
            current: false,
            target_path: target_display,
            uses_proxy: false,
            profile_flag: None,
            connection_label: None,
        };
    };
    let active_id = active_profile_id(Some(&target));
    let active = active_id.as_deref() == Some(profile.id.as_str());
    let current = is_applied(&profile, Some(&target));
    let state = if active && current {
        "active"
    } else if active {
        "stale"
    } else if !profile.has_upstream_configuration() {
        "setup"
    } else {
        "ready"
    };
    CodexProfileState {
        state: state.into(),
        active,
        current,
        target_path: target_display,
        uses_proxy: profile.uses_embedded_cli_proxy(),
        profile_flag: profile_flag(&profile.id, Some(&target)),
        connection_label: Some(
            if profile.uses_embedded_cli_proxy() {
                "proxy"
            } else {
                "direct"
            }
            .into(),
        ),
    }
}

fn format_home_path(path: &Path) -> String {
    if let Ok(home) = std::env::var("HOME") {
        let home_path = PathBuf::from(&home);
        if let Ok(rel) = path.strip_prefix(&home_path) {
            return format!("~/{}", rel.display());
        }
    }
    path.to_string_lossy().to_string()
}

// ---------------------------------------------------------------------------
// Delete helpers
// ---------------------------------------------------------------------------

/// Delete a Codex profile. When `linked_claude_id` is set and `delete_claude`
/// is true (custom dual-record), also remove the Claude profile. Deactivates
/// Codex if this profile is active and removes the overlay file.
pub fn delete_profile(
    profile_id: &str,
    delete_linked_claude: bool,
) -> Result<(), String> {
    let settings = config::load();
    let profile = settings
        .codex_profiles
        .iter()
        .find(|p| p.id == profile_id)
        .cloned();

    // Deactivate if active.
    if active_profile_id(None).as_deref() == Some(profile_id) {
        let _ = deactivate(None);
    }
    remove_profile_file(profile_id, None);

    let mut settings = config::load();
    settings.codex_profiles.retain(|p| p.id != profile_id);

    if delete_linked_claude {
        if let Some(ref p) = profile {
            if let Some(claude_id) = cleaned_opt(p.claude_code_profile_id.as_deref()) {
                settings
                    .claude_code_profiles
                    .retain(|c| c.id != claude_id);
            }
        }
        // Also clear reverse links from any remaining Claude rows.
        for c in &mut settings.claude_code_profiles {
            if cleaned_opt(c.codex_profile_id.as_deref()).as_deref() == Some(profile_id) {
                c.codex_profile_id = None;
            }
        }
    } else {
        // Preset: keep Claude/providers; only clear codexProfileID links.
        for c in &mut settings.claude_code_profiles {
            if cleaned_opt(c.codex_profile_id.as_deref()).as_deref() == Some(profile_id) {
                c.codex_profile_id = None;
            }
        }
        for p in &mut settings.providers {
            if cleaned_opt(p.codex_profile_id.as_deref()).as_deref() == Some(profile_id) {
                p.codex_profile_id = None;
            }
        }
    }
    config::save(&settings)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    static TEST_LOCK: Mutex<()> = Mutex::new(());

    fn sample_direct() -> CodexProfile {
        CodexProfile {
            id: "abc12345".into(),
            name: "My Proxy".into(),
            base_url: "https://api.example.com/v1".into(),
            api_key: "sk-upstream".into(),
            model: "gpt-5.6".into(),
            upstream_protocol_raw: Some(CodexProfile::PROTOCOL_RESPONSES.into()),
            connection_mode_raw: Some(CodexProfile::MODE_DIRECT.into()),
            ..Default::default()
        }
    }

    fn sample_proxy() -> CodexProfile {
        CodexProfile {
            id: "proxy99".into(),
            name: "Anthropic Bridge".into(),
            base_url: "https://api.anthropic.example".into(),
            api_key: "sk-ant".into(),
            model: "claude-sonnet".into(),
            upstream_protocol_raw: Some(CodexProfile::PROTOCOL_ANTHROPIC.into()),
            connection_mode_raw: Some(CodexProfile::MODE_LOCAL_PROXY.into()),
            cli_proxy_base_url: Some(cli_proxy::LOCAL_BASE_URL.into()),
            cli_proxy_api_key: Some("local-key".into()),
            cli_proxy_management_key: Some("mgmt".into()),
            ..Default::default()
        }
    }

    #[test]
    fn document_apply_is_idempotent() {
        let cfg = provider_configuration(&sample_direct()).unwrap();
        let user = "# keep me\n\n[mcp_servers.foo]\ncommand = \"bar\"\n";
        let once = document::applying(&cfg, user);
        let twice = document::applying(&cfg, &document::remove_managed_sections(&once));
        // After remove + re-apply, selection+provider blocks present once each.
        assert_eq!(
            once.matches(SELECTION_START).count(),
            1
        );
        let cleaned = document::remove_managed_sections(&once);
        let reapplied = document::applying(&cfg, &document::remove_root_assignments(&cleaned));
        assert!(document::contains_managed_configuration(&reapplied, &cfg));
        assert_eq!(reapplied.matches(SELECTION_START).count(), 1);
        assert_eq!(reapplied.matches(PROVIDER_START).count(), 1);
        let _ = twice;
    }

    #[test]
    fn apply_deactivate_restores_user_root_lines() {
        let _g = TEST_LOCK.lock().unwrap();
        let dir = std::env::temp_dir().join(format!(
            "birdnion-codex-test-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let config = dir.join("config.toml");
        let original = "model = \"user-model\"\nmodel_provider = \"openai\"\n\n# user comment\n[features]\nx = true\n";
        std::fs::write(&config, original).unwrap();

        let profile = sample_direct();
        apply(&profile, Some(&config)).unwrap();
        let after = std::fs::read_to_string(&config).unwrap();
        assert!(after.contains(SELECTION_START));
        assert!(after.contains(PROVIDER_START));
        assert!(after.contains("gpt-5.6"));
        assert!(after.contains("# user comment"));
        assert!(after.contains("[features]"));
        // User root selection replaced by managed block.
        assert!(!after.contains("model = \"user-model\"") || after.contains(SELECTION_START));

        assert!(deactivate(Some(&config)).unwrap());
        let restored = std::fs::read_to_string(&config).unwrap();
        assert!(restored.contains("model = \"user-model\""));
        assert!(restored.contains("model_provider = \"openai\""));
        assert!(restored.contains("# user comment"));
        assert!(!restored.contains(SELECTION_START));
        assert!(!restored.contains(PROVIDER_START));
        assert!(!state_path(&config).exists());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn managed_block_idempotent_on_disk() {
        let _g = TEST_LOCK.lock().unwrap();
        let dir = std::env::temp_dir().join(format!(
            "birdnion-codex-idemp-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let config = dir.join("config.toml");
        std::fs::write(&config, "debug = true\n").unwrap();
        let profile = sample_direct();
        apply(&profile, Some(&config)).unwrap();
        apply(&profile, Some(&config)).unwrap();
        let contents = std::fs::read_to_string(&config).unwrap();
        assert_eq!(contents.matches(SELECTION_START).count(), 1);
        assert_eq!(contents.matches(PROVIDER_START).count(), 1);
        assert!(is_applied(&profile, Some(&config)));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn overlay_slug_avoids_collision() {
        let _g = TEST_LOCK.lock().unwrap();
        let dir = std::env::temp_dir().join(format!(
            "birdnion-codex-overlay-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let config = dir.join("config.toml");

        let mut a = sample_direct();
        a.id = "aaaa1111".into();
        a.name = "Shared Name".into();
        let mut b = sample_direct();
        b.id = "bbbb2222".into();
        b.name = "Shared Name".into();

        let flag_a = write_profile_file(&a, Some(&config)).unwrap();
        let flag_b = write_profile_file(&b, Some(&config)).unwrap();
        assert_ne!(flag_a, flag_b);
        assert!(flag_a.starts_with("bn-"));
        assert!(flag_b.starts_with("bn-"));
        assert!(dir.join(format!("{flag_a}.config.toml")).exists());
        assert!(dir.join(format!("{flag_b}.config.toml")).exists());

        remove_profile_file(&a.id, Some(&config));
        assert!(!dir.join(format!("{flag_a}.config.toml")).exists());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn signature_differs_direct_vs_proxy() {
        let direct = sample_direct();
        let proxy = sample_proxy();
        let sd = codex_configuration_signature(&direct).unwrap();
        let sp = codex_configuration_signature(&proxy).unwrap();
        assert_ne!(sd, sp);
        assert_eq!(sd.len(), 64);
        assert!(codex_cli_proxy_configuration_signature(&proxy).is_some());
        assert!(codex_cli_proxy_configuration_signature(&direct).is_none());
    }

    #[test]
    fn proxy_config_points_at_loopback() {
        let cfg = provider_configuration(&sample_proxy()).unwrap();
        assert_eq!(cfg.base_url, format!("{}/v1", cli_proxy::LOCAL_BASE_URL));
        assert_eq!(cfg.bearer_token, "local-key");
        assert!(cfg.provider_id.starts_with("birdnion-codex-"));
    }

    #[test]
    fn profile_flag_name_sanitizes() {
        let mut p = sample_direct();
        p.name = "My Cool!! Profile".into();
        assert_eq!(profile_flag_name(&p), "bn-my-cool-profile");
        p.name = "!!!".into();
        p.id = "deadbeef".into();
        assert_eq!(profile_flag_name(&p), "bn-deadbeef");
    }

    #[test]
    fn damaged_marker_does_not_wipe_file() {
        let contents = format!(
            "{SELECTION_START}\nmodel = \"x\"\n# missing end marker\n[keep]\nv = 1\n"
        );
        let cleaned = document::remove_managed_sections(&contents);
        assert!(cleaned.contains("[keep]"));
        assert!(cleaned.contains(SELECTION_START)); // left intact when end missing
    }
}
