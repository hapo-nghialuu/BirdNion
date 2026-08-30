//! GitHub Copilot Device Flow with an opaque frontend session contract.
//!
//! The webview receives only a random handle plus the user-facing code/URI.
//! The raw `device_code`, selected host, and eventual access token remain in
//! Rust. Each poll claims its session so concurrent/replayed polls cannot use
//! the same device code; pending sessions are restored, terminal ones vanish.

#[path = "copilot_accounts.rs"]
pub mod accounts;

use serde::Serialize;
use serde_json::Value;
use std::collections::HashMap;
use std::str::FromStr;
use std::sync::{LazyLock, Mutex};
use std::time::{Duration, Instant};

const CLIENT_ID: &str = "Iv1.b507a08c87ecfe98"; // VS Code public Client ID
const SCOPE: &str = "read:user";
const MAX_DEVICE_SESSION_SECONDS: i64 = 24 * 60 * 60;

#[derive(Clone)]
struct RawDeviceCode {
    user_code: String,
    verification_uri: String,
    device_code: String,
    interval: i64,
    expires_in: i64,
}

/// Secret-free response returned to the Tauri webview.
#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct DeviceCode {
    pub user_code: String,
    pub verification_uri: String,
    pub interval: i64,
    pub handle: String,
}

#[derive(Clone)]
struct DeviceSession {
    host: String,
    device_code: String,
    expires_at: Instant,
}

static DEVICE_SESSIONS: LazyLock<Mutex<HashMap<String, DeviceSession>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

fn parse_device_code(body: &str) -> Result<RawDeviceCode, String> {
    let v: Value = serde_json::from_str(body)
        .map_err(|_| "Phản hồi từ máy chủ không đúng định dạng.".to_string())?;
    let required = |field: &str| {
        v.get(field)
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty())
            .map(String::from)
            .ok_or_else(|| "Phản hồi từ máy chủ không đúng định dạng.".to_string())
    };
    let interval = v
        .get("interval")
        .and_then(Value::as_i64)
        .filter(|value| (1..=300).contains(value))
        .ok_or_else(|| "Phản hồi từ máy chủ không đúng định dạng.".to_string())?;
    let expires_in = v
        .get("expires_in")
        .and_then(Value::as_i64)
        .filter(|value| (1..=MAX_DEVICE_SESSION_SECONDS).contains(value))
        .ok_or_else(|| "Phản hồi từ máy chủ không đúng định dạng.".to_string())?;
    Ok(RawDeviceCode {
        user_code: required("user_code")?,
        verification_uri: required("verification_uri")?,
        device_code: required("device_code")?,
        interval,
        expires_in,
    })
}

fn validated_host(host: &str) -> Result<String, String> {
    let host = host.trim();
    if host.is_empty()
        || host.len() > 253
        || !host.is_ascii()
        || host.contains(['/', '\\', '@', ':', '?', '#', '%'])
        || host.chars().any(char::is_whitespace)
        || std::net::IpAddr::from_str(host).is_ok()
    {
        return Err("GitHub host không hợp lệ".to_string());
    }
    let host = host.to_ascii_lowercase();
    let labels: Vec<&str> = host.split('.').collect();
    if labels.len() < 2
        || labels.iter().any(|label| {
            label.is_empty()
                || label.len() > 63
                || label.starts_with('-')
                || label.ends_with('-')
                || !label
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        })
    {
        return Err("GitHub host không hợp lệ".to_string());
    }
    Ok(host)
}

fn validate_verification_uri(uri: &str, host: &str) -> Result<(), String> {
    let url = reqwest::Url::parse(uri)
        .map_err(|_| "Phản hồi từ máy chủ không đúng định dạng.".to_string())?;
    if url.scheme() != "https"
        || !url.username().is_empty()
        || url.password().is_some()
        || url.host_str() != Some(host)
    {
        return Err("Phản hồi từ máy chủ không đúng định dạng.".to_string());
    }
    Ok(())
}

fn random_handle() -> Result<String, String> {
    let mut bytes = [0_u8; 32];
    getrandom::getrandom(&mut bytes)
        .map_err(|_| "Không thể tạo phiên đăng nhập an toàn".to_string())?;
    Ok(hex::encode(bytes))
}

fn register_session(host: String, raw: RawDeviceCode) -> Result<DeviceCode, String> {
    validate_verification_uri(&raw.verification_uri, &host)?;
    let expires_at = Instant::now()
        .checked_add(Duration::from_secs(raw.expires_in as u64))
        .ok_or_else(|| "Phản hồi từ máy chủ không đúng định dạng.".to_string())?;
    let mut sessions = DEVICE_SESSIONS
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    sessions.retain(|_, session| session.expires_at > Instant::now());
    for _ in 0..8 {
        let handle = random_handle()?;
        if sessions.contains_key(&handle) {
            continue;
        }
        sessions.insert(
            handle.clone(),
            DeviceSession {
                host,
                device_code: raw.device_code,
                expires_at,
            },
        );
        return Ok(DeviceCode {
            user_code: raw.user_code,
            verification_uri: raw.verification_uri,
            interval: raw.interval,
            handle,
        });
    }
    Err("Không thể tạo phiên đăng nhập an toàn".to_string())
}

