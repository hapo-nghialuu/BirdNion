//! FreeModel quota provider — port of `FreemodelProvider.swift`.
//!
//! Session cookie is Akamai's `bm_session`. Endpoints (base
//! `https://freemodel.dev`):
//!   GET /api/usage    (required) -> { "window5h": {...}, "windowWeek": {...} }
//!   GET /api/auth/me  (best-effort, not required for the quota windows)
//!   GET /api/referral + /api/billing (best-effort) -> "Số dư" bonus window
//!     mirroring the dashboard's "Current balance" card

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;
use std::path::PathBuf;
use std::time::Duration;

use crate::providers::browser_cookies;
use crate::providers::{display_name, ProviderStatus, QuotaWindow};

const USAGE_URL: &str = "https://freemodel.dev/api/usage";
const ME_URL: &str = "https://freemodel.dev/api/auth/me";
const REFERRAL_URL: &str = "https://freemodel.dev/api/referral";
const BILLING_URL: &str = "https://freemodel.dev/api/billing";
/// Akamai bot-manager session cookie the budgets are gated on. Passed as the
/// REQUIRED cookie so the browser scan skips browsers that only hold stale
/// analytics/Stripe cookies and keeps looking for the signed-in one (macOS
/// `ProviderCookieReader.resolvedCookieHeader(requiredCookie:)` parity).
const SESSION_COOKIE: &str = "bm_session";
/// freemodel.dev sits behind Akamai — send browser-like headers or the
/// session cookie is rejected (macOS sends the same set).
const USER_AGENT: &str = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 \
    (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36";
const ORIGIN: &str = "https://freemodel.dev";
const REFERER: &str = "https://freemodel.dev/dashboard/usage";
const BONUS_TIMEOUT: Duration = Duration::from_secs(10);
const BALANCE_CACHE_FILENAME: &str = "freemodel-balance-cache.json";
const BALANCE_CACHE_TTL_SECS: i64 = 48 * 3600;

pub async fn fetch(cfg: &crate::config::Provider) -> ProviderStatus {
    let name = display_name(cfg);
    let id = cfg.id.clone();
    let cfg_clone = cfg.clone();

    // Multi-account resolution order: a managed account's stored cookie →
    // a pinned `browser:<name>` entry's live scan of THAT browser → the
    // default all-browser scan.
    let raw_header = match crate::freemodel_accounts::active_cookie() {
        Some(stored) => stored,
        None => {
            let pinned_browser = crate::freemodel_accounts::active_browser();
            let scan = tauri::async_runtime::spawn_blocking(move || match pinned_browser {
                Some(browser) => browser_cookies::single_browser_cookie_header(
                    &browser,
                    &["freemodel.dev"],
                    SESSION_COOKIE,
                ),
                None => browser_cookies::cookie_header_required(
                    &["freemodel.dev"],
                    &cfg_clone,
                    Some(SESSION_COOKIE),
                ),
            })
            .await;
            match scan {
                Ok(Ok(h)) => h,
                Ok(Err(_)) => return ProviderStatus::failure(&id, &name, "Chưa đăng nhập FreeModel trên trình duyệt"),
                Err(_) => return ProviderStatus::failure(&id, &name, "Lỗi nội bộ khi đọc cookie"),
            }
        }
    };

    let Some(cookie_header) = filtered_cookie_header(&raw_header) else {
        return ProviderStatus::failure(&id, &name, "Chưa đăng nhập FreeModel trên trình duyệt");
    };

    let client = crate::providers::shared_client();
    let resp = browser_get(&client, USAGE_URL, &cookie_header).send().await;

    let body = match resp {
        Ok(r) if r.status().is_success() => match r.text().await {
            Ok(t) => t,
            Err(e) => return ProviderStatus::failure(&id, &name, format!("Network: {e}")),
        },
        Ok(r) => return ProviderStatus::failure(&id, &name, format!("Network: HTTP {}", r.status().as_u16())),
        Err(e) => return ProviderStatus::failure(&id, &name, format!("Network: {e}")),
    };

    let mut status = match parse_status(&id, &name, &body) {
        Ok(status) => status,
        Err(e) => return ProviderStatus::failure(&id, &name, e),
    };
    // Account email + bonus balance — best-effort enrichment, never blocks
    // the budgets.
    status.account_label = match cfg.account_label.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
        Some(explicit) => Some(explicit.to_string()),
        None => fetch_email(&client, &cookie_header).await,
    };
    let (referral, billing) = futures::join!(
        optional_json(&client, REFERRAL_URL, &cookie_header, BONUS_TIMEOUT),
        optional_json(&client, BILLING_URL, &cookie_header, BONUS_TIMEOUT),
    );
    append_balance_window(
        &mut status.windows,
        balance_window(referral.as_ref(), billing.as_ref()),
        chrono::Utc::now().timestamp(),
    );
    status
}

