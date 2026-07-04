//! GitHub Copilot quota provider — port of `CopilotProvider.swift`.
//!
//! Token resolution: `~/.config/birdnion/copilot-accounts.json` (same file
//! macOS's Device Flow login writes; that flow is out of scope on Linux, so
//! this reads an existing file only) → `cfg.api_key` manual token fallback.
//!
//! Main endpoint: GET https://<apiHost>/copilot_internal/user.
//! Budget windows are a best-effort browser-cookie scrape of GitHub's
//! billing budgets page — failures there never fail the overall fetch.

use regex::Regex;
use serde::Deserialize;
use serde_json::Value;

use crate::providers::browser_cookies;
use crate::providers::{display_name, ProviderStatus, QuotaWindow};

const USER_AGENT: &str = "GitHubCopilotChat/0.26.7";

pub async fn fetch(cfg: &crate::config::Provider) -> ProviderStatus {
    let name = display_name(cfg);
    let id = cfg.id.clone();

    let account = load_active_account();
    let token = account
        .as_ref()
        .and_then(|a| if a.token.is_empty() { None } else { Some(a.token.clone()) })
        .or_else(|| crate::config::api_key(cfg));

    let Some(token) = token else {
        return ProviderStatus::failure(&id, &name, "Chưa đăng nhập Copilot");
    };

    let api_host = resolve_api_host(cfg);
    let client = crate::providers::shared_client();

    let account_label = if let Some(login) = account.as_ref().and_then(|a| a.login.clone()).filter(|l| !l.is_empty()) {
        login
    } else if let Some(manual) = cfg.account_label.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
        manual.to_string()
    } else if let Some(login) = fetch_github_username(&client, &api_host, &token).await {
        login
    } else {
        token.chars().take(8).collect()
    };

    let usage_url = format!("https://{api_host}/copilot_internal/user");
    let resp = client
        .get(&usage_url)
        .header("Authorization", format!("token {token}"))
        .header("Accept", "application/json")
        .header("Editor-Version", "vscode/1.96.2")
        .header("Editor-Plugin-Version", "copilot-chat/0.26.7")
        .header("User-Agent", USER_AGENT)
        .header("X-Github-Api-Version", "2025-04-01")
        .send()
        .await;

    let body = match resp {
        Ok(r) if r.status().is_success() => match r.text().await {
            Ok(t) => t,
            Err(e) => return ProviderStatus::failure(&id, &name, format!("Network: {e}")),
        },
        Ok(r) if r.status().as_u16() == 401 || r.status().as_u16() == 403 => {
            return ProviderStatus::failure(&id, &name, "GitHub token không hợp lệ / thiếu quyền Copilot")
        }
        Ok(r) => return ProviderStatus::failure(&id, &name, format!("HTTP {}", r.status().as_u16())),
        Err(e) => return ProviderStatus::failure(&id, &name, format!("Network: {e}")),
    };

    let mut base = match parse_status(&id, &name, &body, Some(account_label)) {
        Ok(status) => status,
        Err(e) => return ProviderStatus::failure(&id, &name, e),
    };

    if base.error.is_none() {
        let budget_windows = fetch_budget_windows_best_effort(cfg, &client).await;
        base.windows.extend(budget_windows);
    }

    base
}

struct CopilotAccount {
    login: Option<String>,
    token: String,
}

#[derive(Deserialize)]
struct AccountEntry {
    label: String,
    login: Option<String>,
    token: String,
}

#[derive(Deserialize)]
struct AccountStore {
    #[serde(rename = "activeLabel")]
    active_label: Option<String>,
    #[serde(default)]
    accounts: Vec<AccountEntry>,
}

fn copilot_accounts_path() -> Option<std::path::PathBuf> {
    let home = std::env::var("HOME").ok()?;
    Some(std::path::PathBuf::from(home).join(".config/birdnion/copilot-accounts.json"))
}

fn load_active_account() -> Option<CopilotAccount> {
    let path = copilot_accounts_path()?;
    let text = std::fs::read_to_string(path).ok()?;
    let store: AccountStore = serde_json::from_str(&text).ok()?;

    let active = store
        .active_label
        .as_ref()
        .and_then(|label| store.accounts.iter().find(|a| &a.label == label))
        .or_else(|| store.accounts.first())?;

    Some(CopilotAccount { login: active.login.clone(), token: active.token.clone() })
}

