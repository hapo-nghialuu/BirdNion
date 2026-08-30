//! BirdNion desktop Tauri shell: tray icon + single window + the
//! usage-report commands the web UI calls. The window hides on close so the
//! app lives in the tray, mirroring the macOS menu-bar behavior.

mod claude_code;
mod claude_scanner;
mod cli_proxy;
mod codex_accounts;
mod codex_config;
mod codex_scanner;
mod config;
mod cost_history;
mod elevenlabs_keys;
mod freemodel_accounts;
mod grok_scanner;
mod hiyo_keys;
mod installed_agents;
mod kiro_scanner;
mod omp_scanner;
mod pi_scanner;
mod platform;
mod project_cost_history;
mod project_insights;
mod providers;
mod storage;
mod updater;
mod usage;

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, Ordering};
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
static KIRO_USAGE_SCAN_LOCK: LazyLock<Mutex<()>> = LazyLock::new(|| Mutex::new(()));

/// Claude Code CLI usage rolled up from local session logs. The scan runs on
/// a blocking thread — sync commands execute on the GTK main loop and froze
/// the webview's first paint for the whole log walk (macOS runs its scanners
/// detached off-main for the same reason).
#[tauri::command]
async fn claude_usage_report() -> Option<usage::UsageReport> {
    let started_sources = enabled_usage_sources();
    if !started_sources.contains("claude") {
        return None;
    }
    let report = tauri::async_runtime::spawn_blocking(|| {
        if let Some((at, report)) = USAGE_REPORT_CACHE.lock().unwrap().get("claude") {
            if at.elapsed() < USAGE_REPORT_TTL {
                return report.clone();
            }
        }
        let live = claude_scanner::usage_scan();
        let merged =
            cost_history::apply_and_report("claude", live.as_ref().map(|scan| &scan.usage));
        if let Some(scan) = &live {
            // Insights storage is optional. Its failure must never make the
            // established aggregate usage command fail.
            let _ = project_cost_history::apply("claude", &scan.projects, false);
        }
        USAGE_REPORT_CACHE
            .lock()
            .unwrap()
            .insert("claude", (Instant::now(), merged.clone()));
        merged
    })
    .await
    .ok();
    authorize_usage_report("claude", report, &started_sources, &enabled_usage_sources())
}

/// Codex CLI usage rolled up from local rollout logs (blocking thread + cache,
/// see `claude_usage_report`).
#[tauri::command]
async fn codex_usage_report() -> Option<usage::UsageReport> {
    let started_sources = enabled_usage_sources();
    if !started_sources.contains("codex") {
        return None;
    }
    let report = tauri::async_runtime::spawn_blocking(|| {
        if let Some((at, report)) = USAGE_REPORT_CACHE.lock().unwrap().get("codex") {
            if at.elapsed() < USAGE_REPORT_TTL {
                return report.clone();
            }
        }
        let live = codex_scanner::usage_scan();
        let merged = cost_history::apply_and_report("codex", live.as_ref().map(|scan| &scan.usage));
        if let Some(scan) = &live {
            let _ = project_cost_history::apply_with_retractions(
                "codex",
                &scan.projects,
                &scan.retractions,
                false,
            );
        }
        USAGE_REPORT_CACHE
            .lock()
            .unwrap()
            .insert("codex", (Instant::now(), merged.clone()));
        merged
    })
    .await
    .ok();
    authorize_usage_report("codex", report, &started_sources, &enabled_usage_sources())
}

/// Grok Build local session cost (signals.json) + history merge (blocking
/// thread + cache, see `claude_usage_report`).
fn merge_grok_usage(live: Option<&usage::UsageReport>) -> usage::UsageReport {
    cost_history::apply_and_report_at_counting_revision(
        "grok",
        live,
        grok_scanner::COUNTING_REVISION,
    )
}

#[tauri::command]
async fn grok_usage_report() -> Option<usage::UsageReport> {
    let started_sources = enabled_usage_sources();
    if !started_sources.contains("grok") {
        return None;
    }
    let report = tauri::async_runtime::spawn_blocking(|| {
        if let Some((at, report)) = USAGE_REPORT_CACHE.lock().unwrap().get("grok") {
            if at.elapsed() < USAGE_REPORT_TTL {
                return report.clone();
            }
        }
        let live = grok_scanner::usage_scan();
        // Ngữ nghĩa đếm của Grok đổi ở rev 3 (chia theo dòng thời gian session
        // thay vì dồn vào ngày hoạt động cuối). Các ngày đã lưu theo công thức
        // cũ bị phồng vì cùng một session để lại bản sao ở mỗi ngày nó từng là
        // "hoạt động cuối". History thay source và đóng dấu revision nguyên tử
        // khi có live hợp lệ; thiếu/hỏng live phải giữ nguyên revision cũ.
        let merged = merge_grok_usage(live.as_ref().map(|scan| &scan.usage));
        if let Some(scan) = &live {
            let _ = project_cost_history::apply("grok", &scan.projects, false);
        }
        USAGE_REPORT_CACHE
            .lock()
            .unwrap()
            .insert("grok", (Instant::now(), merged.clone()));
        merged
    })
    .await
    .ok();
    authorize_usage_report("grok", report, &started_sources, &enabled_usage_sources())
}

/// Oh My Pi (`omp`) local session cost + history merge.
#[tauri::command]
async fn omp_usage_report() -> Option<usage::UsageReport> {
    let started_sources = enabled_usage_sources();
    if !started_sources.contains("omp") {
        return None;
    }
    let report = tauri::async_runtime::spawn_blocking(|| {
        if let Some((at, report)) = USAGE_REPORT_CACHE.lock().unwrap().get("omp") {
            if at.elapsed() < USAGE_REPORT_TTL {
                return report.clone();
            }
        }
        let now = chrono::Local::now();
        let scan = omp_scanner::scan_omp_usage(now);
        let merged = cost_history::apply_and_report("omp", Some(&scan.usage));
        let _ = project_cost_history::apply("omp", &scan.projects, false);
        USAGE_REPORT_CACHE
            .lock()
            .unwrap()
            .insert("omp", (Instant::now(), merged.clone()));
        merged
    })
    .await
    .ok();
    authorize_usage_report("omp", report, &started_sources, &enabled_usage_sources())
}

/// Kiro CLI local session cost (real billed credits) + history merge.
/// Kiro sessions carry no `cwd`, so unlike omp/pi there is no per-project
/// contribution to persist here.
fn completed_kiro_usage(scan: &kiro_scanner::KiroUsageScan) -> Option<&usage::UsageReport> {
    scan.completed.then_some(&scan.usage)
}

#[tauri::command]
async fn kiro_usage_report() -> Option<usage::UsageReport> {
    let started_sources = enabled_usage_sources();
    if !started_sources.contains("kiro") {
        return None;
    }
    let report = tauri::async_runtime::spawn_blocking(|| {
        if let Some((at, report)) = USAGE_REPORT_CACHE.lock().unwrap().get("kiro") {
            if at.elapsed() < USAGE_REPORT_TTL {
                return report.clone();
            }
        }
        let _scan_guard = KIRO_USAGE_SCAN_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        // Main, Insights and the digest can request Kiro during the same paint.
        // Recheck after winning the source lock so only the first caller scans.
        if let Some((at, report)) = USAGE_REPORT_CACHE.lock().unwrap().get("kiro") {
            if at.elapsed() < USAGE_REPORT_TTL {
                return report.clone();
            }
        }
        let now = chrono::Local::now();
        let scan = kiro_scanner::scan_kiro_usage(now);
        let merged = cost_history::apply_and_report_at_counting_revision(
            "kiro",
            completed_kiro_usage(&scan),
            kiro_scanner::COUNTING_REVISION,
        );
        // Cache the fail-closed history projection too. Malformed local input
        // must not make every waiter repeat the bounded full scan serially.
        USAGE_REPORT_CACHE
            .lock()
            .unwrap()
            .insert("kiro", (Instant::now(), merged.clone()));
        merged
    })
    .await
    .ok();
    authorize_usage_report("kiro", report, &started_sources, &enabled_usage_sources())
}

