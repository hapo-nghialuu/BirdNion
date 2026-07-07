//! Pure error classifier — Rust mirror of the macOS `ProviderErrorClassifier`.
//! Maps a raw provider error string to exactly one `ProviderErrorKind`. No
//! I/O, no dependencies on other provider modules.

/// Actionable classification of a provider's raw error string.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProviderErrorKind {
    /// Browser session cookie missing/expired -> re-login browser.
    CookieExpiredOrMissing,
    /// API key / OAuth token missing/wrong/expired -> re-paste token.
    TokenInvalidOrMissing,
    /// Unexpected/invalid response shape or 5xx -> app may need update.
    ApiSchemaChanged,
    /// Network down / timeout -> check connection, retry.
    NetworkUnreachableOrTimeout,
    /// HTTP 429 / rate-limit -> wait and retry.
    RateLimited,
    /// Unmatched -> show detail.
    Unknown,
}

impl ProviderErrorKind {
    /// camelCase suffix used to build the frontend i18n keys
    /// `providerError.<suffix>.title` / `.hint`.
    pub fn key_suffix(&self) -> &'static str {
        match self {
            Self::CookieExpiredOrMissing => "cookieExpiredOrMissing",
            Self::TokenInvalidOrMissing => "tokenInvalidOrMissing",
            Self::ApiSchemaChanged => "apiSchemaChanged",
            Self::NetworkUnreachableOrTimeout => "networkUnreachableOrTimeout",
            Self::RateLimited => "rateLimited",
            Self::Unknown => "unknown",
        }
    }
}

/// Pure classifier: maps a raw provider error string to exactly one kind.
/// Returns `None` when there is no error to classify (`None`/empty/whitespace).
///
/// PRECEDENCE (fixed invariant — order of checks matters):
///   1. None/empty            -> None
///   2. cookie marker         -> CookieExpiredOrMissing (beats 401/403)
///   3. 429 / rate-limit      -> RateLimited (beats 401/403)
///   4. timeout/network       -> NetworkUnreachableOrTimeout (beats schema)
///   5. 401/403 / token       -> TokenInvalidOrMissing
///   6. invalid-response/5xx  -> ApiSchemaChanged
///   7. otherwise             -> Unknown
///
/// Matching is case-insensitive substring/code containment over the raw
/// string, intentionally bilingual (vi/en) and ad-hoc across providers.
pub fn classify(raw: Option<&str>) -> Option<ProviderErrorKind> {
    let raw = raw?;
    if raw.trim().is_empty() {
        return None;
    }
    let s = raw.to_lowercase();
    let codes = http_codes(&s);

    const COOKIE_MARKERS: &[&str] = &["cookie", "session cookie", "sessionkey", "__host-auth", "cần auth"];
    const RATE_MARKERS: &[&str] = &["rate limit", "too many", "quá nhiều"];
    const NETWORK_MARKERS: &[&str] = &["timeout", "network", "mạng", "offline", "could not connect"];
    const TOKEN_MARKERS: &[&str] = &["token", "api key", "unauthorized", "chưa cấu hình", "hết hạn"];
    const SCHEMA_MARKERS: &[&str] = &[
        "không hợp lệ",
        "invalid",
        "thiếu trường",
        "missing field",
        "parse",
        "json",
        "không nhận ra",
        "không có model",
    ];

    if COOKIE_MARKERS.iter().any(|m| s.contains(m)) {
        return Some(ProviderErrorKind::CookieExpiredOrMissing);
    }
    if RATE_MARKERS.iter().any(|m| s.contains(m)) || codes.contains(&429) {
        return Some(ProviderErrorKind::RateLimited);
    }
    if NETWORK_MARKERS.iter().any(|m| s.contains(m)) {
        return Some(ProviderErrorKind::NetworkUnreachableOrTimeout);
    }
    if TOKEN_MARKERS.iter().any(|m| s.contains(m)) || codes.contains(&401) || codes.contains(&403) {
        return Some(ProviderErrorKind::TokenInvalidOrMissing);
    }
    if SCHEMA_MARKERS.iter().any(|m| s.contains(m)) || codes.iter().any(|&c| (500..600).contains(&c)) {
        return Some(ProviderErrorKind::ApiSchemaChanged);
    }
    Some(ProviderErrorKind::Unknown)
}

