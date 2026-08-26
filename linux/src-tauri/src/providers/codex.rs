//! Codex (OpenAI/ChatGPT) quota provider — port of `CodexProvider.swift` +
//! `CodexAuth.swift` (OAuth path only; the CLI/`codex app-server` RPC
//! fallback is macOS-only side data and is intentionally not ported).
//!
//! Reads OAuth tokens from `~/.codex/auth.json` (or `$CODEX_HOME/auth.json`),
//! refreshes proactively when stale (>8 days since last_refresh, matching
//! Codex CLI), persists the rotated token back to auth.json, and maps the
//! ChatGPT backend usage response's primary (~5h) / secondary (weekly)
//! windows plus any `additional_rate_limits` (e.g. GPT-5.3-Codex-Spark).
//!
//! Best-effort chatgpt.com web-dashboard enrichment (port of the JSON-API
//! part of `CodexWebDashboard.swift`/`OpenAIDashboardFetcher.fetchDashboardUsageAPI`):
//! hits the *same* `wham/usage` endpoint using a browser session cookie for
//! `chatgpt.com` instead of the OAuth bearer token. This covers the
//! `credits_remaining` + rate-limit windows the Swift dashboard preflight
//! gets over plain JSON. Note: Swift's "Code review remaining %" is parsed
//! from the *rendered* dashboard page body via a hidden WKWebView (regex over
//! DOM text, see `OpenAIDashboardParser.parseCodeReviewRemainingPercent`) —
//! there is no headless/JSON equivalent, so that field is intentionally not
//! ported here. Cookie-fallback failures never break the primary OAuth status.

use crate::codex_accounts;
use crate::config;
use crate::providers::browser_cookies;
use crate::providers::{
    cli_version_blocking, display_name, fetch_service_status, shared_client, ProviderStatus,
    QuotaWindow,
};
use serde_json::Value;
use std::future::Future;
use std::pin::Pin;

const USAGE_URL: &str = "https://chatgpt.com/backend-api/wham/usage";
const REFRESH_URL: &str = "https://auth.openai.com/oauth/token";
const REFRESH_CLIENT_ID: &str = "app_EMoamEEZ73f0CkXaXp7hrann";
const EIGHT_DAYS_SECS: i64 = 8 * 24 * 60 * 60;
const MAX_AUTH_JSON_BYTES: usize = 8 * 1024 * 1024;
/// statuspage probe — macOS `OpenAIStatusProbe` parity.
const STATUS_URL: &str = "https://status.openai.com/api/v2/status.json";

static CLI_VERSION: std::sync::OnceLock<Option<String>> = std::sync::OnceLock::new();

#[derive(Clone, Debug, PartialEq)]
struct Credentials {
    access_token: String,
    refresh_token: String,
    id_token: Option<String>,
    account_id: Option<String>,
    last_refresh: Option<i64>,
}

impl Credentials {
    fn needs_refresh(&self, now: i64) -> bool {
        match self.last_refresh {
            Some(t) => now - t > EIGHT_DAYS_SECS,
            None => true,
        }
    }
}

/// Pure parse of `~/.codex/auth.json` contents (unit-tested). Supports the
/// OPENAI_API_KEY fallback mode (no OAuth tokens) and the standard
/// `tokens.{access_token,refresh_token,id_token,account_id}` shape.
fn parse_auth_json(contents: &str) -> Result<Credentials, String> {
    let json: Value = serde_json::from_str(contents).map_err(|e| format!("JSON: {e}"))?;

    if let Some(api_key) = json.get("OPENAI_API_KEY").and_then(Value::as_str) {
        let trimmed = api_key.trim();
        if !trimmed.is_empty() {
            return Ok(Credentials {
                access_token: trimmed.to_string(),
                refresh_token: String::new(),
                id_token: None,
                account_id: None,
                last_refresh: None,
            });
        }
    }

    let tokens = json
        .get("tokens")
        .ok_or_else(|| "missing tokens".to_string())?;
    let access_token = tokens
        .get("access_token")
        .or_else(|| tokens.get("accessToken"))
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| "missing access_token".to_string())?
        .to_string();

    let refresh_token = tokens
        .get("refresh_token")
        .or_else(|| tokens.get("refreshToken"))
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let id_token = tokens
        .get("id_token")
        .or_else(|| tokens.get("idToken"))
        .and_then(Value::as_str)
        .map(String::from);
    let account_id = tokens
        .get("account_id")
        .or_else(|| tokens.get("accountId"))
        .and_then(Value::as_str)
        .map(String::from);
    let last_refresh = json
        .get("last_refresh")
        .and_then(Value::as_str)
        .and_then(parse_iso8601);

    Ok(Credentials {
        access_token,
        refresh_token,
        id_token,
        account_id,
        last_refresh,
    })
}

fn parse_iso8601(s: &str) -> Option<i64> {
    chrono::DateTime::parse_from_rfc3339(s)
        .ok()
        .map(|d| d.timestamp())
}

/// Decoded JWT payload of the OAuth `id_token`. Never panics.
fn id_token_payload(id_token: Option<&str>) -> Option<Value> {
    let token = id_token?;
    let mut parts = token.split('.');
    parts.next()?;
    let payload_b64 = parts.next()?;
    let payload = decode_base64url(payload_b64)?;
    serde_json::from_slice(&payload).ok()
}

/// Best-effort email from the OAuth `id_token` JWT payload.
fn email_from_id_token(id_token: Option<&str>) -> Option<String> {
    let json = id_token_payload(id_token)?;
    if let Some(email) = json.get("email").and_then(Value::as_str) {
        return Some(email.to_string());
    }
    json.get("https://api.openai.com/profile")
        .and_then(|p| p.get("email"))
        .and_then(Value::as_str)
        .map(String::from)
}

/// ChatGPT plan tier ("plus"/"pro"/"team") from the id_token auth claims —
/// macOS `CodexAuth.planType` parity; drives the settings "Gói" row.
fn plan_from_id_token(id_token: Option<&str>) -> Option<String> {
    id_token_payload(id_token)?
        .get("https://api.openai.com/auth")
        .and_then(|a| a.get("chatgpt_plan_type"))
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(String::from)
}

fn decode_base64url(s: &str) -> Option<Vec<u8>> {
    use base64::Engine;
    let mut padded = s.replace('-', "+").replace('_', "/");
    while padded.len() % 4 != 0 {
        padded.push('=');
    }
    base64::engine::general_purpose::STANDARD
        .decode(padded)
        .ok()
}

/// Writes refreshed tokens back to auth.json, preserving other keys. Mirrors
/// `CodexAuthStore.save` (0600 perms via a staged file + atomic rename).
fn save_auth_json_if_unchanged(
    path: &std::path::Path,
    creds: &Credentials,
    expected: &[u8],
    expected_revision: u64,
) -> std::io::Result<Option<Vec<u8>>> {
    let parent = path.parent().ok_or_else(|| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "Codex auth path has no parent",
        )
    })?;
    let directory = crate::platform::atomic_file::BoundDirectory::open(parent)?;
    save_auth_json_if_unchanged_at_using(
        &directory,
        creds,
        expected,
        expected_revision,
        |directory, data, expected| {
            crate::platform::atomic_file::write_private_json_atomic_if_unchanged_at::<Value>(
                directory,
                std::ffi::OsStr::new("auth.json"),
                data,
                expected,
            )
        },
    )
}

#[cfg(test)]
fn save_auth_json_if_unchanged_with_hook(
    path: &std::path::Path,
    creds: &Credentials,
    expected: &[u8],
    expected_revision: u64,
    after_staging: impl FnOnce(),
) -> std::io::Result<Option<Vec<u8>>> {
    let parent = path.parent().ok_or_else(|| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "Codex auth path has no parent",
        )
    })?;
    let directory = crate::platform::atomic_file::BoundDirectory::open(parent)?;
    save_auth_json_if_unchanged_at_using(
        &directory,
        creds,
        expected,
        expected_revision,
        |directory, data, expected| {
            crate::platform::atomic_file::write_private_json_atomic_if_unchanged_at_with_hook::<Value>(
                directory,
                std::ffi::OsStr::new("auth.json"),
                data,
                expected,
                after_staging,
            )
        },
    )
}

