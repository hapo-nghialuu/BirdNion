//! GitHub Copilot Device Flow login — port of `CopilotOAuth.swift`'s
//! `CopilotDeviceFlow` + `CopilotAccountStore`. Writes the resulting account
//! into `~/.config/birdnion/copilot-accounts.json` in the exact JSON shape
//! macOS's Device Flow login writes (read back by `providers::copilot`).
//!
//! Flow: POST `login/device/code` → {user_code, verification_uri, device_code,
//! interval}; the JS side drives the poll loop (a single `login_poll` call per
//! tick, respecting `interval`/`slow_down`) against `login/oauth/access_token`
//! until the user approves, denies, or the code expires.

use serde::{Deserialize, Serialize};
use serde_json::Value;

const CLIENT_ID: &str = "Iv1.b507a08c87ecfe98"; // VS Code public Client ID
const SCOPE: &str = "read:user";

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct DeviceCode {
    pub user_code: String,
    pub verification_uri: String,
    pub device_code: String,
    pub interval: i64,
}

/// Pure parse of the `login/device/code` JSON response.
fn parse_device_code(body: &str) -> Result<DeviceCode, String> {
    let v: Value = serde_json::from_str(body).map_err(|_| "Phản hồi từ máy chủ không đúng định dạng.".to_string())?;
    let user_code = v.get("user_code").and_then(Value::as_str).ok_or("Phản hồi từ máy chủ không đúng định dạng.")?;
    let verification_uri = v.get("verification_uri").and_then(Value::as_str).ok_or("Phản hồi từ máy chủ không đúng định dạng.")?;
    let device_code = v.get("device_code").and_then(Value::as_str).ok_or("Phản hồi từ máy chủ không đúng định dạng.")?;
    let interval = v.get("interval").and_then(Value::as_i64).ok_or("Phản hồi từ máy chủ không đúng định dạng.")?;
    Ok(DeviceCode {
        user_code: user_code.to_string(),
        verification_uri: verification_uri.to_string(),
        device_code: device_code.to_string(),
        interval,
    })
}

pub async fn start(host: &str) -> Result<DeviceCode, String> {
    let client = reqwest::Client::new();
    let url = format!("https://{host}/login/device/code");
    let resp = client
        .post(&url)
        .header("Accept", "application/json")
        .form(&[("client_id", CLIENT_ID), ("scope", SCOPE)])
        .send()
        .await
        .map_err(|e| format!("Network: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("Máy chủ trả về lỗi HTTP {}.", resp.status().as_u16()));
    }
    let body = resp.text().await.map_err(|e| format!("Network: {e}"))?;
    parse_device_code(&body)
}

/// One poll tick's classification — distinct outcomes so the JS retry loop
/// can decide what to do next instead of treating everything as an error.
#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum PollResult {
    /// User hasn't approved yet — caller should wait `interval` seconds and
    /// poll again.
    Pending,
    /// GitHub asked for a longer interval — caller should add 5s and retry.
    SlowDown,
    /// Login succeeded; account was persisted. `label` is the saved account
    /// label (GitHub login, or a token fragment when `/user` lookup failed).
    Success { label: String },
    /// User denied the request on GitHub's device page.
    Denied,
    /// The device code expired before the user approved.
    Expired,
}

/// Pure parse of one `login/oauth/access_token` poll response body into a
/// (non-persisting) classification. `Success` here carries the raw token —
/// `poll` wraps this with the account-save side effect.
enum RawPollOutcome {
    Pending,
    SlowDown,
    Success(String),
    Denied,
    Expired,
    Unexpected,
}

fn parse_poll_response(body: &str) -> RawPollOutcome {
    let Ok(v) = serde_json::from_str::<Value>(body) else { return RawPollOutcome::Unexpected };
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
        Some(token) if !token.is_empty() => RawPollOutcome::Success(token.to_string()),
        _ => RawPollOutcome::Unexpected,
    }
}

async fn fetch_login(client: &reqwest::Client, host: &str, token: &str) -> Option<String> {
    let api_host = if host == "github.com" { "api.github.com".to_string() } else { format!("api.{host}") };
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
    v.get("login").and_then(Value::as_str).map(String::from)
}

