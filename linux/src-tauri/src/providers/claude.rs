//! Claude (Anthropic) quota provider — port of `ClaudeUsageOrchestrator.swift`.
//! `cfg.source` selects the data source (mirrors macOS `ClaudeUsageDataSource`
//! / `UserDefaults` key `claudeUsageDataSource`), default `"auto"`:
//!   - `"oauth"` — `ClaudeOAuth.swift` port: platform Claude config roots
//!     (or env token), refreshed against `platform.claude.com`, usage from
//!     `api.anthropic.com/api/oauth/usage`.
//!   - `"web"` — `ClaudeWebAPIFetcher.swift` port (portable subset): browser
//!     `sessionKey` cookie for claude.ai, `/api/organizations` +
//!     `/api/organizations/{id}/usage` plus best-effort prepaid credits enrichment.
//!   - `"api"` — Admin API org snapshot (`claude_admin.rs`), mapped onto the
//!     30-day cost total as a single window.
//!   - `"cli"` — no PTY/CLI-session equivalent on Linux; always fails with a
//!     explanatory message.
//!   - `"auto"` (default) — try oauth, then fall back to web. Matches the
//!     macOS default so one shared `settings.json` behaves the same on both
//!     platforms; a pinned mode has no fallback when its single step fails.
//!
//! The macOS-Keychain fallback is dropped — Linux has no Keychain.

use serde_json::Value;

use crate::config;
use crate::providers::{
    browser_cookies, claude_admin, cli_version_blocking, display_name, fetch_service_status,
    ProviderStatus, QuotaWindow,
};

const REFRESH_URL: &str = "https://platform.claude.com/v1/oauth/token";
const USAGE_URL: &str = "https://api.anthropic.com/api/oauth/usage";
const DEFAULT_CLIENT_ID: &str = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
const OAUTH_BETA_HEADER: &str = "oauth-2025-04-20";
/// statuspage probe — macOS `ClaudeProvider.fetchServiceStatus` parity.
const STATUS_URL: &str = "https://status.anthropic.com/api/v2/summary.json";

static CLI_VERSION: std::sync::OnceLock<Option<String>> = std::sync::OnceLock::new();

#[derive(Clone, Debug, PartialEq)]
struct Credentials {
    access_token: String,
    refresh_token: Option<String>,
    /// Unix seconds; None means "treat as non-expiring" (env-supplied tokens).
    expires_at: Option<i64>,
    subscription_type: Option<String>,
    rate_limit_tier: Option<String>,
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
    let rate_limit_tier = oauth.get("rateLimitTier").and_then(Value::as_str).map(String::from);
    Some(Credentials { access_token: token.to_string(), refresh_token, expires_at, subscription_type, rate_limit_tier })
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
                    rate_limit_tier: None,
                });
            }
        }
    }
    None
}

fn load_from_file() -> Option<Credentials> {
    crate::platform::paths::claude_config_dirs()
        .into_iter()
        .find_map(|directory| {
            let contents = std::fs::read_to_string(directory.join(".credentials.json")).ok()?;
            parse_oauth_credentials(&contents)
        })
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
        .map_err(|_| "Không tạo được HTTP client Claude".to_string())?;
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
        .map_err(|_| "Không kết nối được Claude".to_string())?;
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
        .map_err(|_| "Không tạo được HTTP client Claude".to_string())?;
    let resp = client
        .get(USAGE_URL)
        .bearer_auth(access_token)
        .header("Accept", "application/json")
        .header("Content-Type", "application/json")
        .header("anthropic-beta", OAUTH_BETA_HEADER)
        .header("User-Agent", "claude-code/1.0.0")
        .send()
        .await
        .map_err(|_| "Không kết nối được Claude".to_string())?;
    match resp.status().as_u16() {
        200..=299 => resp
            .json::<Value>()
            .await
            .map_err(|_| "Phản hồi Claude không hợp lệ".to_string()),
        401 | 403 => Err("Token Claude hết hạn — đăng nhập lại bằng Claude Code".to_string()),
        code => Err(format!("HTTP {code}")),
    }
}

/// Data source for `cfg`, defaulting to `"auto"`. Split out of `fetch` so the
/// default is testable without touching the network.
fn resolved_source(cfg: &config::Provider) -> &str {
    cfg.source.as_deref().unwrap_or("auto")
}

