//! Antigravity IDE local-server quota provider — port of `AntigravityProvider.swift`.
//!
//! Detection approach (portable POSIX, matches Swift):
//!   1. `ps -ax -o pid=,command=` to find a running `language_server` or `agy` process.
//!   2. Extract `--csrf_token` from the command line.
//!   3. `lsof -nP -iTCP -sTCP:LISTEN -a -p <pid>` for listening ports.
//!   4. POST Connect/JSON (Content-Type: application/json, Connect-Protocol-Version: 1,
//!      X-Codeium-Csrf-Token when non-empty) to the local language server.
//!
//! Fallback chain (mirrors Swift's `auto` mode): running process → `agy` CLI
//! warm-spawn (spawn briefly so its embedded localhost server opens a port,
//! poll `lsof` up to ~7s, then probe the same endpoints) → Google OAuth
//! remote (`cloudcode-pa.googleapis.com`) using a stored refresh token. Each
//! fallback is best-effort and silently skipped on failure; only the final
//! step surfaces an error.
//!
//! The OAuth store (`~/.config/birdnion/antigravity-oauth.json`) uses the same
//! shape as Swift's `AntigravityOAuthStore`. Client id/secret resolve from the
//! store file, then `ANTIGRAVITY_OAUTH_CLIENT_ID`/`_SECRET` env vars — the
//! macOS-only step of scanning an installed `Antigravity.app` bundle for the
//! embedded OAuth client has no Linux equivalent and is intentionally skipped.

use std::process::{Command, Stdio};
use std::time::Duration;

use serde::Deserialize;
use serde_json::Value;

use crate::config;
use crate::providers::{display_name, ProviderStatus, QuotaWindow};

const QUOTA_SUMMARY_PATH: &str = "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary";
const USER_STATUS_PATH: &str = "/exa.language_server_pb.LanguageServerService/GetUserStatus";
const PROBE_TIMEOUT: Duration = Duration::from_secs(8);
const WARM_SPAWN_TIMEOUT: Duration = Duration::from_secs(7);
const OAUTH_TOKEN_URL: &str = "https://oauth2.googleapis.com/token";
const OAUTH_QUOTA_URL: &str = "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota";

struct ProcessInfo {
    pid: i32,
    csrf_token: String,
}

pub async fn fetch(cfg: &config::Provider) -> ProviderStatus {
    let name = display_name(cfg);

    if let Some(status) = fetch_from_running_process(cfg, &name).await {
        return status;
    }
    if let Some(status) = fetch_via_cli_warm_session(cfg, &name).await {
        return status;
    }
    if let Some(status) = fetch_via_oauth(cfg, &name).await {
        return status;
    }

    ProviderStatus::failure(&cfg.id, &name, "Antigravity: cần IDE đang chạy, agy CLI, hoặc đăng nhập Google")
}

/// Probe an already-running `language_server`/`agy` process found via `ps`.
/// Returns `None` (not an error) when nothing is running, so callers can fall
/// through to the next best-effort path.
async fn fetch_from_running_process(cfg: &config::Provider, name: &str) -> Option<ProviderStatus> {
    // ps/lsof are blocking subprocess calls; run them off the async executor.
    let process = tauri::async_runtime::spawn_blocking(detect_process).await.ok()?.ok()?;
    let pid = process.pid;
    let ports = tauri::async_runtime::spawn_blocking(move || listening_ports(pid)).await.ok()?.ok()?;
    if ports.is_empty() {
        return None;
    }
    probe_endpoints(cfg, name, &process, &ports).await
}

/// Spawn the `agy` CLI so its embedded localhost server opens a port, then
/// probe it the same way as a live IDE process. Silently skipped (returns
/// `None`) when the binary is missing or never opens a port — never a hard
/// error, matching Swift's `fetchViaCLIWarmSession`.
async fn fetch_via_cli_warm_session(cfg: &config::Provider, name: &str) -> Option<ProviderStatus> {
    let binary = tauri::async_runtime::spawn_blocking(resolve_agy_binary).await.ok()?;
    let binary = binary?;

    let mut child = Command::new(&binary)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let pid = child.id() as i32;

    let deadline = std::time::Instant::now() + WARM_SPAWN_TIMEOUT;
    let mut ports: Vec<u16> = Vec::new();
    while std::time::Instant::now() < deadline {
        match tauri::async_runtime::spawn_blocking(move || listening_ports(pid)).await {
            Ok(Ok(p)) if !p.is_empty() => {
                ports = p;
                break;
            }
            _ => tokio::time::sleep(Duration::from_millis(400)).await,
        }
    }

    let result = if ports.is_empty() {
        None
    } else {
        let process = ProcessInfo { pid, csrf_token: String::new() };
        probe_endpoints(cfg, name, &process, &ports).await
    };

    // Never leave the spawned agy process lingering after we're done with it.
    let _ = child.kill();
    let _ = child.wait();
    result
}

/// Resolves the `agy` binary: `PATH` lookup, then well-known install paths
/// (matches Swift's `resolveAgyBinary`, minus the macOS Homebrew prefix).
fn resolve_agy_binary() -> Option<String> {
    if let Ok(path_var) = std::env::var("PATH") {
        for dir in path_var.split(':') {
            let candidate = std::path::Path::new(dir).join("agy");
            if is_executable(&candidate) {
                return Some(candidate.to_string_lossy().into_owned());
            }
        }
    }
    let home = std::env::var("HOME").unwrap_or_default();
    let candidates = [format!("{home}/.local/bin/agy"), "/usr/local/bin/agy".to_string()];
    candidates.into_iter().find(|p| is_executable(std::path::Path::new(p)))
}

