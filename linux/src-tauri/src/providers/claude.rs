//! Claude (Anthropic) quota provider — port of `ClaudeUsageOrchestrator.swift`.
//! `cfg.source` selects the data source (mirrors macOS `ClaudeUsageDataSource`
//! / `UserDefaults` key `claudeUsageDataSource`), default `"oauth"`:
//!   - `"oauth"` (default) — `ClaudeOAuth.swift` port: `~/.claude/.credentials.json`
//!     (or env token), refreshed against `platform.claude.com`, usage from
//!     `api.anthropic.com/api/oauth/usage`.
//!   - `"web"` — `ClaudeWebAPIFetcher.swift` port (portable subset): browser
//!     `sessionKey` cookie for claude.ai, `/api/organizations` +
//!     `/api/organizations/{id}/usage`. Account-info/overage-spend-limit
//!     enrichment calls are intentionally not ported (best-effort extras,
//!     out of scope per YAGNI).
//!   - `"api"` — Admin API org snapshot (`claude_admin.rs`), mapped onto the
//!     30-day cost total as a single window.
//!   - `"cli"` — no PTY/CLI-session equivalent on Linux; always fails with a
//!     explanatory message.
//!   - `"auto"` — try oauth, then fall back to web.
//!
//! The macOS-Keychain fallback is dropped — Linux has no Keychain.

use serde_json::Value;

use crate::config;
use crate::providers::{browser_cookies, claude_admin, display_name, ProviderStatus, QuotaWindow};

const REFRESH_URL: &str = "https://platform.claude.com/v1/oauth/token";
const USAGE_URL: &str = "https://api.anthropic.com/api/oauth/usage";
const DEFAULT_CLIENT_ID: &str = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
const OAUTH_BETA_HEADER: &str = "oauth-2025-04-20";

#[derive(Clone, Debug, PartialEq)]
struct Credentials {
    access_token: String,
    refresh_token: Option<String>,
    /// Unix seconds; None means "treat as non-expiring" (env-supplied tokens).
    expires_at: Option<i64>,
    subscription_type: Option<String>,
}

impl Credentials {
    fn is_expired(&self, now: i64) -> bool {
        match self.expires_at {
            Some(t) => now >= t,
            None => false,
        }
    }
}

/// Pure parse of the `claudeAiOauth` JSON blob (shared by env/file/keychain
/// sources on macOS; here only the file source is used). `expiresAt` arrives
/// in epoch milliseconds.
fn parse_oauth_credentials(contents: &str) -> Option<Credentials> {
    if contents.trim().is_empty() {
        return None;
    }
    let root: Value = serde_json::from_str(contents).ok()?;
    let oauth = root.get("claudeAiOauth")?;
    let token = oauth.get("accessToken").and_then(Value::as_str)?.trim();
    if token.is_empty() {
        return None;
    }
    let expires_at = oauth.get("expiresAt").and_then(Value::as_f64).map(|ms| (ms / 1000.0) as i64);
    let refresh_token = oauth.get("refreshToken").and_then(Value::as_str).map(String::from);
    let subscription_type = oauth.get("subscriptionType").and_then(Value::as_str).map(String::from);
    Some(Credentials { access_token: token.to_string(), refresh_token, expires_at, subscription_type })
}

fn load_from_env() -> Option<Credentials> {
    for key in ["CLAUDE_CODE_OAUTH_TOKEN", "BIRDNION_CLAUDE_OAUTH_TOKEN", "CODEXBAR_CLAUDE_OAUTH_TOKEN"] {
        if let Ok(v) = std::env::var(key) {
            let trimmed = v.trim();
            if !trimmed.is_empty() {
                return Some(Credentials {
                    access_token: trimmed.to_string(),
                    refresh_token: None,
                    expires_at: None,
                    subscription_type: None,
                });
            }
        }
    }
    None
}

fn credentials_file_path() -> std::path::PathBuf {
    let home = std::env::var("HOME").unwrap_or_default();
    std::path::PathBuf::from(home).join(".claude/.credentials.json")
}

