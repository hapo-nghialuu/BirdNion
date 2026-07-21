//! Embedded CLIProxyAPI helper — port of macOS `EmbeddedCLIProxyService` +
//! `LocalProxyProcessController` + `CLIProxyAPIConfiguration` + `CLIProxyAPIClient`.
//!
//! Loopback only (127.0.0.1:24323). BirdNion owns credentials; Claude Code
//! receives the loopback key, never the upstream secret.

use crate::config::{self, ClaudeCodeProfile, CodexProfile};
use crate::codex_config;
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{LazyLock, Mutex};
use std::time::Duration;
use tauri::{AppHandle, Manager};

/// Dedicated BirdNion port — avoids colliding with a stock CLIProxyAPI install.
pub const LOCAL_PORT: u16 = 24_323;
pub const LEGACY_LOCAL_PORT: u16 = 8_317;
pub const LOCAL_BASE_URL: &str = "http://127.0.0.1:24323";
pub const LOCAL_ENDPOINT: &str = "http://127.0.0.1:24323/v1";

// ---------------------------------------------------------------------------
// Runtime state
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum RuntimeState {
    Checking,
    Stopped,
    Starting,
    Running,
    Failed,
}

struct ProcessState {
    child: Option<Child>,
    runtime: RuntimeState,
}

static PROCESS: LazyLock<Mutex<ProcessState>> = LazyLock::new(|| {
    Mutex::new(ProcessState {
        child: None,
        runtime: RuntimeState::Checking,
    })
});

fn set_runtime(state: RuntimeState) {
    if let Ok(mut g) = PROCESS.lock() {
        g.runtime = state;
    }
}

fn runtime() -> RuntimeState {
    PROCESS
        .lock()
        .map(|g| g.runtime)
        .unwrap_or(RuntimeState::Stopped)
}

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

fn config_directory() -> PathBuf {
    config::config_path()
        .parent()
        .map(|p| p.join("cli-proxy-api"))
        .unwrap_or_else(|| PathBuf::from("cli-proxy-api"))
}

fn config_yaml_path() -> PathBuf {
    config_directory().join("config.yaml")
}

fn auth_directory() -> PathBuf {
    config_directory().join("auth")
}

/// Resolve the bundled `cliproxyapi` binary: resource dir first, then the
/// crate-local `binaries/` path used during `tauri dev` / `cargo test`.
pub fn resolve_binary(app: &AppHandle) -> Result<PathBuf, String> {
    if let Ok(resource) = app.path().resource_dir() {
        for candidate in [
            resource.join("cliproxyapi"),
            resource.join("binaries/cliproxyapi"),
            resource.join("_up_/binaries/cliproxyapi"),
        ] {
            if candidate.is_file() {
                return Ok(candidate);
            }
        }
    }
    let dev = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("binaries/cliproxyapi");
    if dev.is_file() {
        return Ok(dev);
    }
    Err("Không tìm thấy core CLIProxyAPI trong ứng dụng".into())
}

// ---------------------------------------------------------------------------
// Profile helpers (macOS BirdNionConfigStore.ClaudeCodeProfile)
// ---------------------------------------------------------------------------

fn cleaned(value: Option<&str>) -> Option<String> {
    let t = value?.trim();
    if t.is_empty() {
        None
    } else {
        Some(t.to_string())
    }
}

/// macOS `compatibility == .openAI` (`compatibilityMode == "openai"`).
pub fn is_openai_compatible(p: &ClaudeCodeProfile) -> bool {
    cleaned(p.compatibility_mode.as_deref()).as_deref() == Some("openai")
}

/// macOS `openAIProxyFormat` — only `"responses"` is special; everything else
/// is treated as Chat Completions.
pub fn open_ai_proxy_format(p: &ClaudeCodeProfile) -> Option<String> {
    match cleaned(p.open_ai_format.as_deref()).as_deref() {
        Some("responses") => Some("responses".into()),
        _ => None,
    }
}

/// macOS `usesEmbeddedCLIProxy`: explicit flag, else OpenAI defaults to proxy.
pub fn uses_embedded_cli_proxy(p: &ClaudeCodeProfile) -> bool {
    p.embedded_local_proxy.unwrap_or_else(|| is_openai_compatible(p))
}

/// Upstream base/key for registration — OpenAI fields with Anthropic fallback.
pub fn upstream_base_url(p: &ClaudeCodeProfile) -> Option<String> {
    if is_openai_compatible(p) {
        cleaned(p.open_ai_base_url.as_deref()).or_else(|| cleaned(p.base_url.as_deref()))
    } else {
        cleaned(p.base_url.as_deref())
    }
}

pub fn upstream_api_key(p: &ClaudeCodeProfile) -> Option<String> {
    if is_openai_compatible(p) {
        cleaned(p.open_ai_api_key.as_deref()).or_else(|| cleaned(p.token.as_deref()))
    } else {
        cleaned(p.token.as_deref())
    }
}

pub fn has_upstream_configuration(p: &ClaudeCodeProfile) -> bool {
    upstream_base_url(p).is_some() && upstream_api_key(p).is_some()
}

pub fn cli_proxy_provider_name(p: &ClaudeCodeProfile) -> String {
    let safe: String = p
        .id
        .to_lowercase()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect();
    format!("birdnion-{safe}")
}

pub fn normalized_cli_proxy_base_url(raw: Option<&str>) -> Option<String> {
    let raw = cleaned(raw)?;
    let (scheme, rest) = raw.split_once("://")?;
    let scheme = scheme.to_lowercase();
    if scheme != "http" && scheme != "https" {
        return None;
    }
    let authority = rest.split(['/', '?', '#']).next().unwrap_or(rest);
    if authority.is_empty() {
        return None;
    }
    let path_and_more = rest.get(authority.len()..).unwrap_or("");
    let path = path_and_more
        .split(['?', '#'])
        .next()
        .unwrap_or("")
        .trim_end_matches('/');
    let path = if path == "/v1" { "" } else { path };
    if path.is_empty() {
        Some(format!("{scheme}://{authority}"))
    } else {
        Some(format!("{scheme}://{authority}{path}"))
    }
}

pub fn model_names(p: &ClaudeCodeProfile) -> Vec<String> {
    [p.haiku_model.as_deref(), p.sonnet_model.as_deref(), p.opus_model.as_deref()]
        .into_iter()
        .filter_map(cleaned)
        .collect()
}

pub fn is_embedded_cli_proxy_ready(p: &ClaudeCodeProfile) -> bool {
    normalized_cli_proxy_base_url(p.cli_proxy_base_url.as_deref()).is_some()
        && has_upstream_configuration(p)
        && cleaned(p.cli_proxy_api_key.as_deref()).is_some()
        && cleaned(p.cli_proxy_management_key.as_deref()).is_some()
}

