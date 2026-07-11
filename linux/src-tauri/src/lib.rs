//! BirdNion for Linux — Tauri shell: tray icon + single window + the
//! usage-report commands the web UI calls. The window hides on close so the
//! app lives in the tray, mirroring the macOS menu-bar behavior.

mod claude_code;
mod claude_scanner;
mod codex_accounts;
mod codex_scanner;
mod config;
mod cost_history;
mod freemodel_accounts;
mod grok_scanner;
mod providers;
mod storage;
mod updater;
mod usage;

use std::collections::HashMap;
use std::sync::{LazyLock, Mutex};
use std::time::{Duration, Instant};

use tauri::image::Image;
use tauri::menu::{Menu, MenuItem};
use tauri::tray::TrayIconBuilder;

use tauri_plugin_autostart::ManagerExt as _;
use tauri_plugin_notification::NotificationExt as _;

/// In-memory scanner cache — macOS `ClaudeCostScanner`/`CodexCostScanner`/
/// `GrokCostScanner` actor-cache parity (TTL 300 s): repeat calls within the
/// window skip the full JSONL rescan and the cost-history disk round-trip.
const USAGE_REPORT_TTL: Duration = Duration::from_secs(300);
static USAGE_REPORT_CACHE: LazyLock<Mutex<HashMap<&'static str, (Instant, usage::UsageReport)>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// Runs `scan` (full log walk) at most once per TTL per source, merging with
/// the cost-history high-water mark on refresh (macOS CostHistoryStore
/// parity). Always returns a report — history-backed when no live logs exist.
fn cached_usage_report(
    source: &'static str,
    scan: fn() -> Option<usage::UsageReport>,
) -> usage::UsageReport {
    if let Some((at, report)) = USAGE_REPORT_CACHE.lock().unwrap().get(source) {
        if at.elapsed() < USAGE_REPORT_TTL {
            return report.clone();
        }
    }
    let live = scan();
    let merged = cost_history::apply_and_report(source, live.as_ref());
    USAGE_REPORT_CACHE
        .lock()
        .unwrap()
        .insert(source, (Instant::now(), merged.clone()));
    merged
}

/// Claude Code CLI usage rolled up from local session logs. The scan runs on
/// a blocking thread — sync commands execute on the GTK main loop and froze
/// the webview's first paint for the whole log walk (macOS runs its scanners
/// detached off-main for the same reason).
#[tauri::command]
async fn claude_usage_report() -> Option<usage::UsageReport> {
    tauri::async_runtime::spawn_blocking(|| {
        cached_usage_report("claude", claude_scanner::usage_report)
    })
    .await
    .ok()
}

/// Codex CLI usage rolled up from local rollout logs (blocking thread + cache,
/// see `claude_usage_report`).
#[tauri::command]
async fn codex_usage_report() -> Option<usage::UsageReport> {
    tauri::async_runtime::spawn_blocking(|| {
        cached_usage_report("codex", codex_scanner::usage_report)
    })
    .await
    .ok()
}

/// Grok Build local session cost (signals.json) + history merge (blocking
/// thread + cache, see `claude_usage_report`).
#[tauri::command]
async fn grok_usage_report() -> Option<usage::UsageReport> {
    tauri::async_runtime::spawn_blocking(|| {
        cached_usage_report("grok", grok_scanner::usage_report)
    })
    .await
    .ok()
}

/// Quota status for providers enabled in settings.json, fetched concurrently.
/// When `ids` is provided, only those provider ids are fetched (used by the
/// JS poller to honor per-provider refresh-interval overrides); omitting it
/// fetches every enabled provider. Ports still in progress return an
/// explanatory error status.
#[tauri::command]
async fn provider_statuses(ids: Option<Vec<String>>) -> Vec<providers::ProviderStatus> {
    providers::fetch_filtered(ids.as_deref()).await
}

/// Classifies a raw provider error string into a `ProviderErrorKind` key
/// suffix (e.g. "cookieExpiredOrMissing") so the frontend can build i18n
/// keys `providerError.<suffix>.title` / `.hint` without duplicating the
/// classification logic. `None` when there is nothing to classify.
#[tauri::command]
fn classify_provider_error(raw: Option<String>) -> Option<String> {
    providers::error_classifier::classify(raw.as_deref())
        .map(|kind| kind.key_suffix().to_string())
}