/// Best-effort GET → JSON with the caller's timeout; None on any failure.
async fn optional_json(
    client: &reqwest::Client,
    url: &str,
    cookie_header: &str,
    timeout: Duration,
) -> Option<Value> {
    let resp = browser_get(client, url, cookie_header)
        .timeout(timeout)
        .send()
        .await
        .ok()?;
    if !resp.status().is_success() {
        return None;
    }
    resp.json().await.ok()
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct PersistedBalance {
    window: QuotaWindow,
    saved_at: i64,
}

#[derive(Deserialize, Serialize, Default)]
struct StoredBalances {
    #[serde(default)]
    accounts: HashMap<String, PersistedBalance>,
}

fn balance_cache_path() -> Option<PathBuf> {
    crate::config::support_dir().map(|path| path.join(BALANCE_CACHE_FILENAME))
}

fn load_stored_balances() -> StoredBalances {
    balance_cache_path()
        .and_then(|path| std::fs::read_to_string(path).ok())
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

fn persist_balance_window(window: &QuotaWindow, saved_at: i64) -> Result<(), String> {
    let path = balance_cache_path()
        .ok_or_else(|| "Không xác định được thư mục cấu hình".to_string())?;
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    let mut stored = load_stored_balances();
    stored.accounts.insert(
        crate::freemodel_accounts::active_id(),
        PersistedBalance { window: window.clone(), saved_at },
    );
    let json = serde_json::to_string_pretty(&stored).map_err(|e| e.to_string())?;
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, json).map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600));
    }
    std::fs::rename(&tmp, &path).map_err(|e| e.to_string())
}

fn persisted_balance_window(now: i64) -> Option<QuotaWindow> {
    let entry = load_stored_balances()
        .accounts
        .remove(&crate::freemodel_accounts::active_id())?;
    (now - entry.saved_at < BALANCE_CACHE_TTL_SECS).then_some(entry.window)
}

fn stale_balance_window(window: QuotaWindow) -> QuotaWindow {
    QuotaWindow {
        subtitle: Some(match window.subtitle {
            Some(subtitle) => format!("{subtitle} · số cũ"),
            None => "số cũ".to_string(),
        }),
        ..window
    }
}

fn append_balance_window(windows: &mut Vec<QuotaWindow>, balance: Option<QuotaWindow>, now: i64) {
    if let Some(balance) = balance {
        // A referral-only response renders live as used/used, but must not
        // replace the last complete snapshot used after a restart.
        if balance.remaining_pct > 0 {
            let _ = persist_balance_window(&balance, now);
        }
        windows.push(balance);
    } else if let Some(balance) = persisted_balance_window(now) {
        windows.push(stale_balance_window(balance));
    }
}