/// Claude Code strips the documented `[1m]` marker before sending a request.
/// Keep the marker in the upstream name; register the local alias without it.
pub fn local_model_alias(model: &str) -> String {
    let marker = "[1m]";
    if model.to_lowercase().ends_with(marker) {
        model[..model.len() - marker.len()].to_string()
    } else {
        model.to_string()
    }
}

/// SHA-256 hex of the registration material (macOS `cliProxyConfigurationSignature`).
/// Includes compatibility mode + OpenAI format so Chat ⇄ Responses is detected.
pub fn configuration_signature(p: &ClaudeCodeProfile) -> Option<String> {
    if !uses_embedded_cli_proxy(p) {
        return None;
    }
    let proxy_base = normalized_cli_proxy_base_url(p.cli_proxy_base_url.as_deref())?;
    let upstream_base = upstream_base_url(p)?;
    let upstream_key = upstream_api_key(p)?;
    let proxy_key = cleaned(p.cli_proxy_api_key.as_deref())?;
    let management_key = cleaned(p.cli_proxy_management_key.as_deref())?;
    let compat = if is_openai_compatible(p) {
        "openai"
    } else {
        "anthropic"
    };
    let format = open_ai_proxy_format(p).unwrap_or_else(|| "openai-chat".into());
    let mut parts: Vec<String> = vec![
        "direct-models-v1".into(),
        cli_proxy_provider_name(p),
        compat.into(),
        format,
        proxy_base,
        upstream_base,
        upstream_key,
        proxy_key,
        management_key,
    ];
    parts.extend(model_names(p));
    let material = parts
        .iter()
        .map(|s| format!("{}:{}", s.len(), s))
        .collect::<Vec<_>>()
        .join("|");
    let digest = Sha256::digest(material.as_bytes());
    Some(hex::encode(digest))
}

pub fn is_configuration_current(p: &ClaudeCodeProfile) -> bool {
    match (configuration_signature(p), cleaned(p.cli_proxy_applied_signature.as_deref())) {
        (Some(sig), Some(applied)) => sig == applied,
        _ => false,
    }
}

pub fn random_secret() -> String {
    let mut bytes = [0u8; 32];
    if getrandom::getrandom(&mut bytes).is_err() {
        // Extremely rare; fall back to a non-crypto-but-unique token.
        return format!(
            "fallback{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        );
    }
    URL_SAFE_NO_PAD.encode(bytes)
}

// ---------------------------------------------------------------------------
// YAML configuration
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProxyModel {
    pub name: String,
    pub alias: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeKeyEntry {
    #[serde(rename = "api-key")]
    pub api_key: String,
    pub prefix: String,
    #[serde(rename = "base-url")]
    pub base_url: String,
    pub models: Vec<ProxyModel>,
}

/// One api-key entry under `openai-compatibility` (CLIProxyAPI YAML/JSON).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenAIApiKeyEntry {
    #[serde(rename = "api-key")]
    pub api_key: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenAICompatibilityEntry {
    pub name: String,
    pub prefix: String,
    #[serde(rename = "base-url")]
    pub base_url: String,
    #[serde(rename = "api-key-entries")]
    pub api_key_entries: Vec<OpenAIApiKeyEntry>,
    pub models: Vec<ProxyModel>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub format: Option<String>,
}

#[derive(Debug, Clone)]
pub struct ProxyConfiguration {
    pub base_url: String,
    pub auth_directory: String,
    pub management_key: String,
    pub api_keys: Vec<String>,
    pub claude_api_keys: Vec<ClaudeKeyEntry>,
    pub openai_compatibility: Vec<OpenAICompatibilityEntry>,
}

impl ProxyConfiguration {
    /// Build YAML config from Claude + Codex managed profiles (macOS parity).
    /// Pass empty codex slice for Claude-only (tests and Claude prepare path).
    pub fn from_profiles(
        claude_profiles: &[ClaudeCodeProfile],
        codex_profiles: &[CodexProfile],
        auth_dir: &Path,
    ) -> Option<Self> {
        let managed_claude: Vec<_> = claude_profiles
            .iter()
            .filter(|p| uses_embedded_cli_proxy(p) && is_embedded_cli_proxy_ready(p))
            .collect();
        let managed_codex: Vec<_> = codex_profiles
            .iter()
            .filter(|p| {
                p.uses_embedded_cli_proxy() && codex_config::is_embedded_cli_proxy_ready(p)
            })
            .collect();

        let management_key = managed_claude
            .iter()
            .find_map(|p| cleaned(p.cli_proxy_management_key.as_deref()))
            .or_else(|| {
                managed_codex
                    .iter()
                    .find_map(|p| cleaned(p.cli_proxy_management_key.as_deref()))
            })?;

        let compatible_claude: Vec<_> = managed_claude
            .into_iter()
            .filter(|p| {
                cleaned(p.cli_proxy_management_key.as_deref()).as_deref()
                    == Some(management_key.as_str())
            })
            .collect();
        let compatible_codex: Vec<_> = managed_codex
            .into_iter()
            .filter(|p| {
                cleaned(p.cli_proxy_management_key.as_deref()).as_deref()
                    == Some(management_key.as_str())
            })
            .collect();
        if compatible_claude.is_empty() && compatible_codex.is_empty() {
            return None;
        }

        let mut api_keys = Vec::new();
        let mut claude_api_keys = Vec::new();
        let mut openai_compatibility = Vec::new();

        for p in &compatible_claude {
            if let Some(k) = cleaned(p.cli_proxy_api_key.as_deref()) {
                if !api_keys.contains(&k) {
                    api_keys.push(k);
                }
            }
            let mut models = Vec::new();
            let mut seen = std::collections::HashSet::new();
            for name in model_names(p) {
                let alias = local_model_alias(&name);
                if seen.insert(alias.clone()) {
                    models.push(ProxyModel { name, alias });
                }
            }
            let base = upstream_base_url(p).unwrap_or_default();
            let api_key = upstream_api_key(p).unwrap_or_default();
            if is_openai_compatible(p) {
                openai_compatibility.push(OpenAICompatibilityEntry {
                    name: cli_proxy_provider_name(p),
                    prefix: String::new(),
                    base_url: base,
                    api_key_entries: vec![OpenAIApiKeyEntry { api_key }],
                    models,
                    format: open_ai_proxy_format(p),
                });
            } else {
                claude_api_keys.push(ClaudeKeyEntry {
                    api_key,
                    prefix: String::new(),
                    base_url: base,
                    models,
                });
            }
        }

        for p in &compatible_codex {
            if let Some(k) = cleaned(p.cli_proxy_api_key.as_deref()) {
                if !api_keys.contains(&k) {
                    api_keys.push(k);
                }
            }
            let model = cleaned(Some(p.model.as_str())).unwrap_or_default();
            let models = if model.is_empty() {
                vec![]
            } else {
                vec![ProxyModel {
                    name: model.clone(),
                    alias: model,
                }]
            };
            let base = cleaned(Some(p.base_url.as_str())).unwrap_or_default();
            let api_key = cleaned(Some(p.api_key.as_str())).unwrap_or_default();
            match p.upstream_protocol() {
                CodexProfile::PROTOCOL_ANTHROPIC => {
                    claude_api_keys.push(ClaudeKeyEntry {
                        api_key,
                        prefix: String::new(),
                        base_url: base,
                        models,
                    });
                }
                CodexProfile::PROTOCOL_RESPONSES => {
                    openai_compatibility.push(OpenAICompatibilityEntry {
                        name: p.cli_proxy_provider_name(),
                        prefix: String::new(),
                        base_url: base,
                        api_key_entries: vec![OpenAIApiKeyEntry { api_key }],
                        models,
                        format: Some("responses".into()),
                    });
                }
                _ => {
                    // openai-chat
                    openai_compatibility.push(OpenAICompatibilityEntry {
                        name: p.cli_proxy_provider_name(),
                        prefix: String::new(),
                        base_url: base,
                        api_key_entries: vec![OpenAIApiKeyEntry { api_key }],
                        models,
                        format: None,
                    });
                }
            }
        }

        Some(Self {
            base_url: LOCAL_BASE_URL.to_string(),
            auth_directory: auth_dir.to_string_lossy().to_string(),
            management_key,
            api_keys,
            claude_api_keys,
            openai_compatibility,
        })
    }

    /// Render the subset of CLIProxyAPI YAML BirdNion owns.
    pub fn to_yaml(&self) -> String {
        let mut lines = vec![
            format!("host: {}", yaml_quote("127.0.0.1")),
            format!("port: {LOCAL_PORT}"),
            format!("auth-dir: {}", yaml_quote(&self.auth_directory)),
            "api-keys:".to_string(),
        ];
        for k in &self.api_keys {
            lines.push(format!("  - {}", yaml_quote(k)));
        }
        lines.push("remote-management:".into());
        lines.push("  allow-remote: false".into());
        lines.push(format!("  secret-key: {}", yaml_quote(&self.management_key)));
        lines.push("  disable-control-panel: true".into());
        lines.push("  disable-auto-update-panel: true".into());
        lines.push("disable-claude-cloak-mode: true".into());
        lines.push("force-model-prefix: false".into());
        lines.push("debug: false".into());

        if !self.claude_api_keys.is_empty() {
            lines.push("claude-api-key:".into());
            for entry in &self.claude_api_keys {
                lines.push(format!("  - api-key: {}", yaml_quote(&entry.api_key)));
                lines.push(format!("    prefix: {}", yaml_quote(&entry.prefix)));
                lines.push(format!("    base-url: {}", yaml_quote(&entry.base_url)));
                append_models(&mut lines, &entry.models, "    ");
            }
        }

        if !self.openai_compatibility.is_empty() {
            lines.push("openai-compatibility:".into());
            for entry in &self.openai_compatibility {
                lines.push(format!("  - name: {}", yaml_quote(&entry.name)));
                lines.push(format!("    prefix: {}", yaml_quote(&entry.prefix)));
                lines.push(format!("    base-url: {}", yaml_quote(&entry.base_url)));
                if let Some(fmt) = entry.format.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
                    lines.push(format!("    format: {}", yaml_quote(fmt)));
                }
                lines.push("    api-key-entries:".into());
                for k in &entry.api_key_entries {
                    lines.push(format!("      - api-key: {}", yaml_quote(&k.api_key)));
                }
                append_models(&mut lines, &entry.models, "    ");
            }
        }

        lines.push(String::new());
        lines.join("\n")
    }
}

fn append_models(lines: &mut Vec<String>, models: &[ProxyModel], indent: &str) {
    if models.is_empty() {
        return;
    }
    lines.push(format!("{indent}models:"));
    for m in models {
        lines.push(format!("{indent}  - name: {}", yaml_quote(&m.name)));
        lines.push(format!("{indent}    alias: {}", yaml_quote(&m.alias)));
    }
}

/// JSON-string quote for YAML double-quoted scalars (macOS parity).
pub fn yaml_quote(value: &str) -> String {
    let encoded = serde_json::to_string(value).unwrap_or_else(|_| "\"\"".into());
    // JSON may escape `/` as `\/`; YAML double-quoted scalars do not want that.
    encoded.replace("\\/", "/")
}

fn write_configuration(configuration: &ProxyConfiguration) -> Result<(), String> {
    let dir = config_directory();
    let auth = auth_directory();
    std::fs::create_dir_all(&auth).map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700));
        let _ = std::fs::set_permissions(&auth, std::fs::Permissions::from_mode(0o700));
    }
    let path = config_yaml_path();
    let yaml = configuration.to_yaml();
    let tmp = path.with_extension("yaml.tmp");
    std::fs::write(&tmp, yaml).map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600));
    }
    std::fs::rename(&tmp, &path).map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Process control
