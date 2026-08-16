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

    /// Providers without a pollable feed — strip is a plain status-page link only.
    static func isLinkOnly(_ providerID: String) -> Bool {
        providerID == "grok" || providerID == "xai"
    }

    /// Binary overall health for polled providers (green / red).
    enum Health: Equatable {
        /// Indicator `none` — systems operational.
        case ok
        /// Any non-operational indicator (minor → critical, maintenance).
        case issue
    }

    /// What the popover renders under the provider header.
    enum Strip: Equatable {
        /// Polled overall status chip (Claude / Codex when feed has a reading).
        case health(Health)
        /// Status-page deep link only (Grok, checks off, or not yet polled).
        case linkOnly
    }

    /// True when the statuspage indicator is non-operational.
    static func hasIssue(level: String?) -> Bool {
        guard let level, !level.isEmpty else { return false }
        return level != "none"
    }

    /// Overall health from a statuspage indicator string. `nil` / empty → unknown (no chip).
    static func health(level: String?) -> Health? {
        guard let level, !level.isEmpty else { return nil }
        return level == "none" ? .ok : .issue
    }

    /// Returns nil when this provider has no status page URL.
    ///
    /// - Grok / xAI → always `.linkOnly` (no fake gray “status”).
    /// - Claude / Codex with a polled indicator → `.health`.
    /// - Checks off or not yet polled → `.linkOnly` (link still available).
    static func strip(
        for status: ProviderStatus,
        statusChecksEnabled: Bool
    ) -> Strip? {
        guard url(for: status.id) != nil else { return nil }

        if isLinkOnly(status.id) {
            return .linkOnly
        }

        guard statusChecksEnabled else { return .linkOnly }
        guard let h = health(level: status.serviceStatusLevel) else {
            return .linkOnly
        }
        return .health(h)
    }

    /// Optional feed description for tooltips (full sentence from statuspage).
    static func detailText(for status: ProviderStatus) -> String? {
        let raw = status.serviceStatus?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? nil : raw
    }
}
