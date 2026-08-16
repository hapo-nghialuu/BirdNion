import Foundation

/// Public status-page URLs and display rules for the popover service-status strip.
///
/// Claude / Codex poll a status feed into `ProviderStatus.serviceStatus*`.
/// Grok (and xAI) only deep-link — xAI has no public Statuspage-style feed yet
/// (same split as CodexBar: `statusPageURL` vs `statusLinkURL`).
enum ProviderStatusPage {
    /// Opens in the browser when the user taps the popover strip / Settings link.
    static func url(for providerID: String) -> URL? {
        switch providerID {
        case "claude":
            return URL(string: "https://status.claude.com/")
        case "codex", "openai":
            return URL(string: "https://status.openai.com/")
        case "grok", "xai":
            return URL(string: "https://status.x.ai")
        default:
            return nil
        }
    }

    /// Providers without a pollable feed — strip is a static link only.
    static func isLinkOnly(_ providerID: String) -> Bool {
        providerID == "grok" || providerID == "xai"
    }

    /// True when the statuspage indicator should surface as an issue (dot + text).
    /// `none` / missing = operational; hide the polled strip to keep quota first.
    static func hasIssue(level: String?) -> Bool {
        guard let level, !level.isEmpty else { return false }
        return level != "none"
    }

    /// What the popover strip should render for this provider snapshot.
    enum StripKind: Equatable {
        /// Link-only row (Grok / xAI) — no severity dot.
        case linkOnly
        /// Incident / maintenance / unknown — colored dot + localized text.
        case issue(text: String, level: String)
    }

    /// Returns nil when the strip should not appear.
    ///
    /// - Link-only providers always show when a URL exists.
    /// - Polled providers show only when status checks are enabled and the
    ///   latest snapshot reports a non-operational indicator with text.
    static func stripKind(
        for status: ProviderStatus,
        statusChecksEnabled: Bool
    ) -> StripKind? {
        guard url(for: status.id) != nil else { return nil }

        if isLinkOnly(status.id) {
            return .linkOnly
        }

        guard statusChecksEnabled else { return nil }
        guard hasIssue(level: status.serviceStatusLevel) else { return nil }
        let text = status.serviceStatus?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return nil }
        return .issue(text: text, level: status.serviceStatusLevel ?? "unknown")
    }

    /// Dot color key for issue levels (maps onto theme tokens in the view).
    static func severity(for level: String?) -> Severity {
        switch level {
        case "none": return .ok
        case "minor", "maintenance": return .warning
        case "major": return .warning
        case "critical": return .critical
        default: return .unknown
        }
    }

    enum Severity: Equatable {
        case ok, warning, critical, unknown
    }
}
