import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import BirdNion

final class CodexProviderTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-test-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("auth.json")
    }

    private func makeStubConfig() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubURLProtocol.self] + (c.protocolClasses ?? [])
        return c
    }

    // MARK: - CodexAuthStore.parse

    func testParseOAuthTokens() throws {
        let json = """
        {"tokens":{"access_token":"at","refresh_token":"rt","id_token":"it","account_id":"acc"},
         "last_refresh":"2026-06-01T00:00:00Z"}
        """.data(using: .utf8)!
        let creds = try CodexAuthStore.parse(json)
        XCTAssertEqual(creds.accessToken, "at")
        XCTAssertEqual(creds.refreshToken, "rt")
        XCTAssertEqual(creds.accountId, "acc")
        XCTAssertNotNil(creds.lastRefresh)
    }

    func testParseAPIKeyFallback() throws {
        let json = #"{"OPENAI_API_KEY":"sk-test"}"#.data(using: .utf8)!
        let creds = try CodexAuthStore.parse(json)
        XCTAssertEqual(creds.accessToken, "sk-test")
        XCTAssertTrue(creds.refreshToken.isEmpty)
    }

    func testPrivateJSONReadRejectsSymlinkFIFOAndOversizedFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-private-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let target = directory.appendingPathComponent("target.json")
        try Data("{}".utf8).write(to: target)
        let link = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try CodexAuthStore.readPrivateFile(link))

        let fifo = directory.appendingPathComponent("fifo.json")
        XCTAssertEqual(fifo.path.withCString { Darwin.mkfifo($0, 0o600) }, 0)
        XCTAssertThrowsError(try CodexAuthStore.readPrivateFile(fifo))

        let oversized = directory.appendingPathComponent("oversized.json")
        FileManager.default.createFile(atPath: oversized.path, contents: Data())
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(CodexAuthStore.maxPrivateJSONBytes + 1))
        try handle.close()
        XCTAssertThrowsError(try CodexAuthStore.readPrivateFile(oversized))
    }

    func testManagedBindingRejectsAccountsRootSwappedToSymlinkBeforeBind() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-root-prebind-swap-\(UUID().uuidString)", isDirectory: true)
        let accountsRoot = base.appendingPathComponent("codex-accounts", isDirectory: true)
        let detachedRoot = base.appendingPathComponent("detached-accounts", isDirectory: true)
        let attackerRoot = base.appendingPathComponent("attacker", isDirectory: true)
        let accountID = "44444444-4444-4444-8444-444444444444"
        let originalHome = accountsRoot.appendingPathComponent(accountID, isDirectory: true)
        let attackerHome = attackerRoot.appendingPathComponent(accountID, isDirectory: true)
        try FileManager.default.createDirectory(at: originalHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: attackerHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let attackerAuth = attackerHome.appendingPathComponent("auth.json")
        let sentinel = Data("external-must-not-bind".utf8)
        try sentinel.write(to: attackerAuth)

        try FileManager.default.moveItem(at: accountsRoot, to: detachedRoot)
        try FileManager.default.createSymbolicLink(
            at: accountsRoot, withDestinationURL: attackerRoot)

        XCTAssertThrowsError(try CodexAuthStore.bindManagedCredential(
            accountsRoot: accountsRoot,
            accountID: accountID))
        XCTAssertEqual(try Data(contentsOf: attackerAuth), sentinel)
    }

    func testManagedBindingRejectsRealRootReplacementAfterValidation() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-root-identity-swap-\(UUID().uuidString)", isDirectory: true)
        let accountsRoot = base.appendingPathComponent("codex-accounts", isDirectory: true)
        let detachedRoot = base.appendingPathComponent("detached-accounts", isDirectory: true)
        let accountID = "77777777-7777-4777-8777-777777777777"
        let originalHome = accountsRoot.appendingPathComponent(accountID, isDirectory: true)
        try FileManager.default.createDirectory(at: originalHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        var rootInfo = stat()
        var homeInfo = stat()
        XCTAssertEqual(accountsRoot.path.withCString { lstat($0, &rootInfo) }, 0)
        XCTAssertEqual(originalHome.path.withCString { lstat($0, &homeInfo) }, 0)
        let expectedRoot = CodexAuthStore.FileIdentity(rootInfo)
        let expectedHome = CodexAuthStore.FileIdentity(homeInfo)

        try FileManager.default.moveItem(at: accountsRoot, to: detachedRoot)
        let replacementHome = accountsRoot.appendingPathComponent(accountID, isDirectory: true)
        try FileManager.default.createDirectory(
            at: replacementHome, withIntermediateDirectories: true)
        let replacementAuth = replacementHome.appendingPathComponent("auth.json")
        let sentinel = Data("replacement-must-not-bind".utf8)
        try sentinel.write(to: replacementAuth)

        XCTAssertThrowsError(try CodexAuthStore.bindManagedCredential(
            accountsRoot: accountsRoot,
            accountID: accountID,
            expectedAccountsRootIdentity: expectedRoot,
            expectedAccountIdentity: expectedHome))
        XCTAssertEqual(try Data(contentsOf: replacementAuth), sentinel)
    }

    func testAuthSaveFailsClosedOnMalformedExistingDocument() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("{malformed".utf8)
        try original.write(to: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let credentials = CodexCredentials(
            accessToken: "new-access", refreshToken: "new-refresh",
            idToken: nil, accountId: nil, lastRefresh: nil)
        XCTAssertThrowsError(try CodexAuthStore.save(credentials, url: url))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testParseMissingTokens() {
        let json = #"{"other":1}"#.data(using: .utf8)!
        XCTAssertThrowsError(try CodexAuthStore.parse(json)) { error in
            XCTAssertEqual(error as? CodexAuthError, .missingTokens)
        }
    }

    func testLoadNotFound() {
        XCTAssertThrowsError(try CodexAuthStore.load(url: tempURL())) { error in
            XCTAssertEqual(error as? CodexAuthError, .notFound)
        }
    }

    func testSaveRoundTripPrivatePermissions() throws {
        let url = tempURL()
        let creds = CodexCredentials(
            accessToken: "new-at", refreshToken: "new-rt",
            idToken: nil, accountId: "acc", lastRefresh: Date())
        try CodexAuthStore.save(creds, url: url)
        let reloaded = try CodexAuthStore.load(url: url)
        XCTAssertEqual(reloaded.accessToken, "new-at")
        XCTAssertEqual(reloaded.refreshToken, "new-rt")

        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.int16Value, 0o600)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func testConditionalRefreshSaveRejectsReauthAndRemoval() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let alice = Data(#"{"tokens":{"access_token":"alice","refresh_token":"alice-r"}}"#.utf8)
        let bob = Data(#"{"tokens":{"access_token":"bob","refresh_token":"bob-r"}}"#.utf8)
        try alice.write(to: url)
        let loaded = try CodexAuthStore.loadDocument(url: url)
        let refreshedAlice = CodexCredentials(
            accessToken: "alice-new", refreshToken: "alice-r2",
            idToken: nil, accountId: nil, lastRefresh: Date())

        try bob.write(to: url)
        XCTAssertNil(try CodexAuthStore.saveIfUnchanged(
            refreshedAlice,
            url: url,
            expectedData: loaded.rawData,
            expectedRevision: loaded.revision))
        XCTAssertEqual(try CodexAuthStore.load(url: url).accessToken, "bob")

        try FileManager.default.removeItem(at: url)
        XCTAssertNil(try CodexAuthStore.saveIfUnchanged(
            refreshedAlice,
            url: url,
            expectedData: bob,
            expectedRevision: loaded.revision))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testConditionalRefreshSaveWritesOnlyMatchingDocument() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original = Data(#"{"custom":7,"tokens":{"access_token":"old","refresh_token":"r"}}"#.utf8)
        try original.write(to: url)
        let refreshed = CodexCredentials(
            accessToken: "new", refreshToken: "r2",
            idToken: nil, accountId: nil, lastRefresh: Date())
        let loaded = try CodexAuthStore.loadDocument(url: url)

        let written = try CodexAuthStore.saveIfUnchanged(
            refreshed,
            url: url,
            expectedData: loaded.rawData,
            expectedRevision: loaded.revision)

        XCTAssertNotNil(written)
        XCTAssertEqual(try CodexAuthStore.load(url: url).accessToken, "new")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(json?["custom"] as? Int, 7)
    }

    func testExternalReplaceBetweenCompareAndCommitWinsCAS() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-external-cas-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("auth.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = Data(#"{"tokens":{"access_token":"account-a","refresh_token":"a-r"}}"#.utf8)
        let refreshed = Data(#"{"tokens":{"access_token":"stale-a","refresh_token":"a-r2"}}"#.utf8)
        let external = Data(#"{"tokens":{"access_token":"account-b","refresh_token":"b-r"}}"#.utf8)
        try original.write(to: url)

        let committed = try CodexAuthStore.replacePrivateFileIfUnchanged(
            refreshed,
            to: url,
            replacing: original,
            beforeCommit: {
                try! external.write(to: url, options: .atomic)
            })

        XCTAssertFalse(committed)
        XCTAssertEqual(try Data(contentsOf: url), external)
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: directory.path).filter { $0.contains(".birdnion-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testExternalSpecialEntryIsRestoredAfterCASSwap() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-special-cas-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("auth.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = Data(#"{"tokens":{"access_token":"account-a","refresh_token":"a-r"}}"#.utf8)
        let refreshed = Data(#"{"tokens":{"access_token":"stale-a","refresh_token":"a-r2"}}"#.utf8)
        try original.write(to: url)

        XCTAssertThrowsError(try CodexAuthStore.replacePrivateFileIfUnchanged(
            refreshed,
            to: url,
            replacing: original,
            beforeCommit: {
                try! FileManager.default.removeItem(at: url)
                try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            }))
        var directoryInfo = stat()
        XCTAssertEqual(url.path.withCString { lstat($0, &directoryInfo) }, 0)
        XCTAssertEqual(directoryInfo.st_mode & mode_t(S_IFMT), mode_t(S_IFDIR))

        try FileManager.default.removeItem(at: url)
        try original.write(to: url)
        XCTAssertThrowsError(try CodexAuthStore.replacePrivateFileIfUnchanged(
            refreshed,
            to: url,
            replacing: original,
            beforeCommit: {
                try! FileManager.default.removeItem(at: url)
                try! FileManager.default.createSymbolicLink(
                    at: url,
                    withDestinationURL: directory.appendingPathComponent("missing"))
            }))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: url.path),
            directory.appendingPathComponent("missing").path)
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: directory.path).filter { $0.contains(".birdnion-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testCredentialInvalidationRejectsOtherwiseMatchingRefreshSave() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original = Data(#"{"tokens":{"access_token":"alice","refresh_token":"r"}}"#.utf8)
        try original.write(to: url)
        let loaded = try CodexAuthStore.loadDocument(url: url)
        CodexAuthStore.invalidateCredential(at: url)
        let refreshed = CodexCredentials(
            accessToken: "alice-new", refreshToken: "r2",
            idToken: nil, accountId: nil, lastRefresh: Date())

        XCTAssertNil(try CodexAuthStore.saveIfUnchanged(
            refreshed,
            url: url,
            expectedData: loaded.rawData,
            expectedRevision: loaded.revision))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testManagedRemovalInvalidationRejectsCommitAfterHomeBecomesSymlink() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-bound-removal-\(UUID().uuidString)", isDirectory: true)
        let accountsRoot = base.appendingPathComponent("accounts", isDirectory: true)
        let accountID = "22222222-2222-4222-8222-222222222222"
        let managedHome = accountsRoot.appendingPathComponent(accountID, isDirectory: true)
        let tombstoneName = ".removed-account"
        let tombstone = accountsRoot.appendingPathComponent(tombstoneName, isDirectory: true)
        let systemHome = base.appendingPathComponent("system", isDirectory: true)
        let managedAuth = managedHome.appendingPathComponent("auth.json")
        let systemAuth = systemHome.appendingPathComponent("auth.json")
        try FileManager.default.createDirectory(at: managedHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: systemHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let original = Data(
            #"{"tokens":{"access_token":"same-old","refresh_token":"same-r"}}"#.utf8)
        try original.write(to: managedAuth)
        try original.write(to: systemAuth)

        let binding = try CodexAuthStore.bindManagedCredential(
            accountsRoot: accountsRoot,
            accountID: accountID,
            authURL: managedAuth)
        let loaded = try CodexAuthStore.loadDocument(binding: binding)
        CodexAuthStore.invalidateCredential(binding: binding)
        try binding.stageContainingDirectory(as: tombstoneName)
        try FileManager.default.createSymbolicLink(
            at: managedHome, withDestinationURL: systemHome)

        let committed = try CodexAuthStore.saveIfUnchanged(
            CodexCredentials(
                accessToken: "stale-refresh", refreshToken: "same-r2",
                idToken: nil, accountId: nil, lastRefresh: Date()),
            binding: binding,
            expectedData: loaded.rawData,
            expectedRevision: loaded.revision)

        XCTAssertNil(committed)
        XCTAssertFalse(CodexAuthStore.documentIsCurrent(
            binding: binding,
            expectedData: loaded.rawData,
            expectedRevision: loaded.revision))
        XCTAssertEqual(try Data(contentsOf: systemAuth), original)
        XCTAssertEqual(try Data(contentsOf: tombstone.appendingPathComponent("auth.json")), original)
    }

    func testCredentialCopyPublishesLatestRefreshCommit() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-copy-latest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.json")
        let destination = directory.appendingPathComponent("destination.json")
        let original = Data(#"{"tokens":{"access_token":"old","refresh_token":"r"}}"#.utf8)
        try original.write(to: source)
        let loaded = try CodexAuthStore.loadDocument(url: source)
        let refreshed = CodexCredentials(
            accessToken: "latest", refreshToken: "r2",
            idToken: nil, accountId: nil, lastRefresh: Date())
        XCTAssertNotNil(try CodexAuthStore.saveIfUnchanged(
            refreshed, url: source,
            expectedData: loaded.rawData,
            expectedRevision: loaded.revision))

        XCTAssertTrue(try CodexAuthStore.copyCredential(from: source, to: destination))
        XCTAssertEqual(try CodexAuthStore.load(url: destination).accessToken, "latest")
    }

    func testCredentialCopyRejectsMalformedSourceWithoutChangingDestination() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-copy-malformed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.json")
        let destination = directory.appendingPathComponent("destination.json")
        let malformed = Data(#"{"unrelated":"not-a-credential"}"#.utf8)
        let original = Data(
            #"{"tokens":{"access_token":"system-valid","refresh_token":"system-r"}}"#.utf8)
        try malformed.write(to: source)
        try original.write(to: destination)

        XCTAssertFalse(try CodexAuthStore.copyCredential(from: source, to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), original)

        let expectation = try CodexAuthStore.captureFileExpectation(url: destination)
        XCTAssertFalse(try CodexAuthStore.copyCredential(
            from: source,
            to: destination,
            ifDestinationMatches: expectation))
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }

    func testConditionalCredentialCopySkipsNewerDestination() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-copy-newer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.json")
        let destination = directory.appendingPathComponent("destination.json")
        try Data(#"{"tokens":{"access_token":"source","refresh_token":"r"}}"#.utf8)
            .write(to: source)
        let destinationData = Data(
            #"{"tokens":{"access_token":"destination","refresh_token":"r"}}"#.utf8)
        try destinationData.write(to: destination)
        let now = Date()
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: source.path)
        try FileManager.default.setAttributes(
            [.modificationDate: now], ofItemAtPath: destination.path)

        XCTAssertFalse(try CodexAuthStore.copyCredential(
            from: source, to: destination, onlyIfSourceNewer: true))
        XCTAssertEqual(try Data(contentsOf: destination), destinationData)
    }

    func testCredentialCopyInvalidatesOlderDestinationRefreshSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-copy-revision-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.json")
        let destination = directory.appendingPathComponent("destination.json")
        try Data(#"{"tokens":{"access_token":"source","refresh_token":"r"}}"#.utf8)
            .write(to: source)
        try Data(#"{"tokens":{"access_token":"stale","refresh_token":"r"}}"#.utf8)
            .write(to: destination)
        let staleSourceLoad = try CodexAuthStore.loadDocument(url: source)
        let staleLoad = try CodexAuthStore.loadDocument(url: destination)

        XCTAssertTrue(try CodexAuthStore.copyCredential(from: source, to: destination))
        XCTAssertNil(try CodexAuthStore.saveIfUnchanged(
            CodexCredentials(
                accessToken: "source-stale-refresh", refreshToken: "r3",
                idToken: nil, accountId: nil, lastRefresh: Date()),
            url: source,
            expectedData: staleSourceLoad.rawData,
            expectedRevision: staleSourceLoad.revision))
        XCTAssertNil(try CodexAuthStore.saveIfUnchanged(
            CodexCredentials(
                accessToken: "stale-refresh", refreshToken: "r2",
                idToken: nil, accountId: nil, lastRefresh: Date()),
            url: destination,
            expectedData: staleLoad.rawData,
            expectedRevision: staleLoad.revision))
        XCTAssertEqual(try CodexAuthStore.load(url: destination).accessToken, "source")
    }

    func testTrackedCredentialPairReconcilesNewerManagedTokenButRejectsExternalIdentity() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-pair-reconcile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let system = directory.appendingPathComponent("system.json")
        let managed = directory.appendingPathComponent("managed.json")
        try Data(#"{"tokens":{"access_token":"old","refresh_token":"old-r","account_id":"acct-a"},"last_refresh":"2026-08-24T00:00:00Z"}"#.utf8)
            .write(to: system)
        try Data(#"{"tokens":{"access_token":"new","refresh_token":"new-r","account_id":"acct-a"},"last_refresh":"2026-08-25T00:00:00Z"}"#.utf8)
            .write(to: managed)

        XCTAssertEqual(
            try CodexAuthStore.reconcileCredentialPair(first: system, second: managed),
            .copiedSecondToFirst)
        XCTAssertEqual(try CodexAuthStore.load(url: system).accessToken, "new")

        try Data(#"{"tokens":{"access_token":"external","refresh_token":"external-r","account_id":"acct-b"},"last_refresh":"2026-08-26T00:00:00Z"}"#.utf8)
            .write(to: system)
        XCTAssertEqual(
            try CodexAuthStore.reconcileCredentialPair(first: system, second: managed),
            .identityMismatch)
        XCTAssertEqual(try CodexAuthStore.load(url: managed).accountId, "acct-a")
    }

    func testReauthCopyAllowsIntentionalIdentityChangeOnlyWhileSystemBytesStayExact() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-reauth-copy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let managed = directory.appendingPathComponent("managed.json")
        let system = directory.appendingPathComponent("system.json")
        try Data(#"{"tokens":{"access_token":"old-a","refresh_token":"old-r","account_id":"acct-a"}}"#.utf8)
            .write(to: system)
        let captured = try CodexAuthStore.loadDocument(url: system)
        try Data(#"{"tokens":{"access_token":"new-b","refresh_token":"new-r","account_id":"acct-b"}}"#.utf8)
            .write(to: managed)

        XCTAssertTrue(try CodexAuthStore.copyCredentialIfDestinationUnchanged(
            from: managed,
            to: system,
            expectedDestinationData: captured.rawData,
            expectedDestinationRevision: captured.revision))
        XCTAssertEqual(try CodexAuthStore.load(url: system).accountId, "acct-b")

        let secondCapture = try CodexAuthStore.loadDocument(url: system)
        try Data(#"{"tokens":{"access_token":"external-c","refresh_token":"external-r","account_id":"acct-c"}}"#.utf8)
            .write(to: system)
        XCTAssertFalse(try CodexAuthStore.copyCredentialIfDestinationUnchanged(
            from: managed,
            to: system,
            expectedDestinationData: secondCapture.rawData,
            expectedDestinationRevision: secondCapture.revision))
        XCTAssertEqual(try CodexAuthStore.load(url: system).accountId, "acct-c")
    }

    func testTransactionBoundCopyRejectsLateSystemLoginForPresentAndAbsentStart() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-switch-boundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let managed = directory.appendingPathComponent("managed.json")
        let system = directory.appendingPathComponent("system.json")
        try Data(#"{"tokens":{"access_token":"managed-a","refresh_token":"managed-r","account_id":"acct-a"}}"#.utf8)
            .write(to: managed)
        try Data(#"{"tokens":{"access_token":"system-old","refresh_token":"old-r","account_id":"acct-old"}}"#.utf8)
            .write(to: system)
        let presentExpectation = try CodexAuthStore.captureFileExpectation(url: system)
        try Data(#"{"tokens":{"access_token":"external-b","refresh_token":"b-r","account_id":"acct-b"}}"#.utf8)
            .write(to: system, options: .atomic)

        XCTAssertFalse(try CodexAuthStore.copyCredential(
            from: managed,
            to: system,
            ifDestinationMatches: presentExpectation))
        XCTAssertEqual(try CodexAuthStore.load(url: system).accountId, "acct-b")

        try FileManager.default.removeItem(at: system)
        let absentExpectation = try CodexAuthStore.captureFileExpectation(url: system)
        try Data(#"{"tokens":{"access_token":"external-c","refresh_token":"c-r","account_id":"acct-c"}}"#.utf8)
            .write(to: system, options: .atomic)
        XCTAssertFalse(try CodexAuthStore.copyCredential(
            from: managed,
            to: system,
            ifDestinationMatches: absentExpectation))
        XCTAssertEqual(try CodexAuthStore.load(url: system).accountId, "acct-c")
    }

    // MARK: - needsRefresh

    func testNeedsRefreshBoundary() {
        let stale = CodexCredentials(accessToken: "a", refreshToken: "r", idToken: nil,
                                     accountId: nil, lastRefresh: Date().addingTimeInterval(-9 * 86400))
        let fresh = CodexCredentials(accessToken: "a", refreshToken: "r", idToken: nil,
                                     accountId: nil, lastRefresh: Date())
        let never = CodexCredentials(accessToken: "a", refreshToken: "r", idToken: nil,
                                     accountId: nil, lastRefresh: nil)
        XCTAssertTrue(stale.needsRefresh)
        XCTAssertFalse(fresh.needsRefresh)
        XCTAssertTrue(never.needsRefresh)
    }

    // MARK: - Usage decode + map

    private let usageJSON = """
    {"plan_type":"plus","rate_limit":{
      "primary_window":{"used_percent":42,"reset_at":1750000000,"limit_window_seconds":18000},
      "secondary_window":{"used_percent":8,"reset_at":1750500000,"limit_window_seconds":604800}}}
    """.data(using: .utf8)!

    func testDecodeAndMapWindows() throws {
        let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: usageJSON)
        XCTAssertEqual(usage.planType, "plus")
        let windows = CodexProvider.map(usage)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].label, "5 giờ")
        XCTAssertEqual(windows[0].usedPct, 42)
        XCTAssertEqual(windows[0].remainingPct, 58)
        XCTAssertEqual(windows[0].resetDate, Date(timeIntervalSince1970: 1_750_000_000))
        XCTAssertEqual(windows[1].label, "Tuần")
        XCTAssertEqual(windows[1].remainingPct, 92)
    }

    func testSparkWindowLabelDetection() {
        XCTAssertTrue(CodexProvider.isSparkWindowLabel("Codex Spark 5 giờ"))
        XCTAssertTrue(CodexProvider.isSparkWindowLabel("Codex Spark Tuần"))
        XCTAssertTrue(CodexProvider.isSparkWindowLabel("CODEX SPARK"))
        XCTAssertFalse(CodexProvider.isSparkWindowLabel("5 giờ"))
        XCTAssertFalse(CodexProvider.isSparkWindowLabel("Tuần"))
    }

    func testDecodeCreditsNumber() throws {
        let json = #"{"plan_type":"plus","credits":{"balance":12.5}}"#.data(using: .utf8)!
        let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: json)
        XCTAssertEqual(usage.credits?.balance, 12.5)
    }

    func testDecodeCreditsString() throws {
        // Balance may arrive as a string; decode leniently.
        let json = #"{"credits":{"balance":"0"}}"#.data(using: .utf8)!
        let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: json)
        XCTAssertEqual(usage.credits?.balance, 0)
    }

    func testDecodeNoCredits() throws {
        // Absent credits block stays nil (backward-compatible with old payloads).
        let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: usageJSON)
        XCTAssertNil(usage.credits)
    }

    // Cost-scanner tests live in CodexCostScannerTests.swift (they import
    // CodexBarCore for CostUsageTokenSnapshot, which would otherwise clash with
    // BirdNion's own Codex types in this file).

    // MARK: - Usage source

    func testUsageSourceDefaultsToAuto() {
        let key = CodexUsageSource.defaultsKey
        let previous = UserDefaults.standard.string(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(CodexUsageSource.current, .auto)
    }

    func testSourceCLIUsesCLIDirectly() throws {
        // .cli skips OAuth entirely — the stub session must never be hit.
        let session = URLSession(configuration: makeStubConfig())
        StubURLProtocol.handler = { req in
            XCTFail("OAuth must not be called in .cli mode")
            return (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { StubURLProtocol.reset() }

        let cli = CodexCLIUsage(
            windows: [QuotaWindow(label: "5 giờ", usedPct: 20, remainingPct: 80)],
            planType: "pro", credits: 3, email: "cli@example.com")
        let p = CodexProvider(session: session, authURL: tempURL(), source: .cli,
                              statusProbe: { nil }, versionProbe: { nil },
                              cliUsageProbe: { cli })
        let exp = expectation(description: "fetch")
        var status: ProviderStatus?
        Task { status = try? await p.fetch(); exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertNil(status?.error)
        XCTAssertEqual(status?.windows.count, 1)
        XCTAssertEqual(status?.sourceLabel, "CLI")
        XCTAssertEqual(status?.accountLabel, "cli@example.com")
        XCTAssertEqual(status?.planType, "Pro 20x")
    }

    func testCLICreditsUnlimitedFlowsThrough() throws {
        let session = URLSession(configuration: makeStubConfig())
        defer { StubURLProtocol.reset() }
        let cli = CodexCLIUsage(
            windows: [QuotaWindow(label: "5 giờ", usedPct: 0, remainingPct: 100)],
            planType: nil, credits: nil, creditsUnlimited: true, email: nil)
        let p = CodexProvider(session: session, authURL: tempURL(), source: .cli,
                              statusProbe: { nil }, versionProbe: { nil },
                              cliUsageProbe: { cli })
        let exp = expectation(description: "fetch")
        var status: ProviderStatus?
        Task { status = try? await p.fetch(); exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(status?.creditsUnlimited, true)
        XCTAssertNil(status?.creditsRemaining)
    }

    func testSourceOAuthDoesNotFallBackToCLI() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let nowISO = ISO8601DateFormatter().string(from: Date())
        let auth = #"{"tokens":{"access_token":"at","refresh_token":"rt"},"last_refresh":"\#(nowISO)"}"#
        try auth.data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let session = URLSession(configuration: makeStubConfig())
        StubURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { StubURLProtocol.reset() }

        // CLI probe returns data, but .oauth must ignore it and fail hard.
        let cli = CodexCLIUsage(windows: [QuotaWindow(label: "5 giờ", usedPct: 1, remainingPct: 99)],
                                planType: nil, credits: nil, email: nil)
        let p = CodexProvider(session: session, authURL: url, source: .oauth,
                              statusProbe: { nil }, versionProbe: { nil },
                              cliUsageProbe: { cli })
        let exp = expectation(description: "fetch")
        var status: ProviderStatus?
        Task { status = try? await p.fetch(); exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(status?.windows.count, 0)
        XCTAssertEqual(status?.error, "HTTP 500")
    }

    // MARK: - CodexCLILaunchGate

    func testLaunchGateThrottlesBackgroundAfterFailure() {
        let gate = CodexCLILaunchGate()
        let bin = "/opt/homebrew/bin/codex"
        let now = Date()
        XCTAssertFalse(gate.shouldSkipLaunch(binary: bin, now: now, manual: false))
        gate.recordFailure(binary: bin, now: now)
        XCTAssertTrue(gate.shouldSkipLaunch(binary: bin, now: now, manual: false))
        // A manual refresh always bypasses the throttle.
        XCTAssertFalse(gate.shouldSkipLaunch(binary: bin, now: now, manual: true))
        // The throttle clears once the cooldown elapses.
        let later = now.addingTimeInterval(CodexCLILaunchGate.cooldown + 1)
        XCTAssertFalse(gate.shouldSkipLaunch(binary: bin, now: later, manual: false))
    }

    func testLaunchGateClearResets() {
        let gate = CodexCLILaunchGate()
        let bin = "/usr/local/bin/codex"
        gate.recordFailure(binary: bin)
        XCTAssertTrue(gate.shouldSkipLaunch(binary: bin, manual: false))
        gate.clearFailure(binary: bin)
        XCTAssertFalse(gate.shouldSkipLaunch(binary: bin, manual: false))
    }

    func testRefreshInteractionDefaultsToBackground() {
        XCTAssertFalse(RefreshInteraction.isManual)
    }

    // MARK: - Account reconciliation + snapshot cache

    func testReconcileDedupesByEmail() {
        let system = CodexAccount(id: "system", email: "a@x.com", isSystem: true, homePath: nil)
        let managed = [
            CodexAccount(id: "1", email: "a@x.com", isSystem: false, homePath: "/h1"),  // dup of system
            CodexAccount(id: "2", email: "b@x.com", isSystem: false, homePath: "/h2"),  // unique
            CodexAccount(id: "3", email: "B@x.com", isSystem: false, homePath: "/h3"),  // dup of #2 (case-insensitive)
            CodexAccount(id: "4", email: nil, isSystem: false, homePath: "/h4"),        // unknown → kept
        ]
        let result = CodexAccountStore.reconcile(system: system, managed: managed)
        XCTAssertEqual(result.map(\.id), ["system", "2", "4"])
    }

    func testReconcilePrefersSwitchedManagedOverSystemMirror() {
        let system = CodexAccount(id: "system", email: "a@x.com", isSystem: true, homePath: nil)
        let managed = [
            CodexAccount(id: "1", email: "a@x.com", isSystem: false, homePath: "/h1"),
            CodexAccount(id: "2", email: "b@x.com", isSystem: false, homePath: "/h2"),
        ]
        // Preferred managed account mirrors the system login → managed row
        // wins, system mirror hidden.
        XCTAssertEqual(
            CodexAccountStore.reconcile(system: system, managed: managed, preferManagedID: "1")
                .map(\.id),
            ["1", "2"])
        // No preference → original behavior (system wins, dup hidden).
        XCTAssertEqual(
            CodexAccountStore.reconcile(system: system, managed: managed).map(\.id),
            ["system", "2"])
        // Preference only applies when the emails actually mirror each other.
        XCTAssertEqual(
            CodexAccountStore.reconcile(system: system, managed: managed, preferManagedID: "2")
                .map(\.id),
            ["system", "2"])
    }

    func testVisibleAccountsHidesEmptySystemWhenManagedAccountsExist() {
        let system = CodexAccount(id: "system", email: nil, isSystem: true, homePath: nil)
        let managed = [CodexAccount(id: "1", email: "a@x.com", isSystem: false, homePath: "/h1")]
        XCTAssertEqual(CodexAccountStore.visibleAccounts(system: system, managed: managed).map(\.id), ["1"])
    }

    func testManagedHomePathMustBeDerivedFromUUIDUnderExactRoot() {
        let root = URL(fileURLWithPath: "/tmp/birdnion/codex-accounts", isDirectory: true)
        let id = "11111111-1111-4111-8111-111111111111"
        let expected = root.appendingPathComponent(id, isDirectory: true).path

        XCTAssertTrue(CodexAccountStore.isManagedHomePath(
            id: id, homePath: expected, accountsRoot: root))
        XCTAssertFalse(CodexAccountStore.isManagedHomePath(
            id: "not-a-uuid", homePath: expected, accountsRoot: root))
        XCTAssertFalse(CodexAccountStore.isManagedHomePath(
            id: id, homePath: "/Users/me/Documents", accountsRoot: root))
        XCTAssertFalse(CodexAccountStore.isManagedHomePath(
            id: id,
            homePath: root.appendingPathComponent("../Documents").path,
            accountsRoot: root))
    }

    func testFallbackActiveIDAfterRemovingUsesNextVisibleAccount() {
        let accounts = [
            CodexAccount(id: "system", email: "a@x.com", isSystem: true, homePath: nil),
            CodexAccount(id: "1", email: "b@x.com", isSystem: false, homePath: "/h1"),
        ]
        XCTAssertEqual(CodexAccountStore.fallbackActiveID(afterRemoving: "system", from: accounts), "1")
        XCTAssertEqual(CodexAccountStore.fallbackActiveID(afterRemoving: "1", from: accounts), "system")
        XCTAssertEqual(CodexAccountStore.fallbackActiveID(afterRemoving: "only", from: []), "system")
    }

    func testSnapshotStoreRoundTrip() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-snap-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = CodexAccountSnapshotStore(fileURL: tmp)
        let status = ProviderStatus(
            id: "codex", displayName: "Codex",
            windows: [QuotaWindow(label: "5 giờ", usedPct: 40, remainingPct: 60)],
            lastUpdated: Date(), accountLabel: "a@x.com", sourceLabel: "OAuth")
        store.save(status, forAccount: "acc-1")
        XCTAssertEqual(store.snapshot(forAccount: "acc-1")?.accountLabel, "a@x.com")
        XCTAssertNil(store.snapshot(forAccount: "other"))
        // Persisted: a fresh instance on the same file reloads it.
        let reopened = CodexAccountSnapshotStore(fileURL: tmp)
        XCTAssertEqual(reopened.snapshot(forAccount: "acc-1")?.windows.first?.usedPct, 40)
    }

    func testSnapshotRemovalPersistsAcrossReload() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-snap-remove-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = CodexAccountSnapshotStore(fileURL: tmp)
        let status = ProviderStatus(
            id: "codex", displayName: "Codex",
            windows: [QuotaWindow(label: "5 giờ", usedPct: 40, remainingPct: 60)],
            lastUpdated: Date(), accountLabel: "alice@example.com")
        store.save(status, forAccount: "account-x")

        store.removeSnapshot(forAccount: "account-x")

        XCTAssertNil(store.snapshot(forAccount: "account-x"))
        XCTAssertNil(CodexAccountSnapshotStore(fileURL: tmp).snapshot(forAccount: "account-x"))
    }

    func testSnapshotStoreDoesNotFollowSymlinkOnLoadOrSave() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-snapshot-link-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.json")
        let original = Data("sentinel".utf8)
        try original.write(to: target)
        let link = directory.appendingPathComponent("snapshots.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let store = CodexAccountSnapshotStore(fileURL: link)
        XCTAssertNil(store.snapshot(forAccount: "account-x"))
        store.save(ProviderStatus(
            id: "codex", displayName: "Codex",
            windows: [QuotaWindow(label: "5 giờ", usedPct: 10, remainingPct: 90)],
            lastUpdated: Date()), forAccount: "account-x")

        XCTAssertEqual(try Data(contentsOf: target), original)
        XCTAssertNil(CodexAccountSnapshotStore(fileURL: link).snapshot(forAccount: "account-x"))
    }

    func testSnapshotStoreRejectsFIFOAndOversizedFileWithoutBlocking() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-snapshot-special-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fifo = directory.appendingPathComponent("snapshots-fifo.json")
        XCTAssertEqual(fifo.path.withCString { Darwin.mkfifo($0, 0o600) }, 0)
        XCTAssertNil(CodexAccountSnapshotStore(fileURL: fifo).snapshot(forAccount: "account-x"))

        let oversized = directory.appendingPathComponent("snapshots-large.json")
        FileManager.default.createFile(atPath: oversized.path, contents: Data())
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(2 * 1024 * 1024 + 1))
        try handle.close()
        XCTAssertNil(CodexAccountSnapshotStore(fileURL: oversized).snapshot(forAccount: "account-x"))
    }

    func testCurrentSnapshotDoesNotNormalizeVanishedManagedAccountToSystem() {
        let previous = UserDefaults.standard.string(forKey: CodexAccountStore.activeKey)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: CodexAccountStore.activeKey)
            } else {
                UserDefaults.standard.removeObject(forKey: CodexAccountStore.activeKey)
            }
        }
        UserDefaults.standard.set("vanished-managed-account", forKey: CodexAccountStore.activeKey)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-snap-fallback-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = CodexAccountSnapshotStore(fileURL: tmp)
        store.save(ProviderStatus(
            id: "codex", displayName: "Codex",
            windows: [QuotaWindow(label: "5 giờ", usedPct: 10, remainingPct: 90)],
            lastUpdated: Date(), accountLabel: "stale@example.com"),
            forAccount: "vanished-managed-account")
        store.save(ProviderStatus(
            id: "codex", displayName: "Codex",
            windows: [QuotaWindow(label: "5 giờ", usedPct: 20, remainingPct: 80)],
            lastUpdated: Date(), accountLabel: "system@example.com"),
            forAccount: "system")

        XCTAssertEqual(store.currentSnapshot()?.accountLabel, "stale@example.com")
    }

    func testSnapshotStoreIgnoresErrorAndEmpty() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-snap-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = CodexAccountSnapshotStore(fileURL: tmp)
        store.save(ProviderStatus(id: "codex", displayName: "Codex", windows: [],
                                  lastUpdated: Date(), error: "boom"), forAccount: "e")
        XCTAssertNil(store.snapshot(forAccount: "e"))   // error status ignored
        store.save(ProviderStatus(id: "codex", displayName: "Codex", windows: [],
                                  lastUpdated: Date()), forAccount: "z")
        XCTAssertNil(store.snapshot(forAccount: "z"))   // empty-windows ignored
    }

    func testAccountActiveSelectionRoundTrip() {
        let previous = CodexAccountStore.activeID()
        defer { CodexAccountStore.setActive(previous) }
        CodexAccountStore.setActive("system")
        XCTAssertEqual(CodexAccountStore.activeID(), "system")
        XCTAssertEqual(CodexAccountStore.activeAuthURL(), CodexAccountStore.systemAuthURL())
    }

    func testSystemAuthURLHonorsCodexHome() {
        let customHome = URL(fileURLWithPath: "/tmp/birdnion-codex-home", isDirectory: true)
        XCTAssertEqual(
            CodexAccountStore.systemAuthURL(env: ["CODEX_HOME": customHome.path]),
            customHome.appendingPathComponent("auth.json"))
    }

    func testSystemAuthPathMustBeDisjointFromManagedAccounts() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-path-roles-\(UUID().uuidString)", isDirectory: true)
        let managedRoot = base.appendingPathComponent("managed", isDirectory: true)
        let managedHome = managedRoot.appendingPathComponent("account-a", isDirectory: true)
        let siblingHome = base.appendingPathComponent("system", isDirectory: true)
        let aliasHome = base.appendingPathComponent("system-alias", isDirectory: true)
        try FileManager.default.createDirectory(
            at: managedHome, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: aliasHome, withDestinationURL: managedHome)
        defer { try? FileManager.default.removeItem(at: base) }

        XCTAssertTrue(CodexAccountStore.systemAuthPathIsDisjoint(
            siblingHome.appendingPathComponent("auth.json"),
            managedAccountsRoot: managedRoot))
        XCTAssertFalse(CodexAccountStore.systemAuthPathIsDisjoint(
            managedHome.appendingPathComponent("auth.json"),
            managedAccountsRoot: managedRoot))
        XCTAssertFalse(CodexAccountStore.systemAuthPathIsDisjoint(
            base.appendingPathComponent("auth.json"),
            managedAccountsRoot: managedRoot))
        XCTAssertFalse(CodexAccountStore.systemAuthPathIsDisjoint(
            aliasHome.appendingPathComponent("auth.json"),
            managedAccountsRoot: managedRoot))
    }

    func testSystemAuthPathMixedCaseNonexistentRootUsesVolumeSemantics() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-path-case-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let managedRoot = base.appendingPathComponent("future-managed", isDirectory: true)
        let mixedCaseHome = base.appendingPathComponent(
            "FuTuRe-MaNaGeD/account-a", isDirectory: true)
        let similarlyPrefixedHome = base.appendingPathComponent(
            "FuTuRe-MaNaGeD-sibling", isDirectory: true)
        let mixedCaseSystemHome = base.appendingPathComponent(
            "FuTuRe-System", isDirectory: true)
        let nestedManagedRoot = base.appendingPathComponent(
            "future-system/managed", isDirectory: true)
        let volumeIsCaseSensitive = try XCTUnwrap(
            base.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
                .volumeSupportsCaseSensitiveNames)

        XCTAssertFalse(FileManager.default.fileExists(atPath: managedRoot.path))
        XCTAssertEqual(
            CodexAccountStore.systemAuthPathIsDisjoint(
                mixedCaseHome.appendingPathComponent("auth.json"),
                managedAccountsRoot: managedRoot),
            volumeIsCaseSensitive)
        XCTAssertEqual(
            CodexAccountStore.systemAuthPathIsDisjoint(
                mixedCaseSystemHome.appendingPathComponent("auth.json"),
                managedAccountsRoot: nestedManagedRoot),
            volumeIsCaseSensitive)
        XCTAssertTrue(CodexAccountStore.systemAuthPathIsDisjoint(
            similarlyPrefixedHome.appendingPathComponent("auth.json"),
            managedAccountsRoot: managedRoot))
    }

    func testSystemAuthURLMasksManagedCodexHomeAlias() {
        let managedHome = CodexAccountStore.homeDir(forAccount: UUID().uuidString)
        let configured = managedHome.appendingPathComponent("auth.json")
        let resolved = CodexAccountStore.systemAuthURL(
            env: ["CODEX_HOME": managedHome.path])
        XCTAssertNotEqual(resolved.standardizedFileURL, configured.standardizedFileURL)
        XCTAssertTrue(CodexAccountStore.systemAuthPathIsDisjoint(
            resolved,
            managedAccountsRoot: managedHome.deletingLastPathComponent()))
    }

    func testActiveManagedSelectionFailsClosedWhenMetadataLoadFails() {
        let accountID = "55555555-5555-4555-8555-555555555555"
        let selection = CodexAccountStore.activeSelection(
            id: accountID,
            loadManagedAccounts: { throw CodexAccountStore.AccountError.persistenceFailed })

        XCTAssertEqual(selection.id, accountID)
        XCTAssertNil(selection.authBinding)
        XCTAssertNotEqual(selection.authURL, CodexAccountStore.systemAuthURL())
    }

    func testFetchDoesNotFallbackForUnavailableManagedSelection() async throws {
        let systemAuth = tempURL()
        try FileManager.default.createDirectory(
            at: systemAuth.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: systemAuth.deletingLastPathComponent()) }
        let systemSentinel = Data(
            #"{"tokens":{"access_token":"system","refresh_token":"system-r"}}"#.utf8)
        try systemSentinel.write(to: systemAuth)
        var cliProbeCount = 0
        var webProbeCount = 0
        let provider = CodexProvider(
            session: URLSession(configuration: makeStubConfig()),
            source: .cli,
            statusProbe: { nil },
            versionProbe: { nil },
            cliUsageProbe: {
                cliProbeCount += 1
                return CodexCLIUsage(windows: [], planType: nil, credits: nil, email: nil)
            },
            accountSelection: {
                CodexAccountStore.ActiveSelection(
                    id: "66666666-6666-4666-8666-666666666666",
                    authURL: systemAuth,
                    authBinding: nil)
            },
            webExtrasProbe: { _ in
                webProbeCount += 1
                return nil
            })

        let status = try await provider.fetch()

        XCTAssertEqual(status.error, "Không đọc được auth.json")
        XCTAssertEqual(cliProbeCount, 0)
        XCTAssertEqual(webProbeCount, 0)
        XCTAssertEqual(try Data(contentsOf: systemAuth), systemSentinel)
    }

    func testAllAccountsIncludesSystem() {
        XCTAssertTrue(CodexAccountStore.allAccounts().contains { $0.id == "system" && $0.isSystem })
    }

    // MARK: - CLI switch: pure decisions
    // Round-trip file mutation (switchCLI/restoreSystemCLI/reconcileCLISyncBack)
    // is intentionally NOT exercised here: those functions operate on the
    // real ~/.codex/auth.json with no injectable URL, and an automated test
    // must never overwrite a developer's live Codex CLI login. Verified
    // manually per task-R2-01/R4-01 evidence instead.

    func testShouldSyncBack() {
        XCTAssertFalse(CodexAccountStore.shouldSyncBack(cliModifiedAt: nil, managedModifiedAt: nil))
        XCTAssertFalse(CodexAccountStore.shouldSyncBack(cliModifiedAt: nil, managedModifiedAt: Date()))
        let now = Date()
        let earlier = now.addingTimeInterval(-60)
        XCTAssertTrue(CodexAccountStore.shouldSyncBack(cliModifiedAt: now, managedModifiedAt: earlier))
        XCTAssertFalse(CodexAccountStore.shouldSyncBack(cliModifiedAt: earlier, managedModifiedAt: now))
        XCTAssertFalse(CodexAccountStore.shouldSyncBack(cliModifiedAt: now, managedModifiedAt: now))
        XCTAssertTrue(CodexAccountStore.shouldSyncBack(cliModifiedAt: now, managedModifiedAt: nil))
    }

    func testNeedsPromoteBeforeOverwrite() {
        XCTAssertTrue(CodexAccountStore.needsPromoteBeforeOverwrite(systemEmail: nil, managedEmails: []))
        XCTAssertTrue(CodexAccountStore.needsPromoteBeforeOverwrite(systemEmail: "a@x.com", managedEmails: ["b@x.com"]))
        XCTAssertFalse(CodexAccountStore.needsPromoteBeforeOverwrite(systemEmail: "a@x.com", managedEmails: ["A@X.com"]))
    }

    func testIsAlreadyCLIIdentity() {
        XCTAssertTrue(CodexAccountStore.isAlreadyCLIIdentity(selectedID: "1", trackedID: "1"))
        XCTAssertFalse(CodexAccountStore.isAlreadyCLIIdentity(selectedID: "1", trackedID: "2"))
        XCTAssertTrue(CodexAccountStore.isAlreadyCLIIdentity(selectedID: "system", trackedID: nil))
        XCTAssertFalse(CodexAccountStore.isAlreadyCLIIdentity(selectedID: "system", trackedID: "1"))
    }

    func testRemovingCLIInstalledAccountInvalidatesSystemSelectionBeforeAndAfterMutation() {
        var notifications = 0
        var mutationRan = false
        let observer = NotificationCenter.default.addObserver(
            forName: .birdnionCodexAccountChanged,
            object: nil,
            queue: nil
        ) { _ in
            notifications += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        CodexAccountStore.performRemovalIdentityBoundary(
            removedID: "managed-a",
            activeID: "system",
            cliSwitchedID: "managed-a",
            purgeSnapshot: { _ in }
        ) {
            mutationRan = true
            XCTAssertEqual(notifications, 1, "old identity must be invalidated before disk mutation")
        }

        XCTAssertTrue(mutationRan)
        XCTAssertEqual(notifications, 2, "current identity must refresh after disk mutation")
    }

    func testRemovingUnrelatedAccountDoesNotInvalidateCurrentIdentity() {
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .birdnionCodexAccountChanged,
            object: nil,
            queue: nil
        ) { _ in
            notifications += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        CodexAccountStore.performRemovalIdentityBoundary(
            removedID: "managed-b",
            activeID: "system",
            cliSwitchedID: "managed-a",
            purgeSnapshot: { _ in },
            mutation: {})

        XCTAssertEqual(notifications, 0)
    }

    func testRemovalBoundaryPurgeFailurePreventsMutationAndNotifications() {
        enum Expected: Error { case failure }
        var notifications = 0
        var mutationRan = false
        let observer = NotificationCenter.default.addObserver(
            forName: .birdnionCodexAccountChanged,
            object: nil,
            queue: nil
        ) { _ in notifications += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        XCTAssertThrowsError(try CodexAccountStore.performRemovalIdentityBoundary(
            removedID: "managed-a",
            activeID: "managed-a",
            cliSwitchedID: nil,
            purgeSnapshot: { _ in throw Expected.failure },
            mutation: { mutationRan = true }))
        XCTAssertFalse(mutationRan)
        XCTAssertEqual(notifications, 0)
    }

    func testManagedRemovalRestoreFailureStopsBeforeDestructiveSteps() {
        enum Expected: Error { case failure }
        var steps: [String] = []

        XCTAssertThrowsError(try CodexAccountStore.performManagedRemovalSteps(
            requiresCLIRestore: true,
            restoreCLI: {
                steps.append("restore")
                throw Expected.failure
            },
            stageCredentialHome: { steps.append("stage") },
            persistRemoval: { steps.append("persist") },
            deleteStagedHome: { steps.append("delete") },
            rollback: { steps.append("rollback") }))

        XCTAssertEqual(steps, ["restore"])
    }

    func testManagedRemovalFailureAfterStagingRunsRollback() {
        enum Expected: Error { case failure }
        var steps: [String] = []

        XCTAssertThrowsError(try CodexAccountStore.performManagedRemovalSteps(
            requiresCLIRestore: false,
            restoreCLI: { steps.append("restore") },
            stageCredentialHome: { steps.append("stage") },
            persistRemoval: {
                steps.append("persist")
                throw Expected.failure
            },
            deleteStagedHome: { steps.append("delete") },
            rollback: { steps.append("rollback") }))

        XCTAssertEqual(steps, ["stage", "persist", "rollback"])
    }

    func testManagedRemovalDeleteFailureDoesNotResurrectCommittedAccount() {
        enum Expected: Error { case failure }
        var steps: [String] = []

        XCTAssertThrowsError(try CodexAccountStore.performManagedRemovalSteps(
            requiresCLIRestore: false,
            restoreCLI: { steps.append("restore") },
            stageCredentialHome: { steps.append("stage") },
            persistRemoval: { steps.append("persist") },
            deleteStagedHome: {
                steps.append("delete-partial")
                throw Expected.failure
            },
            rollback: { steps.append("rollback") }))

        XCTAssertEqual(steps, ["stage", "persist", "delete-partial"])
    }

    func testManagedRemovalFenceRejectsInflightReauthThenAllowsRetry() throws {
        let id = "11111111-1111-4111-8111-111111111111"
        let fence = CodexAccountStore.AccountOperationFence()
        try fence.beginReauthentication(id: id)
        var removalRan = false

        XCTAssertThrowsError(try fence.performRemoval(id: id) { removalRan = true })
        XCTAssertFalse(removalRan)
        fence.finishReauthentication(id: id)
        XCTAssertNoThrow(try fence.performRemoval(id: id) { removalRan = true })
        XCTAssertTrue(removalRan)
    }

    func testFailedManagedRemovalRestoresOriginalAndReopensFence() throws {
        enum Expected: Error { case failure }
        let id = "22222222-2222-4222-8222-222222222222"
        let fence = CodexAccountStore.AccountOperationFence()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-remove-rollback-\(UUID().uuidString)", isDirectory: true)
        let home = directory.appendingPathComponent(id, isDirectory: true)
        let staged = directory.appendingPathComponent("staged", isDirectory: true)
        let original = Data("original".utf8)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try original.write(to: home.appendingPathComponent("credential"))
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertThrowsError(try fence.performRemoval(id: id) {
            try CodexAccountStore.performManagedRemovalSteps(
                requiresCLIRestore: false,
                restoreCLI: {},
                stageCredentialHome: {
                    try FileManager.default.moveItem(at: home, to: staged)
                },
                persistRemoval: { throw Expected.failure },
                deleteStagedHome: {},
                rollback: {
                    try? FileManager.default.moveItem(at: staged, to: home)
                })
        })
        XCTAssertEqual(try Data(contentsOf: home.appendingPathComponent("credential")), original)
        XCTAssertNoThrow(try fence.beginReauthentication(id: id))
        fence.finishReauthentication(id: id)
    }

    func testSystemRemovalFenceRejectsInflightReauthInsteadOfDeletingBlindly() throws {
        let fence = CodexAccountStore.AccountOperationFence()
        try fence.beginReauthentication(id: "system")
        var removalRan = false

        XCTAssertThrowsError(try fence.performRemoval(id: "system") { removalRan = true })
        XCTAssertFalse(removalRan)
        fence.finishReauthentication(id: "system")
    }

    func testRemovalAndSwitchPhasesRejectNewReauthUntilSynchronousWorkFinishes() throws {
        let id = "33333333-3333-4333-8333-333333333333"
        let fence = CodexAccountStore.AccountOperationFence()

        try fence.performRemoval(ids: [id, "system"]) {
            XCTAssertThrowsError(try fence.beginReauthentication(id: id))
            XCTAssertThrowsError(try fence.beginReauthentication(id: "system"))
        }
        try fence.performExclusiveMutation(ids: [id, "system"]) {
            XCTAssertThrowsError(try fence.beginReauthentication(id: id))
            XCTAssertThrowsError(try fence.beginReauthentication(id: "system"))
        }
        XCTAssertNoThrow(try fence.beginReauthentication(id: id))
        fence.finishReauthentication(id: id)
    }

    func testSwitchFenceRejectsInflightReauthThenAllowsRetry() throws {
        let id = "44444444-4444-4444-8444-444444444444"
        let fence = CodexAccountStore.AccountOperationFence()
        try fence.beginReauthentication(id: id)
        var switchRan = false

        XCTAssertThrowsError(try fence.performExclusiveMutation(ids: [id, "system"]) {
            switchRan = true
        })
        XCTAssertFalse(switchRan)
        fence.finishReauthentication(id: id)
        XCTAssertNoThrow(try fence.performExclusiveMutation(ids: [id, "system"]) {
            switchRan = true
        })
        XCTAssertTrue(switchRan)
    }

    func testFenceRejectsDuplicateReauthForSameAccount() throws {
        let fence = CodexAccountStore.AccountOperationFence()
        try fence.beginReauthentication(id: "managed")

        XCTAssertThrowsError(try fence.beginReauthentication(id: "managed"))
        fence.finishReauthentication(id: "managed")
        XCTAssertNoThrow(try fence.beginReauthentication(id: "managed"))
        fence.finishReauthentication(id: "managed")
    }

    func testSystemMutationFenceRejectsSystemReauthThenAllowsRetry() throws {
        let fence = CodexAccountStore.AccountOperationFence()
        try fence.beginReauthentication(id: "system")
        var mutationRan = false

        XCTAssertThrowsError(try fence.performExclusiveMutation(ids: ["system"]) {
            mutationRan = true
        })
        XCTAssertFalse(mutationRan)
        fence.finishReauthentication(id: "system")
        XCTAssertNoThrow(try fence.performExclusiveMutation(ids: ["system"]) {
            mutationRan = true
        })
        XCTAssertTrue(mutationRan)
    }

    func testVerifiedCredentialCopyAcceptsRotationOnlyForSameIdentity() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-identity-copy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("managed.json")
        let destination = directory.appendingPathComponent("system.json")
        try Data(#"{"tokens":{"access_token":"new","refresh_token":"new-r","account_id":"acct-a"}}"#.utf8)
            .write(to: source)
        try Data(#"{"tokens":{"access_token":"old","refresh_token":"old-r","account_id":"acct-a"}}"#.utf8)
            .write(to: destination)

        XCTAssertEqual(
            try CodexAuthStore.copyCredentialIfSameIdentity(from: source, to: destination),
            .copied)
        XCTAssertEqual(try CodexAuthStore.load(url: destination).accessToken, "new")

        try Data(#"{"tokens":{"access_token":"external","refresh_token":"external-r","account_id":"acct-b"}}"#.utf8)
            .write(to: destination)
        XCTAssertEqual(
            try CodexAuthStore.copyCredentialIfSameIdentity(from: source, to: destination),
            .identityMismatch)
        XCTAssertEqual(try CodexAuthStore.load(url: destination).accountId, "acct-b")
    }

    func testMetadataMutationPreservesConcurrentAddsAndRemoveWinsWithoutResurrection() {
        let base = CodexAccount(
            id: "11111111-1111-4111-8111-111111111111",
            email: "base@example.com", isSystem: false, homePath: "/accounts/base")
        let accountA = CodexAccount(
            id: "22222222-2222-4222-8222-222222222222",
            email: "a@example.com", isSystem: false, homePath: "/accounts/a")
        let accountB = CodexAccount(
            id: "33333333-3333-4333-8333-333333333333",
            email: "b@example.com", isSystem: false, homePath: "/accounts/b")
        var state = [base]
        let errorLock = NSLock()
        var errors: [Error] = []

        func runConcurrently(_ mutations: [CodexAccountStore.MetadataMutation]) {
            let start = DispatchSemaphore(value: 0)
            let group = DispatchGroup()
            for mutation in mutations {
                group.enter()
                DispatchQueue.global().async {
                    start.wait()
                    do {
                        try CodexAccountStore.commitMetadataMutation(
                            mutation,
                            load: { state },
                            persist: { state = $0 })
                    } catch {
                        errorLock.lock()
                        errors.append(error)
                        errorLock.unlock()
                    }
                    group.leave()
                }
            }
            for _ in mutations { start.signal() }
            XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
        }

        runConcurrently([.add(accountA), .add(accountB)])
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(Set(state.map(\.id)), Set([base.id, accountA.id, accountB.id]))

        state = [base]
        runConcurrently([.add(accountB), .remove(base.id)])
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(state.map(\.id), [accountB.id])

        XCTAssertFalse(try CodexAccountStore.commitMetadataMutation(
            .replace(base), load: { state }, persist: { state = $0 }))
        XCTAssertEqual(state.map(\.id), [accountB.id])
    }

    func testSwitchCLINoOpWhenAlreadyIdentity() {
        // Selecting the system account while nothing is tracked (the default
        // state) must be a no-op and must not throw, since isAlreadyCLIIdentity
        // short-circuits before any file I/O.
        let previous = CodexAccountStore.cliSwitchedID()
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: CodexAccountStore.cliSwitchedKey) }
            else { UserDefaults.standard.removeObject(forKey: CodexAccountStore.cliSwitchedKey) }
        }
        UserDefaults.standard.removeObject(forKey: CodexAccountStore.cliSwitchedKey)
        XCTAssertNoThrow(try CodexAccountStore.switchCLI(to: "system"))
        XCTAssertNil(CodexAccountStore.cliSwitchedID())
    }

    func testCodexBinaryCandidatesPreferIntelHomebrewOnIntelArchitecture() {
        let paths = CodexAccountStore.orderedCodexBinaryCandidates(
            home: "/Users/tester", architecture: "x86_64")
        XCTAssertLessThan(paths.firstIndex(of: "/usr/local/bin/codex")!,
                          paths.firstIndex(of: "/opt/homebrew/bin/codex")!)
    }

    func testCodexBinaryCandidatesPreferAppleSiliconHomebrewOnArmArchitecture() {
        let paths = CodexAccountStore.orderedCodexBinaryCandidates(
            home: "/Users/tester", architecture: "arm64")
        XCTAssertLessThan(paths.firstIndex(of: "/opt/homebrew/bin/codex")!,
                          paths.firstIndex(of: "/usr/local/bin/codex")!)
    }

    func testLoginSearchPathAddsBinaryDirectoryAndCommonToolDirs() {
        let path = CodexAccountStore.loginSearchPath(
            binaryPath: "/custom/bin/codex",
            inheritedPath: "/usr/bin:/bin",
            home: "/Users/tester")
        let parts = path.split(separator: ":").map(String.init)
        XCTAssertEqual(parts.first, "/custom/bin")
        XCTAssertTrue(parts.contains("/usr/local/bin"))
        XCTAssertTrue(parts.contains("/opt/homebrew/bin"))
        XCTAssertTrue(parts.contains("/Users/tester/.local/bin"))
        XCTAssertEqual(parts.filter { $0 == "/usr/bin" }.count, 1)
    }

    func testFirstAbsolutePathFromShellOutput() {
        XCTAssertEqual(CodexAccountStore.firstAbsolutePath(from: "codex not found\n/usr/local/bin/codex\n"),
                       "/usr/local/bin/codex")
        XCTAssertNil(CodexAccountStore.firstAbsolutePath(from: "codex: aliased to codex\n"))
    }

    // MARK: - CodexQuotaPrimer.shouldPrime (pure decision, R2)

    private func makeDate(hour: Int, minute: Int, day: Int = 9) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 7; c.day = day; c.hour = hour; c.minute = minute
        return Calendar.current.date(from: c)!
    }

    func testShouldPrimeOnTimeAndIdle() {
        let now = makeDate(hour: 9, minute: 0)
        XCTAssertTrue(CodexQuotaPrimer.shouldPrime(
            now: now, lastRun: 0, scheduledMinutes: 535, windowUsedPct: nil, enabled: true))
    }

    func testShouldPrimeFalseWhenWindowActive() {
        let now = makeDate(hour: 9, minute: 0)
        XCTAssertFalse(CodexQuotaPrimer.shouldPrime(
            now: now, lastRun: 0, scheduledMinutes: 535, windowUsedPct: 1, enabled: true))
    }

    func testShouldPrimeFalseWhenAlreadyPrimedToday() {
        let now = makeDate(hour: 9, minute: 0)
        let lastRunToday = makeDate(hour: 8, minute: 55).timeIntervalSince1970
        XCTAssertFalse(CodexQuotaPrimer.shouldPrime(
            now: now, lastRun: lastRunToday, scheduledMinutes: 535, windowUsedPct: nil, enabled: true))
    }

    func testShouldPrimeFalseBeforeScheduledTime() {
        let now = makeDate(hour: 8, minute: 0)
        XCTAssertFalse(CodexQuotaPrimer.shouldPrime(
            now: now, lastRun: 0, scheduledMinutes: 535, windowUsedPct: nil, enabled: true))
    }

    func testShouldPrimeCatchUpPastScheduledNotYetPrimed() {
        // Missed the exact scheduled minute (e.g. machine was asleep) — the
        // first awake tick after the scheduled time still primes once.
        let now = makeDate(hour: 14, minute: 30)
        let lastRunYesterday = makeDate(hour: 9, minute: 0, day: 8).timeIntervalSince1970
        XCTAssertTrue(CodexQuotaPrimer.shouldPrime(
            now: now, lastRun: lastRunYesterday, scheduledMinutes: 535, windowUsedPct: nil, enabled: true))
    }

    func testShouldPrimeFalseWhenDisabled() {
        let now = makeDate(hour: 9, minute: 0)
        XCTAssertFalse(CodexQuotaPrimer.shouldPrime(
            now: now, lastRun: 0, scheduledMinutes: 535, windowUsedPct: nil, enabled: false))
    }

    func testMenuBarMetricFilter() {
        let session = QuotaWindow(label: "5 giờ", usedPct: 1, remainingPct: 99)
        let weekly = QuotaWindow(label: "Tuần", usedPct: 7, remainingPct: 93)
        let all = [session, weekly]
        XCTAssertEqual(CodexMenuBarMetric.automatic.filter(all).count, 2)
        XCTAssertEqual(CodexMenuBarMetric.session.filter(all).map(\.label), ["5 giờ"])
        XCTAssertEqual(CodexMenuBarMetric.weekly.filter(all).map(\.label), ["Tuần"])
        // Fallback: chosen window absent → keep all rather than show nothing.
        XCTAssertEqual(CodexMenuBarMetric.weekly.filter([session]).map(\.label), ["5 giờ"])
    }

    // MARK: - fetch()

    func testFetchHappyPath() async throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let nowISO = ISO8601DateFormatter().string(from: Date())
        let auth = #"{"tokens":{"access_token":"at","refresh_token":"rt"},"last_refresh":"\#(nowISO)"}"#
        try auth.data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let session = URLSession(configuration: makeStubConfig())
        StubURLProtocol.handler = { req in
            // Two endpoints are called concurrently: usage + reset credits.
            // Route by URL; the URL assertion is split so a routing mistake fails fast.
            let url = req.url?.absoluteString ?? ""
            if url.hasSuffix("/wham/usage") {
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, self.usageJSON)
            }
            if url.hasSuffix("/wham/rate-limit-reset-credits") {
                let body = #"{"credits":[],"available_count":0}"#.data(using: .utf8)!
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
            }
            XCTFail("unexpected URL: \(url)")
            return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { StubURLProtocol.reset() }

        let p = CodexProvider(session: session, authURL: url,
                              statusProbe: { nil }, versionProbe: { nil })
        let status = try await p.fetch()
        XCTAssertNil(status.error)
        XCTAssertEqual(status.windows.count, 2)
        XCTAssertEqual(status.windows[0].label, "5 giờ")
        XCTAssertEqual(status.sourceLabel, "OAuth")
    }

    func testFetchKeepsAccountPathSourceAndSnapshotBoundAcrossActiveSwitch() async throws {
        let accountAURL = tempURL()
        let accountBURL = tempURL()
        try FileManager.default.createDirectory(
            at: accountAURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: accountBURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: accountAURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: accountBURL.deletingLastPathComponent())
        }

        let staleA = #"{"tokens":{"access_token":"a-old","refresh_token":"a-refresh","account_id":"acct-a"},"last_refresh":"2020-01-01T00:00:00Z"}"#
        let freshB = #"{"tokens":{"access_token":"b-current","refresh_token":"b-refresh","account_id":"acct-b"},"last_refresh":"2026-08-25T00:00:00Z"}"#
        try staleA.data(using: .utf8)!.write(to: accountAURL)
        try freshB.data(using: .utf8)!.write(to: accountBURL)

        let defaults = UserDefaults.standard
        let previousAccount = CodexAccountStore.activeID()
        let previousSource = defaults.string(forKey: CodexUsageSource.defaultsKey)
        defer {
            CodexAccountStore.setActive(previousAccount)
            if let previousSource {
                defaults.set(previousSource, forKey: CodexUsageSource.defaultsKey)
            } else {
                defaults.removeObject(forKey: CodexUsageSource.defaultsKey)
            }
            StubURLProtocol.reset()
        }
        CodexAccountStore.setActive("account-a")
        defaults.set(CodexUsageSource.auto.rawValue, forKey: CodexUsageSource.defaultsKey)

        let session = URLSession(configuration: makeStubConfig())
        StubURLProtocol.handler = { request in
            let url = request.url?.absoluteString ?? ""
            if url.hasSuffix("/oauth/token") {
                // The selection changes while account A's refresh is suspended.
                CodexAccountStore.setActive("account-b")
                defaults.set(CodexUsageSource.oauth.rawValue, forKey: CodexUsageSource.defaultsKey)
                let body = #"{"access_token":"a-refreshed","refresh_token":"a-refresh-2"}"#
                    .data(using: .utf8)!
                return (
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200,
                        httpVersion: nil, headerFields: nil)!,
                    body)
            }
            if url.hasSuffix("/wham/usage") {
                return (
                    HTTPURLResponse(
                        url: request.url!, statusCode: 500,
                        httpVersion: nil, headerFields: nil)!,
                    Data())
            }
            XCTFail("unexpected URL: \(url)")
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: 404,
                    httpVersion: nil, headerFields: nil)!,
                Data())
        }

        var selectionLookups = 0
        let cli = CodexCLIUsage(
            windows: [QuotaWindow(label: "5 giờ", usedPct: 12, remainingPct: 88)],
            planType: nil, credits: nil, email: "a@example.com")
        var syncedRefreshes: [(String, URL)] = []
        let provider = CodexProvider(
            session: session,
            statusProbe: { nil },
            versionProbe: { nil },
            cliUsageProbe: { cli },
            accountSelection: {
                selectionLookups += 1
                let id = CodexAccountStore.activeID()
                return CodexAccountStore.ActiveSelection(
                    id: id,
                    authURL: id == "account-a" ? accountAURL : accountBURL)
            },
            webExtrasProbe: { _ in nil },
            refreshedCredentialSync: {
                syncedRefreshes.append(($0, $1.displayURL))
            })

        let status = try await provider.fetch()
        XCTAssertEqual(status.sourceLabel, "CLI", "captured Auto source must still allow fallback")
        XCTAssertEqual(selectionLookups, 1)
        XCTAssertEqual(CodexAccountStore.activeID(), "account-b")
        XCTAssertEqual(try CodexAuthStore.load(url: accountAURL).accessToken, "a-refreshed")
        XCTAssertEqual(try CodexAuthStore.load(url: accountBURL).accessToken, "b-current")
        XCTAssertEqual(syncedRefreshes.map(\.0), ["account-a"])
        XCTAssertEqual(syncedRefreshes.map(\.1), [accountAURL])
    }

    func testFetchUnauthorizedNoRefreshToken() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let nowISO = ISO8601DateFormatter().string(from: Date())
        let auth = #"{"tokens":{"access_token":"at","refresh_token":""},"last_refresh":"\#(nowISO)"}"#
        try auth.data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let session = URLSession(configuration: makeStubConfig())
        StubURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { StubURLProtocol.reset() }

        // Inject an empty CLI probe so the test never spawns `codex app-server`.
        let p = CodexProvider(session: session, authURL: url,
                              statusProbe: { nil }, versionProbe: { nil },
                              cliUsageProbe: { nil })
        let exp = expectation(description: "fetch")
        var status: ProviderStatus?
        Task { status = try? await p.fetch(); exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(status?.windows.count, 0)
        XCTAssertEqual(status?.error, "Token Codex hết hạn — chạy `codex` để đăng nhập lại")
    }

    func testFetchRejectsRefreshCommitAfterExternalReauthentication() async throws {
        let url = tempURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stale = Data(#"{"tokens":{"access_token":"old-a","refresh_token":"refresh-a","account_id":"acct-a"},"last_refresh":"2020-01-01T00:00:00Z"}"#.utf8)
        let external = Data(#"{"tokens":{"access_token":"current-b","refresh_token":"refresh-b","account_id":"acct-b"},"last_refresh":"2026-08-25T00:00:00Z"}"#.utf8)
        try stale.write(to: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let session = URLSession(configuration: makeStubConfig())
        StubURLProtocol.handler = { request in
            XCTAssertTrue(request.url?.absoluteString.hasSuffix("/oauth/token") == true)
            try! external.write(to: url, options: .atomic)
            let body = Data(#"{"access_token":"stale-refresh-a","refresh_token":"refresh-a-2"}"#.utf8)
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: 200,
                    httpVersion: nil, headerFields: nil)!,
                body)
        }
        defer { StubURLProtocol.reset() }

        let provider = CodexProvider(
            session: session, authURL: url,
            statusProbe: { nil }, versionProbe: { nil },
            cliUsageProbe: { nil })
        let status = try await provider.fetch()

        XCTAssertEqual(status.error, "Tài khoản Codex vừa thay đổi — thử lại")
        XCTAssertTrue(status.windows.isEmpty)
        XCTAssertEqual(try CodexAuthStore.load(url: url).accessToken, "current-b")
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    func testFetchRejectsManagedParentSwapToSystemHomeWithIdenticalBytes() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-parent-swap-\(UUID().uuidString)", isDirectory: true)
        let accountsRoot = base.appendingPathComponent("accounts", isDirectory: true)
        let accountID = "11111111-1111-4111-8111-111111111111"
        let managedHome = accountsRoot.appendingPathComponent(accountID, isDirectory: true)
        let tombstone = accountsRoot.appendingPathComponent(".removed-account", isDirectory: true)
        let systemHome = base.appendingPathComponent("system", isDirectory: true)
        let managedAuth = managedHome.appendingPathComponent("auth.json")
        let systemAuth = systemHome.appendingPathComponent("auth.json")
        try FileManager.default.createDirectory(
            at: managedHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: systemHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let original = Data(#"{"tokens":{"access_token":"same-old","refresh_token":"same-r","account_id":"acct-a"},"last_refresh":"2020-01-01T00:00:00Z"}"#.utf8)
        try original.write(to: managedAuth)
        try original.write(to: systemAuth)

        let session = URLSession(configuration: makeStubConfig())
        StubURLProtocol.handler = { request in
            let url = request.url?.absoluteString ?? ""
            if url.hasSuffix("/oauth/token") {
                try! FileManager.default.moveItem(at: managedHome, to: tombstone)
                try! FileManager.default.createSymbolicLink(
                    at: managedHome, withDestinationURL: systemHome)
                let body = Data(
                    #"{"access_token":"stale-refresh","refresh_token":"same-r2"}"#.utf8)
                return (
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200,
                        httpVersion: nil, headerFields: nil)!,
                    body)
            }
            XCTAssertTrue(url.hasSuffix("/wham/usage"))
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: 500,
                    httpVersion: nil, headerFields: nil)!,
                Data())
        }
        defer { StubURLProtocol.reset() }

        let provider = CodexProvider(
            session: session,
            source: .oauth,
            statusProbe: { nil },
            versionProbe: { nil },
            cliUsageProbe: { nil },
            accountSelection: {
                CodexAccountStore.ActiveSelection(id: accountID, authURL: managedAuth)
            },
            webExtrasProbe: { _ in nil },
            refreshedCredentialSync: { _, _ in })

        let status = try await provider.fetch()

        XCTAssertEqual(status.error, "Tài khoản Codex vừa thay đổi — thử lại")
        XCTAssertEqual(try Data(contentsOf: systemAuth), original)
        XCTAssertEqual(try Data(contentsOf: tombstone.appendingPathComponent("auth.json")), original)
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    func testDescriptorBoundLoginChildCannotFollowManagedHomeSwapToSystem() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-login-fd-swap-\(UUID().uuidString)", isDirectory: true)
        let accountsRoot = base.appendingPathComponent("accounts", isDirectory: true)
        let accountID = "33333333-3333-4333-8333-333333333333"
        let managedHome = accountsRoot.appendingPathComponent(accountID, isDirectory: true)
        let tombstone = accountsRoot.appendingPathComponent(".login-in-flight", isDirectory: true)
        let systemHome = base.appendingPathComponent("system", isDirectory: true)
        let marker = base.appendingPathComponent("child-ready")
        let release = base.appendingPathComponent("child-release")
        let managedAuth = managedHome.appendingPathComponent("auth.json")
        let systemAuth = systemHome.appendingPathComponent("auth.json")
        try FileManager.default.createDirectory(at: managedHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: systemHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let original = Data("managed-original".utf8)
        let systemSentinel = Data("system-must-not-change".utf8)
        try original.write(to: managedAuth)
        try systemSentinel.write(to: systemAuth)

        let binding = try CodexAuthStore.bindManagedCredential(
            accountsRoot: accountsRoot,
            accountID: accountID,
            authURL: managedAuth)
        let child = Task.detached {
            CodexAccountStore.runDescriptorBoundProcess(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "touch \"$1\"; while [ ! -e \"$2\" ]; do sleep 0.01; done; printf child-write > \"$CODEX_HOME/auth.json\"",
                    "birdnion-test",
                    marker.path,
                    release.path,
                ],
                binding: binding)
        }

        for _ in 0..<200 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        try FileManager.default.moveItem(at: managedHome, to: tombstone)
        try FileManager.default.createSymbolicLink(
            at: managedHome, withDestinationURL: systemHome)
        try Data().write(to: release)

        let childResult = await child.value
        XCTAssertFalse(childResult, "detached managed home must not report login success")
        XCTAssertEqual(try Data(contentsOf: systemAuth), systemSentinel)
        XCTAssertEqual(
            try Data(contentsOf: tombstone.appendingPathComponent("auth.json")),
            Data("child-write".utf8))
    }

    // MARK: - CLI RPC fallback (codex app-server)

    func testFetchFallsBackToCLIOnServerError() async throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let nowISO = ISO8601DateFormatter().string(from: Date())
        let auth = #"{"tokens":{"access_token":"at","refresh_token":"rt"},"last_refresh":"\#(nowISO)"}"#
        try auth.data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let session = URLSession(configuration: makeStubConfig())
        StubURLProtocol.handler = { req in
            // OAuth usage is down (500) → provider must fall back to the CLI probe.
            (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { StubURLProtocol.reset() }

        let cli = CodexCLIUsage(
            windows: [QuotaWindow(label: "5 giờ", usedPct: 30, remainingPct: 70)],
            planType: "pro", credits: 5, email: "rpc@example.com")
        let p = CodexProvider(session: session, authURL: url,
                              statusProbe: { nil }, versionProbe: { nil },
                              cliUsageProbe: { cli })
        let status = try await p.fetch()
        XCTAssertNil(status.error)
        XCTAssertEqual(status.windows.count, 1)
        XCTAssertEqual(status.windows.first?.label, "5 giờ")
        XCTAssertEqual(status.planType, "Pro 20x")   // CodexPlanFormatting applied
        XCTAssertEqual(status.creditsRemaining, 5)
        XCTAssertEqual(status.accountLabel, "rpc@example.com")
    }

    func testServerFallbackDoesNotPublishAfterCredentialReplacement() async throws {
        let url = tempURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let nowISO = ISO8601DateFormatter().string(from: Date())
        let original = Data(#"{"tokens":{"access_token":"at-a","refresh_token":"rt-a","account_id":"acct-a"},"last_refresh":"\#(nowISO)"}"#.utf8)
        let replacement = Data(#"{"tokens":{"access_token":"at-b","refresh_token":"rt-b","account_id":"acct-b"},"last_refresh":"\#(nowISO)"}"#.utf8)
        try original.write(to: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let session = URLSession(configuration: makeStubConfig())
        StubURLProtocol.handler = { request in
            (HTTPURLResponse(
                url: request.url!, statusCode: 500,
                httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { StubURLProtocol.reset() }
        let cli = CodexCLIUsage(
            windows: [QuotaWindow(label: "5 giờ", usedPct: 30, remainingPct: 70)],
            planType: nil, credits: nil, email: "old-a@example.com")
        let provider = CodexProvider(
            session: session, authURL: url,
            statusProbe: { nil }, versionProbe: { nil },
            cliUsageProbe: {
                try! replacement.write(to: url, options: .atomic)
                return cli
            })

        let status = try await provider.fetch()
        XCTAssertEqual(status.error, "Tài khoản Codex vừa thay đổi — thử lại")
        XCTAssertTrue(status.windows.isEmpty)
        XCTAssertNil(status.accountLabel)
    }

    func testCLIOnlyDoesNotPublishAfterCredentialReplacement() async throws {
        let url = tempURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let nowISO = ISO8601DateFormatter().string(from: Date())
        let original = Data(#"{"tokens":{"access_token":"at-a","refresh_token":"rt-a","account_id":"acct-a"},"last_refresh":"\#(nowISO)"}"#.utf8)
        let replacement = Data(#"{"tokens":{"access_token":"at-b","refresh_token":"rt-b","account_id":"acct-b"},"last_refresh":"\#(nowISO)"}"#.utf8)
        try original.write(to: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let cli = CodexCLIUsage(
            windows: [QuotaWindow(label: "Tuần", usedPct: 10, remainingPct: 90)],
            planType: nil, credits: nil, email: "old-a@example.com")
        let provider = CodexProvider(
            authURL: url, source: .cli,
            statusProbe: { nil }, versionProbe: { nil },
            cliUsageProbe: {
                try! replacement.write(to: url, options: .atomic)
                return cli
            })

        let status = try await provider.fetch()
        XCTAssertEqual(status.error, "Tài khoản Codex vừa thay đổi — thử lại")
        XCTAssertTrue(status.windows.isEmpty)
        XCTAssertNil(status.accountLabel)
    }

    func testFetchUnauthorizedFallsBackToCLI() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let nowISO = ISO8601DateFormatter().string(from: Date())
        // Empty refresh token → no reactive refresh; goes straight to CLI fallback.
        let auth = #"{"tokens":{"access_token":"at","refresh_token":""},"last_refresh":"\#(nowISO)"}"#
        try auth.data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let session = URLSession(configuration: makeStubConfig())
        StubURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { StubURLProtocol.reset() }

        let cli = CodexCLIUsage(
            windows: [QuotaWindow(label: "Tuần", usedPct: 10, remainingPct: 90)],
            planType: nil, credits: nil, email: nil)
        let p = CodexProvider(session: session, authURL: url,
                              statusProbe: { nil }, versionProbe: { nil },
                              cliUsageProbe: { cli })
        let exp = expectation(description: "fetch")
        var status: ProviderStatus?
        Task { status = try? await p.fetch(); exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertNil(status?.error)
        XCTAssertEqual(status?.windows.map(\.label), ["Tuần"])
    }

    func testFetchNotLoggedIn() throws {
        let session = URLSession(configuration: makeStubConfig())
        defer { StubURLProtocol.reset() }
        let p = CodexProvider(session: session, authURL: tempURL())
        let exp = expectation(description: "fetch")
        var status: ProviderStatus?
        Task { status = try? await p.fetch(); exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(status?.error, "Chưa đăng nhập Codex — chạy `codex` để đăng nhập")
    }

    // MARK: - CodexStatusProbe parser (CLI fallback)

    func testStatusProbeParseCleanText() throws {
        // CodexBar only supports `HH:mm` and `on <date> <time>` for reset
        // date parsing — not relative phrases like "in 3h 12m" or bare
        // "<date> <time>" without the "on" prefix.
        let text = """
        Credits: 42
        5h limit    78% left   resets 14:30
        Weekly limit 91% left  resets on 2 Jul 14:30
        """
        let snap = try CodexStatusProbe.parse(text: text)
        XCTAssertEqual(snap.credits, 42)
        XCTAssertEqual(snap.fiveHourPercentLeft, 78)
        XCTAssertEqual(snap.weeklyPercentLeft, 91)
        XCTAssertNotNil(snap.fiveHourResetsAt)
        XCTAssertNotNil(snap.weeklyResetsAt)
    }

    func testStatusProbeParseStripsAnsi() throws {
        let text = "\u{001B}[32mCredits: 10\u{001B}[0m\n5h limit 50% left resets 12:34"
        let snap = try CodexStatusProbe.parse(text: text)
        XCTAssertEqual(snap.credits, 10)
        XCTAssertEqual(snap.fiveHourPercentLeft, 50)
    }

    func testStatusProbeParseMissingFieldsThrows() {
        XCTAssertThrowsError(try CodexStatusProbe.parse(text: "hello world"))
    }

    func testStatusProbeParseEmptyThrows() {
        XCTAssertThrowsError(try CodexStatusProbe.parse(text: ""))
    }

    func testStatusProbeParseDataNotAvailableThrows() {
        XCTAssertThrowsError(try CodexStatusProbe.parse(text: "data not available yet\n"))
    }

    // MARK: - CodexResetCreditsAPI decode

    func testResetCreditsDecode() throws {
        let now = Date()
        let f1 = ISO8601DateFormatter(); f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let granted = f1.string(from: now)
        let json = #"""
        {"credits":[{"id":"abc","reset_type":"weekly","status":"available",
        "granted_at":"\#(granted)","expires_at":"\#(granted)","title":"Manual reset"}],
        "available_count":1}
        """#.data(using: .utf8)!
        let snap = try CodexResetCreditsAPI.decode(json, now: now)
        XCTAssertEqual(snap.availableCount, 1)
        XCTAssertEqual(snap.credits.count, 1)
        XCTAssertEqual(snap.credits[0].id, "abc")
        XCTAssertEqual(snap.credits[0].status, "available")
        XCTAssertEqual(snap.credits[0].title, "Manual reset")
    }

    func testResetCreditsDecodeMissingFields() throws {
        // No `available_count` key still decodes; absent credits array works too.
        let json = #"{"credits":[],"available_count":0}"#.data(using: .utf8)!
        let snap = try CodexResetCreditsAPI.decode(json, now: Date())
        XCTAssertEqual(snap.availableCount, 0)
        XCTAssertEqual(snap.credits.count, 0)
    }

    func testResetCreditsDecodeNegativeCountThrows() {
        let json = #"{"credits":[],"available_count":-1}"#.data(using: .utf8)!
        XCTAssertThrowsError(try CodexResetCreditsAPI.decode(json, now: Date()))
    }

    // MARK: - Managed home removal pre-flight

    /// The Codex CLI plants symlinks to its binary under `tmp/arg0/...` inside
    /// every managed home, which made deletion fail for all accounts.
    func testManagedHomeContentsAcceptSymlinksPlantedByCodexCLI() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-home-symlink-\(UUID().uuidString)", isDirectory: true)
        let arg0 = home.appendingPathComponent("tmp/arg0/codex-arg0Test", isDirectory: true)
        try FileManager.default.createDirectory(at: arg0, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(#"{"tokens":{"access_token":"a"}}"#.utf8)
            .write(to: home.appendingPathComponent("auth.json"))
        try Data().write(to: arg0.appendingPathComponent(".lock"))
        for name in ["apply_patch", "applypatch", "codex-execve-wrapper"] {
            try FileManager.default.createSymbolicLink(
                at: arg0.appendingPathComponent(name),
                withDestinationURL: URL(fileURLWithPath: "/opt/homebrew/bin/codex"))
        }
        // A dangling link must not fail either — the target is never resolved.
        try FileManager.default.createSymbolicLink(
            at: arg0.appendingPathComponent("gone"),
            withDestinationURL: home.appendingPathComponent("missing"))

        XCTAssertNoThrow(try CodexAccountStore.validateManagedHomeContents(at: home))
    }

    // MARK: - Subprocess wait

    /// `Process.waitUntilExit()` pumps the run loop, which re-entered SwiftUI's
    /// update cycle from `QuotaOverview.body` (via `codexBinary()`) and crashed
    /// AttributeGraph with SIGSEGV. The replacement must never run the loop.
    func testRunAndWaitDoesNotPumpTheMainRunLoop() {
        var observerFired = false
        let observer = CFRunLoopObserverCreateWithHandler(
            nil,
            CFRunLoopActivity.allActivities.rawValue,
            true, 0) { _, _ in observerFired = true }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .defaultMode)
        defer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .defaultMode) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["0.3"]
        XCTAssertTrue(CodexAccountStore.runAndWait(process))
        XCTAssertFalse(
            observerFired,
            "waiting must not run the main run loop — that re-enters SwiftUI mid-body")
    }

    func testRunAndWaitTimesOutInsteadOfBlockingForever() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        let started = Date()
        XCTAssertFalse(CodexAccountStore.runAndWait(process, timeout: 0.4))
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        // terminate() is asynchronous, so poll rather than sampling once: the
        // point is that the timed-out child is killed, not left running for 30s.
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline { usleep(50_000) }
        XCTAssertFalse(process.isRunning, "timed-out process must be terminated")
    }

    func testManagedHomeContentsRejectSpecialFiles() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-home-fifo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let fifo = home.appendingPathComponent("pipe")
        XCTAssertEqual(fifo.path.withCString { mkfifo($0, 0o600) }, 0)

        XCTAssertThrowsError(try CodexAccountStore.validateManagedHomeContents(at: home))
    }
}