fn load_from_file() -> Option<Credentials> {
    let contents = std::fs::read_to_string(credentials_file_path()).ok()?;
    parse_oauth_credentials(&contents)
}

fn load_credentials() -> Option<Credentials> {
    load_from_env().or_else(load_from_file)
}

fn client_id() -> String {
    for key in ["BIRDNION_CLAUDE_OAUTH_CLIENT_ID", "CODEXBAR_CLAUDE_OAUTH_CLIENT_ID"] {
        if let Ok(v) = std::env::var(key) {
            let trimmed = v.trim();
            if !trimmed.is_empty() {
                return trimmed.to_string();
            }
        }
    }
    DEFAULT_CLIENT_ID.to_string()
}

async fn refresh(refresh_token: &str) -> Result<(String, Option<String>, i64), String> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| format!("client: {e}"))?;
    let form = [
        ("grant_type", "refresh_token"),
        ("refresh_token", refresh_token),
        ("client_id", &client_id()),
    ];
    let resp = client
        .post(REFRESH_URL)
        .header("Accept", "application/json")
        .form(&form)
        .send()
        .await
        .map_err(|e| format!("Network: {e}"))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(format!(
            "Claude OAuth refresh HTTP {status} — chạy `claude` để đăng nhập lại."
        ));
    }
    let json: Value = resp.json().await.map_err(|_| "Claude OAuth refresh: phản hồi không hợp lệ.".to_string())?;
    let access_token = json.get("access_token").and_then(Value::as_str).unwrap_or_default().to_string();
    if access_token.is_empty() {
        return Err("Claude OAuth refresh: phản hồi không hợp lệ.".to_string());
    }
    let new_refresh = json.get("refresh_token").and_then(Value::as_str).map(String::from);
    let expires_in = json.get("expires_in").and_then(Value::as_i64).unwrap_or(0);
    Ok((access_token, new_refresh, expires_in))
}

async fn load_with_auto_refresh() -> Option<Credentials> {
    let mut creds = load_credentials()?;
    let now = chrono::Utc::now().timestamp();
    let Some(refresh_token) = creds.refresh_token.clone().filter(|t| !t.is_empty()) else {
        return Some(creds);
    };
    if !creds.is_expired(now) {
        return Some(creds);
    }
    if let Ok((access_token, new_refresh, expires_in)) = refresh(&refresh_token).await {
        creds.access_token = access_token;
        creds.refresh_token = new_refresh.or(Some(refresh_token));
        creds.expires_at = Some(now + expires_in);
    }
    // Refresh failure: fall through with the (expired) credential so the
    // usage call surfaces a 401 → re-auth hint, matching Swift behavior.
    Some(creds)
}

async fn fetch_usage(access_token: &str) -> Result<Value, String> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(15))
        .build()
        .map_err(|e| format!("client: {e}"))?;
    let resp = client
        .get(USAGE_URL)
        .bearer_auth(access_token)
        .header("Accept", "application/json")
        .header("Content-Type", "application/json")
        .header("anthropic-beta", OAUTH_BETA_HEADER)
        .header("User-Agent", "claude-code/1.0.0")
        .send()
        .await
        .map_err(|e| format!("Network: {e}"))?;
    match resp.status().as_u16() {
        200..=299 => resp.json::<Value>().await.map_err(|e| format!("JSON: {e}")),
        401 | 403 => Err("Token Claude hết hạn — đăng nhập lại bằng Claude Code".to_string()),
        code => Err(format!("HTTP {code}")),
    }
}

pub async fn fetch(cfg: &config::Provider) -> ProviderStatus {
    let name = display_name(cfg);
    match cfg.source.as_deref().unwrap_or("oauth") {
        "web" => fetch_web(cfg, &name).await,
        "api" => fetch_admin_api(cfg, &name).await,
        "cli" => ProviderStatus::failure(&cfg.id, &name, "Nguồn CLI chưa được hỗ trợ trên Linux"),
        "auto" => {
            let status = fetch_oauth(cfg, &name).await;
            if status.error.is_some() {
                fetch_web(cfg, &name).await
            } else {
                status
            }
        }
        _ => fetch_oauth(cfg, &name).await,
    }
}

