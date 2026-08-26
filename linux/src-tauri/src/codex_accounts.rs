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
use std::collections::HashMap;
use std::ffi::OsStr;
use std::path::{Path, PathBuf};

use crate::config;
use crate::providers::{self, ProviderStatus};

pub const SYSTEM_ID: &str = "system";
static ACCOUNT_STORE_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
static SNAPSHOT_STORE_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
static AUTH_FILE_REVISIONS: std::sync::LazyLock<
    std::sync::Mutex<HashMap<crate::platform::atomic_file::DirectoryIdentity, u64>>,
> = std::sync::LazyLock::new(|| std::sync::Mutex::new(HashMap::new()));
const MAX_ACCOUNT_STATE_BYTES: usize = 8 * 1024 * 1024;
const AUTH_FILE_NAME: &str = "auth.json";

#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CodexAccount {
    pub id: String,
    pub email: Option<String>,
    pub is_system: bool,
    pub home_path: Option<String>,
}

/// Immutable identity + credential path for one Codex provider fetch.
/// Resolving both fields together prevents an account switch from splitting
/// snapshot ownership from the auth file being read or refreshed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ActiveSelection {
    pub account_id: String,
    pub auth_path: Option<PathBuf>,
    pub(crate) auth_directory: Option<crate::platform::atomic_file::BoundDirectory>,
}

struct ValidatedManagedHome {
    path: PathBuf,
    directory: crate::platform::atomic_file::BoundDirectory,
}

struct ValidatedManagedPath {
    canonical_home: PathBuf,
    root_metadata: std::fs::Metadata,
    home_metadata: std::fs::Metadata,
}

struct BoundManagedHome {
    root: crate::platform::atomic_file::BoundDirectory,
    home: crate::platform::atomic_file::BoundDirectory,
}

#[derive(Deserialize, Serialize, Clone, Debug, Default)]
struct Entry {
    id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    email: Option<String>,
    home_path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    root_device: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    root_inode: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    home_device: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    home_inode: Option<u64>,
}

#[derive(Deserialize, Serialize, Clone, Debug, Default)]
struct Stored {
    #[serde(default)]
    accounts: Vec<Entry>,
}

/// Last observed quota and health for one Codex account. Quota values are
/// last-good: a failed scan updates health without discarding usable quota.
#[derive(Deserialize, Serialize, Clone, Debug, Default, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct AccountQuotaSnapshot {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub remaining_pct: Option<i32>,
    #[serde(default)]
    pub last_checked: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error_kind: Option<String>,
}

fn support_dir() -> Option<PathBuf> {
    // Sibling of settings.json (same directory config::config_path() resolves
    // its parent to), keeping every BirdNion app-state file under one root.
    config::support_dir()
}

fn accounts_root_dir() -> Option<PathBuf> {
    support_dir().map(|path| path.join("codex-accounts"))
}

fn metadata_path() -> Option<PathBuf> {
    support_dir().map(|path| path.join("codex-accounts.json"))
}

fn snapshots_path() -> Option<PathBuf> {
    support_dir().map(|path| path.join("codex-account-snapshots.json"))
}

pub(crate) struct GuardedAuthFile {
    pub bytes: Vec<u8>,
    pub revision: u64,
    pub directory: crate::platform::atomic_file::BoundDirectory,
}

/// Read auth bytes and the app-owned mutation generation under one lock.
/// External CLI writes are still detected by the byte comparison at commit;
/// BirdNion remove/reauth operations additionally share this generation lock.
/// A conditional-write backup is recovered here before absence can be exposed
/// to the provider as a signed-out state after a process/power failure.
pub(crate) fn read_auth_file_guarded(
    path: &Path,
    maximum: usize,
) -> std::io::Result<Option<GuardedAuthFile>> {
    let parent = path.parent().ok_or_else(|| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "Codex auth path has no parent",
        )
    })?;
    let directory = crate::platform::atomic_file::BoundDirectory::open(parent)?;
    read_auth_file_guarded_at(&directory, maximum)
}

pub(crate) fn read_auth_file_guarded_at(
    directory: &crate::platform::atomic_file::BoundDirectory,
    maximum: usize,
) -> std::io::Result<Option<GuardedAuthFile>> {
    let revisions = AUTH_FILE_REVISIONS
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    crate::platform::atomic_file::recover_private_json_atomic_at::<serde_json::Value>(
        directory,
        OsStr::new(AUTH_FILE_NAME),
    )?;
    let Some(bytes) = crate::platform::atomic_file::read_regular_file_bounded_at(
        directory,
        OsStr::new(AUTH_FILE_NAME),
        maximum,
    )?
    else {
        return Ok(None);
    };
    Ok(Some(GuardedAuthFile {
        bytes,
        revision: revisions.get(&directory.identity()).copied().unwrap_or(0),
        directory: directory.clone(),
    }))
}

/// Run a conditional commit while holding the same lock used by account
/// mutation invalidation. Either the commit finishes before removal starts,
/// or the revision bump wins and this returns `None` without writing.
pub(crate) fn with_current_auth_file<T>(
    path: &Path,
    maximum: usize,
    expected_revision: u64,
    expected_bytes: &[u8],
    operation: impl FnOnce() -> std::io::Result<T>,
) -> std::io::Result<Option<T>> {
    let parent = path.parent().ok_or_else(|| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "Codex auth path has no parent",
        )
    })?;
    let directory = crate::platform::atomic_file::BoundDirectory::open(parent)?;
    with_current_auth_file_at(
        &directory,
        maximum,
        expected_revision,
        expected_bytes,
        operation,
    )
}

pub(crate) fn with_current_auth_file_at<T>(
    directory: &crate::platform::atomic_file::BoundDirectory,
    maximum: usize,
    expected_revision: u64,
    expected_bytes: &[u8],
    operation: impl FnOnce() -> std::io::Result<T>,
) -> std::io::Result<Option<T>> {
    let revisions = AUTH_FILE_REVISIONS
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    if revisions.get(&directory.identity()).copied().unwrap_or(0) != expected_revision {
        return Ok(None);
    }
    let Some(current) = crate::platform::atomic_file::read_regular_file_bounded_at(
        directory,
        OsStr::new(AUTH_FILE_NAME),
        maximum,
    )?
    else {
        return Ok(None);
    };
    if current != expected_bytes {
        return Ok(None);
    }
    operation().map(Some)
}

pub(crate) fn invalidate_auth_file(path: &Path) {
    let Some(parent) = path.parent() else { return };
    let Ok(directory) = crate::platform::atomic_file::BoundDirectory::open(parent) else {
        return;
    };
    invalidate_auth_directory(&directory);
}

pub(crate) fn invalidate_auth_directory(directory: &crate::platform::atomic_file::BoundDirectory) {
    let mut revisions = AUTH_FILE_REVISIONS
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let revision = revisions.entry(directory.identity()).or_insert(0);
    *revision = revision.wrapping_add(1);
}

/// Missing or corrupt snapshots are non-fatal: this file is only a popover
/// cache, never an authentication or routing source of truth.
pub fn quota_snapshots() -> HashMap<String, AccountQuotaSnapshot> {
    snapshots_path()
        .and_then(|path| {
            crate::platform::atomic_file::read_regular_file_bounded(&path, MAX_ACCOUNT_STATE_BYTES)
                .ok()
                .flatten()
        })
        .and_then(|json| serde_json::from_slice(&json).ok())
        .unwrap_or_default()
}

