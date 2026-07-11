//! Codex multi-account store — port of `CodexAccountStore.swift`. Mirrors the
//! macOS design: the `system` account is the read-only `~/.codex` login (or
//! `$CODEX_HOME` if set); each *managed* account gets its own private home
//! directory holding a copied `auth.json`, so switching accounts never
//! touches the system login. The active account id is persisted in
//! `settings.json` (`activeCodexAccount`) — the Linux equivalent of macOS's
//! `UserDefaults` key of the same name, since there is no UserDefaults here.
//!
//! Layout (under the app's config-support directory, sibling to
//! `settings.json`): `codex-accounts.json` (metadata) + `codex-accounts/<uuid>/`
//! (one `auth.json` per managed account). Same relative names as macOS's
//! `~/Library/Application Support/BirdNion/` tree, adapted to
//! `~/.config/birdnion/` — the two platforms don't share this feature's on-disk
//! account files (single-user local machine data, not meant to roam), but do
//! share the exact same `settings.json` schema/keys.
//!
//! `codex login` (interactive OAuth in a browser) is not spawned here — CLI
//! login flows are out of scope for this port. "Lưu account hiện tại" (save
//! current account) instead promotes the current system login into a new
//! managed account by copying `auth.json`, mirroring `promoteSystem()`.

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

use crate::config;

pub const SYSTEM_ID: &str = "system";

#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CodexAccount {
    pub id: String,
    pub email: Option<String>,
    pub is_system: bool,
    pub home_path: Option<String>,
}

#[derive(Deserialize, Serialize, Clone, Debug, Default)]
struct Entry {
    id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    email: Option<String>,
    home_path: String,
}

#[derive(Deserialize, Serialize, Clone, Debug, Default)]
struct Stored {
    #[serde(default)]
    accounts: Vec<Entry>,
}

fn support_dir() -> PathBuf {
    // Sibling of settings.json (same directory config::config_path() resolves
    // its parent to), keeping every BirdNion app-state file under one root.
    config::config_path()
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_else(|| PathBuf::from("."))
}

fn accounts_root_dir() -> PathBuf {
    support_dir().join("codex-accounts")
}

fn metadata_path() -> PathBuf {
    support_dir().join("codex-accounts.json")
}

pub fn home_dir_for_account(id: &str) -> PathBuf {
    accounts_root_dir().join(id)
}

pub fn system_auth_path() -> PathBuf {
    let codex_home = std::env::var("CODEX_HOME").ok().filter(|s| !s.trim().is_empty());
    match codex_home {
        Some(h) => PathBuf::from(h).join("auth.json"),
        None => PathBuf::from(std::env::var("HOME").unwrap_or_default())
            .join(".codex")
            .join("auth.json"),
    }
}

/// Active account id, persisted in settings.json. Defaults to `"system"`.
pub fn active_id() -> String {
    config::load().active_codex_account.unwrap_or_else(|| SYSTEM_ID.to_string())
}

pub fn set_active(id: &str) -> Result<(), String> {
    let mut settings = config::load();
    settings.active_codex_account = Some(id.to_string());
    config::save(&settings)
}

/// The auth.json path the Codex provider should read for the active account —
/// mirrors `activeAuthURL()`: falls back to the system login when the active
/// managed account no longer exists.
pub fn active_auth_path() -> PathBuf {
    let id = active_id();
    if id == SYSTEM_ID {
        return system_auth_path();
    }
    match managed_accounts().into_iter().find(|a| a.id == id) {
        Some(account) => match account.home_path {
            Some(home) => PathBuf::from(home).join("auth.json"),
            None => system_auth_path(),
        },
        None => system_auth_path(),
    }
}