// ---------------------------------------------------------------------------

fn is_owned_running() -> bool {
    let mut g = match PROCESS.lock() {
        Ok(g) => g,
        Err(_) => return false,
    };
    if let Some(child) = g.child.as_mut() {
        match child.try_wait() {
            Ok(None) => return true,
            Ok(Some(_)) | Err(_) => {
                g.child = None;
            }
        }
    }
    false
}

fn start_process(executable: &Path, config_url: &Path, work_dir: &Path) -> Result<(), String> {
    let mut g = PROCESS.lock().map_err(|e| e.to_string())?;
    if let Some(child) = g.child.as_mut() {
        if let Ok(None) = child.try_wait() {
            return Ok(());
        }
        g.child = None;
    }
    let child = Command::new(executable)
        .args(["-config", &config_url.to_string_lossy(), "-local-model"])
        .current_dir(work_dir)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| "Không khởi động được proxy local".to_string())?;
    g.child = Some(child);
    Ok(())
}

fn stop_owned_process() -> bool {
    let mut g = match PROCESS.lock() {
        Ok(g) => g,
        Err(_) => return false,
    };
    let Some(mut child) = g.child.take() else {
        return false;
    };
    match child.try_wait() {
        Ok(None) => {
            // SIGTERM (macOS Process.terminate parity) — not SIGKILL.
            let pid = child.id();
            let _ = kill_pid(pid);
            let _ = child.wait();
            true
        }
        _ => false,
    }
}

pub fn is_managed_process(command_line: &str, config_url: &Path) -> bool {
    let path = config_url.to_string_lossy();
    command_line.contains("cliproxyapi") && command_line.contains(path.as_ref())
}

fn listener_pids(port: u16) -> Vec<u32> {
    #[cfg(target_os = "linux")]
    {
        listener_pids_linux(port)
    }
    #[cfg(not(target_os = "linux"))]
    {
        listener_pids_lsof(port)
    }
}

