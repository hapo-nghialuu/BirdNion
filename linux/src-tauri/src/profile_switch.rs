//! Credential-safe compact profile switching for the Linux popover.
//!
//! IPC receives only an opaque snapshot token. The complete stored profile is
//! compared before/after every async boundary so a delayed activation cannot
//! apply a profile that Settings changed or deleted.

use crate::claude_code;
use crate::cli_proxy::{self, ProxyRuntimeFacts};
use crate::codex_config;
use crate::config::{self, ClaudeCodeProfile, CodexProfile};
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use std::future::Future;
use std::sync::OnceLock;
use tauri::AppHandle;

static SNAPSHOT_KEY: OnceLock<[u8; 32]> = OnceLock::new();

/// Shared coordinator for every legacy or popover profile activation writer.
/// Callers must keep the guard alive through proxy prepare and target apply.
pub async fn lock_profile_activation() -> tokio::sync::MutexGuard<'static, ()> {
    cli_proxy::lock_profile_activation().await
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum ProfileAgent {
    Claude,
    Codex,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ProfileActivationRequest {
    pub profile_id: String,
    pub expected_snapshot: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ProfileSwitchRow {
    pub agent: ProfileAgent,
    pub profile_id: String,
    pub name: String,
    pub expected_snapshot: String,
    pub ready: bool,
    pub active: bool,
    pub current: bool,
    pub uses_proxy: bool,
    pub target_path: Option<String>,
    pub profile_flag: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ProfileSwitchCatalog {
    pub claude_profiles: Vec<ProfileSwitchRow>,
    pub codex_profiles: Vec<ProfileSwitchRow>,
    pub proxy: ProxyRuntimeFacts,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ProfileActivationResult {
    pub agent: ProfileAgent,
    pub profile_id: String,
    pub active: bool,
    pub current: bool,
    pub target_path: String,
    pub profile_flag: Option<String>,
    pub proxy: ProxyRuntimeFacts,
}

fn snapshot_key() -> Result<&'static [u8; 32], String> {
    if let Some(key) = SNAPSHOT_KEY.get() {
        return Ok(key);
    }
    let mut generated = [0_u8; 32];
    getrandom::getrandom(&mut generated)
        .map_err(|_| "Không tạo được snapshot bảo mật cho danh sách config".to_string())?;
    let _ = SNAPSHOT_KEY.set(generated);
    SNAPSHOT_KEY
        .get()
        .ok_or_else(|| "Không tạo được snapshot bảo mật cho danh sách config".to_string())
}

fn snapshot_token(profile: &impl Serialize) -> Result<String, String> {
    type HmacSha256 = Hmac<Sha256>;
    let bytes = serde_json::to_vec(profile).map_err(|error| error.to_string())?;
    let mut mac = <HmacSha256 as Mac>::new_from_slice(snapshot_key()?)
        .map_err(|_| "Không tạo được snapshot bảo mật cho config".to_string())?;
    mac.update(&bytes);
    Ok(hex::encode(mac.finalize().into_bytes()))
}

fn display_name(name: Option<&str>, fallback: &str) -> String {
    name.map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or(fallback)
        .to_string()
}

fn proxy_backed_current(
    applied: bool,
    uses_proxy: bool,
    proxy_running: bool,
    proxy_profile_id: Option<&str>,
    profile_id: &str,
) -> bool {
    applied && (!uses_proxy || (proxy_running && proxy_profile_id == Some(profile_id)))
}

fn codex_activation_state(selected: bool, applied: bool) -> (bool, bool) {
    (selected, applied)
}

fn claude_row(
    profile: &ClaudeCodeProfile,
    proxy: &ProxyRuntimeFacts,
) -> Result<ProfileSwitchRow, String> {
    let scope = claude_code::profile_scope(profile);
    let ready = scope.is_some() && claude_code::profile_ready(profile);
    let sync = scope
        .as_ref()
        .map(|scope| claude_code::sync_state_for_profile(profile, scope))
        .unwrap_or(claude_code::SyncState::Off);
    Ok(ProfileSwitchRow {
        agent: ProfileAgent::Claude,
        profile_id: profile.id.clone(),
        name: display_name(profile.name.as_deref(), "Config Claude"),
        expected_snapshot: snapshot_token(profile)?,
        ready,
        active: sync != claude_code::SyncState::Off,
        current: proxy_backed_current(
            sync == claude_code::SyncState::Synced,
            cli_proxy::uses_embedded_cli_proxy(profile),
            proxy.running,
            proxy.claude_profile_id.as_deref(),
            &profile.id,
        ),
        uses_proxy: cli_proxy::uses_embedded_cli_proxy(profile),
        target_path: scope.as_ref().map(|scope| {
            claude_code::target_path(scope)
                .to_string_lossy()
                .to_string()
        }),
        profile_flag: None,
    })
}

fn codex_row(profile: &CodexProfile) -> Result<ProfileSwitchRow, String> {
    let target = codex_config::target_config_path();
    let active =
        codex_config::active_profile_id(Some(&target)).as_deref() == Some(profile.id.as_str());
    let applied = codex_config::is_applied(profile, Some(&target));
    let (active, current) = codex_activation_state(active, applied);
    Ok(ProfileSwitchRow {
        agent: ProfileAgent::Codex,
        profile_id: profile.id.clone(),
        name: display_name(Some(&profile.name), "Config Codex"),
        expected_snapshot: snapshot_token(profile)?,
        ready: profile.has_upstream_configuration(),
        active,
        current,
        uses_proxy: profile.uses_embedded_cli_proxy(),
        target_path: Some(target.to_string_lossy().to_string()),
        profile_flag: codex_config::profile_flag(&profile.id, Some(&target)),
    })
}

/// Safe popover data. No base URL, API key, loopback key, or management key is
/// present; `expectedSnapshot` is a process-local keyed digest.
pub async fn profile_catalog() -> Result<ProfileSwitchCatalog, String> {
    let proxy = cli_proxy::runtime_facts().await?;
    let settings = config::load_checked()?;
    Ok(ProfileSwitchCatalog {
        claude_profiles: settings
            .claude_code_profiles
            .iter()
            .map(|profile| claude_row(profile, &proxy))
            .collect::<Result<Vec<_>, _>>()?,
        codex_profiles: settings
            .codex_profiles
            .iter()
            .map(codex_row)
            .collect::<Result<Vec<_>, _>>()?,
        proxy,
    })
}

fn expected_claude(request: &ProfileActivationRequest) -> Result<ClaudeCodeProfile, String> {
    let profile = config::load_checked()?
        .claude_code_profiles
        .into_iter()
        .find(|profile| profile.id == request.profile_id)
        .ok_or_else(|| "Config Claude đã bị xóa; mở lại danh sách rồi thử lại".to_string())?;
    if snapshot_token(&profile)? != request.expected_snapshot {
        return Err("Config Claude đã thay đổi; mở lại danh sách rồi thử lại".to_string());
    }
    config::require_current_claude_profile(&profile)
}

fn expected_codex(request: &ProfileActivationRequest) -> Result<CodexProfile, String> {
    let profile = config::load_checked()?
        .codex_profiles
        .into_iter()
        .find(|profile| profile.id == request.profile_id)
        .ok_or_else(|| "Config Codex đã bị xóa; mở lại danh sách rồi thử lại".to_string())?;
    if snapshot_token(&profile)? != request.expected_snapshot {
        return Err("Config Codex đã thay đổi; mở lại danh sách rồi thử lại".to_string());
    }
    config::require_current_codex_profile(&profile)
}

async fn prepare_then_apply<T, Check, Prepare, PrepareFuture, Apply>(
    expected: T,
    mut check: Check,
    prepare: Prepare,
    apply: Apply,
) -> Result<T, String>
where
    T: Clone,
    Check: FnMut(&T) -> Result<(), String>,
    Prepare: FnOnce(T) -> PrepareFuture,
    PrepareFuture: Future<Output = Result<T, String>>,
    Apply: FnOnce(&T) -> Result<(), String>,
{
    check(&expected)?;
    let prepared = prepare(expected).await?;
    check(&prepared)?;
    apply(&prepared)?;
    check(&prepared)?;
    Ok(prepared)
}

fn apply_claude(profile: &ClaudeCodeProfile) -> Result<(), String> {
    let scope = claude_code::profile_scope(profile)
        .ok_or_else(|| "Chưa chọn thư mục project cho config Claude".to_string())?;
    let spec = claude_code::spec_for_profile(profile).ok_or_else(|| {
        if cli_proxy::uses_embedded_cli_proxy(profile) {
            "Proxy Claude chưa được chuẩn bị đầy đủ".to_string()
        } else {
            "Nhập Base URL và Token trước khi bật config Claude".to_string()
        }
    })?;
    claude_code::apply(&spec, &scope)?;
    if claude_code::sync_state_for_profile(profile, &scope) != claude_code::SyncState::Synced {
        return Err("Không xác minh được config Claude sau khi ghi".to_string());
    }
    Ok(())
}

fn claude_result(
    profile: &ClaudeCodeProfile,
    proxy: ProxyRuntimeFacts,
) -> Result<ProfileActivationResult, String> {
    let scope = claude_code::profile_scope(profile)
        .ok_or_else(|| "Chưa chọn thư mục project cho config Claude".to_string())?;
    let current = proxy_backed_current(
        claude_code::sync_state_for_profile(profile, &scope) == claude_code::SyncState::Synced,
        cli_proxy::uses_embedded_cli_proxy(profile),
        proxy.running,
        proxy.claude_profile_id.as_deref(),
        &profile.id,
    );
    Ok(ProfileActivationResult {
        agent: ProfileAgent::Claude,
        profile_id: profile.id.clone(),
        active: current,
        current,
        target_path: claude_code::target_path(&scope)
            .to_string_lossy()
            .to_string(),
        profile_flag: None,
        proxy,
    })
}

fn codex_result(profile: &CodexProfile, proxy: ProxyRuntimeFacts) -> ProfileActivationResult {
    let target = codex_config::target_config_path();
    let active =
        codex_config::active_profile_id(Some(&target)).as_deref() == Some(profile.id.as_str());
    let applied = codex_config::is_applied(profile, Some(&target));
    let (active, current) = codex_activation_state(active, applied);
    ProfileActivationResult {
        agent: ProfileAgent::Codex,
        profile_id: profile.id.clone(),
        active,
        current,
        target_path: target.to_string_lossy().to_string(),
        profile_flag: codex_config::profile_flag(&profile.id, Some(&target)),
        proxy,
    }
}

pub async fn activate_claude_profile(
    app: &AppHandle,
    request: ProfileActivationRequest,
) -> Result<ProfileActivationResult, String> {
    let _guard = lock_profile_activation().await;
    let expected = expected_claude(&request)?;
    if !claude_code::profile_ready(&expected) {
        return Err("Config Claude chưa đủ Base URL và Token".to_string());
    }

    let (profile, proxy) = if cli_proxy::uses_embedded_cli_proxy(&expected) {
        let profile = prepare_then_apply(
            expected,
            |profile| config::require_current_claude_profile(profile).map(|_| ()),
            |profile| async move { cli_proxy::prepare_claude_profile_exact(app, &profile).await },
            apply_claude,
        )
        .await?;
        config::require_current_claude_profile(&profile)?;
        let proxy = cli_proxy::runtime_facts().await?;
        config::require_current_claude_profile(&profile)?;
        if !proxy.running || proxy.claude_profile_id.as_deref() != Some(profile.id.as_str()) {
            return Err("Proxy Claude không còn chạy với config vừa chọn".to_string());
        }
        (profile, proxy)
    } else {
        config::require_current_claude_profile(&expected)?;
        apply_claude(&expected)?;
        config::require_current_claude_profile(&expected)?;
        let (profile, proxy) =
            cli_proxy::deactivate_claude_proxy_for_direct(app, &expected).await?;
        config::require_current_claude_profile(&profile)?;
        (profile, proxy)
    };
    claude_result(&profile, proxy)
}

pub async fn activate_codex_profile(
    app: &AppHandle,
    request: ProfileActivationRequest,
) -> Result<ProfileActivationResult, String> {
    let _guard = lock_profile_activation().await;
    let expected = expected_codex(&request)?;
    if !expected.has_upstream_configuration() {
        return Err("Config Codex chưa đủ Base URL, API key và model".to_string());
    }
    let target = codex_config::target_config_path();

    let (profile, proxy) = if expected.uses_embedded_cli_proxy() {
        let profile = prepare_then_apply(
            expected,
            |profile| config::require_current_codex_profile(profile).map(|_| ()),
            |profile| async move { cli_proxy::prepare_codex_profile_exact(app, &profile).await },
            |profile| codex_config::apply_with_profile_file(profile, Some(&target)).map(|_| ()),
        )
        .await?;
        config::require_current_codex_profile(&profile)?;
        let proxy = cli_proxy::runtime_facts().await?;
        config::require_current_codex_profile(&profile)?;
        if !proxy.running || proxy.codex_profile_id.as_deref() != Some(profile.id.as_str()) {
            return Err("Proxy Codex không còn chạy với config vừa chọn".to_string());
        }
        (profile, proxy)
    } else {
        config::require_current_codex_profile(&expected)?;
        codex_config::apply_with_profile_file(&expected, Some(&target))?;
        config::require_current_codex_profile(&expected)?;
        let (profile, proxy) = cli_proxy::deactivate_codex_proxy_for_direct(app, &expected).await?;
        config::require_current_codex_profile(&profile)?;
        (profile, proxy)
    };
    Ok(codex_result(&profile, proxy))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::{Cell, RefCell};

    #[derive(Clone, Debug, PartialEq, Eq)]
    struct TestProfile {
        id: &'static str,
        version: u8,
    }

    #[test]
    fn changed_profile_during_prepare_fails_before_apply() {
        futures::executor::block_on(async {
            let expected = TestProfile {
                id: "p",
                version: 1,
            };
            let stored = RefCell::new(Some(expected.clone()));
            let applied = Cell::new(false);
            let result = prepare_then_apply(
                expected.clone(),
                |profile| match stored.borrow().as_ref() {
                    Some(current) if current == profile => Ok(()),
                    _ => Err("changed".into()),
                },
                |profile| {
                    *stored.borrow_mut() = Some(TestProfile {
                        version: 2,
                        ..profile.clone()
                    });
                    async move { Ok(profile) }
                },
                |_| {
                    applied.set(true);
                    Ok(())
                },
            )
            .await;
            assert_eq!(result.unwrap_err(), "changed");
            assert!(!applied.get());
        });
    }

    #[test]
    fn deleted_profile_during_prepare_fails_before_apply() {
        futures::executor::block_on(async {
            let expected = TestProfile {
                id: "p",
                version: 1,
            };
            let stored = RefCell::new(Some(expected.clone()));
            let applied = Cell::new(false);
            let result = prepare_then_apply(
                expected,
                |profile| match stored.borrow().as_ref() {
                    Some(current) if current == profile => Ok(()),
                    _ => Err("deleted".into()),
                },
                |profile| {
                    *stored.borrow_mut() = None;
                    async move { Ok(profile) }
                },
                |_| {
                    applied.set(true);
                    Ok(())
                },
            )
            .await;
            assert_eq!(result.unwrap_err(), "deleted");
            assert!(!applied.get());
        });
    }

    #[test]
    fn prepare_failure_never_applies_profile() {
        futures::executor::block_on(async {
            let expected = TestProfile {
                id: "p",
                version: 1,
            };
            let applied = Cell::new(false);
            let result = prepare_then_apply(
                expected,
                |_| Ok(()),
                |_| async { Err("prepare failed".to_string()) },
                |_| {
                    applied.set(true);
                    Ok(())
                },
            )
            .await;
            assert_eq!(result.unwrap_err(), "prepare failed");
            assert!(!applied.get());
        });
    }

    #[test]
    fn ipc_result_serialization_contains_no_credentials() {
        let result = ProfileActivationResult {
            agent: ProfileAgent::Claude,
            profile_id: "safe-id".into(),
            active: true,
            current: true,
            target_path: "/tmp/settings.json".into(),
            profile_flag: None,
            proxy: ProxyRuntimeFacts {
                running: true,
                claude_profile_id: Some("safe-id".into()),
                codex_profile_id: None,
            },
        };
        let json = serde_json::to_string(&result).unwrap();
        assert!(!json.contains("apiKey"));
        assert!(!json.contains("token"));
        assert!(!json.contains("management"));
        assert!(!json.contains("baseURL"));
    }

    #[test]
    fn catalog_row_uses_opaque_snapshot_without_serializing_profile_secrets() {
        let profile = ClaudeCodeProfile {
            id: "safe-id".into(),
            name: Some("Private upstream".into()),
            base_url: Some("https://secret-upstream.example/v1".into()),
            token: Some("top-secret-token".into()),
            claude_code_scope: Some("project".into()),
            claude_code_project_path: Some("/path/that/does/not/exist".into()),
            ..Default::default()
        };
        let proxy = ProxyRuntimeFacts {
            running: false,
            claude_profile_id: None,
            codex_profile_id: None,
        };
        let row = claude_row(&profile, &proxy).unwrap();
        assert_eq!(row.expected_snapshot.len(), 64);
        let json = serde_json::to_string(&row).unwrap();
        assert!(!json.contains("top-secret-token"));
        assert!(!json.contains("secret-upstream.example"));
        assert!(!json.contains("baseURL"));
    }

    #[test]
    fn proxy_health_requires_matching_running_profile() {
        assert!(proxy_backed_current(true, false, false, None, "codex-1"));
        assert!(!proxy_backed_current(
            true,
            true,
            false,
            Some("codex-1"),
            "codex-1"
        ));
        assert!(!proxy_backed_current(
            true,
            true,
            true,
            Some("codex-other"),
            "codex-1"
        ));
        assert!(proxy_backed_current(
            true,
            true,
            true,
            Some("codex-1"),
            "codex-1"
        ));
    }

    #[test]
    fn codex_current_is_independent_from_selected_profile() {
        assert_eq!(codex_activation_state(false, true), (false, true));
        assert_eq!(codex_activation_state(true, false), (true, false));
    }
}