fn claim_session(handle: &str) -> Result<DeviceSession, String> {
    let mut sessions = DEVICE_SESSIONS
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    sessions.retain(|_, session| session.expires_at > Instant::now());
    sessions
        .remove(handle.trim())
        .ok_or_else(|| "Phiên đăng nhập không hợp lệ hoặc đã hết hạn".to_string())
}

fn restore_session(handle: &str, session: DeviceSession) -> bool {
    if session.expires_at <= Instant::now() {
        return false;
    }
    let mut sessions = DEVICE_SESSIONS
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    sessions.entry(handle.to_string()).or_insert(session);
    true
}

fn schedule_expiry_cleanup(handle: String, expires_in: Duration) {
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(expires_in).await;
        let mut sessions = DEVICE_SESSIONS
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if sessions
            .get(&handle)
            .is_some_and(|session| session.expires_at <= Instant::now())
        {
            sessions.remove(&handle);
        }
    });
}

pub async fn start(host: &str) -> Result<DeviceCode, String> {
    let host = validated_host(host)?;
    let client = reqwest::Client::new();
    let resp = client
        .post(format!("https://{host}/login/device/code"))
        .header("Accept", "application/json")
        .form(&[("client_id", CLIENT_ID), ("scope", SCOPE)])
        .send()
        .await
        .map_err(|error| format!("Network: {error}"))?;
    if !resp.status().is_success() {
        return Err(format!(
            "Máy chủ trả về lỗi HTTP {}.",
            resp.status().as_u16()
        ));
    }
    let body = resp
        .text()
        .await
        .map_err(|error| format!("Network: {error}"))?;
    let raw = parse_device_code(&body)?;
    let expires_in = Duration::from_secs(raw.expires_in as u64);
    let public = register_session(host, raw)?;
    schedule_expiry_cleanup(public.handle.clone(), expires_in);
    Ok(public)
}

#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum PollResult {
    Pending,
    SlowDown,
    Success { label: String },
    Denied,
    Expired,
}

enum RawPollOutcome {
    Pending,
    SlowDown,
    Success(String),
    Denied,
    Expired,
    Unexpected,
}

fn parse_poll_response(body: &str) -> RawPollOutcome {
    let Ok(v) = serde_json::from_str::<Value>(body) else {
        return RawPollOutcome::Unexpected;
    };
    if let Some(error) = v.get("error").and_then(Value::as_str) {
        return match error {
            "authorization_pending" => RawPollOutcome::Pending,
            "slow_down" => RawPollOutcome::SlowDown,
            "expired_token" => RawPollOutcome::Expired,
            "access_denied" => RawPollOutcome::Denied,
            _ => RawPollOutcome::Unexpected,
        };
    }
    match v.get("access_token").and_then(Value::as_str) {
        Some(token) if !token.trim().is_empty() => RawPollOutcome::Success(token.to_string()),
        _ => RawPollOutcome::Unexpected,
    }
}

async fn fetch_login(client: &reqwest::Client, host: &str, token: &str) -> Option<String> {
    let api_host = if host == "github.com" {
        "api.github.com".to_string()
    } else {
        format!("api.{host}")
    };
    let resp = client
        .get(format!("https://{api_host}/user"))
        .header("Authorization", format!("token {token}"))
        .header("Accept", "application/json")
        .header("User-Agent", "BirdNion/1.0")
        .send()
        .await
        .ok()?;
    if !resp.status().is_success() {
        return None;
    }
    let v: Value = resp.json().await.ok()?;
    v.get("login")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|login| !login.is_empty())
        .map(String::from)
}