fn resolve_api_host(cfg: &crate::config::Provider) -> String {
    let config_host = cfg.base_url.as_deref().map(str::trim).filter(|s| !s.is_empty());
    let env_host = std::env::var("GH_HOST").ok().or_else(|| std::env::var("GITHUB_HOST").ok());
    let host = config_host.map(str::to_string).or(env_host);

    match host {
        Some(h) if !h.is_empty() && h != "github.com" => {
            if h.starts_with("api.") {
                h
            } else {
                format!("api.{h}")
            }
        }
        _ => "api.github.com".to_string(),
    }
}

async fn fetch_github_username(client: &reqwest::Client, api_host: &str, token: &str) -> Option<String> {
    let url = format!("https://{api_host}/user");
    let resp = client
        .get(&url)
        .header("Authorization", format!("token {token}"))
        .header("Accept", "application/json")
        .header("User-Agent", "BirdNion/1.0")
        .send()
        .await
        .ok()?;
    if !resp.status().is_success() {
        return None;
    }
    let v: Value = resp.json().await.ok()?;
    v.get("login").and_then(Value::as_str).map(str::to_string)
}

#[derive(Deserialize)]
struct Snap {
    entitlement: Option<f64>,
    remaining: Option<f64>,
    #[serde(rename = "percent_remaining")]
    percent_remaining: Option<f64>,
    unlimited: Option<bool>,
}

fn window(label: &str, snap: Option<&Snap>, reset: Option<i64>) -> Option<QuotaWindow> {
    let snap = snap?;
    if snap.unlimited == Some(true) {
        return None;
    }
    if snap.entitlement.unwrap_or(0.0) == 0.0 && snap.remaining.unwrap_or(0.0) == 0.0 {
        return None;
    }

    let percent_remaining = if let Some(p) = snap.percent_remaining {
        p
    } else if let (Some(e), Some(rem)) = (snap.entitlement, snap.remaining) {
        if e > 0.0 {
            rem / e * 100.0
        } else {
            return None;
        }
    } else {
        return None;
    };

    let used = (100.0 - percent_remaining).round().clamp(0.0, 100.0) as i32;
    Some(QuotaWindow { label: label.to_string(), used_pct: used, remaining_pct: 100 - used, subtitle: None, resets_at: reset })
}

fn parse_reset(value: Option<&str>) -> Option<i64> {
    let raw = value?.trim();
    if raw.is_empty() {
        return None;
    }
    if let Ok(dt) = chrono::DateTime::parse_from_rfc3339(raw) {
        return Some(dt.timestamp());
    }
    if let Ok(date) = chrono::NaiveDate::parse_from_str(raw, "%Y-%m-%d") {
        return Some(date.and_hms_opt(0, 0, 0)?.and_utc().timestamp());
    }
    None
}

