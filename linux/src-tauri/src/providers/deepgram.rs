//! Deepgram (speech) usage provider — port of `DeepgramProvider.swift`.
//!
//! API key (header `Authorization: Token …`) → lists projects, then
//! aggregates the 30-day usage breakdown (requests + audio hours) across
//! either all projects or one filtered by `cfg.project_id`. No hard quota,
//! so surfaced as info windows (used_pct = 0).

use serde_json::Value;

use crate::config;
use crate::providers::{display_name, shared_client, ProviderStatus, QuotaWindow};

const BASE: &str = "https://api.deepgram.com/v1";

pub async fn fetch(cfg: &config::Provider) -> ProviderStatus {
    let name = display_name(cfg);
    let Some(token) = config::api_key(cfg) else {
        return ProviderStatus::failure(&cfg.id, &name, "Chưa cấu hình API key Deepgram");
    };
    let account_label = cfg
        .account_label
        .clone()
        .unwrap_or_else(|| token.chars().take(8).collect());

    let client = shared_client();
    let projects: Value = match get(&client, &format!("{BASE}/projects"), &token).await {
        Ok(v) => v,
        Err(e) => return ProviderStatus::failure(&cfg.id, &name, e),
    };
    let Some(projects) = projects.get("projects").and_then(Value::as_array) else {
        return ProviderStatus::failure(&cfg.id, &name, "Response thiếu trường");
    };
    if projects.is_empty() {
        return ProviderStatus::failure(&cfg.id, &name, "Không có project Deepgram cho key này");
    }

    let config_pid = cfg.project_id.as_deref().map(str::trim).filter(|s| !s.is_empty());
    let mut target_projects: Vec<(String, Option<String>)> = projects
        .iter()
        .filter_map(|p| {
            let id = p.get("project_id").and_then(Value::as_str)?.to_string();
            let name = p.get("name").and_then(Value::as_str).map(String::from);
            Some((id, name))
        })
        .collect();
    if let Some(pid) = config_pid {
        let matched: Vec<_> = target_projects.iter().filter(|(id, _)| id == pid).cloned().collect();
        target_projects = if matched.is_empty() { vec![(pid.to_string(), None)] } else { matched };
    }

    let now = chrono::Utc::now();
    let start = (now - chrono::Duration::days(30)).format("%Y-%m-%d").to_string();
    let end = now.format("%Y-%m-%d").to_string();

    let mut agg = Aggregate::default();
    let mut ok = 0;
    for (pid, _) in &target_projects {
        let url = format!("{BASE}/projects/{pid}/usage/breakdown?start={start}&end={end}");
        if let Ok(usage) = get(&client, &url, &token).await {
            agg.add(&usage);
            ok += 1;
        }
    }
    if ok == 0 {
        return ProviderStatus::failure(&cfg.id, &name, "Không lấy được usage Deepgram");
    }
    let plan_name = if target_projects.len() > 1 {
        format!("{} projects", target_projects.len())
    } else {
        format!(
            "Project: {}",
            target_projects
                .first()
                .and_then(|(id, n)| n.clone().or_else(|| Some(id.clone())))
                .unwrap_or_default()
        )
    };
    materialize(&cfg.id, &name, &account_label, &agg, &plan_name)
}

async fn get(client: &reqwest::Client, url: &str, token: &str) -> Result<Value, String> {
    let resp = client
        .get(url)
        .header("Authorization", format!("Token {token}"))
        .header("Accept", "application/json")
        .send()
        .await
        .map_err(|e| format!("Network: {e}"))?;
    match resp.status().as_u16() {
        200..=299 => {}
        401 | 403 => return Err("API key Deepgram không hợp lệ".to_string()),
        code => return Err(format!("HTTP {code}")),
    }
    resp.json().await.map_err(|_| "Response thiếu trường".to_string())
}

#[derive(Default)]
struct Aggregate {
    requests: i64,
    hours: f64,
    total_hours: f64,
    agent_hours: f64,
    tokens_in: i64,
    tokens_out: i64,
    tts_characters: i64,
}