async fn fetch_oauth(cfg: &config::Provider, name: &str) -> ProviderStatus {
    let Some(creds) = load_with_auto_refresh().await else {
        return ProviderStatus::failure(&cfg.id, name, "Chưa đăng nhập Claude — đăng nhập bằng Claude Code");
    };
    if creds.access_token.is_empty() {
        return ProviderStatus::failure(&cfg.id, name, "Chưa đăng nhập Claude — đăng nhập bằng Claude Code");
    }
    let body = match fetch_usage(&creds.access_token).await {
        Ok(b) => b,
        Err(e) => return ProviderStatus::failure(&cfg.id, name, e),
    };
    build_status(&cfg.id, name, &body, creds.subscription_type.as_deref())
}

/// Admin API "source" — maps the 30-day org cost snapshot onto a single
/// spend window (there is no per-rate-limit data in the Admin API).
async fn fetch_admin_api(cfg: &config::Provider, name: &str) -> ProviderStatus {
    match claude_admin::fetch_snapshot(cfg).await {
        Some(snap) => ProviderStatus {
            id: cfg.id.clone(),
            display_name: name.to_string(),
            windows: vec![QuotaWindow {
                label: "Chi phí 30 ngày".into(),
                used_pct: 0,
                remaining_pct: 100,
                subtitle: Some(format!("${:.2}", snap.last30_days.cost_usd)),
                resets_at: None,
            }],
            last_updated: chrono::Utc::now().timestamp(),
            account_label: Some("Claude Admin API".to_string()),
            ..Default::default()
        },
        None => ProviderStatus::failure(
            cfg.id.as_str(),
            name,
            "Chưa cấu hình Admin API key hoặc không lấy được dữ liệu",
        ),
    }
}

const CLAUDE_AI_BASE: &str = "https://claude.ai/api";

/// "web" source — port of the portable subset of `ClaudeWebAPIFetcher.swift`:
/// organizations lookup + usage windows via a browser `sessionKey` cookie.
/// Account-info / overage-spend-limit enrichment is intentionally not ported.
async fn fetch_web(cfg: &config::Provider, name: &str) -> ProviderStatus {
    let cfg_clone = cfg.clone();
    let raw_header = match tauri::async_runtime::spawn_blocking(move || {
        browser_cookies::cookie_header(&["claude.ai"], &cfg_clone)
    })
    .await
    {
        Ok(Ok(h)) => h,
        Ok(Err(e)) => return ProviderStatus::failure(&cfg.id, name, e),
        Err(_) => return ProviderStatus::failure(&cfg.id, name, "Lỗi nội bộ khi đọc cookie"),
    };
    let Some(session_key) = session_key_from_header(&raw_header) else {
        return ProviderStatus::failure(&cfg.id, name, "Không tìm thấy session cookie claude.ai trong trình duyệt.");
    };

    let client = crate::providers::shared_client();
    let cookie = format!("sessionKey={session_key}");

    let orgs_body = match fetch_web_json(&client, &format!("{CLAUDE_AI_BASE}/organizations"), &cookie).await {
        Ok(b) => b,
        Err(e) => return ProviderStatus::failure(&cfg.id, name, e),
    };
    let Some(org_id) = pick_organization_id(&orgs_body) else {
        return ProviderStatus::failure(&cfg.id, name, "Không tìm thấy tổ chức Claude cho tài khoản này.");
    };

    let usage_body =
        match fetch_web_json(&client, &format!("{CLAUDE_AI_BASE}/organizations/{org_id}/usage"), &cookie).await {
            Ok(b) => b,
            Err(e) => return ProviderStatus::failure(&cfg.id, name, e),
        };

    build_status(&cfg.id, name, &usage_body, None)
}

