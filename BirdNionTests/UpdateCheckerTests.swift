import XCTest
@testable import BirdNion

/// Pure-logic tests for the GitHub-releases update checker and the provider
/// storage byte formatting.
final class UpdateCheckerTests: XCTestCase {
    // MARK: - SemVer

    func testIsNewerBasicOrdering() {
        XCTAssertTrue(SemVer.isNewer("0.8.3", than: "0.8.2"))
        XCTAssertTrue(SemVer.isNewer("v1.0.0", than: "0.9.9"))
        XCTAssertTrue(SemVer.isNewer("0.9", than: "0.8.9"))
        XCTAssertFalse(SemVer.isNewer("0.8.2", than: "0.8.2"))
        XCTAssertFalse(SemVer.isNewer("0.8.1", than: "0.8.2"))
        XCTAssertFalse(SemVer.isNewer("v0.8.2", than: "0.8.2"))
    }

    func testIsNewerHandlesShorterComponentLists() {
        XCTAssertTrue(SemVer.isNewer("1.0.1", than: "1.0"))
        XCTAssertFalse(SemVer.isNewer("1.0", than: "1.0.0"))
    }

    func testPrereleaseSortsBelowRelease() {
        // Same numbers: prerelease is NOT newer than the release…
        XCTAssertFalse(SemVer.isNewer("1.2.0-beta.1", than: "1.2.0"))
        // …but the final release IS newer than its own prerelease.
        XCTAssertTrue(SemVer.isNewer("1.2.0", than: "1.2.0-beta.1"))
        // Higher numeric wins regardless of prerelease flags.
        XCTAssertTrue(SemVer.isNewer("1.3.0-beta.1", than: "1.2.9"))
    }

    // MARK: - pickLatest

    private func release(_ tag: String, prerelease: Bool = false, draft: Bool = false) -> GitHubRelease {
        GitHubRelease(tagName: tag, htmlURL: "https://example.com/\(tag)",
                      prerelease: prerelease, draft: draft)
    }

    func testPickLatestStableSkipsPrereleasesAndDrafts() {
        let releases = [
            release("v0.9.0-beta.1", prerelease: true),
            release("v0.9.1", draft: true),
            release("v0.8.5"),
            release("v0.8.4"),
        ]
        let picked = UpdateChecker.pickLatest(releases, channel: "stable", currentVersion: "0.8.2")
        XCTAssertEqual(picked?.tagName, "v0.8.5")
    }

    func testPickLatestBetaIncludesPrereleases() {
        let releases = [
            release("v0.9.0-beta.1", prerelease: true),
            release("v0.8.5"),
        ]
        let picked = UpdateChecker.pickLatest(releases, channel: "beta", currentVersion: "0.8.2")
        XCTAssertEqual(picked?.tagName, "v0.9.0-beta.1")
    }

    func testPickLatestReturnsNilWhenUpToDate() {
        let releases = [release("v0.8.2"), release("v0.8.1")]
        XCTAssertNil(UpdateChecker.pickLatest(releases, channel: "stable", currentVersion: "0.8.2"))
        XCTAssertNil(UpdateChecker.pickLatest([], channel: "stable", currentVersion: "0.8.2"))
    }

    // MARK: - Storage formatting

    func testFormatBytesUsesFileStyleUnits() {
        XCTAssertFalse(ProviderStorageScanner.formatBytes(0).isEmpty)
        XCTAssertTrue(ProviderStorageScanner.formatBytes(1_500_000).contains("MB"))
        XCTAssertTrue(ProviderStorageScanner.formatBytes(2_000_000_000).contains("GB"))
    }

    func testCandidatePathsOnlyForKnownProviders() {
        XCTAssertFalse(ProviderStoragePaths.candidatePaths(for: "claude").isEmpty)
        XCTAssertFalse(ProviderStoragePaths.candidatePaths(for: "codex").isEmpty)
        XCTAssertTrue(ProviderStoragePaths.candidatePaths(for: "openrouter").isEmpty)
    }

    func testScanSumsRegularFilesAndSkipsMissingDirs() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: base.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        try Data(count: 1_000).write(to: base.appendingPathComponent("a.bin"))
        try Data(count: 2_000).write(to: base.appendingPathComponent("sub/b.bin"))

        let footprint = ProviderStorageScanner.scan(
            id: "claude",
            paths: [base.path, base.appendingPathComponent("missing").path])

        XCTAssertEqual(footprint.totalBytes, 3_000)
        XCTAssertEqual(footprint.existingPaths, [base.path])
    }
}
