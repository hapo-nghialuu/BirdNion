import Foundation

/// GitHub-releases update check — BirdNion ships ad-hoc signed via a brew
/// tap, so there is no Sparkle. The About pane's "Kiểm tra cập nhật" button
/// (and a daily-throttled launch check) compare the newest release tag with
/// `CFBundleShortVersionString` and link to the release page.

/// Minimal semver comparison for release tags like "v1.2.3" / "0.8.2-beta.1".
enum SemVer {
    /// True when `candidate` is strictly newer than `current`. Numeric
    /// component-wise compare; a prerelease sorts BELOW the same release
    /// version ("1.2.0-beta.1" < "1.2.0").
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let c = parse(candidate)
        let r = parse(current)
        for i in 0..<max(c.numbers.count, r.numbers.count) {
            let a = i < c.numbers.count ? c.numbers[i] : 0
            let b = i < r.numbers.count ? r.numbers[i] : 0
            if a != b { return a > b }
        }
        // Equal numeric parts: candidate is newer only when the CURRENT one
        // is a prerelease and the candidate is the final release.
        return r.isPrerelease && !c.isPrerelease
    }

    private static func parse(_ raw: String) -> (numbers: [Int], isPrerelease: Bool) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("v") { s = String(s.dropFirst()) }
        let parts = s.split(separator: "-", maxSplits: 1)
        let numbers = (parts.first ?? "").split(separator: ".").map { Int($0) ?? 0 }
        return (numbers, parts.count > 1)
    }
}

struct GitHubRelease: Decodable, Equatable {
    let tagName: String
    let htmlURL: String
    let prerelease: Bool
    let draft: Bool

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case prerelease, draft
    }
}

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, url: URL)
        case failed
    }

    @Published private(set) var state: State = .idle

    static let releasesURL = URL(
        string: "https://api.github.com/repos/hapo-nghialuu/BirdNion/releases?per_page=20")!
    static let lastCheckedKey = "updateLastCheckedAt"
    static let checkInterval: TimeInterval = 86_400   // daily throttle

    /// Launch-time check: only when the About toggle is on and the last check
    /// is older than a day. Result surfaces passively in the About pane.
    func checkOnLaunchIfDue(now: Date = Date()) {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "updateAutoCheckEnabled") as? Bool ?? true else { return }
        let last = defaults.double(forKey: Self.lastCheckedKey)
        guard now.timeIntervalSince1970 - last >= Self.checkInterval else { return }
        Task { await check() }
    }

    func check() async {
        guard state != .checking else { return }
        state = .checking
        var request = URLRequest(url: Self.releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                state = .failed
                return
            }
            let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckedKey)
            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            let channel = UserDefaults.standard.string(forKey: "updateChannel") ?? "stable"
            if let newest = Self.pickLatest(releases, channel: channel, currentVersion: current),
               let url = URL(string: newest.htmlURL) {
                state = .available(version: newest.tagName, url: url)
            } else {
                state = .upToDate
            }
        } catch {
            state = .failed
        }
    }

    /// Pure picker (unit-tested): drops drafts, drops prereleases on the
    /// stable channel, then returns the highest tag that is newer than the
    /// installed version — nil when up to date.
    nonisolated static func pickLatest(
        _ releases: [GitHubRelease],
        channel: String,
        currentVersion: String
    ) -> GitHubRelease? {
        releases
            .filter { !$0.draft && (channel == "beta" || !$0.prerelease) }
            .filter { SemVer.isNewer($0.tagName, than: currentVersion) }
            .max { SemVer.isNewer($1.tagName, than: $0.tagName) }
    }
}
