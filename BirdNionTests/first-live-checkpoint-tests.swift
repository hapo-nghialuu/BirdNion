import XCTest
@testable import BirdNion

final class FirstLiveCheckpointTests: XCTestCase {
    private enum ReauthFailure: Error {
        case expected
    }

    func testReceiptCapturesOrderedPrivacySafeMilestones() throws {
        let attempt = try XCTUnwrap(FirstLiveAttempt.begin(
            providerId: "claude",
            detectedSource: "secret-token-should-not-persist",
            setupSavedAt: Date(timeIntervalSince1970: 100),
            probeStartedAt: Date(timeIntervalSince1970: 101),
            attemptId: try XCTUnwrap(UUID(uuidString: "11111111-1111-4111-8111-111111111111")),
            appVersion: "0.10.25"))
        let receipt = attempt.completed(
            freshResultReceivedAt: Date(timeIntervalSince1970: 102),
            liveRenderedAt: Date(timeIntervalSince1970: 102.25))

        XCTAssertTrue(receipt.isValid)
        XCTAssertEqual(receipt.providerId, "claude")
        XCTAssertEqual(receipt.source, "Claude Code / CLI")
        XCTAssertEqual(receipt.setupSavedAtMs, 100_000)
        XCTAssertEqual(receipt.probeStartedAtMs, 101_000)
        XCTAssertEqual(receipt.freshResultReceivedAtMs, 102_000)
        XCTAssertEqual(receipt.liveRenderedAtMs, 102_250)
        XCTAssertEqual(receipt.durationMilliseconds, 1_250)
        XCTAssertEqual(receipt.platform, "macos")

        let json = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
        XCTAssertFalse(json.contains("secret-token"))
    }

    func testFirstLiveSaveDispositionKeepsIndeterminateNeutral() {
        XCTAssertEqual(
            ProvidersPane.firstLiveSaveDisposition(for: .committed),
            .init(
                publishesReceipt: true,
                marksSelfTestFailed: false,
                showsRecoveryWarning: false))
        XCTAssertEqual(
            ProvidersPane.firstLiveSaveDisposition(for: .rejected),
            .init(
                publishesReceipt: false,
                marksSelfTestFailed: true,
                showsRecoveryWarning: false))
        XCTAssertEqual(
            ProvidersPane.firstLiveSaveDisposition(for: .indeterminate),
            .init(
                publishesReceipt: false,
                marksSelfTestFailed: false,
                showsRecoveryWarning: true))
    }