/// Pi Agent local session cost + history merge.
#[tauri::command]
async fn pi_usage_report() -> Option<usage::UsageReport> {
    let started_sources = enabled_usage_sources();
    if !started_sources.contains("pi") {
        return None;
    }
    let report = tauri::async_runtime::spawn_blocking(|| {
        if let Some((at, report)) = USAGE_REPORT_CACHE.lock().unwrap().get("pi") {
            if at.elapsed() < USAGE_REPORT_TTL {
                return report.clone();
            }
        }
        let now = chrono::Local::now();
        let scan = pi_scanner::scan_pi_usage(now);
        let merged = cost_history::apply_and_report("pi", Some(&scan.usage));
        let _ = project_cost_history::apply("pi", &scan.projects, false);
        USAGE_REPORT_CACHE
            .lock()
            .unwrap()
            .insert("pi", (Instant::now(), merged.clone()));
        merged
    })
    .await
    .ok();
    authorize_usage_report("pi", report, &started_sources, &enabled_usage_sources())
}
/// Read-only Insights projection. It reads the optional project store and
/// existing aggregate history; it never starts a second scanner pass.
#[tauri::command]
async fn project_insights_report(
    days: Option<u16>,
    project_key: Option<String>,
) -> Result<project_insights::Report, String> {
    let days = match days {
        Some(30) => 30,
        Some(90) => 90,
        _ => 7,
    };
    let project_key = project_key.filter(|key| {
        key.len() <= 80
            && key
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
    });
    let started_sources = enabled_usage_sources();
    tauri::async_runtime::spawn_blocking(move || {
        let mut current = {
            let cache = USAGE_REPORT_CACHE.lock().unwrap_or_else(|e| e.into_inner());
            let mut reports = fresh_cached_usage_reports(&cache, Instant::now());
            reports.retain(|source, _| started_sources.contains(source));
            reports
        };
        let initial = project_insights::build_report(
            days,
            project_key.as_deref(),
            &current,
            &started_sources,
        );

        // Reading histories above can outlive a settings change. Intersect the
        // start/final canonical sets and rebuild only when authorization
        // narrowed, so no revoked source survives in aggregate totals either.
        let final_sources = enabled_usage_sources();
        let authorized_sources = intersect_usage_sources(&started_sources, &final_sources);
        if authorized_sources == started_sources {
            Ok(initial)
        } else {
            current.retain(|source, _| authorized_sources.contains(source));
            let rebuilt = project_insights::build_report(
                days,
                project_key.as_deref(),
                &current,
                &authorized_sources,
            );
            let publish_sources =
                intersect_usage_sources(&authorized_sources, &enabled_usage_sources());
            if publish_sources == authorized_sources {
                Ok(rebuilt)
            } else {
                Err("Nguồn dữ liệu Insights vừa thay đổi — thử lại".to_string())
            }
        }
    })
    .await
    .map_err(|error| error.to_string())?
}

/// Nguồn chi phí cục bộ quét được từ log trên máy.
const LOCAL_COST_SOURCES: [&str; 6] = ["claude", "codex", "grok", "omp", "pi", "kiro"];

/// Agent phát hiện được trên máy, cache 5 phút — dò PATH nên không gọi mỗi lần
/// dựng báo cáo.
static DETECTED_AGENT_CACHE: LazyLock<Mutex<Option<(Instant, HashSet<String>)>>> =
    LazyLock::new(|| Mutex::new(None));

fn detected_agent_ids() -> HashSet<String> {
    if let Some((at, ids)) = DETECTED_AGENT_CACHE.lock().unwrap().as_ref() {
        if at.elapsed() < USAGE_REPORT_TTL {
            return ids.clone();
        }
    }
    let ids: HashSet<String> = installed_agents::detect(&[], &HashMap::new())
        .into_iter()
        .map(|agent| agent.id)
        .collect();
    *DETECTED_AGENT_CACHE.lock().unwrap() = Some((Instant::now(), ids.clone()));
    ids
}

/// Cost đi theo AGENT, provider chỉ gate quota/tab/menu bar: Grok CLI vẫn hiện
/// chi phí khi provider Grok đang tắt (macOS parity 2026-08-24). Tách riêng
/// khỏi `enabled_usage_sources` để test được mà không cần đụng config/PATH.
fn usage_sources_for(
    enabled_providers: &HashSet<String>,
    detected_agents: &HashSet<String>,
) -> HashSet<String> {
    LOCAL_COST_SOURCES
        .iter()
        .filter(|id| enabled_providers.contains(**id) || detected_agents.contains(**id))
        .map(|id| (*id).to_string())
        .collect()
}

fn enabled_usage_sources() -> HashSet<String> {
    let enabled: HashSet<String> = config::enabled_providers()
        .into_iter()
        .map(|provider| provider.id)
        .collect();
    usage_sources_for(&enabled, &detected_agent_ids())
}

fn sorted_usage_source_ids(sources: &HashSet<String>) -> Vec<String> {
    let mut ids: Vec<String> = sources.iter().cloned().collect();
    ids.sort();
    ids
}

/// Canonical local cost sources enabled by provider settings or detected
/// agents. Read-only: reuses the existing detection cache and never scans
/// session storage.
#[tauri::command]
fn enabled_local_usage_source_ids() -> Vec<String> {
    sorted_usage_source_ids(&enabled_usage_sources())
}

fn intersect_usage_sources(
    started: &HashSet<String>,
    final_sources: &HashSet<String>,
) -> HashSet<String> {
    started.intersection(final_sources).cloned().collect()
}

fn authorize_usage_report(
    source: &str,
    report: Option<usage::UsageReport>,
    started: &HashSet<String>,
    final_sources: &HashSet<String>,
) -> Option<usage::UsageReport> {
    let authorized = intersect_usage_sources(started, final_sources);
    report.filter(|_| authorized.contains(source))
}

fn fresh_cached_usage_reports(
    cache: &HashMap<&'static str, (Instant, usage::UsageReport)>,
    now: Instant,
) -> HashMap<String, usage::UsageReport> {
    cache
        .iter()
        .filter(|(_, (at, _))| now.saturating_duration_since(*at) < USAGE_REPORT_TTL)
        .map(|(source, (_, report))| ((*source).to_string(), report.clone()))
        .collect()
}

#[cfg(test)]
mod usage_source_gating_tests {
    use super::*;

    fn ids(list: &[&str]) -> HashSet<String> {
        list.iter().map(|s| (*s).to_string()).collect()
    }

    #[test]
    fn detected_agent_reports_cost_even_when_its_provider_is_off() {
        // Grok CLI có log trên máy nhưng provider Grok đang tắt: chi phí vẫn
        // phải được quét, chỉ quota/tab mới bị provider gate.
        let sources = usage_sources_for(&ids(&["claude"]), &ids(&["grok"]));
        assert!(sources.contains("grok"), "agent detected phải được quét");
        assert!(sources.contains("claude"), "provider bật phải được quét");
    }

    #[test]
    fn agents_without_a_provider_are_reachable() {
        // omp/pi/kiro không có provider tương ứng — trước đây bị bỏ quét hẳn.
        let sources = usage_sources_for(&HashSet::new(), &ids(&["omp", "pi", "kiro"]));
        for id in ["omp", "pi", "kiro"] {
            assert!(sources.contains(id), "{id} phải được quét khi detected");
        }
    }