fn save_auth_json_if_unchanged_at_using(
    directory: &crate::platform::atomic_file::BoundDirectory,
    creds: &Credentials,
    expected: &[u8],
    expected_revision: u64,
    writer: impl FnOnce(
        &crate::platform::atomic_file::BoundDirectory,
        &[u8],
        &[u8],
    ) -> std::io::Result<crate::platform::atomic_file::ConditionalWriteOutcome>,
) -> std::io::Result<Option<Vec<u8>>> {
    let value: Value = serde_json::from_slice(expected)
        .map_err(|error| std::io::Error::new(std::io::ErrorKind::InvalidData, error))?;
    let mut json = value.as_object().cloned().ok_or_else(|| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "auth.json is not an object",
        )
    })?;

    let mut tokens = json
        .get("tokens")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    tokens.insert(
        "access_token".into(),
        Value::String(creds.access_token.clone()),
    );
    tokens.insert(
        "refresh_token".into(),
        Value::String(creds.refresh_token.clone()),
    );
    if let Some(id_token) = &creds.id_token {
        tokens.insert("id_token".into(), Value::String(id_token.clone()));
    }
    if let Some(account_id) = &creds.account_id {
        tokens.insert("account_id".into(), Value::String(account_id.clone()));
    }
    json.insert("tokens".into(), Value::Object(tokens));
    json.insert(
        "last_refresh".into(),
        Value::String(chrono::Utc::now().to_rfc3339()),
    );
    let data = serde_json::to_vec_pretty(&Value::Object(json))?;

    let outcome = codex_accounts::with_current_auth_file_at(
        directory,
        MAX_AUTH_JSON_BYTES,
        expected_revision,
        expected,
        || writer(directory, &data, expected),
    )?;
    match outcome {
        Some(crate::platform::atomic_file::ConditionalWriteOutcome::Written) => Ok(Some(data)),
        Some(crate::platform::atomic_file::ConditionalWriteOutcome::Conflict) | None => Ok(None),
    }
}

fn save_bound_auth(
    selection: &codex_accounts::ActiveSelection,
    creds: &Credentials,
    expected: &[u8],
    expected_revision: u64,
) -> std::io::Result<Option<Vec<u8>>> {
    let directory = selection.auth_directory.as_ref().ok_or_else(|| {
        std::io::Error::new(
            std::io::ErrorKind::NotFound,
            "Codex auth directory unavailable",
        )
    })?;
    save_auth_json_if_unchanged_at_using(
        directory,
        creds,
        expected,
        expected_revision,
        |directory, data, expected| {
            crate::platform::atomic_file::write_private_json_atomic_if_unchanged_at::<Value>(
                directory,
                std::ffi::OsStr::new("auth.json"),
                data,
                expected,
            )
        },
    )
}

#[derive(Clone)]
struct AuthContentGuard {
    directory: crate::platform::atomic_file::BoundDirectory,
    expected: Vec<u8>,
    revision: u64,
}

#[derive(Clone)]
enum AuthStateGuard {
    Present(AuthContentGuard),
    Missing(crate::platform::atomic_file::BoundDirectory),
    Unavailable,
    Unreadable(crate::platform::atomic_file::BoundDirectory),
}

#[derive(Clone)]
struct FetchGuard {
    selection: codex_accounts::ActiveSelection,
    auth: AuthStateGuard,
}

impl FetchGuard {
    fn is_current(&self) -> bool {
        if !matches!(
            codex_accounts::active_selection_checked(),
            Ok(current) if current == self.selection
        ) {
            return false;
        }
        match &self.auth {
            AuthStateGuard::Present(guard) => auth_guard_is_current_value(guard),
            AuthStateGuard::Missing(directory) => {
                matches!(
                    codex_accounts::read_auth_file_guarded_at(directory, MAX_AUTH_JSON_BYTES),
                    Ok(None)
                )
            }
            AuthStateGuard::Unavailable => true,
            AuthStateGuard::Unreadable(directory) => {
                codex_accounts::read_auth_file_guarded_at(directory, MAX_AUTH_JSON_BYTES).is_err()
            }
        }
    }

    fn auth_content_mut(&mut self) -> Option<&mut AuthContentGuard> {
        match &mut self.auth {
            AuthStateGuard::Present(guard) => Some(guard),
            _ => None,
        }
    }

    fn auth_content(&self) -> Option<&AuthContentGuard> {
        match &self.auth {
            AuthStateGuard::Present(guard) => Some(guard),
            _ => None,
        }
    }
}

fn auth_guard_is_current_value(guard: &AuthContentGuard) -> bool {
    codex_accounts::with_current_auth_file_at(
        &guard.directory,
        MAX_AUTH_JSON_BYTES,
        guard.revision,
        &guard.expected,
        || Ok(()),
    )
    .ok()
    .flatten()
    .is_some()
}

#[cfg(test)]
fn auth_guard_is_current(guard: &AuthContentGuard) -> bool {
    auth_guard_is_current_value(guard)
}

fn save_bound_snapshot_if_current(
    selection: &codex_accounts::ActiveSelection,
    status: &ProviderStatus,
    guard: &AuthContentGuard,
) -> bool {
    matches!(
        codex_accounts::with_current_auth_file_at(
            &guard.directory,
            MAX_AUTH_JSON_BYTES,
            guard.revision,
            &guard.expected,
            || {
                let _ = codex_accounts::save_snapshot(&selection.account_id, status);
                Ok(())
            },
        ),
        Ok(Some(()))
    )
}

type RefreshResult = Result<(String, Option<String>, Option<String>), String>;
type RefreshFuture<'a> = Pin<Box<dyn Future<Output = RefreshResult> + Send + 'a>>;
type UsageFuture<'a> = Pin<Box<dyn Future<Output = Result<Value, UsageError>> + Send + 'a>>;
type EnrichmentFuture<'a> = Pin<Box<dyn Future<Output = Option<Value>> + Send + 'a>>;
type SideInfoFuture<'a> = Pin<Box<dyn Future<Output = SideInfo> + Send + 'a>>;

trait CodexOperations: Sync {
    fn refresh<'a>(&'a self, refresh_token: &'a str) -> RefreshFuture<'a>;
    fn usage<'a>(&'a self, access_token: &'a str, account_id: Option<&'a str>) -> UsageFuture<'a>;
    fn enrichment<'a>(&'a self, cfg: &'a config::Provider) -> EnrichmentFuture<'a>;
    fn side_info(&self) -> SideInfoFuture<'_>;
}

struct LiveOperations;

impl CodexOperations for LiveOperations {
    fn refresh<'a>(&'a self, refresh_token: &'a str) -> RefreshFuture<'a> {
        Box::pin(refresh_token_request(refresh_token))
    }

    fn usage<'a>(&'a self, access_token: &'a str, account_id: Option<&'a str>) -> UsageFuture<'a> {
        Box::pin(async move {
            let client = shared_client();
            fetch_usage(&client, access_token, account_id).await
        })
    }

    fn enrichment<'a>(&'a self, cfg: &'a config::Provider) -> EnrichmentFuture<'a> {
        Box::pin(fetch_cookie_enrichment(cfg))
    }

    fn side_info(&self) -> SideInfoFuture<'_> {
        Box::pin(async {
            let (version, service) = futures::join!(
                tauri::async_runtime::spawn_blocking(|| {
                    cli_version_blocking(&CLI_VERSION, "codex")
                }),
                fetch_service_status(STATUS_URL),
            );
            SideInfo {
                version: version.unwrap_or(None),
                service,
            }
        })
    }
}

static LIVE_OPERATIONS: LiveOperations = LiveOperations;