fn persist_snapshots(snapshots: &HashMap<String, AccountQuotaSnapshot>) -> Result<(), String> {
    let path =
        snapshots_path().ok_or_else(|| "Không xác định được thư mục cấu hình".to_string())?;
    let json = serde_json::to_string_pretty(snapshots).map_err(|e| e.to_string())?;
    crate::platform::atomic_file::write_private_json_atomic::<
        HashMap<String, AccountQuotaSnapshot>,
    >(&path, json.as_bytes())
        .map_err(|e| e.to_string())
}

/// Persist the result of an already-completed Codex provider fetch. No new
/// request is initiated here. A failure keeps the last-good quota but records
/// the current actionable error classification.
pub fn save_snapshot(account_id: &str, status: &ProviderStatus) -> Result<(), String> {
    let _guard = SNAPSHOT_STORE_LOCK
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let mut snapshots = quota_snapshots();
    let previous = snapshots.get(account_id).cloned().unwrap_or_default();
    let lowest = status
        .windows
        .iter()
        .min_by_key(|window| window.remaining_pct);

    let snapshot = if let Some(raw_error) = status.error.as_deref() {
        AccountQuotaSnapshot {
            label: previous.label,
            remaining_pct: previous.remaining_pct,
            last_checked: status.last_updated,
            error_kind: providers::error_classifier::classify(Some(raw_error))
                .map(|kind| kind.key_suffix().to_string()),
        }
    } else if let Some(window) = lowest {
        AccountQuotaSnapshot {
            label: Some(window.label.clone()),
            remaining_pct: Some(window.remaining_pct.clamp(0, 100)),
            last_checked: status.last_updated,
            error_kind: None,
        }
    } else {
        AccountQuotaSnapshot {
            last_checked: status.last_updated,
            error_kind: None,
            ..previous
        }
    };

    snapshots.insert(account_id.to_string(), snapshot);
    persist_snapshots(&snapshots)
}

fn prune_snapshot(account_id: &str) -> Result<(), String> {
    let _guard = SNAPSHOT_STORE_LOCK
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let mut snapshots = quota_snapshots();
    if snapshots.remove(account_id).is_some() {
        persist_snapshots(&snapshots)?;
    }
    Ok(())
}

pub fn home_dir_for_account(id: &str) -> Option<PathBuf> {
    accounts_root_dir().map(|path| path.join(id))
}

pub fn system_auth_path() -> Option<PathBuf> {
    validated_system_home().map(|home| home.join("auth.json"))
}

/// Resolve existing symlink components while retaining a nonexistent suffix.
/// Returning the resolved path also binds subsequent auth reads to the path
/// role checked here instead of following a CODEX_HOME alias a second time.
fn resolved_path_role(path: &Path) -> Option<PathBuf> {
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir().ok()?.join(path)
    };
    let mut normalized = PathBuf::new();
    for component in absolute.components() {
        match component {
            std::path::Component::Prefix(prefix) => normalized.push(prefix.as_os_str()),
            std::path::Component::RootDir => normalized.push(component.as_os_str()),
            std::path::Component::CurDir => {}
            std::path::Component::ParentDir => {
                if normalized.file_name().is_some() {
                    normalized.pop();
                }
            }
            std::path::Component::Normal(part) => normalized.push(part),
        }
    }

    let mut existing = normalized.clone();
    let mut suffix = Vec::new();
    loop {
        match std::fs::canonicalize(&existing) {
            Ok(mut resolved) => {
                for component in suffix.iter().rev() {
                    resolved.push(component);
                }
                return Some(resolved);
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                suffix.push(existing.file_name()?.to_os_string());
                if !existing.pop() {
                    return None;
                }
            }
            Err(_) => return None,
        }
    }
}

fn path_component_prefix(path: &Path, base: &Path, case_insensitive: bool) -> bool {
    let mut path_components = path.components();
    for base_component in base.components() {
        let Some(path_component) = path_components.next() else {
            return false;
        };
        let equal = if case_insensitive {
            path_component
                .as_os_str()
                .to_string_lossy()
                .eq_ignore_ascii_case(&base_component.as_os_str().to_string_lossy())
        } else {
            path_component == base_component
        };
        if !equal {
            return false;
        }
    }
    true
}

fn paths_equal_for_role(left: &Path, right: &Path) -> bool {
    path_component_prefix(left, right, cfg!(windows))
        && path_component_prefix(right, left, cfg!(windows))
}

fn paths_overlap_for_role(left: &Path, right: &Path) -> bool {
    path_component_prefix(left, right, cfg!(windows))
        || path_component_prefix(right, left, cfg!(windows))
}

fn validated_system_home() -> Option<PathBuf> {
    let system_home = resolved_path_role(&crate::platform::paths::codex_home()?)?;
    let managed_root = resolved_path_role(&accounts_root_dir()?)?;
    (!paths_overlap_for_role(&system_home, &managed_root)).then_some(system_home)
}

fn bind_existing_role_directory(
    path: &Path,
) -> Option<crate::platform::atomic_file::BoundDirectory> {
    let before = std::fs::symlink_metadata(path).ok()?;
    if !before.is_dir() || metadata_is_link_like(&before) {
        return None;
    }
    let directory = crate::platform::atomic_file::BoundDirectory::open(path).ok()?;
    if !directory.matches_metadata(&before) {
        return None;
    }
    let after = std::fs::symlink_metadata(path).ok()?;
    (after.is_dir() && !metadata_is_link_like(&after) && directory.matches_metadata(&after))
        .then_some(directory)
}

fn system_selection() -> ActiveSelection {
    let home = validated_system_home();
    let auth_path = home.as_ref().map(|path| path.join(AUTH_FILE_NAME));
    let auth_directory = home.as_deref().and_then(|path| {
        let directory = bind_existing_role_directory(path)?;
        let current = validated_system_home()?;
        paths_equal_for_role(&current, path).then_some(directory)
    });
    ActiveSelection {
        account_id: SYSTEM_ID.to_string(),
        auth_path,
        auth_directory,
    }
}

/// Active account id, persisted in settings.json. Defaults to `"system"`.
pub fn active_id() -> String {
    active_id_checked().unwrap_or_else(|_| SYSTEM_ID.to_string())
}

fn active_id_checked() -> Result<String, String> {
    Ok(config::load_checked()?
        .active_codex_account
        .unwrap_or_else(|| SYSTEM_ID.to_string()))
}

pub fn set_active(id: &str) -> Result<(), String> {
    config::update(|settings| {
        settings.active_codex_account = Some(id.to_string());
        Ok(())
    })
}

/// Resolve the active account id and auth path as one immutable value. The
/// system credential is eligible only when authoritative settings explicitly
/// select it (or omit the key). An invalid managed route must never fall
/// through to the system credential.
pub fn active_selection_checked() -> Result<ActiveSelection, String> {
    selection_for_id_checked(active_id_checked()?)
}

