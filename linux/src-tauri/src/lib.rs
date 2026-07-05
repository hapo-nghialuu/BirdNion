//! BirdNion for Linux — Tauri shell: tray icon + single window + the
//! usage-report commands the web UI calls. The window hides on close so the
//! app lives in the tray, mirroring the macOS menu-bar behavior.

mod claude_code;
mod claude_scanner;
mod codex_scanner;
mod config;
mod providers;
mod usage;

use tauri::menu::{Menu, MenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::Manager;
use tauri_plugin_autostart::ManagerExt as _;
use tauri_plugin_notification::NotificationExt as _;

/// Claude Code CLI usage rolled up from local session logs.
/// None (→ null) when no projects root exists on this machine.
#[tauri::command]
fn claude_usage_report() -> Option<usage::UsageReport> {
    claude_scanner::usage_report()
}

/// Codex CLI usage rolled up from local rollout logs.
/// None (→ null) when no sessions root exists on this machine.
#[tauri::command]
fn codex_usage_report() -> Option<usage::UsageReport> {
    codex_scanner::usage_report()
}

/// Quota status for every provider enabled in settings.json, fetched
/// concurrently. Ports still in progress return an explanatory error status.
#[tauri::command]
async fn provider_statuses() -> Vec<providers::ProviderStatus> {
    providers::fetch_all().await
}

/// Claude Admin API org usage/cost dashboard (30-day). None when no admin
/// key is configured (env vars or the Claude row's `adminApiKey` field) or
/// the fetch fails — the Claude tab simply omits the extra card.
#[tauri::command]
async fn claude_admin_usage() -> Option<providers::claude_admin::ClaudeAdminSnapshot> {
    let claude_cfg = config::load()
        .providers
        .into_iter()
        .find(|p| p.id == "claude")
        .unwrap_or_else(|| config::Provider { id: "claude".to_string(), ..Default::default() });
    providers::claude_admin::fetch_snapshot(&claude_cfg).await
}

/// Claude Code quick-apply state for a provider: on/off/stale/needsSetup +
/// the settings.json path it targets. Drives the power-button card in the
/// provider tab and the "Claude Code" Settings pane.
#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct ClaudeCodeState {
    state: &'static str,
    target_path: Option<String>,
}

fn claude_code_state_for(provider_id: &str) -> ClaudeCodeState {
    let provider = config::find_provider(provider_id);
    let scope = claude_code::current_scope(&provider);
    let configured = scope.is_some() && claude_code::is_fully_configured(provider_id, &provider);
    let (sync, target) = match (&scope, configured) {
        (Some(sc), true) => {
            let spec = claude_code::spec_for_provider(provider_id, &provider);
            let sync = spec
                .as_ref()
                .map(|s| claude_code::sync_state(s, sc))
                .unwrap_or(claude_code::SyncState::Off);
            (sync, Some(claude_code::target_path(sc).to_string_lossy().to_string()))
        }
        (Some(sc), false) => (claude_code::SyncState::Off, Some(claude_code::target_path(sc).to_string_lossy().to_string())),
        (None, _) => (claude_code::SyncState::Off, None),
    };
    let power = claude_code::power_state(configured, sync);
    let state = match power {
        claude_code::PowerState::On => "on",
        claude_code::PowerState::Off => "off",
        claude_code::PowerState::Stale => "stale",
        claude_code::PowerState::NeedsSetup => "needsSetup",
    };
    ClaudeCodeState { state, target_path: target }
}

/// Claude Code quick-apply state for a provider (on/off/stale/needsSetup) +
/// the settings.json path it would write to.
#[tauri::command]
fn claude_code_state(provider_id: String) -> ClaudeCodeState {
    claude_code_state_for(&provider_id)
}

/// Merge this provider's Claude Code env into its currently-selected scope
/// (global or project). Fails with a Vietnamese message mirroring the macOS
/// `WriteError` when the provider isn't ready.
#[tauri::command]
fn claude_code_apply(provider_id: String) -> Result<ClaudeCodeState, String> {
    let provider = config::find_provider(&provider_id);
    if !claude_code::is_supported(&provider_id) {
        return Err("Provider không hỗ trợ làm backend Claude Code".to_string());
    }
    let scope = claude_code::current_scope(&provider)
        .ok_or_else(|| "Chưa chọn thư mục project".to_string())?;
    let spec = claude_code::spec_for_provider(&provider_id, &provider).ok_or_else(|| {
        if provider.api_key.as_deref().unwrap_or("").trim().is_empty() {
            "Provider chưa có API key".to_string()
        } else {
            "Chưa chọn đủ 3 model (Haiku/Sonnet/Opus)".to_string()
        }
    })?;
    claude_code::apply(&spec, &scope)?;
    Ok(claude_code_state_for(&provider_id))
}