/// Runs a single self-test fetch for one provider (never the whole refresh
/// loop). Returns a failure status keyed to `provider.selfTest.disabled`
/// when the provider is disabled or not found in settings.json.
#[tauri::command]
async fn test_provider(id: String) -> providers::ProviderStatus {
    let cfg = config::load().providers.into_iter().find(|p| p.id == id);
    match cfg {
        Some(cfg) if cfg.enabled.unwrap_or(false) => providers::fetch(&cfg).await,
        Some(cfg) => providers::ProviderStatus::failure(
            &id,
            &providers::display_name(&cfg),
            "provider.selfTest.disabled",
        ),
        None => providers::ProviderStatus::failure(&id, &id, "provider.selfTest.disabled"),
    }
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

/// Static backend facts for the Claude Code pane's read-only rows: resolved
/// Anthropic-compatible base URL + suggested model ids (macOS
/// `ClaudeCodeBackend.baseURL` / `.suggestedModels`).
#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct ClaudeCodeBackendInfo {
    base_url: Option<String>,
    suggested_models: Vec<String>,
}

#[tauri::command]
fn claude_code_backend_info(provider_id: String) -> ClaudeCodeBackendInfo {
    let provider = config::find_provider(&provider_id);
    ClaudeCodeBackendInfo {
        base_url: claude_code::base_url_for_provider(&provider_id, &provider),
        suggested_models: claude_code::suggested_models(&provider_id)
            .iter()
            .map(|s| s.to_string())
            .collect(),
    }
}

/// `GET {base}/v1/models` against an Anthropic-compatible backend — macOS
/// `ClaudeCodeModelsFetcher` (x-api-key first, Bearer retry on 401/403).
#[tauri::command]
async fn claude_code_models(base_url: String, token: String) -> Result<Vec<String>, String> {
    claude_code::fetch_models(&base_url, &token).await
}

// --- Custom Claude Code profiles (macOS `claudeCodeProfiles`) --------------

fn claude_code_profile_state_for(profile_id: &str) -> ClaudeCodeState {
    let Some(profile) = config::find_profile(profile_id) else {
        return ClaudeCodeState { state: "needsSetup", target_path: None };
    };
    let scope = claude_code::profile_scope(&profile);
    let configured = scope.is_some() && claude_code::profile_ready(&profile);
    let (sync, target) = match (&scope, configured) {
        (Some(sc), true) => {
            let sync = claude_code::spec_for_profile(&profile)
                .map(|s| claude_code::sync_state(&s, sc))
                .unwrap_or(claude_code::SyncState::Off);
            (sync, Some(claude_code::target_path(sc).to_string_lossy().to_string()))
        }
        (Some(sc), false) => (
            claude_code::SyncState::Off,
            Some(claude_code::target_path(sc).to_string_lossy().to_string()),
        ),
        (None, _) => (claude_code::SyncState::Off, None),
    };
    let state = match claude_code::power_state(configured, sync) {
        claude_code::PowerState::On => "on",
        claude_code::PowerState::Off => "off",
        claude_code::PowerState::Stale => "stale",
        claude_code::PowerState::NeedsSetup => "needsSetup",
    };
    ClaudeCodeState { state, target_path: target }
}

#[tauri::command]
fn claude_code_profile_state(profile_id: String) -> ClaudeCodeState {
    claude_code_profile_state_for(&profile_id)
}

#[tauri::command]
fn claude_code_profile_apply(profile_id: String) -> Result<ClaudeCodeState, String> {
    let profile = config::find_profile(&profile_id).ok_or_else(|| "Không tìm thấy config".to_string())?;
    let scope = claude_code::profile_scope(&profile)
        .ok_or_else(|| "Chưa chọn thư mục project".to_string())?;
    let spec = claude_code::spec_for_profile(&profile)
        .ok_or_else(|| "Nhập Base URL + Token để bật".to_string())?;
    claude_code::apply(&spec, &scope)?;
    Ok(claude_code_profile_state_for(&profile_id))
}

#[tauri::command]
fn claude_code_profile_deactivate(profile_id: String) -> Result<ClaudeCodeState, String> {
    let profile = config::find_profile(&profile_id).ok_or_else(|| "Không tìm thấy config".to_string())?;
    let scope = claude_code::profile_scope(&profile)
        .ok_or_else(|| "Chưa chọn thư mục project".to_string())?;
    claude_code::deactivate(&scope)?;
    Ok(claude_code_profile_state_for(&profile_id))
}