impl Aggregate {
    fn add(&mut self, usage: &Value) {
        let Some(results) = usage.get("results").and_then(Value::as_array) else { return };
        for r in results {
            self.requests += r.get("requests").and_then(Value::as_i64).unwrap_or(0);
            self.hours += r.get("hours").and_then(Value::as_f64).unwrap_or(0.0);
            self.total_hours += r.get("total_hours").and_then(Value::as_f64).unwrap_or(0.0);
            self.agent_hours += r.get("agent_hours").and_then(Value::as_f64).unwrap_or(0.0);
            self.tokens_in += r.get("tokens_in").and_then(Value::as_i64).unwrap_or(0);
            self.tokens_out += r.get("tokens_out").and_then(Value::as_i64).unwrap_or(0);
            self.tts_characters += r.get("tts_characters").and_then(Value::as_i64).unwrap_or(0);
        }
    }
}

fn fmt(n: i64) -> String {
    let s = n.abs().to_string();
    let grouped: String = s
        .chars()
        .rev()
        .enumerate()
        .flat_map(|(i, c)| if i > 0 && i % 3 == 0 { vec![c, ','] } else { vec![c] })
        .collect::<String>()
        .chars()
        .rev()
        .collect();
    if n < 0 {
        format!("-{grouped}")
    } else {
        grouped
    }
}

/// Pure aggregate → status mapping (unit-tested).
fn materialize(id: &str, name: &str, account_label: &str, agg: &Aggregate, plan_name: &str) -> ProviderStatus {
    let mut windows = vec![QuotaWindow {
        label: "Requests (30d)".into(),
        used_pct: 0,
        remaining_pct: 100,
        subtitle: Some(fmt(agg.requests)),
        resets_at: None,
    }];
    if agg.hours > 0.0 {
        let audio = if agg.total_hours > 0.0 {
            format!("{:.1} giờ · {:.1} billable", agg.hours, agg.total_hours)
        } else {
            format!("{:.1} giờ", agg.hours)
        };
        windows.push(QuotaWindow {
            label: "Audio (30d)".into(),
            used_pct: 0,
            remaining_pct: 100,
            subtitle: Some(audio),
            resets_at: None,
        });
    }
    let mut extra = Vec::new();
    let tokens = agg.tokens_in + agg.tokens_out;
    if tokens > 0 {
        extra.push(format!("{} tokens", fmt(tokens)));
    }
    if agg.tts_characters > 0 {
        extra.push(format!("{} TTS", fmt(agg.tts_characters)));
    }
    if agg.agent_hours > 0.0 {
        extra.push(format!("{:.1} agent giờ", agg.agent_hours));
    }
    if !extra.is_empty() {
        windows.push(QuotaWindow {
            label: "Chi tiết (30d)".into(),
            used_pct: 0,
            remaining_pct: 100,
            subtitle: Some(extra.join(" · ")),
            resets_at: None,
        });
    }
    let _ = plan_name; // surfaced via account_label/plan in Swift; no plan field on Rust ProviderStatus.
    ProviderStatus {
        id: id.to_string(),
        display_name: name.to_string(),
        windows,
        last_updated: chrono::Utc::now().timestamp(),
        error: None,
        account_label: Some(account_label.to_string()),
        credits_remaining: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn aggregates_breakdown_results() {
        let mut agg = Aggregate::default();
        agg.add(&json!({"results": [
            {"requests": 10, "hours": 1.5, "total_hours": 2.0, "tokens_in": 100, "tokens_out": 50}
        ]}));
        let s = materialize("deepgram", "Deepgram", "key1234", &agg, "Project: p1");
        assert!(s.error.is_none());
        assert_eq!(s.windows.len(), 3);
        assert_eq!(s.windows[0].subtitle.as_deref(), Some("10"));
        assert_eq!(s.windows[1].subtitle.as_deref(), Some("1.5 giờ · 2.0 billable"));
        assert_eq!(s.windows[2].subtitle.as_deref(), Some("150 tokens"));
    }

    #[test]
    fn zero_usage_only_shows_requests_window() {
        let agg = Aggregate::default();
        let s = materialize("deepgram", "Deepgram", "key1234", &agg, "Project: p1");
        assert_eq!(s.windows.len(), 1);
        assert_eq!(s.windows[0].subtitle.as_deref(), Some("0"));
    }
}