/// Turn Claude Code's backing OFF for this provider's currently-selected
/// scope: clears the managed `env`/`apiKeyHelper` block, leaves the rest of
/// settings.json intact.
#[tauri::command]
fn claude_code_deactivate(provider_id: String) -> Result<ClaudeCodeState, String> {
    let provider = config::find_provider(&provider_id);
    let scope = claude_code::current_scope(&provider)
        .ok_or_else(|| "Chưa chọn thư mục project".to_string())?;
    claude_code::deactivate(&scope)?;
    Ok(claude_code_state_for(&provider_id))
}

/// Remove the Claude Code env block from this provider's currently-selected
/// scope without creating a settings file when none exists. Returns whether
/// anything was actually removed.
#[tauri::command]
fn claude_code_remove_env(provider_id: String) -> Result<bool, String> {
    let provider = config::find_provider(&provider_id);
    let scope = claude_code::current_scope(&provider)
        .ok_or_else(|| "Chưa chọn thư mục project".to_string())?;
    claude_code::remove_env_settings(&scope)
}

/// Starts a GitHub Device Flow login for Copilot: requests a user code the
/// user enters at the returned verification URL.
#[tauri::command]
async fn copilot_login_start() -> Result<providers::copilot_oauth::DeviceCode, String> {
    providers::copilot_oauth::start("github.com").await
}

/// Single poll tick against the device-flow token endpoint. The caller (JS)
/// drives the retry loop, sleeping `interval` seconds between calls.
#[tauri::command]
async fn copilot_login_poll(device_code: String) -> Result<providers::copilot_oauth::PollResult, String> {
    providers::copilot_oauth::poll("github.com", &device_code).await
}

/// Full settings.json content for the Settings view (local app — keys stay
/// on this machine, same plaintext-by-design store as macOS).
#[tauri::command]
fn get_settings() -> config::Settings {
    config::load()
}

/// Persist the whole settings document (atomic write, 0600).
#[tauri::command]
fn save_settings(settings: config::Settings) -> Result<(), String> {
    config::save(&settings)
}

/// OS notification (quota warnings) — the JS side owns the threshold logic,
/// mirroring the macOS QuotaNotifier's fire-once-per-crossing behavior.
#[tauri::command]
fn notify(app: tauri::AppHandle, title: String, body: String) -> Result<(), String> {
    app.notification()
        .builder()
        .title(title)
        .body(body)
        .show()
        .map_err(|e| e.to_string())
}

/// Launch-at-login toggle (XDG autostart entry on Linux).
#[tauri::command]
fn set_autostart(app: tauri::AppHandle, enabled: bool) -> Result<(), String> {
    let manager = app.autolaunch();
    if enabled {
        manager.enable().map_err(|e| e.to_string())
    } else {
        manager.disable().map_err(|e| e.to_string())
    }
}

#[tauri::command]
fn get_autostart(app: tauri::AppHandle) -> bool {
    app.autolaunch().is_enabled().unwrap_or(false)
}

/// Tray tooltip mirror of the macOS menu-bar percent readout — the JS side
/// pushes "Claude 78% · Codex 95%"-style summaries after each refresh.
#[tauri::command]
fn set_tray_tooltip(app: tauri::AppHandle, tooltip: String) {
    if let Some(tray) = app.tray_by_id("main-tray") {
        let _ = tray.set_tooltip(Some(tooltip));
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            None,
        ))
        .invoke_handler(tauri::generate_handler![
            claude_usage_report,
            codex_usage_report,
            provider_statuses,
            claude_admin_usage,
            claude_code_state,
            claude_code_apply,
            claude_code_deactivate,
            claude_code_remove_env,
            copilot_login_start,
            copilot_login_poll,
            get_settings,
            save_settings,
            notify,
            set_autostart,
            get_autostart,
            set_tray_tooltip
        ])
        .setup(|app| {
            let show = MenuItem::with_id(app, "show", "Mở BirdNion", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "Thoát", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&show, &quit])?;
            TrayIconBuilder::with_id("main-tray")
                .icon(app.default_window_icon().unwrap().clone())
                .menu(&menu)
                .show_menu_on_left_click(true)
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "show" => {
                        if let Some(window) = app.get_webview_window("main") {
                            let _ = window.show();
                            let _ = window.set_focus();
                        }
                    }
                    "quit" => app.exit(0),
                    _ => {}
                })
                .build(app)?;
            Ok(())
        })
        .on_window_event(|window, event| {
            // Tray app: closing the window only hides it; quit lives in the
            // tray menu.
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                let _ = window.hide();
                api.prevent_close();
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