fn is_executable(path: &std::path::Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::metadata(path).map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0).unwrap_or(false)
    }
    #[cfg(not(unix))]
    {
        path.is_file()
    }
}

async fn probe_endpoints(cfg: &config::Provider, name: &str, process: &ProcessInfo, ports: &[u16]) -> Option<ProviderStatus> {
    for &port in ports {
        if let Some(status) = try_summary_endpoint(cfg, name, process, port).await {
            return Some(status);
        }
        if let Some(status) = try_user_status_endpoint(cfg, name, process, port).await {
            return Some(status);
        }
    }
    None
}

fn detect_process() -> Result<ProcessInfo, String> {
    let output = run_command("/bin/ps", &["-ax", "-o", "pid=,command="], PROBE_TIMEOUT)?;
    parse_process_list(&output).ok_or_else(|| "notRunning".to_string())
}

/// Pure: parse `ps -ax -o pid=,command=` output for a language_server/agy process.
fn parse_process_list(output: &str) -> Option<ProcessInfo> {
    for raw_line in output.lines() {
        let trimmed = raw_line.trim();
        let mut parts = trimmed.splitn(2, ' ');
        let pid: i32 = parts.next()?.parse().ok()?;
        let command = parts.next().unwrap_or("").trim();
        if command.is_empty() {
            continue;
        }
        let lower = command.to_lowercase();
        if !is_antigravity_process(&lower) {
            continue;
        }
        if let Some(token) = extract_flag("--csrf_token", command) {
            return Some(ProcessInfo { pid, csrf_token: token });
        }
        if is_cli_process(&lower) {
            return Some(ProcessInfo { pid, csrf_token: String::new() });
        }
    }
    None
}

fn is_antigravity_process(lower: &str) -> bool {
    is_language_server_process(lower) || is_cli_process(lower)
}

fn is_language_server_process(lower: &str) -> bool {
    let looks_like_language_server = lower
        .split(|c: char| c == '/' || c == '\\' || c.is_whitespace())
        .any(|segment| {
            let s = segment.strip_suffix(".exe").unwrap_or(segment);
            s == "language_server" || s == "language-server" || (s.starts_with("language") && (s.contains('_') || s.contains('-')))
        });
    looks_like_language_server && (lower.contains("antigravity") || lower.contains("--app_data_dir"))
}

fn is_cli_process(lower: &str) -> bool {
    lower.split(|c: char| c == '/' || c == '\\' || c.is_whitespace()).any(|segment| {
        segment == "antigravity-cli" || segment == "antigravity_cli" || segment == "agy"
    })
}

fn extract_flag(flag: &str, command: &str) -> Option<String> {
    let idx = command.find(flag)?;
    let rest = &command[idx + flag.len()..];
    let rest = rest.trim_start_matches(['=', ' ', '\t']);
    let end = rest.find(char::is_whitespace).unwrap_or(rest.len());
    let value = &rest[..end];
    (!value.is_empty()).then(|| value.to_string())
}

fn listening_ports(pid: i32) -> Result<Vec<u16>, String> {
    let lsof = ["/usr/sbin/lsof", "/usr/bin/lsof"]
        .into_iter()
        .find(|p| std::path::Path::new(p).exists())
        .ok_or_else(|| "lsof không có sẵn".to_string())?;
    let pid_str = pid.to_string();
    let output = run_command(lsof, &["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", &pid_str], PROBE_TIMEOUT)?;
    let ports = parse_listening_ports(&output);
    if ports.is_empty() {
        return Err("Không tìm thấy port đang listen".to_string());
    }
    Ok(ports)
}

/// Pure: parse `lsof -nP -iTCP -sTCP:LISTEN` output for listening TCP ports.
fn parse_listening_ports(output: &str) -> Vec<u16> {
    let mut ports: Vec<u16> = Vec::new();
    for line in output.lines() {
        let Some(listen_idx) = line.find("(LISTEN)") else { continue };
        let before = &line[..listen_idx];
        let Some(colon_idx) = before.rfind(':') else { continue };
        let port_str: String = before[colon_idx + 1..].chars().take_while(|c| c.is_ascii_digit()).collect();
        if let Ok(port) = port_str.trim().parse::<u16>() {
            if !ports.contains(&port) {
                ports.push(port);
            }
        }
    }
    ports.sort_unstable();
    ports
}

/// Runs a subprocess with a hard timeout, killing it on expiry. Uses polling
/// since std::process has no native timeout support (matches kiro.rs).
fn run_command(binary: &str, args: &[&str], timeout: Duration) -> Result<String, String> {
    let mut child = Command::new(binary)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| format!("Không chạy được {binary}: {e}"))?;

    let start = std::time::Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_status)) => break,
            Ok(None) => {
                if start.elapsed() >= timeout {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(format!("{binary} timeout"));
                }
                std::thread::sleep(Duration::from_millis(50));
            }
            Err(e) => return Err(format!("{binary} lỗi: {e}")),
        }
    }

    let output = child.wait_with_output().map_err(|e| format!("{binary} lỗi: {e}"))?;
    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}