/// Single poll tick against `login/oauth/access_token`. On success, persists
/// the account to copilot-accounts.json before returning `Success`. The
/// caller (JS) owns the retry loop: sleep `interval` (or +5s on `SlowDown`)
/// between calls, stop on `Success`/`Denied`/`Expired`.
pub async fn poll(host: &str, device_code: &str) -> Result<PollResult, String> {
    let client = reqwest::Client::new();
    let url = format!("https://{host}/login/oauth/access_token");
    let resp = client
        .post(&url)
        .header("Accept", "application/json")
        .form(&[
            ("client_id", CLIENT_ID),
            ("device_code", device_code),
            ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
        ])
        .send()
        .await
        .map_err(|e| format!("Network: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("Máy chủ trả về lỗi HTTP {}.", resp.status().as_u16()));
    }
    let body = resp.text().await.map_err(|e| format!("Network: {e}"))?;

    match parse_poll_response(&body) {
        RawPollOutcome::Pending => Ok(PollResult::Pending),
        RawPollOutcome::SlowDown => Ok(PollResult::SlowDown),
        RawPollOutcome::Expired => Ok(PollResult::Expired),
        RawPollOutcome::Denied => Ok(PollResult::Denied),
        RawPollOutcome::Unexpected => Err("Phản hồi từ máy chủ không đúng định dạng.".to_string()),
        RawPollOutcome::Success(token) => {
            let login = fetch_login(&client, host, &token).await;
            let label = login.clone().unwrap_or_else(|| token.chars().take(8).collect());
            save_account(&label, login.as_deref(), &token)?;
            Ok(PollResult::Success { label })
        }
    }
}

#[derive(Deserialize, Serialize, Default)]
struct AccountEntry {
    label: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    login: Option<String>,
    token: String,
}

#[derive(Deserialize, Serialize, Default)]
struct AccountStore {
    #[serde(rename = "activeLabel", skip_serializing_if = "Option::is_none")]
    active_label: Option<String>,
    #[serde(default)]
    accounts: Vec<AccountEntry>,
}

fn copilot_accounts_path() -> std::path::PathBuf {
    let home = std::env::var("HOME").unwrap_or_default();
    std::path::PathBuf::from(home).join(".config/birdnion/copilot-accounts.json")
}

/// Adds/updates the account by label and persists (0600), same shape as the
/// Swift `CopilotAccountStore.addAccount` + `save`.
fn save_account(label: &str, login: Option<&str>, token: &str) -> Result<(), String> {
    let path = copilot_accounts_path();
    let mut store: AccountStore = std::fs::read_to_string(&path)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default();
    merge_account(&mut store, label, login, token);

    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    let json = serde_json::to_string_pretty(&store).map_err(|e| e.to_string())?;
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, json).map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600));
    }
    std::fs::rename(&tmp, &path).map_err(|e| e.to_string())
}

/// Pure store mutation (unit-tested): add-or-update by label, default the
/// active label to the first-ever account — mirrors
/// `CopilotAccountStore.addAccount` (Swift updates in place; active label is
/// set by the caller there, but the Linux login flow always wants the newly
/// logged-in account made active on first login).
fn merge_account(store: &mut AccountStore, label: &str, login: Option<&str>, token: &str) {
    if let Some(existing) = store.accounts.iter_mut().find(|a| a.label == label) {
        existing.token = token.to_string();
        existing.login = login.map(String::from);
    } else {
        store.accounts.push(AccountEntry { label: label.to_string(), login: login.map(String::from), token: token.to_string() });
    }
    if store.active_label.is_none() {
        store.active_label = Some(label.to_string());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_device_code_response() {
        let body = r#"{"device_code":"dc","user_code":"ABCD-1234","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#;
        let dc = parse_device_code(body).unwrap();
        assert_eq!(dc.user_code, "ABCD-1234");
        assert_eq!(dc.device_code, "dc");
        assert_eq!(dc.interval, 5);
    }

    #[test]
    fn malformed_device_code_response_errors() {
        assert!(parse_device_code("not json").is_err());
        assert!(parse_device_code(r#"{"device_code":"dc"}"#).is_err());
    }

    #[test]
    fn poll_response_pending_and_slow_down() {
        assert!(matches!(parse_poll_response(r#"{"error":"authorization_pending"}"#), RawPollOutcome::Pending));
        assert!(matches!(parse_poll_response(r#"{"error":"slow_down"}"#), RawPollOutcome::SlowDown));
    }

    #[test]
    fn poll_response_denied_and_expired() {
        assert!(matches!(parse_poll_response(r#"{"error":"access_denied"}"#), RawPollOutcome::Denied));
        assert!(matches!(parse_poll_response(r#"{"error":"expired_token"}"#), RawPollOutcome::Expired));
    }

    #[test]
    fn poll_response_success_extracts_token() {
        match parse_poll_response(r#"{"access_token":"ghu_abc123","token_type":"bearer"}"#) {
            RawPollOutcome::Success(t) => assert_eq!(t, "ghu_abc123"),
            _ => panic!("expected success"),
        }
    }

    #[test]
    fn poll_response_unexpected_shape() {
        assert!(matches!(parse_poll_response("not json"), RawPollOutcome::Unexpected));
        assert!(matches!(parse_poll_response(r#"{"foo":"bar"}"#), RawPollOutcome::Unexpected));
    }

    #[test]
    fn merge_account_adds_new_and_sets_active_label() {
        let mut store = AccountStore::default();
        merge_account(&mut store, "octocat", Some("octocat"), "ghu_1");
        assert_eq!(store.accounts.len(), 1);
        assert_eq!(store.active_label.as_deref(), Some("octocat"));
        assert_eq!(store.accounts[0].token, "ghu_1");
    }

    #[test]
    fn merge_account_updates_existing_by_label_without_touching_active_label() {
        let mut store = AccountStore { active_label: Some("other".into()), accounts: vec![AccountEntry { label: "octocat".into(), login: Some("octocat".into()), token: "old".into() }] };
        merge_account(&mut store, "octocat", Some("octocat"), "new");
        assert_eq!(store.accounts.len(), 1);
        assert_eq!(store.accounts[0].token, "new");
        assert_eq!(store.active_label.as_deref(), Some("other"));
    }
}