async fn refresh_token_request(
    refresh_token: &str,
) -> Result<(String, Option<String>, Option<String>), String> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| format!("client: {e}"))?;
    let body = serde_json::json!({
        "client_id": REFRESH_CLIENT_ID,
        "grant_type": "refresh_token",
        "refresh_token": refresh_token,
        "scope": "openid profile email",
    });
    let resp = client
        .post(REFRESH_URL)
        .header("Content-Type", "application/json")
        .json(&body)
        .send()
        .await
        .map_err(|e| format!("Network: {e}"))?;
    if resp.status().as_u16() != 200 {
        return Err(format!("refresh HTTP {}", resp.status().as_u16()));
    }
    let json: Value = resp.json().await.map_err(|e| format!("JSON: {e}"))?;
    let access_token = json
        .get("access_token")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    if access_token.is_empty() {
        return Err("refresh response missing access_token".to_string());
    }
    let new_refresh = json
        .get("refresh_token")
        .and_then(Value::as_str)
        .map(String::from);
    let id_token = json
        .get("id_token")
        .and_then(Value::as_str)
        .map(String::from);
    Ok((access_token, new_refresh, id_token))
}

async fn fetch_usage(
    client: &reqwest::Client,
    access_token: &str,
    account_id: Option<&str>,
) -> Result<Value, UsageError> {
    let mut req = client
        .get(USAGE_URL)
        .bearer_auth(access_token)
        .header("User-Agent", "BirdNion")
        .header("Accept", "application/json");
    if let Some(id) = account_id.filter(|s| !s.is_empty()) {
        req = req.header("ChatGPT-Account-Id", id);
    }
    let resp = req
        .send()
        .await
        .map_err(|e| UsageError::Network(e.to_string()))?;
    match resp.status().as_u16() {
        200..=299 => resp
            .json::<Value>()
            .await
            .map_err(|e| UsageError::Invalid(e.to_string())),
        401 | 403 => Err(UsageError::Unauthorized),
        code => Err(UsageError::Server(code)),
    }
}

enum UsageError {
    Unauthorized,
    Server(u16),
    Invalid(String),
    Network(String),
}

/// Best-effort chatgpt.com web-dashboard enrichment: hits the same
/// `wham/usage` JSON endpoint using a browser session cookie for
/// `chatgpt.com` (mirrors `OpenAIDashboardFetcher.fetchDashboardUsageAPI`'s
/// cookie-authenticated preflight). Returns `None` on any failure — this must
/// never break the primary OAuth status.
async fn fetch_cookie_enrichment(cfg: &config::Provider) -> Option<Value> {
    let cfg_clone = cfg.clone();
    let cookie_header = tauri::async_runtime::spawn_blocking(move || {
        browser_cookies::cookie_header(&["chatgpt.com"], &cfg_clone)
    })
    .await
    .ok()?
    .ok()?;
    if cookie_header.trim().is_empty() {
        return None;
    }
    let client = shared_client();
    let resp = client
        .get(USAGE_URL)
        .header("Cookie", &cookie_header)
        .header("Accept", "application/json")
        .header("Accept-Language", "en-US,en;q=0.9")
        .header("User-Agent", "BirdNion")
        .send()
        .await
        .ok()?;
    if !resp.status().is_success() {
        return None;
    }
    resp.json::<Value>().await.ok()
}

pub async fn fetch(cfg: &config::Provider) -> ProviderStatus {
    fetch_with_operations(cfg, &LIVE_OPERATIONS).await
}

enum FetchAttempt {
    Ready(ProviderStatus, FetchGuard),
    Stale,
}

fn finish_attempt(status: ProviderStatus, guard: FetchGuard) -> FetchAttempt {
    if guard.is_current() {
        FetchAttempt::Ready(status, guard)
    } else {
        FetchAttempt::Stale
    }
}

async fn fetch_with_operations(
    cfg: &config::Provider,
    operations: &dyn CodexOperations,
) -> ProviderStatus {
    for _ in 0..2 {
        let selection = match codex_accounts::active_selection_checked() {
            Ok(selection) => selection,
            Err(_) => {
                return ProviderStatus::failure(
                    &cfg.id,
                    &display_name(cfg),
                    "Không đọc được cấu hình account Codex",
                )
            }
        };
        match fetch_uncached(cfg, &selection, operations).await {
            FetchAttempt::Stale => continue,
            FetchAttempt::Ready(status, guard) => {
                if !guard.is_current() {
                    continue;
                }
                if let Some(auth_guard) = guard.auth_content() {
                    if !save_bound_snapshot_if_current(&selection, &status, auth_guard) {
                        continue;
                    }
                }
                if guard.is_current() {
                    return status;
                }
            }
        }
    }
    ProviderStatus::failure(
        &cfg.id,
        &display_name(cfg),
        "Phiên đăng nhập Codex đã thay đổi — thử lại",
    )
}

async fn fetch_uncached(
    cfg: &config::Provider,
    selection: &codex_accounts::ActiveSelection,
    operations: &dyn CodexOperations,
) -> FetchAttempt {
    let name = display_name(cfg);
    if selection.account_id != codex_accounts::SYSTEM_ID && selection.auth_path.is_none() {
        return FetchAttempt::Ready(
            ProviderStatus::failure(
                &cfg.id,
                &name,
                "Không thể xác minh account Codex đang hoạt động",
            ),
            FetchGuard {
                selection: selection.clone(),
                auth: AuthStateGuard::Unavailable,
            },
        );
    }
    if selection.auth_path.is_none() {
        let guard = FetchGuard {
            selection: selection.clone(),
            auth: AuthStateGuard::Unavailable,
        };
        let status = fetch_cookie_fallback(cfg, &name).await;
        return finish_attempt(status, guard);
    }
    let Some(directory) = selection.auth_directory.as_ref() else {
        let guard = FetchGuard {
            selection: selection.clone(),
            auth: AuthStateGuard::Unavailable,
        };
        let status = fetch_cookie_fallback(cfg, &name).await;
        return finish_attempt(status, guard);
    };

    let guarded_file =
        match codex_accounts::read_auth_file_guarded_at(directory, MAX_AUTH_JSON_BYTES) {
            Ok(Some(guarded)) => guarded,
            Ok(None) => {
                let guard = FetchGuard {
                    selection: selection.clone(),
                    auth: AuthStateGuard::Missing(directory.clone()),
                };
                let status = fetch_cookie_fallback(cfg, &name).await;
                return finish_attempt(status, guard);
            }
            Err(_) => {
                return finish_attempt(
                    ProviderStatus::failure(&cfg.id, &name, "Không đọc được auth.json"),
                    FetchGuard {
                        selection: selection.clone(),
                        auth: AuthStateGuard::Unreadable(directory.clone()),
                    },
                )
            }
        };
    let mut guard = FetchGuard {
        selection: selection.clone(),
        auth: AuthStateGuard::Present(AuthContentGuard {
            directory: guarded_file.directory.clone(),
            expected: guarded_file.bytes.clone(),
            revision: guarded_file.revision,
        }),
    };
    let contents = match std::str::from_utf8(&guarded_file.bytes) {
        Ok(contents) => contents,
        Err(_) => {
            return finish_attempt(
                ProviderStatus::failure(&cfg.id, &name, "Không đọc được auth.json"),
                guard,
            )
        }
    };
    let mut creds = match parse_auth_json(contents) {
        Ok(c) => c,
        Err(_) => {
            return finish_attempt(
                ProviderStatus::failure(&cfg.id, &name, "Không đọc được auth.json"),
                guard,
            )
        }
    };

    let now = chrono::Utc::now().timestamp();
    if creds.needs_refresh(now) && !creds.refresh_token.is_empty() {
        let refresh_result = operations.refresh(&creds.refresh_token).await;
        if !guard
            .auth_content()
            .is_some_and(auth_guard_is_current_value)
        {
            return FetchAttempt::Stale;
        }
        if let Ok((access, rotated_refresh, id_token)) = refresh_result {
            creds.access_token = access;
            creds.refresh_token = rotated_refresh.unwrap_or(creds.refresh_token);
            creds.id_token = id_token.or(creds.id_token);
            creds.last_refresh = Some(now);
            let auth_guard = guard.auth_content_mut().expect("present auth guard");
            match save_bound_auth(selection, &creds, &auth_guard.expected, auth_guard.revision) {
                Ok(Some(written)) => auth_guard.expected = written,
                Ok(None) => return FetchAttempt::Stale,
                Err(_) => {
                    return finish_attempt(
                        ProviderStatus::failure(
                            &cfg.id,
                            &name,
                            "Không lưu được auth.json sau khi làm mới token",
                        ),
                        guard,
                    )
                }
            }
        }
        if !guard.is_current() {
            return FetchAttempt::Stale;
        }
    }

    // Side-channel info fetched alongside usage (macOS runs these the same
    // way): CLI version (memoized) + statuspage probe — both best-effort.
    let (usage, side) = futures::join!(
        operations.usage(&creds.access_token, creds.account_id.as_deref()),
        operations.side_info(),
    );
    if !guard.is_current() {
        return FetchAttempt::Stale;
    }
    let mut status = match usage {
        Ok(body) => {
            let enrichment = operations.enrichment(cfg).await;
            if !guard.is_current() {
                return FetchAttempt::Stale;
            }
            build_success(&cfg.id, &name, &body, &creds, enrichment.as_ref(), &side).await
        }
        Err(UsageError::Unauthorized) => {
            if !creds.refresh_token.is_empty() {
                let refresh_result = operations.refresh(&creds.refresh_token).await;
                if !guard
                    .auth_content()
                    .is_some_and(auth_guard_is_current_value)
                {
                    return FetchAttempt::Stale;
                }
                if let Ok((access, rotated_refresh, id_token)) = refresh_result {
                    creds.access_token = access;
                    creds.refresh_token = rotated_refresh.unwrap_or(creds.refresh_token);
                    creds.id_token = id_token.or(creds.id_token);
                    creds.last_refresh = Some(now);
                    let auth_guard = guard.auth_content_mut().expect("present auth guard");
                    match save_bound_auth(
                        selection,
                        &creds,
                        &auth_guard.expected,
                        auth_guard.revision,
                    ) {
                        Ok(Some(written)) => auth_guard.expected = written,
                        Ok(None) => return FetchAttempt::Stale,
                        Err(_) => {
                            return finish_attempt(
                                ProviderStatus::failure(
                                    &cfg.id,
                                    &name,
                                    "Không lưu được auth.json sau khi làm mới token",
                                ),
                                guard,
                            )
                        }
                    }
                    if !guard.is_current() {
                        return FetchAttempt::Stale;
                    }
                    let retry = operations
                        .usage(&creds.access_token, creds.account_id.as_deref())
                        .await;
                    if !guard.is_current() {
                        return FetchAttempt::Stale;
                    }
                    if let Ok(body) = retry {
                        let enrichment = operations.enrichment(cfg).await;
                        if !guard.is_current() {
                            return FetchAttempt::Stale;
                        }
                        let mut status = build_success(
                            &cfg.id,
                            &name,
                            &body,
                            &creds,
                            enrichment.as_ref(),
                            &side,
                        )
                        .await;
                        if !guard.is_current() {
                            return FetchAttempt::Stale;
                        }
                        status.menu_bar_metric = cfg.menu_bar_metric.clone();
                        return finish_attempt(status, guard);
                    }
                }
            }
            ProviderStatus::failure(
                &cfg.id,
                &name,
                "Token Codex hết hạn — chạy `codex` để đăng nhập lại",
            )
        }
        Err(UsageError::Server(code)) => {
            ProviderStatus::failure(&cfg.id, &name, format!("HTTP {code}"))
        }
        Err(UsageError::Invalid(e)) => {
            ProviderStatus::failure(&cfg.id, &name, format!("Response không hợp lệ: {e}"))
        }
        Err(UsageError::Network(e)) => {
            ProviderStatus::failure(&cfg.id, &name, format!("Network: {e}"))
        }
    };
    if !guard.is_current() {
        return FetchAttempt::Stale;
    }
    status.menu_bar_metric = cfg.menu_bar_metric.clone();
    finish_attempt(status, guard)
}

