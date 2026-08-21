//! Local Grok session cost scanner — port of macOS `GrokCostScanner`.
//! Walks `~/.grok/sessions/**/signals.json`.
//!
//! Each scan attributes a session's full lifetime total
//! (`totalTokensBeforeCompaction + contextTokensUsed`) to its last-active day,
//! matching CodexBar `GrokLocalSessionScanner` and macOS (rev 2+). macOS then
//! merges into `CostHistoryStore` with prefer-higher so deleted sessions keep
//! past bars; Linux has no day-history store so a rescan only reflects sessions
//! still on disk.

use chrono::{DateTime, Duration, Local};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::path::{Component, Path, PathBuf};
use walkdir::WalkDir;

use crate::project_cost_history::{ProjectContribution, ProjectModel};
use crate::usage::{DailyModel, DailyUsage, UsageReport};

/// Trailing daily window for charts / heatmap (macOS CombinedUsageReport 120d).
pub const HISTORY_DAYS: i64 = 120;

#[derive(Clone, Debug, PartialEq)]
struct ProjectIdentity {
    key: String,
    display_name: String,
    label_is_verified: bool,
}

pub struct GrokUsageScan {
    pub usage: UsageReport,
    pub projects: Vec<ProjectContribution>,
}

fn normalized_absolute_path(raw: &str) -> Option<PathBuf> {
    if raw.chars().any(char::is_control) {
        return None;
    }
    let path = Path::new(raw);
    if !path.is_absolute() {
        return None;
    }
    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            Component::Prefix(prefix) => normalized.push(prefix.as_os_str()),
            Component::RootDir => normalized.push(component.as_os_str()),
            Component::CurDir => {}
            Component::ParentDir => {
                if !normalized.pop() {
                    return None;
                }
            }
            Component::Normal(part) => normalized.push(part),
        }
    }
    Some(normalized)
}

fn safe_absolute_basename(raw: &str) -> Option<String> {
    let normalized = normalized_absolute_path(raw)?;
    let raw_name = normalized.file_name()?.to_str()?;
    let name = raw_name
        .chars()
        .filter(|char| !char.is_control() && *char != '/' && *char != '\\')
        .take(80)
        .collect::<String>()
        .trim()
        .to_string();
    (!name.is_empty() && name != "." && name != "..").then_some(name)
}

fn grok_project_identity(root: &Path, signals_path: &Path) -> Option<ProjectIdentity> {
    if signals_path.file_name()?.to_str()? != "signals.json" {
        return None;
    }
    let session_dir = signals_path.parent()?;
    let encoded_dir = session_dir.parent()?;
    if encoded_dir.parent()? != root {
        return None;
    }
    let encoded = encoded_dir.file_name()?;
    let encoded = encoded.to_str()?;
    if encoded.is_empty()
        || encoded.contains('/')
        || encoded.contains('\\')
        || encoded.chars().any(char::is_control)
    {
        return None;
    }
    let mut hasher = Sha256::new();
    hasher.update(b"grok:encoded-cwd-v1\0");
    hasher.update(encoded.as_bytes());
    let key = hex::encode(hasher.finalize());
    Some(ProjectIdentity {
        display_name: format!("Grok Project {}", &key[..8]),
        key,
        label_is_verified: false,
    })
}

