//! Oh My Pi (`omp`) session cost scanner.
//! Walks session JSONL logs under `~/.omp/agent/sessions/` and named profile roots.

use chrono::{DateTime, Duration, Local, NaiveDate};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::fs::File;
use std::io::{BufRead, BufReader};
use std::path::{Component, Path, PathBuf};
use walkdir::WalkDir;

use crate::project_cost_history::{ProjectContribution, ProjectModel};
use crate::usage::{DailyModel, DailyUsage, UsageReport};

pub const HISTORY_DAYS: i64 = 120;

#[derive(Clone, Debug, PartialEq)]
struct ProjectIdentity {
    key: String,
    display_name: String,
    label_is_verified: bool,
}

pub struct OMPUsageScan {
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
    if raw_name.is_empty() || raw_name.chars().any(|c| c.is_control() || c == '/' || c == '\\') {
        None
    } else {
        Some(raw_name.to_string())
    }
}

fn sha256_hex(input: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(input);
    format!("{:x}", hasher.finalize())
}

impl ProjectIdentity {
    fn from_cwd(cwd: Option<&str>) -> Option<Self> {
        let cwd = cwd?;
        let normalized = normalized_absolute_path(cwd)?;
        let display_name = safe_absolute_basename(cwd)
            .unwrap_or_else(|| format!("OMP Project {}", &sha256_hex(normalized.to_string_lossy().as_bytes())[..8]));
        let key = sha256_hex(format!("omp:cwd-v1\0{}", normalized.to_string_lossy()).as_bytes());
        Some(Self {
            key,
            display_name,
            label_is_verified: true,
        })
    }
}

