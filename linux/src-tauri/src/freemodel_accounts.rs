//! FreeModel multi-account store — same shape as the Codex account store:
//! an implicit read-only "browser" entry (live browser-cookie scan) plus
//! managed accounts, each holding one pasted `bm_session` cookie string.
//!
//! Cookies are secrets, so they live in their OWN file
//! (`~/.config/birdnion/freemodel-accounts.json`, chmod 0600) instead of the
//! shared `settings.json` — a macOS save of the shared file must never wipe
//! them. Only the active-account id rides in settings.json
//! (`active_freemodel_account`).

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

use crate::codex_accounts::uuid_v4;
use crate::config;

pub const BROWSER_ID: &str = "browser";
/// Per-browser session accounts use `browser:<name>` ids ("browser:chrome"…)
/// — different browsers signed in to different FreeModel accounts each show
/// up as their own selectable entry.
pub const BROWSER_PREFIX: &str = "browser:";

/// Human label for a `browser:<name>` id ("Chrome", "Brave"…).
pub fn browser_label(browser: &str) -> String {
    match browser {
        "chrome" => "Chrome".to_string(),
        "chromium" => "Chromium".to_string(),
        "brave" => "Brave".to_string(),
        "edge" => "Edge".to_string(),
        "firefox" => "Firefox".to_string(),
        other => other.to_string(),
    }
}

/// UI-facing account descriptor — the cookie value itself is NEVER
/// serialized to the frontend.
#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct FreemodelAccount {
    pub id: String,
    pub email: Option<String>,
    pub label: Option<String>,
    pub is_browser: bool,
}

#[derive(Deserialize, Serialize, Clone, Debug, Default)]
struct Entry {
    id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    email: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    label: Option<String>,
    cookie: String,
}

#[derive(Deserialize, Serialize, Clone, Debug, Default)]
struct Stored {
    #[serde(default)]
    accounts: Vec<Entry>,
}

fn metadata_path() -> PathBuf {
    config::config_path()
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_else(|| PathBuf::from("."))
        .join("freemodel-accounts.json")
}

fn load_stored() -> Stored {
    std::fs::read_to_string(metadata_path())
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

fn persist(entries: &[Entry]) -> Result<(), String> {
    let path = metadata_path();
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    let json = serde_json::to_string_pretty(&Stored { accounts: entries.to_vec() })
        .map_err(|e| e.to_string())?;
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, json).map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600));
    }
    std::fs::rename(&tmp, &path).map_err(|e| e.to_string())
}

/// Active account id, persisted in settings.json. Defaults to `"browser"`.
pub fn active_id() -> String {
    config::load().active_freemodel_account.unwrap_or_else(|| BROWSER_ID.to_string())
}

pub fn set_active(id: &str) -> Result<(), String> {
    let mut settings = config::load();
    settings.active_freemodel_account = Some(id.to_string());
    config::save(&settings)
}

fn to_account(e: &Entry) -> FreemodelAccount {
    FreemodelAccount { id: e.id.clone(), email: e.email.clone(), label: e.label.clone(), is_browser: false }
}

/// Browser entry first, then managed accounts in stored order.
pub fn all_accounts() -> Vec<FreemodelAccount> {
    let mut out = vec![FreemodelAccount {
        id: BROWSER_ID.to_string(),
        email: None,
        label: None,
        is_browser: true,
    }];
    out.extend(load_stored().accounts.iter().map(to_account));
    out
}

/// The stored cookie for the ACTIVE account — `None` for browser entries
/// (auto or per-browser live scan) or when the managed account vanished.
pub fn active_cookie() -> Option<String> {
    let id = active_id();
    if id == BROWSER_ID || id.starts_with(BROWSER_PREFIX) {
        return None;
    }
    load_stored().accounts.into_iter().find(|e| e.id == id).map(|e| e.cookie)
}

/// The specific browser name when the active account is a `browser:<name>`
/// entry (e.g. "chrome"), else `None`.
pub fn active_browser() -> Option<String> {
    active_id().strip_prefix(BROWSER_PREFIX).map(String::from)
}

/// Stores a validated cookie as a new managed account.
pub fn add(cookie: &str, label: Option<&str>, email: Option<&str>) -> Result<FreemodelAccount, String> {
    let cookie = cookie.trim();
    if cookie.is_empty() {
        return Err("Cookie trống".to_string());
    }
    let entry = Entry {
        id: uuid_v4(),
        email: email.map(str::trim).filter(|s| !s.is_empty()).map(String::from),
        label: label.map(str::trim).filter(|s| !s.is_empty()).map(String::from),
        cookie: cookie.to_string(),
    };
    let account = to_account(&entry);
    let mut entries = load_stored().accounts;
    entries.push(entry);
    persist(&entries)?;
    Ok(account)
}

/// Removes a managed account; falls the active selection back to "browser"
/// when it was the removed one. No-op for browser entries (auto + per-browser).
pub fn remove(id: &str) -> Result<(), String> {
    if id == BROWSER_ID || id.starts_with(BROWSER_PREFIX) {
        return Ok(());
    }
    let entries: Vec<Entry> = load_stored().accounts.into_iter().filter(|e| e.id != id).collect();
    persist(&entries)?;
    if active_id() == id {
        set_active(BROWSER_ID)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    // Shared process-wide lock (config.rs) — codex_accounts tests touch the
    // same BIRDNION_CONFIG env var.
    use crate::config::TEST_ENV_LOCK as ENV_LOCK;

    fn temp_config(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("birdnion-fm-accounts-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn add_switch_remove_roundtrip() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config("roundtrip");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));

        assert_eq!(all_accounts().len(), 1); // browser only
        assert_eq!(active_id(), BROWSER_ID);
        assert!(active_cookie().is_none());

        let account = add("bm_session=abc123", Some("Acc 1"), Some("a@b.com")).unwrap();
        assert_eq!(all_accounts().len(), 2);
        assert_eq!(account.email.as_deref(), Some("a@b.com"));

        set_active(&account.id).unwrap();
        assert_eq!(active_cookie().as_deref(), Some("bm_session=abc123"));

        remove(&account.id).unwrap();
        assert_eq!(active_id(), BROWSER_ID);
        assert!(active_cookie().is_none());
        assert_eq!(all_accounts().len(), 1);

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn vanished_active_account_falls_back_to_browser_scan() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config("vanished");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));
        set_active("nonexistent").unwrap();
        assert!(active_cookie().is_none());
        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn per_browser_ids_scan_live_and_survive_remove() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config("per-browser");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));

        set_active("browser:chrome").unwrap();
        // Browser entries never resolve a stored cookie — live scan path.
        assert!(active_cookie().is_none());
        assert_eq!(active_browser().as_deref(), Some("chrome"));
        // Remove is a no-op and keeps the selection.
        assert!(remove("browser:chrome").is_ok());
        assert_eq!(active_id(), "browser:chrome");

        set_active(BROWSER_ID).unwrap();
        assert!(active_browser().is_none());

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn browser_label_maps_known_names() {
        assert_eq!(browser_label("chrome"), "Chrome");
        assert_eq!(browser_label("firefox"), "Firefox");
        assert_eq!(browser_label("unknown-browser"), "unknown-browser");
    }

    #[test]
    fn empty_cookie_rejected_and_browser_remove_is_noop() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config("guards");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));
        assert!(add("   ", None, None).is_err());
        assert!(remove(BROWSER_ID).is_ok());
        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(&base);
    }
}
