//! OpenAI API Platform provider — port of macOS `OpenAIProvider.swift`.
//!
//! Preferred: Admin API org costs + completions usage.
//! Fallback: legacy credit grants for user API keys (no project scope).

use chrono::{Duration, Utc};
use serde_json::Value;

use crate::config;
use crate::providers::{display_name, shared_client, ProviderStatus, QuotaWindow};

const COSTS_URL: &str = "https://api.openai.com/v1/organization/costs";
const COMPLETIONS_URL: &str = "https://api.openai.com/v1/organization/usage/completions";
const CREDITS_URL: &str = "https://api.openai.com/v1/dashboard/billing/credit_grants";

pub async fn fetch(cfg: &config::Provider) -> ProviderStatus {
    let name = display_name(cfg);
    let Some(token) = resolve_token(cfg) else {
        return ProviderStatus::failure(
            &cfg.id,
            &name,
            "Chưa cấu hình OpenAI Admin/API key (OPENAI_ADMIN_KEY / Settings)",
        );
    };
    let project = resolve_project(cfg);
    let account = cfg
        .account_label
        .clone()
        .unwrap_or_else(|| token.chars().take(8).collect());

    match fetch_admin_usage(&token, project.as_deref()).await {
        Ok(status) => status.with_account(account),
        Err(admin_err) => {
            if project.is_some() {
                return ProviderStatus::failure(&cfg.id, &name, admin_err);
            }
            match fetch_credit_grants(&token).await {
                Ok(status) => status.with_account(account),
                Err(e) => ProviderStatus::failure(&cfg.id, &name, format!("{admin_err}; fallback: {e}")),
            }
        }
    }
}

fn resolve_token(cfg: &config::Provider) -> Option<String> {
    for var in ["OPENAI_ADMIN_KEY", "OPENAI_API_KEY"] {
        if let Ok(v) = std::env::var(var) {
            let v = v.trim().to_string();
            if !v.is_empty() {
                return Some(v);
            }
        }
    }
    config::api_key(cfg)
}

