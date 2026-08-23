import XCTest
@testable import BirdNion

final class InstalledAgentCatalogTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-catalog-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    func testAbsentEvidenceProducesEmptyRoster() {
        let context = InstalledAgentDetectionContext(
            homeURL: tempDirectory,
            environment: [:]
        )
        let detected = InstalledAgentDetectors.detect(context: context)
        XCTAssertTrue(detected.isEmpty)
    }

    func testExactKnownMarkersProduceDeterministicCatalogOrder() {
        createDirectory(".claude")
        createDirectory(".codex")
        createDirectory(".omp/agent")

        let context = InstalledAgentDetectionContext(
            homeURL: tempDirectory,
            environment: [:]
        )
        let detected = InstalledAgentDetectors.detect(context: context)
        XCTAssertEqual(detected.map(\.id), [.claude, .codex, .omp])
    }

    func testExecutableEvidenceIsBoundedAndRedacted() {
        let binDirectory = tempDirectory.appendingPathComponent("bin")
        try? FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let customBinary = binDirectory.appendingPathComponent("pi")
        FileManager.default.createFile(atPath: customBinary.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])

        let context = InstalledAgentDetectionContext(
            homeURL: tempDirectory,
            environment: ["PATH": binDirectory.path]
        )
        let detected = InstalledAgentDetectors.detect(context: context)
        XCTAssertEqual(detected.map(\.id), [.pi])
        XCTAssertEqual(detected.first?.evidence.first?.token, "PATH:pi")
    }

    func testUnknownPathsNeverCreateRecords() {
        createDirectory(".unknown-tool")
        let context = InstalledAgentDetectionContext(
            homeURL: tempDirectory,
            environment: [:]
        )
        let detected = InstalledAgentDetectors.detect(context: context)
        XCTAssertTrue(detected.isEmpty)
    }

    private func createDirectory(_ path: String) {
        let target = tempDirectory.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    }
}