fn selection_for_id_checked(id: String) -> Result<ActiveSelection, String> {
    if id == SYSTEM_ID {
        return Ok(system_selection());
    }
    let home = validated_active_managed_home(&id)
        .ok_or_else(|| "Không thể xác minh account Codex đang hoạt động".to_string())?;
    Ok(ActiveSelection {
        account_id: id,
        auth_path: Some(home.path.join(AUTH_FILE_NAME)),
        auth_directory: Some(home.directory),
    })
}

/// Compatibility wrapper for read-only callers. Failure is represented as an
/// unavailable selection and therefore cannot expose the system credential.
pub fn active_selection() -> ActiveSelection {
    match active_id_checked() {
        Ok(id) => selection_for_id_checked(id.clone()).unwrap_or(ActiveSelection {
            account_id: id,
            auth_path: None,
            auth_directory: None,
        }),
        Err(_) => ActiveSelection {
            account_id: String::new(),
            auth_path: None,
            auth_directory: None,
        },
    }
}

/// The auth.json path the Codex provider should read for the active account.
#[cfg(test)]
pub fn active_auth_path() -> Option<PathBuf> {
    active_selection().auth_path
}

fn managed_home_for_id(id: &str) -> Option<PathBuf> {
    let mut components = std::path::Path::new(id).components();
    let is_single_normal = matches!(components.next(), Some(std::path::Component::Normal(value)) if value == id)
        && components.next().is_none()
        && id != "."
        && id != "..";
    if !is_single_normal {
        return None;
    }
    accounts_root_dir().map(|root| root.join(id))
}

fn bind_managed_home_directory(
    id: &str,
    canonical_home: &Path,
    expected_root_metadata: &std::fs::Metadata,
    expected_home_metadata: &std::fs::Metadata,
) -> Option<BoundManagedHome> {
    let root = accounts_root_dir()?;
    let expected_home = managed_home_for_id(id)?;
    let canonical_root = std::fs::canonicalize(&root).ok()?;
    let root_directory = bind_existing_role_directory(&canonical_root)?;
    let current_root = resolved_path_role(&root)?;
    if !paths_equal_for_role(&current_root, &canonical_root)
        || !root_directory.matches_metadata(expected_root_metadata)
    {
        return None;
    }
    let home_directory = root_directory.open_child_directory(OsStr::new(id)).ok()?;
    let current_home = std::fs::canonicalize(&expected_home).ok()?;
    let current_metadata = std::fs::symlink_metadata(&expected_home).ok()?;
    if metadata_is_link_like(&current_metadata)
        || !paths_equal_for_role(&current_home, canonical_home)
        || !home_directory.matches_metadata(expected_home_metadata)
        || !home_directory.matches_metadata(&current_metadata)
        || !root_directory.child_directory_has_identity(OsStr::new(id), home_directory.identity())
    {
        return None;
    }
    Some(BoundManagedHome {
        root: root_directory,
        home: home_directory,
    })
}

/// Credential routing accepts only one metadata entry whose stored path and
/// real directory both resolve to the app-owned account home. Any malformed,
/// linked, duplicated, or relocated entry fails closed without exposing its
/// target or the system credential to provider reads or refresh writes.
fn validated_active_managed_home(id: &str) -> Option<ValidatedManagedHome> {
    validated_active_managed_home_with_hook(id, || {})
}

fn validated_active_managed_home_with_hook(
    id: &str,
    after_validation_before_bind: impl FnOnce(),
) -> Option<ValidatedManagedHome> {
    let stored = load_stored_for_mutation().ok()?;
    let mut matches = stored.accounts.iter().filter(|entry| entry.id == id);
    let entry = matches.next()?;
    if matches.next().is_some() {
        return None;
    }
    let expected_home = managed_home_for_id(&entry.id)?;
    let validated_path = validate_managed_home_with_identity(&expected_home).ok()??;
    let stored_home = resolved_path_role(Path::new(&entry.home_path))?;
    if !paths_equal_for_role(&stored_home, &validated_path.canonical_home) {
        return None;
    }

    after_validation_before_bind();
    let bound_home = bind_managed_home_directory(
        &entry.id,
        &validated_path.canonical_home,
        &validated_path.root_metadata,
        &validated_path.home_metadata,
    )?;
    if !entry_identity_matches_binding(entry, &bound_home) {
        return None;
    }
    Some(ValidatedManagedHome {
        path: validated_path.canonical_home,
        directory: bound_home.home,
    })
}

fn entry_identity_matches_binding(entry: &Entry, binding: &BoundManagedHome) -> bool {
    match (
        entry.root_device,
        entry.root_inode,
        entry.home_device,
        entry.home_inode,
    ) {
        (Some(root_device), Some(root_inode), Some(home_device), Some(home_inode)) => {
            binding.root.identity_parts() == (root_device, root_inode)
                && binding.home.identity_parts() == (home_device, home_inode)
        }
        _ => false,
    }
}

fn load_stored() -> Stored {
    load_stored_for_mutation().unwrap_or_default()
}

/// Credential-routing mutations may start empty only when the metadata file
/// is genuinely missing. Existing malformed, linked, special, or oversized
/// state fails closed so promote/remove cannot erase or route around it.
fn load_stored_for_mutation() -> Result<Stored, String> {
    let path = metadata_path().ok_or_else(|| "Không xác định được thư mục cấu hình".to_string())?;
    let Some(bytes) =
        crate::platform::atomic_file::read_regular_file_bounded(&path, MAX_ACCOUNT_STATE_BYTES)
            .map_err(|error| error.to_string())?
    else {
        return Ok(Stored::default());
    };
    serde_json::from_slice(&bytes).map_err(|error| error.to_string())
}

fn persist(entries: &[Entry]) -> Result<(), String> {
    let path = metadata_path().ok_or_else(|| "Không xác định được thư mục cấu hình".to_string())?;
    let stored = Stored {
        accounts: entries.to_vec(),
    };
    let json = serde_json::to_string_pretty(&stored).map_err(|e| e.to_string())?;
    crate::platform::atomic_file::write_private_json_atomic::<Stored>(&path, json.as_bytes())
        .map_err(|e| e.to_string())
}

/// Best-effort email lookup from an account's `auth.json` (JWT `id_token`
/// claim). Never fails the caller — returns `None` on any parse error.
fn email_of(auth_path: &Path) -> Option<String> {
    let contents =
        crate::platform::atomic_file::read_regular_file_bounded(auth_path, MAX_ACCOUNT_STATE_BYTES)
            .ok()
            .flatten()?;
    email_from_auth_bytes(&contents)
}

fn email_from_auth_bytes(contents: &[u8]) -> Option<String> {
    let json: serde_json::Value = serde_json::from_slice(&contents).ok()?;
    let id_token = json
        .get("tokens")?
        .get("id_token")
        .and_then(serde_json::Value::as_str)?;
    email_from_id_token(id_token)
}

fn email_from_id_token(id_token: &str) -> Option<String> {
    use base64::Engine;
    let payload_b64 = id_token.split('.').nth(1)?;
    let mut padded = payload_b64.replace('-', "+").replace('_', "/");
    while padded.len() % 4 != 0 {
        padded.push('=');
    }
    let payload = base64::engine::general_purpose::STANDARD
        .decode(padded)
        .ok()?;
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
        .map(|e| CodexAccount {
            id: e.id,
            email: e.email,
            is_system: false,
            home_path: Some(e.home_path),
        })
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
        email: system_path.as_deref().and_then(email_of),
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
    promote_system_after_staging(|| {})
}