fn capitalize_words(s: &str) -> String {
    s.replace('_', " ")
        .split(' ')
        .map(|word| {
            let mut chars = word.chars();
            match chars.next() {
                Some(c) => c.to_uppercase().collect::<String>() + &chars.as_str().to_lowercase(),
                None => String::new(),
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// Pure parser (fixture-tested). Budget windows are layered on by `fetch()`.
fn parse_status(id: &str, name: &str, body: &str, account_label: Option<String>) -> Result<ProviderStatus, String> {
    let v: Value = serde_json::from_str(body).map_err(|_| "Response thiếu trường".to_string())?;

    let reset = parse_reset(v.get("quota_reset_date").and_then(Value::as_str));
    let snapshots = v.get("quota_snapshots");
    let premium: Option<Snap> = snapshots.and_then(|s| s.get("premium_interactions")).and_then(|s| serde_json::from_value(s.clone()).ok());
    let chat: Option<Snap> = snapshots.and_then(|s| s.get("chat")).and_then(|s| serde_json::from_value(s.clone()).ok());

    let mut windows = Vec::new();
    if let Some(w) = window("Premium", premium.as_ref(), reset) {
        windows.push(w);
    }
    if let Some(w) = window("Chat", chat.as_ref(), reset) {
        windows.push(w);
    }

    let plan = v.get("copilot_plan").and_then(Value::as_str).map(capitalize_words);

    let error = if windows.is_empty() && plan.is_none() { Some("Copilot chưa có dữ liệu quota".to_string()) } else { None };

    Ok(ProviderStatus {
        id: id.to_string(),
        display_name: name.to_string(),
        windows,
        last_updated: chrono::Utc::now().timestamp(),
        error,
        account_label,
        credits_remaining: None,
    })
}

async fn fetch_budget_windows_best_effort(cfg: &crate::config::Provider, client: &reqwest::Client) -> Vec<QuotaWindow> {
    let cfg_clone = cfg.clone();
    let cookie_header = match tauri::async_runtime::spawn_blocking(move || browser_cookies::cookie_header(&["github.com"], &cfg_clone)).await {
        Ok(Ok(h)) if !h.trim().is_empty() => h,
        _ => return Vec::new(),
    };

    let nonce = fetch_budget_nonce_best_effort(client, &cookie_header).await;
    let budgets = match fetch_budget_page(client, &cookie_header, nonce.as_deref()).await {
        Ok(b) => b,
        Err(_) => return Vec::new(),
    };
    budget_windows(&budgets)
}

async fn fetch_budget_nonce_best_effort(client: &reqwest::Client, cookie_header: &str) -> Option<String> {
    let resp = client
        .get("https://github.com/settings/billing/budgets")
        .header("Cookie", cookie_header)
        .header("Accept", "text/html,application/xhtml+xml")
        .header("User-Agent", "BirdNion/1.0")
        .send()
        .await
        .ok()?;
    if !resp.status().is_success() {
        return None;
    }
    let html = resp.text().await.ok()?;
    extract_fetch_nonce(&html)
}

fn extract_fetch_nonce(html: &str) -> Option<String> {
    const PATTERNS: &[&str] = &[
        r#"x-fetch-nonce"\s+content="([^"]+)""#,
        r#"X-Fetch-Nonce"\s*:\s*"([^"]+)""#,
        r#"fetchNonce"\s*:\s*"([^"]+)""#,
        r#"data-fetch-nonce="([^"]+)""#,
    ];
    for pattern in PATTERNS {
        if let Ok(re) = Regex::new(&format!("(?i){pattern}")) {
            if let Some(cap) = re.captures(html) {
                if let Some(m) = cap.get(1) {
                    return Some(m.as_str().to_string());
                }
            }
        }
    }
    None
}

#[derive(Deserialize, Default)]
struct BudgetEntry {
    name: Option<String>,
    #[serde(rename = "budget_type")]
    budget_type: Option<String>,
    #[serde(rename = "budget_product_skus", default)]
    budget_product_skus: Vec<String>,
    #[serde(rename = "budget_entity_name")]
    budget_entity_name: Option<String>,
    #[serde(rename = "budget_amount", default)]
    budget_amount: f64,
    #[serde(rename = "current_usage", default)]
    current_amount: f64,
}

async fn fetch_budget_page(client: &reqwest::Client, cookie_header: &str, nonce: Option<&str>) -> Result<Vec<BudgetEntry>, String> {
    let mut req = client
        .get("https://github.com/settings/billing/budgets")
        .query(&[("page", "1"), ("page_size", "10"), ("scope", "customer")])
        .header("Cookie", cookie_header)
        .header("Accept", "application/json")
        .header("Referer", "https://github.com/settings/billing/budgets")
        .header("X-Requested-With", "XMLHttpRequest")
        .header("GitHub-Verified-Fetch", "true")
        .header("User-Agent", "BirdNion/1.0");
    if let Some(n) = nonce.filter(|n| !n.is_empty()) {
        req = req.header("X-Fetch-Nonce", n);
    }

    let resp = req.send().await.map_err(|e| e.to_string())?;
    if !resp.status().is_success() {
        return Ok(Vec::new());
    }
    let v: Value = resp.json().await.map_err(|e| e.to_string())?;
    Ok(parse_budget_page(&v))
}

/// GitHub may wrap the budgets array in a `payload` envelope or return it directly.
fn parse_budget_page(v: &Value) -> Vec<BudgetEntry> {
    if let Some(payload) = v.get("payload") {
        return parse_budget_page(payload);
    }
    v.get("budgets")
        .and_then(Value::as_array)
        .map(|arr| arr.iter().filter_map(|e| serde_json::from_value(e.clone()).ok()).collect())
        .unwrap_or_default()
}

const COPILOT_KEYWORDS: &[&str] = &["copilot", "premium_request", "spark"];

fn budget_windows(budgets: &[BudgetEntry]) -> Vec<QuotaWindow> {
    budgets
        .iter()
        .filter_map(|b| {
            if b.budget_amount <= 0.0 {
                return None;
            }
            let mut identifiers: Vec<String> = [b.name.as_deref(), b.budget_type.as_deref(), b.budget_entity_name.as_deref()]
                .into_iter()
                .flatten()
                .map(|s| s.to_lowercase().replace('-', "_"))
                .collect();
            identifiers.extend(b.budget_product_skus.iter().map(|s| s.to_lowercase().replace('-', "_")));

            let is_copilot = identifiers.iter().any(|id| COPILOT_KEYWORDS.iter().any(|kw| id.contains(kw)));
            if !is_copilot {
                return None;
            }

            let used_raw = b.current_amount / b.budget_amount * 100.0;
            let used = used_raw.round().clamp(0.0, 100.0) as i32;
            let label_name = b.name.clone().unwrap_or_else(|| "Copilot".to_string());
            Some(QuotaWindow {
                label: format!("Budget · {label_name}"),
                used_pct: used,
                remaining_pct: 100 - used,
                subtitle: Some(format!("${:.2} / ${:.2}", b.current_amount, b.budget_amount)),
                resets_at: None,
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_premium_and_chat_windows() {
        let body = r#"{"copilot_plan":"individual_pro","quota_reset_date":"2025-08-01","quota_snapshots":{"premium_interactions":{"entitlement":100.0,"remaining":40.0,"unlimited":false},"chat":{"entitlement":50.0,"remaining":50.0,"unlimited":false}}}"#;
        let status = parse_status("copilot", "Copilot", body, Some("octocat".to_string())).unwrap();
        assert_eq!(status.windows.len(), 2);
        assert_eq!(status.windows[0].label, "Premium");
        assert_eq!(status.windows[0].used_pct, 60);
        assert_eq!(status.account_label, Some("octocat".to_string()));
    }

    #[test]
    fn unlimited_snapshot_is_skipped() {
        let body = r#"{"quota_snapshots":{"premium_interactions":{"unlimited":true},"chat":{"entitlement":10.0,"remaining":5.0}}}"#;
        let status = parse_status("copilot", "Copilot", body, None).unwrap();
        assert_eq!(status.windows.len(), 1);
        assert_eq!(status.windows[0].label, "Chat");
    }

    #[test]
    fn zero_entitlement_and_remaining_is_placeholder_skipped() {
        let body = r#"{"quota_snapshots":{"premium_interactions":{"entitlement":0.0,"remaining":0.0}}}"#;
        let status = parse_status("copilot", "Copilot", body, None).unwrap();
        assert!(status.windows.is_empty());
        assert!(status.error.is_some());
    }

    #[test]
    fn plan_without_windows_still_succeeds() {
        let body = r#"{"copilot_plan":"individual"}"#;
        let status = parse_status("copilot", "Copilot", body, None).unwrap();
        assert!(status.error.is_none());
    }

    #[test]
    fn invalid_json_is_error() {
        assert!(parse_status("copilot", "Copilot", "not json", None).is_err());
    }

    #[test]
    fn budget_windows_filters_non_copilot_and_zero_amount() {
        let budgets = vec![
            BudgetEntry { name: Some("Copilot Premium".into()), budget_amount: 50.0, current_amount: 25.0, ..Default::default() },
            BudgetEntry { name: Some("Other Spend".into()), budget_amount: 100.0, current_amount: 10.0, ..Default::default() },
            BudgetEntry { name: Some("Zero Budget".into()), budget_amount: 0.0, current_amount: 0.0, budget_product_skus: vec!["copilot".into()], ..Default::default() },
        ];
        let windows = budget_windows(&budgets);
        assert_eq!(windows.len(), 1);
        assert!(windows[0].label.contains("Copilot Premium"));
        assert_eq!(windows[0].used_pct, 50);
    }

    #[test]
    fn extract_fetch_nonce_from_meta_tag() {
        let html = r#"<meta name="x-fetch-nonce" content="abc123">"#;
        assert_eq!(extract_fetch_nonce(html), Some("abc123".to_string()));
    }

    #[test]
    fn resolves_default_api_host() {
        let cfg = crate::config::Provider { id: "copilot".to_string(), ..Default::default() };
        assert_eq!(resolve_api_host(&cfg), "api.github.com");
    }

    #[test]
    fn resolves_enterprise_api_host_from_base_url() {
        let cfg = crate::config::Provider { id: "copilot".to_string(), base_url: Some("github.mycorp.com".to_string()), ..Default::default() };
        assert_eq!(resolve_api_host(&cfg), "api.github.mycorp.com");
    }
}