async fn post_connect_json(port: u16, path: &str, csrf_token: &str, body: Value) -> Result<Value, String> {
    let client = reqwest::Client::builder()
        .timeout(PROBE_TIMEOUT)
        .build()
        .map_err(|e| format!("Client error: {e}"))?;
    let url = format!("http://127.0.0.1:{port}{path}");
    let mut req = client.post(&url).header("Content-Type", "application/json").header("Connect-Protocol-Version", "1").json(&body);
    if !csrf_token.is_empty() {
        req = req.header("X-Codeium-Csrf-Token", csrf_token);
    }
    let resp = req.send().await.map_err(|e| format!("Network: {e}"))?;
    if resp.status().as_u16() != 200 {
        return Err(format!("HTTP {}", resp.status().as_u16()));
    }
    resp.json::<Value>().await.map_err(|e| format!("Invalid JSON: {e}"))
}

async fn try_summary_endpoint(cfg: &config::Provider, name: &str, process: &ProcessInfo, port: u16) -> Option<ProviderStatus> {
    let body = serde_json::json!({"forceRefresh": true});
    let data = post_connect_json(port, QUOTA_SUMMARY_PATH, &process.csrf_token, body).await.ok()?;
    let groups = parse_quota_summary(&data)?;
    let windows = map_summary_windows(&groups);
    if windows.is_empty() {
        return None;
    }
    let email = fetch_identity_email(process, port).await;
    Some(build_status(cfg, name, windows, email))
}

async fn try_user_status_endpoint(cfg: &config::Provider, name: &str, process: &ProcessInfo, port: u16) -> Option<ProviderStatus> {
    let body = default_request_body();
    let data = post_connect_json(port, USER_STATUS_PATH, &process.csrf_token, body).await.ok()?;
    let (quotas, email) = parse_user_status(&data)?;
    let windows = map_model_windows(&quotas);
    if windows.is_empty() {
        return None;
    }
    Some(build_status(cfg, name, windows, email))
}

async fn fetch_identity_email(process: &ProcessInfo, port: u16) -> Option<String> {
    let data = post_connect_json(port, USER_STATUS_PATH, &process.csrf_token, default_request_body()).await.ok()?;
    parse_user_status(&data)?.1
}

fn default_request_body() -> Value {
    serde_json::json!({
        "metadata": {
            "ideName": "antigravity",
            "extensionName": "antigravity",
            "ideVersion": "unknown",
            "locale": "en",
        }
    })
}

fn build_status(cfg: &config::Provider, name: &str, windows: Vec<QuotaWindow>, email: Option<String>) -> ProviderStatus {
    let account_label = cfg.account_label.clone().or(email).unwrap_or_else(|| "Antigravity".to_string());
    ProviderStatus {
        id: cfg.id.clone(),
        display_name: name.to_string(),
        windows,
        last_updated: chrono::Utc::now().timestamp(),
        account_label: Some(account_label),
        menu_bar_metric: cfg.menu_bar_metric.clone(),
        ..Default::default()
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Hash)]
enum SemanticPool {
    Gemini,
    ClaudeGpt,
}

#[derive(Clone, Copy, PartialEq, Eq, Hash)]
enum SemanticInterval {
    FiveHour,
    Weekly,
}

impl SemanticPool {
    fn label(self) -> &'static str {
        match self {
            Self::Gemini => "Gemini",
            Self::ClaudeGpt => "Claude/GPT",
        }
    }
}

impl SemanticInterval {
    fn label(self) -> &'static str {
        match self {
            Self::FiveHour => "5-hour",
            Self::Weekly => "weekly",
        }
    }

    fn seconds(self) -> i64 {
        match self {
            Self::FiveHour => 18_000,
            Self::Weekly => 604_800,
        }
    }
}

#[derive(Clone)]
struct SemanticCandidate {
    pool: SemanticPool,
    interval: SemanticInterval,
    used_pct: i32,
    remaining_pct: i32,
    raw_remaining_fraction: f64,
    resets_at: Option<i64>,
    stable_label: String,
}

struct ModelQuota {
    label: String,
    model_id: String,
    remaining_fraction: Option<f64>,
    reset_time: Option<i64>,
}

fn ignored_marker(text: &str) -> bool {
    let lower = text.to_lowercase();
    lower.contains("image")
        || lower.contains("lite")
        || lower.contains("autocomplete")
        || lower.contains("unknown")
        || lower.contains("model_placeholder")
        || lower.contains("model-placeholder")
}

fn semantic_pool(text: &str) -> Option<SemanticPool> {
    let lower = text.to_lowercase();
    if lower.contains("gemini") {
        Some(SemanticPool::Gemini)
    } else if lower.contains("claude") || lower.contains("gpt") || lower.contains("openai") {
        Some(SemanticPool::ClaudeGpt)
    } else {
        None
    }
}

fn semantic_interval(text: &str) -> Option<SemanticInterval> {
    let lower = text.to_lowercase();
    if lower.contains("5h")
        || lower.contains("5-hour")
        || lower.contains("5 hour")
        || lower.contains("five hour")
    {
        Some(SemanticInterval::FiveHour)
    } else if lower.contains("weekly") || lower.contains("week") {
        Some(SemanticInterval::Weekly)
    } else {
        None
    }
}

fn semantic_candidate(
    marker: &str,
    remaining_fraction: Option<f64>,
    resets_at: Option<i64>,
    stable_label: impl Into<String>,
) -> Option<SemanticCandidate> {
    if ignored_marker(marker) {
        return None;
    }
    let fraction = remaining_fraction.filter(|value| value.is_finite())?;
    let pool = semantic_pool(marker)?;
    let interval = semantic_interval(marker)?;
    let remaining_pct = (fraction.clamp(0.0, 1.0) * 100.0).round() as i32;
    Some(SemanticCandidate {
        pool,
        interval,
        used_pct: 100 - remaining_pct,
        remaining_pct,
        raw_remaining_fraction: fraction,
        resets_at,
        stable_label: stable_label.into(),
    })
}

