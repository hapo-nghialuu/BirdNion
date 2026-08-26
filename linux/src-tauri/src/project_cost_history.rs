//! Optional per-project cost history, isolated from `cost-history.json`.
//! A missing or corrupt document is an empty Insights store and never affects
//! the existing usage/quota path.

use chrono::{Local, NaiveDate};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;

use crate::config;

pub const RETAIN_DAYS: i64 = 400;
const MAX_DAY_USD: f64 = 1_000_000_000.0;
const MAX_DAY_TOKENS: i64 = 1_000_000_000_000;
const MODEL_LIMIT: usize = 5;

#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ProjectModel {
    pub name: String,
    pub usd: f64,
    pub tokens: i64,
}

#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ProjectDay {
    pub usd: f64,
    pub tokens: i64,
    #[serde(default)]
    pub models: Vec<ProjectModel>,
}

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub struct ProjectRecord {
    pub display_name: String,
    #[serde(default = "default_capability")]
    pub capability: String,
    #[serde(default)]
    pub days: HashMap<String, ProjectDay>,
}

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct Document {
    #[serde(default)]
    pub version: u32,
    /// source -> project key -> record. Keys are SHA-256 hex digests.
    #[serde(default)]
    pub sources: HashMap<String, HashMap<String, ProjectRecord>>,
    /// Privacy-hashed, idempotent tombstones already applied to this store.
    #[serde(default)]
    pub applied_retraction_ids: HashMap<String, Vec<String>>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ProjectContribution {
    pub project_key: String,
    pub display_name: String,
    pub capability: String,
    pub date: String,
    pub usd: f64,
    pub tokens: i64,
    pub models: Vec<ProjectModel>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ProjectRetraction {
    pub retraction_id: String,
    pub project_key: String,
    pub contributions: Vec<ProjectContribution>,
}

fn default_capability() -> String {
    "derivedPath".into()
}

fn valid_project_key(key: &str) -> bool {
    key.len() == 64 && key.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn safe_display_name(raw: &str) -> String {
    let tail = raw.rsplit(['/', '\\']).next().unwrap_or("");
    let safe: String = tail
        .chars()
        .filter(|char| !char.is_control())
        .take(80)
        .collect::<String>()
        .trim()
        .to_string();
    if safe.is_empty() || safe == "." || safe == ".." {
        "Unknown".into()
    } else {
        safe
    }
}

fn safe_model_name(raw: &str) -> String {
    safe_display_name(raw)
}

fn safe_capability(raw: &str) -> String {
    if raw == "exact" {
        "exact".into()
    } else {
        "derivedPath".into()
    }
}

fn safe_usd(value: f64) -> f64 {
    if value.is_finite() && (0.0..=MAX_DAY_USD).contains(&value) {
        value
    } else {
        0.0
    }
}

fn safe_tokens(value: i64) -> i64 {
    if (0..=MAX_DAY_TOKENS).contains(&value) {
        value
    } else {
        0
    }
}

fn safe_models(models: &[ProjectModel]) -> Vec<ProjectModel> {
    let mut merged: HashMap<String, ProjectModel> = HashMap::new();
    for model in models {
        let name = safe_model_name(&model.name);
        let entry = merged.entry(name.clone()).or_insert(ProjectModel {
            name,
            usd: 0.0,
            tokens: 0,
        });
        entry.usd = (entry.usd + safe_usd(model.usd)).min(MAX_DAY_USD);
        entry.tokens = entry
            .tokens
            .saturating_add(safe_tokens(model.tokens))
            .min(MAX_DAY_TOKENS);
    }
    let mut rows: Vec<_> = merged
        .into_values()
        .filter(|model| model.usd > 0.0 || model.tokens > 0)
        .collect();
    rows.sort_by(|left, right| {
        right
            .usd
            .total_cmp(&left.usd)
            .then_with(|| right.tokens.cmp(&left.tokens))
            .then_with(|| left.name.cmp(&right.name))
    });
    rows.truncate(MODEL_LIMIT);
    rows
}

fn sanitize(doc: &mut Document) {
    doc.applied_retraction_ids
        .retain(|source, _| matches!(source.as_str(), "claude" | "codex" | "grok"));
    for ids in doc.applied_retraction_ids.values_mut() {
        ids.retain(|id| valid_project_key(id));
        ids.sort();
        ids.dedup();
    }
    doc.sources
        .retain(|source, _| matches!(source.as_str(), "claude" | "codex" | "grok"));
    for projects in doc.sources.values_mut() {
        projects.retain(|key, record| {
            if !valid_project_key(key) {
                return false;
            }
            record.display_name = safe_display_name(&record.display_name);
            record.capability = safe_capability(&record.capability);
            record.days.retain(|date, _| {
                NaiveDate::parse_from_str(date, "%Y-%m-%d")
                    .is_ok_and(|parsed| parsed.to_string() == *date)
            });
            for day in record.days.values_mut() {
                day.usd = safe_usd(day.usd);
                day.tokens = safe_tokens(day.tokens);
                day.models = safe_models(&day.models);
            }
            true
        });
    }
    doc.sources.retain(|_, projects| !projects.is_empty());
}

pub fn history_path() -> Option<PathBuf> {
    config::support_dir().map(|path| path.join("project-cost-history.json"))
}

pub fn read() -> Document {
    let mut document = history_path()
        .and_then(|path| std::fs::read_to_string(path).ok())
        .and_then(|raw| serde_json::from_str(&raw).ok())
        .unwrap_or_default();
    sanitize(&mut document);
    document
}

fn write(doc: &Document) -> Result<(), String> {
    let path = history_path().ok_or_else(|| "Không xác định được thư mục cấu hình".to_string())?;
    let mut output = doc.clone();
    output.version = 2;
    let json = serde_json::to_string_pretty(&output).map_err(|e| e.to_string())?;
    crate::platform::atomic_file::write_private_json_atomic::<Document>(&path, json.as_bytes())
        .map_err(|e| e.to_string())
}

fn prefer_higher(existing: &ProjectDay, incoming: &ProjectDay) -> ProjectDay {
    if incoming.tokens != existing.tokens {
        return if incoming.tokens > existing.tokens {
            incoming.clone()
        } else {
            existing.clone()
        };
    }
    if incoming.usd != existing.usd {
        return if incoming.usd > existing.usd {
            incoming.clone()
        } else {
            existing.clone()
        };
    }
    if incoming.models.len() >= existing.models.len() {
        incoming.clone()
    } else {
        existing.clone()
    }
}

static PROJECT_HISTORY_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

fn subtract_retraction(
    projects: &mut HashMap<String, ProjectRecord>,
    retraction: &ProjectRetraction,
) {
    if !valid_project_key(&retraction.project_key) {
        return;
    }
    let Some(record) = projects.get_mut(&retraction.project_key) else {
        return;
    };
    for contribution in &retraction.contributions {
        if contribution.project_key != retraction.project_key {
            continue;
        }
        let Some(day) = record.days.get_mut(&contribution.date) else {
            continue;
        };
        day.usd = (day.usd - contribution.usd.max(0.0)).max(0.0);
        day.tokens = (day.tokens - contribution.tokens.max(0)).max(0);
        for incoming in &contribution.models {
            let name = safe_model_name(&incoming.name);
            let Some(model) = day.models.iter_mut().find(|model| model.name == name) else {
                continue;
            };
            model.usd = (model.usd - incoming.usd.max(0.0)).max(0.0);
            model.tokens = (model.tokens - incoming.tokens.max(0)).max(0);
        }
        day.models
            .retain(|model| model.usd > 0.0 || model.tokens > 0);
    }
    record
        .days
        .retain(|_, day| day.usd > 0.0 || day.tokens > 0 || !day.models.is_empty());
    projects.retain(|_, record| !record.days.is_empty());
}

/// High-water merge for one source. `replace_source` is reserved for an
/// explicit future counting/pricing revision; normal scans always pass false.
pub fn apply(
    source: &str,
    live: &[ProjectContribution],
    replace_source: bool,
) -> Result<(), String> {
    apply_with_retractions(source, live, &[], replace_source)
}

/// Applies explicit, privacy-safe retractions once before merging the current
/// scan. An empty scan without a retraction keeps the prior high-water value.
pub fn apply_with_retractions(
    source: &str,
    live: &[ProjectContribution],
    retractions: &[ProjectRetraction],
    replace_source: bool,
) -> Result<(), String> {
    if !matches!(source, "claude" | "codex" | "grok") {
        return Err("unsupported project history source".into());
    }
    let _guard = PROJECT_HISTORY_LOCK
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let today = Local::now().date_naive();
    let prune_before = today - chrono::Duration::days(RETAIN_DAYS - 1);
    let mut doc = read();
    sanitize(&mut doc);
    if replace_source {
        doc.sources.remove(source);
    }

    let applied_ids = doc
        .applied_retraction_ids
        .entry(source.to_string())
        .or_default();
    let projects = doc.sources.entry(source.to_string()).or_default();
    for retraction in retractions {
        if !valid_project_key(&retraction.retraction_id)
            || applied_ids.contains(&retraction.retraction_id)
        {
            continue;
        }
        subtract_retraction(projects, retraction);
        applied_ids.push(retraction.retraction_id.clone());
    }
    for contribution in live {
        if !valid_project_key(&contribution.project_key) {
            continue;
        }
        let display_name = safe_display_name(&contribution.display_name);
        let capability = safe_capability(&contribution.capability);
        let record = projects
            .entry(contribution.project_key.clone())
            .or_insert_with(|| ProjectRecord {
                display_name: display_name.clone(),
                capability: capability.clone(),
                days: HashMap::new(),
            });
        record.display_name = display_name;
        record.capability = capability;
        let incoming = ProjectDay {
            usd: contribution.usd,
            tokens: contribution.tokens,
            models: contribution
                .models
                .iter()
                .map(|model| ProjectModel {
                    name: safe_model_name(&model.name),
                    usd: model.usd,
                    tokens: model.tokens,
                })
                .collect(),
        };
        record
            .days
            .entry(contribution.date.clone())
            .and_modify(|existing| *existing = prefer_higher(existing, &incoming))
            .or_insert(incoming);
    }

    for source_projects in doc.sources.values_mut() {
        source_projects.retain(|_, record| {
            record.days.retain(|date, _| {
                NaiveDate::parse_from_str(date, "%Y-%m-%d")
                    .map(|day| day >= prune_before)
                    .unwrap_or(false)
            });
            !record.days.is_empty()
        });
    }
    doc.sources.retain(|_, projects| !projects.is_empty());
    sanitize(&mut doc);
    write(&doc)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::TEST_ENV_LOCK;
    use std::fs;

    fn temp_config(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "birdnion-project-history-{tag}-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn contribution(date: String, tokens: i64, usd: f64) -> ProjectContribution {
        ProjectContribution {
            project_key: "a".repeat(64),
            display_name: "birdnion".into(),
            capability: "exact".into(),
            date,
            usd,
            tokens,
            models: vec![ProjectModel {
                name: "claude-sonnet".into(),
                usd,
                tokens,
            }],
        }
    }

    #[test]
    fn merge_is_high_water_and_writes_private_file() {
        let _guard = TEST_ENV_LOCK.lock().unwrap();
        let base = temp_config("merge");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));
        let today = Local::now().date_naive().to_string();

        apply("claude", &[contribution(today.clone(), 100, 1.0)], false).unwrap();
        apply("claude", &[contribution(today.clone(), 10, 10.0)], false).unwrap();
        let doc = read();
        let day = &doc.sources["claude"][&"a".repeat(64)].days[&today];
        assert_eq!(day.tokens, 100);
        assert_eq!(day.usd, 1.0);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(history_path().unwrap())
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777,
                0o600
            );
        }

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = fs::remove_dir_all(base);
    }

    #[test]
    fn apply_prunes_old_days() {
        let _guard = TEST_ENV_LOCK.lock().unwrap();
        let base = temp_config("prune");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));
        let old = (Local::now().date_naive() - chrono::Duration::days(RETAIN_DAYS)).to_string();
        let today = Local::now().date_naive().to_string();

        apply(
            "claude",
            &[
                contribution(old.clone(), 100, 1.0),
                contribution(today.clone(), 20, 0.2),
            ],
            false,
        )
        .unwrap();
        let days = &read().sources["claude"][&"a".repeat(64)].days;
        assert!(!days.contains_key(&old));
        assert!(days.contains_key(&today));

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = fs::remove_dir_all(base);
    }

    #[test]
    fn corrupt_input_is_preserved_and_rejected() {
        let _guard = TEST_ENV_LOCK.lock().unwrap();
        let base = temp_config("corrupt");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));
        fs::write(history_path().unwrap(), "{not-json").unwrap();
        let today = Local::now().date_naive().to_string();

        assert!(apply("claude", &[contribution(today, 20, 0.2)], false).is_err());
        assert_eq!(
            fs::read_to_string(history_path().unwrap()).unwrap(),
            "{not-json"
        );

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = fs::remove_dir_all(base);
    }

    #[test]
    fn empty_later_scan_does_not_shrink_observed_history() {
        let _guard = TEST_ENV_LOCK.lock().unwrap();
        let base = temp_config("identity-upgrade");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));
        let today = Local::now().date_naive().to_string();
        let observed = contribution(today.clone(), 100, 1.0);

        apply("claude", &[observed.clone()], false).unwrap();
        apply("claude", &[], false).unwrap();
        let projects = &read().sources["claude"];

        assert_eq!(projects[&observed.project_key].days[&today].tokens, 100);
        std::env::remove_var("BIRDNION_CONFIG");
        let _ = fs::remove_dir_all(base);
    }

    #[test]
    fn explicit_retraction_is_idempotent_and_preserves_other_session_usage() {
        let _guard = TEST_ENV_LOCK.lock().unwrap();
        let base = temp_config("retraction");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));
        let today = Local::now().date_naive().to_string();
        let mut combined = contribution(today.clone(), 140, 1.4);
        combined.models[0].tokens = 140;
        combined.models[0].usd = 1.4;
        let mut remaining = contribution(today.clone(), 40, 0.4);
        remaining.models[0].tokens = 40;
        remaining.models[0].usd = 0.4;
        let removed = contribution(today.clone(), 100, 1.0);
        let retraction = ProjectRetraction {
            retraction_id: "c".repeat(64),
            project_key: combined.project_key.clone(),
            contributions: vec![removed],
        };

        apply_with_retractions("codex", &[combined], &[], false).unwrap();
        apply_with_retractions("codex", &[remaining.clone()], &[retraction.clone()], false)
            .unwrap();
        apply_with_retractions("codex", &[remaining], &[retraction], false).unwrap();

        let doc = read();
        let day = &doc.sources["codex"][&"a".repeat(64)].days[&today];
        assert_eq!(day.tokens, 40);
        assert!((day.usd - 0.4).abs() < 1e-12);
        assert_eq!(day.models[0].tokens, 40);
        assert!((day.models[0].usd - 0.4).abs() < 1e-12);
        assert_eq!(doc.applied_retraction_ids["codex"], vec!["c".repeat(64)]);

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = fs::remove_dir_all(base);
    }

    #[test]
    fn retraction_removes_zero_project_but_empty_scan_does_not() {
        let _guard = TEST_ENV_LOCK.lock().unwrap();
        let base = temp_config("retraction-remove");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));
        let today = Local::now().date_naive().to_string();
        let observed = contribution(today, 100, 1.0);
        let retraction = ProjectRetraction {
            retraction_id: "d".repeat(64),
            project_key: observed.project_key.clone(),
            contributions: vec![observed.clone()],
        };

        apply("codex", &[observed], false).unwrap();
        apply("codex", &[], false).unwrap();
        assert!(read().sources.contains_key("codex"));
        apply_with_retractions("codex", &[], &[retraction], false).unwrap();
        let doc = read();
        assert!(!doc.sources.contains_key("codex"));
        assert_eq!(doc.applied_retraction_ids["codex"], vec!["d".repeat(64)]);

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = fs::remove_dir_all(base);
    }

    #[test]
    fn valid_privacy_unsafe_input_is_sanitized_before_rewrite() {
        let _guard = TEST_ENV_LOCK.lock().unwrap();
        let base = temp_config("privacy");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));
        let today = Local::now().date_naive().to_string();
        let valid_key = "b".repeat(64);
        let long_parent = "private-parent".repeat(20);
        let mut raw = serde_json::json!({
            "version": 1,
            "sources": {
                "/Users/private/secret-source": {
                    "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd": {
                        "displayName": "secret", "days": {}
                    }
                },
                "claude": {
                    "/Users/private/repo": { "displayName": "/Users/private/repo", "days": {} }
                }
            }
        });
        raw["sources"]["claude"][valid_key.as_str()] = serde_json::json!({
            "displayName": format!("/Users/private/{long_parent}/repo"),
            "capability": "unsafe",
            "days": { today.clone(): { "usd": 1.0, "tokens": 10, "models": [
                { "name": "/Users/private/secret/client-model", "usd": 1.0, "tokens": 10 }
            ] } }
        });
        let unsafe_day = format!("{today} /Users/private/secret");
        raw["sources"]["claude"][valid_key.as_str()]["days"][unsafe_day.as_str()] =
            serde_json::json!({ "usd": 99.0, "tokens": 99, "models": [] });
        fs::write(
            history_path().unwrap(),
            serde_json::to_string(&raw).unwrap(),
        )
        .unwrap();

        apply("claude", &[], false).unwrap();
        let doc = read();
        assert_eq!(doc.sources["claude"].len(), 1);
        assert_eq!(doc.sources["claude"][&valid_key].display_name, "repo");
        assert_eq!(doc.sources["claude"][&valid_key].capability, "derivedPath");
        assert_eq!(
            doc.sources["claude"][&valid_key].days[&today].models[0].name,
            "client-model"
        );
        assert_eq!(doc.sources["claude"][&valid_key].days.len(), 1);
        assert!(!fs::read_to_string(history_path().unwrap())
            .unwrap()
            .contains("/Users/private"));

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = fs::remove_dir_all(base);
    }

    #[test]
    fn codex_and_grok_contributions_persist_only_sanitized_fields() {
        let _guard = TEST_ENV_LOCK.lock().unwrap();
        let base = temp_config("codex-grok-privacy");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));
        let today = Local::now().date_naive().to_string();
        let mut grok = contribution(today.clone(), 100, 1.0);
        grok.project_key = "b".repeat(64);
        grok.display_name = "/Users/alice/private/repo".into();
        grok.capability = "derivedPath".into();
        grok.models[0].name = "/Users/alice/private/grok-code-fast".into();
        let mut invalid_day = grok.clone();
        invalid_day.date = format!("{today}-/Users/alice/private");

        apply("codex", &[contribution(today.clone(), 50, 0.5)], false).unwrap();
        apply("grok", &[grok, invalid_day], false).unwrap();

        let doc = read();
        let stored = &doc.sources["grok"][&"b".repeat(64)];
        assert_eq!(stored.display_name, "repo");
        assert_eq!(stored.capability, "derivedPath");
        assert_eq!(stored.days[&today].models[0].name, "grok-code-fast");
        assert_eq!(stored.days.len(), 1);
        assert!(doc.sources.contains_key("codex"));
        assert!(!fs::read_to_string(history_path().unwrap())
            .unwrap()
            .contains("/Users/alice"));
        assert!(apply("unsupported", &[], false).is_err());

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = fs::remove_dir_all(base);
    }

    #[test]
    fn semantic_corruption_is_nonnegative_bounded_and_top_five() {
        let _guard = TEST_ENV_LOCK.lock().unwrap();
        let base = temp_config("semantic-corruption");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));
        let today = Local::now().date_naive().to_string();
        let key = "e".repeat(64);
        let models: Vec<_> = (0..7)
            .map(|index| {
                serde_json::json!({
                    "name": format!("model-{index}"),
                    "usd": index as f64,
                    "tokens": index,
                })
            })
            .chain(std::iter::once(serde_json::json!({
                "name": "negative", "usd": -1.0, "tokens": -100,
            })))
            .collect();
        let raw = serde_json::json!({
            "version": 2,
            "sources": {"codex": {key.clone(): {
                "displayName": "birdnion",
                "capability": "exact",
                "days": {today.clone(): {"usd": 1.0, "tokens": -100, "models": models}}
            }}}
        });
        fs::write(history_path().unwrap(), serde_json::to_vec(&raw).unwrap()).unwrap();

        apply("codex", &[], false).unwrap();
        let doc = read();
        let day = &doc.sources["codex"][&key].days[&today];
        assert_eq!(day.tokens, 0);
        assert_eq!(day.models.len(), MODEL_LIMIT);
        assert!(day
            .models
            .iter()
            .all(|model| model.usd >= 0.0 && model.tokens >= 0));

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = fs::remove_dir_all(base);
    }
}