pub async fn fetch(cfg: &config::Provider) -> ProviderStatus {
    let name = display_name(cfg);
    match resolved_source(cfg) {
        "web" => fetch_web(cfg, &name).await,
        "api" => fetch_admin_api(cfg, &name).await,
        "cli" => ProviderStatus::failure(&cfg.id, &name, "Nguồn CLI chưa được hỗ trợ trong bản này"),
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
    // Side-channel info alongside usage (macOS parity): CLI version
    // (memoized) + statuspage probe — both best-effort, never fail the fetch.
    let (body, version, service) = futures::join!(
        fetch_usage(&creds.access_token),
        tauri::async_runtime::spawn_blocking(|| cli_version_blocking(&CLI_VERSION, "claude")),
        fetch_service_status(STATUS_URL),
    );
    let body = match body {
        Ok(b) => b,
        Err(e) => return ProviderStatus::failure(&cfg.id, name, e),
    };
    let mut status = build_status(
        &cfg.id,
        name,
        &body,
        creds.subscription_type.as_deref(),
        creds.rate_limit_tier.as_deref(),
    );
    status.account_label = cfg.account_label.clone();
    status.version = version.unwrap_or(None);
    status.service_status = service.as_ref().map(|(d, _)| d.clone());
    status.service_status_level = service.map(|(_, i)| i);
    status.source_label = Some("OAuth".to_string());
    status.menu_bar_metric = cfg.menu_bar_metric.clone();
    status
}

/// Admin API "source" — maps the 30-day org cost snapshot onto a single
/// spend window (there is no per-rate-limit data in the Admin API).
async fn fetch_admin_api(cfg: &config::Provider, name: &str) -> ProviderStatus {
    match claude_admin::fetch_snapshot(cfg).await {
        Some(snap) => ProviderStatus {
            id: cfg.id.clone(),
            display_name: name.to_string(),
            windows: vec![QuotaWindow { semantic_key: None, semantic_kind: None,
                label: "Chi phí 30 ngày".into(),
                used_pct: 0,
                remaining_pct: 100,
                subtitle: Some(format!("${:.2}", snap.last30_days.cost_usd)),
                resets_at: None,
                window_seconds: None,
            }],
            last_updated: chrono::Utc::now().timestamp(),
            account_label: Some("Claude Admin API".to_string()),
            source_label: Some("Admin API".to_string()),
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

    let usage_url = format!("{CLAUDE_AI_BASE}/organizations/{org_id}/usage");
    let prepaid_url = format!("{CLAUDE_AI_BASE}/organizations/{org_id}/prepaid/credits");
    let prepaid_request = async {
        tokio::time::timeout(
            std::time::Duration::from_secs(2),
            fetch_web_json(&client, &prepaid_url, &cookie),
        )
        .await
        .ok()
        .and_then(Result::ok)
    };
    let (usage_result, prepaid_body) = futures::join!(
        fetch_web_json(&client, &usage_url, &cookie),
        prepaid_request,
    );
    let usage_body = match usage_result {
        Ok(b) => b,
        Err(e) => return ProviderStatus::failure(&cfg.id, name, e),
    };
    let prepaid = prepaid_body.and_then(|body| parse_prepaid_balance(&body));

    let mut status = build_status(&cfg.id, name, &usage_body, None, None);
    if let Some(balance) = prepaid {
        status.credits_remaining = Some(balance.amount);
    }
    status.account_label = cfg.account_label.clone();
    status.source_label = Some("Web".to_string());
    status
}

async fn fetch_web_json(client: &reqwest::Client, url: &str, cookie: &str) -> Result<Value, String> {
    let resp = client
        .get(url)
        .header("Cookie", cookie)
        .header("Accept", "application/json")
        .send()
        .await
        .map_err(|_| "Không kết nối được Claude Web".to_string())?;
    match resp.status().as_u16() {
        200..=299 => resp
            .json::<Value>()
            .await
            .map_err(|_| "Phản hồi Claude Web không hợp lệ".to_string()),
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

#[derive(Clone, Debug, PartialEq)]
struct PrepaidBalance {
    amount: f64,
    currency: String,
}

fn parse_prepaid_balance(body: &Value) -> Option<PrepaidBalance> {
    let amount = body.get("amount").and_then(Value::as_f64)?;
    if !amount.is_finite() || amount < 0.0 {
        return None;
    }
    let currency = body.get("currency").and_then(Value::as_str)?.trim().to_uppercase();
    if currency.is_empty() {
        return None;
    }
    Some(PrepaidBalance { amount: amount / 100.0, currency })
}

/// 2026 schema: some accounts no longer return a flat `seven_day` — weekly
/// limits live only in the `limits` array (`kind: "weekly_scoped"`,
/// `group: "weekly"`, `scope.model`). Returns the account-wide ("All models"
/// / unscoped) entry as the main weekly fallback. Model-scoped entries are
/// deliberately NOT surfaced as bars — same call as the macOS popover
/// ("Fable only" bars were rejected as noise). `is_active` is intentionally
/// not a filter: observed enforceable scoped limits report false.
fn all_models_weekly_limit(body: &Value) -> Option<RateWindow> {
    let limits = body.get("limits").and_then(Value::as_array)?;
    for entry in limits {
        if entry.get("group").and_then(Value::as_str) != Some("weekly")
            || entry.get("kind").and_then(Value::as_str) != Some("weekly_scoped")
        {
            continue;
        }
        let Some(percent) = entry.get("percent").and_then(Value::as_f64) else { continue };
        if !percent.is_finite() {
            continue;
        }
        let model = entry.get("scope").and_then(|s| s.get("model"));
        let model_name = model
            .and_then(|m| m.get("display_name"))
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty());
        let model_id = model
            .and_then(|m| m.get("id"))
            .and_then(Value::as_str)
            .unwrap_or("");
        let is_all_models = model_name.is_none()
            || model_name == Some("All models")
            || model_id == "all-models"
            || model_id.ends_with("-all-models");
        if is_all_models {
            return Some(RateWindow {
                used_pct: percent,
                resets_at: parse_iso8601(entry.get("resets_at").and_then(Value::as_str)),
            });
        }
    }
    None
}

const FIVE_HOURS_SECS: i64 = 5 * 3600;
const SEVEN_DAYS_SECS: i64 = 7 * 24 * 3600;

fn to_quota_window(w: RateWindow, label: &str, window_seconds: Option<i64>) -> QuotaWindow {
    let used = w.used_pct.round().clamp(0.0, 100.0) as i32;
    QuotaWindow { semantic_key: None, semantic_kind: None,
        label: label.to_string(),
        used_pct: used,
        remaining_pct: 100 - used,
        subtitle: None,
        resets_at: w.resets_at,
        window_seconds,
    }
}

/// Pure OAuth usage payload → windows mapping (unit-tested). Mirrors
/// `ClaudeOAuthUsageAPI.mapOAuthUsage`: primary window from five_hour (or the
/// seven_day fallbacks), secondary from seven_day, plus Opus/Sonnet/Routines
/// as named extra windows. Falls back to an `extra_usage` spend-limit window
/// when no rate-limit window is present at all.
fn build_status(
    id: &str,
    name: &str,
    body: &Value,
    subscription_type: Option<&str>,
    rate_limit_tier: Option<&str>,
) -> ProviderStatus {
    let five_hour = parse_window(body.get("five_hour"));
    let seven_day = parse_window(body.get("seven_day"));
    let seven_day_oauth_apps = parse_window(body.get("seven_day_oauth_apps"));
    let seven_day_opus = parse_window(body.get("seven_day_opus"));
    let seven_day_sonnet = parse_window(body.get("seven_day_sonnet"));

    let mut windows = Vec::new();
    let primary = five_hour.or(seven_day_oauth_apps).or_else(|| parse_window(body.get("seven_day")));
    let has_primary = primary.is_some();

    if let Some(w) = primary {
        windows.push(to_quota_window(w, "5 giờ", Some(FIVE_HOURS_SECS)));
    }
    // Weekly limits moved into the `limits` array on some accounts (2026
    // schema): the account-wide entry backs the main weekly window when
    // seven_day is absent.
    if let Some(w) = seven_day.or_else(|| all_models_weekly_limit(body)) {
        windows.push(to_quota_window(w, "Tuần", Some(SEVEN_DAYS_SECS)));
    }
    if let Some(w) = seven_day_opus {
        windows.push(to_quota_window(w, "Opus", Some(SEVEN_DAYS_SECS)));
    }
    if let Some(w) = seven_day_sonnet {
        windows.push(to_quota_window(w, "Sonnet", Some(SEVEN_DAYS_SECS)));
    }
    if let Some(w) = parse_window(body.get("seven_day_routines")) {
        windows.push(to_quota_window(w, "Daily Routines", Some(SEVEN_DAYS_SECS)));
    }

    let mut credits_remaining = None;
    if !has_primary {
        if let Some(spend) = spend_limit_window(body.get("extra_usage")) {
            credits_remaining = spend.1;
            windows.insert(0, spend.0);
        }
    }

    // Plan rides in `plan_name` (settings "Tên gói" row + popover meta) —
    // bare label ("Max 5x", "Pro", "Team", …), matching macOS `ClaudePlanLabeler.label()`.
    // `account_label` stays free for the config override, macOS parity.
    ProviderStatus {
        id: id.to_string(),
        display_name: name.to_string(),
        windows,
        last_updated: chrono::Utc::now().timestamp(),
        plan_name: subscription_type
            .or(rate_limit_tier)
            .map(|_| plan_label(subscription_type, rate_limit_tier)),
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
        QuotaWindow { semantic_key: None, semantic_kind: None,
            label: "Spend limit".into(),
            used_pct: pct.round() as i32,
            remaining_pct: 100 - pct.round() as i32,
            subtitle: Some(format!("${used:.2} / ${limit:.2}")),
            resets_at: None,
            window_seconds: None,
        },
        Some(remaining),
    ))
}

fn max_usage_multiplier(rate_limit_tier: &str) -> Option<&'static str> {
    if rate_limit_tier.contains("default_claude_max_5x") {
        Some("Max 5x")
    } else if rate_limit_tier.contains("default_claude_max_20x") {
        Some("Max 20x")
    } else {
        None
    }
}

/// Bare plan label ("Max 5x", "Pro", "Team", …) — matches macOS
/// `ClaudePlanLabeler.label()`. Callers that need a "Claude "-prefixed
/// login-method/source label (e.g. the OAuth/web login row) should add the
/// prefix at the call site, mirroring `ClaudePlanLabeler.oauthLoginMethod()`.
fn plan_label(subscription_type: Option<&str>, rate_limit_tier: Option<&str>) -> String {
    let sub = subscription_type.unwrap_or("").to_lowercase();
    let tier = rate_limit_tier.unwrap_or("").to_lowercase();
    let plan = if sub.contains("max") {
        match max_usage_multiplier(&tier) {
            Some(multiplier) => Some(multiplier),
            None => Some("Max"),
        }
    } else if sub.contains("ultra") {
        Some("Ultra")
    } else if sub.contains("pro") {
        Some("Pro")
    } else if sub.contains("team") {
        Some("Team")
    } else if sub.contains("enterprise") {
        Some("Enterprise")
    } else if let Some(multiplier) = max_usage_multiplier(&tier) {
        Some(multiplier)
    } else if tier.contains("max") {
        Some("Max")
    } else if tier.contains("ultra") {
        Some("Ultra")
    } else {
        None
    };
    match plan {
        Some(p) => p.to_string(),
        None => "Claude account".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// Regression: this file resolved an unset source to "oauth" while
    /// `config.rs` documented the field as `"auto" (default)` and macOS
    /// defaults to auto. A pinned mode runs a single step with no fallback,
    /// so the mismatch silently removed Linux's oauth -> web recovery for
    /// every user who never touched the picker.
    #[test]
    fn unset_source_defaults_to_auto() {
        let cfg = config::Provider { id: "claude".to_string(), ..Default::default() };
        assert_eq!(resolved_source(&cfg), "auto");
    }

    #[test]
    fn explicit_source_is_respected() {
        for source in ["auto", "oauth", "web", "cli", "api"] {
            let cfg = config::Provider {
                id: "claude".to_string(),
                source: Some(source.to_string()),
                ..Default::default()
            };
            assert_eq!(resolved_source(&cfg), source);
        }
    }

    #[test]
    fn weekly_falls_back_to_all_models_limit() {
        // 2026 schema: no flat seven_day — the account-wide entry in `limits`
        // backs the main weekly window; model-scoped entries stay hidden.
        let body = json!({
            "five_hour": {"utilization": 12.0, "resets_at": "2026-07-26T18:00:00Z"},
            "limits": [
                {"kind": "weekly_scoped", "group": "weekly", "percent": 41.5,
                 "resets_at": "2026-07-30T00:00:00Z",
                 "scope": {"model": {"id": "all-models", "display_name": "All models"}}},
                {"kind": "weekly_scoped", "group": "weekly", "percent": 9.0,
                 "scope": {"model": {"id": "claude-sonnet-4-5", "display_name": "Sonnet"}}}
            ]
        });
        let status = build_status("claude", "Claude", &body, None, None);
        let labels: Vec<_> = status.windows.iter().map(|w| w.label.as_str()).collect();
        assert_eq!(labels, vec!["5 giờ", "Tuần"]);
        assert_eq!(status.windows[1].used_pct, 42); // 41.5 rounded
    }

    #[test]
    fn flat_seven_day_still_wins_over_limits() {
        let body = json!({
            "five_hour": {"utilization": 1.0},
            "seven_day": {"utilization": 55.0},
            "limits": [
                {"kind": "weekly_scoped", "group": "weekly", "percent": 41.5,
                 "scope": {"model": {"id": "all-models", "display_name": "All models"}}}
            ]
        });
        let status = build_status("claude", "Claude", &body, None, None);
        assert_eq!(status.windows[1].label, "Tuần");
        assert_eq!(status.windows[1].used_pct, 55);
    }

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
        let creds = Credentials { access_token: "a".into(), refresh_token: None, expires_at: Some(1000), subscription_type: None, rate_limit_tier: None };
        assert!(creds.is_expired(1000));
        assert!(!creds.is_expired(999));
        let never = Credentials { access_token: "a".into(), refresh_token: None, expires_at: None, subscription_type: None, rate_limit_tier: None };
        assert!(!never.is_expired(999_999_999));
    }

    #[test]
    fn builds_primary_and_secondary_windows() {
        let body = json!({
            "five_hour": {"utilization": 42.0, "resets_at": "2026-01-01T00:00:00Z"},
            "seven_day": {"utilization": 10.0, "resets_at": "2026-01-08T00:00:00Z"},
        });
        let s = build_status("claude", "Claude", &body, Some("max"), None);
        assert_eq!(s.windows.len(), 2);
        assert_eq!(s.windows[0].label, "5 giờ");
        assert_eq!(s.windows[0].used_pct, 42);
        assert_eq!(s.windows[1].label, "Tuần");
        assert_eq!(s.plan_name.as_deref(), Some("Max"));
        assert_eq!(s.windows[0].window_seconds, Some(FIVE_HOURS_SECS));
        assert_eq!(s.windows[1].window_seconds, Some(SEVEN_DAYS_SECS));
    }

    #[test]
    fn falls_back_to_spend_limit_when_no_usage_windows() {
        let body = json!({
            "extra_usage": {"is_enabled": true, "used_credits": 500.0, "monthly_limit": 2000.0, "utilization": 25.0}
        });
        let s = build_status("claude", "Claude", &body, None, None);
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
        let s = build_status("claude", "Claude", &body, None, None);
        assert_eq!(s.windows.len(), 3);
        assert_eq!(s.windows[1].label, "Opus");
        assert_eq!(s.windows[2].label, "Sonnet");
    }

    #[test]
    fn max_multiplier_labels_prefer_subscription_and_support_v2_tier() {
        // Bare plan labels — macOS parity. The "Claude " prefix is added by
        // callers (e.g. settings row) when a login-method/source label is
        // needed, not baked into `plan_name`.
        assert_eq!(plan_label(None, Some("default_claude_max_5x")), "Max 5x");
        assert_eq!(plan_label(None, Some("v2_default_claude_max_20x")), "Max 20x");
        assert_eq!(plan_label(Some("team"), Some("default_claude_max_5x")), "Team");
        assert_eq!(plan_label(Some("max"), None), "Max");
        assert_eq!(plan_label(Some("pro"), None), "Pro");
        assert_eq!(plan_label(None, None), "Claude account");
    }

    #[test]
    fn prepaid_balance_parses_minor_units() {
        let balance = parse_prepaid_balance(&json!({"amount": 12345.0, "currency": "usd"})).unwrap();
        assert!((balance.amount - 123.45).abs() < 0.001);
        assert_eq!(balance.currency, "USD");
    }

    #[test]
    fn prepaid_balance_failure_is_noop() {
        assert_eq!(parse_prepaid_balance(&json!({"amount": "bad", "currency": "USD"})), None);
        assert_eq!(parse_prepaid_balance(&json!({"amount": 100, "currency": ""})), None);
    }

    #[test]
    fn empty_payload_yields_no_windows() {
        let s = build_status("claude", "Claude", &json!({}), None, None);
        assert!(s.windows.is_empty());
        // No subscription type → no plan row (config label stays separate).
        assert!(s.plan_name.is_none());
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