/// Dashboard "Current balance" (§ Extra usage). 2026 schema: referral
/// `credits` is always 0 — the remaining bonus lives in billing
/// `creditCents` (`signupCreditCents` mirrors it and was the legacy
/// signup-credit field). remaining = referral credits + billing credit;
/// total = remaining + `used` (matches the web card's "$used / $total").
/// Renders from referral alone when billing is missing — billing tops the
/// total up when it answers. None when nothing was earned.
fn balance_window(referral: Option<&Value>, billing: Option<&Value>) -> Option<QuotaWindow> {
    let referral = referral?;
    let credits = referral.get("credits").and_then(Value::as_f64).unwrap_or(0.0);
    let used = referral.get("used").and_then(Value::as_f64).unwrap_or(0.0);
    let count = referral.get("count").and_then(Value::as_i64).unwrap_or(0);
    let billing_usd = billing
        .and_then(|b| b.get("creditCents").or_else(|| b.get("signupCreditCents")))
        .and_then(Value::as_f64)
        .unwrap_or(0.0)
        / 100.0;

    let remaining = credits + billing_usd;
    let total = remaining + used;
    if total <= 0.0 {
        return None;
    }
    let pct = (used / total * 100.0).round().clamp(0.0, 100.0) as i32;
    let mut subtitle = format!("${used:.2} / ${total:.2}");
    if count > 0 {
        subtitle += &format!(" · {count} giới thiệu");
    }
    Some(QuotaWindow { semantic_key: None, semantic_kind: None,
        label: "Số dư".to_string(),
        used_pct: pct,
        remaining_pct: 100 - pct,
        subtitle: Some(subtitle),
        resets_at: None,
        window_seconds: None,
    })
}

/// GET with the browser-like header set freemodel/Akamai expects.
fn browser_get(client: &reqwest::Client, url: &str, cookie_header: &str) -> reqwest::RequestBuilder {
    client
        .get(url)
        .header("Cookie", cookie_header)
        .header("Accept", "application/json, text/plain, */*")
        .header("Accept-Language", "en-US,en;q=0.9")
        .header("User-Agent", USER_AGENT)
        .header("Origin", ORIGIN)
        .header("Referer", REFERER)
}

/// `/api/auth/me` → `{ "user": { "email": … } }` — 5s budget like macOS.
/// `pub(crate)`: the add-account command uses it to validate + label a
/// pasted cookie.
pub(crate) async fn fetch_email(client: &reqwest::Client, cookie_header: &str) -> Option<String> {
    let resp = browser_get(client, ME_URL, cookie_header)
        .timeout(std::time::Duration::from_secs(5))
        .send()
        .await
        .ok()?;
    if !resp.status().is_success() {
        return None;
    }
    let body: Value = resp.json().await.ok()?;
    body.get("user")
        .and_then(|u| u.get("email"))
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(String::from)
}

/// Tolerates a full `"Cookie: ..."` line prefix (case-insensitive); a bare
/// token (no `=`) wraps as `bm_session=<token>`; otherwise forwards ALL
/// cookie pairs, gated on `bm_session` being present. `pub(crate)` so the
/// add-account command normalizes pasted cookies through the same rules.
pub(crate) fn filtered_cookie_header(raw: &str) -> Option<String> {
    let stripped = strip_cookie_prefix(raw.trim());
    if stripped.is_empty() {
        return None;
    }
    if !stripped.contains('=') {
        return Some(format!("bm_session={stripped}"));
    }

    let has_session = stripped.split(';').any(|chunk| {
        let t = chunk.trim();
        t.split('=').next().map(|n| n.trim().eq_ignore_ascii_case("bm_session")).unwrap_or(false)
    });

    if has_session {
        Some(stripped.to_string())
    } else {
        None
    }
}

fn strip_cookie_prefix(s: &str) -> &str {
    let lower = s.to_lowercase();
    if let Some(rest) = lower.strip_prefix("cookie:") {
        s[s.len() - rest.len()..].trim()
    } else {
        s
    }
}

fn parse_status(id: &str, name: &str, body: &str) -> Result<ProviderStatus, String> {
    let v: Value = serde_json::from_str(body).map_err(|_| "Response /api/usage không hợp lệ".to_string())?;

    let mut windows = Vec::new();
    if let Some(w5h) = v.get("window5h") {
        windows.push(cents_window("5 giờ", w5h)?);
    }
    if let Some(week) = v.get("windowWeek") {
        windows.push(cents_window("Tuần", week)?);
    }

    if windows.is_empty() {
        return Err("Response /api/usage không hợp lệ".to_string());
    }

    Ok(ProviderStatus {
        id: id.to_string(),
        display_name: name.to_string(),
        windows,
        last_updated: chrono::Utc::now().timestamp(),
        ..Default::default()
    })
}

