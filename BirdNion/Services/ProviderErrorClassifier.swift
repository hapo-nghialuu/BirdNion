import Foundation

/// Actionable classification of a provider's raw error string. Pure, UI-free.
/// Order of the cases is NOT significant; the ORDER OF CHECKS in `classify` IS
/// (see the classification precedence invariant below).
enum ProviderErrorKind: String, CaseIterable, Equatable, Sendable {
    case cookieExpiredOrMissing      // browser session cookie missing/expired -> re-login browser
    case tokenInvalidOrMissing       // API key / OAuth token missing/wrong/expired -> re-paste token
    case apiSchemaChanged            // unexpected/invalid response shape or 5xx -> app may need update
    case networkUnreachableOrTimeout // network down / timeout -> check connection, retry
    case rateLimited                 // HTTP 429 / rate-limit -> wait and retry
    case unknown                     // unmatched -> show detail

    /// L10n key for the short title.
    var titleKey: String { "providerError.\(rawValue).title" }
    /// L10n key for the one-line remediation hint.
    var hintKey: String { "providerError.\(rawValue).hint" }
}

/// Pure classifier: maps a raw provider error string to exactly one kind.
/// Returns nil when there is no error to classify (nil/empty input).
/// PRECEDENCE (fixed invariant — order of checks matters):
///   1. nil/empty            -> nil                         (R0.7)
///   2. cookie marker        -> cookieExpiredOrMissing      (R0.3, beats 401/403)
///   3. 429 / rate-limit     -> rateLimited                 (R0.4, beats 401/403)
///   4. timeout/network      -> networkUnreachableOrTimeout (R0.5, beats schema)
///   5. 401/403 / token      -> tokenInvalidOrMissing
///   6. invalid-response/5xx -> apiSchemaChanged
///   7. otherwise            -> unknown                     (R0.6)
/// Matching is case-insensitive substring/code containment over the raw string,
/// which is intentionally bilingual (vi/en) and ad-hoc across providers.
func classify(rawError: String?) -> ProviderErrorKind? {
    guard let rawError, !rawError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return nil
    }
    let s = rawError.lowercased()
    let codes = httpCodes(in: s)

    // Marker sets are the single source of truth — extend with one-line additions.
    // Ambiguous single-word markers ("đăng nhập", "expired", "connection") are
    // deliberately excluded: they appear across cookie AND token provider copy.
    let cookieMarkers = ["cookie", "session cookie", "cần auth", "__host-auth", "sessionkey"]
    let rateMarkers = ["rate limit", "too many", "quá nhiều"]
    let networkMarkers = ["timeout", "network", "mạng", "offline", "could not connect"]
    let tokenMarkers = ["token", "api key", "unauthorized", "chưa cấu hình", "hết hạn"]
    let schemaMarkers = ["không hợp lệ", "invalid", "thiếu trường", "missing field",
                         "parse", "json", "không nhận ra", "không có model"]

    if cookieMarkers.contains(where: s.contains) { return .cookieExpiredOrMissing }
    if rateMarkers.contains(where: s.contains) || codes.contains(429) { return .rateLimited }
    if networkMarkers.contains(where: s.contains) { return .networkUnreachableOrTimeout }
    if tokenMarkers.contains(where: s.contains) || codes.contains(401) || codes.contains(403) {
        return .tokenInvalidOrMissing
    }
    if schemaMarkers.contains(where: s.contains) || codes.contains(where: { (500..<600).contains($0) }) {
        return .apiSchemaChanged
    }
    return .unknown
}

/// Extracts HTTP status codes that appear in an HTTP context only: "http NNN",
/// "(NNN)", "status NNN", or a standalone 3-digit token. Digits embedded in a
/// longer run or decimal ("5000 tokens", "0.140.0", "429ms") are NOT codes.
private func httpCodes(in lowercased: String) -> Set<Int> {
    var codes: Set<Int> = []
    // Standalone 3-digit tokens: not preceded/followed by a digit, dot, or
    // letter-run that would make it a unit ("429ms") or version ("0.140.0").
    let pattern = #"(?:http |status |\()(\d{3})\b|(?<![\d.\w])(\d{3})(?![\d.\w])"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return codes }
    let range = NSRange(lowercased.startIndex..., in: lowercased)
    regex.enumerateMatches(in: lowercased, range: range) { match, _, _ in
        guard let match else { return }
        for group in 1...2 {
            let r = match.range(at: group)
            guard r.location != NSNotFound, let swiftRange = Range(r, in: lowercased),
                  let code = Int(lowercased[swiftRange]), (100..<600).contains(code) else { continue }
            codes.insert(code)
        }
    }
    return codes
}
