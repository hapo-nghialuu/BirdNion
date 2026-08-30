//! Private Copilot OAuth account store plus secret-free IPC descriptors.
//!
//! Tokens remain in `copilot-accounts.json`; callers only receive label/login
//! metadata. Every mutation is serialized and uses the shared private atomic
//! writer so an unreadable or corrupt existing store is never replaced.

use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::path::{Path, PathBuf};

const MAX_STORE_BYTES: usize = 8 * 1024 * 1024;
static STORE_MUTATION_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
pub(crate) const GENERIC_ACCOUNT_LABEL: &str = "GitHub";

#[derive(Deserialize, Serialize, Clone, Default)]
struct AccountEntry {
    label: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    login: Option<String>,
    token: String,
}

#[derive(Deserialize, Serialize, Clone, Default)]
struct AccountStore {
    #[serde(rename = "activeLabel", skip_serializing_if = "Option::is_none")]
    active_label: Option<String>,
    #[serde(default)]
    accounts: Vec<AccountEntry>,
}

/// UI-facing metadata. The token is deliberately absent from this type.
#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CopilotAccountDescriptor {
    pub label: String,
    pub login: Option<String>,
    pub active: bool,
}

#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CopilotAccountsState {
    pub accounts: Vec<CopilotAccountDescriptor>,
    pub active_label: Option<String>,
}

/// One immutable credential selection for a provider fetch. This type is not
/// serializable or debuggable so its token cannot accidentally cross IPC/logs.
pub(crate) struct ActiveCredential {
    pub(crate) label: String,
    pub(crate) login: Option<String>,
    pub(crate) token: String,
}

fn store_path() -> Result<PathBuf, String> {
    crate::config::support_dir()
        .map(|path| path.join("copilot-accounts.json"))
        .ok_or_else(|| "Không xác định được thư mục cấu hình".to_string())
}

fn read_store_at(path: &Path) -> Result<AccountStore, String> {
    let bytes = crate::platform::atomic_file::read_regular_file_bounded(path, MAX_STORE_BYTES)
        .map_err(|_| "Không thể đọc Copilot account store; file được giữ nguyên".to_string())?;
    let Some(bytes) = bytes else {
        return Ok(AccountStore::default());
    };
    serde_json::from_slice(&bytes)
        .map_err(|_| "Copilot account store không hợp lệ; file được giữ nguyên".to_string())
}

fn save_store_at(path: &Path, store: &AccountStore) -> Result<(), String> {
    let json = serde_json::to_vec_pretty(store).map_err(|error| error.to_string())?;
    crate::platform::atomic_file::write_private_json_atomic::<AccountStore>(path, &json)
        .map_err(|error| error.to_string())
}

fn token_prefix(token: &str) -> String {
    token.chars().take(8).collect()
}

fn is_token_prefix(value: &str, token: &str) -> bool {
    let prefix = token_prefix(token);
    !prefix.is_empty() && value.trim() == prefix
}

fn cleaned_login(login: Option<&str>, token: &str) -> Option<String> {
    login
        .map(str::trim)
        .filter(|value| !value.is_empty() && !is_token_prefix(value, token))
        .map(String::from)
}

fn unique_label(base: &str, used: &mut HashSet<String>) -> String {
    let base = if base.trim().is_empty() {
        GENERIC_ACCOUNT_LABEL
    } else {
        base.trim()
    };
    if used.insert(base.to_string()) {
        return base.to_string();
    }
    for suffix in 2.. {
        let candidate = format!("{base} {suffix}");
        if used.insert(candidate.clone()) {
            return candidate;
        }
    }
    unreachable!()
}

/// Migrates the old eight-character token fallback to non-secret labels and
/// repairs duplicate/missing active labels. Returns whether persistence is
/// required before any metadata may be exposed.
fn sanitize_store(store: &mut AccountStore) -> bool {
    let active_index = store.active_label.as_ref().and_then(|label| {
        store
            .accounts
            .iter()
            .position(|account| &account.label == label)
    });
    let mut changed = false;
    let mut used = HashSet::new();

    for account in &mut store.accounts {
        let login = cleaned_login(account.login.as_deref(), &account.token);
        if login != account.login {
            account.login = login;
            changed = true;
        }
        let trimmed = account.label.trim();
        let base = if trimmed.is_empty() || is_token_prefix(trimmed, &account.token) {
            account.login.as_deref().unwrap_or(GENERIC_ACCOUNT_LABEL)
        } else {
            trimmed
        };
        let label = unique_label(base, &mut used);
        if label != account.label {
            account.label = label;
            changed = true;
        }
    }

    let active_label = active_index
        .and_then(|index| store.accounts.get(index))
        .or_else(|| store.accounts.first())
        .map(|account| account.label.clone());
    if active_label != store.active_label {
        store.active_label = active_label;
        changed = true;
    }
    changed
}