fn prefer_candidate(lhs: &SemanticCandidate, rhs: &SemanticCandidate) -> bool {
    if lhs.used_pct != rhs.used_pct {
        return lhs.used_pct > rhs.used_pct;
    }
    // Same rounded percentage: compare raw remaining_fraction (lower = more used = prefer)
    if (lhs.raw_remaining_fraction - rhs.raw_remaining_fraction).abs() > f64::EPSILON {
        return lhs.raw_remaining_fraction < rhs.raw_remaining_fraction;
    }
    // Equal raw usage: earlier reset wins
    match (lhs.resets_at, rhs.resets_at) {
        (Some(left), Some(right)) if left != right => return left < right,
        (Some(_), None) => return true,
        (None, Some(_)) => return false,
        _ => {}
    }
    lhs.stable_label.to_lowercase() < rhs.stable_label.to_lowercase()
}

fn semantic_label(pool: SemanticPool, interval: SemanticInterval) -> String {
    format!("{} {}", pool.label(), interval.label())
}

fn normalize_candidates(candidates: impl IntoIterator<Item = SemanticCandidate>) -> Vec<QuotaWindow> {
    let mut by_key: std::collections::HashMap<(SemanticPool, SemanticInterval), SemanticCandidate> =
        std::collections::HashMap::new();
    for candidate in candidates {
        let key = (candidate.pool, candidate.interval);
        match by_key.get(&key) {
            Some(existing) if !prefer_candidate(&candidate, existing) => {}
            _ => {
                by_key.insert(key, candidate);
            }
        }
    }

    let mut windows = Vec::with_capacity(4);
    for pool in [SemanticPool::Gemini, SemanticPool::ClaudeGpt] {
        for interval in [SemanticInterval::FiveHour, SemanticInterval::Weekly] {
            let Some(candidate) = by_key.get(&(pool, interval)) else {
                continue;
            };
            windows.push(QuotaWindow {
                semantic_key: Some(format!(
                    "antigravity-{}-{}",
                    pool.label().to_lowercase().replace('/', "-"),
                    interval.label()
                )),
                semantic_kind: Some("antigravity".to_string()),
                label: semantic_label(pool, interval),
                used_pct: candidate.used_pct,
                remaining_pct: candidate.remaining_pct,
                subtitle: None,
                resets_at: candidate.resets_at,
                window_seconds: Some(interval.seconds()),
            });
        }
    }
    windows
}

/// Pure: parse `GetUserStatus` JSON → (model quotas, email).
fn parse_user_status(json: &Value) -> Option<(Vec<ModelQuota>, Option<String>)> {
    if let Some(code) = json.get("code").and_then(Value::as_i64) {
        if code != 0 {
            return None;
        }
    }
    let user_status = json.get("userStatus")?;
    let email = user_status.get("email").and_then(Value::as_str).map(String::from);
    let configs = user_status
        .get("cascadeModelConfigData")
        .and_then(|v| v.get("clientModelConfigs"))
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let quotas = configs.iter().filter_map(parse_model_config).collect();
    Some((quotas, email))
}

fn parse_model_config(config: &Value) -> Option<ModelQuota> {
    let quota_info = config.get("quotaInfo")?;
    let label = config.get("label").and_then(Value::as_str).unwrap_or("").to_string();
    let model_id = config
        .get("modelOrAlias")
        .and_then(|m| m.get("model"))
        .and_then(Value::as_str)
        .map(String::from)
        .unwrap_or_else(|| label.clone());
    let remaining_fraction = quota_info.get("remainingFraction").and_then(Value::as_f64);
    let reset_time = quota_info.get("resetTime").and_then(parse_reset_value);
    Some(ModelQuota { label, model_id, remaining_fraction, reset_time })
}

fn parse_reset_time(s: &str) -> Option<i64> {
    chrono::DateTime::parse_from_rfc3339(s).ok().map(|d| d.timestamp()).or_else(|| s.parse::<f64>().ok().map(|t| t as i64))
}

/// Pure: normalize `GetUserStatus` model quotas to canonical semantic windows.
fn map_model_windows(quotas: &[ModelQuota]) -> Vec<QuotaWindow> {
    normalize_candidates(quotas.iter().filter_map(|quota| {
        let marker = format!("{} {}", quota.model_id, quota.label);
        semantic_candidate(
            &marker,
            quota.remaining_fraction,
            quota.reset_time,
            marker.clone(),
        )
    }))
}

/// Pure: parse `RetrieveUserQuotaSummary` JSON → group list.
fn parse_quota_summary(json: &Value) -> Option<Vec<Value>> {
    if let Some(code) = json.get("code").and_then(Value::as_i64) {
        if code != 0 {
            return None;
        }
    }
    let summary = json.get("quotaSummary").unwrap_or(json);
    Some(summary.get("groups").and_then(Value::as_array).cloned().unwrap_or_default())
}

