import Foundation

/// Mirror of `WidgetSnapshotStore`'s write schema (app side). Keep field
/// names in sync — the widget decodes the same JSON, it must never grow a
/// private dialect.
struct WidgetWindowSnapshot: Codable, Equatable {
    let label: String
    let usedPercent: Int
    let windowMinutes: Int?
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

enum WidgetSnapshotLoader {
    static let appGroupID = "group.com.local.birdnion"
    static let filename = "widget-snapshot.json"

    /// App Group container first (signed builds), then the shared XDG
    /// settings dir the app writes to in unsigned/local builds.
    static func snapshotURL(fileManager: FileManager = .default) -> URL {
        if let container = fileManager
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return container.appendingPathComponent(filename)
        }
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let xdg = env["XDG_CONFIG_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !xdg.isEmpty, (xdg as NSString).isAbsolutePath {
            return URL(fileURLWithPath: xdg)
                .appendingPathComponent("birdnion/\(filename)")
        }
        return home.appendingPathComponent(".config/birdnion/\(filename)")
    }

    static func load(fileManager: FileManager = .default) -> WidgetQuotaSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL(fileManager: fileManager)) else { return nil }
        return try? JSONDecoder().decode(WidgetQuotaSnapshot.self, from: data)
    }
}
