import CryptoKit
import XCTest
@testable import CodexBarCore

/// The Codex cost cache is keyed on `CodexParserHash`. A cached file whose bytes
/// have not changed is never re-parsed, so changing the counting logic without
/// rotating the hash means the new logic silently never runs against history
/// already on disk — no error, no failing test, just numbers that never move.
///
/// This test is the tripwire: edit anything under `Vendored/CostUsage/` and it
/// fails until `Scripts/regenerate-codex-parser-hash.sh` has been run.
final class CodexParserHashTests: XCTestCase {

    /// Repo root derived from this file's own path, so the test reads the real
    /// sources rather than whatever happens to be in the test bundle.
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // BirdNionTests
            .deletingLastPathComponent()  // repo root
    }

    private var parserSourcesDirectory: URL {
        repoRoot
            .appendingPathComponent("Vendor/CodexBar/Sources/CodexBarCore/Vendored/CostUsage")
    }

    /// Byte-for-byte identical to `compute()` in the regeneration script: for
    /// each `.swift` file in byte order, feed the file name then its contents.
    private func expectedHash() throws -> String {
        let files = try FileManager.default
            .contentsOfDirectory(at: parserSourcesDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent.utf8.lexicographicallyPrecedes($1.lastPathComponent.utf8) }
        XCTAssertFalse(files.isEmpty, "no parser sources at \(parserSourcesDirectory.path)")

        var digest = SHA256()
        for file in files {
            digest.update(data: Data(file.lastPathComponent.utf8))
            digest.update(data: try Data(contentsOf: file))
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    func testGeneratedHashMatchesParserSources() throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: parserSourcesDirectory.path),
            "parser sources unavailable (running outside a source checkout)")

        XCTAssertEqual(
            CodexParserHash.value,
            try expectedHash(),
            """
            CodexParserHash is stale: the vendored Codex parser changed but the \
            generated hash did not. Cached scans keep the old numbers and the \
            change never runs. Fix with:

                Scripts/regenerate-codex-parser-hash.sh

            then commit Vendor/CodexBar/Sources/CodexBarCore/Generated/\
            CodexParserHash.generated.swift with the change.
            """)
    }
}