fn load_stored() -> Stored {
    std::fs::read_to_string(metadata_path())
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

fn persist(entries: &[Entry]) -> Result<(), String> {
    let dir = support_dir();
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let stored = Stored { accounts: entries.to_vec() };
    let json = serde_json::to_string_pretty(&stored).map_err(|e| e.to_string())?;
    std::fs::write(metadata_path(), json).map_err(|e| e.to_string())
}

/// Best-effort email lookup from an account's `auth.json` (JWT `id_token`
/// claim). Never fails the caller — returns `None` on any parse error.
fn email_of(auth_path: &Path) -> Option<String> {
    let contents = std::fs::read_to_string(auth_path).ok()?;
    let json: serde_json::Value = serde_json::from_str(&contents).ok()?;
    let id_token = json.get("tokens")?.get("id_token").and_then(serde_json::Value::as_str)?;
    email_from_id_token(id_token)
}

fn email_from_id_token(id_token: &str) -> Option<String> {
    use base64::Engine;
    let payload_b64 = id_token.split('.').nth(1)?;
    let mut padded = payload_b64.replace('-', "+").replace('_', "/");
    while padded.len() % 4 != 0 {
        padded.push('=');
    }
    let payload = base64::engine::general_purpose::STANDARD.decode(padded).ok()?;
    let json: serde_json::Value = serde_json::from_slice(&payload).ok()?;
    if let Some(email) = json.get("email").and_then(serde_json::Value::as_str) {
        return Some(email.to_string());
    }
    json.get("https://api.openai.com/profile")
        .and_then(|p| p.get("email"))
        .and_then(serde_json::Value::as_str)
        .map(String::from)
}

pub fn managed_accounts() -> Vec<CodexAccount> {
    load_stored()
        .accounts
        .into_iter()
        .map(|e| CodexAccount { id: e.id, email: e.email, is_system: false, home_path: Some(e.home_path) })
        .collect()
}

/// Pure reconciliation: drop a managed account whose email matches one
/// already listed (case-insensitive) so the same identity isn't shown twice.
/// Accounts with an unknown email are always kept. Unit-tested.
pub fn reconcile(system: CodexAccount, managed: Vec<CodexAccount>) -> Vec<CodexAccount> {
    let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
    if let Some(email) = system.email.as_deref() {
        seen.insert(email.to_lowercase());
    }
    let deduped: Vec<CodexAccount> = managed
        .into_iter()
        .filter(|a| match a.email.as_deref() {
            Some(email) => seen.insert(email.to_lowercase()),
            None => true,
        })
        .collect();
    let mut out = vec![system];
    out.extend(deduped);
    out
}

pub fn all_accounts() -> Vec<CodexAccount> {
    let system_path = system_auth_path();
    let system = CodexAccount {
        id: SYSTEM_ID.to_string(),
        email: email_of(&system_path),
        is_system: true,
        home_path: None,
    };
    reconcile(system, managed_accounts())
}

/// Copies the current system `~/.codex/auth.json` into a new managed home so
/// it survives future re-logins of the system account. Mirrors
/// `promoteSystem()`. Errors with the same Vietnamese message as Swift when
/// there is no system login yet.
pub fn promote_system() -> Result<CodexAccount, String> {
    let system_path = system_auth_path();
    if !system_path.is_file() {
        return Err("Chưa có đăng nhập hệ thống (~/.codex) để chuyển thành managed.".to_string());
    }
    let id = uuid_v4();
    let home = home_dir_for_account(&id);
    std::fs::create_dir_all(&home).map_err(|e| e.to_string())?;
    let dest = home.join("auth.json");
    std::fs::copy(&system_path, &dest).map_err(|e| e.to_string())?;

    let account = CodexAccount {
        id: id.clone(),
        email: email_of(&dest),
        is_system: false,
        home_path: Some(home.to_string_lossy().to_string()),
    };
    let mut entries = load_stored().accounts;
    entries.push(Entry { id, email: account.email.clone(), home_path: home.to_string_lossy().to_string() });
    persist(&entries)?;
    Ok(account)
}

/// Removes a managed account's home directory and metadata entry. No-op for
/// the system account (mirrors Swift's `guard id != "system"`). Falls the
/// active selection back to `"system"` if the removed account was active.
pub fn remove(id: &str) -> Result<(), String> {
    if id == SYSTEM_ID {
        return Ok(());
    }
    if let Some(account) = managed_accounts().into_iter().find(|a| a.id == id) {
        if let Some(home) = account.home_path {
            let _ = std::fs::remove_dir_all(home);
        }
    }
    let entries: Vec<Entry> = load_stored().accounts.into_iter().filter(|e| e.id != id).collect();
    persist(&entries)?;
    if active_id() == id {
        set_active(SYSTEM_ID)?;
    }
    Ok(())
}

/// Minimal UUID v4 generator (no extra crate dependency) — format matches
/// `UUID().uuidString` closely enough for a directory/account name; only
/// uniqueness matters here, not RFC-strict compliance. Shared with the
/// freemodel account store.
pub(crate) fn uuid_v4() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_nanos();
    let pid = std::process::id() as u128;
    let mut seed = nanos ^ (pid << 64);
    let mut bytes = [0u8; 16];
    for b in &mut bytes {
        // xorshift-ish mix, seeded per-call — good enough for a local, unique
        // directory name; not used for any security purpose.
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        *b = (seed & 0xff) as u8;
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15],
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    // Shared process-wide lock (config.rs) — freemodel_accounts tests touch
    // the same BIRDNION_CONFIG env var.
    use crate::config::TEST_ENV_LOCK as ENV_LOCK;

    fn temp_config_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("birdnion-codex-accounts-test-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn reconcile_dedupes_matching_email_case_insensitive() {
        let system = CodexAccount { id: "system".into(), email: Some("a@b.com".into()), is_system: true, home_path: None };
        let managed = vec![
            CodexAccount { id: "1".into(), email: Some("A@B.com".into()), is_system: false, home_path: Some("/x".into()) },
            CodexAccount { id: "2".into(), email: Some("c@d.com".into()), is_system: false, home_path: Some("/y".into()) },
        ];
        let out = reconcile(system, managed);
        assert_eq!(out.len(), 2);
        assert_eq!(out[1].id, "2");
    }

    #[test]
    fn reconcile_keeps_unknown_email_accounts() {
        let system = CodexAccount { id: "system".into(), email: None, is_system: true, home_path: None };
        let managed = vec![
            CodexAccount { id: "1".into(), email: None, is_system: false, home_path: Some("/x".into()) },
            CodexAccount { id: "2".into(), email: None, is_system: false, home_path: Some("/y".into()) },
        ];
        let out = reconcile(system, managed);
        assert_eq!(out.len(), 3);
    }

    #[test]
    fn promote_switch_remove_roundtrip_on_temp_dirs() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config_dir("roundtrip");
        let codex_home = base.join("codex-home");
        std::fs::create_dir_all(&codex_home).unwrap();
        std::fs::write(
            codex_home.join("auth.json"),
            r#"{"tokens":{"access_token":"at","refresh_token":"rt"}}"#,
        )
        .unwrap();

        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));
        std::env::set_var("CODEX_HOME", &codex_home);

        // No managed accounts yet — only "system" is listed.
        let before = all_accounts();
        assert_eq!(before.len(), 1);
        assert_eq!(before[0].id, SYSTEM_ID);

        // Promote system -> new managed account with a copied auth.json.
        let promoted = promote_system().expect("promote should succeed");
        assert!(!promoted.is_system);
        assert!(PathBuf::from(promoted.home_path.as_ref().unwrap()).join("auth.json").is_file());

        let after = all_accounts();
        assert_eq!(after.len(), 2);

        // Switch active -> the promoted account's auth.json resolves.
        set_active(&promoted.id).unwrap();
        assert_eq!(active_id(), promoted.id);
        assert_eq!(active_auth_path(), PathBuf::from(promoted.home_path.as_ref().unwrap()).join("auth.json"));

        // Remove -> falls back to system automatically.
        remove(&promoted.id).unwrap();
        assert_eq!(active_id(), SYSTEM_ID);
        assert_eq!(active_auth_path(), system_auth_path());
        assert_eq!(all_accounts().len(), 1);

        std::env::remove_var("BIRDNION_CONFIG");
        std::env::remove_var("CODEX_HOME");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn remove_is_noop_for_system_account() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config_dir("remove-system");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));
        set_active(SYSTEM_ID).unwrap();
        assert!(remove(SYSTEM_ID).is_ok());
        assert_eq!(active_id(), SYSTEM_ID);
        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn active_auth_path_falls_back_to_system_when_account_vanished() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config_dir("vanished");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));
        std::env::set_var("HOME", base.join("home"));
        std::env::remove_var("CODEX_HOME");
        set_active("nonexistent-uuid").unwrap();
        assert_eq!(active_auth_path(), system_auth_path());
        std::env::remove_var("BIRDNION_CONFIG");
        std::env::remove_var("HOME");
        let _ = std::fs::remove_dir_all(&base);
    }
}