fn public_state(store: &AccountStore) -> CopilotAccountsState {
    let active_label = store
        .active_label
        .as_ref()
        .filter(|label| {
            store
                .accounts
                .iter()
                .any(|account| &account.label == *label)
        })
        .cloned()
        .or_else(|| store.accounts.first().map(|account| account.label.clone()));
    CopilotAccountsState {
        accounts: store
            .accounts
            .iter()
            .map(|account| CopilotAccountDescriptor {
                label: account.label.clone(),
                login: account.login.clone(),
                active: active_label.as_deref() == Some(account.label.as_str()),
            })
            .collect(),
        active_label,
    }
}

fn load_sanitized_at(path: &Path) -> Result<AccountStore, String> {
    let mut store = read_store_at(path)?;
    if sanitize_store(&mut store) {
        save_store_at(path, &store)?;
    }
    Ok(store)
}

pub fn accounts_list() -> Result<CopilotAccountsState, String> {
    let _guard = STORE_MUTATION_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    Ok(public_state(&load_sanitized_at(&store_path()?)?))
}

fn set_active(store: &mut AccountStore, label: &str) -> Result<(), String> {
    let label = label.trim();
    if label.is_empty() || !store.accounts.iter().any(|account| account.label == label) {
        return Err("Không tìm thấy tài khoản Copilot".to_string());
    }
    store.active_label = Some(label.to_string());
    Ok(())
}

pub fn account_switch(label: &str) -> Result<CopilotAccountsState, String> {
    let _guard = STORE_MUTATION_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let path = store_path()?;
    let mut store = read_store_at(&path)?;
    sanitize_store(&mut store);
    set_active(&mut store, label)?;
    save_store_at(&path, &store)?;
    Ok(public_state(&store))
}

fn remove_account(store: &mut AccountStore, label: &str) -> Result<(), String> {
    if !store.accounts.iter().any(|account| account.label == label) {
        return Err("Không tìm thấy tài khoản Copilot".to_string());
    }
    store.accounts.retain(|account| account.label != label);
    if store.active_label.as_deref() == Some(label)
        || store.active_label.as_ref().is_some_and(|active| {
            !store
                .accounts
                .iter()
                .any(|account| &account.label == active)
        })
    {
        store.active_label = store.accounts.first().map(|account| account.label.clone());
    }
    Ok(())
}

pub fn account_remove(label: &str) -> Result<CopilotAccountsState, String> {
    let _guard = STORE_MUTATION_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let path = store_path()?;
    let mut store = read_store_at(&path)?;
    sanitize_store(&mut store);
    remove_account(&mut store, label.trim())?;
    save_store_at(&path, &store)?;
    Ok(public_state(&store))
}

fn upsert_account(store: &mut AccountStore, label: &str, login: Option<&str>, token: &str) {
    sanitize_store(store);
    let login = cleaned_login(login, token);
    let requested = label.trim();
    let label = if requested.is_empty() || is_token_prefix(requested, token) {
        login
            .clone()
            .unwrap_or_else(|| GENERIC_ACCOUNT_LABEL.to_string())
    } else {
        requested.to_string()
    };

    if let Some(account) = store
        .accounts
        .iter_mut()
        .find(|account| account.label == label)
    {
        account.login = login;
        account.token = token.to_string();
    } else {
        store.accounts.push(AccountEntry {
            label: label.clone(),
            login,
            token: token.to_string(),
        });
    }
    store.active_label = Some(label);
}

pub(crate) fn save_login_account(
    label: &str,
    login: Option<&str>,
    token: &str,
) -> Result<CopilotAccountsState, String> {
    let token = token.trim();
    if token.is_empty() {
        return Err("GitHub token trống".to_string());
    }
    let _guard = STORE_MUTATION_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let path = store_path()?;
    let mut store = read_store_at(&path)?;
    upsert_account(&mut store, label, login, token);
    save_store_at(&path, &store)?;
    Ok(public_state(&store))
}

