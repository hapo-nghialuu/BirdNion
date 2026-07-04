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

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .invoke_handler(tauri::generate_handler![
            claude_usage_report,
            codex_usage_report,
            provider_statuses
        ])
        .setup(|app| {
            let show = MenuItem::with_id(app, "show", "Mở BirdNion", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "Thoát", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&show, &quit])?;
            TrayIconBuilder::new()
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
