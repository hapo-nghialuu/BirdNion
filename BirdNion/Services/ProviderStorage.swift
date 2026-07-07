import Foundation

/// Per-provider on-disk data footprint ("dung lượng lưu trữ") — trimmed-down
/// port of CodexBar's provider storage feature. Shown in the Providers detail
/// pane when Settings → Advanced enables `providerStorageFootprintsEnabled`.

/// Known on-disk locations per provider id (BirdNion `settings.json` ids).
/// Providers without local data return an empty list and render no row.
enum ProviderStoragePaths {
    static func candidatePaths(
        for id: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String] {
        func p(_ rel: String) -> String { home.appendingPathComponent(rel).path }
        switch id {
        case "claude":
            return [p(".claude"), p(".config/claude")]
        case "codex":
            if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"], !custom.isEmpty {
                return [custom]
            }
            return [p(".codex")]
        case "gemini":
            return [p(".gemini"), p(".config/gemini")]
        case "copilot":
            return [p(".config/github-copilot")]
        case "opencode", "opencodego":
            return [p(".config/opencode"), p(".local/share/opencode")]
        case "cursor":
            return [
                p("Library/Application Support/Cursor"),
                p(".cursor"),
                p("Library/Caches/Cursor"),
            ]
        case "kiro":
            return [p(".kiro")]
        case "kilo":
            return [p(".local/share/kilo")]
        default:
            return []
        }
    }
}

struct ProviderStorageFootprint: Equatable {
    let providerID: String
    let totalBytes: Int64
    /// Candidate paths that actually exist on disk.
    let existingPaths: [String]
    let updatedAt: Date
}

/// Scans provider data dirs off-main and publishes results for the Providers
/// detail pane. Results are cached for `ttl` per provider so switching rows
/// back and forth doesn't re-walk large trees (Cursor can be GBs).
@MainActor
final class ProviderStorageScanner: ObservableObject {
    static let shared = ProviderStorageScanner()

    @Published private(set) var footprints: [String: ProviderStorageFootprint] = [:]

    private var inFlight: Set<String> = []
    private static let ttl: TimeInterval = 300

    /// Kick a background scan unless a fresh result exists or one is running.
    func refreshIfStale(id: String, now: Date = Date()) {
        let paths = ProviderStoragePaths.candidatePaths(for: id)
        guard !paths.isEmpty else { return }
        if let cached = footprints[id], now.timeIntervalSince(cached.updatedAt) < Self.ttl { return }
        guard !inFlight.contains(id) else { return }
        inFlight.insert(id)
        Task.detached(priority: .utility) {
            let result = Self.scan(id: id, paths: paths)
            await MainActor.run {
                self.footprints[id] = result
                self.inFlight.remove(id)
            }
        }
    }

    /// Walks every existing candidate dir and sums regular-file sizes.
    /// Symlinks are skipped so shared/aliased trees aren't double-counted.
    nonisolated static func scan(id: String, paths: [String], now: Date = Date()) -> ProviderStorageFootprint {
        let fm = FileManager.default
        var total: Int64 = 0
        var existing: [String] = []
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]
        for path in paths {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            existing.append(path)
            guard isDir.boolValue else {
                total += (try? fm.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
                continue
            }
            guard let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: path),
                includingPropertiesForKeys: Array(keys),
                options: [.skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.isSymbolicLink != true,
                      values.isRegularFile == true else { continue }
                total += Int64(values.fileSize ?? 0)
            }
        }
        return ProviderStorageFootprint(
            providerID: id, totalBytes: total, existingPaths: existing, updatedAt: now)
    }

    /// "1.2 GB" / "348 KB" — file-style units, matches Finder.
    nonisolated static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
