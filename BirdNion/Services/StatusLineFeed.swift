import Foundation

/// Opt-in statusline feed: on every quota publish, writes one compact line to
/// `~/.config/birdnion/statusline.txt` that a `statusLine` config (Claude Code
/// or any terminal tool) can render via `cat`. Off by default, clearly labeled
/// in Settings, and fail soft — a write failure only produces an empty or
/// stale file, never an error surface.
enum StatusLineFeed {
    static let defaultsKey = "statusLineFeedEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/birdnion/statusline.txt")
    }

    /// Compact single-line render: one segment per provider, worst window
    /// first — "Claude 5 GIỜ 18% | Codex TUẦN 61% | Devin 2.9/5 ACU".
    static func render(_ statuses: [ProviderStatus]) -> String {
        statuses.compactMap { status -> String? in
            let window = status.windows
                .filter { !$0.isSupplementary && !$0.isInactive }
                .min(by: { $0.remainingPct < $1.remainingPct })
            guard let window else { return nil }
            let value: String
            if let allowance = window.allowance,
               let used = allowance.used, let limit = allowance.limit,
               used.isFinite, limit.isFinite, limit > 0 {
                value = "\(format(used))/\(format(limit)) \(allowance.unit.rawValue)"
            } else {
                value = "\(window.remainingPct)%"
            }
            return "\(status.displayName) \(window.label) \(value)"
        }.joined(separator: " | ")
    }

    /// Called from `QuotaService.statuses.didSet` — same seam as the widget
    /// snapshot. No-op when disabled; never throws.
    static func write(_ statuses: [ProviderStatus]) {
        guard isEnabled else { return }
        let line = render(statuses)
        let url = fileURL
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try? (line + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Remove the feed file when the toggle turns off so a stale line can't
    /// linger in the user's statusline.
    static func removeFile() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static func format(_ number: Double) -> String {
        let rounded = (number * 100).rounded() / 100
        if rounded == rounded.rounded() {
            return String(Int(rounded))
        }
        return String(format: "%.2f", rounded)
    }
}