fn promote_system_after_staging(after_staging: impl FnOnce()) -> Result<CodexAccount, String> {
    let _guard = ACCOUNT_STORE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let mut entries = load_stored_for_mutation()?.accounts;
    let system_selection = system_selection();
    let system_directory = system_selection
        .auth_directory
        .as_ref()
        .ok_or_else(|| "Không xác định được thư mục Codex hệ thống".to_string())?;
    let source = read_auth_file_guarded_at(system_directory, MAX_ACCOUNT_STATE_BYTES)
        .map_err(|error| error.to_string())?
        .ok_or_else(|| {
            "Chưa có đăng nhập hệ thống (~/.codex) để chuyển thành managed.".to_string()
        })?;
    let id = uuid_v4();
    let root = ensure_accounts_root()?;
    let home = root.join(&id);
    match std::fs::symlink_metadata(&home) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error.to_string()),
        Ok(_) => return Err("Codex account home đã tồn tại ngoài dự kiến".to_string()),
    }
    std::fs::create_dir(&home).map_err(|e| e.to_string())?;
    let validated_path = validate_managed_home_with_identity(&home)?
        .ok_or_else(|| "Codex account home mới đã biến mất".to_string())?;
    let destination_binding = bind_managed_home_directory(
        &id,
        &validated_path.canonical_home,
        &validated_path.root_metadata,
        &validated_path.home_metadata,
    )
    .ok_or_else(|| "Không thể bind thư mục account Codex mới".to_string())?;
    let destination_outcome =
        crate::platform::atomic_file::write_private_json_atomic_if_matches_at::<serde_json::Value>(
            &destination_binding.home,
            OsStr::new(AUTH_FILE_NAME),
            &source.bytes,
            None,
        );
    if !matches!(
        destination_outcome,
        Ok(crate::platform::atomic_file::ConditionalWriteOutcome::Written)
    ) {
        let error = destination_outcome
            .err()
            .map(|error| error.to_string())
            .unwrap_or_else(|| "Codex auth mới đã xuất hiện ngoài dự kiến".to_string());
        return Err(cleanup_uncommitted_managed_binding(
            &destination_binding,
            &id,
            error,
        ));
    }
    after_staging();

    let account = CodexAccount {
        id: id.clone(),
        email: email_from_auth_bytes(&source.bytes),
        is_system: false,
        home_path: Some(home.to_string_lossy().to_string()),
    };
    let (root_device, root_inode) = destination_binding.root.identity_parts();
    let (home_device, home_inode) = destination_binding.home.identity_parts();
    entries.push(Entry {
        id: id.clone(),
        email: account.email.clone(),
        home_path: home.to_string_lossy().to_string(),
        root_device: Some(root_device),
        root_inode: Some(root_inode),
        home_device: Some(home_device),
        home_inode: Some(home_inode),
    });
    // Metadata is the promotion commit point. Hold the same CAS lock as a
    // provider refresh while revalidating the exact source revision + bytes,
    // so either the refresh wins and this staged home is discarded, or this
    // promotion commits from a source that is still current.
    let committed = with_current_auth_file_at(
        &source.directory,
        MAX_ACCOUNT_STATE_BYTES,
        source.revision,
        &source.bytes,
        || {
            if !managed_binding_is_current(&id, &destination_binding) {
                return Err(std::io::Error::other(
                    "Codex account root/home đã đổi trước metadata commit",
                ));
            }
            persist(&entries).map_err(std::io::Error::other)
        },
    );
    match committed {
        Ok(Some(())) => Ok(account),
        Ok(None) => Err(cleanup_uncommitted_managed_binding(
            &destination_binding,
            &id,
            "Codex auth hệ thống đã thay đổi trong lúc lưu account; vui lòng thử lại.".to_string(),
        )),
        Err(error) => Err(cleanup_uncommitted_managed_binding(
            &destination_binding,
            &id,
            error.to_string(),
        )),
    }
}

fn managed_binding_is_current(id: &str, binding: &BoundManagedHome) -> bool {
    let Some(root) = accounts_root_dir() else {
        return false;
    };
    let Ok(root_metadata) = std::fs::symlink_metadata(root) else {
        return false;
    };
    binding.root.matches_metadata(&root_metadata)
        && binding
            .root
            .child_directory_has_identity(OsStr::new(id), binding.home.identity())
}

fn cleanup_uncommitted_managed_binding(
    binding: &BoundManagedHome,
    id: &str,
    error: String,
) -> String {
    if !binding
        .root
        .child_directory_has_identity(OsStr::new(id), binding.home.identity())
    {
        return format!("{error}; không thể xác minh credential chưa đăng ký để dọn");
    }
    match binding
        .home
        .remove_file_if_present(OsStr::new(AUTH_FILE_NAME))
    {
        Ok(()) => error,
        Err(cleanup_error) => {
            format!("{error}; không thể dọn credential chưa đăng ký: {cleanup_error}")
        }
    }
}

/// Removes a managed account's home directory and metadata entry. No-op for
/// the system account (mirrors Swift's `guard id != "system"`). Falls the
/// active selection back to `"system"` if the removed account was active.
pub fn remove(id: &str) -> Result<(), String> {
    remove_with_stage_hook(id, || {})
}

fn remove_with_stage_hook(id: &str, after_metadata_commit: impl FnOnce()) -> Result<(), String> {
    if id == SYSTEM_ID {
        return Ok(());
    }
    let _guard = ACCOUNT_STORE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let original_entries = load_stored_for_mutation()?.accounts;
    let matching_entry = original_entries.iter().find(|entry| entry.id == id);
    let bound_home = if let Some(entry) = matching_entry {
        let home =
            managed_home_for_id(id).ok_or_else(|| "Codex account id không an toàn".to_string())?;
        if let Some(validated_path) = validate_managed_home_with_identity(&home)? {
            let binding = bind_managed_home_directory(
                id,
                &validated_path.canonical_home,
                &validated_path.root_metadata,
                &validated_path.home_metadata,
            )
            .ok_or_else(|| "Không thể bind thư mục account Codex cần xóa".to_string())?;
            entry_identity_matches_binding(entry, &binding).then_some(binding)
        } else {
            None
        }
    } else {
        None
    };
    let entries: Vec<Entry> = original_entries
        .iter()
        .filter(|entry| entry.id != id)
        .cloned()
        .collect();
    persist(&entries)?;
    after_metadata_commit();
    let mut post_commit_errors = Vec::new();
    if let Some(binding) = bound_home {
        invalidate_auth_directory(&binding.home);
        if let Err(error) = binding
            .home
            .remove_file_if_present(OsStr::new(AUTH_FILE_NAME))
        {
            post_commit_errors.push(format!("không thể dọn credential: {error}"));
        }
    }
    if active_id() == id {
        if let Err(error) = set_active(SYSTEM_ID) {
            post_commit_errors.push(format!("không thể lưu account fallback: {error}"));
        }
    }
    if let Err(error) = prune_snapshot(id) {
        post_commit_errors.push(format!("không thể xóa quota snapshot: {error}"));
    }
    if !post_commit_errors.is_empty() {
        return Err(format!(
            "Account đã được xóa khỏi metadata; {}",
            post_commit_errors.join("; ")
        ));
    }
    Ok(())
}