#[cfg(target_os = "linux")]
fn listener_pids_linux(port: u16) -> Vec<u32> {
    // Scan /proc/net/tcp{,6} for local port in LISTEN, then match inode → pid.
    let mut inodes = std::collections::HashSet::new();
    for path in ["/proc/net/tcp", "/proc/net/tcp6"] {
        let Ok(text) = std::fs::read_to_string(path) else {
            continue;
        };
        for line in text.lines().skip(1) {
            let cols: Vec<&str> = line.split_whitespace().collect();
            if cols.len() < 10 {
                continue;
            }
            // local_address is ip:port hex; state 0A = LISTEN
            let Some((_, port_hex)) = cols[1].split_once(':') else {
                continue;
            };
            let Ok(p) = u16::from_str_radix(port_hex, 16) else {
                continue;
            };
            if p != port || cols[3] != "0A" {
                continue;
            }
            if let Ok(inode) = cols[9].parse::<u64>() {
                inodes.insert(inode);
            }
        }
    }
    if inodes.is_empty() {
        return Vec::new();
    }
    let mut pids = Vec::new();
    let Ok(entries) = std::fs::read_dir("/proc") else {
        return pids;
    };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if !name.chars().all(|c| c.is_ascii_digit()) {
            continue;
        }
        let Ok(pid) = name.parse::<u32>() else {
            continue;
        };
        let fd_dir = entry.path().join("fd");
        let Ok(fds) = std::fs::read_dir(fd_dir) else {
            continue;
        };
        for fd in fds.flatten() {
            let Ok(link) = std::fs::read_link(fd.path()) else {
                continue;
            };
            let s = link.to_string_lossy();
            // socket:[inode]
            if let Some(rest) = s.strip_prefix("socket:[") {
                if let Some(num) = rest.strip_suffix(']') {
                    if let Ok(inode) = num.parse::<u64>() {
                        if inodes.contains(&inode) {
                            pids.push(pid);
                            break;
                        }
                    }
                }
            }
        }
    }
    pids
}

#[cfg(not(target_os = "linux"))]
fn listener_pids_lsof(port: u16) -> Vec<u32> {
    let output = Command::new("/usr/sbin/lsof")
        .args(["-nP", "-t", &format!("-iTCP:{port}"), "-sTCP:LISTEN"])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .ok();
    let Some(out) = output else {
        return Vec::new();
    };
    String::from_utf8_lossy(&out.stdout)
        .split_whitespace()
        .filter_map(|s| s.parse().ok())
        .collect()
}

fn command_line_for(pid: u32) -> String {
    #[cfg(target_os = "linux")]
    {
        std::fs::read_to_string(format!("/proc/{pid}/cmdline"))
            .map(|s| s.replace('\0', " "))
            .unwrap_or_default()
    }
    #[cfg(not(target_os = "linux"))]
    {
        Command::new("/bin/ps")
            .args(["-ww", "-p", &pid.to_string(), "-o", "command="])
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .output()
            .ok()
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
            .unwrap_or_default()
    }
}

fn kill_pid(pid: u32) -> bool {
    #[cfg(unix)]
    {
        // SIGTERM without depending on the full `libc` crate.
        extern "C" {
            fn kill(pid: i32, sig: i32) -> i32;
        }
        // SAFETY: libc kill with a process id and SIGTERM (15).
        unsafe { kill(pid as i32, 15) == 0 }
    }
    #[cfg(not(unix))]
    {
        let _ = pid;
        false
    }
}

/// Stops only listeners started with BirdNion's private CLIProxyAPI config.
fn stop_managed_listeners(ports: &[u16]) -> bool {
    let config_url = config_yaml_path();
    let mut stopped = stop_owned_process();
    let mut pids = std::collections::HashSet::new();
    for &port in ports {
        for pid in listener_pids(port) {
            pids.insert(pid);
        }
    }
    for pid in pids {
        let cmd = command_line_for(pid);
        if is_managed_process(&cmd, &config_url) {
            if kill_pid(pid) {
                stopped = true;
            }
        }
    }
    stopped
}

// ---------------------------------------------------------------------------
// Health + management API
// ---------------------------------------------------------------------------

async fn is_healthy() -> bool {
    let client = match reqwest::Client::builder()
        .timeout(Duration::from_secs(1))
        .build()
    {
        Ok(c) => c,
        Err(_) => return false,
    };
    let url = format!("{LOCAL_BASE_URL}/healthz");
    match client.get(&url).send().await {
        Ok(resp) => resp.status().is_success(),
        Err(_) => false,
    }
}

async fn put_management<T: Serialize>(
    management_key: &str,
    base_url: &str,
    route: &str,
    body: &T,
) -> Result<(), String> {
    let endpoint = management_endpoint(base_url, route)?;
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(12))
        .build()
        .map_err(|e| format!("client: {e}"))?;
    let resp = client
        .put(&endpoint)
        .header("Authorization", format!("Bearer {management_key}"))
        .header("Content-Type", "application/json")
        .json(body)
        .send()
        .await
        .map_err(|_| "Không kết nối được proxy local".to_string())?;
    let code = resp.status().as_u16();
    if (200..300).contains(&code) {
        Ok(())
    } else {
        Err(format!("CLIProxyAPI trả về HTTP {code}"))
    }
}

fn management_endpoint(base_url: &str, route: &str) -> Result<String, String> {
    let base = base_url.trim().trim_end_matches('/');
    if base.is_empty() || !base.contains("://") {
        return Err("Local proxy URL không hợp lệ".into());
    }
    Ok(format!("{base}/v0/management/{route}"))
}

async fn synchronize(configuration: &ProxyConfiguration) -> Result<(), String> {
    // Management API expects the JSON shapes of the managed lists.
    // Claude keys use snake-ish serde renames matching the Go server.
    #[derive(Serialize)]
    struct ClaudeKeyJson<'a> {
        #[serde(rename = "api-key")]
        api_key: &'a str,
        prefix: &'a str,
        #[serde(rename = "base-url")]
        base_url: &'a str,
        models: &'a [ProxyModel],
    }
    #[derive(Serialize)]
    struct OpenAIKeyJson<'a> {
        #[serde(rename = "api-key")]
        api_key: &'a str,
    }
    #[derive(Serialize)]
    struct OpenAICompatJson<'a> {
        name: &'a str,
        prefix: &'a str,
        #[serde(rename = "base-url")]
        base_url: &'a str,
        #[serde(rename = "api-key-entries")]
        api_key_entries: Vec<OpenAIKeyJson<'a>>,
        models: &'a [ProxyModel],
        #[serde(skip_serializing_if = "Option::is_none")]
        format: Option<&'a str>,
    }

    put_management(
        &configuration.management_key,
        &configuration.base_url,
        "api-keys",
        &configuration.api_keys,
    )
    .await?;

    let claude: Vec<ClaudeKeyJson> = configuration
        .claude_api_keys
        .iter()
        .map(|e| ClaudeKeyJson {
            api_key: &e.api_key,
            prefix: &e.prefix,
            base_url: &e.base_url,
            models: &e.models,
        })
        .collect();
    put_management(
        &configuration.management_key,
        &configuration.base_url,
        "claude-api-key",
        &claude,
    )
    .await?;

    let openai: Vec<OpenAICompatJson> = configuration
        .openai_compatibility
        .iter()
        .map(|e| OpenAICompatJson {
            name: &e.name,
            prefix: &e.prefix,
            base_url: &e.base_url,
            api_key_entries: e
                .api_key_entries
                .iter()
                .map(|k| OpenAIKeyJson {
                    api_key: &k.api_key,
                })
                .collect(),
            models: &e.models,
            format: e.format.as_deref(),
        })
        .collect();
    put_management(
        &configuration.management_key,
        &configuration.base_url,
        "openai-compatibility",
        &openai,
    )
    .await?;
    Ok(())
}

