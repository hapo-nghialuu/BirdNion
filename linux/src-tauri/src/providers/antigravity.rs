//! Antigravity IDE local-server quota provider — port of `AntigravityProvider.swift`.
//!
//! Detection approach (portable POSIX, matches Swift):
//!   1. `ps -ax -o pid=,command=` to find a running `language_server` or `agy` process.
//!   2. Extract `--csrf_token` from the command line.
//!   3. `lsof -nP -iTCP -sTCP:LISTEN -a -p <pid>` for listening ports.
//!   4. POST Connect/JSON (Content-Type: application/json, Connect-Protocol-Version: 1,
//!      X-Codeium-Csrf-Token when non-empty) to the local language server.
//!
//! Scope note: only the running-process probe is ported (Swift's `auto` mode
//! step 1). The `agy` CLI warm-spawn fallback and the Google OAuth remote
//! fallback are Swift "best-effort" extras layered on top of this core path
//! and are skipped here (YAGNI) — a missing IDE process yields the same
//! "no server found" error message class as Swift's `notRunning` case.

use std::process::{Command, Stdio};
use std::time::Duration;

use serde_json::Value;

use crate::config;
use crate::providers::{display_name, ProviderStatus, QuotaWindow};

const QUOTA_SUMMARY_PATH: &str = "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary";
const USER_STATUS_PATH: &str = "/exa.language_server_pb.LanguageServerService/GetUserStatus";
const PROBE_TIMEOUT: Duration = Duration::from_secs(8);

struct ProcessInfo {
    pid: i32,
    csrf_token: String,
}

pub async fn fetch(cfg: &config::Provider) -> ProviderStatus {
    let name = display_name(cfg);

    // ps/lsof are blocking subprocess calls; run them off the async executor.
    let process = match tauri::async_runtime::spawn_blocking(detect_process).await {
        Ok(Ok(p)) => p,
        _ => return ProviderStatus::failure(&cfg.id, &name, "Antigravity: cần IDE đang chạy"),
    };

    let pid = process.pid;
    let ports = match tauri::async_runtime::spawn_blocking(move || listening_ports(pid)).await {
        Ok(Ok(p)) if !p.is_empty() => p,
        _ => return ProviderStatus::failure(&cfg.id, &name, "Antigravity: cần IDE đang chạy"),
    };

    for port in ports {
        if let Some(status) = try_summary_endpoint(cfg, &name, &process, port).await {
            return status;
        }
        if let Some(status) = try_user_status_endpoint(cfg, &name, &process, port).await {
            return status;
        }
    }

    ProviderStatus::failure(&cfg.id, &name, "Antigravity: cần IDE đang chạy")
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
        error: None,
        account_label: Some(account_label),
        credits_remaining: None,
    }
}

struct ModelQuota {
    label: String,
    model_id: String,
    remaining_fraction: Option<f64>,
    reset_time: Option<i64>,
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
    let reset_time = quota_info.get("resetTime").and_then(Value::as_str).and_then(parse_reset_time);
    Some(ModelQuota { label, model_id, remaining_fraction, reset_time })
}

fn parse_reset_time(s: &str) -> Option<i64> {
    chrono::DateTime::parse_from_rfc3339(s).ok().map(|d| d.timestamp()).or_else(|| s.parse::<f64>().ok().map(|t| t as i64))
}

/// Pure: filter text models, sort by family (Claude > GPT > Gemini Pro > Gemini
/// Flash > other), map to QuotaWindow.
fn map_model_windows(quotas: &[ModelQuota]) -> Vec<QuotaWindow> {
    let mut text_models: Vec<&ModelQuota> = quotas
        .iter()
        .filter(|q| {
            let lower = format!("{} {}", q.model_id, q.label).to_lowercase();
            !lower.contains("image") && !lower.contains("lite") && !lower.contains("autocomplete")
        })
        .collect();
    text_models.sort_by_key(|q| family_rank(q));
    text_models
        .into_iter()
        .map(|q| {
            let fraction = q.remaining_fraction.unwrap_or(0.0).clamp(0.0, 1.0);
            let remaining_pct = (fraction * 100.0).round() as i32;
            let id = if q.model_id.is_empty() { &q.label } else { &q.model_id };
            QuotaWindow {
                label: humanize_model_id(id),
                used_pct: 100 - remaining_pct,
                remaining_pct,
                subtitle: None,
                resets_at: q.reset_time,
            }
        })
        .collect()
}