/// Pure: map quota-summary groups to canonical semantic windows.
fn map_summary_windows(groups: &[Value]) -> Vec<QuotaWindow> {
    let mut candidates = Vec::new();
    for group in groups {
        let group_title = group
            .get("displayName")
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim();
        let group_description = group.get("description").and_then(Value::as_str).unwrap_or("");
        let Some(buckets) = group.get("buckets").and_then(Value::as_array) else {
            continue;
        };
        for bucket in buckets {
            if bucket.get("disabled").and_then(Value::as_bool) == Some(true) {
                continue;
            }
            let bucket_title = bucket
                .get("displayName")
                .and_then(Value::as_str)
                .unwrap_or("");
            let bucket_id = bucket.get("bucketId").and_then(Value::as_str).unwrap_or("");
            let reset_description = bucket
                .get("resetDescription")
                .and_then(Value::as_str)
                .unwrap_or("");
            let marker = format!(
                "{group_title} {group_description} {bucket_id} {bucket_title} {reset_description}"
            );
            let stable_label = format!("{group_title} {bucket_id} {bucket_title}");
            if let Some(candidate) = semantic_candidate(
                &marker,
                remaining_fraction(bucket),
                bucket.get("resetTime").and_then(parse_reset_value),
                stable_label,
            ) {
                candidates.push(candidate);
            }
        }
    }
    normalize_candidates(candidates)
}

fn remaining_fraction(value: &Value) -> Option<f64> {
    value
        .get("remainingFraction")
        .and_then(Value::as_f64)
        .or_else(|| {
            let remaining = value.get("remaining")?;
            remaining
                .get("remainingFraction")
                .and_then(Value::as_f64)
                .or_else(|| {
                    (remaining.get("case").and_then(Value::as_str) == Some("remainingFraction"))
                        .then(|| remaining.get("value").and_then(Value::as_f64))
                        .flatten()
                })
        })
}

fn parse_reset_value(value: &Value) -> Option<i64> {
    value
        .as_str()
        .and_then(parse_reset_time)
        .or_else(|| value.as_f64().map(|timestamp| timestamp as i64))
}

// MARK: - Google OAuth remote fallback (port of `AntigravityRemoteUsage` +
// the relevant slice of `AntigravityOAuthStore`).

#[derive(Deserialize, Default)]
struct OAuthAccount {
    label: String,
    #[serde(rename = "refreshToken")]
    refresh_token: String,
}

#[derive(Deserialize, Default)]
struct OAuthStore {
    #[serde(rename = "clientId")]
    client_id: Option<String>,
    #[serde(rename = "clientSecret")]
    client_secret: Option<String>,
    #[serde(rename = "activeLabel")]
    active_label: Option<String>,
    #[serde(default)]
    accounts: Vec<OAuthAccount>,
}

fn oauth_store_path() -> std::path::PathBuf {
    let home = std::env::var("HOME").unwrap_or_default();
    std::path::PathBuf::from(home).join(".config/birdnion/antigravity-oauth.json")
}

fn load_oauth_store() -> Option<OAuthStore> {
    let contents = std::fs::read_to_string(oauth_store_path()).ok()?;
    serde_json::from_str(&contents).ok()
}

/// Pure: active account is the one matching `activeLabel`, else the first.
fn active_account(store: &OAuthStore) -> Option<&OAuthAccount> {
    if let Some(label) = &store.active_label {
        if let Some(a) = store.accounts.iter().find(|a| &a.label == label) {
            return Some(a);
        }
    }
    store.accounts.first()
}

/// Resolves the OAuth client id: store file → env var. No installed-app-bundle
/// scan on Linux (macOS-only discovery step, intentionally not ported).
fn resolved_client_id(store: &OAuthStore) -> Option<String> {
    non_empty(store.client_id.as_deref()).or_else(|| non_empty(std::env::var("ANTIGRAVITY_OAUTH_CLIENT_ID").ok().as_deref()))
}

fn resolved_client_secret(store: &OAuthStore) -> Option<String> {
    non_empty(store.client_secret.as_deref()).or_else(|| non_empty(std::env::var("ANTIGRAVITY_OAUTH_CLIENT_SECRET").ok().as_deref()))
}

fn non_empty(s: Option<&str>) -> Option<String> {
    s.map(str::trim).filter(|s| !s.is_empty()).map(String::from)
}

/// Google OAuth remote path: uses the active stored account to fetch quota
/// from cloudcode-pa. Returns `None` when no account/credentials are
/// configured (so the fallback chain can end with the generic error), an
/// error status when the fetch itself fails.
async fn fetch_via_oauth(cfg: &config::Provider, name: &str) -> Option<ProviderStatus> {
    let store = load_oauth_store()?;
    let account = active_account(&store)?;
    let client_id = resolved_client_id(&store)?;
    let client_secret = resolved_client_secret(&store)?;

    let client = reqwest::Client::builder().timeout(Duration::from_secs(15)).build().ok()?;
    let access_token = match refresh_access_token(&client, &account.refresh_token, &client_id, &client_secret).await {
        Ok(t) => t,
        Err(e) => return Some(ProviderStatus::failure(&cfg.id, name, format!("Antigravity OAuth: {e}"))),
    };
    let windows = match fetch_quota_windows(&client, &access_token).await {
        Ok(w) => w,
        Err(e) => return Some(ProviderStatus::failure(&cfg.id, name, format!("Antigravity OAuth: {e}"))),
    };
    if windows.is_empty() {
        return Some(ProviderStatus::failure(&cfg.id, name, "Antigravity: không lấy được quota OAuth"));
    }

    let account_label = cfg.account_label.clone().unwrap_or_else(|| account.label.clone());
    Some(ProviderStatus {
        id: cfg.id.clone(),
        display_name: name.to_string(),
        windows,
        last_updated: chrono::Utc::now().timestamp(),
        account_label: Some(account_label),
        menu_bar_metric: cfg.menu_bar_metric.clone(),
        ..Default::default()
    })
}