    #[test]
    fn nothing_enabled_or_detected_scans_nothing() {
        assert!(usage_sources_for(&HashSet::new(), &HashSet::new()).is_empty());
    }

    #[test]
    fn only_the_six_local_cost_sources_are_ever_returned() {
        // Provider bật nhưng không phải nguồn cost cục bộ (vd. openai admin)
        // không được kéo theo một scanner không tồn tại.
        let sources = usage_sources_for(&ids(&["openai", "gemini", "claude"]), &HashSet::new());
        assert_eq!(sources, ids(&["claude"]));
    }

    #[test]
    fn local_usage_source_ids_are_canonical_and_sorted() {
        let sources =
            usage_sources_for(&ids(&["openai", "pi", "claude"]), &ids(&["kiro", "codex"]));

        assert_eq!(
            sorted_usage_source_ids(&sources),
            vec!["claude", "codex", "kiro", "pi"]
        );
    }

    #[test]
    fn report_authorization_requires_source_at_start_and_finish() {
        let report = usage::UsageReport::default();
        let started = ids(&["claude", "kiro"]);
        let revoked = ids(&["claude"]);

        assert!(authorize_usage_report("kiro", Some(report.clone()), &started, &revoked).is_none());
        assert!(authorize_usage_report("claude", Some(report), &started, &revoked).is_some());
        assert_eq!(intersect_usage_sources(&started, &revoked), revoked);
    }
}

#[cfg(test)]
mod kiro_usage_completion_tests {
    use super::*;

    #[test]
    fn incomplete_kiro_scan_is_not_exposed_as_live_usage() {
        let scan = kiro_scanner::KiroUsageScan {
            usage: usage::UsageReport::default(),
            completed: false,
        };

        assert!(completed_kiro_usage(&scan).is_none());
    }

    #[test]
    fn completed_kiro_scan_is_exposed_as_live_usage() {
        let scan = kiro_scanner::KiroUsageScan {
            usage: usage::UsageReport::default(),
            completed: true,
        };

        assert!(completed_kiro_usage(&scan).is_some());
    }
}

#[cfg(test)]
mod grok_counting_revision_tests {
    use super::*;
    use crate::config::TEST_ENV_LOCK as ENV_LOCK;
    use chrono::Local;
    use std::path::{Path, PathBuf};

    fn temp_config(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "birdnion-grok-counting-revision-{tag}-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn live_report(tokens: i64) -> usage::UsageReport {
        usage::UsageReport {
            daily: vec![usage::DailyUsage {
                date: Local::now().date_naive().to_string(),
                usd: 0.01,
                tokens,
                models: vec![],
            }],
            ..Default::default()
        }
    }

    fn stored_source_tokens(document: &cost_history::Document) -> i64 {
        document.sources["grok"]
            .values()
            .map(|day| day.tokens)
            .sum()
    }

    fn report_tokens(report: &usage::UsageReport) -> i64 {
        report.daily.iter().map(|day| day.tokens).sum()
    }

    fn cleanup(base: &Path) {
        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(base);
    }

    #[test]
    fn grok_call_path_replaces_old_revision_and_stamps_revision_three() {
        let _guard = ENV_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let base = temp_config("replace");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));
        assert!(cost_history::apply_and_report("grok", Some(&live_report(999))).live);

        let report = merge_grok_usage(Some(&live_report(25)));
        let document = cost_history::read();
        cleanup(&base);

        assert!(report.live);
        assert_eq!(report_tokens(&report), 25);
        assert_eq!(stored_source_tokens(&document), 25);
        assert_eq!(document.counting_revision.get("grok"), Some(&3));
    }

    #[test]
    fn grok_call_path_does_not_stamp_without_valid_live_data() {
        let _guard = ENV_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let base = temp_config("deferred");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));
        assert!(cost_history::apply_and_report("grok", Some(&live_report(999))).live);
        let path = cost_history::history_path().unwrap();
        let original = std::fs::read(&path).unwrap();

        let missing = merge_grok_usage(None);
        let after_missing = cost_history::read();
        let mut invalid = live_report(25);
        invalid.daily[0].usd = -1.0;
        let rejected = merge_grok_usage(Some(&invalid));
        let after_invalid = cost_history::read();
        let persisted = std::fs::read(path).unwrap();
        cleanup(&base);

        assert!(!missing.live);
        assert_eq!(report_tokens(&missing), 999);
        assert!(!rejected.live);
        assert_eq!(report_tokens(&rejected), 999);
        assert_eq!(after_missing.counting_revision.get("grok"), None);
        assert_eq!(after_invalid.counting_revision.get("grok"), None);
        assert_eq!(persisted, original);
    }

    #[test]
    fn grok_call_path_does_not_downgrade_a_future_revision() {
        let _guard = ENV_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let base = temp_config("future");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));
        let seeded =
            cost_history::apply_and_report_at_counting_revision("grok", Some(&live_report(999)), 4);
        assert!(seeded.live);
        let path = cost_history::history_path().unwrap();
        let original = std::fs::read(&path).unwrap();

        let report = merge_grok_usage(Some(&live_report(25)));
        let document = cost_history::read();
        let persisted = std::fs::read(path).unwrap();
        cleanup(&base);

        assert!(!report.live);
        assert_eq!(report_tokens(&report), 999);
        assert_eq!(stored_source_tokens(&document), 999);
        assert_eq!(document.counting_revision.get("grok"), Some(&4));
        assert_eq!(persisted, original);
    }
}

#[cfg(test)]
mod project_insights_cache_tests {
    use super::*;

    #[test]
    fn stale_usage_cache_is_not_reported_as_live_insights() {
        let now = Instant::now();
        let cache = HashMap::from([
            (
                "claude",
                (
                    now - USAGE_REPORT_TTL - Duration::from_secs(1),
                    usage::UsageReport::default(),
                ),
            ),
            (
                "codex",
                (now - Duration::from_secs(1), usage::UsageReport::default()),
            ),
        ]);

        let fresh = fresh_cached_usage_reports(&cache, now);

        assert!(!fresh.contains_key("claude"));
        assert!(fresh.contains_key("codex"));
    }
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
    providers::error_classifier::classify(raw.as_deref()).map(|kind| kind.key_suffix().to_string())
}

/// Whether a raw provider error is transient enough that the JS poller
/// should keep showing the last-good quota windows instead of collapsing to
/// an error-only card (network/timeout, rate-limit, genuine 5xx). Single
/// source of truth shared with the macOS `isTransientForLastGood` policy —
/// see `providers::error_classifier::is_transient_for_last_good`.
#[tauri::command]
fn is_transient_provider_error(raw: Option<String>) -> bool {
    providers::error_classifier::is_transient_for_last_good(raw.as_deref())
}

/// Whether a raw provider error is something Settings can actually fix —
/// gates the popover/self-test "Fix" button so it never shows for rate-limit
/// or network errors. See `ProviderErrorKind::is_fixable`.
#[tauri::command]
fn is_fixable_provider_error(raw: Option<String>) -> bool {
    providers::error_classifier::classify(raw.as_deref())
        .map(|kind| kind.is_fixable())
        .unwrap_or(false)
}

/// Maps a classified failure to the exact Settings remediation target shared
/// with macOS. `None` is intentionally details/retry-only.
#[tauri::command]
fn provider_remediation_target(provider_id: String, raw: Option<String>) -> Option<String> {
    let kind = providers::error_classifier::classify(raw.as_deref())?;
    providers::error_classifier::remediation_target(&provider_id, kind).map(str::to_string)
}

#[derive(Debug, PartialEq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct ProviderOnboardingDetection {
    is_ready: bool,
    source: String,
}