pub(crate) fn active_credential() -> Result<Option<ActiveCredential>, String> {
    let _guard = STORE_MUTATION_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let store = load_sanitized_at(&store_path()?)?;
    let active = store
        .active_label
        .as_ref()
        .and_then(|label| {
            store
                .accounts
                .iter()
                .find(|account| &account.label == label)
        })
        .or_else(|| store.accounts.first());
    Ok(active.map(|account| ActiveCredential {
        label: account.label.clone(),
        login: account.login.clone(),
        token: account.token.clone(),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_path(tag: &str) -> PathBuf {
        let directory = std::env::temp_dir().join(format!(
            "birdnion-copilot-{tag}-{}-{}",
            std::process::id(),
            chrono::Utc::now().timestamp_nanos_opt().unwrap_or_default()
        ));
        std::fs::create_dir_all(&directory).unwrap();
        directory.join("copilot-accounts.json")
    }

    #[test]
    fn public_state_serializes_no_secret_fields() {
        let mut store = AccountStore::default();
        upsert_account(&mut store, "octocat", Some("octocat"), "ghu_secret-token");
        let json = serde_json::to_string(&public_state(&store)).unwrap();
        assert!(json.contains("octocat"));
        assert!(!json.contains("ghu_secret-token"));
        assert!(!json.contains("token"));
    }

    #[test]
    fn second_login_becomes_active_and_duplicate_updates_in_place() {
        let mut store = AccountStore::default();
        upsert_account(&mut store, "personal", Some("personal"), "first-token");
        upsert_account(&mut store, "work", Some("work"), "work-token-one");
        assert_eq!(store.active_label.as_deref(), Some("work"));
        assert_eq!(store.accounts.len(), 2);

        upsert_account(&mut store, "work", Some("work"), "work-token-two");
        assert_eq!(store.accounts.len(), 2);
        assert_eq!(store.accounts[1].token, "work-token-two");
        assert_eq!(store.active_label.as_deref(), Some("work"));
    }

    #[test]
    fn unknown_switch_fails_without_changing_active() {
        let mut store = AccountStore::default();
        upsert_account(&mut store, "personal", Some("personal"), "first-token");
        assert!(set_active(&mut store, "missing").is_err());
        assert_eq!(store.active_label.as_deref(), Some("personal"));
    }

    #[test]
    fn removing_active_account_falls_back_to_first() {
        let mut store = AccountStore::default();
        upsert_account(&mut store, "personal", Some("personal"), "first-token");
        upsert_account(&mut store, "work", Some("work"), "second-token");
        remove_account(&mut store, "work").unwrap();
        assert_eq!(store.active_label.as_deref(), Some("personal"));
        assert_eq!(store.accounts.len(), 1);
    }

    #[test]
    fn unknown_remove_fails_without_mutating_store() {
        let mut store = AccountStore::default();
        upsert_account(&mut store, "personal", Some("personal"), "first-token");
        let before = serde_json::to_vec(&store).unwrap();
        assert!(remove_account(&mut store, "missing").is_err());
        assert_eq!(serde_json::to_vec(&store).unwrap(), before);
    }

    #[test]
    fn corrupt_existing_store_is_preserved() {
        let path = temp_path("corrupt");
        let corrupt = b"{not-json";
        std::fs::write(&path, corrupt).unwrap();
        assert!(load_sanitized_at(&path).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), corrupt);
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn legacy_token_prefix_label_is_sanitized_before_serialization() {
        let token = "ghu_abcdefghijklmnop";
        let prefix = token_prefix(token);
        let mut store = AccountStore {
            active_label: Some(prefix.clone()),
            accounts: vec![AccountEntry {
                label: prefix.clone(),
                login: Some(prefix.clone()),
                token: token.to_string(),
            }],
        };
        assert!(sanitize_store(&mut store));
        let json = serde_json::to_string(&public_state(&store)).unwrap();
        assert_eq!(store.accounts[0].label, GENERIC_ACCOUNT_LABEL);
        assert!(store.accounts[0].login.is_none());
        assert!(!json.contains(&prefix));
        assert!(!json.contains(token));
    }

    #[cfg(unix)]
    #[test]
    fn store_write_is_atomic_and_private() {
        use std::os::unix::fs::PermissionsExt;

        let path = temp_path("private");
        save_store_at(&path, &AccountStore::default()).unwrap();
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }
}
