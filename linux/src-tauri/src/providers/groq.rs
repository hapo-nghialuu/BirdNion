//! Groq usage provider — port of `GroqProvider.swift`.
//!
//! Bearer API key → Prometheus metrics endpoint reports rolling 5-minute
//! rates (no hard quota), surfaced as req/min + tokens/min info windows.

use serde_json::Value;

use crate::config;
use crate::providers::{display_name, shared_client, ProviderStatus, QuotaWindow};

const QUERY_URL: &str = "https://api.groq.com/v1/metrics/prometheus/api/v1/query";

pub async fn fetch(cfg: &config::Provider) -> ProviderStatus {
    let name = display_name(cfg);
    let Some(token) = config::api_key(cfg) else {
        return ProviderStatus::failure(&cfg.id, &name, "Chưa cấu hình API key Groq");
    };
    let account_label = cfg
        .account_label
        .clone()
        .unwrap_or_else(|| token.chars().take(8).collect());

    let client = shared_client();
    let requests = scalar(&client, "sum(model_project_id_status_code:requests:rate5m)", &token);
    let tokens_in = scalar(&client, "sum(model_project_id:tokens_in:rate5m)", &token);
    let tokens_out = scalar(&client, "sum(model_project_id:tokens_out:rate5m)", &token);
    let cache_hits = scalar(&client, "sum(model_project_id:prompt_cache_hits:rate5m)", &token);

    let (req, tin, tout, hits) = match futures::future::try_join4(requests, tokens_in, tokens_out, cache_hits).await
    {
        Ok(v) => v,
        Err(e) => return ProviderStatus::failure(&cfg.id, &name, format!("Groq: {e}")),
    };

    build_status(&cfg.id, &name, &account_label, req, tin, tout, hits)
}

async fn scalar(client: &reqwest::Client, query: &str, token: &str) -> Result<f64, String> {
    let resp = client
        .get(QUERY_URL)
        .query(&[("query", query)])
        .bearer_auth(token)
        .header("Accept", "application/json")
        .send()
        .await
        .map_err(|e| e.to_string())?;
    if !resp.status().is_success() {
        return Err(format!("HTTP {}", resp.status().as_u16()));
    }
    let body: Value = resp.json().await.map_err(|e| e.to_string())?;
    Ok(parse_scalar(&body))
}

/// Sums the last value of each result series in a Prometheus vector/scalar
/// response. Returns 0 on malformed or non-"success" payloads.
pub fn parse_scalar(body: &Value) -> f64 {
    if body.get("status").and_then(Value::as_str) != Some("success") {
        return 0.0;
    }
    let Some(results) = body.get("data").and_then(|d| d.get("result")).and_then(Value::as_array) else {
        return 0.0;
    };
    results
        .iter()
        .filter_map(|series| {
            let values = series.get("value").and_then(Value::as_array)?;
            let last = values.last()?;
            // Prometheus values are `[timestamp, "string-number"]` or plain numbers.
            last.as_str().and_then(|s| s.parse().ok()).or_else(|| last.as_f64())
        })
        .sum()
}

fn dec(v: f64) -> String {
    if v >= 100.0 {
        format!("{v:.0}")
    } else if v >= 10.0 {
        format!("{v:.1}")
    } else {
        format!("{v:.2}")
    }
}

/// Pure metrics → status mapping (unit-tested).
fn build_status(
    id: &str,
    name: &str,
    account_label: &str,
    req: f64,
    tin: f64,
    tout: f64,
    hits: f64,
) -> ProviderStatus {
    let req_per_min = req * 60.0;
    let tok_per_min = (tin + tout) * 60.0;
    let cache_per_min = hits * 60.0;

    let mut windows = vec![
        QuotaWindow {
            label: "Yêu cầu/phút".into(),
            used_pct: 0,
            remaining_pct: 100,
            subtitle: Some(format!("{} req/phút", dec(req_per_min))),
            resets_at: None,
        },
        QuotaWindow {
            label: "Tokens/phút".into(),
            used_pct: 0,
            remaining_pct: 100,
            subtitle: Some(format!("{} tok/phút", dec(tok_per_min))),
            resets_at: None,
        },
    ];
    if cache_per_min > 0.0 {
        windows.push(QuotaWindow {
            label: "Cache hit/phút".into(),
            used_pct: 0,
            remaining_pct: 100,
            subtitle: Some(format!("{} cache/phút", dec(cache_per_min))),
            resets_at: None,
        });
    }

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
    fn parses_prometheus_scalar_result() {
        let body = json!({"status": "success", "data": {"result": [{"value": [1700000000, "1.5"]}]}});
        assert!((parse_scalar(&body) - 1.5).abs() < 0.0001);
    }

    #[test]
    fn non_success_status_returns_zero() {
        assert_eq!(parse_scalar(&json!({"status": "error"})), 0.0);
        assert_eq!(parse_scalar(&json!({})), 0.0);
    }

    #[test]
    fn build_status_adds_cache_window_only_when_positive() {
        let s = build_status("groq", "Groq", "gsk-1234", 0.1, 0.5, 0.5, 0.0);
        assert_eq!(s.windows.len(), 2);
        let s2 = build_status("groq", "Groq", "gsk-1234", 0.1, 0.5, 0.5, 0.2);
        assert_eq!(s2.windows.len(), 3);
        assert_eq!(s2.windows[2].subtitle.as_deref(), Some("12.0 cache/phút"));
    }
}