fn family_rank(q: &ModelQuota) -> i32 {
    let lower = format!("{} {}", q.model_id, q.label).to_lowercase();
    if lower.contains("claude") {
        0
    } else if lower.contains("gpt") || lower.contains("openai") {
        1
    } else if lower.contains("gemini") && lower.contains("pro") {
        2
    } else if lower.contains("gemini") && lower.contains("flash") {
        3
    } else {
        4
    }
}

fn humanize_model_id(id: &str) -> String {
    id.split('-')
        .map(|part| {
            let mut chars = part.chars();
            match chars.next() {
                Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
                None => String::new(),
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
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

/// Pure: map quota-summary groups → QuotaWindow list.
fn map_summary_windows(groups: &[Value]) -> Vec<QuotaWindow> {
    let mut windows = Vec::new();
    for group in groups {
        let group_title = group.get("displayName").and_then(Value::as_str).unwrap_or("Quota").trim().to_string();
        let buckets = group.get("buckets").and_then(Value::as_array).cloned().unwrap_or_default();
        for bucket in &buckets {
            if bucket.get("disabled").and_then(Value::as_bool) == Some(true) {
                continue;
            }
            let bucket_title = bucket.get("displayName").and_then(Value::as_str).unwrap_or("");
            let remaining_fraction = bucket.get("remainingFraction").and_then(Value::as_f64);
            let remaining_pct = remaining_fraction.map(|f| (f.clamp(0.0, 1.0) * 100.0).round() as i32).unwrap_or(0);
            let reset_time = bucket.get("resetTime").and_then(Value::as_str).and_then(parse_reset_time);
            let label = format!("{group_title} {bucket_title}").trim().to_string();
            windows.push(QuotaWindow {
                label,
                used_pct: 100 - remaining_pct,
                remaining_pct,
                subtitle: None,
                resets_at: reset_time,
            });
        }
    }
    windows
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
                        {"label": "claude-sonnet", "modelOrAlias": {"model": "claude-sonnet-4"}, "quotaInfo": {"remainingFraction": 0.75}},
                        {"label": "gemini-flash", "modelOrAlias": {"model": "gemini-flash"}, "quotaInfo": {"remainingFraction": 0.5}}
                    ]
                }
            }
        });
        let (quotas, email) = parse_user_status(&body).unwrap();
        assert_eq!(quotas.len(), 2);
        assert_eq!(email.as_deref(), Some("user@example.com"));
        let windows = map_model_windows(&quotas);
        assert_eq!(windows[0].label, "Claude Sonnet 4");
        assert_eq!(windows[0].remaining_pct, 75);
    }

    #[test]
    fn user_status_nonzero_code_is_none() {
        let body = json!({"code": 5, "message": "not found"});
        assert!(parse_user_status(&body).is_none());
    }

    #[test]
    fn image_and_lite_models_are_filtered_out() {
        let quotas = vec![
            ModelQuota { label: "image-gen".into(), model_id: "image-model".into(), remaining_fraction: Some(1.0), reset_time: None },
            ModelQuota { label: "claude-lite".into(), model_id: "claude-lite".into(), remaining_fraction: Some(1.0), reset_time: None },
            ModelQuota { label: "gpt-5".into(), model_id: "gpt-5".into(), remaining_fraction: Some(0.9), reset_time: None },
        ];
        let windows = map_model_windows(&quotas);
        assert_eq!(windows.len(), 1);
        assert_eq!(windows[0].label, "Gpt 5");
    }

    #[test]
    fn parses_quota_summary_groups_and_buckets() {
        let body = json!({
            "quotaSummary": {
                "groups": [
                    {"displayName": "Models", "buckets": [
                        {"displayName": "Claude", "remainingFraction": 0.6},
                        {"displayName": "Disabled", "disabled": true, "remainingFraction": 0.1}
                    ]}
                ]
            }
        });
        let groups = parse_quota_summary(&body).unwrap();
        let windows = map_summary_windows(&groups);
        assert_eq!(windows.len(), 1);
        assert_eq!(windows[0].label, "Models Claude");
        assert_eq!(windows[0].remaining_pct, 60);
    }

    #[test]
    fn quota_summary_nonzero_code_is_none() {
        let body = json!({"code": 3});
        assert!(parse_quota_summary(&body).is_none());
    }
}