#[tauri::command]
fn claude_code_profile_remove_env(profile_id: String) -> Result<bool, String> {
    let profile = config::find_profile(&profile_id).ok_or_else(|| "Không tìm thấy config".to_string())?;
    let scope = claude_code::profile_scope(&profile)
        .ok_or_else(|| "Chưa chọn thư mục project".to_string())?;
    claude_code::remove_env_settings(&scope)
}

/// Every Codex login the app knows about (system + managed accounts) plus
/// the currently active id. Drives the account-list row in Settings.
#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct CodexAccountsState {
    accounts: Vec<codex_accounts::CodexAccount>,
    active_id: String,
}

#[tauri::command]
fn codex_accounts_list() -> CodexAccountsState {
    CodexAccountsState { accounts: codex_accounts::all_accounts(), active_id: codex_accounts::active_id() }
}

/// "Lưu account hiện tại" — copies the current system `~/.codex/auth.json`
/// into a new managed account so it survives future re-logins of the system
/// account. Mirrors `CodexAccountStore.promoteSystem()`.
#[tauri::command]
fn codex_account_save_current() -> Result<CodexAccountsState, String> {
    codex_accounts::promote_system()?;
    Ok(codex_accounts_list())
}

/// Switches the active Codex account the provider/scanner read from.
#[tauri::command]
fn codex_account_switch(id: String) -> Result<CodexAccountsState, String> {
    codex_accounts::set_active(&id)?;
    Ok(codex_accounts_list())
}

/// Removes a managed Codex account (no-op for "system"). Falls the active
/// selection back to "system" if the removed account was active.
#[tauri::command]
fn codex_account_remove(id: String) -> Result<CodexAccountsState, String> {
    codex_accounts::remove(&id)?;
    Ok(codex_accounts_list())
}

/// FreeModel multi-account state — implicit "browser" entry (auto scan) +
/// one entry per signed-in browser + managed pasted-cookie accounts, plus
/// the active id.
#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct FreemodelAccountsState {
    accounts: Vec<freemodel_accounts::FreemodelAccount>,
    active_id: String,
}

/// Per-browser email cache — a browser's signed-in FreeModel identity only
/// changes when the user re-logs in there; don't hit `/api/auth/me` on
/// every settings render.
static FM_BROWSER_EMAILS: LazyLock<Mutex<HashMap<String, Option<String>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// Detects every browser signed in to freemodel.dev (has `bm_session`) and
/// resolves each one's account email, so two browsers logged in to two
/// different FreeModel accounts appear as two selectable entries.
async fn freemodel_detected_browsers() -> Vec<freemodel_accounts::FreemodelAccount> {
    let sessions = tauri::async_runtime::spawn_blocking(|| {
        providers::browser_cookies::browsers_with_cookie(&["freemodel.dev"], "bm_session")
    })
    .await
    .unwrap_or_default();

    let client = providers::shared_client();
    let mut out = Vec::new();
    for (browser, header) in sessions {
        let cached = FM_BROWSER_EMAILS.lock().unwrap().get(browser).cloned();
        let email = match cached {
            Some(email) => email,
            None => {
                let email = providers::freemodel::fetch_email(&client, &header).await;
                FM_BROWSER_EMAILS.lock().unwrap().insert(browser.to_string(), email.clone());
                email
            }
        };
        out.push(freemodel_accounts::FreemodelAccount {
            id: format!("{}{browser}", freemodel_accounts::BROWSER_PREFIX),
            email,
            label: Some(freemodel_accounts::browser_label(browser)),
            is_browser: true,
        });
    }
    out
}

async fn freemodel_state() -> FreemodelAccountsState {
    let mut accounts = freemodel_accounts::all_accounts();
    // Splice per-browser sessions right after the "auto" entry (index 0).
    let detected = freemodel_detected_browsers().await;
    accounts.splice(1..1, detected);
    FreemodelAccountsState { accounts, active_id: freemodel_accounts::active_id() }
}

#[tauri::command]
async fn freemodel_accounts_list() -> FreemodelAccountsState {
    freemodel_state().await
}

