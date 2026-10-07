import Foundation

/// Local cost source: Qwen Code chat logs under
/// `~/.qwen/projects/<project>/chats/*.jsonl` (same files ccusage reads via
/// `QWEN_DATA_DIR`). Assistant rows carry `usageMetadata` token counts
/// (Gemini-API shape: prompt/candidates/cached/thoughts/total).
enum QwenCostSource {

    static let descriptor = LocalCostSource(
        source: .qwen,
        displayName: "Qwen Code",
        countingRevision: 1,
        roots: { QwenCostSource.dataRoots() },
        turnReader: { roots, cutoff in
            GenericJsonCostSource.turns(
                roots: roots,
                extensions: ["jsonl"],
                spec: .default,
                cutoff: cutoff,
                dedupePrefix: "qwen")
        })

    private static func dataRoots() -> [URL] {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".qwen/projects")
        if FileManager.default.fileExists(atPath: dir.path) { return [dir] }
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".qwen")
        return FileManager.default.fileExists(atPath: base.path) ? [base] : []
    }
}