/// Polls one opaque session. Pending/slow-down and transport failures remain
/// retryable; every terminal response consumes the handle before processing.
pub async fn poll(handle: &str) -> Result<PollResult, String> {
    let session = claim_session(handle)?;
    let client = reqwest::Client::new();
    let response = client
        .post(format!("https://{}/login/oauth/access_token", session.host))
        .header("Accept", "application/json")
        .form(&[
            ("client_id", CLIENT_ID),
            ("device_code", session.device_code.as_str()),
            ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
        ])
        .send()
        .await;

    let response = match response {
        Ok(response) => response,
        Err(error) => {
            restore_session(handle.trim(), session);
            return Err(format!("Network: {error}"));
        }
    };
    if !response.status().is_success() {
        let status = response.status().as_u16();
        restore_session(handle.trim(), session);
        return Err(format!("Máy chủ trả về lỗi HTTP {status}."));
    }
    let body = match response.text().await {
        Ok(body) => body,
        Err(error) => {
            restore_session(handle.trim(), session);
            return Err(format!("Network: {error}"));
        }
    };

    match parse_poll_response(&body) {
        RawPollOutcome::Pending => {
            if restore_session(handle.trim(), session) {
                Ok(PollResult::Pending)
            } else {
                Ok(PollResult::Expired)
            }
        }
        RawPollOutcome::SlowDown => {
            if restore_session(handle.trim(), session) {
                Ok(PollResult::SlowDown)
            } else {
                Ok(PollResult::Expired)
            }
        }
        RawPollOutcome::Expired => Ok(PollResult::Expired),
        RawPollOutcome::Denied => Ok(PollResult::Denied),
        RawPollOutcome::Unexpected => Err("Phản hồi từ máy chủ không đúng định dạng.".to_string()),
        RawPollOutcome::Success(token) => {
            let login = fetch_login(&client, &session.host, &token).await;
            let label = login.as_deref().unwrap_or(accounts::GENERIC_ACCOUNT_LABEL);
            let state = accounts::save_login_account(label, login.as_deref(), &token)?;
            Ok(PollResult::Success {
                label: state
                    .active_label
                    .unwrap_or_else(|| accounts::GENERIC_ACCOUNT_LABEL.to_string()),
            })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn raw_device_code(device_code: &str) -> RawDeviceCode {
        RawDeviceCode {
            user_code: "ABCD-1234".to_string(),
            verification_uri: "https://github.com/login/device".to_string(),
            device_code: device_code.to_string(),
            interval: 5,
            expires_in: 900,
        }
    }

    #[test]
    fn parses_device_code_response() {
        let body = r#"{"device_code":"dc","user_code":"ABCD-1234","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#;
        let code = parse_device_code(body).unwrap();
        assert_eq!(code.user_code, "ABCD-1234");
        assert_eq!(code.device_code, "dc");
        assert_eq!(code.interval, 5);
        assert_eq!(code.expires_in, 900);
    }

    #[test]
    fn malformed_device_code_response_errors() {
        assert!(parse_device_code("not json").is_err());
        assert!(parse_device_code(r#"{"device_code":"dc"}"#).is_err());
        assert!(parse_device_code(r#"{"device_code":"dc","user_code":"u","verification_uri":"https://github.com/login/device","expires_in":900,"interval":0}"#).is_err());
    }

    #[test]
    fn validates_github_and_enterprise_hosts() {
        assert_eq!(validated_host("github.com").unwrap(), "github.com");
        assert_eq!(
            validated_host("GitHub.Example-Corp.com").unwrap(),
            "github.example-corp.com"
        );
        for host in [
            "https://github.com",
            "user@github.com",
            "github.com/login/device",
            "github.com:443",
            "127.0.0.1",
            "localhost",
            "github..com",
        ] {
            assert!(validated_host(host).is_err(), "accepted unsafe host {host}");
        }
    }

    #[test]
    fn device_session_is_opaque_and_single_claim() {
        let raw = "raw-device-code-must-stay-in-rust";
        let public = register_session("github.com".to_string(), raw_device_code(raw)).unwrap();
        let json = serde_json::to_string(&public).unwrap();
        assert!(!json.contains(raw));
        assert!(!json.contains("deviceCode"));
        assert_eq!(public.handle.len(), 64);

        let session = claim_session(&public.handle).unwrap();
        assert_eq!(session.device_code, raw);
        assert!(claim_session(&public.handle).is_err());
    }

    #[test]
    fn poll_response_pending_slow_down_and_terminal_states() {
        assert!(matches!(
            parse_poll_response(r#"{"error":"authorization_pending"}"#),
            RawPollOutcome::Pending
        ));
        assert!(matches!(
            parse_poll_response(r#"{"error":"slow_down"}"#),
            RawPollOutcome::SlowDown
        ));
        assert!(matches!(
            parse_poll_response(r#"{"error":"access_denied"}"#),
            RawPollOutcome::Denied
        ));
        assert!(matches!(
            parse_poll_response(r#"{"error":"expired_token"}"#),
            RawPollOutcome::Expired
        ));
    }

    #[test]
    fn poll_response_success_extracts_token_without_serializing_it() {
        match parse_poll_response(r#"{"access_token":"ghu_abc123","token_type":"bearer"}"#) {
            RawPollOutcome::Success(token) => assert_eq!(token, "ghu_abc123"),
            _ => panic!("expected success"),
        }
        assert!(matches!(
            parse_poll_response(r#"{"foo":"bar"}"#),
            RawPollOutcome::Unexpected
        ));
    }
}