fn resolve_project(cfg: &config::Provider) -> Option<String> {
    if let Ok(v) = std::env::var("OPENAI_PROJECT_ID") {
        let v = v.trim().to_string();
        if !v.is_empty() {
            return Some(v);
        }
    }
    cfg.project_id
        .as_ref()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

async fn fetch_admin_usage(token: &str, project: Option<&str>) -> Result<ProviderStatus, String> {
    let client = shared_client();
    let now = Utc::now();
    let start = (now - Duration::days(30)).timestamp();
    let end = now.timestamp();

    let mut costs_url = format!(
        "{COSTS_URL}?start_time={start}&end_time={end}&bucket_width=1d&limit=31"
    );
    let mut comp_url = format!(
        "{COMPLETIONS_URL}?start_time={start}&end_time={end}&bucket_width=1d&limit=31"
    );
    if let Some(p) = project {
        costs_url.push_str(&format!("&project_ids={p}"));
        comp_url.push_str(&format!("&project_ids={p}"));
    }

    let costs = get_json(&client, &costs_url, token).await?;
    let comps = get_json(&client, &comp_url, token).await?;

    Ok(parse_admin_status("openai", "OpenAI", &costs, &comps, project))
}

async fn get_json(client: &reqwest::Client, url: &str, token: &str) -> Result<Value, String> {
    let resp = client
        .get(url)
        .bearer_auth(token)
        .header("Accept", "application/json")
        .send()
        .await
        .map_err(|e| format!("Network: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("HTTP {}", resp.status().as_u16()));
    }
    resp.json().await.map_err(|e| format!("JSON: {e}"))
}

/// Pure mapping for unit tests.
pub fn parse_admin_status(
    id: &str,
    name: &str,
    costs: &Value,
    _completions: &Value,
    project: Option<&str>,
) -> ProviderStatus {
    let buckets = costs
        .get("data")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();

    let mut by_day: Vec<(i64, f64)> = Vec::new();
    for b in &buckets {
        let start = b.get("start_time").and_then(Value::as_i64).unwrap_or(0);
        let mut day_cost = 0.0;
        if let Some(results) = b.get("results").and_then(Value::as_array) {
            for r in results {
                // amount.value is often in dollars as string/number
                let amt = r
                    .pointer("/amount/value")
                    .and_then(|v| v.as_f64().or_else(|| v.as_str().and_then(|s| s.parse().ok())))
                    .unwrap_or(0.0);
                day_cost += amt;
            }
        }
        by_day.push((start, day_cost));
    }
    by_day.sort_by_key(|(t, _)| *t);

    let today = by_day.last().map(|(_, c)| *c).unwrap_or(0.0);
    let week: f64 = by_day.iter().rev().take(7).map(|(_, c)| c).sum();
    let month: f64 = by_day.iter().map(|(_, c)| c).sum();

    let plan = project
        .map(|p| format!("Admin · {p}"))
        .unwrap_or_else(|| "Admin API".into());

    ProviderStatus {
        id: id.into(),
        display_name: name.into(),
        windows: vec![
            spend_window("Hôm nay", today),
            spend_window("7 ngày", week),
            spend_window("30 ngày", month),
        ],
        last_updated: Utc::now().timestamp(),
        error: None,
        account_label: None,
        credits_remaining: None,
        signed_in_email: None,
        code_review_remaining_percent: None,
        credits_purchase_url: None,
        credits_history_count: None,
        plan_type: None,
        plan_name: None,
        version: None,
        service_status: None,
        service_status_level: None,
        source_label: Some("Admin API".into()),
        credits_unlimited: false,
        kiro_context_percent: None,
    }
    .with_plan_label(plan)
}

fn spend_window(label: &str, usd: f64) -> QuotaWindow {
    QuotaWindow {
        label: label.into(),
        used_pct: 0,
        remaining_pct: 100,
        subtitle: Some(format!("${usd:.2}")),
        resets_at: None,
        window_seconds: None,
    }
}

async fn fetch_credit_grants(token: &str) -> Result<ProviderStatus, String> {
    let client = shared_client();
    let body = get_json(&client, CREDITS_URL, token).await?;
    Ok(parse_credits("openai", "OpenAI", &body))
}

pub fn parse_credits(id: &str, name: &str, body: &Value) -> ProviderStatus {
    let granted = body
        .get("total_granted")
        .and_then(Value::as_f64)
        .unwrap_or(0.0);
    let used = body.get("total_used").and_then(Value::as_f64).unwrap_or(0.0);
    let available = body
        .get("total_available")
        .and_then(Value::as_f64)
        .unwrap_or((granted - used).max(0.0));
    let used_pct = if granted > 0.0 {
        ((used / granted) * 100.0).round().clamp(0.0, 100.0) as i32
    } else if available > 0.0 {
        0
    } else {
        100
    };
    ProviderStatus {
        id: id.into(),
        display_name: name.into(),
        windows: vec![QuotaWindow {
            label: "Credits".into(),
            used_pct,
            remaining_pct: 100 - used_pct,
            subtitle: Some(format!("${available:.2} available / ${granted:.2} granted")),
            resets_at: None,
            window_seconds: None,
        }],
        last_updated: Utc::now().timestamp(),
        credits_remaining: Some(available),
        ..Default::default()
    }
}

trait StatusExtras {
    fn with_account(self, label: String) -> Self;
    fn with_plan_label(self, _plan: String) -> Self;
}

impl StatusExtras for ProviderStatus {
    fn with_account(mut self, label: String) -> Self {
        self.account_label = Some(label);
        self
    }
    fn with_plan_label(self, _plan: String) -> Self {
        // planName not on Linux ProviderStatus yet — windows carry the info
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parse_credits_used_percent() {
        let body = json!({
            "total_granted": 100.0,
            "total_used": 25.0,
            "total_available": 75.0
        });
        let s = parse_credits("openai", "OpenAI", &body);
        assert_eq!(s.windows[0].used_pct, 25);
        assert!((s.credits_remaining.unwrap() - 75.0).abs() < 0.01);
    }

    #[test]
    fn parse_admin_sums_buckets() {
        let costs = json!({
            "data": [
                {"start_time": 1, "results": [{"amount": {"value": 1.5}}]},
                {"start_time": 2, "results": [{"amount": {"value": 2.5}}]}
            ]
        });
        let s = parse_admin_status("openai", "OpenAI", &costs, &json!({}), None);
        assert_eq!(s.windows.len(), 3);
        // 30d = 4.0
        assert!(s.windows[2].subtitle.as_ref().unwrap().contains("4.00"));
    }
}