fn onboarding_detection_from_flags(
    has_primary: bool,
    primary: &str,
    has_secondary: bool,
    secondary: &str,
    fallback: &str,
) -> ProviderOnboardingDetection {
    ProviderOnboardingDetection {
        is_ready: has_primary || has_secondary,
        source: if has_primary {
            primary
        } else if has_secondary {
            secondary
        } else {
            fallback
        }
        .to_string(),
    }
}

/// Safe readiness probe for first-run onboarding. It checks only path and
/// executable existence; it never opens or parses a credential file.
#[tauri::command]
fn provider_onboarding_detection(id: String) -> ProviderOnboardingDetection {
    match id.as_str() {
        "claude" => {
            let current_platform = platform::paths::Platform::current();
            let has_file = platform::paths::claude_config_dirs()
                .into_iter()
                .map(|path| {
                    if platform::paths::is_projects_dir(&path, current_platform) {
                        path.parent()
                            .map(std::path::Path::to_path_buf)
                            .unwrap_or(path)
                    } else {
                        path
                    }
                })
                .any(|path| path.join(".credentials.json").is_file());
            let has_cli = platform::executable::resolve_executable("claude").is_some();
            onboarding_detection_from_flags(
                has_file,
                "Claude Code",
                has_cli,
                "Claude CLI",
                "Claude Code / CLI",
            )
        }
        "codex" => {
            let has_file =
                platform::paths::codex_home().is_some_and(|path| path.join("auth.json").is_file());
            let has_cli = platform::executable::resolve_executable("codex").is_some();
            onboarding_detection_from_flags(
                has_file,
                "Codex login",
                has_cli,
                "Codex CLI",
                "Codex login / CLI",
            )
        }
        "grok" => {
            let root = platform::paths::grok_home();
            let has_auth = root
                .as_ref()
                .is_some_and(|path| path.join("auth.json").is_file());
            let has_sessions = root.is_some_and(|path| path.join("sessions").is_dir());
            onboarding_detection_from_flags(
                has_auth,
                "Grok login",
                has_sessions,
                "Grok sessions",
                "Grok login / sessions",
            )
        }
        _ => onboarding_detection_from_flags(false, "", false, "", ""),
    }
}

#[cfg(test)]
mod onboarding_detection_tests {
    use super::*;

    #[test]
    fn detection_prefers_primary_then_secondary() {
        assert_eq!(
            onboarding_detection_from_flags(true, "login", true, "cli", "none"),
            ProviderOnboardingDetection {
                is_ready: true,
                source: "login".into()
            }
        );
        assert_eq!(
            onboarding_detection_from_flags(false, "login", true, "cli", "none"),
            ProviderOnboardingDetection {
                is_ready: true,
                source: "cli".into()
            }
        );
        assert_eq!(
            onboarding_detection_from_flags(false, "login", false, "cli", "none"),
            ProviderOnboardingDetection {
                is_ready: false,
                source: "none".into()
            }
        );
    }
}

/// Runs a single self-test fetch for one provider (never the whole refresh
/// loop). Returns a failure status keyed to `provider.selfTest.disabled`
/// when the provider is not found in settings.json. The Settings onboarding
/// persists the enabled flag before this command, but the probe itself does
/// not rely on a second config reload race.
#[tauri::command]
async fn test_provider(id: String) -> providers::ProviderStatus {
    let cfg = config::load().providers.into_iter().find(|p| p.id == id);
    match cfg {
        Some(cfg) => providers::fetch(&cfg).await,
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
        .unwrap_or_else(|| config::Provider {
            id: "claude".to_string(),
            ..Default::default()
        });
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
    let target = scope.as_ref().map(claude_code::target_path);
    if scope.is_some() && target.is_none() {
        return ClaudeCodeState {
            state: "unavailable",
            target_path: None,
        };
    }
    let sync = match (&scope, configured) {
        (Some(sc), true) => {
            let spec = claude_code::spec_for_provider(provider_id, &provider);
            let sync = spec
                .as_ref()
                .map(|s| claude_code::sync_state(s, sc))
                .unwrap_or(claude_code::SyncState::Off);
            sync
        }
        _ => claude_code::SyncState::Off,
    };
    let power = claude_code::power_state(configured, sync);
    let state = match power {
        claude_code::PowerState::On => "on",
        claude_code::PowerState::Off => "off",
        claude_code::PowerState::Stale => "stale",
        claude_code::PowerState::NeedsSetup => "needsSetup",
    };
    ClaudeCodeState {
        state,
        target_path: target.map(|path| path.to_string_lossy().to_string()),
    }
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
        return ClaudeCodeState {
            state: "needsSetup",
            target_path: None,
        };
    };
    let scope = claude_code::profile_scope(&profile);
    let configured = scope.is_some() && claude_code::profile_ready(&profile);
    let target = scope.as_ref().map(claude_code::target_path);
    if scope.is_some() && target.is_none() {
        return ClaudeCodeState {
            state: "unavailable",
            target_path: None,
        };
    }
    let sync = match (&scope, configured) {
        (Some(sc), true) => claude_code::sync_state_for_profile(&profile, sc),
        _ => claude_code::SyncState::Off,
    };
    let state = match claude_code::power_state(configured, sync) {
        claude_code::PowerState::On => "on",
        claude_code::PowerState::Off => "off",
        claude_code::PowerState::Stale => "stale",
        claude_code::PowerState::NeedsSetup => "needsSetup",
    };
    ClaudeCodeState {
        state,
        target_path: target.map(|path| path.to_string_lossy().to_string()),
    }
}

#[tauri::command]
fn claude_code_profile_state(profile_id: String) -> ClaudeCodeState {
    claude_code_profile_state_for(&profile_id)
}

#[tauri::command]
fn claude_code_profile_apply(profile_id: String) -> Result<ClaudeCodeState, String> {
    let profile =
        config::find_profile(&profile_id).ok_or_else(|| "Không tìm thấy config".to_string())?;
    let scope = claude_code::profile_scope(&profile)
        .ok_or_else(|| "Chưa chọn thư mục project".to_string())?;
    let spec = claude_code::spec_for_profile(&profile)
        .ok_or_else(|| "Nhập Base URL + Token để bật".to_string())?;
    claude_code::apply(&spec, &scope)?;
    Ok(claude_code_profile_state_for(&profile_id))
}

#[tauri::command]
fn claude_code_profile_deactivate(profile_id: String) -> Result<ClaudeCodeState, String> {
    let profile =
        config::find_profile(&profile_id).ok_or_else(|| "Không tìm thấy config".to_string())?;
    let scope = claude_code::profile_scope(&profile)
        .ok_or_else(|| "Chưa chọn thư mục project".to_string())?;
    claude_code::deactivate(&scope)?;
    Ok(claude_code_profile_state_for(&profile_id))
}

#[tauri::command]
fn claude_code_profile_remove_env(profile_id: String) -> Result<bool, String> {
    let profile =
        config::find_profile(&profile_id).ok_or_else(|| "Không tìm thấy config".to_string())?;
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
    quota_snapshots: HashMap<String, codex_accounts::AccountQuotaSnapshot>,
    settings: config::Settings,
}