fn ensure_accounts_root() -> Result<PathBuf, String> {
    let root = accounts_root_dir()
        .ok_or_else(|| "Không xác định được thư mục account Codex".to_string())?;
    match std::fs::symlink_metadata(&root) {
        Ok(metadata) if metadata.is_dir() && !metadata_is_link_like(&metadata) => return Ok(root),
        Ok(_) => return Err("Từ chối dùng thư mục account symlink/reparse point".to_string()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error.to_string()),
    }
    crate::platform::atomic_file::ensure_private_directory(&root).map_err(|e| e.to_string())?;
    let metadata = std::fs::symlink_metadata(&root).map_err(|e| e.to_string())?;
    if !metadata.is_dir() || metadata_is_link_like(&metadata) {
        return Err("Từ chối dùng thư mục account symlink/reparse point".to_string());
    }
    Ok(root)
}

fn validate_managed_home_with_identity(
    home: &Path,
) -> Result<Option<ValidatedManagedPath>, String> {
    let root = accounts_root_dir()
        .ok_or_else(|| "Không xác định được thư mục account Codex".to_string())?;
    let root_metadata = std::fs::symlink_metadata(&root).map_err(|e| e.to_string())?;
    if metadata_is_link_like(&root_metadata) {
        return Err("Từ chối xóa qua thư mục account symlink/reparse point".to_string());
    }
    let metadata = match std::fs::symlink_metadata(home) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.to_string()),
    };
    if metadata_is_link_like(&metadata) {
        return Err("Từ chối xóa Codex account qua symlink/reparse point".to_string());
    }
    let canonical_root = std::fs::canonicalize(&root).map_err(|e| e.to_string())?;
    let canonical_home = std::fs::canonicalize(home).map_err(|e| e.to_string())?;
    if canonical_home == canonical_root || !canonical_home.starts_with(&canonical_root) {
        return Err("Codex account path nằm ngoài thư mục được quản lý".to_string());
    }
    for entry in walkdir::WalkDir::new(&canonical_home).follow_links(false) {
        let entry = entry.map_err(|e| e.to_string())?;
        let metadata = std::fs::symlink_metadata(entry.path()).map_err(|e| e.to_string())?;
        if metadata_is_link_like(&metadata) {
            return Err("Từ chối xóa Codex account chứa symlink/reparse point".to_string());
        }
    }
    Ok(Some(ValidatedManagedPath {
        canonical_home,
        root_metadata,
        home_metadata: metadata,
    }))
}

fn metadata_is_link_like(metadata: &std::fs::Metadata) -> bool {
    if metadata.file_type().is_symlink() {
        return true;
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        return metadata.file_attributes() & 0x400 != 0;
    }
    #[cfg(not(windows))]
    false
}