/// Best-effort side-channel info shown in the settings detail grid.
struct SideInfo {
    version: Option<String>,
    service: Option<(String, String)>,
}

/// No usable OAuth session (`auth.json` missing) → try the cookie-authenticated
/// dashboard enrichment as a standalone best-effort status instead of failing
/// outright, mirroring how the Swift extras path can surface data independent
/// of the CLI login state.
async fn fetch_cookie_fallback(cfg: &config::Provider, name: &str) -> ProviderStatus {
    let Some(body) = fetch_cookie_enrichment(cfg).await else {
        return ProviderStatus::failure(
            &cfg.id,
            name,
            "Chưa đăng nhập Codex — chạy `codex` để đăng nhập",
        );
    };
    let windows = map_windows(&body);
    if windows.is_empty() {
        return ProviderStatus::failure(
            &cfg.id,
            name,
            "Chưa đăng nhập Codex — chạy `codex` để đăng nhập",
        );
    }
    let credits_remaining = credits_balance(&body);
    let extras = dashboard_extras(&body);
    let label = extras
        .signed_in_email
        .clone()
        .or_else(|| cfg.account_label.clone())
        .unwrap_or_else(|| "cookie".to_string());
    ProviderStatus {
        id: cfg.id.clone(),
        display_name: name.to_string(),
        windows,
        last_updated: chrono::Utc::now().timestamp(),
        account_label: Some(label),
        credits_remaining,
        signed_in_email: extras.signed_in_email,
        credits_purchase_url: extras.credits_purchase_url,
        credits_history_count: extras.credits_history_count,
        source_label: Some("Cookie".to_string()),
        credits_unlimited: credits_unlimited(&body),
        ..Default::default()
    }
}

fn credits_balance(body: &Value) -> Option<f64> {
    body.get("credits")
        .and_then(|c| c.get("balance"))
        .and_then(Value::as_f64)
}

/// Pure dashboard-extras mapping from a `wham/usage` payload — port of the
/// JSON-derivable subset of `CodexWebDashboard.map(_:)`. `codeReviewRemainingPercent`
/// has no equivalent here (see module docs) and is always left `None`.
struct DashboardExtras {
    signed_in_email: Option<String>,
    credits_purchase_url: Option<String>,
    credits_history_count: Option<i32>,
}

fn dashboard_extras(body: &Value) -> DashboardExtras {
    let credits = body.get("credits");
    DashboardExtras {
        signed_in_email: body.get("email").and_then(Value::as_str).map(String::from),
        credits_purchase_url: credits
            .and_then(|c| c.get("purchase_url").or_else(|| c.get("purchase_url_web")))
            .and_then(Value::as_str)
            .map(String::from),
        credits_history_count: credits
            .and_then(|c| c.get("credit_events").or_else(|| c.get("events")))
            .and_then(Value::as_array)
            .filter(|events| !events.is_empty())
            .map(|events| events.len() as i32),
    }
}

/// True when either payload reports unlimited credits.
fn credits_unlimited(body: &Value) -> bool {
    body.get("credits")
        .and_then(|c| c.get("unlimited"))
        .and_then(Value::as_bool)
        .unwrap_or(false)
}

async fn build_success(
    id: &str,
    name: &str,
    body: &Value,
    creds: &Credentials,
    cookie_enrichment: Option<&Value>,
    side: &SideInfo,
) -> ProviderStatus {
    let windows = map_windows(body);
    if windows.is_empty() {
        return ProviderStatus::failure(id, name, "Codex chưa có dữ liệu quota");
    }
    let account_label =
        email_from_id_token(creds.id_token.as_deref()).unwrap_or_else(|| "Codex".to_string());
    // OAuth's own `wham/usage` response is the source of truth; the cookie
    // enrichment only fills in credits/extras when OAuth omitted them
    // (e.g. plans where credits are absent from the bearer-token response).
    let extras = dashboard_extras(body);
    let cookie_extras = cookie_enrichment.map(dashboard_extras);
    let credits_remaining =
        credits_balance(body).or_else(|| cookie_enrichment.and_then(credits_balance));
    let signed_in_email = extras.signed_in_email.or_else(|| {
        cookie_extras
            .as_ref()
            .and_then(|e| e.signed_in_email.clone())
    });
    let credits_purchase_url = extras.credits_purchase_url.or_else(|| {
        cookie_extras
            .as_ref()
            .and_then(|e| e.credits_purchase_url.clone())
    });
    let credits_history_count = extras
        .credits_history_count
        .or_else(|| cookie_extras.as_ref().and_then(|e| e.credits_history_count));
    ProviderStatus {
        id: id.to_string(),
        display_name: name.to_string(),
        windows,
        last_updated: chrono::Utc::now().timestamp(),
        account_label: Some(account_label),
        credits_remaining,
        signed_in_email,
        credits_purchase_url,
        credits_history_count,
        plan_type: plan_from_id_token(creds.id_token.as_deref()),
        version: side.version.clone(),
        service_status: side.service.as_ref().map(|(d, _)| d.clone()),
        service_status_level: side.service.as_ref().map(|(_, i)| i.clone()),
        source_label: Some("OAuth".to_string()),
        credits_unlimited: credits_unlimited(body)
            || cookie_enrichment.map(credits_unlimited).unwrap_or(false),
        ..Default::default()
    }
}

