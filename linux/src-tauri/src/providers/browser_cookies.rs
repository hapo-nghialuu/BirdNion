//! Shared browser-cookie helper for the cookie-based quota providers
//! (OpenCode, OpenCodeGo, CommandCode, Cursor, MiMo, Alibaba, Freemodel,
//! Copilot budget scrape). Ports `ProviderCookieReader` from the macOS app
//! using the `rookie` crate for cross-platform (Chrome/Chromium/Brave/Edge/
//! Firefox) cookie-store extraction — including Linux keyring decryption.
//!
//! `cfg.cookie_source` controls the resolution strategy:
//!   - "manual" → use `cfg.manual_cookie` verbatim.
//!   - "off"    → error immediately (user disabled cookie-based auth).
//!   - anything else (default "auto") → scan browsers in a fixed order and
//!     return the first non-empty cookie set for the given domains.
//!
//! `rookie` calls hit disk (SQLite files, OS keyrings) and are blocking —
//! callers MUST invoke `cookie_header` from a `spawn_blocking` context.

use crate::config;

/// Order mirrors the Swift `ProviderCookieReader`'s default browser scan —
/// Chrome-family first, Firefox last (it's the slowest / needs profile scan).
const BROWSER_ORDER: &[&str] = &["chrome", "chromium", "brave", "edge", "firefox"];

/// Resolve the `Cookie:` header value for the given domains, honoring the
/// provider's configured cookie source. Blocking — see module docs.
pub fn cookie_header(domains: &[&str], cfg: &config::Provider) -> Result<String, String> {
    cookie_header_required(domains, cfg, None)
}

/// Like [`cookie_header`], but in auto mode only accepts a browser whose
/// cookie set contains `required_cookie` — macOS `resolvedCookieHeader(...,
/// requiredCookie:)` parity: a browser holding only stale analytics/Stripe
/// cookies for the domain must not shadow the browser the user actually
/// signed in with.
pub fn cookie_header_required(
    domains: &[&str],
    cfg: &config::Provider,
    required_cookie: Option<&str>,
) -> Result<String, String> {
    match cfg.cookie_source.as_deref() {
        Some("manual") => {
            let manual = cfg.manual_cookie.as_deref().unwrap_or("").trim();
            if manual.is_empty() {
                Err("Chưa dán cookie thủ công".to_string())
            } else {
                Ok(manual.to_string())
            }
        }
        Some("off") => Err("Đã tắt nguồn cookie".to_string()),
        _ => auto_cookie_header(domains, required_cookie),
    }
}

/// Scans supported browsers in order, returning the first cookie set for
/// `domains` that is non-empty (and contains `required_cookie` when given).
/// Only a genuine per-browser error (not "no cookies") is surfaced if every
/// browser fails to produce cookies.
fn auto_cookie_header(domains: &[&str], required_cookie: Option<&str>) -> Result<String, String> {
    let domain_list: Vec<String> = domains.iter().map(|d| d.to_string()).collect();
    let mut last_error: Option<String> = None;

    for browser in BROWSER_ORDER {
        let result = read_browser(browser, domain_list.clone());
        match result {
            Ok(cookies) if !cookies.is_empty() => {
                if let Some(required) = required_cookie {
                    if !cookies.iter().any(|c| c.name == required) {
                        continue; // keep scanning — this browser isn't signed in
                    }
                }
                let header = cookies
                    .iter()
                    .map(|c| format!("{}={}", c.name, c.value))
                    .collect::<Vec<_>>()
                    .join("; ");
                if !header.is_empty() {
                    return Ok(header);
                }
            }
            Ok(_) => {}
            Err(e) => last_error = Some(e),
        }
    }

    match last_error {
        Some(e) => Err(format!("Không đọc được cookie trình duyệt: {e}")),
        None => Err("Không tìm thấy cookie đăng nhập trong trình duyệt".to_string()),
    }
}

/// Every browser (scan order) whose cookie set for `domains` contains
/// `required_cookie`, as `(browser_id, header)` pairs — lets multi-account
/// UIs surface "Chrome" and "Brave" sessions as separate accounts. Blocking.
pub fn browsers_with_cookie(domains: &[&str], required_cookie: &str) -> Vec<(&'static str, String)> {
    let domain_list: Vec<String> = domains.iter().map(|d| d.to_string()).collect();
    let mut out = Vec::new();
    for browser in BROWSER_ORDER {
        let Ok(cookies) = read_browser(browser, domain_list.clone()) else { continue };
        if cookies.is_empty() || !cookies.iter().any(|c| c.name == required_cookie) {
            continue;
        }
        let header = cookies
            .iter()
            .map(|c| format!("{}={}", c.name, c.value))
            .collect::<Vec<_>>()
            .join("; ");
        out.push((*browser, header));
    }
    out
}

/// Cookie header from ONE specific browser, gated on `required_cookie`.
/// Blocking — see module docs.
pub fn single_browser_cookie_header(
    browser: &str,
    domains: &[&str],
    required_cookie: &str,
) -> Result<String, String> {
    let domain_list: Vec<String> = domains.iter().map(|d| d.to_string()).collect();
    let cookies = read_browser(browser, domain_list)?;
    if cookies.is_empty() || !cookies.iter().any(|c| c.name == required_cookie) {
        return Err(format!("Không tìm thấy cookie đăng nhập trong {browser}"));
    }
    Ok(cookies
        .iter()
        .map(|c| format!("{}={}", c.name, c.value))
        .collect::<Vec<_>>()
        .join("; "))
}

fn read_browser(browser: &str, domains: Vec<String>) -> Result<Vec<rookie::enums::Cookie>, String> {
    let domains = Some(domains);
    let result = match browser {
        "chrome" => rookie::chrome(domains),
        "chromium" => rookie::chromium(domains),
        "brave" => rookie::brave(domains),
        "edge" => rookie::edge(domains),
        "firefox" => rookie::firefox(domains),
        other => return Err(format!("Trình duyệt không hỗ trợ: {other}")),
    };
    result.map_err(|e| e.to_string())
}