/// Validates a pasted FreeModel cookie (must carry `bm_session`; a bare token
/// is wrapped), resolves the account email best-effort, and stores it as a
/// new managed account.
#[tauri::command]
async fn freemodel_account_add(cookie: String, label: Option<String>) -> Result<FreemodelAccountsState, String> {
    let Some(normalized) = providers::freemodel::filtered_cookie_header(&cookie) else {
        return Err("Cookie phải chứa bm_session".to_string());
    };
    // Email lookup doubles as a soft validation — a dead cookie still stores
    // (freemodel may rate-limit /me), it just goes in unlabeled.
    let client = providers::shared_client();
    let email = providers::freemodel::fetch_email(&client, &normalized).await;
    freemodel_accounts::add(&normalized, label.as_deref(), email.as_deref())?;
    Ok(freemodel_state().await)
}

/// Switches the active FreeModel account the provider fetch reads from.
#[tauri::command]
async fn freemodel_account_switch(id: String) -> Result<FreemodelAccountsState, String> {
    freemodel_accounts::set_active(&id)?;
    Ok(freemodel_state().await)
}

/// Removes a managed FreeModel account (no-op for browser entries).
#[tauri::command]
async fn freemodel_account_remove(id: String) -> Result<FreemodelAccountsState, String> {
    freemodel_accounts::remove(&id)?;
    Ok(freemodel_state().await)
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

/// Tray status mirror of the macOS menu-bar percent readout.
///
/// Visual contract (macOS NSStatusItem parity): **`91%` then provider logo**.
/// The JS side paints that into a single composite PNG (`icon_png`) because
/// tray-icon places the image left of the title on macOS; compositing keeps
/// the percent→logo order. Title is left empty when a composite is provided.
///
/// * `tooltip` — hover text (macOS/Windows; unsupported on Linux panel).
/// * `title` — optional raw text (unused when `icon_png` carries the frame).
/// * `icon_png` — composite frame PNG, or `None` to restore the default logo.
#[tauri::command]
fn set_tray_status(
    app: tauri::AppHandle,
    tooltip: String,
    title: Option<String>,
    icon_png: Option<Vec<u8>>,
) {
    if let Some(tray) = app.tray_by_id("main-tray") {
        let _ = tray.set_tooltip(Some(tooltip.as_str()));
        // Empty string clears the title slot so the composite icon stands alone.
        match title.as_deref().filter(|s| !s.is_empty()) {
            Some(t) => {
                let _ = tray.set_title(Some(t));
            }
            None => {
                let _ = tray.set_title(Some(""));
            }
        }
        if let Some(bytes) = icon_png {
            if let Ok(img) = Image::from_bytes(&bytes) {
                let _ = tray.set_icon(Some(img));
                // Colors (incl. white-tinted logos) are baked into the PNG.
                let _ = tray.set_icon_as_template(false);
            }
        } else if let Some(def) = app.default_window_icon() {
            let _ = tray.set_icon(Some(def.clone()));
            let _ = tray.set_icon_as_template(false);
        }
    }
}

/// Back-compat: tooltip only (title left unchanged). Prefer `set_tray_status`.
#[tauri::command]
fn set_tray_tooltip(app: tauri::AppHandle, tooltip: String) {
    if let Some(tray) = app.tray_by_id("main-tray") {
        let _ = tray.set_tooltip(Some(tooltip));
    }
}

/// Quit the whole process (footer / settings parity with macOS popover Quit).
#[tauri::command]
fn quit_app(app: tauri::AppHandle) {
    app.exit(0);
}

/// Open (or focus) the dedicated Settings window — macOS Settings scene parity
/// (780×720, separate from the tray popover).
#[tauri::command]
fn open_settings_window(app: tauri::AppHandle) -> Result<(), String> {
    open_settings_window_impl(&app, None)
}

fn open_settings_window_impl(app: &tauri::AppHandle, section: Option<&str>) -> Result<(), String> {
    use tauri::{Manager, WebviewUrl, WebviewWindowBuilder};
    if let Some(existing) = app.get_webview_window("settings") {
        if let Some(sec) = section {
            // Single path: localStorage + one custom event (no emit+eval double fire).
            let script = format!(
                "localStorage.setItem('birdnion.settingsSection',{});\
                 window.dispatchEvent(new CustomEvent('birdnion-settings-section',{{detail:{}}}));",
                serde_json::to_string(sec).unwrap_or_else(|_| "\"general\"".into()),
                serde_json::to_string(sec).unwrap_or_else(|_| "\"general\"".into()),
            );
            let _ = existing.eval(&script);
        }
        let _ = existing.show();
        let _ = existing.set_focus();
        return Ok(());
    }
    // Dedicated settings.html entry — never shares the popover main.ts path
    // (blank/spinning Settings was caused by wrong branch + blocked await paint).
    let mut init = String::from("window.__BIRDNION_MODE__='settings';");
    if let Some(sec) = section {
        init.push_str(&format!(
            "localStorage.setItem('birdnion.settingsSection',{});",
            serde_json::to_string(sec).unwrap_or_else(|_| "\"general\"".into())
        ));
    }
    let win = WebviewWindowBuilder::new(app, "settings", WebviewUrl::App("settings.html".into()))
        .title("BirdNion Settings")
        .inner_size(780.0, 720.0)
        .min_inner_size(640.0, 520.0)
        .resizable(true)
        .initialization_script(&init)
        .build()
        .map_err(|e| e.to_string())?;
    let _ = win.set_focus();
    Ok(())
}

fn show_main_window(app: &tauri::AppHandle) {
    use tauri::Manager;
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.show();
        let _ = window.set_focus();
    }
}

