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

    /// Providers without a pollable feed — health stays `.unknown` until a feed exists.
    static func isLinkOnly(_ providerID: String) -> Bool {
        providerID == "grok" || providerID == "xai"
    }

    /// Binary overall health for the popover strip (green / red / gray).
    enum Health: Equatable {
        /// Indicator `none` — systems operational.
        case ok
        /// Any non-operational indicator (minor → critical, maintenance).
        case issue
        /// No feed, checks off, or not yet polled.
        case unknown
    }

    /// One row: overall health + status label; the view always pairs it with a link.
    struct Strip: Equatable {
        let health: Health
        /// Primary status text (left of the link).
        let label: String
    }

    /// True when the statuspage indicator is non-operational.
    static func hasIssue(level: String?) -> Bool {
        guard let level, !level.isEmpty else { return false }
        return level != "none"
    }

    /// Overall health from a statuspage indicator string.
    static func health(level: String?) -> Health {
        guard let level, !level.isEmpty else { return .unknown }
        return level == "none" ? .ok : .issue
    }

    /// Returns nil when this provider has no status page URL.
    ///
    /// Always shows a strip for Claude / Codex / Grok when a URL exists so the
    /// user can open the status page; health is green (ok), red (issue), or
    /// gray (unknown / link-only / checks off).
    static func strip(
        for status: ProviderStatus,
        statusChecksEnabled: Bool,
        operationalLabel: String,
        issueFallbackLabel: String,
        unknownLabel: String
    ) -> Strip? {
        guard url(for: status.id) != nil else { return nil }

        if isLinkOnly(status.id) {
            return Strip(health: .unknown, label: unknownLabel)
        }

        guard statusChecksEnabled else {
            return Strip(health: .unknown, label: unknownLabel)
        }

        let level = status.serviceStatusLevel
        switch health(level: level) {
        case .ok:
            let raw = status.serviceStatus?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Strip(health: .ok, label: raw.isEmpty ? operationalLabel : raw)
        case .issue:
            let raw = status.serviceStatus?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Strip(health: .issue, label: raw.isEmpty ? issueFallbackLabel : raw)
        case .unknown:
            return Strip(health: .unknown, label: unknownLabel)
        }
    }
}