async fn fetch_web_json(client: &reqwest::Client, url: &str, cookie: &str) -> Result<Value, String> {
    let resp = client
        .get(url)
        .header("Cookie", cookie)
        .header("Accept", "application/json")
        .send()
        .await
        .map_err(|e| format!("Network: {e}"))?;
    match resp.status().as_u16() {
        200..=299 => resp.json::<Value>().await.map_err(|e| format!("JSON: {e}")),
        401 | 403 => Err("Phiên đăng nhập hết hạn — vui lòng đăng nhập lại claude.ai.".to_string()),
        code => Err(format!("Claude API lỗi HTTP {code}.")),
    }
}

/// Pure: extracts a `sk-ant-`-prefixed `sessionKey` value from a raw
/// `Cookie:` header string (as returned by `browser_cookies::cookie_header`).
/// Mirrors `ClaudeWebCookieReader.findSessionKey`.
fn session_key_from_header(header: &str) -> Option<String> {
    header.split(';').find_map(|part| {
        let (raw_name, raw_value) = part.split_once('=')?;
        if raw_name.trim() != "sessionKey" {
            return None;
        }
        let value = raw_value.trim();
        value.starts_with("sk-ant-").then(|| value.to_string())
    })
}

/// Pure: picks the org with chat capability, else the first non-API-only
/// org, else the first org at all. Mirrors `parseOrganizationResponse`.
fn pick_organization_id(body: &Value) -> Option<String> {
    let orgs = body.as_array()?;
    let has_chat = |o: &&Value| {
        o.get("capabilities")
            .and_then(Value::as_array)
            .map(|caps| caps.iter().any(|c| c.as_str().map(|s| s.eq_ignore_ascii_case("chat")).unwrap_or(false)))
            .unwrap_or(false)
    };
    let is_api_only = |o: &&Value| {
        o.get("capabilities")
            .and_then(Value::as_array)
            .map(|caps| {
                !caps.is_empty()
                    && caps.iter().all(|c| c.as_str().map(|s| s.eq_ignore_ascii_case("api")).unwrap_or(false))
            })
            .unwrap_or(false)
    };
    let selected = orgs.iter().find(has_chat).or_else(|| orgs.iter().find(|o| !is_api_only(o))).or_else(|| orgs.first());
    selected?.get("uuid").and_then(Value::as_str).map(String::from)
}

struct RateWindow {
    used_pct: f64,
    resets_at: Option<i64>,
}

fn parse_iso8601(s: Option<&str>) -> Option<i64> {
    let s = s?;
    if s.is_empty() {
        return None;
    }
    chrono::DateTime::parse_from_rfc3339(s).ok().map(|d| d.timestamp())
}

fn parse_window(v: Option<&Value>) -> Option<RateWindow> {
    let v = v?;
    let used_pct = v.get("utilization").and_then(Value::as_f64)?;
    let resets_at = parse_iso8601(v.get("resets_at").and_then(Value::as_str));
    Some(RateWindow { used_pct, resets_at })
}

fn to_quota_window(w: RateWindow, label: &str) -> QuotaWindow {
    let used = w.used_pct.round().clamp(0.0, 100.0) as i32;
    QuotaWindow { label: label.to_string(), used_pct: used, remaining_pct: 100 - used, subtitle: None, resets_at: w.resets_at }
}

