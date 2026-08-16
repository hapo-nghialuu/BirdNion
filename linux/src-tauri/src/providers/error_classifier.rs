//! Pure error classifier — Rust mirror of the macOS `ProviderErrorClassifier`.
//! Maps a raw provider error string to exactly one `ProviderErrorKind`. No
//! I/O, no dependencies on other provider modules.

/// Actionable classification of a provider's raw error string.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProviderErrorKind {
    /// Browser session cookie missing/expired -> re-login browser.
    CookieExpiredOrMissing,
    /// Provider never set up (no token/login attempted yet) -> open Settings.
    NotConfigured,
    /// API key / OAuth token present but wrong/expired -> re-paste token.
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
            Self::NotConfigured => "notConfigured",
            Self::TokenInvalidOrMissing => "tokenInvalidOrMissing",
            Self::ApiSchemaChanged => "apiSchemaChanged",
            Self::NetworkUnreachableOrTimeout => "networkUnreachableOrTimeout",
            Self::RateLimited => "rateLimited",
            Self::Unknown => "unknown",
        }
    }

    /// Whether this kind is something Settings can actually fix — i.e. the
    /// popover/self-test "Fix" action makes sense and should open the
    /// provider's Settings row. Rate-limit and network errors are not
    /// configuration problems, so "Fix" must never show for them; a schema
    /// change or unknown error isn't fixable from Settings either.
    pub fn is_fixable(&self) -> bool {
        matches!(
            self,
            Self::NotConfigured | Self::TokenInvalidOrMissing | Self::CookieExpiredOrMissing
        )
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
///   5. not-configured        -> NotConfigured (beats token: never set up != wrong value)
///   6. 401/403 / token       -> TokenInvalidOrMissing
///   7. invalid-response/5xx  -> ApiSchemaChanged
///   8. otherwise             -> Unknown
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
    // "Never configured/logged in" is distinct from "token present but
    // wrong": the former needs the user to CONNECT a source; the latter
    // needs them to RE-PASTE/refresh one. Checked before `TOKEN_MARKERS`
    // since several of these messages also contain "api key"/"token" (e.g.
    // "API key is not configured").
    const NOT_CONFIGURED_MARKERS: &[&str] = &[
        "not configured",
        "chưa cấu hình",
        "chưa đăng nhập",
        "not signed in",
        "not logged in",
        "no api key",
        "missing api key",
        "chưa có api key",
        "please configure",
        "chưa thiết lập",
        "chưa nhập",
    ];
    const TOKEN_MARKERS: &[&str] = &["token", "api key", "unauthorized", "hết hạn"];
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
    if NOT_CONFIGURED_MARKERS.iter().any(|m| s.contains(m)) {
        return Some(ProviderErrorKind::NotConfigured);
    }
    if TOKEN_MARKERS.iter().any(|m| s.contains(m)) || codes.contains(&401) || codes.contains(&403) {
        return Some(ProviderErrorKind::TokenInvalidOrMissing);
    }
    if SCHEMA_MARKERS.iter().any(|m| s.contains(m)) || codes.iter().any(|&c| (500..600).contains(&c)) {
        return Some(ProviderErrorKind::ApiSchemaChanged);
    }
    Some(ProviderErrorKind::Unknown)
}