#[tauri::command]
fn codex_accounts_list() -> CodexAccountsState {
    CodexAccountsState {
        accounts: codex_accounts::all_accounts(),
        active_id: codex_accounts::active_id(),
        quota_snapshots: codex_accounts::quota_snapshots(),
        settings: config::load(),
    }
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

/// Antigravity Google OAuth accounts. The returned descriptors intentionally
/// contain only label/email; tokens and client credentials stay in Rust.
#[tauri::command]
fn antigravity_accounts_list() -> providers::antigravity::OAuthAccountsState {
    providers::antigravity::accounts_list()
}

#[tauri::command]
fn antigravity_account_add(
    credential_json: String,
    label: Option<String>,
    email: Option<String>,
) -> Result<providers::antigravity::OAuthAccountsState, String> {
    providers::antigravity::account_add(&credential_json, label.as_deref(), email.as_deref())
}

#[tauri::command]
fn antigravity_account_switch(
    label: String,
) -> Result<providers::antigravity::OAuthAccountsState, String> {
    providers::antigravity::account_switch(&label)
}

#[tauri::command]
fn antigravity_account_remove(
    label: String,
) -> Result<providers::antigravity::OAuthAccountsState, String> {
    providers::antigravity::account_remove(&label)
}

/// FreeModel multi-account state — implicit "browser" entry (auto scan) +
/// one entry per signed-in browser + managed pasted-cookie accounts, plus
/// the active id.
#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct FreemodelAccountsState {
    accounts: Vec<freemodel_accounts::FreemodelAccount>,
    active_id: String,
    settings: config::Settings,
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
                FM_BROWSER_EMAILS
                    .lock()
                    .unwrap()
                    .insert(browser.to_string(), email.clone());
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
    FreemodelAccountsState {
        accounts,
        active_id: freemodel_accounts::active_id(),
        settings: config::load(),
    }
}

#[tauri::command]
async fn freemodel_accounts_list() -> FreemodelAccountsState {
    freemodel_state().await
}

/// Validates a pasted FreeModel cookie (must carry `bm_session`; a bare token
/// is wrapped), resolves the account email best-effort, and stores it as a
/// new managed account.
#[tauri::command]
async fn freemodel_account_add(
    cookie: String,
    label: Option<String>,
) -> Result<FreemodelAccountsState, String> {
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

/// ElevenLabs multi-key state — managed keys + active id (secrets never leave Rust).
#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct ElevenLabsKeysState {
    keys: Vec<elevenlabs_keys::ElevenLabsKey>,
    active_id: Option<String>,
    settings: config::Settings,
}

fn elevenlabs_keys_state() -> ElevenLabsKeysState {
    ElevenLabsKeysState {
        keys: elevenlabs_keys::all_keys(),
        active_id: elevenlabs_keys::active_id(),
        settings: config::load(),
    }
}

#[tauri::command]
fn elevenlabs_keys_list() -> ElevenLabsKeysState {
    elevenlabs_keys_state()
}

#[tauri::command]
fn elevenlabs_key_add(
    api_key: String,
    label: Option<String>,
) -> Result<ElevenLabsKeysState, String> {
    elevenlabs_keys::add(&api_key, label.as_deref())?;
    Ok(elevenlabs_keys_state())
}

#[tauri::command]
fn elevenlabs_key_switch(id: String) -> Result<ElevenLabsKeysState, String> {
    elevenlabs_keys::set_active(&id)?;
    Ok(elevenlabs_keys_state())
}

#[tauri::command]
fn elevenlabs_key_remove(id: String) -> Result<ElevenLabsKeysState, String> {
    elevenlabs_keys::remove(&id)?;
    Ok(elevenlabs_keys_state())
}

/// Hiyo multi-key state — managed keys + active id (secrets never leave Rust).
#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct HiyoKeysState {
    keys: Vec<hiyo_keys::HiyoKey>,
    active_id: Option<String>,
    settings: config::Settings,
}

fn hiyo_keys_state() -> HiyoKeysState {
    HiyoKeysState {
        keys: hiyo_keys::all_keys(),
        active_id: hiyo_keys::active_id(),
        settings: config::load(),
    }
}

#[tauri::command]
fn hiyo_keys_list() -> HiyoKeysState {
    hiyo_keys_state()
}

#[tauri::command]
fn hiyo_key_add(api_key: String, label: Option<String>) -> Result<HiyoKeysState, String> {
    hiyo_keys::add(&api_key, label.as_deref())?;
    Ok(hiyo_keys_state())
}

#[tauri::command]
fn hiyo_key_switch(id: String) -> Result<HiyoKeysState, String> {
    hiyo_keys::set_active(&id)?;
    Ok(hiyo_keys_state())
}

#[tauri::command]
fn hiyo_key_remove(id: String) -> Result<HiyoKeysState, String> {
    hiyo_keys::remove(&id)?;
    Ok(hiyo_keys_state())
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
async fn copilot_login_poll(
    device_code: String,
) -> Result<providers::copilot_oauth::PollResult, String> {
    providers::copilot_oauth::poll("github.com", &device_code).await
}

/// Full settings.json content for the Settings view (local app — keys stay
/// on this machine, same plaintext-by-design store as macOS).
#[tauri::command]
fn get_settings() -> Result<config::Settings, String> {
    config::load_checked()
}

/// Persist the whole settings document (atomic write, 0600).
/// Runs Claude→Codex upstream mirror sync so linked records stay consistent
/// even when the frontend bulk-saves the whole settings blob. Returns the new
/// optimistic-concurrency revision for the caller's in-memory snapshot.
#[tauri::command]
fn save_settings(mut settings: config::Settings) -> Result<u64, String> {
    let _ = config::migrate_standalone_codex_profiles(&mut settings);
    config::mirror_claude_to_codex(&mut settings);
    config::save_frontend_snapshot(settings)
}

// --- Codex CLI profile activation (macOS CodexConfigWriter parity) -----------

#[tauri::command]
fn codex_profile_state(id: String) -> codex_config::CodexProfileState {
    codex_config::profile_state(&id)
}

#[tauri::command]
fn codex_active_id() -> Option<String> {
    codex_config::active_profile_id(None)
}

#[tauri::command]
async fn codex_apply(
    app: tauri::AppHandle,
    id: String,
) -> Result<codex_config::CodexProfileState, String> {
    let target = codex_config::target_config_path();
    let mut profile =
        config::find_codex_profile(&id).ok_or_else(|| "Không tìm thấy config Codex".to_string())?;
    if !profile.has_upstream_configuration() {
        return Err("Thiếu Base URL, API key hoặc model cho Codex".into());
    }

    if profile.uses_embedded_cli_proxy() {
        let st = cli_proxy::prepare_codex_profile_cmd(&app, &id).await?;
        if st.state != "running" {
            return Err("Không khởi động được proxy local cho Codex".into());
        }
        // Reload after prepare stamped loopback keys + signature.
        profile = config::find_codex_profile(&id)
            .ok_or_else(|| "Không tìm thấy config Codex".to_string())?;
        codex_config::apply(&profile, Some(&target))?;
    } else {
        profile.cli_proxy_applied_signature = None;
        config::save_codex_profile(profile.clone())?;
        codex_config::apply(&profile, Some(&target))?;
        let _ = cli_proxy::deactivate_codex_proxy_profiles(&app).await;
    }

    // Per-project overlay — same content as global apply.
    codex_config::write_profile_file(&profile, Some(&target))?;
    Ok(codex_config::profile_state(&id))
}

#[tauri::command]
async fn codex_deactivate(
    app: tauri::AppHandle,
    id: String,
) -> Result<codex_config::CodexProfileState, String> {
    let target = codex_config::target_config_path();
    let _ = codex_config::deactivate(Some(&target))?;
    if let Some(mut profile) = config::find_codex_profile(&id) {
        profile.cli_proxy_applied_signature = None;
        config::save_codex_profile(profile)?;
    }
    let _ = cli_proxy::deactivate_codex_proxy_profiles(&app).await;
    Ok(codex_config::profile_state(&id))
}

#[tauri::command]
async fn codex_delete(
    app: tauri::AppHandle,
    id: String,
    delete_linked_claude: bool,
) -> Result<(), String> {
    let target = codex_config::target_config_path();
    // Best-effort: if this was the active proxy codex profile, drop it from helper.
    if let Some(p) = config::find_codex_profile(&id) {
        if p.uses_embedded_cli_proxy() {
            let _ = cli_proxy::deactivate_codex_proxy_profiles(&app).await;
        }
    }
    let _ = &target;
    codex_config::delete_profile(&id, delete_linked_claude)
}

/// Ensure a custom Claude profile has a linked Codex counterpart (create if needed).
#[tauri::command]
fn codex_ensure_counterpart(claude_profile_id: String) -> Result<config::CodexProfile, String> {
    config::update(|settings| {
        let claude = settings
            .claude_code_profiles
            .iter()
            .find(|p| p.id == claude_profile_id)
            .cloned()
            .ok_or_else(|| "Không tìm thấy config Claude".to_string())?;

        if let Some(cid) = claude
            .codex_profile_id
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            if let Some(existing) = settings.codex_profiles.iter().find(|c| c.id == cid) {
                return Ok(existing.clone());
            }
        }

        let created = config::make_codex_profile_from_claude(&claude, uuid_v4());
        let created_id = created.id.clone();
        settings.codex_profiles.push(created.clone());
        if let Some(claude) = settings
            .claude_code_profiles
            .iter_mut()
            .find(|profile| profile.id == claude_profile_id)
        {
            claude.codex_profile_id = Some(created_id);
        }
        Ok(created)
    })
}