fn cents_window(label: &str, window: &Value) -> Result<QuotaWindow, String> {
    let used_cents = window.get("usedCents").and_then(Value::as_f64).ok_or_else(|| "Response /api/usage không hợp lệ".to_string())?;
    let limit_cents = window.get("limitCents").and_then(Value::as_f64).ok_or_else(|| "Response /api/usage không hợp lệ".to_string())?;
    let resets_at = window.get("resetsAt").and_then(Value::as_i64).filter(|&t| t != 0);

    let used_usd = used_cents / 100.0;
    let limit_usd = limit_cents / 100.0;
    let pct = if limit_usd > 0.0 { (used_usd / limit_usd * 100.0).round().clamp(0.0, 100.0) as i32 } else { 0 };

    // Window lengths are fixed by the product (5h + weekly) — drives the
    // settings pace line, macOS windowSeconds parity.
    let window_seconds = match label {
        "5 giờ" => Some(5 * 3600),
        "Tuần" => Some(7 * 24 * 3600),
        _ => None,
    };
    Ok(QuotaWindow { semantic_key: None, semantic_kind: None,
        label: label.to_string(),
        used_pct: pct,
        remaining_pct: 100 - pct,
        subtitle: Some(format!("${used_usd:.2} / ${limit_usd:.2}")),
        resets_at,
        window_seconds,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::TEST_ENV_LOCK as ENV_LOCK;

    fn temp_config(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "birdnion-freemodel-balance-{tag}-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn balance(remaining_pct: i32) -> QuotaWindow {
        QuotaWindow {
            label: "Số dư".to_string(),
            used_pct: 100 - remaining_pct,
            remaining_pct,
            subtitle: Some("$67.22 / $187.84 · 8 giới thiệu".to_string()),
            resets_at: None,
            window_seconds: None,
            semantic_key: None,
            semantic_kind: None,
        }
    }

    #[test]
    fn parses_both_windows() {
        let body = r#"{"window5h":{"usedCents":2250,"limitCents":20000,"resetsAt":1782724407},"windowWeek":{"usedCents":8,"limitCents":132000,"resetsAt":1783321795}}"#;
        let status = parse_status("freemodel", "FreeModel", body).unwrap();
        assert_eq!(status.windows.len(), 2);
        assert_eq!(status.windows[0].label, "5 giờ");
        assert_eq!(status.windows[1].label, "Tuần");
    }

    #[test]
    fn zero_resets_at_becomes_none() {
        let body = r#"{"window5h":{"usedCents":100,"limitCents":1000,"resetsAt":0}}"#;
        let status = parse_status("freemodel", "FreeModel", body).unwrap();
        assert!(status.windows[0].resets_at.is_none());
    }

    #[test]
    fn balance_window_from_referral_and_billing() {
        let referral: Value =
            serde_json::from_str(r#"{"code":"x","count":8,"credits":100.62,"used":67.22}"#).unwrap();
        let billing: Value = serde_json::from_str(r#"{"signupCreditCents":2000}"#).unwrap();
        let w = balance_window(Some(&referral), Some(&billing)).unwrap();
        assert_eq!(w.label, "Số dư");
        assert_eq!(w.subtitle.as_deref(), Some("$67.22 / $187.84 · 8 giới thiệu"));
        assert_eq!(w.used_pct, 36);

        // No referral payload → no window; zero balance → hidden.
        assert!(balance_window(None, Some(&billing)).is_none());
        let zero: Value = serde_json::from_str(r#"{"count":0,"credits":0,"used":0}"#).unwrap();
        assert!(balance_window(Some(&zero), None).is_none());
    }

    #[test]
    fn balance_window_2026_schema_credit_cents() {
        // 2026 schema: referral.credits is always 0 — the remaining bonus
        // lives in billing.creditCents. Live capture: $189.79 used +
        // creditCents 13373 → "$189.79 / $323.52".
        let referral: Value =
            serde_json::from_str(r#"{"code":"x","count":8,"credits":0,"used":189.79}"#).unwrap();
        let billing: Value =
            serde_json::from_str(r#"{"creditCents":13373,"signupCreditCents":13373}"#).unwrap();
        let w = balance_window(Some(&referral), Some(&billing)).unwrap();
        assert_eq!(w.subtitle.as_deref(), Some("$189.79 / $323.52 · 8 giới thiệu"));
        assert_eq!(w.used_pct, 59);

        // Billing timed out: referral-only figure still renders (used/used).
        let w = balance_window(Some(&referral), None).unwrap();
        assert_eq!(w.subtitle.as_deref(), Some("$189.79 / $189.79 · 8 giới thiệu"));
        assert_eq!(w.used_pct, 100);
    }

    #[test]
    fn invalid_json_is_error() {
        assert!(parse_status("freemodel", "FreeModel", "not json").is_err());
    }

    #[test]
    fn bare_token_wraps_as_bm_session() {
        assert_eq!(filtered_cookie_header("abc123").unwrap(), "bm_session=abc123");
    }

    #[test]
    fn strips_cookie_prefix_line() {
        let header = filtered_cookie_header("Cookie: bm_session=xyz; other=1").unwrap();
        assert!(header.starts_with("bm_session=xyz"));
    }

    #[test]
    fn missing_bm_session_returns_none() {
        assert!(filtered_cookie_header("foo=bar; baz=qux").is_none());
    }

    #[test]
    fn persisted_balance_round_trips() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config("roundtrip");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));

        let original = balance(64);
        persist_balance_window(&original, 1_000).unwrap();
        let restored = persisted_balance_window(1_001).unwrap();
        assert_eq!(restored.label, original.label);
        assert_eq!(restored.used_pct, original.used_pct);
        assert_eq!(restored.remaining_pct, original.remaining_pct);
        assert_eq!(restored.subtitle, original.subtitle);

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn persisted_balance_expires_at_48_hours() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config("expiry");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));

        let saved_at = 1_000;
        persist_balance_window(&balance(64), saved_at).unwrap();
        assert!(persisted_balance_window(saved_at + BALANCE_CACHE_TTL_SECS - 1).is_some());
        assert!(persisted_balance_window(saved_at + BALANCE_CACHE_TTL_SECS).is_none());

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn incomplete_balance_is_not_persisted() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config("incomplete");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));

        let mut windows = Vec::new();
        append_balance_window(&mut windows, Some(balance(0)), 1_000);
        assert_eq!(windows.len(), 1);
        assert!(persisted_balance_window(1_000).is_none());

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn persisted_balances_are_keyed_by_active_account() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config("accounts");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));

        crate::freemodel_accounts::set_active("account-a").unwrap();
        persist_balance_window(&balance(64), 1_000).unwrap();
        crate::freemodel_accounts::set_active("account-b").unwrap();
        assert!(persisted_balance_window(1_001).is_none());
        persist_balance_window(&balance(35), 1_002).unwrap();

        crate::freemodel_accounts::set_active("account-a").unwrap();
        assert_eq!(persisted_balance_window(1_003).unwrap().remaining_pct, 64);
        crate::freemodel_accounts::set_active("account-b").unwrap();
        assert_eq!(persisted_balance_window(1_003).unwrap().remaining_pct, 35);

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn fallback_marks_balance_as_stale_once() {
        let _guard = ENV_LOCK.lock().unwrap();
        let base = temp_config("stale-marker");
        std::env::set_var("BIRDNION_CONFIG", base.join("settings.json"));

        persist_balance_window(&balance(64), 1_000).unwrap();
        let mut windows = Vec::new();
        append_balance_window(&mut windows, None, 1_001);
        append_balance_window(&mut windows, None, 1_002);
        for window in windows {
            assert_eq!(
                window.subtitle.as_deref(),
                Some("$67.22 / $187.84 · 8 giới thiệu · số cũ")
            );
            assert_eq!(window.subtitle.unwrap().matches("số cũ").count(), 1);
        }

        std::env::remove_var("BIRDNION_CONFIG");
        let _ = std::fs::remove_dir_all(&base);
    }
}
