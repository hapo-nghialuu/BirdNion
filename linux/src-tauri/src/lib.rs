//! BirdNion for Linux — Tauri shell: tray icon + single window + the
//! usage-report commands the web UI calls. The window hides on close so the
//! app lives in the tray, mirroring the macOS menu-bar behavior.

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

/// Anthropic Admin API org usage/cost snapshot for the enabled `claude`
/// provider entry (Admin API key via env or config, separate from the OAuth
/// token). `null` when no admin key is configured or the fetch fails.
#[tauri::command]
async fn claude_admin_usage() -> Option<providers::claude_admin::ClaudeAdminSnapshot> {
    let cfg = config::enabled_providers().into_iter().find(|p| p.id == "claude")?;
    providers::claude_admin::fetch_snapshot(&cfg).await
}

/// Starts a GitHub Copilot Device Flow login, returning the user code and
/// verification URL for the web UI to display.
#[tauri::command]
async fn copilot_device_start() -> Result<providers::copilot_device::DeviceCode, String> {
    providers::copilot_device::start("github.com").await
}

/// Polls the Device Flow until the user approves/denies (or it expires),
/// persisting the resulting account on success and returning its label.
#[tauri::command]
async fn copilot_device_poll(device_code: String, interval: i64) -> Result<String, String> {
    providers::copilot_device::poll_and_save("github.com", &device_code, interval).await
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
            copilot_device_start,
            copilot_device_poll,
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