struct Window {
    used_percent: i64,
    reset_at: i64,
    limit_window_seconds: i64,
}

fn parse_window(v: &Value) -> Option<Window> {
    Some(Window {
        used_percent: v.get("used_percent").and_then(Value::as_i64)?,
        reset_at: v.get("reset_at").and_then(Value::as_i64).unwrap_or(0),
        limit_window_seconds: v
            .get("limit_window_seconds")
            .and_then(Value::as_i64)
            .unwrap_or(0),
    })
}

fn clamp_window(w: Window) -> Window {
    Window {
        used_percent: w.used_percent.clamp(0, 100),
        ..w
    }
}

enum WindowRole {
    Session,
    Weekly,
    Unknown,
}

fn window_role(w: &Window) -> WindowRole {
    match w.limit_window_seconds / 60 {
        300 => WindowRole::Session,
        10080 => WindowRole::Weekly,
        _ => WindowRole::Unknown,
    }
}

/// Normalizes primary/secondary windows into (session, weekly) regardless of
/// which API slot they arrived in — mirrors `CodexRateWindowNormalizer`.
fn normalize(
    primary: Option<Window>,
    secondary: Option<Window>,
) -> (Option<Window>, Option<Window>) {
    match (primary, secondary) {
        (Some(p), Some(s)) => match (window_role(&p), window_role(&s)) {
            (WindowRole::Weekly, WindowRole::Session)
            | (WindowRole::Weekly, WindowRole::Unknown) => {
                (Some(clamp_window(s)), Some(clamp_window(p)))
            }
            _ => (Some(clamp_window(p)), Some(clamp_window(s))),
        },
        (Some(p), None) => match window_role(&p) {
            WindowRole::Weekly => (None, Some(clamp_window(p))),
            _ => (Some(clamp_window(p)), None),
        },
        (None, Some(s)) => match window_role(&s) {
            WindowRole::Weekly => (None, Some(clamp_window(s))),
            _ => (Some(clamp_window(s)), None),
        },
        (None, None) => (None, None),
    }
}

fn to_quota_window(w: Window, label: &str) -> QuotaWindow {
    QuotaWindow {
        semantic_key: None,
        semantic_kind: None,
        label: label.to_string(),
        used_pct: w.used_percent as i32,
        remaining_pct: (100 - w.used_percent) as i32,
        subtitle: None,
        resets_at: if w.reset_at > 0 {
            Some(w.reset_at)
        } else {
            None
        },
        window_seconds: (w.limit_window_seconds > 0).then_some(w.limit_window_seconds),
    }
}

/// Pure payload → windows mapping (unit-tested). Primary → "5 giờ", secondary
/// → "Tuần", plus `additional_rate_limits` (Spark 5h/Weekly, or one window per
/// other model-specific entry).
fn map_windows(body: &Value) -> Vec<QuotaWindow> {
    let rate_limit = body.get("rate_limit");
    let primary = rate_limit
        .and_then(|r| r.get("primary_window"))
        .and_then(parse_window);
    let secondary = rate_limit
        .and_then(|r| r.get("secondary_window"))
        .and_then(parse_window);
    let (session, weekly) = normalize(primary, secondary);

    let mut windows = Vec::new();
    if let Some(w) = session {
        windows.push(to_quota_window(w, "5 giờ"));
    }
    if let Some(w) = weekly {
        windows.push(to_quota_window(w, "Tuần"));
    }
    windows.extend(additional_windows(body.get("additional_rate_limits")));
    windows
}

fn additional_windows(entries: Option<&Value>) -> Vec<QuotaWindow> {
    let Some(entries) = entries.and_then(Value::as_array) else {
        return Vec::new();
    };
    let mut used_labels = std::collections::HashSet::new();
    let mut out = Vec::new();
    for entry in entries {
        let metered_feature = entry
            .get("metered_feature")
            .and_then(Value::as_str)
            .unwrap_or("");
        let limit_name = entry
            .get("limit_name")
            .and_then(Value::as_str)
            .unwrap_or("");
        let is_spark = metered_feature.to_lowercase().contains("spark")
            || limit_name.to_lowercase().contains("spark");
        let rate_limit = entry.get("rate_limit");
        let primary = rate_limit
            .and_then(|r| r.get("primary_window"))
            .and_then(parse_window);
        let secondary = rate_limit
            .and_then(|r| r.get("secondary_window"))
            .and_then(parse_window);

        if is_spark {
            if let Some(p) = primary {
                if used_labels.insert("Codex Spark 5 giờ") {
                    out.push(to_quota_window(p, "Codex Spark 5 giờ"));
                }
            }
            if let Some(s) = secondary {
                if used_labels.insert("Codex Spark Tuần") {
                    out.push(to_quota_window(s, "Codex Spark Tuần"));
                }
            }
            continue;
        }

        let Some(w) = primary.or(secondary) else {
            continue;
        };
        let raw_label = if !metered_feature.is_empty() {
            metered_feature
        } else if !limit_name.is_empty() {
            limit_name
        } else {
            "Codex"
        };
        let label = title_case(raw_label);
        if used_labels.insert(Box::leak(label.clone().into_boxed_str()) as &str) {
            out.push(to_quota_window(w, &label));
        }
    }
    out
}

