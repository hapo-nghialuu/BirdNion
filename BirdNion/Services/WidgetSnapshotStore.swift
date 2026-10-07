import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Snapshot of per-provider quota written for the Burn Down widget
/// extension. The widget decodes the same schema from its own copy
/// (`BirdNionWidget/WidgetSnapshotModel.swift`) — keep field names in sync.
struct WidgetWindowSnapshot: Codable, Equatable {
    /// Provider-native window label ("5 giờ", "Ngày", "Tuần", …).
    let label: String
    let usedPercent: Int
    /// Window length in minutes (300 = 5h, 10080 = week).
    let windowMinutes: Int?
    /// Reset instant as unix seconds; nil when the source gives none.
    let resetsAt: TimeInterval?
}

struct WidgetProviderSnapshot: Codable, Equatable {
    let id: String
    let name: String
    let updatedAt: TimeInterval
    let creditsRemaining: Double?
    let windows: [WidgetWindowSnapshot]
}

struct WidgetQuotaSnapshot: Codable, Equatable {
    var version: Int = 1
    let generatedAt: TimeInterval
    let providers: [WidgetProviderSnapshot]
}

/// Persists `WidgetQuotaSnapshot` for the widget extension.
/// Path: App Group container when the app is signed with a team that has the
/// group entitlement, else the settings directory (`~/.config/birdnion/`).
/// Widget reads app-group first, then the same XDG path — identical to
/// upstream CodexBar's `AppGroupSupport.snapshotURL` fallback.
enum WidgetSnapshotStore {
    static let widgetKind = "BirdNionBurnDown"
    static let appGroupID = "group.com.local.birdnion"
    static let filename = "widget-snapshot.json"

    static func snapshotURL(
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default) -> URL {
        // `containerURL` can return a URL for a group container that was never
        // materialized — on unsigned builds (no group entitlement) the system
        // can't create it, and `createDirectory` against that path blocks
        // instead of failing. Only use the container once it exists on disk.
        if let container = fileManager
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID),
            fileManager.fileExists(atPath: container.path) {
            return container.appendingPathComponent(filename)
        }
        return BirdNionConfigStore.configURL(env: env, fileManager: fileManager)
            .deletingLastPathComponent()
            .appendingPathComponent(filename)
    }

    /// Write the snapshot derived from the latest published statuses and ask
    /// WidgetKit to reload timelines. Runs off the caller's queue — this is
    /// called from `QuotaService.statuses.didSet` on the main actor, and file
    /// I/O must never stall publishing.
    static func save(_ statuses: [ProviderStatus]) {
        let url = snapshotURL()
        DispatchQueue.global(qos: .utility).async {
            save(statuses, to: url, reloadTimelines: true)
        }
    }

    static func save(_ statuses: [ProviderStatus],
                     to url: URL,
                     reloadTimelines: Bool) {
        let providers = statuses.map { status in
            WidgetProviderSnapshot(
                id: status.id,
                name: status.displayName,
                updatedAt: status.lastUpdated.timeIntervalSince1970,
                creditsRemaining: status.creditsRemaining,
                windows: status.windows
                    .filter { !$0.isSupplementary }
                    .map { w in
                        WidgetWindowSnapshot(
                            label: w.label,
                            usedPercent: w.usedPct,
                            windowMinutes: w.windowSeconds.map { $0 / 60 },
                            resetsAt: w.resetDate?.timeIntervalSince1970)
                    })
        }
        let snapshot = WidgetQuotaSnapshot(
            generatedAt: Date().timeIntervalSince1970,
            providers: providers)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
        if reloadTimelines {
            reload()
        }
    }

    static func load(from url: URL) -> WidgetQuotaSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetQuotaSnapshot.self, from: data)
    }

    static func reload() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
        #endif
    }
}