/// Pure OAuth usage payload → windows mapping (unit-tested). Mirrors
/// `ClaudeOAuthUsageAPI.mapOAuthUsage`: primary window from five_hour (or the
/// seven_day fallbacks), secondary from seven_day, plus Opus/Sonnet/Routines
/// as named extra windows. Falls back to an `extra_usage` spend-limit window
/// when no rate-limit window is present at all.
fn build_status(id: &str, name: &str, body: &Value, subscription_type: Option<&str>) -> ProviderStatus {
    let five_hour = parse_window(body.get("five_hour"));
    let seven_day = parse_window(body.get("seven_day"));
    let seven_day_oauth_apps = parse_window(body.get("seven_day_oauth_apps"));
    let seven_day_opus = parse_window(body.get("seven_day_opus"));
    let seven_day_sonnet = parse_window(body.get("seven_day_sonnet"));

    let mut windows = Vec::new();
    let primary = five_hour.or(seven_day_oauth_apps).or_else(|| parse_window(body.get("seven_day")));
    let has_primary = primary.is_some();

    if let Some(w) = primary {
        windows.push(to_quota_window(w, "5 giờ"));
    }
    if let Some(w) = seven_day {
        windows.push(to_quota_window(w, "Tuần"));
    }
    if let Some(w) = seven_day_opus {
        windows.push(to_quota_window(w, "Opus"));
    }
    if let Some(w) = seven_day_sonnet {
        windows.push(to_quota_window(w, "Sonnet"));
    }
    if let Some(w) = parse_window(body.get("seven_day_routines")) {
        windows.push(to_quota_window(w, "Daily Routines"));
    }

    let mut credits_remaining = None;
    if !has_primary {
        if let Some(spend) = spend_limit_window(body.get("extra_usage")) {
            credits_remaining = spend.1;
            windows.insert(0, spend.0);
        }
    }

    let account_label = plan_label(subscription_type);
    ProviderStatus {
        id: id.to_string(),
        display_name: name.to_string(),
        windows,
        last_updated: chrono::Utc::now().timestamp(),
        account_label: Some(account_label),
        credits_remaining,
        ..Default::default()
    }
}

/// `extra_usage` spend-limit fallback (cents → dollars) shown as the primary
/// bar when no rate-limit window is present. Returns the window plus the
/// remaining-dollars figure (for `credits_remaining`).
fn spend_limit_window(extra: Option<&Value>) -> Option<(QuotaWindow, Option<f64>)> {
    let extra = extra?;
    if extra.get("is_enabled").and_then(Value::as_bool) != Some(true) {
        return None;
    }
    let used_cents = extra.get("used_credits").and_then(Value::as_f64)?;
    let limit_cents = extra.get("monthly_limit").and_then(Value::as_f64)?;
    if limit_cents <= 0.0 {
        return None;
    }
    let used = used_cents / 100.0;
    let limit = limit_cents / 100.0;
    let pct = extra.get("utilization").and_then(Value::as_f64).unwrap_or((used / limit) * 100.0).clamp(0.0, 100.0);
    let remaining = (limit - used).max(0.0);
    Some((
        QuotaWindow {
            label: "Spend limit".into(),
            used_pct: pct.round() as i32,
            remaining_pct: 100 - pct.round() as i32,
            subtitle: Some(format!("${used:.2} / ${limit:.2}")),
            resets_at: None,
        },
        Some(remaining),
    ))
}