fn title_case(raw: &str) -> String {
    raw.split(|c: char| c == '_' || c == '-' || c.is_whitespace())
        .filter(|s| !s.is_empty())
        .map(|w| {
            let lower = w.to_lowercase();
            let mut chars = lower.chars();
            match chars.next() {
                Some(f) => f.to_uppercase().collect::<String>() + chars.as_str(),
                None => String::new(),
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    use crate::config::TEST_ENV_LOCK as ENV_LOCK;

    fn block_on<F: std::future::Future>(future: F) -> F::Output {
        tokio::runtime::Builder::new_current_thread()
            .enable_time()
            .build()
            .unwrap()
            .block_on(future)
    }

    #[test]
    fn parses_auth_json_oauth_tokens() {
        let raw = r#"{"tokens":{"access_token":"at","refresh_token":"rt","id_token":"idt","account_id":"acc"},"last_refresh":"2026-06-01T00:00:00Z"}"#;
        let creds = parse_auth_json(raw).unwrap();
        assert_eq!(creds.access_token, "at");
        assert_eq!(creds.account_id.as_deref(), Some("acc"));
        assert!(creds.last_refresh.is_some());
    }

    #[test]
    fn parses_auth_json_api_key_mode() {
        let raw = r#"{"OPENAI_API_KEY":"sk-test-123"}"#;
        let creds = parse_auth_json(raw).unwrap();
        assert_eq!(creds.access_token, "sk-test-123");
        assert!(creds.refresh_token.is_empty());
    }

    #[test]
    fn malformed_auth_json_is_error() {
        assert!(parse_auth_json("not json").is_err());
        assert!(parse_auth_json(r#"{"tokens":{}}"#).is_err());
    }

    #[test]
    fn needs_refresh_when_stale() {
        let now = 10_000_000i64;
        let fresh = Credentials {
            access_token: "a".into(),
            refresh_token: "r".into(),
            id_token: None,
            account_id: None,
            last_refresh: Some(now - 3600),
        };
        assert!(!fresh.needs_refresh(now));
        let stale = Credentials {
            access_token: "a".into(),
            refresh_token: "r".into(),
            id_token: None,
            account_id: None,
            last_refresh: Some(now - EIGHT_DAYS_SECS - 1),
        };
        assert!(stale.needs_refresh(now));
        let never = Credentials {
            access_token: "a".into(),
            refresh_token: "r".into(),
            id_token: None,
            account_id: None,
            last_refresh: None,
        };
        assert!(never.needs_refresh(now));
    }

    #[test]
    fn conditional_refresh_save_rejects_same_path_reauth_and_removal() {
        let base = std::env::temp_dir().join(format!(
            "birdnion-codex-auth-cas-test-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(&base).unwrap();
        let path = base.join("auth.json");
        let alice = br#"{"tokens":{"access_token":"alice","refresh_token":"alice-r"}}"#;
        let bob = br#"{"tokens":{"access_token":"bob","refresh_token":"bob-r"}}"#;
        std::fs::write(&path, alice).unwrap();
        let refreshed = Credentials {
            access_token: "alice-new".into(),
            refresh_token: "alice-r2".into(),
            id_token: None,
            account_id: None,
            last_refresh: Some(123),
        };

        let revision = codex_accounts::read_auth_file_guarded(&path, MAX_AUTH_JSON_BYTES)
            .unwrap()
            .unwrap()
            .revision;
        std::fs::write(&path, bob).unwrap();
        assert!(
            save_auth_json_if_unchanged(&path, &refreshed, alice, revision)
                .unwrap()
                .is_none()
        );
        assert_eq!(
            parse_auth_json(&std::fs::read_to_string(&path).unwrap())
                .unwrap()
                .access_token,
            "bob"
        );

        std::fs::remove_file(&path).unwrap();
        assert!(
            save_auth_json_if_unchanged(&path, &refreshed, bob, revision)
                .unwrap()
                .is_none()
        );
        assert!(!path.exists());

        std::fs::write(&path, alice).unwrap();
        assert!(
            save_auth_json_if_unchanged(&path, &refreshed, alice, revision)
                .unwrap()
                .is_some()
        );
        assert_eq!(
            parse_auth_json(&std::fs::read_to_string(&path).unwrap())
                .unwrap()
                .access_token,
            "alice-new"
        );

        std::fs::write(&path, alice).unwrap();
        let guarded = codex_accounts::read_auth_file_guarded(&path, MAX_AUTH_JSON_BYTES)
            .unwrap()
            .unwrap();
        codex_accounts::invalidate_auth_file(&path);
        assert!(
            save_auth_json_if_unchanged(&path, &refreshed, &guarded.bytes, guarded.revision,)
                .unwrap()
                .is_none()
        );
        assert_eq!(std::fs::read(&path).unwrap(), alice);
        let _ = std::fs::remove_dir_all(base);
    }

    #[test]
    fn external_reauth_after_compare_before_rename_is_never_overwritten() {
        let base = std::env::temp_dir().join(format!(
            "birdnion-codex-auth-external-cas-test-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(&base).unwrap();
        let path = base.join("auth.json");
        let alice = br#"{"tokens":{"access_token":"alice","refresh_token":"alice-r"}}"#;
        let bob = br#"{"tokens":{"access_token":"bob","refresh_token":"bob-r"}}"#;
        std::fs::write(&path, alice).unwrap();
        let guarded = codex_accounts::read_auth_file_guarded(&path, MAX_AUTH_JSON_BYTES)
            .unwrap()
            .unwrap();
        let refreshed = Credentials {
            access_token: "alice-refreshed".into(),
            refresh_token: "alice-r2".into(),
            id_token: None,
            account_id: None,
            last_refresh: Some(123),
        };

        let result = save_auth_json_if_unchanged_with_hook(
            &path,
            &refreshed,
            &guarded.bytes,
            guarded.revision,
            || std::fs::write(&path, bob).unwrap(),
        )
        .unwrap();

        assert!(result.is_none());
        assert_eq!(std::fs::read(&path).unwrap(), bob);
        assert!(!base
            .join("auth.json.birdnion-cas-backup")
            .try_exists()
            .unwrap());
        let _ = std::fs::remove_dir_all(base);
    }

    #[cfg(unix)]
    #[test]
    fn special_or_oversized_auth_fails_closed_without_cookie_fallback() {
        use std::ffi::CString;
        use std::os::unix::ffi::OsStrExt;
        use std::os::unix::fs::symlink;

        let _guard = ENV_LOCK.lock().unwrap();
        let base = std::env::temp_dir().join(format!(
            "birdnion-codex-auth-special-test-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(&base).unwrap();
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));
        let cfg = config::Provider {
            id: "codex".into(),
            ..Default::default()
        };
        let assert_read_failure = |home: &std::path::Path| {
            std::env::set_var("CODEX_HOME", home);
            let selection = codex_accounts::active_selection();
            let outcome = block_on(fetch_uncached(&cfg, &selection, &LIVE_OPERATIONS));
            let FetchAttempt::Ready(status, _) = outcome else {
                panic!("unchanged unreadable auth must return its failure status");
            };
            assert_eq!(status.error.as_deref(), Some("Không đọc được auth.json"));
        };

        let target = base.join("target.json");
        std::fs::write(
            &target,
            br#"{"tokens":{"access_token":"target","refresh_token":"r"}}"#,
        )
        .unwrap();
        let link_home = base.join("link-home");
        std::fs::create_dir_all(&link_home).unwrap();
        let link = link_home.join("auth.json");
        symlink(&target, &link).unwrap();
        assert_read_failure(&link_home);

        let fifo_home = base.join("fifo-home");
        std::fs::create_dir_all(&fifo_home).unwrap();
        let fifo = fifo_home.join("auth.json");
        let fifo_path = CString::new(fifo.as_os_str().as_bytes()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(fifo_path.as_ptr(), 0o600) }, 0);
        assert_read_failure(&fifo_home);

        let oversized_home = base.join("oversized-home");
        std::fs::create_dir_all(&oversized_home).unwrap();
        let oversized = oversized_home.join("auth.json");
        let file = std::fs::File::create(&oversized).unwrap();
        file.set_len((MAX_AUTH_JSON_BYTES + 1) as u64).unwrap();
        assert_read_failure(&oversized_home);
        std::env::remove_var("BIRDNION_CONFIG");
        std::env::remove_var("CODEX_HOME");
        let _ = std::fs::remove_dir_all(base);
    }

    struct BlockingOperations {
        started: tokio::sync::Notify,
        proceed: tokio::sync::Notify,
        refresh_calls: std::sync::atomic::AtomicUsize,
        usage_tokens: std::sync::Mutex<Vec<String>>,
    }

    impl CodexOperations for BlockingOperations {
        fn refresh<'a>(&'a self, refresh_token: &'a str) -> RefreshFuture<'a> {
            Box::pin(async move {
                assert_eq!(refresh_token, "alice-r");
                self.refresh_calls
                    .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                self.started.notify_one();
                self.proceed.notified().await;
                Ok(("alice-refreshed".into(), Some("alice-r2".into()), None))
            })
        }

        fn usage<'a>(
            &'a self,
            access_token: &'a str,
            _account_id: Option<&'a str>,
        ) -> UsageFuture<'a> {
            Box::pin(async move {
                self.usage_tokens
                    .lock()
                    .unwrap()
                    .push(access_token.to_string());
                Ok(json!({
                    "rate_limit": {
                        "primary_window": {
                            "used_percent": 25,
                            "reset_at": 1_800_000_000,
                            "limit_window_seconds": 300 * 60
                        }
                    }
                }))
            })
        }

        fn enrichment<'a>(&'a self, _cfg: &'a config::Provider) -> EnrichmentFuture<'a> {
            Box::pin(async { None })
        }

        fn side_info(&self) -> SideInfoFuture<'_> {
            Box::pin(async {
                SideInfo {
                    version: None,
                    service: None,
                }
            })
        }
    }

    struct CountingOperations {
        refresh_calls: std::sync::atomic::AtomicUsize,
        usage_calls: std::sync::atomic::AtomicUsize,
    }

    impl CountingOperations {
        fn new() -> Self {
            Self {
                refresh_calls: std::sync::atomic::AtomicUsize::new(0),
                usage_calls: std::sync::atomic::AtomicUsize::new(0),
            }
        }
    }

    impl CodexOperations for CountingOperations {
        fn refresh<'a>(&'a self, _refresh_token: &'a str) -> RefreshFuture<'a> {
            self.refresh_calls
                .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            Box::pin(async { Ok(("unexpected-refresh".into(), None, None)) })
        }

        fn usage<'a>(
            &'a self,
            _access_token: &'a str,
            _account_id: Option<&'a str>,
        ) -> UsageFuture<'a> {
            self.usage_calls
                .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            Box::pin(async { Ok(json!({})) })
        }

        fn enrichment<'a>(&'a self, _cfg: &'a config::Provider) -> EnrichmentFuture<'a> {
            Box::pin(async { None })
        }

        fn side_info(&self) -> SideInfoFuture<'_> {
            Box::pin(async {
                SideInfo {
                    version: None,
                    service: None,
                }
            })
        }
    }

    #[test]
    fn invalid_account_routing_never_refreshes_or_snapshots_system_auth() {
        let _guard = ENV_LOCK.lock().unwrap();
        let root = std::env::temp_dir().join(format!(
            "birdnion-codex-invalid-routing-test-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        let cfg = config::Provider {
            id: "codex".into(),
            ..Default::default()
        };
        let auth = br#"{"tokens":{"access_token":"system","refresh_token":"system-r"},"last_refresh":"1970-01-01T00:00:00Z"}"#;
        let operations = CountingOperations::new();

        for malformed_settings in [true, false] {
            let base = root.join(if malformed_settings {
                "malformed-settings"
            } else {
                "missing-managed-account"
            });
            let codex_home = base.join("codex-home");
            let settings_path = base.join("settings.json");
            std::fs::create_dir_all(&codex_home).unwrap();
            let auth_path = codex_home.join("auth.json");
            std::fs::write(&auth_path, auth).unwrap();
            std::env::set_var("BIRDNION_CONFIG", &settings_path);
            std::env::set_var("CODEX_HOME", &codex_home);

            if malformed_settings {
                std::fs::write(&settings_path, b"not-json").unwrap();
            } else {
                codex_accounts::set_active("missing-managed-account").unwrap();
            }

            let status = block_on(fetch_with_operations(&cfg, &operations));
            assert_eq!(
                status.error.as_deref(),
                Some("Không đọc được cấu hình account Codex")
            );
            assert_eq!(std::fs::read(&auth_path).unwrap(), auth);
            assert!(codex_accounts::quota_snapshots().is_empty());
        }

        assert_eq!(
            operations
                .refresh_calls
                .load(std::sync::atomic::Ordering::SeqCst),
            0
        );
        assert_eq!(
            operations
                .usage_calls
                .load(std::sync::atomic::Ordering::SeqCst),
            0
        );

        std::env::remove_var("BIRDNION_CONFIG");
        std::env::remove_var("CODEX_HOME");
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn auth_change_during_refresh_discards_old_identity_and_retries_once() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = std::env::temp_dir().join(format!(
            "birdnion-codex-stale-refresh-test-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&base);
        let codex_home = base.join("codex-home");
        std::fs::create_dir_all(&codex_home).unwrap();
        let auth_path = codex_home.join("auth.json");
        let jwt = |email: &str| {
            use base64::Engine;
            let payload = serde_json::to_vec(&json!({ "email": email })).unwrap();
            format!(
                "e30.{}.signature",
                base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(payload)
            )
        };
        let alice = serde_json::to_vec(&json!({
            "tokens": {
                "access_token": "alice",
                "refresh_token": "alice-r",
                "id_token": jwt("alice@example.com")
            },
            "last_refresh": "1970-01-01T00:00:00Z"
        }))
        .unwrap();
        let bob = serde_json::to_vec(&json!({
            "tokens": {
                "access_token": "bob",
                "refresh_token": "",
                "id_token": jwt("bob@example.com")
            },
            "last_refresh": chrono::Utc::now().to_rfc3339()
        }))
        .unwrap();
        std::fs::write(&auth_path, &alice).unwrap();
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));
        std::env::set_var("CODEX_HOME", &codex_home);

        let operations = BlockingOperations {
            started: tokio::sync::Notify::new(),
            proceed: tokio::sync::Notify::new(),
            refresh_calls: std::sync::atomic::AtomicUsize::new(0),
            usage_tokens: std::sync::Mutex::new(Vec::new()),
        };
        let cfg = config::Provider {
            id: "codex".into(),
            ..Default::default()
        };
        let status = block_on(async {
            let fetch = fetch_with_operations(&cfg, &operations);
            let reauth = async {
                operations.started.notified().await;
                std::fs::write(&auth_path, &bob).unwrap();
                operations.proceed.notify_one();
            };
            let (status, ()) = futures::join!(fetch, reauth);
            status
        });

        assert_eq!(
            operations
                .refresh_calls
                .load(std::sync::atomic::Ordering::SeqCst),
            1
        );
        assert_eq!(&std::fs::read(&auth_path).unwrap(), &bob);
        assert_eq!(
            *operations.usage_tokens.lock().unwrap(),
            vec!["bob".to_string()]
        );
        assert!(status.error.is_none());
        assert_eq!(status.windows[0].remaining_pct, 75);
        assert_eq!(status.account_label.as_deref(), Some("bob@example.com"));
        assert!(status.signed_in_email.is_none());
        let snapshot = codex_accounts::quota_snapshots()
            .remove(codex_accounts::SYSTEM_ID)
            .unwrap();
        assert_eq!(snapshot.label.as_deref(), Some("5 giờ"));
        assert_eq!(snapshot.remaining_pct, Some(75));

        std::env::remove_var("BIRDNION_CONFIG");
        std::env::remove_var("CODEX_HOME");
        let _ = std::fs::remove_dir_all(base);
    }

    #[test]
    fn stale_same_account_auth_guard_blocks_snapshot_persistence() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = std::env::temp_dir().join(format!(
            "birdnion-codex-snapshot-cas-test-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(&base).unwrap();
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));
        let path = base.join("auth.json");
        let alice = br#"{"tokens":{"access_token":"alice","refresh_token":"alice-r"}}"#;
        let bob = br#"{"tokens":{"access_token":"bob","refresh_token":"bob-r"}}"#;
        std::fs::write(&path, alice).unwrap();
        let guarded = codex_accounts::read_auth_file_guarded(&path, MAX_AUTH_JSON_BYTES)
            .unwrap()
            .unwrap();
        let guard = AuthContentGuard {
            directory: guarded.directory.clone(),
            expected: alice.to_vec(),
            revision: guarded.revision,
        };
        std::fs::write(&path, bob).unwrap();
        let status = ProviderStatus {
            id: "codex".into(),
            display_name: "Codex".into(),
            windows: vec![QuotaWindow {
                label: "Tuần".into(),
                used_pct: 12,
                remaining_pct: 88,
                subtitle: None,
                resets_at: None,
                window_seconds: None,
                semantic_key: None,
                semantic_kind: None,
            }],
            last_updated: 456,
            ..Default::default()
        };
        let selection = codex_accounts::ActiveSelection {
            account_id: "same-managed-id".into(),
            auth_path: Some(path.clone()),
            auth_directory: Some(guard.directory.clone()),
        };
        save_bound_snapshot_if_current(&selection, &status, &guard);

        assert!(!auth_guard_is_current(&guard));
        assert!(codex_accounts::quota_snapshots().is_empty());
        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(base);
    }

    #[test]
    fn account_switch_midflight_cannot_redirect_auth_or_snapshot() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = std::env::temp_dir().join(format!(
            "birdnion-codex-fetch-binding-test-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&base);
        let codex_home = base.join("codex-home");
        std::fs::create_dir_all(&codex_home).unwrap();
        std::fs::write(
            codex_home.join("auth.json"),
            r#"{"tokens":{"access_token":"system","refresh_token":"system-r"}}"#,
        )
        .unwrap();
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));
        std::env::set_var("CODEX_HOME", &codex_home);

        let account_a = codex_accounts::promote_system().unwrap();
        let account_b = codex_accounts::promote_system().unwrap();
        let path_a =
            std::path::PathBuf::from(account_a.home_path.as_ref().unwrap()).join("auth.json");
        let path_b =
            std::path::PathBuf::from(account_b.home_path.as_ref().unwrap()).join("auth.json");
        std::fs::write(
            &path_a,
            r#"{"tokens":{"access_token":"a-old","refresh_token":"a-r"}}"#,
        )
        .unwrap();
        std::fs::write(
            &path_b,
            r#"{"tokens":{"access_token":"b-current","refresh_token":"b-r"}}"#,
        )
        .unwrap();
        codex_accounts::set_active(&account_a.id).unwrap();

        let started = tokio::sync::Notify::new();
        let proceed = tokio::sync::Notify::new();
        let selection = block_on(async {
            let fetch = async {
                let selection = codex_accounts::active_selection();
                let guarded = codex_accounts::read_auth_file_guarded_at(
                    selection.auth_directory.as_ref().unwrap(),
                    MAX_AUTH_JSON_BYTES,
                )
                .unwrap()
                .unwrap();
                started.notify_one();
                proceed.notified().await;

                let refreshed = Credentials {
                    access_token: "a-refreshed".into(),
                    refresh_token: "a-r-2".into(),
                    id_token: None,
                    account_id: Some("acct-a".into()),
                    last_refresh: Some(123),
                };
                let written =
                    save_bound_auth(&selection, &refreshed, &guarded.bytes, guarded.revision)
                        .unwrap()
                        .expect("captured account A remains writable after selecting B");
                let auth_guard = AuthContentGuard {
                    directory: guarded.directory,
                    expected: written,
                    revision: guarded.revision,
                };
                let status = ProviderStatus {
                    id: "codex".into(),
                    display_name: "Codex".into(),
                    windows: vec![QuotaWindow {
                        label: "Tuần".into(),
                        used_pct: 12,
                        remaining_pct: 88,
                        subtitle: None,
                        resets_at: None,
                        window_seconds: None,
                        semantic_key: None,
                        semantic_kind: None,
                    }],
                    last_updated: 456,
                    ..Default::default()
                };
                assert!(save_bound_snapshot_if_current(
                    &selection,
                    &status,
                    &auth_guard,
                ));
                selection
            };
            let switch = async {
                started.notified().await;
                codex_accounts::set_active(&account_b.id).unwrap();
                proceed.notify_one();
            };
            let (selection, ()) = futures::join!(fetch, switch);
            selection
        });

        assert_eq!(selection.account_id, account_a.id);
        assert_eq!(
            std::fs::canonicalize(selection.auth_path.as_ref().unwrap()).unwrap(),
            std::fs::canonicalize(&path_a).unwrap(),
        );
        assert_eq!(codex_accounts::active_id(), account_b.id);
        assert_eq!(
            parse_auth_json(&std::fs::read_to_string(&path_a).unwrap())
                .unwrap()
                .access_token,
            "a-refreshed"
        );
        assert_eq!(
            parse_auth_json(&std::fs::read_to_string(&path_b).unwrap())
                .unwrap()
                .access_token,
            "b-current"
        );
        let snapshots = codex_accounts::quota_snapshots();
        assert_eq!(
            snapshots
                .get(&account_a.id)
                .and_then(|item| item.remaining_pct),
            Some(88)
        );
        assert!(!snapshots.contains_key(&account_b.id));

        std::env::remove_var("BIRDNION_CONFIG");
        std::env::remove_var("CODEX_HOME");
        let _ = std::fs::remove_dir_all(base);
    }

    #[test]
    fn maps_primary_and_secondary_windows() {
        let body = json!({
            "rate_limit": {
                "primary_window": {"used_percent": 42, "reset_at": 1_800_000_000, "limit_window_seconds": 300 * 60},
                "secondary_window": {"used_percent": 10, "reset_at": 1_800_500_000, "limit_window_seconds": 10080 * 60},
            }
        });
        let windows = map_windows(&body);
        assert_eq!(windows.len(), 2);
        assert_eq!(windows[0].label, "5 giờ");
        assert_eq!(windows[0].used_pct, 42);
        assert_eq!(windows[1].label, "Tuần");
        assert_eq!(windows[1].used_pct, 10);
    }

    #[test]
    fn normalizer_swaps_when_api_reports_weekly_as_primary() {
        let body = json!({
            "rate_limit": {
                "primary_window": {"used_percent": 5, "reset_at": 1, "limit_window_seconds": 10080 * 60},
                "secondary_window": {"used_percent": 90, "reset_at": 2, "limit_window_seconds": 300 * 60},
            }
        });
        let windows = map_windows(&body);
        assert_eq!(windows[0].label, "5 giờ");
        assert_eq!(windows[0].used_pct, 90);
        assert_eq!(windows[1].label, "Tuần");
        assert_eq!(windows[1].used_pct, 5);
    }

    #[test]
    fn maps_spark_additional_rate_limits() {
        let body = json!({
            "rate_limit": {"primary_window": {"used_percent": 1, "reset_at": 1, "limit_window_seconds": 300 * 60}},
            "additional_rate_limits": [
                {
                    "metered_feature": "codex-spark",
                    "rate_limit": {
                        "primary_window": {"used_percent": 20, "reset_at": 1, "limit_window_seconds": 300 * 60},
                        "secondary_window": {"used_percent": 30, "reset_at": 2, "limit_window_seconds": 10080 * 60},
                    }
                }
            ]
        });
        let windows = map_windows(&body);
        assert_eq!(windows.len(), 3);
        assert_eq!(windows[1].label, "Codex Spark 5 giờ");
        assert_eq!(windows[2].label, "Codex Spark Tuần");
    }

    #[test]
    fn empty_windows_payload_returns_no_windows() {
        assert!(map_windows(&json!({})).is_empty());
    }

    #[test]
    fn credentials_missing_access_token_errors() {
        let raw = r#"{"tokens":{"refresh_token":"rt"}}"#;
        assert!(parse_auth_json(raw).is_err());
    }

    #[test]
    fn credits_balance_reads_dashboard_payload_shape() {
        let body = json!({"credits": {"has_credits": true, "unlimited": false, "balance": 12.5}});
        assert_eq!(credits_balance(&body), Some(12.5));
    }

    #[test]
    fn credits_balance_missing_or_malformed_is_none() {
        assert_eq!(credits_balance(&json!({})), None);
        assert_eq!(
            credits_balance(&json!({"credits": {"unlimited": true}})),
            None
        );
    }

    #[test]
    fn cookie_dashboard_payload_maps_windows_and_credits() {
        // Same `wham/usage` shape as the OAuth path, just fetched via cookie auth.
        let body = json!({
            "rate_limit": {
                "primary_window": {"used_percent": 15, "reset_at": 100, "limit_window_seconds": 300 * 60},
                "secondary_window": {"used_percent": 40, "reset_at": 200, "limit_window_seconds": 10080 * 60},
            },
            "credits": {"has_credits": true, "unlimited": false, "balance": 3.25}
        });
        let windows = map_windows(&body);
        assert_eq!(windows.len(), 2);
        assert_eq!(windows[0].used_pct, 15);
        assert_eq!(credits_balance(&body), Some(3.25));
    }

    #[test]
    fn dashboard_extras_reads_email_and_purchase_url() {
        let body = json!({
            "email": "user@example.com",
            "credits": {
                "balance": 3.25,
                "purchase_url": "https://platform.openai.com/settings/organization/billing",
                "credit_events": [{"amount": 5.0}, {"amount": -1.75}]
            }
        });
        let extras = dashboard_extras(&body);
        assert_eq!(extras.signed_in_email, Some("user@example.com".to_string()));
        assert_eq!(
            extras.credits_purchase_url,
            Some("https://platform.openai.com/settings/organization/billing".to_string())
        );
        assert_eq!(extras.credits_history_count, Some(2));
    }

    #[test]
    fn dashboard_extras_missing_fields_are_none() {
        let extras = dashboard_extras(&json!({}));
        assert!(extras.signed_in_email.is_none());
        assert!(extras.credits_purchase_url.is_none());
        assert!(extras.credits_history_count.is_none());

        let extras_empty_events = dashboard_extras(&json!({"credits": {"credit_events": []}}));
        assert!(extras_empty_events.credits_history_count.is_none());
    }
}