/// Extracts HTTP status codes that appear in an HTTP context only: "http NNN",
/// "(NNN)", "status NNN", or a standalone 3-digit token. Digits embedded in a
/// longer run or decimal ("5000 tokens", "0.140.0", "429ms") are NOT codes.
///
/// Implemented without a regex crate: scan each contiguous digit run and
/// accept it as a code when either (a) it is exactly 3 digits with no
/// adjacent digit/dot/letter on either side, or (b) it is immediately
/// preceded by "http ", "status ", or "(".
fn http_codes(lowercased: &str) -> Vec<u32> {
    let bytes = lowercased.as_bytes();
    let len = bytes.len();
    let mut codes = Vec::new();

    let mut i = 0;
    while i < len {
        if bytes[i].is_ascii_digit() {
            let start = i;
            let mut j = i;
            while j < len && bytes[j].is_ascii_digit() {
                j += 1;
            }
            let run_len = j - start;

            let prev_is_word_or_dot = start > 0
                && (bytes[start - 1] == b'.' || bytes[start - 1].is_ascii_alphanumeric());
            let next_is_word_or_dot =
                j < len && (bytes[j] == b'.' || bytes[j].is_ascii_alphanumeric());
            let standalone = run_len == 3 && !prev_is_word_or_dot && !next_is_word_or_dot;

            let http_context = ["http ", "status ", "("]
                .iter()
                .any(|kw| start >= kw.len() && &lowercased[start - kw.len()..start] == *kw);

            if run_len == 3 && (standalone || http_context) {
                if let Ok(code) = lowercased[start..j].parse::<u32>() {
                    if (100..600).contains(&code) {
                        codes.push(code);
                    }
                }
            }
            i = j;
        } else {
            i += 1;
        }
    }

    codes
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn none_on_none() {
        assert_eq!(classify(None), None);
    }

    #[test]
    fn none_on_empty_or_whitespace() {
        assert_eq!(classify(Some("")), None);
        assert_eq!(classify(Some("   ")), None);
    }

    #[test]
    fn cookie_marker() {
        assert_eq!(classify(Some("Session cookie expired")), Some(ProviderErrorKind::CookieExpiredOrMissing));
    }

    #[test]
    fn token_marker() {
        assert_eq!(classify(Some("Invalid token provided")), Some(ProviderErrorKind::TokenInvalidOrMissing));
    }

    #[test]
    fn schema_marker() {
        assert_eq!(classify(Some("failed to parse json response")), Some(ProviderErrorKind::ApiSchemaChanged));
    }

    #[test]
    fn network_marker() {
        assert_eq!(classify(Some("connection timeout")), Some(ProviderErrorKind::NetworkUnreachableOrTimeout));
    }

    #[test]
    fn rate_marker() {
        assert_eq!(classify(Some("rate limit exceeded")), Some(ProviderErrorKind::RateLimited));
    }

    #[test]
    fn unknown_fallback() {
        assert_eq!(classify(Some("something weird happened")), Some(ProviderErrorKind::Unknown));
    }

    #[test]
    fn precedence_cookie_beats_401() {
        assert_eq!(
            classify(Some("HTTP 401 — cookie missing")),
            Some(ProviderErrorKind::CookieExpiredOrMissing)
        );
    }

    #[test]
    fn precedence_rate_beats_401() {
        assert_eq!(
            classify(Some("HTTP 401 — rate limit hit")),
            Some(ProviderErrorKind::RateLimited)
        );
    }

    #[test]
    fn precedence_network_beats_schema() {
        assert_eq!(
            classify(Some("network timeout while parsing json")),
            Some(ProviderErrorKind::NetworkUnreachableOrTimeout)
        );
    }

    #[test]
    fn code_429_infers_rate_limited() {
        assert_eq!(classify(Some("request failed with status 429")), Some(ProviderErrorKind::RateLimited));
    }

    #[test]
    fn code_401_infers_token() {
        assert_eq!(classify(Some("http 401 unauthorized-ish")), Some(ProviderErrorKind::TokenInvalidOrMissing));
    }

    #[test]
    fn code_5xx_infers_schema() {
        assert_eq!(classify(Some("server responded (500)")), Some(ProviderErrorKind::ApiSchemaChanged));
    }

    #[test]
    fn marker_wins_before_bare_code_timeout_429ms() {
        // "timeout" marker fires before any bare-code inference is reached.
        assert_eq!(
            classify(Some("timeout sau 429ms")),
            Some(ProviderErrorKind::NetworkUnreachableOrTimeout)
        );
    }

    #[test]
    fn digit_run_not_a_code_token_count() {
        assert_ne!(classify(Some("5000 tokens used")), Some(ProviderErrorKind::ApiSchemaChanged));
    }

    #[test]
    fn digit_run_not_a_code_account_id() {
        assert_eq!(classify(Some("account id 140399")), Some(ProviderErrorKind::Unknown));
    }

    #[test]
    fn digit_run_not_a_code_version_string() {
        assert_eq!(classify(Some("0.140.0")), Some(ProviderErrorKind::Unknown));
    }

    #[test]
    fn key_suffix_matches_camel_case() {
        assert_eq!(ProviderErrorKind::CookieExpiredOrMissing.key_suffix(), "cookieExpiredOrMissing");
        assert_eq!(ProviderErrorKind::TokenInvalidOrMissing.key_suffix(), "tokenInvalidOrMissing");
        assert_eq!(ProviderErrorKind::ApiSchemaChanged.key_suffix(), "apiSchemaChanged");
        assert_eq!(ProviderErrorKind::NetworkUnreachableOrTimeout.key_suffix(), "networkUnreachableOrTimeout");
        assert_eq!(ProviderErrorKind::RateLimited.key_suffix(), "rateLimited");
        assert_eq!(ProviderErrorKind::Unknown.key_suffix(), "unknown");
    }
}
