import Foundation

/// Local cost source: Amp thread files under `~/.local/share/amp/threads/**/*.json`
/// (same files ccusage reads via `AMP_DATA_DIR`). Assistant message usage
/// blocks carry input/output/cache token counts; credits are ignored.
enum AmpCostSource {

    static let descriptor = LocalCostSource(
        source: .amp,
        displayName: "Amp",
        countingRevision: 1,
        roots: { AmpCostSource.dataRoots() },
        turnReader: { roots, cutoff in
            GenericJsonCostSource.turns(
                roots: roots,
                extensions: ["json"],
                spec: .default,
                cutoff: cutoff,
                dedupePrefix: "amp")
        })

    private static func dataRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let threads = home.appendingPathComponent(".local/share/amp/threads")
        if FileManager.default.fileExists(atPath: threads.path) { return [threads] }
        let base = home.appendingPathComponent(".local/share/amp")
        return FileManager.default.fileExists(atPath: base.path) ? [base] : []
    }
}