fn grok_home() -> PathBuf {
    if let Ok(h) = std::env::var("GROK_HOME") {
        let h = h.trim();
        if !h.is_empty() {
            return PathBuf::from(h);
        }
    }
    std::env::var("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("/tmp"))
        .join(".grok")
}

fn blended_usd(tokens: i64, model: &str) -> f64 {
    let m = model.to_lowercase();
    let (input, output) = if m.contains("grok-4.5") || m.contains("grok-4-5") {
        (2.0, 6.0)
    } else if m.contains("fast") {
        if m.contains("code") {
            (0.20, 1.50)
        } else {
            (0.20, 0.50)
        }
    } else if m.contains("4.3") || m.contains("4.20") || m.contains("4-3") || m.contains("4-20") {
        (1.25, 2.50)
    } else if m.contains("grok-4") {
        (3.0, 15.0)
    } else if m.contains("build") || m.contains("code") {
        (1.0, 2.0)
    } else {
        (2.0, 6.0)
    };
    let blended = 0.75 * input + 0.25 * output;
    (tokens as f64) / 1_000_000.0 * blended
}

pub fn usage_scan() -> Option<GrokUsageScan> {
    scan_with_projects(Local::now())
}

pub fn scan_with_projects(now: DateTime<Local>) -> Option<GrokUsageScan> {
    let root = grok_home().join("sessions");
    // Missing/not-a-dir root means Grok was never scanned on this machine —
    // return None (not a fabricated all-zero report) so the Data Confidence
    // Pass can tell "never scanned" apart from "scanned, found nothing". An
    // existing-but-empty root still returns Some (all-zero daily buckets)
    // via the normal walk below, which naturally finds zero sessions.
    if !root.is_dir() {
        return None;
    }
    let today = now.date_naive();
    let cutoff = today - Duration::days(HISTORY_DAYS - 1);

    let mut buckets: HashMap<String, (f64, i64, HashMap<String, (f64, i64)>)> = HashMap::new();
    let mut project_buckets: HashMap<
        (String, String),
        (String, f64, i64, HashMap<String, (f64, i64)>),
    > = HashMap::new();

    for entry in WalkDir::new(&root).into_iter().filter_map(Result::ok) {
        if entry.file_name() != "signals.json" {
            continue;
        }
        let path = entry.path();
        let session_dir = path.parent().unwrap_or(path);
        let summary_path = session_dir.join("summary.json");
        let mut project = grok_project_identity(&root, path);

        let mut model = "grok-4.5".to_string();
        let mut active = entry
            .metadata()
            .ok()
            .and_then(|m| m.modified().ok())
            .map(DateTime::<Local>::from)
            .unwrap_or(now);

        if let Ok(text) = std::fs::read_to_string(&summary_path) {
            if let Ok(v) = serde_json::from_str::<Value>(&text) {
                if let Some(m) = v.get("current_model_id").and_then(Value::as_str) {
                    if !m.is_empty() {
                        model = m.to_string();
                    }
                }
                if let Some(raw) = v
                    .get("last_active_at")
                    .or_else(|| v.get("updated_at"))
                    .and_then(Value::as_str)
                {
                    if let Ok(dt) = DateTime::parse_from_rfc3339(raw) {
                        active = dt.with_timezone(&Local);
                    }
                }
                if let Some(display_name) = v
                    .get("git_root_dir")
                    .and_then(Value::as_str)
                    .and_then(safe_absolute_basename)
                {
                    if let Some(identity) = &mut project {
                        identity.display_name = display_name;
                        identity.label_is_verified = true;
                    }
                }
            }
        }

        let day = active.date_naive();
        if day < cutoff || active > now {
            continue;
        }

        let Ok(text) = std::fs::read_to_string(path) else {
            continue;
        };
        let Ok(v) = serde_json::from_str::<Value>(&text) else {
            continue;
        };

        if let Some(m) = v.get("primaryModelId").and_then(Value::as_str) {
            if !m.is_empty() {
                model = m.to_string();
            }
        }

        let before = v
            .get("totalTokensBeforeCompaction")
            .and_then(Value::as_i64)
            .unwrap_or(0);
        let context = v
            .get("contextTokensUsed")
            .and_then(Value::as_i64)
            .unwrap_or(0);
        let tokens = (before + context).max(0);
        if tokens <= 0 {
            continue;
        }
        let usd = blended_usd(tokens, &model);
        let key = day.format("%Y-%m-%d").to_string();
        let b = buckets.entry(key.clone()).or_default();
        b.0 += usd;
        b.1 += tokens;
        let m = b.2.entry(model.clone()).or_default();
        m.0 += usd;
        m.1 += tokens;
        if let Some(project) = project {
            let display_name = project.display_name;
            let project_day = project_buckets
                .entry((project.key, key))
                .or_insert_with(|| (display_name.clone(), 0.0, 0, HashMap::new()));
            if project.label_is_verified && project_day.0.starts_with("Grok Project ") {
                project_day.0 = display_name;
            }
            project_day.1 += usd;
            project_day.2 += tokens;
            let project_model = project_day.3.entry(model).or_default();
            project_model.0 += usd;
            project_model.1 += tokens;
        }
    }

    let mut daily = Vec::new();
    for offset in (0..HISTORY_DAYS).rev() {
        let day = today - Duration::days(offset);
        let key = day.format("%Y-%m-%d").to_string();
        let (usd, tokens, models_map) = buckets.remove(&key).unwrap_or_default();
        let mut models: Vec<DailyModel> = models_map
            .into_iter()
            .map(|(name, (u, t))| DailyModel {
                name,
                usd: u,
                tokens: t,
            })
            .collect();
        models.sort_by(|a, b| {
            b.usd
                .partial_cmp(&a.usd)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then(b.tokens.cmp(&a.tokens))
        });
        models.truncate(5);
        daily.push(DailyUsage {
            date: key,
            usd,
            tokens,
            models,
        });
    }

    let last30_usd: f64 = daily.iter().rev().take(30).map(|d| d.usd).sum();
    let last30_tokens: i64 = daily.iter().rev().take(30).map(|d| d.tokens).sum();
    let today_usd = daily.last().map(|d| d.usd).unwrap_or(0.0);
    let today_tokens = daily.last().map(|d| d.tokens).unwrap_or(0);
    let top_model = daily
        .iter()
        .rev()
        .take(30)
        .flat_map(|d| d.models.iter())
        .max_by_key(|m| m.tokens)
        .map(|m| m.name.clone());
    let usage = UsageReport {
        today_usd,
        today_tokens,
        last30_usd,
        last30_tokens,
        daily,
        hourly: vec![],
        top_model,
        // Confidence metadata (included/live/scanned_at) is decided by
        // `cost_history::apply_and_report`, which owns the merge; this
        // intermediate "live" report is only ever consumed there.
        ..Default::default()
    };
    let mut projects: Vec<ProjectContribution> = project_buckets
        .into_iter()
        .filter(|(_, (_, usd, tokens, _))| *usd > 0.0 || *tokens > 0)
        .map(|((project_key, date), (display_name, usd, tokens, models))| {
            let mut models: Vec<ProjectModel> = models
                .into_iter()
                .filter(|(_, (model_usd, model_tokens))| *model_usd > 0.0 || *model_tokens > 0)
                .map(|(name, (usd, tokens))| ProjectModel { name, usd, tokens })
                .collect();
            models.sort_by(|a, b| {
                b.usd
                    .total_cmp(&a.usd)
                    .then_with(|| b.tokens.cmp(&a.tokens))
                    .then_with(|| a.name.cmp(&b.name))
            });
            models.truncate(5);
            ProjectContribution {
                project_key,
                display_name,
                capability: "derivedPath".into(),
                date,
                usd,
                tokens,
                models,
            }
        })
        .collect();
    projects.sort_by(|a, b| {
        a.date
            .cmp(&b.date)
            .then_with(|| a.project_key.cmp(&b.project_key))
    });
    Some(GrokUsageScan { usage, projects })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::TEST_ENV_LOCK as ENV_LOCK;

    fn scan(now: DateTime<Local>) -> Option<UsageReport> {
        scan_with_projects(now).map(|scan| scan.usage)
    }

    fn temp_grok_home(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "birdnion-grok-scanner-{tag}-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }

    fn write_session(
        home: &Path,
        encoded_cwd: &str,
        session_id: &str,
        now: DateTime<Local>,
        git_root_dir: Option<&str>,
    ) {
        let dir = home.join("sessions").join(encoded_cwd).join(session_id);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("signals.json"),
            r#"{"totalTokensBeforeCompaction":75000,"contextTokensUsed":25000,"primaryModelId":"grok-code-fast"}"#,
        )
        .unwrap();
        let mut summary = serde_json::json!({
            "last_active_at": now.to_rfc3339(),
            "current_model_id": "grok-code-fast"
        });
        if let Some(root) = git_root_dir {
            summary["git_root_dir"] = Value::String(root.into());
        }
        std::fs::write(dir.join("summary.json"), serde_json::to_string(&summary).unwrap()).unwrap();
    }

    #[test]
    fn scan_returns_none_when_sessions_root_missing() {
        let _guard = ENV_LOCK.lock().unwrap();
        let home = temp_grok_home("missing");
        // Deliberately do NOT create `home` (or its `sessions` subdir) — the
        // scanner must report "no data" (None), not a fabricated all-zero
        // report, so the Data Confidence Pass can tell "never scanned"
        // apart from "scanned and found nothing".
        std::env::set_var("GROK_HOME", &home);

        let result = scan(Local::now());

        std::env::remove_var("GROK_HOME");
        let _ = std::fs::remove_dir_all(&home);
        assert!(result.is_none());
    }

    #[test]
    fn scan_returns_empty_report_when_sessions_root_exists_but_empty() {
        let _guard = ENV_LOCK.lock().unwrap();
        let home = temp_grok_home("empty");
        std::fs::create_dir_all(home.join("sessions")).unwrap();
        std::env::set_var("GROK_HOME", &home);

        let result = scan(Local::now());

        std::env::remove_var("GROK_HOME");
        let _ = std::fs::remove_dir_all(&home);
        let report = result.expect("an existing, empty sessions dir still scans (Some)");
        assert_eq!(report.today_tokens, 0);
        assert_eq!(report.last30_tokens, 0);
        assert_eq!(report.daily.len(), HISTORY_DAYS as usize);
        assert!(report.daily.iter().all(|d| d.tokens == 0 && d.usd == 0.0));
    }

    #[test]
    fn grok_project_key_uses_encoded_parent_without_persisting_it() {
        let root = PathBuf::from("/tmp/grok/sessions");
        let path = root.join("-Users-alice-repo/session-id/signals.json");

        let project = grok_project_identity(&root, &path).unwrap();

        assert_eq!(
            project.key,
            "01950f551872a74198cd3294f17f96b02b95f3a791576631f406a58d294f5614"
        );
        assert_eq!(project.display_name, "Grok Project 01950f55");
        assert!(!project.key.contains("-Users-alice-repo"));
        assert!(!project.display_name.contains("-Users-alice-repo"));
    }

    #[test]
    fn malformed_shape_and_unsafe_encoded_tokens_stay_unattributed() {
        let _guard = ENV_LOCK.lock().unwrap();
        let home = temp_grok_home("unsafe-shape");
        let now = Local::now();
        write_session(&home, "encoded/extra", "session-a", now, None);
        write_session(&home, r"encoded\private", "session-b", now, None);
        write_session(&home, "encoded\nprivate", "session-c", now, None);
        std::env::set_var("GROK_HOME", &home);

        let scan = scan_with_projects(Local::now()).unwrap();

        std::env::remove_var("GROK_HOME");
        let _ = std::fs::remove_dir_all(&home);
        assert_eq!(scan.usage.today_tokens, 300_000);
        assert!(scan.projects.is_empty());
        let root = PathBuf::from("/tmp/grok/sessions");
        assert!(grok_project_identity(
            &root,
            &root.join("encoded/session/other.json")
        )
        .is_none());
    }

    #[test]
    fn named_projects_aggregate_with_usage_and_keep_only_safe_label() {
        let _guard = ENV_LOCK.lock().unwrap();
        let home = temp_grok_home("projects");
        let now = Local::now();
        write_session(
            &home,
            "-Users-alice-repo",
            "session-a",
            now,
            None,
        );
        write_session(
            &home,
            "-Users-alice-repo",
            "session-b",
            now,
            Some("/Users/alice/private/repo"),
        );
        std::env::set_var("GROK_HOME", &home);

        let scan = scan_with_projects(Local::now()).unwrap();

        std::env::remove_var("GROK_HOME");
        let _ = std::fs::remove_dir_all(&home);
        assert_eq!(scan.usage.today_tokens, 200_000);
        assert_eq!(scan.projects.len(), 1);
        assert_eq!(scan.projects[0].tokens, scan.usage.today_tokens);
        assert_eq!(scan.projects[0].display_name, "repo");
        assert_eq!(scan.projects[0].capability, "derivedPath");
        let debug = format!("{:?}", scan.projects);
        assert!(!debug.contains("/Users/alice/private"));
        assert!(!debug.contains("-Users-alice-repo"));
    }

    #[test]
    fn missing_relative_or_malformed_git_root_uses_generic_private_label() {
        let _guard = ENV_LOCK.lock().unwrap();
        let home = temp_grok_home("generic-label");
        let now = Local::now();
        write_session(
            &home,
            "-Users-alice-secret",
            "session-a",
            now,
            Some("relative/private/repo"),
        );
        write_session(
            &home,
            "-Users-alice-missing",
            "session-b",
            now,
            None,
        );
        write_session(
            &home,
            "-Users-alice-malformed",
            "session-c",
            now,
            Some("/Users/alice/private/repo"),
        );
        std::fs::write(
            home.join("sessions/-Users-alice-malformed/session-c/summary.json"),
            "{not-json",
        )
        .unwrap();
        std::env::set_var("GROK_HOME", &home);

        let scan = scan_with_projects(Local::now()).unwrap();

        std::env::remove_var("GROK_HOME");
        let _ = std::fs::remove_dir_all(&home);
        assert_eq!(scan.projects.len(), 3);
        assert!(scan
            .projects
            .iter()
            .all(|project| project.display_name.starts_with("Grok Project ")));
        assert!(scan
            .projects
            .iter()
            .all(|project| !project.display_name.contains("alice")));
    }
}
