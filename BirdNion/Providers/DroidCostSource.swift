import Foundation

/// Local cost source: Factory Droid session settings under
/// `~/.factory/sessions/**/*.settings.json` (same files ccusage reads via
/// `DROID_SESSIONS_DIR`). Settings files carry input/output/cache/thinking
/// token counts.
enum DroidCostSource {

    static let descriptor = LocalCostSource(
        source: .droid,
        displayName: "Droid",
        countingRevision: 1,
        roots: { DroidCostSource.dataRoots() },
        turnReader: { roots, cutoff in
            GenericJsonCostSource.turns(
                roots: roots,
                extensions: ["json"],
                fileFilter: { $0.lastPathComponent.hasSuffix(".settings.json") },
                spec: .default,
                cutoff: cutoff,
                dedupePrefix: "droid")
        })

    private static func dataRoots() -> [URL] {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".factory/sessions")
        return FileManager.default.fileExists(atPath: dir.path) ? [dir] : []
    }
}