async fn refresh_access_token(client: &reqwest::Client, refresh_token: &str, client_id: &str, client_secret: &str) -> Result<String, String> {
    let resp = client
        .post(OAUTH_TOKEN_URL)
        .header("Content-Type", "application/x-www-form-urlencoded")
        .form(&[("client_id", client_id), ("client_secret", client_secret), ("refresh_token", refresh_token), ("grant_type", "refresh_token")])
        .send()
        .await
        .map_err(|e| format!("Network: {e}"))?;
    if resp.status().as_u16() != 200 {
        return Err(format!("HTTP {}", resp.status().as_u16()));
    }
    let json: Value = resp.json().await.map_err(|e| format!("Invalid JSON: {e}"))?;
    json.get("access_token").and_then(Value::as_str).map(String::from).ok_or_else(|| "Không parse được access_token".to_string())
}

async fn fetch_quota_windows(client: &reqwest::Client, access_token: &str) -> Result<Vec<QuotaWindow>, String> {
    let resp = client
        .post(OAUTH_QUOTA_URL)
        .bearer_auth(access_token)
        .header("Content-Type", "application/json")
        .body("{}")
        .send()
        .await
        .map_err(|e| format!("Network: {e}"))?;
    match resp.status().as_u16() {
        200 => {}
        401 => return Err("Access token hết hạn (401)".to_string()),
        code => return Err(format!("HTTP {code}")),
    }
    let json: Value = resp.json().await.map_err(|e| format!("Invalid JSON: {e}"))?;
    let buckets = json.get("buckets").and_then(Value::as_array).cloned().unwrap_or_default();
    if buckets.is_empty() {
        return Err("Không có quota buckets trong response".to_string());
    }
    Ok(map_buckets_to_windows(&buckets))
}