    func testStoreKeepsLatestValidReceiptPerProvider() throws {
        let suite = "FirstLiveCheckpointTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = try checkpoint(providerId: "codex", second: 100)
        let latest = try checkpoint(providerId: "codex", second: 200)
        let grok = try checkpoint(providerId: "grok", second: 300)
        XCTAssertTrue(FirstLiveCheckpointStore.save(first, defaults: defaults))
        XCTAssertTrue(FirstLiveCheckpointStore.save(grok, defaults: defaults))
        XCTAssertTrue(FirstLiveCheckpointStore.save(latest, defaults: defaults))
        XCTAssertFalse(FirstLiveCheckpointStore.save(first, defaults: defaults))

        let loaded = FirstLiveCheckpointStore.load(defaults: defaults)
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded["codex"], latest)
        XCTAssertEqual(loaded["grok"], grok)
    }

    func testStoreRequiresSynchronizationAndExactReadback() throws {
        let receipt = try checkpoint(providerId: "codex", second: 100)

        let acknowledged = CheckpointDefaultsDouble(
            synchronizeResult: true,
            readback: .writtenValue)
        XCTAssertTrue(FirstLiveCheckpointStore.save(receipt, defaults: acknowledged))
        XCTAssertEqual(Array(acknowledged.events.suffix(3)), ["set", "synchronize", "object"])

        let denied = CheckpointDefaultsDouble(
            synchronizeResult: false,
            readback: .writtenValue)
        XCTAssertFalse(FirstLiveCheckpointStore.save(receipt, defaults: denied))
        XCTAssertEqual(denied.synchronizeCallCount, 2)
        XCTAssertNil(denied.storedData)
        XCTAssertEqual(FirstLiveCheckpointStore.load(defaults: denied), [:])

        let mismatched = CheckpointDefaultsDouble(
            synchronizeResult: true,
            readback: .mismatchedData)
        XCTAssertFalse(FirstLiveCheckpointStore.save(receipt, defaults: mismatched))
        XCTAssertNil(mismatched.storedData)
        XCTAssertEqual(FirstLiveCheckpointStore.load(defaults: mismatched), [:])
    }

    func testFailedReceiptSaveRestoresExactPriorBytes() throws {
        let prior = try checkpoint(providerId: "codex", second: 100)
        let replacement = try checkpoint(providerId: "codex", second: 200)
        let priorData = try JSONEncoder().encode(["codex": prior])
        let denied = CheckpointDefaultsDouble(
            synchronizeResult: false,
            readback: .writtenValue,
            initialValue: priorData)

        XCTAssertFalse(FirstLiveCheckpointStore.save(replacement, defaults: denied))
        XCTAssertEqual(denied.storedData, priorData)
        XCTAssertEqual(FirstLiveCheckpointStore.load(defaults: denied), ["codex": prior])
    }

    func testFailedReceiptSaveQuarantinesCandidateWhenRollbackIsIgnored() throws {
        let prior = try checkpoint(providerId: "codex", second: 100)
        let candidate = try checkpoint(providerId: "codex", second: 200)
        let priorData = try JSONEncoder().encode(["codex": prior])
        let defaults = RollbackIgnoringCheckpointDefaultsDouble(initialValue: priorData)

        XCTAssertFalse(FirstLiveCheckpointStore.save(candidate, defaults: defaults))
        let strandedData = try XCTUnwrap(defaults.storedData)
        XCTAssertEqual(
            try JSONDecoder().decode([String: FirstLiveCheckpoint].self, from: strandedData),
            ["codex": candidate])
        XCTAssertEqual(FirstLiveCheckpointStore.load(defaults: defaults), ["codex": prior])
        XCTAssertTrue(defaults.hasRecoveryMarker)

        let missingPrior = RollbackIgnoringCheckpointDefaultsDouble(initialValue: nil)
        XCTAssertFalse(FirstLiveCheckpointStore.save(candidate, defaults: missingPrior))
        XCTAssertNotNil(missingPrior.storedData)
        XCTAssertEqual(FirstLiveCheckpointStore.load(defaults: missingPrior), [:])
        XCTAssertTrue(missingPrior.hasRecoveryMarker)
    }

    func testAcknowledgedCandidateIsNotReportedFailedWhenMarkerCleanupIsUncertain() throws {
        let prior = try checkpoint(providerId: "codex", second: 100)
        let candidate = try checkpoint(providerId: "codex", second: 200)
        let priorData = try JSONEncoder().encode(["codex": prior])
        let defaults = CleanupFailureCheckpointDefaultsDouble(initialValue: priorData)

        XCTAssertTrue(FirstLiveCheckpointStore.save(candidate, defaults: defaults))
        XCTAssertFalse(defaults.hasRecoveryMarker)
        XCTAssertEqual(FirstLiveCheckpointStore.load(defaults: defaults), ["codex": candidate])
    }

    func testAtomicFileStorePersistsPrivateCheckpointsAndRejectsCorruptState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FirstLiveCheckpointFileTests.\(UUID().uuidString)")
        let url = root
            .appendingPathComponent("BirdNion", isDirectory: true)
            .appendingPathComponent("first-live-checkpoints-v1.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try checkpoint(providerId: "codex", second: 100)
        let latest = try checkpoint(providerId: "codex", second: 200)

        XCTAssertEqual(FirstLiveCheckpointStore.save(first, url: url), .committed)
        XCTAssertEqual(FirstLiveCheckpointStore.save(latest, url: url), .committed)
        XCTAssertEqual(FirstLiveCheckpointStore.load(url: url), ["codex": latest])
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeRegular)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        try Data("{broken".utf8).write(to: url)
        XCTAssertEqual(FirstLiveCheckpointStore.load(url: url), [:])
        XCTAssertEqual(FirstLiveCheckpointStore.save(latest, url: url), .rejected)
    }

    func testAtomicFilePreCommitRouteFailureKeepsLegacyAndReportsFailure() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FirstLiveCheckpointRouteTests.\(UUID().uuidString)")
        let parent = root.appendingPathComponent("BirdNion", isDirectory: true)
        let movedParent = root.appendingPathComponent("BirdNion-moved", isDirectory: true)
        let url = parent.appendingPathComponent("first-live-checkpoints-v1.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let prior = try checkpoint(providerId: "codex", second: 100)
        let candidate = try checkpoint(providerId: "codex", second: 200)
        let priorData = try JSONEncoder().encode(["codex": prior])
        let legacy = CheckpointDefaultsDouble(
            synchronizeResult: true,
            readback: .writtenValue,
            initialValue: priorData)
        var didSwapRoute = false

        let saved = FirstLiveCheckpointStore.saveForTesting(
            candidate,
            url: url,
            legacyDefaults: legacy,
            beforeMainCommit: {
            do {
                try FileManager.default.moveItem(at: parent, to: movedParent)
                try Data("not-a-directory".utf8).write(to: parent)
                didSwapRoute = true
            } catch {
                didSwapRoute = false
            }
        })

        XCTAssertTrue(didSwapRoute)
        XCTAssertEqual(saved, .rejected)
        XCTAssertEqual(legacy.storedData, priorData)
        XCTAssertEqual(FirstLiveCheckpointStore.load(defaults: legacy), ["codex": prior])
        XCTAssertEqual(FirstLiveCheckpointStore.load(url: url), [:])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: movedParent.appendingPathComponent(url.lastPathComponent).path))
    }

    func testAtomicFileParentSwapAfterMainInstallCannotCommitCandidate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FirstLiveCheckpointPostInstallTests.\(UUID().uuidString)")
        let parent = root.appendingPathComponent("BirdNion", isDirectory: true)
        let movedParent = root.appendingPathComponent("BirdNion-moved", isDirectory: true)
        let url = parent.appendingPathComponent("first-live-checkpoints-v1.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let prior = try checkpoint(providerId: "codex", second: 100)
        let candidate = try checkpoint(providerId: "codex", second: 200)
        let priorData = try JSONEncoder().encode(["codex": prior])
        let legacy = CheckpointDefaultsDouble(
            synchronizeResult: true,
            readback: .writtenValue,
            initialValue: priorData)
        XCTAssertEqual(FirstLiveCheckpointStore.save(prior, url: url), .committed)
        var didSwapRoute = false

        let saved = FirstLiveCheckpointStore.saveForTesting(
            candidate,
            url: url,
            legacyDefaults: legacy,
            afterMainCommit: {
                do {
                    try FileManager.default.moveItem(at: parent, to: movedParent)
                    try FileManager.default.createDirectory(
                        at: parent,
                        withIntermediateDirectories: false)
                    didSwapRoute = true
                } catch {
                    didSwapRoute = false
                }
            })

        XCTAssertTrue(didSwapRoute)
        XCTAssertEqual(saved, .rejected)
        XCTAssertEqual(legacy.storedData, priorData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        try FileManager.default.removeItem(at: parent)
        try FileManager.default.moveItem(at: movedParent, to: parent)
        XCTAssertEqual(FirstLiveCheckpointStore.load(url: url), ["codex": prior])
    }

    func testCommitSlotDirectorySyncFailureRecoversPriorBeforeMainMutation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FirstLiveCheckpointCommitSlotTests.\(UUID().uuidString)")
        let url = root
            .appendingPathComponent("BirdNion", isDirectory: true)
            .appendingPathComponent("first-live-checkpoints-v1.json")
        let pendingURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).pending")
        let commitURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).commit")
        defer { try? FileManager.default.removeItem(at: root) }
        let prior = try checkpoint(providerId: "codex", second: 100)
        let candidate = try checkpoint(providerId: "codex", second: 200)
        let priorData = try JSONEncoder().encode(["codex": prior])
        let legacy = CheckpointDefaultsDouble(
            synchronizeResult: true,
            readback: .writtenValue,
            initialValue: priorData)
        XCTAssertEqual(FirstLiveCheckpointStore.save(prior, url: url), .committed)

        XCTAssertEqual(FirstLiveCheckpointStore.saveForTesting(
            candidate,
            url: url,
            legacyDefaults: legacy,
            commitSlotDirectorySync: { false }), .rejected)
        XCTAssertEqual(legacy.storedData, priorData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: commitURL.path))

        XCTAssertEqual(FirstLiveCheckpointStore.load(url: url), ["codex": prior])
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: commitURL.path))
    }

    func testParentSwapAfterCommitReadAndInvalidationFailureRollsBackMain() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FirstLiveCheckpointCommitReadTests.\(UUID().uuidString)")
        let parent = root.appendingPathComponent("BirdNion", isDirectory: true)
        let movedParent = root.appendingPathComponent("BirdNion-moved", isDirectory: true)
        let url = parent.appendingPathComponent("first-live-checkpoints-v1.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let prior = try checkpoint(providerId: "codex", second: 100)
        let candidate = try checkpoint(providerId: "codex", second: 200)
        let priorData = try JSONEncoder().encode(["codex": prior])
        let legacy = CheckpointDefaultsDouble(
            synchronizeResult: true,
            readback: .writtenValue,
            initialValue: priorData)
        XCTAssertEqual(FirstLiveCheckpointStore.save(prior, url: url), .committed)
        var didSwapRoute = false

        let saved = FirstLiveCheckpointStore.saveForTesting(
            candidate,
            url: url,
            legacyDefaults: legacy,
            afterCommitMarkerRead: {
                do {
                    try FileManager.default.moveItem(at: parent, to: movedParent)
                    try FileManager.default.createDirectory(
                        at: parent,
                        withIntermediateDirectories: false)
                    didSwapRoute = true
                } catch {
                    didSwapRoute = false
                }
            },
            commitMarkerInvalidationSync: { false })

        XCTAssertTrue(didSwapRoute)
        XCTAssertEqual(saved, .rejected)
        XCTAssertEqual(legacy.storedData, priorData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        try FileManager.default.removeItem(at: parent)
        try FileManager.default.moveItem(at: movedParent, to: parent)
        XCTAssertEqual(FirstLiveCheckpointStore.load(url: url), ["codex": prior])
    }

    func testInvalidationAndRollbackThrowsReturnIndeterminateWithoutClearingLegacy() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FirstLiveCheckpointIndeterminateTests.\(UUID().uuidString)")
        let parent = root.appendingPathComponent("BirdNion", isDirectory: true)
        let movedParent = root.appendingPathComponent("BirdNion-moved", isDirectory: true)
        let url = parent.appendingPathComponent("first-live-checkpoints-v1.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let prior = try checkpoint(providerId: "codex", second: 100)
        let candidate = try checkpoint(providerId: "codex", second: 200)
        let priorData = try JSONEncoder().encode(["codex": prior])
        let legacy = CheckpointDefaultsDouble(
            synchronizeResult: true,
            readback: .writtenValue,
            initialValue: priorData)
        XCTAssertEqual(FirstLiveCheckpointStore.save(prior, url: url), .committed)

        let outcome = FirstLiveCheckpointStore.saveForTesting(
            candidate,
            url: url,
            legacyDefaults: legacy,
            afterCommitMarkerRead: {
                try? FileManager.default.moveItem(at: parent, to: movedParent)
                try? FileManager.default.createDirectory(
                    at: parent,
                    withIntermediateDirectories: false)
            },
            beforeCommitMarkerInvalidation: { throw ReauthFailure.expected },
            beforeRollback: { throw ReauthFailure.expected })

        XCTAssertEqual(outcome, .indeterminate)
        XCTAssertEqual(legacy.storedData, priorData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        try FileManager.default.removeItem(at: parent)
        try FileManager.default.moveItem(at: movedParent, to: parent)
        XCTAssertEqual(FirstLiveCheckpointStore.load(url: url), ["codex": candidate])
    }

    func testCodexReauthNotifiesBeforeAndAfterSuccessfulMutation() async throws {
        var events: [String] = []
        let observer = NotificationCenter.default.addObserver(
            forName: .birdnionCodexAccountChanged,
            object: nil,
            queue: nil
        ) { _ in
            events.append("notification")
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        try await CodexAccountStore.reauth(id: "system") { _ in
            events.append("mutation")
        }

        XCTAssertEqual(events, ["notification", "mutation", "notification"])
    }

    func testCodexReauthNotifiesAfterFailedMutation() async {
        var events: [String] = []
        let observer = NotificationCenter.default.addObserver(
            forName: .birdnionCodexAccountChanged,
            object: nil,
            queue: nil
        ) { _ in
            events.append("notification")
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        do {
            try await CodexAccountStore.reauth(id: "system") { _ in
                events.append("mutation")
                throw ReauthFailure.expected
            }
            XCTFail("Expected injected auth mutation to fail")
        } catch ReauthFailure.expected {
            // Expected: the post-mutation notification must still be emitted.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(events, ["notification", "mutation", "notification"])
    }

    func testInvalidReceiptCannotOverwritePriorSuccess() throws {
        let suite = "FirstLiveCheckpointTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let valid = try checkpoint(providerId: "claude", second: 100)
        XCTAssertTrue(FirstLiveCheckpointStore.save(valid, defaults: defaults))

        let invalid = FirstLiveCheckpoint(
            attemptId: "not-a-uuid", providerId: "claude", source: "Claude Code",
            setupSavedAtMs: 1, probeStartedAtMs: 2,
            freshResultReceivedAtMs: 3, liveRenderedAtMs: 4,
            appVersion: "0.10.25", platform: "macos")
        XCTAssertFalse(FirstLiveCheckpointStore.save(invalid, defaults: defaults))

        let nonRFCUUID = FirstLiveCheckpoint(
            attemptId: "00000000-0000-0000-0000-000000000000",
            providerId: "claude", source: "Claude Code",
            setupSavedAtMs: 1, probeStartedAtMs: 2,
            freshResultReceivedAtMs: 3, liveRenderedAtMs: 4,
            appVersion: "0.10.25", platform: "macos")
        XCTAssertFalse(FirstLiveCheckpointStore.save(nonRFCUUID, defaults: defaults))
        XCTAssertEqual(FirstLiveCheckpointStore.load(defaults: defaults)["claude"], valid)
    }

    func testStoreNormalizesEntriesAndPreservesCorruptRoot() throws {
        let suite = "FirstLiveCheckpointTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let valid = try checkpoint(providerId: "grok", second: 100)
        var validObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        validObject["credential"] = "SECRET"
        let mixed: [String: Any] = [
            "grok": validObject,
            "codex": ["attemptId": "corrupt"],
        ]
        defaults.set(
            try JSONSerialization.data(withJSONObject: mixed),
            forKey: FirstLiveCheckpointStore.defaultsKey)

        XCTAssertEqual(FirstLiveCheckpointStore.load(defaults: defaults), ["grok": valid])
        let codex = try checkpoint(providerId: "codex", second: 200)
        XCTAssertTrue(FirstLiveCheckpointStore.save(codex, defaults: defaults))
        let normalized = try XCTUnwrap(defaults.data(forKey: FirstLiveCheckpointStore.defaultsKey))
        XCTAssertFalse(String(decoding: normalized, as: UTF8.self).contains("SECRET"))
        XCTAssertFalse(String(decoding: normalized, as: UTF8.self).contains("credential"))

        let corruptRoot = Data("{broken".utf8)
        defaults.set(corruptRoot, forKey: FirstLiveCheckpointStore.defaultsKey)
        XCTAssertEqual(FirstLiveCheckpointStore.load(defaults: defaults), [:])
        XCTAssertFalse(FirstLiveCheckpointStore.save(valid, defaults: defaults))
        XCTAssertEqual(defaults.data(forKey: FirstLiveCheckpointStore.defaultsKey), corruptRoot)

        let unknownRoot = try JSONSerialization.data(withJSONObject: ["unknown": validObject])
        defaults.set(unknownRoot, forKey: FirstLiveCheckpointStore.defaultsKey)
        XCTAssertEqual(FirstLiveCheckpointStore.load(defaults: defaults), [:])
        XCTAssertFalse(FirstLiveCheckpointStore.save(valid, defaults: defaults))

        let oversizedRoot = Data(repeating: 0x20, count: 64 * 1024 + 1)
        defaults.set(oversizedRoot, forKey: FirstLiveCheckpointStore.defaultsKey)
        XCTAssertEqual(FirstLiveCheckpointStore.load(defaults: defaults), [:])
        XCTAssertFalse(FirstLiveCheckpointStore.save(valid, defaults: defaults))
    }

    func testFutureReceiptIsDroppedAndCannotLockCurrentSuccess() throws {
        let suite = "FirstLiveCheckpointTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let current = try checkpoint(providerId: "claude", second: 400)
        let futureMs = Int64(Date().addingTimeInterval(86_400).timeIntervalSince1970 * 1_000)
        let future = FirstLiveCheckpoint(
            attemptId: "22222222-2222-4222-8222-222222222222",
            providerId: "claude",
            source: "Claude Code",
            setupSavedAtMs: futureMs,
            probeStartedAtMs: futureMs + 1,
            freshResultReceivedAtMs: futureMs + 2,
            liveRenderedAtMs: futureMs + 3,
            appVersion: "0.10.25",
            platform: "macos")
        XCTAssertFalse(future.isValid)
        defaults.set(
            try JSONEncoder().encode(["claude": future]),
            forKey: FirstLiveCheckpointStore.defaultsKey)

        XCTAssertEqual(FirstLiveCheckpointStore.load(defaults: defaults), [:])
        XCTAssertTrue(FirstLiveCheckpointStore.save(current, defaults: defaults))
        XCTAssertEqual(FirstLiveCheckpointStore.load(defaults: defaults)["claude"], current)

        let nearFutureMs = Int64(Date().addingTimeInterval(4 * 60).timeIntervalSince1970 * 1_000)
        let nearFuture = FirstLiveCheckpoint(
            attemptId: "33333333-3333-4333-8333-333333333333",
            providerId: "claude",
            source: "Claude Code",
            setupSavedAtMs: nearFutureMs,
            probeStartedAtMs: nearFutureMs + 1,
            freshResultReceivedAtMs: nearFutureMs + 2,
            liveRenderedAtMs: nearFutureMs + 3,
            appVersion: "0.10.25",
            platform: "macos")
        XCTAssertTrue(nearFuture.isValid)
        defaults.set(
            try JSONEncoder().encode(["claude": nearFuture]),
            forKey: FirstLiveCheckpointStore.defaultsKey)
        XCTAssertEqual(FirstLiveCheckpointStore.load(defaults: defaults)["claude"], nearFuture)
        XCTAssertFalse(FirstLiveCheckpointStore.save(nearFuture, defaults: defaults))
        XCTAssertTrue(FirstLiveCheckpointStore.save(current, defaults: defaults))
        XCTAssertEqual(FirstLiveCheckpointStore.load(defaults: defaults)["claude"], current)
    }

    func testUnknownVersionAndCrossProviderSourceFailClosed() throws {
        XCTAssertNil(FirstLiveAttempt.begin(
            providerId: "claude", detectedSource: "Claude Code", appVersion: "unknown"))
        XCTAssertNil(FirstLiveAttempt.begin(
            providerId: "claude",
            detectedSource: "Claude Code",
            appVersion: "token=sk-secret"))
        XCTAssertNil(FirstLiveAttempt.begin(
            providerId: "claude",
            detectedSource: "Claude Code",
            appVersion: "sk-ant-api03-abcdef123456"))
        let attempt = try XCTUnwrap(FirstLiveAttempt.begin(
            providerId: "claude",
            detectedSource: "Grok sessions",
            setupSavedAt: Date(timeIntervalSince1970: 100),
            probeStartedAt: Date(timeIntervalSince1970: 101),
            appVersion: "0.10.25"))
        XCTAssertEqual(attempt.source, "Claude Code / CLI")
        XCTAssertNotNil(FirstLiveAttempt.begin(
            providerId: "claude",
            detectedSource: "Claude Code",
            appVersion: "0.10.25-beta.1"))
    }

    private func checkpoint(providerId: String, second: TimeInterval) throws -> FirstLiveCheckpoint {
        let source = providerId == "claude" ? "Claude Code"
            : providerId == "codex" ? "Codex CLI" : "Grok sessions"
        let start = Date(timeIntervalSince1970: second)
        let attempt = try XCTUnwrap(FirstLiveAttempt.begin(
            providerId: providerId, detectedSource: source,
            setupSavedAt: start, probeStartedAt: start,
            appVersion: "0.10.25"))
        return attempt.completed(
            freshResultReceivedAt: start.addingTimeInterval(1),
            liveRenderedAt: start.addingTimeInterval(2))
    }
}

private final class CheckpointDefaultsDouble: FirstLiveCheckpointDefaults {
    enum Readback {
        case writtenValue
        case mismatchedData
    }

    private let synchronizeResult: Bool
    private let readback: Readback
    private var values: [String: Any]
    private var didSet = false
    private var mismatchNextRead = false
    private(set) var events: [String] = []
    private(set) var synchronizeCallCount = 0
    var storedData: Data? { values[FirstLiveCheckpointStore.defaultsKey] as? Data }

    init(synchronizeResult: Bool, readback: Readback, initialValue: Any? = nil) {
        self.synchronizeResult = synchronizeResult
        self.readback = readback
        if let initialValue {
            self.values = [FirstLiveCheckpointStore.defaultsKey: initialValue]
        } else {
            self.values = [:]
        }
    }

    func object(forKey defaultName: String) -> Any? {
        events.append("object")
        if mismatchNextRead {
            mismatchNextRead = false
            return Data("mismatch".utf8)
        }
        return values[defaultName]
    }

    func set(_ value: Any?, forKey defaultName: String) {
        events.append("set")
        if let value {
            values[defaultName] = value
        } else {
            values.removeValue(forKey: defaultName)
        }
        if defaultName == FirstLiveCheckpointStore.defaultsKey, !didSet {
            didSet = true
            mismatchNextRead = readback == .mismatchedData
        }
    }

    func synchronize() -> Bool {
        events.append("synchronize")
        synchronizeCallCount += 1
        return synchronizeResult
    }
}

private final class RollbackIgnoringCheckpointDefaultsDouble: FirstLiveCheckpointDefaults {
    private var values: [String: Any]
    private var didAcceptCandidate = false

    var storedData: Data? {
        values[FirstLiveCheckpointStore.defaultsKey] as? Data
    }

    var hasRecoveryMarker: Bool {
        values.keys.contains { $0 != FirstLiveCheckpointStore.defaultsKey }
    }

    init(initialValue: Data?) {
        if let initialValue {
            values = [FirstLiveCheckpointStore.defaultsKey: initialValue]
        } else {
            values = [:]
        }
    }

    func object(forKey defaultName: String) -> Any? {
        values[defaultName]
    }

    func set(_ value: Any?, forKey defaultName: String) {
        if defaultName == FirstLiveCheckpointStore.defaultsKey {
            guard !didAcceptCandidate else { return }
            didAcceptCandidate = true
        }
        if let value {
            values[defaultName] = value
        } else {
            values.removeValue(forKey: defaultName)
        }
    }

    func synchronize() -> Bool {
        !didAcceptCandidate
    }
}

private final class CleanupFailureCheckpointDefaultsDouble: FirstLiveCheckpointDefaults {
    private var values: [String: Any]
    private var synchronizeCallCount = 0
    private var didRemoveRecoveryMarker = false

    var hasRecoveryMarker: Bool {
        values.keys.contains { $0 != FirstLiveCheckpointStore.defaultsKey }
    }

    init(initialValue: Data) {
        values = [FirstLiveCheckpointStore.defaultsKey: initialValue]
    }

    func object(forKey defaultName: String) -> Any? {
        values[defaultName]
    }

    func set(_ value: Any?, forKey defaultName: String) {
        if defaultName != FirstLiveCheckpointStore.defaultsKey {
            if value == nil {
                didRemoveRecoveryMarker = true
                values.removeValue(forKey: defaultName)
            } else if !didRemoveRecoveryMarker {
                values[defaultName] = value
            }
            return
        }
        if let value {
            values[defaultName] = value
        } else {
            values.removeValue(forKey: defaultName)
        }
    }

    func synchronize() -> Bool {
        synchronizeCallCount += 1
        return synchronizeCallCount <= 2
    }
}