fn toggle_main_window(app: &tauri::AppHandle) {
    use tauri::Manager;
    if let Some(window) = app.get_webview_window("main") {
        if window.is_visible().unwrap_or(false) {
            let _ = window.hide();
        } else {
            let _ = window.show();
            let _ = window.set_focus();
        }
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            None,
        ))
        .invoke_handler(tauri::generate_handler![
            claude_usage_report,
            codex_usage_report,
            grok_usage_report,
            provider_statuses,
            classify_provider_error,
            test_provider,
            claude_admin_usage,
            claude_code_state,
            claude_code_apply,
            claude_code_deactivate,
            claude_code_remove_env,
            claude_code_backend_info,
            claude_code_models,
            claude_code_profile_state,
            claude_code_profile_apply,
            claude_code_profile_deactivate,
            claude_code_profile_remove_env,
            codex_accounts_list,
            codex_account_save_current,
            codex_account_switch,
            codex_account_remove,
            freemodel_accounts_list,
            freemodel_account_add,
            freemodel_account_switch,
            freemodel_account_remove,
            copilot_login_start,
            copilot_login_poll,
            get_settings,
            save_settings,
            notify,
            set_autostart,
            get_autostart,
            set_tray_status,
            set_tray_tooltip,
            quit_app,
            open_settings_window,
            updater::check_update,
            storage::provider_storage,
            storage::format_storage_bytes
        ])
        .setup(|app| {
            // Tray context menu mirrors the macOS status-item menu / popover footer:
            // open the quota popover, open Settings window, About, Quit.
            // Left-click on macOS toggles the main popover (show_menu_on_left_click = false).
            // Linux libappindicator only supports menu-on-click, so left-click shows this menu.
            let show = MenuItem::with_id(app, "show", "Mở BirdNion", true, None::<&str>)?;
            let settings = MenuItem::with_id(app, "settings", "Cài đặt…", true, None::<&str>)?;
            let about = MenuItem::with_id(app, "about", "Giới thiệu BirdNion", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "Thoát BirdNion", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&show, &settings, &about, &quit])?;

            let mut tray = TrayIconBuilder::with_id("main-tray")
                .icon(app.default_window_icon().unwrap().clone())
                .menu(&menu)
                // macOS: left-click → popover; right-click → menu (matches NSStatusItem).
                // Linux: menu on click is the only reliable path (no tray click events).
                .show_menu_on_left_click(cfg!(not(target_os = "macos")))
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "show" => show_main_window(app),
                    "settings" => {
                        let _ = open_settings_window_impl(app, Some("general"));
                    }
                    "about" => {
                        let _ = open_settings_window_impl(app, Some("about"));
                    }
                    "quit" => app.exit(0),
                    _ => {}
                });

            // macOS/Windows: left-click toggles the quota popover window.
            #[cfg(any(target_os = "macos", target_os = "windows"))]
            {
                tray = tray.on_tray_icon_event(|tray, event| {
                    use tauri::tray::{MouseButton, MouseButtonState, TrayIconEvent};
                    if let TrayIconEvent::Click {
                        button: MouseButton::Left,
                        button_state: MouseButtonState::Up,
                        ..
                    } = event
                    {
                        toggle_main_window(tray.app_handle());
                    }
                });
            }

            tray.build(app)?;
            Ok(())
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                // Settings is a real window — destroy on close.
                // Main popover stays tray-resident (hide only).
                if window.label() == "settings" {
                    return;
                }
                let _ = window.hide();
                api.prevent_close();
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