/// Minimal UUID v4 generator (no extra crate dependency) — format matches
/// `UUID().uuidString` closely enough for a directory/account name; only
/// uniqueness matters here, not RFC-strict compliance. Shared with the
/// freemodel account store.
pub(crate) fn uuid_v4() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
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
    use crate::providers::QuotaWindow;

    // Shared process-wide lock (config.rs) — freemodel_accounts tests touch
    // the same BIRDNION_CONFIG env var.
    use crate::config::TEST_ENV_LOCK as ENV_LOCK;

    fn temp_config_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "birdnion-codex-accounts-test-{tag}-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn identity_bound_entry(id: &str, home: &Path) -> Entry {
        let validated = validate_managed_home_with_identity(home).unwrap().unwrap();
        let binding = bind_managed_home_directory(
            id,
            &validated.canonical_home,
            &validated.root_metadata,
            &validated.home_metadata,
        )
        .unwrap();
        let (root_device, root_inode) = binding.root.identity_parts();
        let (home_device, home_inode) = binding.home.identity_parts();
        Entry {
            id: id.to_string(),
            email: None,
            home_path: home.to_string_lossy().to_string(),
            root_device: Some(root_device),
            root_inode: Some(root_inode),
            home_device: Some(home_device),
            home_inode: Some(home_inode),
        }
    }

    fn quota_status(remaining_pct: i32, checked_at: i64) -> ProviderStatus {
        ProviderStatus {
            id: "codex".into(),
            display_name: "Codex".into(),
            windows: vec![QuotaWindow {
                label: "Week".into(),
                used_pct: 100 - remaining_pct,
                remaining_pct,
                subtitle: None,
                resets_at: None,
                window_seconds: None,
                semantic_key: None,
                semantic_kind: None,
            }],
            last_updated: checked_at,
            ..Default::default()
        }
    }

    #[test]
    fn guarded_read_recovers_claimed_auth_after_process_crash() {
        let base = temp_config_dir("auth-crash-recovery");
        let path = base.join("auth.json");
        let backup = base.join("auth.json.birdnion-cas-backup");
        let credential = br#"{"tokens":{"access_token":"survives","refresh_token":"survives-r"}}"#;
        std::fs::write(&backup, credential).unwrap();

        let guarded = read_auth_file_guarded(&path, MAX_ACCOUNT_STATE_BYTES)
            .unwrap()
            .expect("normal auth read must heal the claimed file");

        assert_eq!(guarded.bytes, credential);
        assert_eq!(std::fs::read(&path).unwrap(), credential);
        assert!(!backup.try_exists().unwrap());
        let _ = std::fs::remove_dir_all(base);
    }

    #[test]
    fn quota_snapshots_missing_file_is_empty() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config_dir("snapshot-missing");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));

        assert!(quota_snapshots().is_empty());

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(base);
    }

    #[test]
    fn quota_snapshot_roundtrip_success() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config_dir("snapshot-roundtrip");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));

        save_snapshot("account-1", &quota_status(42, 123)).unwrap();
        let snapshot = quota_snapshots().remove("account-1").unwrap();
        assert_eq!(snapshot.label.as_deref(), Some("Week"));
        assert_eq!(snapshot.remaining_pct, Some(42));
        assert_eq!(snapshot.last_checked, 123);
        assert_eq!(snapshot.error_kind, None);

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(base);
    }

    #[cfg(unix)]
    #[test]
    fn snapshot_store_rejects_symlink_fifo_and_oversized_state() {
        use std::ffi::CString;
        use std::os::unix::ffi::OsStrExt;
        use std::os::unix::fs::symlink;

        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config_dir("snapshot-special");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));
        let snapshots = snapshots_path().unwrap();
        let target = base.join("snapshot-target.json");
        std::fs::write(&target, b"sentinel").unwrap();
        symlink(&target, &snapshots).unwrap();
        assert!(quota_snapshots().is_empty());
        assert!(save_snapshot("account-1", &quota_status(42, 123)).is_err());
        assert_eq!(std::fs::read(&target).unwrap(), b"sentinel");

        std::fs::remove_file(&snapshots).unwrap();
        let fifo_path = CString::new(snapshots.as_os_str().as_bytes()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(fifo_path.as_ptr(), 0o600) }, 0);
        assert!(quota_snapshots().is_empty());

        std::fs::remove_file(&snapshots).unwrap();
        let oversized = std::fs::File::create(&snapshots).unwrap();
        oversized
            .set_len((MAX_ACCOUNT_STATE_BYTES + 1) as u64)
            .unwrap();
        assert!(quota_snapshots().is_empty());

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(base);
    }

    #[test]
    fn failed_snapshot_preserves_last_good_quota_and_updates_health() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config_dir("snapshot-error");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));

        save_snapshot("account-1", &quota_status(55, 100)).unwrap();
        let mut failure = ProviderStatus::failure(
            "codex",
            "Codex",
            "Token Codex hết hạn — chạy codex để đăng nhập lại",
        );
        failure.last_updated = 200;
        save_snapshot("account-1", &failure).unwrap();

        let snapshot = quota_snapshots().remove("account-1").unwrap();
        assert_eq!(snapshot.label.as_deref(), Some("Week"));
        assert_eq!(snapshot.remaining_pct, Some(55));
        assert_eq!(snapshot.last_checked, 200);
        assert_eq!(
            snapshot.error_kind.as_deref(),
            Some("tokenInvalidOrMissing")
        );

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(base);
    }

    #[test]
    fn remove_prunes_quota_snapshot() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config_dir("snapshot-prune");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));

        save_snapshot("managed-1", &quota_status(70, 100)).unwrap();
        assert!(quota_snapshots().contains_key("managed-1"));
        remove("managed-1").unwrap();
        assert!(!quota_snapshots().contains_key("managed-1"));

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(base);
    }

    #[test]
    fn reconcile_dedupes_matching_email_case_insensitive() {
        let system = CodexAccount {
            id: "system".into(),
            email: Some("a@b.com".into()),
            is_system: true,
            home_path: None,
        };
        let managed = vec![
            CodexAccount {
                id: "1".into(),
                email: Some("A@B.com".into()),
                is_system: false,
                home_path: Some("/x".into()),
            },
            CodexAccount {
                id: "2".into(),
                email: Some("c@d.com".into()),
                is_system: false,
                home_path: Some("/y".into()),
            },
        ];
        let out = reconcile(system, managed);
        assert_eq!(out.len(), 2);
        assert_eq!(out[1].id, "2");
    }

    #[test]
    fn reconcile_keeps_unknown_email_accounts() {
        let system = CodexAccount {
            id: "system".into(),
            email: None,
            is_system: true,
            home_path: None,
        };
        let managed = vec![
            CodexAccount {
                id: "1".into(),
                email: None,
                is_system: false,
                home_path: Some("/x".into()),
            },
            CodexAccount {
                id: "2".into(),
                email: None,
                is_system: false,
                home_path: Some("/y".into()),
            },
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
        assert!(PathBuf::from(promoted.home_path.as_ref().unwrap())
            .join("auth.json")
            .is_file());

        let after = all_accounts();
        assert_eq!(after.len(), 2);

        // Switch active -> the promoted account's auth.json resolves.
        set_active(&promoted.id).unwrap();
        assert_eq!(active_id(), promoted.id);
        let canonical_managed_home =
            std::fs::canonicalize(promoted.home_path.as_ref().unwrap()).unwrap();
        assert_eq!(
            active_auth_path(),
            Some(canonical_managed_home.join("auth.json"))
        );

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
    fn malformed_metadata_blocks_promote_without_orphaning_credentials() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config_dir("malformed-promote");
        let codex_home = base.join("codex-home");
        std::fs::create_dir_all(&codex_home).unwrap();
        std::fs::write(
            codex_home.join("auth.json"),
            r#"{"tokens":{"access_token":"at","refresh_token":"rt"}}"#,
        )
        .unwrap();
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));
        std::env::set_var("CODEX_HOME", &codex_home);
        let metadata = metadata_path().unwrap();
        std::fs::write(&metadata, b"{malformed").unwrap();

        assert!(promote_system().is_err());
        assert_eq!(std::fs::read(&metadata).unwrap(), b"{malformed");
        assert!(!accounts_root_dir().unwrap().exists());

        std::env::remove_var("BIRDNION_CONFIG");
        std::env::remove_var("CODEX_HOME");
        let _ = std::fs::remove_dir_all(base);
    }

    #[test]
    fn concurrent_system_refresh_blocks_stale_promotion_and_cleans_staged_home() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config_dir("concurrent-promotion-cas");
        let codex_home = base.join("codex-home");
        std::fs::create_dir_all(&codex_home).unwrap();
        let system_auth = codex_home.join("auth.json");
        let original = br#"{"tokens":{"access_token":"old","refresh_token":"old-rt"}}"#;
        let refreshed = br#"{"tokens":{"access_token":"new","refresh_token":"new-rt"}}"#;
        std::fs::write(&system_auth, original).unwrap();
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));
        std::env::set_var("CODEX_HOME", &codex_home);

        let refresh_guard = read_auth_file_guarded(&system_auth, MAX_ACCOUNT_STATE_BYTES)
            .unwrap()
            .unwrap();
        let staged = std::sync::Arc::new(std::sync::Barrier::new(2));
        let refresh_committed = std::sync::Arc::new(std::sync::Barrier::new(2));
        let promotion_staged = staged.clone();
        let promotion_refresh_committed = refresh_committed.clone();
        let promotion = std::thread::spawn(move || {
            promote_system_after_staging(|| {
                promotion_staged.wait();
                promotion_refresh_committed.wait();
            })
        });

        staged.wait();
        let committed = with_current_auth_file(
            &system_auth,
            MAX_ACCOUNT_STATE_BYTES,
            refresh_guard.revision,
            &refresh_guard.bytes,
            || {
                crate::platform::atomic_file::write_private_json_atomic::<serde_json::Value>(
                    &system_auth,
                    refreshed,
                )
            },
        )
        .unwrap();
        assert_eq!(committed, Some(()));
        refresh_committed.wait();

        assert!(promotion.join().unwrap().is_err());
        assert_eq!(std::fs::read(&system_auth).unwrap(), refreshed);
        assert!(managed_accounts().is_empty());
        assert!(!metadata_path().unwrap().exists());
        let staged_home = std::fs::read_dir(accounts_root_dir().unwrap())
            .unwrap()
            .next()
            .unwrap()
            .unwrap()
            .path();
        assert_eq!(std::fs::read_dir(staged_home).unwrap().count(), 0);

        std::env::remove_var("BIRDNION_CONFIG");
        std::env::remove_var("CODEX_HOME");
        let _ = std::fs::remove_dir_all(base);
    }

    #[test]
    fn managed_root_replacement_before_promotion_commit_cannot_retarget_metadata() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config_dir("promotion-root-replacement");
        let support = base.join("support");
        let codex_home = base.join("system-codex");
        std::fs::create_dir_all(&support).unwrap();
        std::fs::create_dir(&codex_home).unwrap();
        std::fs::write(
            codex_home.join(AUTH_FILE_NAME),
            br#"{"tokens":{"access_token":"system","refresh_token":"system-r"}}"#,
        )
        .unwrap();
        std::env::set_var("BIRDNION_CONFIG", support.join("settings.json"));
        std::env::set_var("CODEX_HOME", &codex_home);

        let root = accounts_root_dir().unwrap();
        let detached_root = support.join("detached-promotion-root");
        let mut replacement_auth = None;
        let result = promote_system_after_staging(|| {
            let id = std::fs::read_dir(&root)
                .unwrap()
                .next()
                .unwrap()
                .unwrap()
                .file_name();
            std::fs::rename(&root, &detached_root).unwrap();
            let replacement_home = root.join(id);
            std::fs::create_dir_all(&replacement_home).unwrap();
            let auth = replacement_home.join(AUTH_FILE_NAME);
            std::fs::write(&auth, b"attacker-credential").unwrap();
            replacement_auth = Some(auth);
        });

        assert!(result.is_err());
        assert!(managed_accounts().is_empty());
        assert_eq!(
            std::fs::read(replacement_auth.unwrap()).unwrap(),
            b"attacker-credential"
        );
        let detached_home = std::fs::read_dir(&detached_root)
            .unwrap()
            .next()
            .unwrap()
            .unwrap()
            .path();
        assert_eq!(std::fs::read_dir(detached_home).unwrap().count(), 0);

        std::env::remove_var("CODEX_HOME");
        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(base);
    }

    #[test]
    fn promoted_identity_rejects_root_replacement_after_metadata_commit() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config_dir("promotion-post-commit-root-replacement");
        let support = base.join("support");
        let codex_home = base.join("system-codex");
        std::fs::create_dir_all(&support).unwrap();
        std::fs::create_dir(&codex_home).unwrap();
        std::fs::write(
            codex_home.join(AUTH_FILE_NAME),
            br#"{"tokens":{"access_token":"system","refresh_token":"system-r"}}"#,
        )
        .unwrap();
        std::env::set_var("BIRDNION_CONFIG", support.join("settings.json"));
        std::env::set_var("CODEX_HOME", &codex_home);

        let promoted = promote_system().unwrap();
        set_active(&promoted.id).unwrap();
        let root = accounts_root_dir().unwrap();
        let detached_root = support.join("detached-post-commit-root");
        std::fs::rename(&root, &detached_root).unwrap();
        let replacement_auth = root.join(&promoted.id).join(AUTH_FILE_NAME);
        std::fs::create_dir_all(root.join(&promoted.id)).unwrap();
        std::fs::write(&replacement_auth, b"attacker-credential").unwrap();

        assert!(active_selection_checked().is_err());
        assert_eq!(
            std::fs::read(detached_root.join(&promoted.id).join(AUTH_FILE_NAME)).unwrap(),
            br#"{"tokens":{"access_token":"system","refresh_token":"system-r"}}"#
        );
        assert_eq!(
            std::fs::read(&replacement_auth).unwrap(),
            b"attacker-credential"
        );

        std::env::remove_var("CODEX_HOME");
        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(base);
    }

    #[test]
    fn promotion_cas_read_error_cleans_staged_home_without_metadata() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config_dir("promotion-cas-error");
        let codex_home = base.join("codex-home");
        std::fs::create_dir_all(&codex_home).unwrap();
        let system_auth = codex_home.join("auth.json");
        std::fs::write(
            &system_auth,
            br#"{"tokens":{"access_token":"old","refresh_token":"old-rt"}}"#,
        )
        .unwrap();
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));
        std::env::set_var("CODEX_HOME", &codex_home);

        let source_to_break = system_auth.clone();
        let result = promote_system_after_staging(|| {
            std::fs::remove_file(&source_to_break).unwrap();
            std::fs::create_dir(&source_to_break).unwrap();
        });

        assert!(result.is_err());
        assert!(managed_accounts().is_empty());
        assert!(!metadata_path().unwrap().exists());
        let staged_home = std::fs::read_dir(accounts_root_dir().unwrap())
            .unwrap()
            .next()
            .unwrap()
            .unwrap()
            .path();
        assert_eq!(std::fs::read_dir(staged_home).unwrap().count(), 0);

        std::env::remove_var("BIRDNION_CONFIG");
        std::env::remove_var("CODEX_HOME");
        let _ = std::fs::remove_dir_all(base);
    }

    #[test]
    fn malformed_metadata_blocks_remove_before_managed_home_changes() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config_dir("malformed-remove");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));
        let root = accounts_root_dir().unwrap();
        std::fs::create_dir_all(&root).unwrap();
        let id = "11111111-1111-4111-8111-111111111111";
        let home = root.join(id);
        std::fs::create_dir(&home).unwrap();
        let auth = home.join("auth.json");
        std::fs::write(&auth, b"credential-bytes").unwrap();
        let metadata = metadata_path().unwrap();
        std::fs::write(&metadata, b"{malformed").unwrap();

        assert!(remove(id).is_err());
        assert_eq!(std::fs::read(&metadata).unwrap(), b"{malformed");
        assert_eq!(std::fs::read(&auth).unwrap(), b"credential-bytes");

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(base);
    }

    #[test]
    fn managed_root_replacement_after_remove_commit_never_deletes_replacement() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config_dir("remove-root-replacement");
        let support = base.join("support");
        std::fs::create_dir_all(&support).unwrap();
        std::env::set_var("BIRDNION_CONFIG", support.join("settings.json"));

        let id = "11111111-1111-4111-8111-111111111111";
        let root = accounts_root_dir().unwrap();
        let home = root.join(id);
        std::fs::create_dir_all(&home).unwrap();
        std::fs::write(home.join(AUTH_FILE_NAME), b"original-credential").unwrap();
        persist(&[identity_bound_entry(id, &home)]).unwrap();

        let detached_root = support.join("detached-removal-root");
        let replacement_auth = root.join(id).join(AUTH_FILE_NAME);
        remove_with_stage_hook(id, || {
            std::fs::rename(&root, &detached_root).unwrap();
            std::fs::create_dir_all(root.join(id)).unwrap();
            std::fs::write(&replacement_auth, b"attacker-credential").unwrap();
        })
        .unwrap();

        assert!(managed_accounts().is_empty());
        assert_eq!(
            std::fs::read(&replacement_auth).unwrap(),
            b"attacker-credential"
        );
        assert_eq!(
            std::fs::read_dir(detached_root.join(id)).unwrap().count(),
            0
        );

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(base);
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
    fn system_auth_path_rejects_managed_path_roles_and_accepts_disjoint_home() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config_dir("system-path-roles");
        let support = base.join("support");
        std::fs::create_dir_all(&support).unwrap();
        std::env::set_var("BIRDNION_CONFIG", support.join("settings.json"));
        let managed_root = accounts_root_dir().unwrap();
        std::fs::create_dir_all(&managed_root).unwrap();

        let disjoint = base.join("system-codex");
        std::fs::create_dir(&disjoint).unwrap();
        std::env::set_var("CODEX_HOME", &disjoint);
        assert_eq!(
            system_auth_path(),
            Some(std::fs::canonicalize(&disjoint).unwrap().join("auth.json"))
        );

        for alias in [
            managed_root.clone(),
            managed_root.join("managed-account"),
            support.clone(),
            managed_root.join("nested").join(".."),
        ] {
            std::env::set_var("CODEX_HOME", alias);
            assert!(system_auth_path().is_none());
        }

        #[cfg(unix)]
        {
            let alias = base.join("managed-root-alias");
            std::os::unix::fs::symlink(&managed_root, &alias).unwrap();
            std::env::set_var("CODEX_HOME", alias);
            assert!(system_auth_path().is_none());
        }

        std::env::remove_var("CODEX_HOME");
        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(base);
    }

    #[test]
    fn windows_path_role_comparison_handles_mixed_case_nonexistent_suffixes() {
        let managed = Path::new("/support/codex-accounts");
        let mixed_case_child = Path::new("/support/CODEX-ACCOUNTS/account-a");
        let sibling = Path::new("/support/codex-accounts-backup");

        assert!(path_component_prefix(mixed_case_child, managed, true));
        assert!(path_component_prefix(managed, mixed_case_child, true) == false);
        assert!(!path_component_prefix(sibling, managed, true));
        assert!(!path_component_prefix(mixed_case_child, managed, false));
    }

    #[test]
    fn active_selection_rejects_mismatched_managed_metadata_path() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config_dir("managed-metadata-path");
        let support = base.join("support");
        let system_home = base.join("system-home");
        std::fs::create_dir_all(&support).unwrap();
        std::fs::create_dir(&system_home).unwrap();
        std::env::set_var("BIRDNION_CONFIG", support.join("settings.json"));
        std::env::set_var("CODEX_HOME", &system_home);

        let id = "11111111-1111-4111-8111-111111111111";
        let root = accounts_root_dir().unwrap();
        let home = root.join(id);
        std::fs::create_dir_all(&home).unwrap();
        std::fs::write(home.join("auth.json"), b"managed-credential").unwrap();
        persist(&[Entry {
            id: id.to_string(),
            email: None,
            home_path: system_home.to_string_lossy().to_string(),
            ..Entry::default()
        }])
        .unwrap();
        set_active(id).unwrap();

        assert!(active_selection_checked().is_err());
        let selection = active_selection();
        assert_eq!(selection.account_id, id);
        assert_eq!(selection.auth_path, None);

        std::env::remove_var("CODEX_HOME");
        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(base);
    }

    #[test]
    fn managed_root_replacement_after_validation_cannot_retarget_selection() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config_dir("managed-root-replacement");
        let support = base.join("support");
        std::fs::create_dir_all(&support).unwrap();
        std::env::set_var("BIRDNION_CONFIG", support.join("settings.json"));

        let id = "11111111-1111-4111-8111-111111111111";
        let root = accounts_root_dir().unwrap();
        let home = root.join(id);
        std::fs::create_dir_all(&home).unwrap();
        let original_auth = home.join(AUTH_FILE_NAME);
        std::fs::write(&original_auth, b"original-credential").unwrap();
        persist(&[identity_bound_entry(id, &home)]).unwrap();
        set_active(id).unwrap();

        let detached_root = support.join("detached-codex-accounts");
        let replacement_auth = root.join(id).join(AUTH_FILE_NAME);
        let selection = validated_active_managed_home_with_hook(id, || {
            std::fs::rename(&root, &detached_root).unwrap();
            std::fs::create_dir_all(root.join(id)).unwrap();
            std::fs::write(&replacement_auth, b"attacker-credential").unwrap();
        });

        assert!(selection.is_none());
        assert_eq!(
            std::fs::read(detached_root.join(id).join(AUTH_FILE_NAME)).unwrap(),
            b"original-credential"
        );
        assert_eq!(
            std::fs::read(&replacement_auth).unwrap(),
            b"attacker-credential"
        );

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(base);
    }

    #[cfg(unix)]
    #[test]
    fn active_selection_rejects_managed_root_and_home_symlink_routes() {
        use std::os::unix::fs::symlink;

        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config_dir("managed-parent-links");
        let support = base.join("support");
        let system_home = base.join("system-home");
        std::fs::create_dir_all(&support).unwrap();
        std::fs::create_dir(&system_home).unwrap();
        std::env::set_var("BIRDNION_CONFIG", support.join("settings.json"));
        std::env::set_var("CODEX_HOME", &system_home);

        let id = "11111111-1111-4111-8111-111111111111";
        let root = accounts_root_dir().unwrap();
        let home = root.join(id);
        persist(&[Entry {
            id: id.to_string(),
            email: None,
            home_path: home.to_string_lossy().to_string(),
            ..Entry::default()
        }])
        .unwrap();
        set_active(id).unwrap();

        let outside_root = base.join("outside-root");
        let outside_root_home = outside_root.join(id);
        std::fs::create_dir_all(&outside_root_home).unwrap();
        let root_target_auth = outside_root_home.join("auth.json");
        std::fs::write(&root_target_auth, b"root-target").unwrap();
        symlink(&outside_root, &root).unwrap();
        assert!(active_selection_checked().is_err());
        let root_link_selection = active_selection();
        assert_eq!(root_link_selection.account_id, id);
        assert_eq!(root_link_selection.auth_path, None);
        assert_eq!(std::fs::read(&root_target_auth).unwrap(), b"root-target");

        std::fs::remove_file(&root).unwrap();
        std::fs::create_dir(&root).unwrap();
        let outside_home = base.join("outside-home");
        std::fs::create_dir(&outside_home).unwrap();
        let home_target_auth = outside_home.join("auth.json");
        std::fs::write(&home_target_auth, b"home-target").unwrap();
        symlink(&outside_home, &home).unwrap();
        assert!(active_selection_checked().is_err());
        let home_link_selection = active_selection();
        assert_eq!(home_link_selection.account_id, id);
        assert_eq!(home_link_selection.auth_path, None);
        assert_eq!(std::fs::read(&home_target_auth).unwrap(), b"home-target");

        std::fs::remove_file(&home).unwrap();
        std::env::remove_var("CODEX_HOME");
        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(base);
    }

    #[test]
    fn managed_auth_alias_cannot_be_promoted_or_selected_as_system() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config_dir("managed-system-alias");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));
        let managed_root = accounts_root_dir().unwrap();
        std::fs::create_dir_all(&managed_root).unwrap();
        std::fs::write(
            managed_root.join("auth.json"),
            br#"{"tokens":{"access_token":"managed","refresh_token":"managed-r"}}"#,
        )
        .unwrap();
        std::env::set_var("CODEX_HOME", &managed_root);

        set_active(SYSTEM_ID).unwrap();
        assert!(system_auth_path().is_none());
        assert_eq!(active_selection().auth_path, None);
        assert!(promote_system().is_err());
        assert!(managed_accounts().is_empty());

        std::env::remove_var("CODEX_HOME");
        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(base);
    }

    #[test]
    fn active_auth_path_fails_closed_when_account_vanished() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config_dir("vanished");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));
        std::env::set_var("HOME", base.join("home"));
        std::env::remove_var("CODEX_HOME");
        set_active("nonexistent-uuid").unwrap();
        assert!(active_selection_checked().is_err());
        let selection = active_selection();
        assert_eq!(selection.account_id, "nonexistent-uuid");
        assert_eq!(selection.auth_path, None);
        std::env::remove_var("BIRDNION_CONFIG");
        std::env::remove_var("HOME");
        let _ = std::fs::remove_dir_all(&base);
    }
}
