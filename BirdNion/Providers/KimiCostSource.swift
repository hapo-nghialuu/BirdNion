import Foundation

/// Local cost source: Kimi / Kimi Code wire logs —
/// `~/.kimi/sessions/<group>/<session>/wire.jsonl` and
/// `~/.kimi-code/sessions/<workspace>/<session>/agents/<agent>/wire.jsonl`
/// (same files ccusage reads via `KIMI_DATA_DIR`). Wire records carry a
/// `token_usage`/`usage` dict of token counters.
enum KimiCostSource {

    static let descriptor = LocalCostSource(
        source: .kimi,
        displayName: "Kimi",
        countingRevision: 1,
        roots: { KimiCostSource.dataRoots() },
        turnReader: { roots, cutoff in
            GenericJsonCostSource.turns(
                roots: roots,
                extensions: ["jsonl"],
                fileFilter: { $0.lastPathComponent == "wire.jsonl" },
                spec: .default,
                cutoff: cutoff,
                dedupePrefix: "kimi")
        })

    private static func dataRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [".kimi", ".kimi-code"].compactMap { name in
            let dir = home.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
        }
    }
}
