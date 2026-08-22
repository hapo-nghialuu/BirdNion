//! Privacy-safe projections over aggregate and per-project local history.

use chrono::{Duration, Local, NaiveDate};
use serde::Serialize;
use std::collections::{HashMap, HashSet};

use crate::cost_history;
use crate::project_cost_history::{self, ProjectDay, ProjectModel};
use crate::usage::UsageReport;
const SOURCES: [&str; 5] = ["claude", "codex", "grok", "omp", "pi"];
const PROJECT_RANKING_LIMIT: usize = 100;

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct SourceTotal {
    pub source: String,
    pub usd: f64,
    pub tokens: i64,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct ModelTotal {
    pub source: String,
    pub name: String,
    pub usd: f64,
    pub tokens: i64,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct SourceConfidence {
    pub source: String,
    pub state: String,
    pub scanned_at: Option<i64>,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct ProjectRanking {
    pub project_key: String,
    pub display_name: String,
    pub source: String,
    pub capability: String,
    pub is_unknown: bool,
    pub usd: f64,
    pub tokens: i64,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct ProjectDetail {
    pub project: ProjectRanking,
    pub daily: Vec<ProjectDetailDay>,
    pub models: Vec<ProjectModel>,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct ProjectDetailDay {
    pub date: String,
    pub usd: f64,
    pub tokens: i64,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Overview {
    pub current7_usd: f64,
    pub current7_tokens: i64,
    pub previous7_usd: f64,
    pub previous7_tokens: i64,
    pub change_pct: Option<f64>,
    pub top_source: Option<SourceTotal>,
    pub top_model: Option<ModelTotal>,
    pub top_project: Option<ProjectRanking>,
    pub confidence: Vec<SourceConfidence>,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Report {
    pub days: u16,
    pub overview: Overview,
    pub projects: Vec<ProjectRanking>,
    pub selected_project: Option<ProjectDetail>,
}

#[derive(Clone)]
struct ProjectSeries {
    project_key: String,
    display_name: String,
    source: String,
    capability: String,
    is_unknown: bool,
    days: HashMap<String, ProjectDay>,
}

fn safe_name(raw: &str) -> String {
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

fn valid_project_key(key: &str) -> bool {
    key.len() == 64 && key.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn valid_day_key(key: &str) -> bool {
    NaiveDate::parse_from_str(key, "%Y-%m-%d")
        .is_ok_and(|date| date.to_string() == key)
}

fn aggregate_days(
    doc: &cost_history::Document,
    current: &HashMap<String, UsageReport>,
) -> HashMap<String, HashMap<String, cost_history::HistoryDay>> {
    let mut result = doc.sources.clone();
    for days in result.values_mut() {
        days.retain(|date, _| valid_day_key(date));
    }
    for source in SOURCES {
        let Some(report) = current.get(source) else {
            continue;
        };
        let days = result.entry(source.to_string()).or_default();
        for day in &report.daily {
            let incoming = cost_history::HistoryDay {
                usd: day.usd,
                tokens: day.tokens,
                models: day
                    .models
                    .iter()
                    .map(|model| cost_history::HistoryModel {
                        name: model.name.clone(),
                        usd: model.usd,
                        tokens: model.tokens,
                    })
                    .collect(),
            };
            days.entry(day.date.clone())
                .and_modify(|existing| *existing = cost_history::prefer_higher(existing, &incoming))
                .or_insert(incoming);
        }
    }
    result
}

fn unknown_series(source: &str, days: HashMap<String, ProjectDay>) -> ProjectSeries {
    ProjectSeries {
        project_key: format!("unknown-{source}"),
        display_name: "Unknown".into(),
        source: source.into(),
        capability: "unknown".into(),
        is_unknown: true,
        days,
    }
}

fn proportional_token_targets(values: &[(String, i64)], target: i64) -> Vec<i64> {
    let normalized: Vec<i64> = values.iter().map(|(_, value)| (*value).max(0)).collect();
    let total: i128 = normalized.iter().map(|value| i128::from(*value)).sum();
    let target = i128::from(target.max(0)).min(total);
    if total == 0 || target == total {
        return normalized;
    }

    let mut result = Vec::with_capacity(normalized.len());
    let mut remainders = Vec::with_capacity(normalized.len());
    for value in &normalized {
        let product = i128::from(*value) * target;
        result.push((product / total) as i64);
        remainders.push(product % total);
    }
    let assigned: i128 = result.iter().map(|value| i128::from(*value)).sum();
    let remaining = usize::try_from(target - assigned).unwrap_or(0);
    let mut order: Vec<usize> = (0..normalized.len()).collect();
    order.sort_by(|left, right| {
        remainders[*right]
            .cmp(&remainders[*left])
            .then_with(|| values[*left].0.cmp(&values[*right].0))
            .then_with(|| left.cmp(right))
    });
    for index in order.into_iter().take(remaining) {
        result[index] += 1;
    }
    result
}

fn scale_model_tokens(models: &mut [ProjectModel], original_day: i64, target_day: i64) {
    if original_day <= 0 || target_day >= original_day {
        return;
    }
    let model_total: i128 = models
        .iter()
        .map(|model| i128::from(model.tokens.max(0)))
        .sum();
    let model_target = ((model_total * i128::from(target_day.max(0))) / i128::from(original_day))
        .min(i128::from(target_day.max(0))) as i64;
    let values: Vec<_> = models
        .iter()
        .map(|model| (model.name.clone(), model.tokens))
        .collect();
    for (model, scaled) in models
        .iter_mut()
        .zip(proportional_token_targets(&values, model_target))
    {
        model.tokens = scaled;
    }
}

fn reconcile_named_days(
    series: &mut [ProjectSeries],
    source: &str,
    aggregate: Option<&HashMap<String, cost_history::HistoryDay>>,
) {
    let mut dates = HashSet::new();
    for project in series.iter().filter(|project| project.source == source) {
        dates.extend(project.days.keys().cloned());
    }

    for date in dates {
        let mut indices: Vec<usize> = series
            .iter()
            .enumerate()
            .filter(|(_, project)| project.source == source && project.days.contains_key(&date))
            .map(|(index, _)| index)
            .collect();
        indices.sort_by(|left, right| {
            series[*left]
                .project_key
                .cmp(&series[*right].project_key)
        });
        let authoritative = aggregate.and_then(|days| days.get(&date));

        let target_usd = authoritative.map(|day| day.usd.max(0.0)).unwrap_or(0.0);
        let named_usd: f64 = indices
            .iter()
            .map(|index| series[*index].days[&date].usd.max(0.0))
            .sum();
        if named_usd > target_usd && named_usd > 0.0 {
            let scale = target_usd / named_usd;
            let mut assigned = 0.0;
            let last = indices.len().saturating_sub(1);
            for (position, index) in indices.iter().enumerate() {
                let original = series[*index].days[&date].usd.max(0.0);
                let scaled = if position == last {
                    (target_usd - assigned).max(0.0)
                } else {
                    (original * scale).min((target_usd - assigned).max(0.0))
                };
                assigned += scaled;
                let effective_scale = if original > 0.0 {
                    scaled / original
                } else {
                    scale
                };
                let day = series[*index].days.get_mut(&date).unwrap();
                day.usd = scaled;
                for model in &mut day.models {
                    model.usd *= effective_scale;
                }
            }
        }

        let token_values: Vec<_> = indices
            .iter()
            .map(|index| {
                (
                    series[*index].project_key.clone(),
                    series[*index].days[&date].tokens,
                )
            })
            .collect();
        let named_tokens: i128 = token_values
            .iter()
            .map(|(_, value)| i128::from((*value).max(0)))
            .sum();
        let target_tokens = authoritative.map(|day| day.tokens.max(0)).unwrap_or(0);
        if named_tokens > i128::from(target_tokens) {
            let targets = proportional_token_targets(&token_values, target_tokens);
            for (index, target) in indices.into_iter().zip(targets) {
                let day = series[index].days.get_mut(&date).unwrap();
                let original = day.tokens.max(0);
                scale_model_tokens(&mut day.models, original, target);
                day.tokens = target;
            }
        }
    }
}

fn build_series(
    project_doc: &project_cost_history::Document,
    aggregate: &HashMap<String, HashMap<String, cost_history::HistoryDay>>,
) -> Vec<ProjectSeries> {
    let mut series = Vec::new();
    for source in SOURCES {
        if let Some(projects) = project_doc.sources.get(source) {
            for (key, record) in projects {
                if !valid_project_key(key) {
                    continue;
                }
                series.push(ProjectSeries {
                    project_key: key.clone(),
                    display_name: safe_name(&record.display_name),
                    source: source.into(),
                    capability: match record.capability.as_str() {
                        "exact" => "exact",
                        _ => "derivedPath",
                    }
                    .into(),
                    is_unknown: false,
                    days: record.days.clone(),
                });
            }
        }
        reconcile_named_days(&mut series, source, aggregate.get(source));

        // Aggregate history can predate project attribution or include usage
        // whose metadata was missing/ambiguous. Preserve only that remainder
        // as Unknown instead of assigning it to a named project.
        let Some(source_days) = aggregate.get(source) else {
            continue;
        };
        let mut residual = HashMap::new();
        for (date, total) in source_days {
            let known = series
                .iter()
                .filter(|project| project.source == source)
                .filter_map(|project| project.days.get(date))
                .fold((0.0, 0_i64), |acc, day| {
                    (acc.0 + day.usd, acc.1 + day.tokens)
                });
            let usd = (total.usd - known.0).max(0.0);
            let tokens = (total.tokens - known.1).max(0);
            if usd > 0.0 || tokens > 0 {
                residual.insert(
                    date.clone(),
                    ProjectDay {
                        usd,
                        tokens,
                        models: Vec::new(),
                    },
                );
            }
        }
        if !residual.is_empty() {
            series.push(unknown_series(source, residual));
        }
    }
    series
}

fn window_bounds(today: NaiveDate, days: u16) -> (String, String) {
    (
        (today - Duration::days(i64::from(days) - 1)).to_string(),
        today.to_string(),
    )
}

fn ranking(project: &ProjectSeries, start: &str, end: &str) -> ProjectRanking {
    let (usd, tokens) = project
        .days
        .iter()
        .filter(|(date, _)| date.as_str() >= start && date.as_str() <= end)
        .fold((0.0, 0_i64), |acc, (_, day)| {
            (acc.0 + day.usd, acc.1 + day.tokens)
        });
    ProjectRanking {
        project_key: project.project_key.clone(),
        display_name: project.display_name.clone(),
        source: project.source.clone(),
        capability: project.capability.clone(),
        is_unknown: project.is_unknown,
        usd,
        tokens,
    }
}

fn compare_rankings(a: &ProjectRanking, b: &ProjectRanking) -> std::cmp::Ordering {
    b.usd
        .total_cmp(&a.usd)
        .then_with(|| b.tokens.cmp(&a.tokens))
        .then_with(|| a.source.cmp(&b.source))
        .then_with(|| a.project_key.cmp(&b.project_key))
}

fn rank_projects(series: &[ProjectSeries], start: &str, end: &str) -> Vec<ProjectRanking> {
    let mut rows: Vec<_> = series
        .iter()
        .map(|project| ranking(project, start, end))
        .filter(|row| row.usd > 0.0 || row.tokens > 0)
        .collect();
    rows.sort_by(compare_rankings);
    rows.truncate(PROJECT_RANKING_LIMIT);
    rows
}

fn selected_detail(
    series: &[ProjectSeries],
    selected_key: Option<&str>,
    start: &str,
    end: &str,
) -> Option<ProjectDetail> {
    let project = series
        .iter()
        .find(|project| Some(project.project_key.as_str()) == selected_key)?;
    let project_row = ranking(project, start, end);
    let mut daily = Vec::new();
    let mut models: HashMap<String, ProjectModel> = HashMap::new();
    for (date, day) in &project.days {
        if !valid_day_key(date) {
            continue;
        }
        if date.as_str() < start || date.as_str() > end {
            continue;
        }
        daily.push(ProjectDetailDay {
            date: date.clone(),
            usd: day.usd,
            tokens: day.tokens,
        });
        for model in &day.models {
            let name = safe_name(&model.name);
            let entry = models
                .entry(name.clone())
                .or_insert_with(|| ProjectModel {
                    name,
                    usd: 0.0,
                    tokens: 0,
                });
            entry.usd += model.usd;
            entry.tokens += model.tokens;
        }
    }
    daily.sort_by(|a, b| a.date.cmp(&b.date));
    let mut models: Vec<_> = models.into_values().collect();
    models.sort_by(|a, b| {
        b.usd
            .total_cmp(&a.usd)
            .then_with(|| b.tokens.cmp(&a.tokens))
            .then_with(|| a.name.cmp(&b.name))
    });
    Some(ProjectDetail {
        project: project_row,
        daily,
        models,
    })
}

fn overview(
    today: NaiveDate,
    aggregate: &HashMap<String, HashMap<String, cost_history::HistoryDay>>,
    current: &HashMap<String, UsageReport>,
    scanned_at: &HashMap<String, i64>,
    series: &[ProjectSeries],
    enabled_sources: &HashSet<String>,
) -> Overview {
    let (current_start, current_end) = window_bounds(today, 7);
    let previous_end = today - Duration::days(7);
    let (previous_start, previous_end) = window_bounds(previous_end, 7);
    let mut current_by_source: HashMap<String, SourceTotal> = HashMap::new();
    let mut previous = (0.0, 0_i64);
    let mut models: HashMap<(String, String), ModelTotal> = HashMap::new();

    for source in SOURCES
        .into_iter()
        .filter(|source| enabled_sources.contains(*source))
    {
        let mut total = SourceTotal {
            source: source.into(),
            usd: 0.0,
            tokens: 0,
        };
        for (date, day) in aggregate.get(source).into_iter().flatten() {
            if date >= &current_start && date <= &current_end {
                total.usd += day.usd;
                total.tokens += day.tokens;
                for model in &day.models {
                    let key = (source.to_string(), model.name.clone());
                    let entry = models.entry(key).or_insert_with(|| ModelTotal {
                        source: source.into(),
                        name: safe_name(&model.name),
                        usd: 0.0,
                        tokens: 0,
                    });
                    entry.usd += model.usd;
                    entry.tokens += model.tokens;
                }
            } else if date >= &previous_start && date <= &previous_end {
                previous.0 += day.usd;
                previous.1 += day.tokens;
            }
        }
        current_by_source.insert(source.into(), total);
    }
    let current_total = current_by_source.values().fold((0.0, 0_i64), |acc, total| {
        (acc.0 + total.usd, acc.1 + total.tokens)
    });
    let top_source = current_by_source
        .into_values()
        .filter(|value| value.usd > 0.0 || value.tokens > 0)
        .max_by(|a, b| {
            a.tokens
                .cmp(&b.tokens)
                .then_with(|| a.usd.total_cmp(&b.usd))
                .then_with(|| b.source.cmp(&a.source))
        });
    let top_model = models.into_values().max_by(|a, b| {
        a.tokens
            .cmp(&b.tokens)
            .then_with(|| a.usd.total_cmp(&b.usd))
            .then_with(|| b.name.cmp(&a.name))
            .then_with(|| b.source.cmp(&a.source))
    });
    let top_project = rank_projects(series, &current_start, &current_end)
        .into_iter()
        .next();
    let confidence = SOURCES
        .iter()
        .filter(|source| enabled_sources.contains(**source))
        .map(|source| {
            let current_report = current.get(*source);
            let has_history = aggregate
                .get(*source)
                .is_some_and(|days| days.values().any(|day| day.usd > 0.0 || day.tokens > 0));
            let state = if current_report.is_some_and(|report| report.included && report.live) {
                "live"
            } else if current_report.is_some_and(|report| report.included) || has_history {
                "history"
            } else {
                "unavailable"
            };
            SourceConfidence {
                source: (*source).into(),
                state: state.into(),
                scanned_at: current_report
                    .and_then(|report| report.scanned_at)
                    .or_else(|| scanned_at.get(*source).copied()),
            }
        })
        .collect();

    Overview {
        current7_usd: current_total.0,
        current7_tokens: current_total.1,
        previous7_usd: previous.0,
        previous7_tokens: previous.1,
        change_pct: (previous.0 > 0.0)
            .then_some(((current_total.0 - previous.0) / previous.0) * 100.0),
        top_source,
        top_model,
        top_project,
        confidence,
    }
}

pub fn build_report(
    requested_days: u16,
    selected_key: Option<&str>,
    current: &HashMap<String, UsageReport>,
    enabled_sources: &HashSet<String>,
) -> Report {
    let days = match requested_days {
        1 => 1,
        30 => 30,
        90 => 90,
        _ => 7,
    };
    let today = Local::now().date_naive();
    let mut cost_doc = cost_history::read();
    let mut project_doc = project_cost_history::read();
    retain_enabled_sources(&mut cost_doc, &mut project_doc, enabled_sources);
    let aggregate = aggregate_days(&cost_doc, current);
    let series = build_series(&project_doc, &aggregate);
    let (start, end) = window_bounds(today, days);
    let projects = rank_projects(&series, &start, &end);
    let selected_project = selected_detail(&series, selected_key, &start, &end);
    Report {
        days,
        overview: overview(
            today, &aggregate, current, &cost_doc.scanned_at, &series,
            enabled_sources),
        projects,
        selected_project,
    }
}

fn retain_enabled_sources(
    cost_doc: &mut cost_history::Document,
    project_doc: &mut project_cost_history::Document,
    enabled_sources: &HashSet<String>,
) {
    cost_doc.sources.retain(|source, _| enabled_sources.contains(source));
    cost_doc.scanned_at.retain(|source, _| enabled_sources.contains(source));
    project_doc.sources.retain(|source, _| enabled_sources.contains(source));
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::TEST_ENV_LOCK;
    use std::fs;

    fn day(usd: f64, tokens: i64) -> ProjectDay {
        ProjectDay {
            usd,
            tokens,
            models: Vec::new(),
        }
    }

    #[test]
    fn ranking_is_cost_first_and_deterministic() {
        let today = Local::now().date_naive().to_string();
        let projects = vec![
            ProjectSeries {
                project_key: "b".repeat(64),
                display_name: "zeta".into(),
                source: "claude".into(),
                capability: "derivedPath".into(),
                is_unknown: false,
                days: HashMap::from([(today.clone(), day(2.0, 10))]),
            },
            ProjectSeries {
                project_key: "a".repeat(64),
                display_name: "alpha".into(),
                source: "claude".into(),
                capability: "derivedPath".into(),
                is_unknown: false,
                days: HashMap::from([(today.clone(), day(2.0, 10))]),
            },
            ProjectSeries {
                project_key: "c".repeat(64),
                display_name: "tokens".into(),
                source: "claude".into(),
                capability: "derivedPath".into(),
                is_unknown: false,
                days: HashMap::from([(today.clone(), day(1.0, 999))]),
            },
        ];
        let rows = rank_projects(&projects, &today, &today);
        assert_eq!(
            rows.iter()
                .map(|row| row.display_name.as_str())
                .collect::<Vec<_>>(),
            vec!["alpha", "zeta", "tokens"]
        );
    }

    #[test]
    fn ranking_tie_break_matches_macos_source_then_privacy_key() {
        let rows = vec![
            ProjectRanking {
                project_key: "a".repeat(64),
                display_name: "zeta".into(),
                source: "claude".into(),
                capability: "derivedPath".into(),
                is_unknown: false,
                usd: 1.0,
                tokens: 10,
            },
            ProjectRanking {
                project_key: "b".repeat(64),
                display_name: "alpha".into(),
                source: "claude".into(),
                capability: "derivedPath".into(),
                is_unknown: false,
                usd: 1.0,
                tokens: 10,
            },
        ];
        let mut sorted = rows;
        sorted.sort_by(compare_rankings);

        assert_eq!(sorted[0].display_name, "zeta");
    }

    #[test]
    fn detail_models_sort_by_cost_then_tokens_then_name() {
        let today = Local::now().date_naive().to_string();
        let project = ProjectSeries {
            project_key: "a".repeat(64),
            display_name: "birdnion".into(),
            source: "claude".into(),
            capability: "derivedPath".into(),
            is_unknown: false,
            days: HashMap::from([(
                today.clone(),
                ProjectDay {
                    usd: 4.0,
                    tokens: 2_500,
                    models: vec![
                        ProjectModel { name: "model-b".into(), usd: 1.0, tokens: 1_000 },
                        ProjectModel { name: "model-c".into(), usd: 2.0, tokens: 500 },
                        ProjectModel { name: "model-a".into(), usd: 1.0, tokens: 1_000 },
                    ],
                },
            )]),
        };

        let detail = selected_detail(&[project], Some(&"a".repeat(64)), &today, &today).unwrap();
        assert_eq!(
            detail.models.iter().map(|model| model.name.as_str()).collect::<Vec<_>>(),
            vec!["model-c", "model-a", "model-b"]
        );
    }

    #[test]
    fn ranking_payload_is_bounded() {
        let today = Local::now().date_naive().to_string();
        let projects = (0..(PROJECT_RANKING_LIMIT + 1))
            .map(|index| ProjectSeries {
                project_key: format!("{index:064x}"),
                display_name: format!("project-{index}"),
                source: "claude".into(),
                capability: "exact".into(),
                is_unknown: false,
                days: HashMap::from([(today.clone(), day(1.0, 1))]),
            })
            .collect::<Vec<_>>();

        assert_eq!(rank_projects(&projects, &today, &today).len(), PROJECT_RANKING_LIMIT);
    }

    #[test]
    fn safe_name_uses_basename_after_long_private_parent() {
        let parent = "private-parent".repeat(20);
        assert_eq!(safe_name(&format!("/Users/alice/{parent}/client-model")), "client-model");
    }

    #[test]
    fn disabled_sources_are_removed_from_aggregate_and_project_history() {
        let mut cost_doc = cost_history::Document::default();
        cost_doc.sources.insert("claude".into(), HashMap::new());
        cost_doc.sources.insert("codex".into(), HashMap::new());
        let mut project_doc = project_cost_history::Document::default();
        project_doc.sources.insert("claude".into(), HashMap::new());
        project_doc.sources.insert("codex".into(), HashMap::new());
        let enabled = HashSet::from(["codex".to_string()]);

        retain_enabled_sources(&mut cost_doc, &mut project_doc, &enabled);

        assert!(!cost_doc.sources.contains_key("claude"));
        assert!(!project_doc.sources.contains_key("claude"));
        assert!(cost_doc.sources.contains_key("codex"));
        assert!(project_doc.sources.contains_key("codex"));
    }

    #[test]
    fn codex_and_grok_include_named_rows_plus_exact_unknown_residuals() {
        let today = Local::now().date_naive().to_string();
        let aggregate = HashMap::from([
            (
                "codex".into(),
                HashMap::from([(
                    today.clone(),
                    cost_history::HistoryDay {
                        usd: 1.0,
                        tokens: 10,
                        models: Vec::new(),
                    },
                )]),
            ),
            (
                "grok".into(),
                HashMap::from([(
                    today.clone(),
                    cost_history::HistoryDay {
                        usd: 2.0,
                        tokens: 20,
                        models: Vec::new(),
                    },
                )]),
            ),
        ]);
        let project_doc = project_cost_history::Document {
            version: 1,
            applied_retraction_ids: HashMap::new(),
            sources: HashMap::from([
                (
                    "codex".into(),
                    HashMap::from([(
                        "c".repeat(64),
                        project_cost_history::ProjectRecord {
                            display_name: "birdnion".into(),
                            capability: "exact".into(),
                            days: HashMap::from([(today.clone(), day(0.6, 6))]),
                        },
                    )]),
                ),
                (
                    "grok".into(),
                    HashMap::from([(
                        "d".repeat(64),
                        project_cost_history::ProjectRecord {
                            display_name: "client".into(),
                            capability: "derivedPath".into(),
                            days: HashMap::from([(today.clone(), day(1.5, 15))]),
                        },
                    )]),
                ),
            ]),
        };

        let rows = build_series(&project_doc, &aggregate);

        assert_eq!(rows.len(), 4);
        for source in ["codex", "grok"] {
            assert!(rows.iter().any(|row| row.source == source && !row.is_unknown));
            assert!(rows.iter().any(|row| {
                row.project_key == format!("unknown-{source}")
                    && row.is_unknown
                    && row.capability == "unknown"
            }));
            let totals = rows
                .iter()
                .filter(|row| row.source == source)
                .filter_map(|row| row.days.get(&today))
                .fold((0.0, 0_i64), |sum, value| {
                    (sum.0 + value.usd, sum.1 + value.tokens)
                });
            let aggregate_day = &aggregate[source][&today];
            assert!((totals.0 - aggregate_day.usd).abs() < 1e-9);
            assert_eq!(totals.1, aggregate_day.tokens);
        }
    }

    #[test]
    fn sequential_project_high_water_is_scaled_to_authoritative_aggregate() {
        let today = Local::now().date_naive().to_string();
        let aggregate = HashMap::from([(
            "codex".into(),
            HashMap::from([(
                today.clone(),
                cost_history::HistoryDay {
                    usd: 100.0,
                    tokens: 100,
                    models: Vec::new(),
                },
            )]),
        )]);
        let project_doc = project_cost_history::Document {
            version: 1,
            applied_retraction_ids: HashMap::new(),
            sources: HashMap::from([(
                "codex".into(),
                HashMap::from([
                    (
                        "a".repeat(64),
                        project_cost_history::ProjectRecord {
                            display_name: "project-a".into(),
                            capability: "exact".into(),
                            days: HashMap::from([(
                                today.clone(),
                                ProjectDay {
                                    usd: 30.0,
                                    tokens: 100,
                                    models: vec![
                                        ProjectModel {
                                            name: "zeta".into(),
                                            usd: 20.0,
                                            tokens: 1,
                                        },
                                        ProjectModel {
                                            name: "alpha".into(),
                                            usd: 10.0,
                                            tokens: 1,
                                        },
                                    ],
                                },
                            )]),
                        },
                    ),
                    (
                        "b".repeat(64),
                        project_cost_history::ProjectRecord {
                            display_name: "project-b".into(),
                            capability: "exact".into(),
                            days: HashMap::from([(
                                today.clone(),
                                ProjectDay {
                                    usd: 20.0,
                                    tokens: 100,
                                    models: vec![ProjectModel {
                                        name: "gamma".into(),
                                        usd: 20.0,
                                        tokens: 100,
                                    }],
                                },
                            )]),
                        },
                    ),
                ]),
            )]),
        };

        let rows = build_series(&project_doc, &aggregate);
        let project_a = rows
            .iter()
            .find(|row| row.project_key == "a".repeat(64))
            .unwrap();
        let project_b = rows
            .iter()
            .find(|row| row.project_key == "b".repeat(64))
            .unwrap();
        let unknown = rows
            .iter()
            .find(|row| row.project_key == "unknown-codex")
            .unwrap();

        assert_eq!(project_a.days[&today].tokens, 50);
        assert_eq!(project_b.days[&today].tokens, 50);
        assert_eq!(project_a.days[&today].usd, 30.0);
        assert_eq!(project_b.days[&today].usd, 20.0);
        assert_eq!(
            project_a.days[&today]
                .models
                .iter()
                .find(|model| model.name == "alpha")
                .unwrap()
                .usd,
            10.0
        );
        assert_eq!(unknown.days[&today].tokens, 0);
        assert_eq!(unknown.days[&today].usd, 50.0);
        let models = &project_a.days[&today].models;
        assert_eq!(models.iter().find(|model| model.name == "alpha").unwrap().tokens, 1);
        assert_eq!(models.iter().find(|model| model.name == "zeta").unwrap().tokens, 0);
        let totals = rows
            .iter()
            .filter(|row| row.source == "codex")
            .filter_map(|row| row.days.get(&today))
            .fold((0.0, 0_i64), |sum, value| {
                (sum.0 + value.usd, sum.1 + value.tokens)
            });
        assert_eq!(totals, (100.0, 100));
    }

    #[test]
    fn explicit_ambiguity_retraction_projects_usage_as_unknown() {
        let _guard = TEST_ENV_LOCK.lock().unwrap();
        let base = std::env::temp_dir().join(format!(
            "birdnion-project-insights-retraction-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&base);
        fs::create_dir_all(&base).unwrap();
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));
        let today = Local::now().date_naive().to_string();
        let contribution = project_cost_history::ProjectContribution {
            project_key: "a".repeat(64),
            display_name: "project-a".into(),
            capability: "exact".into(),
            date: today.clone(),
            usd: 1.0,
            tokens: 100,
            models: vec![ProjectModel {
                name: "gpt-5".into(),
                usd: 1.0,
                tokens: 100,
            }],
        };
        let retraction = project_cost_history::ProjectRetraction {
            retraction_id: "e".repeat(64),
            project_key: contribution.project_key.clone(),
            contributions: vec![contribution.clone()],
        };
        project_cost_history::apply("codex", &[contribution], false).unwrap();
        project_cost_history::apply_with_retractions(
            "codex",
            &[],
            &[retraction.clone()],
            false,
        )
        .unwrap();
        project_cost_history::apply_with_retractions("codex", &[], &[retraction], false)
            .unwrap();
        let aggregate = HashMap::from([(
            "codex".into(),
            HashMap::from([(
                today.clone(),
                cost_history::HistoryDay {
                    usd: 1.0,
                    tokens: 100,
                    models: Vec::new(),
                },
            )]),
        )]);

        let rows = build_series(&project_cost_history::read(), &aggregate);

        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].project_key, "unknown-codex");
        assert_eq!(rows[0].days[&today].tokens, 100);
        assert!((rows[0].days[&today].usd - 1.0).abs() < 1e-12);

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = fs::remove_dir_all(base);
    }

    #[test]
    fn usd_reconciliation_scales_models_without_scaling_authoritative_tokens() {
        let today = Local::now().date_naive().to_string();
        let mut rows = vec![
            ProjectSeries {
                project_key: "a".repeat(64),
                display_name: "project-a".into(),
                source: "codex".into(),
                capability: "exact".into(),
                is_unknown: false,
                days: HashMap::from([(
                    today.clone(),
                    ProjectDay {
                        usd: 80.0,
                        tokens: 25,
                        models: vec![ProjectModel {
                            name: "alpha".into(),
                            usd: 80.0,
                            tokens: 25,
                        }],
                    },
                )]),
            },
            ProjectSeries {
                project_key: "b".repeat(64),
                display_name: "project-b".into(),
                source: "codex".into(),
                capability: "exact".into(),
                is_unknown: false,
                days: HashMap::from([(
                    today.clone(),
                    ProjectDay {
                        usd: 20.0,
                        tokens: 75,
                        models: vec![ProjectModel {
                            name: "beta".into(),
                            usd: 20.0,
                            tokens: 75,
                        }],
                    },
                )]),
            },
        ];
        let aggregate = HashMap::from([(
            today.clone(),
            cost_history::HistoryDay {
                usd: 50.0,
                tokens: 100,
                models: Vec::new(),
            },
        )]);

        reconcile_named_days(&mut rows, "codex", Some(&aggregate));

        assert_eq!(rows[0].days[&today].usd, 40.0);
        assert_eq!(rows[1].days[&today].usd, 10.0);
        assert_eq!(rows[0].days[&today].tokens, 25);
        assert_eq!(rows[1].days[&today].tokens, 75);
        assert_eq!(rows[0].days[&today].models[0].usd, 40.0);
        assert_eq!(rows[1].days[&today].models[0].usd, 10.0);
        assert_eq!(rows[0].days[&today].models[0].tokens, 25);
        assert_eq!(rows[1].days[&today].models[0].tokens, 75);
    }

    #[test]
    fn token_largest_remainder_is_deterministic_by_privacy_key() {
        let forward = proportional_token_targets(
            &[("b".into(), 40), ("a".into(), 80)],
            100,
        );
        let reverse = proportional_token_targets(
            &[("a".into(), 80), ("b".into(), 40)],
            100,
        );
        let tied = proportional_token_targets(
            &[("b".into(), 1), ("a".into(), 1)],
            1,
        );

        assert_eq!(forward, vec![33, 67]);
        assert_eq!(reverse, vec![67, 33]);
        assert_eq!(tied, vec![0, 1]);
    }

    #[test]
    fn unsafe_persisted_key_is_not_exposed() {
        let doc = project_cost_history::Document {
            version: 1,
            applied_retraction_ids: HashMap::new(),
            sources: HashMap::from([(
                "claude".into(),
                HashMap::from([(
                    "/Users/private/repo".into(),
                project_cost_history::ProjectRecord {
                    display_name: "/Users/private/repo".into(),
                    capability: "exact".into(),
                    days: HashMap::new(),
                },
                )]),
            )]),
        };
        assert!(build_series(&doc, &HashMap::new()).is_empty());
        assert_eq!(safe_name("/Users/private/repo"), "repo");
    }
}