/// Ensure a preset provider has a derived Codex profile (Anthropic + local proxy).
#[tauri::command]
fn codex_ensure_preset(provider_id: String) -> Result<config::CodexProfile, String> {
    config::update(|settings| {
        let provider = settings
            .providers
            .iter()
            .find(|p| p.id == provider_id)
            .cloned()
            .ok_or_else(|| "Không tìm thấy provider".to_string())?;
        let base = claude_code::base_url_for_provider(&provider_id, &provider)
            .ok_or_else(|| "Thiếu Base URL, API key hoặc model cho Codex".to_string())?;
        let key = provider
            .api_key
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .ok_or_else(|| "Thiếu Base URL, API key hoặc model cho Codex".to_string())?
            .to_string();

        if let Some(cid) = provider
            .codex_profile_id
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            if let Some(idx) = settings.codex_profiles.iter().position(|c| c.id == cid) {
                let existing = &mut settings.codex_profiles[idx];
                if existing.base_url != base || existing.api_key != key {
                    existing.base_url = base;
                    existing.api_key = key;
                    existing.cli_proxy_applied_signature = None;
                }
                return Ok(existing.clone());
            }
        }

        let name = provider
            .display_name
            .clone()
            .filter(|s| !s.trim().is_empty())
            .unwrap_or_else(|| provider_id.clone());
        let created = config::CodexProfile {
            id: uuid_v4(),
            name,
            base_url: base,
            api_key: key,
            model: String::new(),
            upstream_protocol_raw: Some(config::CodexProfile::PROTOCOL_ANTHROPIC.into()),
            connection_mode_raw: Some(config::CodexProfile::MODE_LOCAL_PROXY.into()),
            ..Default::default()
        };
        let created_id = created.id.clone();
        settings.codex_profiles.push(created.clone());
        if let Some(p) = settings.providers.iter_mut().find(|p| p.id == provider_id) {
            p.codex_profile_id = Some(created_id);
        }
        Ok(created)
    })
}

/// Minimal UUID v4 (no extra crate) — same approach as codex_accounts.
fn uuid_v4() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let mut bytes = [0u8; 16];
    let _ = getrandom::getrandom(&mut bytes);
    // Mix time for uniqueness when getrandom is weak in tests.
    let t = nanos.to_le_bytes();
    for i in 0..8 {
        bytes[i] ^= t[i % t.len()];
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
    )
}

/// OS notification (quota warnings) — the JS side owns the threshold logic,
/// mirroring the macOS QuotaNotifier's fire-once-per-crossing behavior.
#[tauri::command]
fn notify(app: tauri::AppHandle, title: String, body: String) -> Result<(), String> {
    app.notification()
        .builder()
        .title(title)
        .body(body)
        // Match the icon name installed by the Linux desktop bundle instead
        // of relying on the notification daemon to infer it from the process.
        .icon("birdnion")
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

/// Tray-slot wordmark: the light-on-dark "BN" mark. The app icon is the
/// dark-ink variant made for light dock backgrounds, so reusing it here left
/// the mark nearly invisible on the GNOME panel (dark by default).
const TRAY_ICON_PNG: &[u8] = include_bytes!("../icons/tray.png");

/// Default (no-percent) tray image. `None` when the bundled wordmark fails to
/// decode, so callers can fall back to the app's own window icon.
fn tray_default_icon() -> Option<Image<'static>> {
    Image::from_bytes(TRAY_ICON_PNG).ok()
}

/// Fingerprint of the image last handed to the tray, so repeated polls that
/// resolve to the same frame become no-ops.
///
/// `tray-icon`'s GTK backend writes every `set_icon` to a *new* temp PNG and
/// deletes the previous one, so re-publishing an unchanged icon churned that
/// file for nothing — the refresh poll re-sends the current frame on every
/// tick, and a single-provider rotation re-sends the same frame every 5 s.
/// A genuine change (new percent, or back to the plain wordmark) still has a
/// different fingerprint and goes through.
static TRAY_ICON_FINGERPRINT: LazyLock<Mutex<Option<u64>>> = LazyLock::new(|| Mutex::new(None));

/// Cheap content hash — only used to detect "same frame as last time".
fn tray_icon_fingerprint(icon_png: Option<&[u8]>) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    match icon_png {
        // Discriminate the default-logo case from an (unlikely) empty payload.
        None => 0u8.hash(&mut hasher),
        Some(bytes) => {
            1u8.hash(&mut hasher);
            bytes.hash(&mut hasher);
        }
    }
    hasher.finish()
}