/// Pure: normalize OAuth buckets to canonical semantic windows.
fn map_buckets_to_windows(buckets: &[Value]) -> Vec<QuotaWindow> {
    normalize_candidates(buckets.iter().filter_map(|bucket| {
        if bucket.get("disabled").and_then(Value::as_bool) == Some(true) {
            return None;
        }
        let model_id = bucket
            .get("modelId")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|id| !id.is_empty())?;
        let quota_type = bucket
            .get("quotaType")
            .and_then(Value::as_str)
            .map(str::trim)
            .unwrap_or("");
        // Marker chỉ dùng identity/model fields (modelId + quotaType) để pool.
        // KHÔNG dùng description/metadata khác — tránh custom-model bị phân loại sai
        // khi description chứa "Gemini"/"Claude"/"GPT".
        let marker = format!("{} {}", model_id, quota_type);
        semantic_candidate(
            &marker,
            remaining_fraction(bucket),
            bucket.get("resetTime").and_then(parse_reset_value),
            marker.clone(),
        )
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parses_language_server_process_with_csrf_token() {
        let output = "  1234 /opt/antigravity/language_server --csrf_token=abc123 --app_data_dir=/x\n";
        let info = parse_process_list(output).unwrap();
        assert_eq!(info.pid, 1234);
        assert_eq!(info.csrf_token, "abc123");
    }

    #[test]
    fn parses_agy_cli_process_without_token() {
        let output = "5678 agy serve\n";
        let info = parse_process_list(output).unwrap();
        assert_eq!(info.pid, 5678);
        assert_eq!(info.csrf_token, "");
    }

    #[test]
    fn no_antigravity_process_returns_none() {
        let output = "111 /usr/bin/zsh\n222 some-other-language-server --app_data_dir=/y\n";
        assert!(parse_process_list(output).is_none());
    }

    #[test]
    fn parses_listening_ports_from_lsof_output() {
        let output = "COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME\n\
                       language 1234 user   10u  IPv4 0x0      0t0      TCP 127.0.0.1:50123 (LISTEN)\n\
                       language 1234 user   11u  IPv4 0x0      0t0      TCP 127.0.0.1:50124 (LISTEN)\n";
        let ports = parse_listening_ports(output);
        assert_eq!(ports, vec![50123, 50124]);
    }

    #[test]
    fn empty_lsof_output_has_no_ports() {
        assert!(parse_listening_ports("").is_empty());
    }

    #[test]
    fn parses_user_status_with_model_configs() {
        let body = json!({
            "userStatus": {
                "email": "user@example.com",
                "cascadeModelConfigData": {
                    "clientModelConfigs": [
                        {"label": "claude 5-hour", "modelOrAlias": {"model": "claude-sonnet-4"}, "quotaInfo": {"remainingFraction": 0.75}},
                        {"label": "gemini weekly", "modelOrAlias": {"model": "gemini-flash"}, "quotaInfo": {"remainingFraction": 0.5}}
                    ]
                }
            }
        });
        let (quotas, email) = parse_user_status(&body).unwrap();
        assert_eq!(quotas.len(), 2);
        assert_eq!(email.as_deref(), Some("user@example.com"));
        let windows = map_model_windows(&quotas);
        assert_eq!(windows.iter().map(|w| w.label.as_str()).collect::<Vec<_>>(), vec!["Gemini weekly", "Claude/GPT 5-hour"]);
        assert_eq!(windows[0].remaining_pct, 50);
    }

    #[test]
    fn user_status_nonzero_code_is_none() {
        let body = json!({"code": 5, "message": "not found"});
        assert!(parse_user_status(&body).is_none());
    }

    #[test]
    fn image_lite_and_non_target_models_are_filtered_out() {
        let quotas = vec![
            ModelQuota { label: "image-gen 5h".into(), model_id: "image-model".into(), remaining_fraction: Some(1.0), reset_time: None },
            ModelQuota { label: "claude-lite 5h".into(), model_id: "claude-lite".into(), remaining_fraction: Some(1.0), reset_time: None },
            ModelQuota { label: "custom 5h".into(), model_id: "custom-model".into(), remaining_fraction: Some(1.0), reset_time: None },
            ModelQuota { label: "gpt 5h".into(), model_id: "gpt-5".into(), remaining_fraction: Some(0.9), reset_time: None },
        ];
        let windows = map_model_windows(&quotas);
        assert_eq!(windows.len(), 1);
        assert_eq!(windows[0].label, "Claude/GPT 5-hour");
    }

    #[test]
    fn unknown_placeholder_and_missing_fraction_are_filtered_out() {
        let quotas = vec![
            ModelQuota { label: "unknown 5h".into(), model_id: "unknown".into(), remaining_fraction: Some(0.1), reset_time: None },
            ModelQuota { label: "placeholder 5h".into(), model_id: "MODEL_PLACEHOLDER".into(), remaining_fraction: Some(0.1), reset_time: None },
            ModelQuota { label: "gemini 5h".into(), model_id: "gemini-pro".into(), remaining_fraction: None, reset_time: None },
        ];
        assert!(map_model_windows(&quotas).is_empty());
    }

    #[test]
    fn parses_quota_summary_groups_and_buckets() {
        let body = json!({
            "quotaSummary": {
                "groups": [
                    {"displayName": "Gemini", "description": "weekly quota", "buckets": [
                        {"displayName": "Weekly", "remainingFraction": 0.6},
                        {"displayName": "Disabled", "disabled": true, "remainingFraction": 0.1}
                    ]}
                ]
            }
        });
        let groups = parse_quota_summary(&body).unwrap();
        let windows = map_summary_windows(&groups);
        assert_eq!(windows.len(), 1);
        assert_eq!(windows[0].label, "Gemini weekly");
        assert_eq!(windows[0].remaining_pct, 60);
        assert_eq!(windows[0].window_seconds, Some(604_800));
    }

    #[test]
    fn quota_summary_nonzero_code_is_none() {
        let body = json!({"code": 3});
        assert!(parse_quota_summary(&body).is_none());
    }

    #[test]
    fn active_account_matches_active_label() {
        let store = OAuthStore {
            client_id: None,
            client_secret: None,
            active_label: Some("work".to_string()),
            accounts: vec![
                OAuthAccount { label: "personal".into(), refresh_token: "rt1".into() },
                OAuthAccount { label: "work".into(), refresh_token: "rt2".into() },
            ],
        };
        assert_eq!(active_account(&store).unwrap().refresh_token, "rt2");
    }

    #[test]
    fn active_account_falls_back_to_first_when_no_active_label() {
        let store = OAuthStore {
            client_id: None,
            client_secret: None,
            active_label: None,
            accounts: vec![OAuthAccount { label: "only".into(), refresh_token: "rt".into() }],
        };
        assert_eq!(active_account(&store).unwrap().label, "only");
    }

    #[test]
    fn resolved_client_id_prefers_store_over_env() {
        let store = OAuthStore { client_id: Some("store-id".into()), ..Default::default() };
        assert_eq!(resolved_client_id(&store).as_deref(), Some("store-id"));
    }

    #[test]
    fn resolved_client_secret_blank_falls_through() {
        let store = OAuthStore { client_secret: Some("   ".into()), ..Default::default() };
        assert!(resolved_client_secret(&store).is_none() || std::env::var("ANTIGRAVITY_OAUTH_CLIENT_SECRET").is_ok());
    }

    #[test]
    fn semantic_windows_use_canonical_order_and_cap_at_four() {
        let quotas = vec![
            ModelQuota { label: "claude weekly".into(), model_id: "claude".into(), remaining_fraction: Some(0.8), reset_time: None },
            ModelQuota { label: "gemini 5h".into(), model_id: "gemini".into(), remaining_fraction: Some(0.7), reset_time: None },
            ModelQuota { label: "gpt 5-hour".into(), model_id: "gpt".into(), remaining_fraction: Some(0.6), reset_time: None },
            ModelQuota { label: "gemini weekly".into(), model_id: "gemini".into(), remaining_fraction: Some(0.5), reset_time: None },
            ModelQuota { label: "claude 5h".into(), model_id: "claude".into(), remaining_fraction: Some(0.4), reset_time: None },
        ];
        let windows = map_model_windows(&quotas);
        assert_eq!(windows.len(), 4);
        assert_eq!(
            windows.iter().map(|w| w.label.as_str()).collect::<Vec<_>>(),
            vec!["Gemini 5-hour", "Gemini weekly", "Claude/GPT 5-hour", "Claude/GPT weekly"]
        );
    }

    #[test]
    fn duplicate_keeps_higher_usage_then_earlier_reset() {
        let quotas = vec![
            ModelQuota { label: "gemini 5h late".into(), model_id: "gemini".into(), remaining_fraction: Some(0.2), reset_time: Some(200) },
            ModelQuota { label: "gemini 5h early".into(), model_id: "gemini".into(), remaining_fraction: Some(0.2), reset_time: Some(100) },
            ModelQuota { label: "gemini 5h unused".into(), model_id: "gemini".into(), remaining_fraction: Some(0.9), reset_time: Some(50) },
        ];
        let windows = map_model_windows(&quotas);
        assert_eq!(windows.len(), 1);
        assert_eq!(windows[0].used_pct, 80);
        assert_eq!(windows[0].remaining_pct, 20);
        assert_eq!(windows[0].resets_at, Some(100));
    }

    #[test]
    fn known_interval_sets_duration_but_explicit_reset_wins() {
        let quotas = vec![
            ModelQuota { label: "gemini 5-hour".into(), model_id: "gemini".into(), remaining_fraction: Some(0.75), reset_time: Some(1_700_000_000) },
            ModelQuota { label: "claude weekly".into(), model_id: "claude".into(), remaining_fraction: Some(0.5), reset_time: None },
        ];
        let windows = map_model_windows(&quotas);
        assert_eq!(windows[0].resets_at, Some(1_700_000_000));
        assert_eq!(windows[0].window_seconds, Some(18_000));
        assert_eq!(windows[1].resets_at, None);
        assert_eq!(windows[1].window_seconds, Some(604_800));
    }

    #[test]
    fn maps_oauth_buckets_to_semantic_windows_and_filters_invalid_rows() {
        let buckets = json!([
            {"modelId": "gemini-pro", "quotaType": "5h", "remainingFraction": 0.8},
            {"modelId": "gemini-pro", "quotaType": "weekly", "remainingFraction": 0.6},
            {"modelId": "gemini-lite", "quotaType": "5h", "remainingFraction": 0.1},
            {"modelId": "MODEL_PLACEHOLDER", "quotaType": "5h", "remainingFraction": 0.1},
            {"modelId": "custom", "quotaType": "5h", "remainingFraction": 0.1}
        ]);
        let windows = map_buckets_to_windows(buckets.as_array().unwrap());
        assert_eq!(windows.iter().map(|w| w.label.as_str()).collect::<Vec<_>>(), vec!["Gemini 5-hour", "Gemini weekly"]);
        assert_eq!(windows[0].remaining_pct, 80);
    }

    #[test]
    fn unknown_interval_does_not_guess_duration_or_emit_row() {
        let buckets = json!([
            {"modelId": "gemini-pro", "remainingFraction": 0.8}
        ]);
        assert!(map_buckets_to_windows(buckets.as_array().unwrap()).is_empty());
    }

    #[test]
    fn oauth_custom_model_bucket_with_gemini_description_drops() {
        // Custom model bucket with "Gemini" in description should be dropped (not classified as Gemini pool)
        let buckets = json!([
            {"modelId": "custom-model-123", "quotaType": "5h", "remainingFraction": 0.5, "description": "Custom model with Gemini description"}
        ]);
        let windows = map_buckets_to_windows(buckets.as_array().unwrap());
        // Custom model without gemini/claude/gpt in modelId should be dropped
        assert!(windows.is_empty(), "Custom model with 'Gemini' in description should not be classified as Gemini pool");
    }

    #[test]
    fn duplicate_fraction_prefers_higher_raw_usage_then_earlier_reset() {
        // Two buckets with same rounded percentage (20% = 80% used), but different raw fractions
        // 0.201 remaining = 79.9% used → rounds to 20% remaining (80% used)
        // 0.204 remaining = 79.6% used → rounds to 20% remaining (80% used)
        // Should pick 0.201 (higher raw usage = lower remaining_fraction) even if its reset is later
        let buckets = json!([
            {"modelId": "gemini-pro", "quotaType": "5h", "remainingFraction": 0.204, "resetTime": "2026-07-30T10:00:00Z"},  // earlier reset, less used
            {"modelId": "gemini-pro", "quotaType": "5h", "remainingFraction": 0.201, "resetTime": "2026-07-30T12:00:00Z"}   // later reset, MORE used (0.201 < 0.204)
        ]);
        let windows = map_buckets_to_windows(buckets.as_array().unwrap());
        assert_eq!(windows.len(), 1);
        // Should pick the one with higher raw usage (0.201 remaining = more used)
        assert_eq!(windows[0].remaining_pct, 20);
        assert_eq!(windows[0].used_pct, 80);
        // And since raw usage differs, earlier reset should NOT win - higher raw usage wins
        // 0.201 resets at 12:00 (later), but it's more used so it wins
        assert_eq!(windows[0].resets_at, Some(1_785_412_800)); // 2026-07-30T12:00:00Z
    }

    #[test]
    fn duplicate_exact_raw_usage_prefers_earlier_reset() {
        // Same raw remaining_fraction, same rounded percentage - earlier reset should win
        let buckets = json!([
            {"modelId": "gemini-pro", "quotaType": "5h", "remainingFraction": 0.200, "resetTime": "2026-07-30T12:00:00Z"},
            {"modelId": "gemini-pro", "quotaType": "5h", "remainingFraction": 0.200, "resetTime": "2026-07-30T10:00:00Z"}  // earlier reset
        ]);
        let windows = map_buckets_to_windows(buckets.as_array().unwrap());
        assert_eq!(windows.len(), 1);
        assert_eq!(windows[0].remaining_pct, 20);
        assert_eq!(windows[0].used_pct, 80);
        // Equal raw usage → earlier reset wins
        assert_eq!(windows[0].resets_at, Some(1_785_405_600)); // 2026-07-30T10:00:00Z
    }
}
