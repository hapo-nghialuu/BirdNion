//! Hiyo multi-key store — same shape as the ElevenLabs key store:
//! managed API keys live in their own file
//! (`~/.config/birdnion/hiyo-keys.json`, chmod 0600); only the active
//! key id rides in settings.json (`active_hiyo_key`).
//!
//! Legacy single `providers.hiyo.apiKey` is imported once when the
//! multi-key store is empty.

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

use crate::codex_accounts::uuid_v4;
use crate::config;

/// UI-facing key descriptor — the raw API key is NEVER sent to the frontend.
#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct HiyoKey {
    pub id: String,
    pub label: Option<String>,
    pub preview: String,
}

#[derive(Deserialize, Serialize, Clone, Debug, Default)]
struct Entry {
    id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    label: Option<String>,
    api_key: String,
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
        .join("hiyo-keys.json")
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
    let json = serde_json::to_string_pretty(&Stored {
        accounts: entries.to_vec(),
    })
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

fn preview_of(key: &str) -> String {
    key.chars().take(8).collect()
}

fn to_key(e: &Entry) -> HiyoKey {
    HiyoKey {
        id: e.id.clone(),
        label: e.label.clone(),
        preview: preview_of(&e.api_key),
    }
}

/// One-time import of legacy `providers.hiyo.apiKey` when the multi-key
/// file has never been created. An empty list after the user deleted every
/// key is left empty (no re-import loop).
pub fn ensure_legacy_import() {
    if metadata_path().exists() {
        return;
    }
    let settings = config::load();
    let Some(provider) = settings.providers.iter().find(|p| p.id == "hiyo") else {
        return;
    };
    let Some(legacy) = config::api_key(provider) else {
        return;
    };
    let entry = Entry {
        id: uuid_v4(),
        label: provider.account_label.clone(),
        api_key: legacy,
    };
    let active_id = entry.id.clone();
    if persist(&[entry]).is_ok() {
        let _ = set_active(&active_id);
    }
}

/// Active key id from settings.json. Falls back to the first stored key.
pub fn active_id() -> Option<String> {
    ensure_legacy_import();
    let stored = load_stored().accounts;
    if stored.is_empty() {
        return None;
    }
    let settings = config::load();
    if let Some(id) = settings.active_hiyo_key {
        if stored.iter().any(|e| e.id == id) {
            return Some(id);
        }
    }
    stored.first().map(|e| e.id.clone())
}

pub fn set_active(id: &str) -> Result<(), String> {
    let mut settings = config::load();
    settings.active_hiyo_key = Some(id.to_string());
    config::save(&settings)
}

/// Full API key for the active entry — `None` when the store is empty.
pub fn active_api_key() -> Option<String> {
    ensure_legacy_import();
    let id = active_id()?;
    load_stored()
        .accounts
        .into_iter()
        .find(|e| e.id == id)
        .map(|e| e.api_key)
}

/// Display label for the active key (custom label or key preview).
pub fn active_display_label() -> Option<String> {
    let id = active_id()?;
    let entry = load_stored().accounts.into_iter().find(|e| e.id == id)?;
    if let Some(label) = entry.label.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
        return Some(label.to_string());
    }
    Some(preview_of(&entry.api_key))
}

/// All managed keys (no secrets).
pub fn all_keys() -> Vec<HiyoKey> {
    ensure_legacy_import();
    load_stored().accounts.iter().map(to_key).collect()
}

/// Stores a new managed API key. Sets active when this is the first key.
pub fn add(api_key: &str, label: Option<&str>) -> Result<HiyoKey, String> {
    let api_key = api_key.trim();
    if api_key.is_empty() {
        return Err("API key trống".to_string());
    }
    let entry = Entry {
        id: uuid_v4(),
        label: label.map(str::trim).filter(|s| !s.is_empty()).map(String::from),
        api_key: api_key.to_string(),
    };
    let key = to_key(&entry);
    let mut entries = load_stored().accounts;
    let is_first = entries.is_empty();
    entries.push(entry);
    persist(&entries)?;
    if is_first || active_id().is_none() {
        set_active(&key.id)?;
    }
    Ok(key)
}

/// Removes a managed key; falls active back to the first remaining key.
pub fn remove(id: &str) -> Result<(), String> {
    let previous = active_id();
    let remaining: Vec<Entry> = load_stored()
        .accounts
        .into_iter()
        .filter(|e| e.id != id)
        .collect();
    persist(&remaining)?;
    if previous.as_deref() == Some(id) {
        if let Some(first) = remaining.first() {
            set_active(&first.id)?;
        } else {
            let mut settings = config::load();
            settings.active_hiyo_key = None;
            config::save(&settings)?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::TEST_ENV_LOCK as ENV_LOCK;

    fn temp_config(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "birdnion-hiyo-keys-{tag}-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn add_switch_remove_roundtrip() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config("roundtrip");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));

        assert!(all_keys().is_empty());
        assert!(active_api_key().is_none());

        let k1 = add("sk-key-one-aaaaaaaa", Some("Work")).unwrap();
        assert_eq!(all_keys().len(), 1);
        assert_eq!(k1.label.as_deref(), Some("Work"));
        assert_eq!(active_api_key().as_deref(), Some("sk-key-one-aaaaaaaa"));

        let k2 = add("sk-key-two-bbbbbbbb", Some("Personal")).unwrap();
        assert_eq!(all_keys().len(), 2);
        // First key stays active until explicit switch.
        assert_eq!(active_id().as_deref(), Some(k1.id.as_str()));

        set_active(&k2.id).unwrap();
        assert_eq!(active_api_key().as_deref(), Some("sk-key-two-bbbbbbbb"));

        remove(&k2.id).unwrap();
        assert_eq!(active_id().as_deref(), Some(k1.id.as_str()));
        assert_eq!(all_keys().len(), 1);

        remove(&k1.id).unwrap();
        assert!(all_keys().is_empty());
        assert!(active_api_key().is_none());

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn empty_key_rejected() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config("empty");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));
        assert!(add("   ", None).is_err());
        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn preview_is_first_8_chars() {
        assert_eq!(preview_of("sk-abcdefghij"), "sk-abcde");
    }
}