/// Tray status mirror of the macOS menu-bar percent readout.
///
/// Visual contract (macOS NSStatusItem parity): **`91%` then provider logo**.
/// The JS side paints that into a single composite PNG (`icon_png`) because
/// tray-icon places the image left of the title on macOS; compositing keeps
/// the percent→logo order.
///
/// On Linux (GNOME AppIndicator / StatusNotifier), `title` is a **panel label**
/// drawn at full system type size — putting `"59%"` there makes the percent
/// look comically large next to the bird. Always clear the title slot; the
/// percent must live inside `icon_png` only.
///
/// * `tooltip` — hover text (macOS/Windows; unsupported on Linux panel).
/// * `title` — ignored on Linux; always cleared. Kept in the signature so
///   older frontends still call this command without schema break.
/// * `icon_png` — composite frame PNG, or `None` to restore the default logo.
#[tauri::command]
fn set_tray_status(
    app: tauri::AppHandle,
    tooltip: String,
    title: Option<String>,
    icon_png: Option<Vec<u8>>,
) {
    let _ = title; // intentionally unused — see doc above
    if let Some(tray) = app.tray_by_id("main-tray") {
        let _ = tray.set_tooltip(Some(tooltip.as_str()));
        // Always clear the StatusNotifier label. `None` and `Some("")` both
        // needed across tray-icon/ayatana versions — try both.
        let _ = tray.set_title(None::<&str>);
        let _ = tray.set_title(Some(""));

        // Skip redundant repaints: `tray-icon` writes a fresh temp PNG (and
        // deletes the old one) on every `set_icon`, so re-publishing the same
        // frame each poll churned the file the panel is reading from.
        let fingerprint = tray_icon_fingerprint(icon_png.as_deref());
        let mut last = TRAY_ICON_FINGERPRINT.lock().unwrap();
        if *last == Some(fingerprint) {
            return;
        }

        let applied = match icon_png {
            Some(bytes) => match Image::from_bytes(&bytes) {
                Ok(img) => {
                    let _ = tray.set_icon(Some(img));
                    // Colors (incl. white-tinted logos) are baked into the PNG.
                    let _ = tray.set_icon_as_template(false);
                    true
                }
                Err(_) => false,
            },
            None => {
                let fallback = tray_default_icon().or_else(|| app.default_window_icon().cloned());
                match fallback {
                    Some(img) => {
                        let _ = tray.set_icon(Some(img));
                        let _ = tray.set_icon_as_template(false);
                        true
                    }
                    None => false,
                }
            }
        };
        if applied {
            *last = Some(fingerprint);
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

/// Catalog agent cài trên máy cho Settings → Agent (macOS parity).
/// Quota lấy từ provider đang bật, chi phí 90 ngày lấy từ cost-history.
#[tauri::command]
/// `provider_ids_with_quota`: id của provider đang có quota window, do phía
/// giao diện truyền xuống.
///
/// Trước đây hàm này tự gọi `provider_statuses(None)` — một lượt fetch mạng
/// TOÀN BỘ provider. Nó chạy song song với chính fan-out của `load()` nên mỗi
/// lần nạp là gọi API provider hai lần, và `inFlightProviderIds` phía web
/// không chặn được vì đây là lệnh khác. Caller đã có sẵn danh sách này rồi,
/// nên chỉ cần truyền xuống.
async fn list_installed_agents(
    provider_ids_with_quota: Option<Vec<String>>,
) -> Vec<installed_agents::InstalledAgent> {
    let with_quota = provider_ids_with_quota.unwrap_or_default();

    // Tổng 90 ngày theo source, đọc thẳng từ history đã lưu.
    let doc = cost_history::read();
    let today = chrono::Local::now().date_naive();
    let cutoff = today - chrono::Duration::days(89);
    let mut totals: HashMap<String, f64> = HashMap::new();
    for (source, days) in &doc.sources {
        let mut sum = 0.0;
        for (day, entry) in days {
            if let Ok(parsed) = chrono::NaiveDate::parse_from_str(day, "%Y-%m-%d") {
                if parsed >= cutoff && parsed <= today {
                    sum += entry.usd;
                }
            }
        }
        totals.insert(source.clone(), sum);
    }

    installed_agents::detect(&with_quota, &totals)
}

/// Mở (hoặc cập nhật) cửa sổ panel phụ cạnh popover — port của macOS
/// `AgentDetailPanelCoordinator`. `pinned=false` là panel transient do hover,
/// sẽ bị `close_side_panel` đóng khi chuột rời; panel đã ghim chỉ đóng bằng
/// nút ✕ trong nội dung.
/// Panel có đang được MUỐN hiện hay không.
///
/// `open_side_panel` là async và lần đầu phải dựng hẳn một cửa sổ, trong khi
/// `close_side_panel` chạy đồng bộ. Rê chuột qua rồi rời ngay thì lệnh đóng
/// chạy trước lúc cửa sổ dựng xong: `get_webview_window("panel")` trả `None`
/// nên chẳng ẩn được gì, và cửa sổ hiện ra sau đó nằm lại trên màn hình.
/// Cờ này cho lệnh đóng "thắng" cuộc đua — cửa sổ vừa dựng thấy ý định đã bị
/// huỷ thì tự ẩn ngay.
static PANEL_WANTED: AtomicBool = AtomicBool::new(false);

/// Log vòng đời panel ra stderr khi đặt `BIRDNION_PANEL_DEBUG=1` — dùng để
/// truy vết đua mở/đóng mà không phải đoán.
fn panel_log(msg: &str) {
    if std::env::var_os("BIRDNION_PANEL_DEBUG").is_some() {
        eprintln!("[panel] {msg}");
    }
}

/// Beacon tạm để truy vết vòng đời hover phía web.
#[tauri::command]
fn panel_debug(msg: String) {
    panel_log(&msg);
}

/// Trả focus về popover ngay sau khi hiện panel.
///
/// `show()` có thể kích hoạt cửa sổ tuỳ nền tảng. Chỉ cửa sổ key mới nhận sự
/// kiện chuột, nên nếu panel giữ focus thì popover ngừng nhận
/// `mouseover`/`mouseleave` và panel hover sẽ không bao giờ đóng được. Đây là
/// cách bù cho việc Tauri không có "panel không-thành-key" như NSPanel.
fn keep_popover_key(app: &tauri::AppHandle) {
    use tauri::Manager;
    if let Some(main) = app.get_webview_window("main") {
        if main.is_visible().unwrap_or(false) {
            let _ = main.set_focus();
        }
    }
}

#[tauri::command]
async fn open_side_panel(
    app: tauri::AppHandle,
    payload: serde_json::Value,
    pinned: bool,
) -> Result<(), String> {
    use tauri::{Emitter, Manager, WebviewUrl, WebviewWindowBuilder};

    PANEL_WANTED.store(true, Ordering::SeqCst);
    let kind = payload.get("kind").and_then(|v| v.as_str()).unwrap_or("?");
    panel_log(&format!("open kind={kind} pinned={pinned}"));
    let payload_json = serde_json::to_string(&payload).map_err(|e| e.to_string())?;

    if let Some(existing) = app.get_webview_window("panel") {
        let _ = existing.emit("birdnion-panel-payload", payload.clone());
        position_panel_beside_main(&app, &existing);
        if PANEL_WANTED.load(Ordering::SeqCst) {
            let _ = existing.show();
            keep_popover_key(&app);
            panel_log("open: reused existing window");
        } else {
            let _ = existing.hide();
            panel_log("open: cancelled before show (reuse)");
        }
        return Ok(());
    }

    // Dựng ẩn rồi mới hiện: tránh nháy, và cho phép huỷ giữa chừng.
    // Seed payload trước khi script chạy để panel không nháy trống.
    let init = format!("window.__BIRDNION_PANEL__={payload_json};");
    let win = WebviewWindowBuilder::new(&app, "panel", WebviewUrl::App("panel.html".into()))
        .title("BirdNion")
        .inner_size(340.0, 430.0)
        .resizable(false)
        .decorations(false)
        .always_on_top(true)
        .skip_taskbar(true)
        .visible(false)
        // KHÔNG BAO GIỜ lấy focus. Cửa sổ key mới được nhận sự kiện chuột, nên
        // panel mà giành focus thì popover ngừng nhận `mouseover`/`mouseleave`
        // — hover mở panel xong là không cách nào đóng lại được. macOS dùng
        // NSPanel không-thành-key chính vì lý do này.
        .focused(false)
        .initialization_script(&init)
        .build()
        .map_err(|e| e.to_string())?;
    position_panel_beside_main(&app, &win);
    // Chuột đã rời trong lúc dựng → không hiện nữa.
    if PANEL_WANTED.load(Ordering::SeqCst) {
        let _ = win.show();
        keep_popover_key(&app);
        panel_log("open: built and shown");
    } else {
        panel_log("open: cancelled while building");
    }
    Ok(())
}

/// Update an existing visible panel without changing its visibility intent.
/// Status ticks use this command so stale JS state cannot reopen a panel that
/// is concurrently closing through × or the main popover lifecycle.
#[tauri::command]
fn update_side_panel(
    app: tauri::AppHandle,
    payload: serde_json::Value,
) -> Result<(), String> {
    use tauri::{Emitter, Manager};

    if !PANEL_WANTED.load(Ordering::SeqCst) {
        panel_log("update: ignored because panel is not wanted");
        return Ok(());
    }
    let Some(panel) = app.get_webview_window("panel") else {
        return Ok(());
    };
    if !panel.is_visible().unwrap_or(false) {
        panel_log("update: ignored because panel is hidden");
        return Ok(());
    }
    let _ = panel.emit("birdnion-panel-payload", payload);
    position_panel_beside_main(&app, &panel);
    Ok(())
}

/// Ẩn panel phụ (hover rời hoặc bấm ✕).
///
/// Báo về popover để nó bỏ cờ ghim: nếu không, sau khi bấm ✕ phía popover vẫn
/// tưởng panel đang ghim và chặn mọi lần hover mở lại.
#[tauri::command]
fn close_side_panel(app: tauri::AppHandle) -> Result<(), String> {
    use tauri::{Emitter, Manager};
    // Đặt trước khi ẩn: nếu cửa sổ đang dựng dở, nó sẽ thấy cờ này và không hiện.
    PANEL_WANTED.store(false, Ordering::SeqCst);
    match app.get_webview_window("panel") {
        Some(panel) => {
            let _ = panel.hide();
            panel_log("close: hidden");
        }
        None => panel_log("close: no window yet (intent cleared)"),
    }
    if let Some(main) = app.get_webview_window("main") {
        let _ = main.emit("birdnion-panel-closed", ());
    }
    Ok(())
}

/// Neo panel vào cạnh phải popover, lệch 4px như bản macOS.
const PANEL_WIDTH: f64 = 340.0;
const PANEL_MIN_HEIGHT: f64 = 180.0;
/// Chừa mép màn hình như macOS `position(_:beside:)`.
const PANEL_SCREEN_MARGIN: f64 = 16.0;

fn position_panel_beside_main(app: &tauri::AppHandle, panel: &tauri::WebviewWindow) {
    use tauri::Manager;
    let Some(main) = app.get_webview_window("main") else {
        return;
    };
    let (Ok(pos), Ok(size)) = (main.outer_position(), main.outer_size()) else {
        return;
    };
    let x = pos.x + size.width as i32 + 4;
    let _ = panel.set_position(tauri::PhysicalPosition::new(x, pos.y));
}

/// Khớp chiều cao panel với nội dung thật (macOS `refitToContent`).
///
/// Panel cố định 430px thì tab ngắn thừa khoảng trắng, tab dài lại phải cuộn.
/// Trang panel tự đo `scrollHeight` rồi gọi lệnh này; ở đây chỉ chặn trên theo
/// chiều cao màn hình để panel không tràn ra ngoài.
#[tauri::command]
fn resize_side_panel(app: tauri::AppHandle, height: f64) -> Result<(), String> {
    use tauri::Manager;
    let Some(panel) = app.get_webview_window("panel") else {
        return Ok(());
    };

    let scale = panel.scale_factor().unwrap_or(1.0);
    let available = panel
        .current_monitor()
        .ok()
        .flatten()
        .map(|m| m.size().height as f64 / scale - PANEL_SCREEN_MARGIN * 2.0)
        .unwrap_or(900.0);
    let clamped = height.max(PANEL_MIN_HEIGHT).min(available);

    let _ = panel.set_size(tauri::LogicalSize::new(PANEL_WIDTH, clamped));
    position_panel_beside_main(&app, &panel);
    panel_log(&format!("resize to {clamped:.0} (asked {height:.0})"));
    Ok(())
}

/// Open (or focus) the dedicated Settings window — macOS Settings scene parity
/// (780×720, separate from the tray popover).
#[tauri::command]
fn open_settings_window(app: tauri::AppHandle, section: Option<String>) -> Result<(), String> {
    open_settings_window_impl(&app, section.as_deref())
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
    // macOS SettingsSceneRoot: fixed 920×620 (parity with SwiftUI frame).
    let win = WebviewWindowBuilder::new(app, "settings", WebviewUrl::App("settings.html".into()))
        .title("BirdNion Settings")
        .inner_size(920.0, 620.0)
        .min_inner_size(780.0, 520.0)
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
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
    }
}

/// Ẩn popover thì panel phụ phải đi cùng — nếu không nó lơ lửng một mình
/// trên màn hình (macOS `AppDelegate` gọi `agentDetailCoordinator.close()`
/// mỗi lần đóng popover).
fn hide_side_panel_with_popover(app: &tauri::AppHandle) {
    use tauri::{Emitter, Manager};
    PANEL_WANTED.store(false, Ordering::SeqCst);
    if let Some(panel) = app.get_webview_window("panel") {
        let _ = panel.hide();
    }
    if let Some(main) = app.get_webview_window("main") {
        let _ = main.emit("birdnion-panel-closed", ());
    }
}

fn toggle_main_window(app: &tauri::AppHandle) {
    use tauri::Manager;
    if let Some(window) = app.get_webview_window("main") {
        if window.is_visible().unwrap_or(false) {
            let _ = window.hide();
            hide_side_panel_with_popover(app);
        } else {
            let _ = window.show();
            let _ = window.set_focus();
        }
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            show_main_window(app);
        }))
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
            kiro_usage_report,
            omp_usage_report,
            pi_usage_report,
            enabled_local_usage_source_ids,
            project_insights_report,
            provider_statuses,
            list_installed_agents,
            panel_debug,
            open_side_panel,
            update_side_panel,
            close_side_panel,
            resize_side_panel,
            classify_provider_error,
            is_transient_provider_error,
            is_fixable_provider_error,
            provider_remediation_target,
            provider_onboarding_detection,
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
            cli_proxy::cli_proxy_status,
            cli_proxy::cli_proxy_prepare,
            cli_proxy::cli_proxy_codex_status,
            cli_proxy::cli_proxy_codex_prepare,
            cli_proxy::cli_proxy_stop,
            cli_proxy::cli_proxy_restore,
            codex_profile_state,
            codex_active_id,
            codex_apply,
            codex_deactivate,
            codex_delete,
            codex_ensure_counterpart,
            codex_ensure_preset,
            codex_accounts_list,
            codex_account_save_current,
            codex_account_switch,
            codex_account_remove,
            antigravity_accounts_list,
            antigravity_account_add,
            antigravity_account_switch,
            antigravity_account_remove,
            freemodel_accounts_list,
            freemodel_account_add,
            freemodel_account_switch,
            freemodel_account_remove,
            elevenlabs_keys_list,
            elevenlabs_key_add,
            elevenlabs_key_switch,
            elevenlabs_key_remove,
            hiyo_keys_list,
            hiyo_key_add,
            hiyo_key_switch,
            hiyo_key_remove,
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
                .icon(
                    tray_default_icon()
                        .unwrap_or_else(|| app.default_window_icon().unwrap().clone()),
                )
                .menu(&menu)
                // macOS: left-click → popover; right-click → menu (matches NSStatusItem).
                // Linux: menu on click is the only reliable path (no tray click events).
                .show_menu_on_left_click(cfg!(target_os = "linux"))
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

            // Restore the loopback CLIProxyAPI helper when a previously
            // activated embedded profile is still registered (non-blocking).
            let handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                cli_proxy::restore_if_configured(&handle).await;
            });

            Ok(())
        })
        .on_window_event(|window, event| {
            use tauri::Manager;
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                // Settings is a real window — destroy on close.
                // Main popover stays tray-resident (hide only).
                if window.label() == "settings" {
                    return;
                }
                let _ = window.hide();
                if window.label() == "main" {
                    // Không bám vào `Focused(false)`: bấm vào chính panel cũng
                    // làm popover mất focus, panel sẽ tự đóng oan.
                    hide_side_panel_with_popover(window.app_handle());
                }
                api.prevent_close();
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
