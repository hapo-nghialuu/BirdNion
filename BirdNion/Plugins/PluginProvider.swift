import Foundation

/// Maps a plugin's `CodexBarUsageSnapshot`-shaped result onto BirdNion's
/// `ProviderStatus`. Percent-only windows stay percent-only; absolute values
/// are never fabricated (same contract as `QuotaAllowance`).
enum PluginSnapshotMapper {
    static func status(_ snap: PluginUsageSnapshot,
                       id: String,
                       displayName: String) -> ProviderStatus {
        let s = snap.effective
        var windows: [QuotaWindow] = []
        for (position, w) in [(0, s.primary), (1, s.secondary), (2, s.tertiary)] {
            if let w { windows.append(window(w, label: positionalLabel(w, position: position))) }
        }
        for named in s.extraWindows ?? [] {
            windows.append(window(named.rateWindow, label: named.title))
        }

        return ProviderStatus(
            id: id,
            displayName: displayName,
            windows: windows,
            lastUpdated: Date(),
            error: nil,
            accountLabel: s.identity?.email ?? s.identity?.organization,
            creditsRemaining: costBalance(s.cost),
            sourceLabel: snap.sourceLabel)
    }

    /// `cost.balance` is a spendable balance, not a rate window — surface it as
    /// `creditsRemaining` (the Codex credits chip) rather than a fake window.
    private static func costBalance(_ cost: PluginCostSnapshot?) -> Double? {
        guard let balance = cost?.balance, balance.isFinite, balance >= 0 else { return nil }
        return balance
    }

    private static func window(_ w: PluginRateWindow, label: String) -> QuotaWindow {
        let usageKnown = w.usageKnown ?? true
        let usedPct = Int(((w.usedPercent ?? 0) / 100.0 * 100).rounded())
            .clamped(to: 0...100)
        return QuotaWindow(
            label: label,
            usedPct: usageKnown ? usedPct : 0,
            remainingPct: usageKnown ? 100 - usedPct : 100,
            subtitle: w.resetDescription,
            resetDate: w.resetsAt?.date,
            windowSeconds: w.windowMinutes.map { Int($0 * 60) },
            isInactive: !usageKnown)
    }

    /// Upstream has no labels on primary/secondary/tertiary — derive from the
    /// window length, matching BirdNion's existing "5 giờ" / "Ngày" / "Tuần" /
    /// "Tháng" scheme.
    private static func positionalLabel(_ w: PluginRateWindow, position: Int) -> String {
        if let minutes = w.windowMinutes {
            switch Int(minutes) {
            case 0..<720: return "5 giờ"
            case 720..<2880: return "Ngày"
            case 2880..<20160: return "Tuần"
            default: return "Tháng"
            }
        }
        return w.resetDescription ?? ["Phiên", "Tuần", "Tháng"][min(position, 2)]
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

/// A `QuotaProvider` backed by a JavaScript plugin file.
final class PluginProvider: QuotaProvider {
    let id: String
    let displayName: String
    private let engine: PluginEngine

    init(engine: PluginEngine) {
        self.engine = engine
        self.id = engine.manifest.id
        self.displayName = engine.manifest.name
        engine.secretResolver = { key in
            if let env = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !env.isEmpty { return env }
            return BirdNionConfigStore.apiKey(provider: engine.manifest.id)
        }
    }

    func fetch() async throws -> ProviderStatus {
        do {
            let snap = try engine.fetchUsage()
            return PluginSnapshotMapper.status(snap, id: id, displayName: displayName)
        } catch let e as PluginFetchError {
            return ProviderStatus(
                id: id, displayName: displayName, windows: [],
                lastUpdated: Date(), error: e.message)
        }
    }
}

/// Discovers plugin files (bundle `Resources/Plugins` + user
/// `~/.config/birdnion/plugins`) and exposes their manifests so the provider
/// list, Settings sidebar, and `ServicesContainer` can treat them like native
/// providers.
enum PluginRegistry {
    /// Manifest + source URL for every valid plugin found. Sorted by id.
    static var discovered: [(manifest: PluginManifest, url: URL)] {
        var seen: Set<String> = []
        var out: [(PluginManifest, URL)] = []
        for url in pluginFiles() {
            guard let engine = try? PluginEngine(source: (try? String(contentsOf: url, encoding: .utf8)) ?? "") else { continue }
            guard seen.insert(engine.manifest.id).inserted else { continue }
            out.append((engine.manifest, url))
        }
        return out.sorted { $0.0.id < $1.0.id }
    }

    /// Config-store rows to inject into the provider list for plugins not yet
    /// present — disabled by default (opt-in), carrying the manifest name so
    /// the sidebar shows the real provider name.
    static func defaultEntries() -> [BirdNionConfigStore.Provider] {
        discovered.map { m, _ in
            BirdNionConfigStore.Provider(id: m.id, enabled: false, displayName: m.name)
        }
    }

    /// Build a provider for a config id when it matches a discovered plugin.
    static func makeProvider(id: String) -> PluginProvider? {
        guard let entry = discovered.first(where: { $0.manifest.id == id }),
              let source = try? String(contentsOf: entry.url, encoding: .utf8),
              let engine = try? PluginEngine(source: source)
        else { return nil }
        return PluginProvider(engine: engine)
    }

    /// Manifest for a discovered plugin id — used by Settings for the
    /// provider's display name and settings schema.
    static func manifest(id: String) -> PluginManifest? {
        discovered.first { $0.manifest.id == id }?.manifest
    }

    private static func pluginFiles() -> [URL] {
        var urls: [URL] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Plugins", isDirectory: true) {
            urls.append(contentsOf: jsFiles(in: bundled))
        }
        urls.append(contentsOf: jsFiles(in: userPluginsDir))
        return urls
    }

    static var userPluginsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/birdnion/plugins", isDirectory: true)
    }

    private static func jsFiles(in dir: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "js" || $0.pathExtension == "ts" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    }
}