/// Whether a raw provider error is transient enough to justify preserving a
/// prior last-good snapshot instead of collapsing to an error-only card.
/// Transient = network/timeout, rate-limit, or a genuine 5xx server error.
/// Credential, cookie, and generic schema/unknown errors are NOT transient —
/// the shown data may no longer be trustworthy, so the caller must surface
/// the fresh (error) status instead of hiding it behind stale numbers.
/// Mirrors the macOS `isTransientForLastGood` — single source of truth for
/// the last-good policy shared by the JS refresh poller and self-test.
pub fn is_transient_for_last_good(raw: Option<&str>) -> bool {
    let Some(raw) = raw else { return false };
    if raw.trim().is_empty() {
        return false;
    }
    match classify(Some(raw)) {
        Some(ProviderErrorKind::NetworkUnreachableOrTimeout) | Some(ProviderErrorKind::RateLimited) => true,
        Some(ProviderErrorKind::ApiSchemaChanged) => {
            let s = raw.to_lowercase();
            http_codes(&s).iter().any(|&c| (500..600).contains(&c))
        }
        _ => false,
    }
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

            // `http_context` only checked the prefix, so "http 429ms" wrongly
            // accepted 429 as a code — the trailing boundary must hold
            // regardless of which branch matched (mirrors the Swift
            // regex's trailing `\b`, which fails between two word chars).
            if run_len == 3 && !next_is_word_or_dot && (standalone || http_context) {
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
    fn not_configured_marker() {
        assert_eq!(classify(Some("Chưa cấu hình token")), Some(ProviderErrorKind::NotConfigured));
        assert_eq!(
            classify(Some("xAI Management API key is not configured. Set XAI_MANAGEMENT_API_KEY.")),
            Some(ProviderErrorKind::NotConfigured)
        );
        assert_eq!(
            classify(Some("Chưa đăng nhập Codex — chạy `codex` để đăng nhập")),
            Some(ProviderErrorKind::NotConfigured)
        );
    }

    #[test]
    fn not_configured_beats_token_marker() {
        // "API key" also matches TOKEN_MARKERS but not-configured must win.
        assert_eq!(
            classify(Some("xAI team ID is not configured. Set XAI_TEAM_ID or enter it in Settings.")),
            Some(ProviderErrorKind::NotConfigured)
        );
    }

    #[test]
    fn is_fixable_only_for_config_credential_cookie() {
        assert!(ProviderErrorKind::NotConfigured.is_fixable());
        assert!(ProviderErrorKind::TokenInvalidOrMissing.is_fixable());
        assert!(ProviderErrorKind::CookieExpiredOrMissing.is_fixable());
        assert!(!ProviderErrorKind::RateLimited.is_fixable());
        assert!(!ProviderErrorKind::NetworkUnreachableOrTimeout.is_fixable());
        assert!(!ProviderErrorKind::ApiSchemaChanged.is_fixable());
        assert!(!ProviderErrorKind::Unknown.is_fixable());
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
    fn http_codes_rejects_embedded_suffix_even_in_http_context() {
        // Before the fix, `http_context` only checked the PREFIX ("http "/
        // "status "/"("), so a trailing unit suffix like "ms" was wrongly
        // accepted — "http 429ms" parsed as HTTP 429. The trailing boundary
        // must hold for this branch too, same as the standalone one.
        assert_eq!(http_codes("http 429ms"), Vec::<u32>::new());
        assert_eq!(http_codes("status 500abc"), Vec::<u32>::new());
        assert_eq!(http_codes("(500x)"), Vec::<u32>::new());
        // Sanity: the legitimate prefixed forms still work.
        assert_eq!(http_codes("http 429"), vec![429]);
        assert_eq!(http_codes("status 500"), vec![500]);
        assert_eq!(http_codes("(500)"), vec![500]);
    }

    #[test]
    fn embedded_suffix_after_http_prefix_does_not_infer_rate_limited() {
        // No other marker in this string — if the bare-code inference wrongly
        // accepted "429" here, this would classify as RateLimited instead.
        assert_eq!(
            classify(Some("request to http 429ms delay")),
            Some(ProviderErrorKind::Unknown)
        );
    }

    #[test]
    fn transient_none_on_none_or_empty() {
        assert!(!is_transient_for_last_good(None));
        assert!(!is_transient_for_last_good(Some("")));
        assert!(!is_transient_for_last_good(Some("   ")));
    }

    #[test]
    fn transient_network_timeout_and_rate_limit() {
        assert!(is_transient_for_last_good(Some("Claude: timeout sau 12s")));
        assert!(is_transient_for_last_good(Some("Network: could not connect to host")));
        assert!(is_transient_for_last_good(Some("HTTP 429 rate limit exceeded")));
    }

    #[test]
    fn transient_server_5xx_but_not_generic_schema() {
        assert!(is_transient_for_last_good(Some("server responded (500)")));
        assert!(is_transient_for_last_good(Some("HTTP 503")));
        assert!(!is_transient_for_last_good(Some("failed to parse json response")));
    }

    #[test]
    fn not_transient_credential_and_cookie() {
        assert!(!is_transient_for_last_good(Some("HTTP 401")));
        assert!(!is_transient_for_last_good(Some("Invalid token provided")));
        assert!(!is_transient_for_last_good(Some("Session cookie expired")));
    }

    #[test]
    fn not_transient_unknown() {
        assert!(!is_transient_for_last_good(Some("something weird happened")));
    }

    #[test]
    fn key_suffix_matches_camel_case() {
        assert_eq!(ProviderErrorKind::CookieExpiredOrMissing.key_suffix(), "cookieExpiredOrMissing");
        assert_eq!(ProviderErrorKind::NotConfigured.key_suffix(), "notConfigured");
        assert_eq!(ProviderErrorKind::TokenInvalidOrMissing.key_suffix(), "tokenInvalidOrMissing");
        assert_eq!(ProviderErrorKind::ApiSchemaChanged.key_suffix(), "apiSchemaChanged");
        assert_eq!(ProviderErrorKind::NetworkUnreachableOrTimeout.key_suffix(), "networkUnreachableOrTimeout");
        assert_eq!(ProviderErrorKind::RateLimited.key_suffix(), "rateLimited");
        assert_eq!(ProviderErrorKind::Unknown.key_suffix(), "unknown");
    }
}