async fn ensure_running(executable: &Path) -> Result<(), String> {
    if is_owned_running() {
        return Ok(());
    }
    if is_healthy().await {
        return Ok(());
    }
    let config_url = config_yaml_path();
    let work_dir = config_directory();
    start_process(executable, &config_url, &work_dir)?;
    for _ in 0..25 {
        if is_healthy().await {
            return Ok(());
        }
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    stop_owned_process();
    Err("Không khởi động được proxy local".into())
}

async fn reload(
    executable: &Path,
    claude_profiles: &[ClaudeCodeProfile],
    codex_profiles: &[CodexProfile],
) -> Result<(), String> {
    let configuration =
        ProxyConfiguration::from_profiles(claude_profiles, codex_profiles, &auth_directory())
            .ok_or_else(|| "Thiếu Base URL hoặc API key".to_string())?;
    write_configuration(&configuration)?;
    ensure_running(executable).await?;
    match synchronize(&configuration).await {
        Ok(()) => Ok(()),
        Err(err) if err.contains("HTTP 401") || err.contains("HTTP 403") => {
            // Stale orphan still answers /healthz but rejects today's key.
            let _ = stop_managed_listeners(&[LOCAL_PORT, LEGACY_LOCAL_PORT]);
            ensure_running(executable).await?;
            synchronize(&configuration).await
        }
        Err(err) => Err(err),
    }
}

// ---------------------------------------------------------------------------
// Profile prepare / save
// ---------------------------------------------------------------------------

fn shared_management_key(
    excluding_claude_id: Option<&str>,
    excluding_codex_id: Option<&str>,
    fallback: Option<&str>,
) -> String {
    let settings = config::load();
    let from_active_claude = settings
        .claude_code_profiles
        .iter()
        .filter(|p| {
            excluding_claude_id.map(|id| p.id != id).unwrap_or(true)
                && uses_embedded_cli_proxy(p)
                && is_configuration_current(p)
        })
        .find_map(|p| cleaned(p.cli_proxy_management_key.as_deref()));
    if let Some(k) = from_active_claude {
        return k;
    }
    let from_active_codex = settings
        .codex_profiles
        .iter()
        .filter(|p| {
            excluding_codex_id.map(|id| p.id != id).unwrap_or(true)
                && p.uses_embedded_cli_proxy()
                && codex_config::is_cli_proxy_configuration_current(p)
        })
        .find_map(|p| cleaned(p.cli_proxy_management_key.as_deref()));
    if let Some(k) = from_active_codex {
        return k;
    }
    if let Some(k) = cleaned(fallback) {
        return k;
    }
    let any_claude = settings
        .claude_code_profiles
        .iter()
        .filter(|p| {
            excluding_claude_id.map(|id| p.id != id).unwrap_or(true) && uses_embedded_cli_proxy(p)
        })
        .find_map(|p| cleaned(p.cli_proxy_management_key.as_deref()));
    if let Some(k) = any_claude {
        return k;
    }
    settings
        .codex_profiles
        .iter()
        .filter(|p| {
            excluding_codex_id.map(|id| p.id != id).unwrap_or(true) && p.uses_embedded_cli_proxy()
        })
        .find_map(|p| cleaned(p.cli_proxy_management_key.as_deref()))
        .unwrap_or_else(random_secret)
}

fn prepare_claude_profile(profile: &ClaudeCodeProfile) -> Result<ClaudeCodeProfile, String> {
    if !has_upstream_configuration(profile) {
        return Err("Thiếu Base URL hoặc API key".into());
    }
    let mut settings = config::load();
    let mut profiles = settings.claude_code_profiles;
    if let Some(idx) = profiles.iter().position(|p| p.id == profile.id) {
        profiles[idx] = profile.clone();
    } else {
        profiles.push(profile.clone());
    }

    let shared_mgmt = shared_management_key(
        Some(&profile.id),
        None,
        profile.cli_proxy_management_key.as_deref(),
    );

    for p in &mut profiles {
        if p.id == profile.id {
            let needs_fresh = p.embedded_local_proxy != Some(true)
                || cleaned(p.cli_proxy_api_key.as_deref()).is_none();
            p.embedded_local_proxy = Some(true);
            p.cli_proxy_base_url = Some(LOCAL_BASE_URL.to_string());
            if needs_fresh {
                p.cli_proxy_api_key = Some(random_secret());
            }
            p.cli_proxy_management_key = Some(shared_mgmt.clone());
            p.cli_proxy_applied_signature = None;
        } else if p.cli_proxy_applied_signature.is_some() {
            // One active Claude profile on the helper at a time.
            p.cli_proxy_applied_signature = None;
        }
    }

    let current = profiles
        .iter()
        .find(|p| p.id == profile.id)
        .cloned()
        .ok_or_else(|| "Thiếu Base URL hoặc API key".to_string())?;
    settings.claude_code_profiles = profiles;
    config::save(&settings)?;
    Ok(current)
}

fn prepare_codex_profile(profile: &CodexProfile) -> Result<CodexProfile, String> {
    if cleaned(Some(profile.base_url.as_str())).is_none()
        || cleaned(Some(profile.api_key.as_str())).is_none()
        || cleaned(Some(profile.model.as_str())).is_none()
    {
        return Err("Thiếu Base URL, API key hoặc model cho Codex".into());
    }
    let mut settings = config::load();
    let mut profiles = settings.codex_profiles;
    if let Some(idx) = profiles.iter().position(|p| p.id == profile.id) {
        profiles[idx] = profile.clone();
    } else {
        profiles.push(profile.clone());
    }

    let shared_mgmt = shared_management_key(
        None,
        Some(&profile.id),
        profile.cli_proxy_management_key.as_deref(),
    );

    for p in &mut profiles {
        if p.id == profile.id {
            let needs_fresh = !p.uses_embedded_cli_proxy()
                || cleaned(p.cli_proxy_api_key.as_deref()).is_none();
            p.connection_mode_raw = Some(CodexProfile::MODE_LOCAL_PROXY.into());
            p.cli_proxy_base_url = Some(LOCAL_BASE_URL.to_string());
            if needs_fresh {
                p.cli_proxy_api_key = Some(random_secret());
            }
            p.cli_proxy_management_key = Some(shared_mgmt.clone());
            p.cli_proxy_applied_signature = None;
        } else if p.cli_proxy_applied_signature.is_some() {
            p.cli_proxy_applied_signature = None;
        }
    }

    let current = profiles
        .iter()
        .find(|p| p.id == profile.id)
        .cloned()
        .ok_or_else(|| "Thiếu Base URL, API key hoặc model cho Codex".to_string())?;
    settings.codex_profiles = profiles;
    config::save(&settings)?;
    Ok(current)
}

fn active_claude_profiles(profiles: &[ClaudeCodeProfile]) -> Vec<ClaudeCodeProfile> {
    profiles
        .iter()
        .filter(|p| uses_embedded_cli_proxy(p) && is_configuration_current(p))
        .cloned()
        .collect()
}

fn active_codex_profiles(profiles: &[CodexProfile]) -> Vec<CodexProfile> {
    profiles
        .iter()
        .filter(|p| p.uses_embedded_cli_proxy() && codex_config::is_cli_proxy_configuration_current(p))
        .cloned()
        .collect()
}

// ---------------------------------------------------------------------------
// Public orchestration
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProxyStatus {
    /// needsConfig | checking | starting | running | needsUpdate | stopped | failed
    pub state: String,
    pub endpoint: String,
    pub configuration_current: bool,
    pub has_upstream: bool,
}

pub async fn status_for_profile(profile_id: &str) -> ProxyStatus {
    let endpoint = LOCAL_ENDPOINT.to_string();
    let Some(profile) = config::find_profile(profile_id) else {
        return ProxyStatus {
            state: "needsConfig".into(),
            endpoint,
            configuration_current: false,
            has_upstream: false,
        };
    };
    let has_upstream = has_upstream_configuration(&profile);
    if !uses_embedded_cli_proxy(&profile) || !has_upstream {
        return ProxyStatus {
            state: "needsConfig".into(),
            endpoint,
            configuration_current: false,
            has_upstream,
        };
    }

    let rt = runtime();
    if rt == RuntimeState::Starting {
        return ProxyStatus {
            state: "starting".into(),
            endpoint,
            configuration_current: is_configuration_current(&profile),
            has_upstream,
        };
    }

    let healthy = is_healthy().await;
    let current = is_configuration_current(&profile);
    let state = if healthy {
        if current {
            set_runtime(RuntimeState::Running);
            "running"
        } else {
            set_runtime(RuntimeState::Running);
            "needsUpdate"
        }
    } else if rt == RuntimeState::Failed {
        "failed"
    } else {
        set_runtime(RuntimeState::Stopped);
        "stopped"
    };

    ProxyStatus {
        state: state.into(),
        endpoint,
        configuration_current: current,
        has_upstream,
    }
}

pub async fn prepare_profile(
    app: &AppHandle,
    profile_id: &str,
) -> Result<ProxyStatus, String> {
    let profile =
        config::find_profile(profile_id).ok_or_else(|| "Không tìm thấy config".to_string())?;
    if !has_upstream_configuration(&profile) {
        return Err("Thiếu Base URL hoặc API key".into());
    }
    set_runtime(RuntimeState::Starting);
    let executable = resolve_binary(app)?;
    match prepare_and_reload(&executable, &profile).await {
        Ok(prepared) => {
            let mut applied = prepared;
            applied.cli_proxy_applied_signature = configuration_signature(&applied);
            // Persist signature on this profile.
            let mut settings = config::load();
            if let Some(p) = settings
                .claude_code_profiles
                .iter_mut()
                .find(|p| p.id == applied.id)
            {
                p.cli_proxy_applied_signature = applied.cli_proxy_applied_signature.clone();
                p.cli_proxy_api_key = applied.cli_proxy_api_key.clone();
                p.cli_proxy_management_key = applied.cli_proxy_management_key.clone();
                p.cli_proxy_base_url = applied.cli_proxy_base_url.clone();
                p.embedded_local_proxy = Some(true);
            }
            config::save(&settings)?;
            set_runtime(RuntimeState::Running);
            Ok(ProxyStatus {
                state: "running".into(),
                endpoint: LOCAL_ENDPOINT.into(),
                configuration_current: true,
                has_upstream: true,
            })
        }
        Err(e) => {
            set_runtime(RuntimeState::Failed);
            Err(e)
        }
    }
}

async fn prepare_and_reload(
    executable: &Path,
    profile: &ClaudeCodeProfile,
) -> Result<ClaudeCodeProfile, String> {
    let prepared = prepare_claude_profile(profile)?;
    let active_codex = active_codex_profiles(&config::load().codex_profiles);
    // Reload with the prepared profile as the sole managed Claude entry
    // (signature not yet stamped — is_embedded_cli_proxy_ready still holds).
    reload(executable, &[prepared.clone()], &active_codex).await?;
    Ok(prepared)
}

/// Prepare a Codex profile on the embedded proxy and reload the helper.
pub async fn prepare_codex_profile_cmd(
    app: &AppHandle,
    profile_id: &str,
) -> Result<ProxyStatus, String> {
    let profile =
        config::find_codex_profile(profile_id).ok_or_else(|| "Không tìm thấy config".to_string())?;
    if cleaned(Some(profile.base_url.as_str())).is_none()
        || cleaned(Some(profile.api_key.as_str())).is_none()
        || cleaned(Some(profile.model.as_str())).is_none()
    {
        return Err("Thiếu Base URL, API key hoặc model cho Codex".into());
    }
    set_runtime(RuntimeState::Starting);
    let executable = resolve_binary(app)?;
    match prepare_and_reload_codex(&executable, &profile).await {
        Ok(prepared) => {
            let mut applied = prepared;
            applied.cli_proxy_applied_signature =
                codex_config::codex_cli_proxy_configuration_signature(&applied);
            let mut settings = config::load();
            if let Some(p) = settings
                .codex_profiles
                .iter_mut()
                .find(|p| p.id == applied.id)
            {
                *p = applied.clone();
            }
            config::save(&settings)?;
            // Overlay bearer rotation — keep existing --profile file in sync.
            if codex_config::profile_flag(&applied.id, None).is_some() {
                let _ = codex_config::write_profile_file(&applied, None);
            }
            set_runtime(RuntimeState::Running);
            Ok(ProxyStatus {
                state: "running".into(),
                endpoint: LOCAL_ENDPOINT.into(),
                configuration_current: true,
                has_upstream: true,
            })
        }
        Err(e) => {
            set_runtime(RuntimeState::Failed);
            Err(e)
        }
    }
}

async fn prepare_and_reload_codex(
    executable: &Path,
    profile: &CodexProfile,
) -> Result<CodexProfile, String> {
    let prepared = prepare_codex_profile(profile)?;
    let active_claude = active_claude_profiles(&config::load().claude_code_profiles);
    reload(executable, &active_claude, &[prepared.clone()]).await?;
    Ok(prepared)
}

/// Drop Codex proxy entries while keeping any active Claude profile.
pub async fn deactivate_codex_proxy_profiles(app: &AppHandle) -> Result<(), String> {
    let settings = config::load();
    let active_claude = active_claude_profiles(&settings.claude_code_profiles);
    if active_claude.is_empty() {
        stop_proxy();
        return Ok(());
    }
    let executable = resolve_binary(app)?;
    set_runtime(RuntimeState::Starting);
    match reload(&executable, &active_claude, &[]).await {
        Ok(()) => {
            set_runtime(RuntimeState::Running);
            Ok(())
        }
        Err(e) => {
            set_runtime(RuntimeState::Failed);
            Err(e)
        }
    }
}

pub async fn status_for_codex_profile(profile_id: &str) -> ProxyStatus {
    let endpoint = LOCAL_ENDPOINT.to_string();
    let Some(profile) = config::find_codex_profile(profile_id) else {
        return ProxyStatus {
            state: "needsConfig".into(),
            endpoint,
            configuration_current: false,
            has_upstream: false,
        };
    };
    let has_upstream = cleaned(Some(profile.base_url.as_str())).is_some()
        && cleaned(Some(profile.api_key.as_str())).is_some()
        && cleaned(Some(profile.model.as_str())).is_some();
    if !profile.uses_embedded_cli_proxy() || !has_upstream {
        return ProxyStatus {
            state: "needsConfig".into(),
            endpoint,
            configuration_current: false,
            has_upstream,
        };
    }
    let rt = runtime();
    if rt == RuntimeState::Starting {
        return ProxyStatus {
            state: "starting".into(),
            endpoint,
            configuration_current: codex_config::is_cli_proxy_configuration_current(&profile),
            has_upstream,
        };
    }
    let healthy = is_healthy().await;
    let current = codex_config::is_cli_proxy_configuration_current(&profile);
    let state = if healthy {
        set_runtime(RuntimeState::Running);
        if current {
            "running"
        } else {
            "needsUpdate"
        }
    } else if rt == RuntimeState::Failed {
        "failed"
    } else {
        set_runtime(RuntimeState::Stopped);
        "stopped"
    };
    ProxyStatus {
        state: state.into(),
        endpoint,
        configuration_current: current,
        has_upstream,
    }
}

pub fn stop_proxy() -> bool {
    let stopped = stop_managed_listeners(&[LOCAL_PORT, LEGACY_LOCAL_PORT]);
    set_runtime(RuntimeState::Stopped);
    stopped
}

/// Non-blocking restore after app launch when a previously activated proxy
/// profile exists. Failures stay quiet — Settings can surface them later.
pub async fn restore_if_configured(app: &AppHandle) {
    let settings = config::load();
    let ready_claude = settings
        .claude_code_profiles
        .iter()
        .any(|p| uses_embedded_cli_proxy(p) && is_embedded_cli_proxy_ready(p));
    let ready_codex = settings
        .codex_profiles
        .iter()
        .any(|p| p.uses_embedded_cli_proxy() && codex_config::is_embedded_cli_proxy_ready(p));
    if !ready_claude && !ready_codex {
        set_runtime(RuntimeState::Stopped);
        return;
    }

    // Migrate legacy port marker if needed.
    let mut profiles = settings.claude_code_profiles.clone();
    let mut migrated = false;
    for p in &mut profiles {
        if uses_embedded_cli_proxy(p)
            && is_embedded_cli_proxy_ready(p)
            && normalized_cli_proxy_base_url(p.cli_proxy_base_url.as_deref()).as_deref()
                != Some(LOCAL_BASE_URL)
        {
            p.cli_proxy_base_url = Some(LOCAL_BASE_URL.to_string());
            p.cli_proxy_applied_signature = None;
            migrated = true;
        }
    }
    if migrated {
        let mut full = config::load();
        full.claude_code_profiles = profiles;
        let _ = config::save(&full);
        set_runtime(RuntimeState::Stopped);
        return;
    }

    let active = active_claude_profiles(&profiles);
    let active_codex = active_codex_profiles(&settings.codex_profiles);
    if active.len() > 1 || active_codex.len() > 1 || (active.is_empty() && active_codex.is_empty()) {
        set_runtime(RuntimeState::Stopped);
        return;
    }

    let Ok(executable) = resolve_binary(app) else {
        set_runtime(RuntimeState::Failed);
        return;
    };
    set_runtime(RuntimeState::Starting);
    match reload(&executable, &active, &active_codex).await {
        Ok(()) => set_runtime(RuntimeState::Running),
        Err(_) => set_runtime(RuntimeState::Failed),
    }
}

// ---------------------------------------------------------------------------
// Tauri commands
// ---------------------------------------------------------------------------

#[tauri::command]
pub async fn cli_proxy_status(profile_id: String) -> ProxyStatus {
    status_for_profile(&profile_id).await
}

#[tauri::command]
pub async fn cli_proxy_prepare(
    app: AppHandle,
    profile_id: String,
) -> Result<ProxyStatus, String> {
    prepare_profile(&app, &profile_id).await
}

#[tauri::command]
pub async fn cli_proxy_codex_status(profile_id: String) -> ProxyStatus {
    status_for_codex_profile(&profile_id).await
}

#[tauri::command]
pub async fn cli_proxy_codex_prepare(
    app: AppHandle,
    profile_id: String,
) -> Result<ProxyStatus, String> {
    prepare_codex_profile_cmd(&app, &profile_id).await
}

#[tauri::command]
pub fn cli_proxy_stop() -> bool {
    stop_proxy()
}

#[tauri::command]
pub async fn cli_proxy_restore(app: AppHandle) {
    restore_if_configured(&app).await;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_profile() -> ClaudeCodeProfile {
        ClaudeCodeProfile {
            id: "abc-123".into(),
            name: Some("Test".into()),
            base_url: Some("https://api.example.com/anthropic".into()),
            token: Some("sk-upstream-secret".into()),
            haiku_model: Some("model-h".into()),
            sonnet_model: Some("model-s[1m]".into()),
            opus_model: Some("model-o".into()),
            embedded_local_proxy: Some(true),
            cli_proxy_base_url: Some(LOCAL_BASE_URL.into()),
            cli_proxy_api_key: Some("local-loopback-key".into()),
            cli_proxy_management_key: Some("mgmt-key".into()),
            ..Default::default()
        }
    }

    #[test]
    fn yaml_writer_emits_loopback_and_claude_entries() {
        let p = sample_profile();
        let cfg = ProxyConfiguration::from_profiles(&[p], &[], Path::new("/tmp/auth")).unwrap();
        let yaml = cfg.to_yaml();
        assert!(yaml.contains("host: \"127.0.0.1\""));
        assert!(yaml.contains(&format!("port: {LOCAL_PORT}")));
        assert!(yaml.contains("api-keys:"));
        assert!(yaml.contains("local-loopback-key"));
        assert!(yaml.contains("remote-management:"));
        assert!(yaml.contains("allow-remote: false"));
        assert!(yaml.contains("secret-key: \"mgmt-key\""));
        assert!(yaml.contains("claude-api-key:"));
        assert!(yaml.contains("sk-upstream-secret"));
        assert!(yaml.contains("https://api.example.com/anthropic"));
        // Alias strips [1m]
        assert!(yaml.contains("alias: \"model-s\""));
        assert!(yaml.contains("name: \"model-s[1m]\""));
        // Secrets must not be logged by the test harness either — just present in yaml file content.
        assert!(!yaml.contains("openai-compatibility:"));
    }

    #[test]
    fn yaml_quote_escapes_specials() {
        assert_eq!(yaml_quote("plain"), "\"plain\"");
        assert_eq!(yaml_quote("a\"b"), "\"a\\\"b\"");
        assert_eq!(yaml_quote("path/to"), "\"path/to\"");
    }

    #[test]
    fn signature_is_stable_and_sensitive_to_upstream() {
        let p = sample_profile();
        let a = configuration_signature(&p).unwrap();
        let b = configuration_signature(&p).unwrap();
        assert_eq!(a, b);
        assert_eq!(a.len(), 64); // sha256 hex
        let mut changed = p.clone();
        changed.token = Some("sk-other".into());
        let c = configuration_signature(&changed).unwrap();
        assert_ne!(a, c);
    }

    #[test]
    fn local_model_alias_strips_1m_suffix() {
        assert_eq!(local_model_alias("MiniMax-M3[1m]"), "MiniMax-M3");
        assert_eq!(local_model_alias("MiniMax-M3[1M]"), "MiniMax-M3");
        assert_eq!(local_model_alias("plain"), "plain");
    }

    #[test]
    fn managed_process_requires_cliproxy_and_config_path() {
        let path = Path::new("/home/u/.config/birdnion/cli-proxy-api/config.yaml");
        assert!(is_managed_process(
            "cliproxyapi -config /home/u/.config/birdnion/cli-proxy-api/config.yaml -local-model",
            path
        ));
        assert!(!is_managed_process(
            "nginx -c /home/u/.config/birdnion/cli-proxy-api/config.yaml",
            path
        ));
        assert!(!is_managed_process("cliproxyapi -config /other/config.yaml", path));
    }

    #[test]
    fn normalized_base_strips_v1_suffix() {
        assert_eq!(
            normalized_cli_proxy_base_url(Some("http://127.0.0.1:24323/v1")),
            Some("http://127.0.0.1:24323".into())
        );
        assert_eq!(
            normalized_cli_proxy_base_url(Some("http://127.0.0.1:24323")),
            Some("http://127.0.0.1:24323".into())
        );
    }

    #[test]
    fn random_secret_is_base64url_without_padding() {
        let s = random_secret();
        assert!(!s.contains('+'));
        assert!(!s.contains('/'));
        assert!(!s.contains('='));
        assert!(s.len() >= 40);
    }

    fn sample_openai_profile(format: Option<&str>) -> ClaudeCodeProfile {
        ClaudeCodeProfile {
            id: "oa-456".into(),
            name: Some("OpenAI upstream".into()),
            compatibility_mode: Some("openai".into()),
            open_ai_base_url: Some("https://openai-upstream.example/v1".into()),
            open_ai_api_key: Some("upstream-openai-key".into()),
            open_ai_format: format.map(str::to_string),
            haiku_model: Some("gpt-h".into()),
            sonnet_model: Some("gpt-s[1m]".into()),
            opus_model: Some("gpt-o".into()),
            embedded_local_proxy: Some(true),
            cli_proxy_base_url: Some(LOCAL_BASE_URL.into()),
            cli_proxy_api_key: Some("local-loopback-key".into()),
            cli_proxy_management_key: Some("mgmt-key".into()),
            ..Default::default()
        }
    }

    #[test]
    fn signature_includes_openai_fields() {
        let chat = sample_openai_profile(None);
        let responses = sample_openai_profile(Some("responses"));
        let chat_sig = configuration_signature(&chat).unwrap();
        let resp_sig = configuration_signature(&responses).unwrap();
        assert_ne!(chat_sig, resp_sig);

        let mut key_changed = chat.clone();
        key_changed.open_ai_api_key = Some("other-upstream".into());
        assert_ne!(chat_sig, configuration_signature(&key_changed).unwrap());

        let mut url_changed = chat.clone();
        url_changed.open_ai_base_url = Some("https://other.example/v1".into());
        assert_ne!(chat_sig, configuration_signature(&url_changed).unwrap());

        // Anthropic signature must not match OpenAI with same loopback keys.
        let anthropic = sample_profile();
        assert_ne!(chat_sig, configuration_signature(&anthropic).unwrap());
    }

    #[test]
    fn yaml_writer_emits_openai_compatibility_entries() {
        let p = sample_openai_profile(Some("responses"));
        let cfg = ProxyConfiguration::from_profiles(&[p], &[], Path::new("/tmp/auth")).unwrap();
        let yaml = cfg.to_yaml();
        assert!(yaml.contains("openai-compatibility:"));
        assert!(yaml.contains("name: \"birdnion-oa-456\""));
        assert!(yaml.contains("base-url: \"https://openai-upstream.example/v1\""));
        assert!(yaml.contains("upstream-openai-key"));
        assert!(yaml.contains("format: \"responses\""));
        assert!(yaml.contains("alias: \"gpt-s\""));
        assert!(yaml.contains("name: \"gpt-s[1m]\""));
        // OpenAI profiles must not also land in claude-api-key.
        assert!(!yaml.contains("claude-api-key:"));
    }

    #[test]
    fn yaml_openai_chat_omits_format() {
        let p = sample_openai_profile(None);
        let cfg = ProxyConfiguration::from_profiles(&[p], &[], Path::new("/tmp/auth")).unwrap();
        let yaml = cfg.to_yaml();
        assert!(yaml.contains("openai-compatibility:"));
        assert!(!yaml.contains("format:"));
    }

    #[test]
    fn openai_without_explicit_flag_uses_proxy() {
        let mut p = sample_openai_profile(None);
        p.embedded_local_proxy = None;
        assert!(uses_embedded_cli_proxy(&p));
        assert!(has_upstream_configuration(&p));
    }

    #[test]
    fn openai_uses_open_ai_fields_for_upstream() {
        let mut p = sample_openai_profile(None);
        // Anthropic pair empty — still ready via openAI* fields.
        p.base_url = None;
        p.token = None;
        assert!(has_upstream_configuration(&p));
        assert_eq!(
            upstream_base_url(&p).as_deref(),
            Some("https://openai-upstream.example/v1")
        );
        assert_eq!(
            upstream_api_key(&p).as_deref(),
            Some("upstream-openai-key")
        );
    }
}