/// Discover all session roots for OMP (default + named profiles + XDG).
pub fn discover_session_roots() -> Vec<PathBuf> {
    let mut roots = Vec::new();
    let home = std::env::var("HOME").unwrap_or_default();
    if home.is_empty() {
        return roots;
    }

    let base_dir = std::env::var("PI_CONFIG_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from(&home).join(".omp"));

    // 1. Default session directory
    let default_sessions = std::env::var("PI_CODING_AGENT_DIR")
        .map(|d| PathBuf::from(d).join("sessions"))
        .unwrap_or_else(|_| base_dir.join("agent").join("sessions"));

    if default_sessions.is_dir() {
        roots.push(default_sessions);
    }

    // 2. Active profile from environment
    if let Ok(profile) = std::env::var("OMP_PROFILE").or_else(|_| std::env::var("PI_PROFILE")) {
        if !profile.trim().is_empty() {
            let p_dir = base_dir.join("profiles").join(profile.trim()).join("agent").join("sessions");
            if p_dir.is_dir() && !roots.contains(&p_dir) {
                roots.push(p_dir);
            }
        }
    }

    // 3. Profiles under ~/.omp/profiles/*/agent/sessions
    let profiles_dir = base_dir.join("profiles");
    if let Ok(entries) = std::fs::read_dir(profiles_dir) {
        for entry in entries.flatten() {
            let p_dir = entry.path().join("agent").join("sessions");
            if p_dir.is_dir() && !roots.contains(&p_dir) {
                roots.push(p_dir);
            }
        }
    }

    // 4. XDG Data Home
    if let Ok(xdg) = std::env::var("XDG_DATA_HOME") {
        let xdg_p = PathBuf::from(xdg).join("omp").join("agent").join("sessions");
        if xdg_p.is_dir() && !roots.contains(&xdg_p) {
            roots.push(xdg_p);
        }
    }

    roots
}

struct ParsedTurn {
    date: NaiveDate,
    model: String,
    tokens: i64,
    usd: f64,
    cwd: Option<String>,
}

pub fn scan_omp_usage(now: DateTime<Local>) -> OMPUsageScan {
    let roots = discover_session_roots();
    let cutoff_date = (now - Duration::days(HISTORY_DAYS)).date_naive();
    let mut turns = Vec::new();
    let mut seen_turns: HashSet<(String, String)> = HashSet::new();

    for root in roots {
        for entry in WalkDir::new(root).into_iter().flatten() {
            let path = entry.path();
            if !path.is_file() || path.extension().and_then(|s| s.to_str()) != Some("jsonl") {
                continue;
            }

            let Ok(file) = File::open(path) else { continue };
            let reader = BufReader::new(file);
            let mut session_cwd: Option<String> = None;

            for line in reader.lines().flatten() {
                let trimmed = line.trim();
                if trimmed.is_empty() {
                    continue;
                }
                let Ok(json) = serde_json::from_str::<Value>(trimmed) else {
                    continue;
                };

                let entry_type = json.get("type").and_then(|v| v.as_str()).unwrap_or_default();
                if entry_type == "session" {
                    if let Some(cwd) = json.get("cwd").and_then(|v| v.as_str()) {
                        if !cwd.is_empty() {
                            session_cwd = Some(cwd.to_string());
                        }
                    }
                } else if entry_type == "message" {
                    let Some(msg) = json.get("message") else { continue };
                    let role = msg.get("role").and_then(|v| v.as_str()).unwrap_or_default();
                    if role != "assistant" {
                        continue;
                    }

                    let entry_id = json.get("id").and_then(|v| v.as_str())
                        .or_else(|| msg.get("id").and_then(|v| v.as_str()))
                        .unwrap_or_default()
                        .to_string();

                    let timestamp_str = msg.get("timestamp").and_then(|v| v.as_str())
                        .or_else(|| json.get("timestamp").and_then(|v| v.as_str()))
                        .unwrap_or_default();

                    let turn_key = (entry_id, timestamp_str.to_string());
                    if seen_turns.contains(&turn_key) {
                        continue;
                    }
                    seen_turns.insert(turn_key);

                    let Ok(ts) = DateTime::parse_from_rfc3339(timestamp_str) else { continue };
                    let date = ts.with_timezone(&Local).date_naive();
                    if date < cutoff_date {
                        continue;
                    }

                    let model = msg.get("model").and_then(|v| v.as_str())
                        .or_else(|| json.get("model").and_then(|v| v.as_str()))
                        .unwrap_or("unknown")
                        .to_string();

                    let usage = msg.get("usage").or_else(|| json.get("usage"));
                    let total_tokens = usage.and_then(|u| u.get("totalTokens").or_else(|| u.get("total_tokens")))
                        .and_then(|v| v.as_i64())
                        .unwrap_or(0);

                    let cost_usd = usage.and_then(|u| {
                        u.get("cost").and_then(|c| c.get("total")).and_then(|v| v.as_f64())
                            .or_else(|| u.get("costUSD").or_else(|| u.get("cost_usd")).and_then(|v| v.as_f64()))
                    }).unwrap_or(0.0).max(0.0);

                    turns.push(ParsedTurn {
                        date,
                        model,
                        tokens: total_tokens,
                        usd: cost_usd,
                        cwd: session_cwd.clone(),
                    });
                }
            }
        }
    }

    // Build Daily and Project aggregates
    let today_date = now.date_naive();
    let mut daily_map: HashMap<NaiveDate, (f64, i64, HashMap<String, (f64, i64)>)> = HashMap::new();
    let mut project_map: HashMap<String, (String, bool, HashMap<NaiveDate, (f64, i64, HashMap<String, (f64, i64)>)>)> = HashMap::new();

    for turn in turns {
        let entry = daily_map.entry(turn.date).or_insert_with(|| (0.0, 0, HashMap::new()));
        entry.0 += turn.usd;
        entry.1 += turn.tokens;
        let m_entry = entry.2.entry(turn.model.clone()).or_insert((0.0, 0));
        m_entry.0 += turn.usd;
        m_entry.1 += turn.tokens;

        if let Some(identity) = ProjectIdentity::from_cwd(turn.cwd.as_deref()) {
            let p_entry = project_map.entry(identity.key.clone()).or_insert_with(|| {
                (identity.display_name.clone(), identity.label_is_verified, HashMap::new())
            });
            let p_day = p_entry.2.entry(turn.date).or_insert_with(|| (0.0, 0, HashMap::new()));
            p_day.0 += turn.usd;
            p_day.1 += turn.tokens;
            let pm_entry = p_day.2.entry(turn.model).or_insert((0.0, 0));
            pm_entry.0 += turn.usd;
            pm_entry.1 += turn.tokens;
        }
    }

    // Build 120 contiguous days
    let mut daily_list = Vec::with_capacity(HISTORY_DAYS as usize);
    let mut last30_usd = 0.0;
    let mut last30_tokens = 0;
    let last30_cutoff = (now - Duration::days(30)).date_naive();

    for i in (0..HISTORY_DAYS).rev() {
        let d = (now - Duration::days(i)).date_naive();
        if let Some((usd, tokens, model_map)) = daily_map.get(&d) {
            let models: Vec<DailyModel> = model_map.iter().map(|(name, (m_usd, m_tok))| DailyModel {
                name: name.clone(),
                usd: *m_usd,
                tokens: *m_tok,
            }).collect();

            if d > last30_cutoff {
                last30_usd += usd;
                last30_tokens += tokens;
            }

            daily_list.push(DailyUsage {
                date: d.format("%Y-%m-%d").to_string(),
                usd: *usd,
                tokens: *tokens,
                models,
            });
        } else {
            daily_list.push(DailyUsage {
                date: d.format("%Y-%m-%d").to_string(),
                usd: 0.0,
                tokens: 0,
                models: Vec::new(),
            });
        }
    }

    let today_entry = daily_map.get(&today_date);
    let today_usd = today_entry.map(|e| e.0).unwrap_or(0.0);
    let today_tokens = today_entry.map(|e| e.1).unwrap_or(0);

    let mut all_models: HashMap<String, f64> = HashMap::new();
    for entry in daily_map.values() {
        for (m, (usd, _)) in &entry.2 {
            *all_models.entry(m.clone()).or_insert(0.0) += usd;
        }
    }
    let top_model = all_models.into_iter().max_by(|a, b| a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal)).map(|(m, _)| m);

    let mut projects = Vec::new();
    for (key, (name, verified, days)) in project_map {
        for (d, (usd, tokens, m_map)) in days {
            let p_models: Vec<ProjectModel> = m_map.into_iter().map(|(m_name, (m_usd, m_tok))| ProjectModel {
                name: m_name,
                usd: m_usd,
                tokens: m_tok,
            }).collect();
            projects.push(ProjectContribution {
                project_key: key.clone(),
                display_name: name.clone(),
                capability: if verified { "exact".to_string() } else { "derivedPath".to_string() },
                date: d.format("%Y-%m-%d").to_string(),
                usd,
                tokens,
                models: p_models,
            });
        }
    }

    OMPUsageScan {
        usage: UsageReport {
            today_usd,
            today_tokens,
            last30_usd,
            last30_tokens,
            daily: daily_list,
            hourly: Vec::new(),
            top_model,
            included: true,
            live: true,
            scanned_at: None,
        },
        projects,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    #[test]
    fn test_project_identity_from_cwd() {
        let identity = ProjectIdentity::from_cwd(Some("/Users/test/projects/alpha")).unwrap();
        assert_eq!(identity.display_name, "alpha");
        assert!(identity.label_is_verified);
        assert_eq!(identity.key.len(), 64);
    }
}