fn plan_label(subscription_type: Option<&str>) -> String {
    let sub = subscription_type.unwrap_or("").to_lowercase();
    let plan = if sub.contains("max") {
        Some("Max")
    } else if sub.contains("ultra") {
        Some("Ultra")
    } else if sub.contains("pro") {
        Some("Pro")
    } else if sub.contains("team") {
        Some("Team")
    } else if sub.contains("enterprise") {
        Some("Enterprise")
    } else {
        None
    };
    match plan {
        Some(p) => format!("Claude {p}"),
        None => "Claude account".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parses_oauth_credentials_blob() {
        let raw = r#"{"claudeAiOauth":{"accessToken":"at","refreshToken":"rt","expiresAt":1000000,"subscriptionType":"max"}}"#;
        let creds = parse_oauth_credentials(raw).unwrap();
        assert_eq!(creds.access_token, "at");
        assert_eq!(creds.expires_at, Some(1000));
        assert_eq!(creds.subscription_type.as_deref(), Some("max"));
    }

    #[test]
    fn empty_access_token_is_none() {
        let raw = r#"{"claudeAiOauth":{"accessToken":"","refreshToken":"rt"}}"#;
        assert!(parse_oauth_credentials(raw).is_none());
    }

    #[test]
    fn malformed_json_is_none() {
        assert!(parse_oauth_credentials("not json").is_none());
        assert!(parse_oauth_credentials("").is_none());
        assert!(parse_oauth_credentials(r#"{"other":{}}"#).is_none());
    }

    #[test]
    fn is_expired_checks_epoch() {
        let creds = Credentials { access_token: "a".into(), refresh_token: None, expires_at: Some(1000), subscription_type: None };
        assert!(creds.is_expired(1000));
        assert!(!creds.is_expired(999));
        let never = Credentials { access_token: "a".into(), refresh_token: None, expires_at: None, subscription_type: None };
        assert!(!never.is_expired(999_999_999));
    }

    #[test]
    fn builds_primary_and_secondary_windows() {
        let body = json!({
            "five_hour": {"utilization": 42.0, "resets_at": "2026-01-01T00:00:00Z"},
            "seven_day": {"utilization": 10.0, "resets_at": "2026-01-08T00:00:00Z"},
        });
        let s = build_status("claude", "Claude", &body, Some("max"));
        assert_eq!(s.windows.len(), 2);
        assert_eq!(s.windows[0].label, "5 giờ");
        assert_eq!(s.windows[0].used_pct, 42);
        assert_eq!(s.windows[1].label, "Tuần");
        assert_eq!(s.account_label.as_deref(), Some("Claude Max"));
    }

    #[test]
    fn falls_back_to_spend_limit_when_no_usage_windows() {
        let body = json!({
            "extra_usage": {"is_enabled": true, "used_credits": 500.0, "monthly_limit": 2000.0, "utilization": 25.0}
        });
        let s = build_status("claude", "Claude", &body, None);
        assert_eq!(s.windows.len(), 1);
        assert_eq!(s.windows[0].label, "Spend limit");
        assert_eq!(s.windows[0].used_pct, 25);
        assert!((s.credits_remaining.unwrap() - 15.0).abs() < 0.001);
    }

    #[test]
    fn opus_and_sonnet_surfaced_as_named_windows() {
        let body = json!({
            "five_hour": {"utilization": 1.0, "resets_at": null},
            "seven_day_opus": {"utilization": 5.0, "resets_at": null},
            "seven_day_sonnet": {"utilization": 6.0, "resets_at": null},
        });
        let s = build_status("claude", "Claude", &body, None);
        assert_eq!(s.windows.len(), 3);
        assert_eq!(s.windows[1].label, "Opus");
        assert_eq!(s.windows[2].label, "Sonnet");
    }

    #[test]
    fn empty_payload_yields_no_windows() {
        let s = build_status("claude", "Claude", &json!({}), None);
        assert!(s.windows.is_empty());
        assert_eq!(s.account_label.as_deref(), Some("Claude account"));
    }

    #[test]
    fn session_key_from_header_requires_sk_ant_prefix() {
        let header = "other=1; sessionKey=sk-ant-abc123; foo=bar";
        assert_eq!(session_key_from_header(header), Some("sk-ant-abc123".to_string()));
        assert_eq!(session_key_from_header("sessionKey=not-a-real-key"), None);
        assert_eq!(session_key_from_header("unrelated=xyz"), None);
    }

    #[test]
    fn pick_organization_id_prefers_chat_capability() {
        let body = json!([
            {"uuid": "org-api", "capabilities": ["api"]},
            {"uuid": "org-chat", "capabilities": ["chat", "api"]}
        ]);
        assert_eq!(pick_organization_id(&body), Some("org-chat".to_string()));
    }

    #[test]
    fn pick_organization_id_falls_back_to_first_non_api_only_then_first() {
        let no_chat = json!([{"uuid": "org-api", "capabilities": ["api"]}, {"uuid": "org-plain"}]);
        assert_eq!(pick_organization_id(&no_chat), Some("org-plain".to_string()));

        let all_api_only = json!([{"uuid": "org-api", "capabilities": ["api"]}]);
        assert_eq!(pick_organization_id(&all_api_only), Some("org-api".to_string()));

        assert_eq!(pick_organization_id(&json!([])), None);
        assert_eq!(pick_organization_id(&json!({})), None);
    }
}
