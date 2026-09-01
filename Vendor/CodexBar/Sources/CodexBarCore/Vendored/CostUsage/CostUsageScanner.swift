#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// swiftlint:disable type_body_length file_length
enum CostUsageScanner {
    typealias CancellationCheck = () throws -> Void

    static let log = CodexBarLog.logger(LogCategories.tokenCost)
    static let codexActiveSessionLookbackDays = 30
    static let codexCatchUpScanCandidateLimit = 512
    static let costScale = 1_000_000_000.0

    enum ClaudeLogProviderFilter {
        case all
        case vertexAIOnly
        case excludeVertexAI
    }

    struct Options {
        var codexSessionsRoot: URL?
        var claudeProjectsRoots: [URL]?
        var cacheRoot: URL?
        var codexTraceDatabaseURL: URL?
        var refreshMinIntervalSeconds: TimeInterval = 60
        var claudeLogProviderFilter: ClaudeLogProviderFilter = .all
        /// Force a full rescan, ignoring per-file cache and incremental offsets.
        var forceRescan: Bool = false
        /// Ngân sách thời gian (giây) cho MỘT lần scan. Khi vượt, vòng lặp file
        /// dừng sớm nhưng vẫn lưu cache tiến độ đã quét; lần scan sau resume
        /// (skip file đã quét bằng mtime, parse tiếp phần còn lại). Chống treo
        /// khi lịch sử JSONL cực lớn (hàng GB) hoặc scan lạnh/migration. `nil` =
        /// không giới hạn (hành vi cũ).
        var maxScanWallClock: TimeInterval?

        init(
            codexSessionsRoot: URL? = nil,
            claudeProjectsRoots: [URL]? = nil,
            cacheRoot: URL? = nil,
            codexTraceDatabaseURL: URL? = nil,
            claudeLogProviderFilter: ClaudeLogProviderFilter = .all,
            forceRescan: Bool = false,
            maxScanWallClock: TimeInterval? = nil)
        {
            self.codexSessionsRoot = codexSessionsRoot
            self.claudeProjectsRoots = claudeProjectsRoots
            self.cacheRoot = cacheRoot
            self.codexTraceDatabaseURL = codexTraceDatabaseURL
            self.claudeLogProviderFilter = claudeLogProviderFilter
            self.forceRescan = forceRescan
            self.maxScanWallClock = maxScanWallClock
        }
    }

    struct CodexParseResult {
        let days: [String: [String: [Int]]]
        var parsedBytes: Int64
        let lastModel: String?
        let lastTotals: CostUsageCodexTotals?
        let lastCountedTotals: CostUsageCodexTotals?
        let lastRawTotalsBaseline: CostUsageCodexTotals?
        let hasDivergentTotals: Bool
        let lastCodexTurnID: String?
        let sessionId: String?
        let forkedFromId: String?
        let projectKey: String?
        let projectName: String?
        let projectAttributionAmbiguous: Bool
        let rows: [CodexUsageRow]
        let scanComplete: Bool
        let resumeState: CodexParseResumeState
    }

    struct CodexUsageRow: Codable, Equatable {
        let day: String
        let model: String
        let turnID: String?
        let input: Int
        let cached: Int
        let output: Int
    }

    struct CodexScanState {
        var seenSessionIds: Set<String> = []
        var sessionFilePaths: [String: String] = [:]
        var ambiguousProjectSessionIds: Set<String> = []
        var seenFileIds: Set<String> = []
    }

    enum CodexForkBaseline {
        case resolved(CostUsageCodexTotals?)
        case unresolved
        case stopped
    }

    static func codexParentQueryKey(sessionId: String, cutoffTimestamp: String) -> String {
        Self.sha256Hex(Data(("parent-query-v1\0" + sessionId + "\0" + cutoffTimestamp).utf8))
    }

    private static func codexTotalsEqual(_ lhs: CostUsageCodexTotals?, _ rhs: CostUsageCodexTotals?) -> Bool {
        lhs?.input == rhs?.input && lhs?.cached == rhs?.cached && lhs?.output == rhs?.output
    }

    private static func codexTotalsAtLeast(_ lhs: CostUsageCodexTotals, _ rhs: CostUsageCodexTotals) -> Bool {
        lhs.input >= rhs.input && lhs.cached >= rhs.cached && lhs.output >= rhs.output
    }

    private static func codexTotalsAtMost(_ lhs: CostUsageCodexTotals, _ rhs: CostUsageCodexTotals) -> Bool {
        lhs.input <= rhs.input && lhs.cached <= rhs.cached && lhs.output <= rhs.output
    }

    private static func codexShouldPreferTotalDelta(
        rawBaseline: CostUsageCodexTotals?,
        currentTotal: CostUsageCodexTotals,
        totalDelta: CostUsageCodexTotals,
        lastDelta: CostUsageCodexTotals,
        sawDivergentTotals: Bool) -> Bool
    {
        guard !sawDivergentTotals, let rawBaseline else { return false }
        return Self.codexTotalsAtLeast(currentTotal, rawBaseline)
            && Self.codexTotalsAtMost(totalDelta, lastDelta)
    }

    private static func codexAddTotals(
        _ lhs: CostUsageCodexTotals,
        _ rhs: CostUsageCodexTotals) -> CostUsageCodexTotals
    {
        CostUsageCodexTotals(
            input: lhs.input + rhs.input,
            cached: lhs.cached + rhs.cached,
            output: lhs.output + rhs.output)
    }

    private static func codexMinTotals(
        _ lhs: CostUsageCodexTotals,
        _ rhs: CostUsageCodexTotals) -> CostUsageCodexTotals
    {
        CostUsageCodexTotals(
            input: min(lhs.input, rhs.input),
            cached: min(lhs.cached, rhs.cached),
            output: min(lhs.output, rhs.output))
    }

    private static func codexTotalDelta(
        from baseline: CostUsageCodexTotals?,
        to current: CostUsageCodexTotals) -> CostUsageCodexTotals
    {
        let baseline = baseline ?? .init(input: 0, cached: 0, output: 0)
        return CostUsageCodexTotals(
            input: max(0, current.input - baseline.input),
            cached: max(0, current.cached - baseline.cached),
            output: max(0, current.output - baseline.output))
    }

    private static func codexDivergentTotalDelta(
        rawBaseline: CostUsageCodexTotals?,
        countedBaseline: CostUsageCodexTotals?,
        current: CostUsageCodexTotals) -> CostUsageCodexTotals
    {
        let rawBaseline = rawBaseline ?? .init(input: 0, cached: 0, output: 0)
        let countedBaseline = countedBaseline ?? .init(input: 0, cached: 0, output: 0)

        func delta(raw: Int, counted: Int, current: Int) -> Int {
            if current >= raw {
                return max(0, current - raw)
            }
            return max(0, current - counted)
        }

        return CostUsageCodexTotals(
            input: delta(raw: rawBaseline.input, counted: countedBaseline.input, current: current.input),
            cached: delta(raw: rawBaseline.cached, counted: countedBaseline.cached, current: current.cached),
            output: delta(raw: rawBaseline.output, counted: countedBaseline.output, current: current.output))
    }

    struct CodexScanResources {
        let fileIndex: CodexSessionFileIndex
        let inheritedResolver: CodexInheritedTotalsResolver
        let modelsDevCatalog: ModelsDevCatalog?
        let modelsDevCacheRoot: URL?
        let priorityTurns: [String: CodexPriorityTurnMetadata]
    }

    struct CodexFileScanContext {
        let range: CostUsageDayRange
        let forceFullScan: Bool
        let dropDeferredCodexRows: Bool
        let requiresTurnIDCache: Bool
        let changedPriorityTurnIDs: Set<String>
        let resources: CodexScanResources
        let checkCancellation: CancellationCheck?
        let shouldStop: (() -> Bool)?
        let scanGeneration: String
        let roots: [URL]

        init(
            range: CostUsageDayRange,
            forceFullScan: Bool,
            dropDeferredCodexRows: Bool,
            requiresTurnIDCache: Bool,
            changedPriorityTurnIDs: Set<String>,
            resources: CodexScanResources,
            checkCancellation: CancellationCheck?,
            shouldStop: (() -> Bool)?,
            scanGeneration: String,
            roots: [URL] = [])
        {
            self.range = range
            self.forceFullScan = forceFullScan
            self.dropDeferredCodexRows = dropDeferredCodexRows
            self.requiresTurnIDCache = requiresTurnIDCache
            self.changedPriorityTurnIDs = changedPriorityTurnIDs
            self.resources = resources
            self.checkCancellation = checkCancellation
            self.shouldStop = shouldStop
            self.scanGeneration = scanGeneration
            self.roots = roots
        }
    }

    struct CodexRefreshPlan {
        let refreshMs: Int64
        let roots: [URL]
        let rootsFingerprint: [String: Int64]
        let rootsChanged: Bool
        let windowExpanded: Bool
        let needsCostCacheMigration: Bool
        let modelsDevCatalog: ModelsDevCatalog?
        let codexPricingKey: String
        let codexPriorityMetadataKey: String
        let hasPriorityMetadata: Bool
        let priorityTurns: [String: CodexPriorityTurnMetadata]
        let priorityTurnKeys: [String: String]
        let priorityTurnIDsByDay: [String: [String]]
        let pricingChanged: Bool
        let priorityMetadataChanged: Bool
        let priorityTurnsChanged: Bool
        let needsTurnIDCacheMigration: Bool
        let changedPriorityTurnIDs: Set<String>
        let shouldRefresh: Bool
    }

    final class CodexSessionFileIndex {
        private static let maximumDiscoveryDepth = 32

        private let files: [URL]
        private let roots: [URL]
        private let targetEOFByPath: [String: Int64]
        private let checkCancellation: CancellationCheck?
        private let shouldStop: (() -> Bool)?
        private let generation: String
        private var nextUnindexedFile = 0
        private var fileURLBySessionId: [String: URL] = [:]
        private var missingSessionIds: Set<String> = []
        private var pendingIdentitySessionIds: Set<String> = []
        private(set) var directoryEnumerationCount = 0
        private(set) var pendingParentDiscoveries: [String: CodexParentDiscoveryJournal]

        init(
            files: [URL],
            roots: [URL],
            targetEOFByPath: [String: Int64] = [:],
            cachedSessionFiles: [String: URL] = [:],
            checkCancellation: CancellationCheck? = nil,
            shouldStop: (() -> Bool)? = nil,
            generation: String = "",
            pendingParentDiscoveries: [String: CodexParentDiscoveryJournal] = [:])
        {
            self.files = files
            self.roots = roots.sorted { $0.path < $1.path }
            self.targetEOFByPath = targetEOFByPath
            self.fileURLBySessionId = cachedSessionFiles
            self.checkCancellation = checkCancellation
            self.shouldStop = shouldStop
            self.generation = generation
            self.pendingParentDiscoveries = pendingParentDiscoveries.filter {
                $0.value.generation == generation
            }
        }

        func remember(fileURL: URL, sessionId: String?) {
            guard let sessionId, !sessionId.isEmpty else { return }
            self.fileURLBySessionId[sessionId] = fileURL
        }

        func containingRoot(for fileURL: URL) -> URL? {
            CostUsageScanner.codexContainingRoot(fileURL: fileURL, roots: self.roots)
        }

        func fileURL(for sessionId: String) throws -> URL? {
            if let cached = self.fileURLBySessionId[sessionId] {
                return cached
            }
            if let resolved = try self.resolvedDiscoveryFileURL(sessionId: sessionId) {
                self.fileURLBySessionId[sessionId] = resolved
                return resolved
            }
            if self.missingSessionIds.contains(sessionId) {
                return nil
            }

            // Resolve the already-bounded current file set first. Parents
            // outside it fall through to the durable root discovery cursor.
            while self.nextUnindexedFile < self.files.count {
                try self.checkCancellation?()
                if self.shouldStop?() == true { return nil }
                let fileURL = self.files[self.nextUnindexedFile]
                let root = CostUsageScanner.codexContainingRoot(
                    fileURL: fileURL,
                    roots: self.roots)
                switch try CostUsageScanner.parseCodexSessionIdentifier(
                    fileURL: fileURL,
                    checkCancellation: self.checkCancellation,
                    maximumBytes: Int(min(
                        Int64(512 * 1024),
                        max(0, self.targetEOFByPath[fileURL.path] ?? Int64(512 * 1024)))),
                    withinRoot: root)
                {
                case let .found(indexedSessionId):
                    self.nextUnindexedFile += 1
                    self.fileURLBySessionId[indexedSessionId] = fileURL
                    if indexedSessionId == sessionId { return fileURL }
                case .definitivelyAbsent:
                    self.nextUnindexedFile += 1
                case .retryableIOFailure:
                    self.pendingIdentitySessionIds.insert(sessionId)
                    return nil
                }
            }

            return try self.discoverInRoots(sessionId: sessionId)
        }

        func discoveryIsPending(sessionId: String) -> Bool {
            self.pendingParentDiscoveries[sessionId] != nil
                || self.pendingIdentitySessionIds.contains(sessionId)
        }

        private func resolvedDiscoveryFileURL(sessionId: String) throws -> URL? {
            guard let journal = self.pendingParentDiscoveries[sessionId] else { return nil }
            if journal.resolvedRootIndex == nil, journal.resolvedRelativePath == nil { return nil }
            guard let rootIndex = journal.resolvedRootIndex,
                  let relativePath = journal.resolvedRelativePath,
                  self.roots.indices.contains(rootIndex),
                  let candidate = Self.discoveryFileURL(
                      root: self.roots[rootIndex], relativePath: relativePath)
            else {
                self.pendingParentDiscoveries.removeValue(forKey: sessionId)
                return nil
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: candidate.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  (try? FileManager.default.destinationOfSymbolicLink(atPath: candidate.path)) == nil,
                  candidate.pathExtension.lowercased() == "jsonl",
                  CostUsageScanner.codexFileMetadata(
                      fileURL: candidate,
                      withinRoot: self.roots[rootIndex]).fileId != nil
            else {
                self.pendingParentDiscoveries.removeValue(forKey: sessionId)
                return nil
            }
            switch try CostUsageScanner.parseCodexSessionIdentifier(
                fileURL: candidate,
                checkCancellation: self.checkCancellation,
                withinRoot: self.roots[rootIndex])
            {
            case let .found(indexedSessionId) where indexedSessionId == sessionId:
                return candidate
            case .retryableIOFailure:
                return nil
            case .found, .definitivelyAbsent:
                self.pendingParentDiscoveries.removeValue(forKey: sessionId)
                return nil
            }
        }

        private func discoverInRoots(sessionId: String) throws -> URL? {
            guard !self.roots.isEmpty else {
                self.missingSessionIds.insert(sessionId)
                return nil
            }
            var journal = self.pendingParentDiscoveries[sessionId]
                ?? CodexParentDiscoveryJournal(
                    generation: self.generation,
                    rootIndex: 0,
                    directoryStack: [],
                    resolvedRootIndex: nil,
                    resolvedRelativePath: nil)
            if journal.rootIndex < 0 {
                journal = CodexParentDiscoveryJournal(
                    generation: self.generation,
                    rootIndex: 0,
                    directoryStack: [],
                    resolvedRootIndex: nil,
                    resolvedRelativePath: nil)
            }

            while journal.rootIndex < self.roots.count {
                try self.checkCancellation?()
                if self.shouldStop?() == true {
                    self.pendingParentDiscoveries[sessionId] = journal
                    return nil
                }
                let root = self.roots[journal.rootIndex].standardizedFileURL
                if journal.directoryStack.isEmpty {
                    journal.directoryStack = [CodexParentDiscoveryDirectoryCursor(
                        relativePath: "", lastEntryName: nil)]
                }

                while !journal.directoryStack.isEmpty {
                    try self.checkCancellation?()
                    if self.shouldStop?() == true {
                        self.pendingParentDiscoveries[sessionId] = journal
                        return nil
                    }
                    let cursorIndex = journal.directoryStack.count - 1
                    var cursor = journal.directoryStack[cursorIndex]
                    guard let directoryURL = Self.discoveryDirectoryURL(
                        root: root, relativePath: cursor.relativePath)
                    else {
                        journal.directoryStack.removeLast()
                        continue
                    }
                    if cursor.frozenEntryNames == nil {
                        do {
                            self.directoryEnumerationCount += 1
                            let names = try FileManager.default.contentsOfDirectory(
                                at: directoryURL,
                                includingPropertiesForKeys: nil,
                                options: [.skipsHiddenFiles])
                                .map(\.lastPathComponent)
                                .filter { name in
                                    !name.isEmpty && name != "." && name != ".."
                                        && !name.contains("/")
                                        && (cursor.lastEntryName == nil || name > cursor.lastEntryName!)
                                }
                                .sorted()
                            cursor.frozenEntryNames = names
                            cursor.nextEntryIndex = 0
                            journal.directoryStack[cursorIndex] = cursor
                        } catch {
                            journal.directoryStack.removeLast()
                            continue
                        }
                    }
                    let entryNames = cursor.frozenEntryNames ?? []
                    var descended = false
                    var processedEntry = false
                    var entryIndex = max(0, cursor.nextEntryIndex ?? 0)
                    while entryIndex < entryNames.count {
                        try self.checkCancellation?()
                        // Enumeration itself can cross the deadline. Always
                        // classify/checkpoint its first remaining candidate so
                        // the next pass cannot repeat the same expensive list.
                        if processedEntry, self.shouldStop?() == true {
                            self.pendingParentDiscoveries[sessionId] = journal
                            return nil
                        }
                        processedEntry = true
                        let entryName = entryNames[entryIndex]
                        let entry = directoryURL.appendingPathComponent(entryName)
                        if (try? FileManager.default.destinationOfSymbolicLink(
                            atPath: entry.path)) != nil
                        {
                            entryIndex += 1
                            journal.directoryStack[cursorIndex].nextEntryIndex = entryIndex
                            journal.directoryStack[cursorIndex].lastEntryName = entryName
                            continue
                        }
                        var isDirectory: ObjCBool = false
                        guard FileManager.default.fileExists(
                            atPath: entry.path, isDirectory: &isDirectory)
                        else {
                            entryIndex += 1
                            journal.directoryStack[cursorIndex].nextEntryIndex = entryIndex
                            journal.directoryStack[cursorIndex].lastEntryName = entryName
                            continue
                        }
                        if isDirectory.boolValue {
                            entryIndex += 1
                            journal.directoryStack[cursorIndex].nextEntryIndex = entryIndex
                            journal.directoryStack[cursorIndex].lastEntryName = entryName
                            guard journal.directoryStack.count < Self.maximumDiscoveryDepth else {
                                continue
                            }
                            let childRelative = cursor.relativePath.isEmpty
                                ? entryName
                                : cursor.relativePath + "/" + entryName
                            journal.directoryStack.append(CodexParentDiscoveryDirectoryCursor(
                                relativePath: childRelative, lastEntryName: nil))
                            descended = true
                            break
                        }
                        guard entry.pathExtension.lowercased() == "jsonl"
                        else {
                            entryIndex += 1
                            journal.directoryStack[cursorIndex].nextEntryIndex = entryIndex
                            journal.directoryStack[cursorIndex].lastEntryName = entryName
                            continue
                        }
                        guard CostUsageScanner.codexFileMetadata(
                            fileURL: entry,
                            withinRoot: root).fileId != nil
                        else {
                            entryIndex += 1
                            journal.directoryStack[cursorIndex].nextEntryIndex = entryIndex
                            journal.directoryStack[cursorIndex].lastEntryName = entryName
                            continue
                        }
                        let identity = try CostUsageScanner.parseCodexSessionIdentifier(
                            fileURL: entry,
                            checkCancellation: self.checkCancellation,
                            withinRoot: root)
                        if case .retryableIOFailure = identity {
                            self.pendingParentDiscoveries[sessionId] = journal
                            return nil
                        }
                        entryIndex += 1
                        journal.directoryStack[cursorIndex].nextEntryIndex = entryIndex
                        journal.directoryStack[cursorIndex].lastEntryName = entryName
                        let indexedSessionId: String? = if case let .found(identifier) = identity {
                            identifier
                        } else {
                            nil
                        }
                        if let indexedSessionId, indexedSessionId == sessionId {
                            let relativePath = cursor.relativePath.isEmpty
                                ? entryName
                                : cursor.relativePath + "/" + entryName
                            guard Self.discoveryFileURL(
                                root: root, relativePath: relativePath) != nil
                            else {
                                journal.directoryStack.removeLast()
                                descended = true
                                break
                            }
                            self.fileURLBySessionId[indexedSessionId] = entry
                            journal.directoryStack = []
                            journal.resolvedRootIndex = journal.rootIndex
                            journal.resolvedRelativePath = relativePath
                            self.pendingParentDiscoveries[sessionId] = journal
                            return entry
                        }
                        // A definitive bounded result is a durable checkpoint,
                        // even when the deadline fires immediately afterward.
                        if let indexedSessionId {
                            self.fileURLBySessionId[indexedSessionId] = entry
                        }
                        if self.shouldStop?() == true {
                            self.pendingParentDiscoveries[sessionId] = journal
                            return nil
                        }
                    }
                    if descended { continue }
                    journal.directoryStack.removeLast()
                }
                journal.rootIndex += 1
            }
            self.pendingParentDiscoveries.removeValue(forKey: sessionId)
            self.missingSessionIds.insert(sessionId)
            return nil
        }

        private static func discoveryDirectoryURL(root: URL, relativePath: String) -> URL? {
            guard !relativePath.hasPrefix("/"),
                  relativePath.isEmpty || relativePath.split(
                      separator: "/", omittingEmptySubsequences: false).allSatisfy({
                          !$0.isEmpty && $0 != "." && $0 != ".."
                      })
            else { return nil }
            let canonicalRoot = root.standardizedFileURL
            let candidate = relativePath.isEmpty
                ? canonicalRoot
                : canonicalRoot.appendingPathComponent(relativePath, isDirectory: true)
            let rootPath = canonicalRoot.path
            let candidatePath = candidate.standardizedFileURL.path
            guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else { return nil }
            guard Self.relativePathContainsNoSymlink(
                root: canonicalRoot, relativePath: relativePath)
            else { return nil }
            return URL(fileURLWithPath: candidatePath, isDirectory: true)
        }

        private static func discoveryFileURL(root: URL, relativePath: String) -> URL? {
            guard !relativePath.isEmpty,
                  !relativePath.hasPrefix("/"),
                  relativePath.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                      !$0.isEmpty && $0 != "." && $0 != ".."
                  })
            else { return nil }
            let canonicalRoot = root.standardizedFileURL
            let candidate = canonicalRoot.appendingPathComponent(relativePath)
                .standardizedFileURL
            guard candidate.path.hasPrefix(canonicalRoot.path + "/") else { return nil }
            guard Self.relativePathContainsNoSymlink(
                root: canonicalRoot, relativePath: relativePath)
            else { return nil }
            return candidate
        }

        private static func relativePathContainsNoSymlink(
            root: URL,
            relativePath: String
        ) -> Bool {
            var candidate = root
            for component in relativePath.split(separator: "/") {
                candidate.appendPathComponent(String(component))
                if (try? FileManager.default.destinationOfSymbolicLink(
                    atPath: candidate.path)) != nil
                {
                    return false
                }
            }
            return true
        }
    }

    final class CodexInheritedTotalsResolver {
        private let fileIndex: CodexSessionFileIndex
        private let checkCancellation: CancellationCheck?
        private let shouldStop: (() -> Bool)?
        private let generation: String
        private var resolvedTotalsByQuery: [String: CostUsageCodexTotals] = [:]
        private var resolvedEmptyQueries: Set<String> = []
        private(set) var pendingParentScans: [String: CodexParentSnapshotJournal]
        private(set) var resumeOffsetsBySessionId: [String: Int64] = [:]

        init(
            fileIndex: CodexSessionFileIndex,
            checkCancellation: CancellationCheck?,
            shouldStop: (() -> Bool)?,
            generation: String,
            pendingParentScans: [String: CodexParentSnapshotJournal] = [:])
        {
            self.fileIndex = fileIndex
            self.checkCancellation = checkCancellation
            self.shouldStop = shouldStop
            self.generation = generation
            self.pendingParentScans = pendingParentScans.filter { key, journal in
                guard journal.generation == generation,
                      journal.snapshots == nil,
                      let cutoff = journal.cutoffTimestamp,
                      !cutoff.isEmpty
                else { return false }
                return key == CostUsageScanner.codexParentQueryKey(
                    sessionId: journal.sessionId, cutoffTimestamp: cutoff)
            }
        }

        func inheritedTotals(for sessionId: String, atOrBefore cutoffTimestamp: String) throws -> CodexForkBaseline {
            if self.shouldStop?() == true { return .stopped }
            guard !cutoffTimestamp.isEmpty else {
                CostUsageScanner.log.warning(
                    "Codex cost usage fork timestamp missing; treating parent baseline as unresolved",
                    metadata: ["sessionId": sessionId])
                return .unresolved
            }
            let queryKey = CostUsageScanner.codexParentQueryKey(
                sessionId: sessionId, cutoffTimestamp: cutoffTimestamp)
            if let cached = self.resolvedTotalsByQuery[queryKey] { return .resolved(cached) }
            if self.resolvedEmptyQueries.contains(queryKey) { return .resolved(nil) }
            return try self.resolveBaseline(
                queryKey: queryKey,
                sessionId: sessionId,
                cutoffTimestamp: cutoffTimestamp)
        }

        private func resolveBaseline(
            queryKey: String,
            sessionId: String,
            cutoffTimestamp: String) throws -> CodexForkBaseline
        {
            try self.checkCancellation?()
            if self.shouldStop?() == true { return .stopped }
            guard let fileURL = try self.fileIndex.fileURL(for: sessionId) else {
                if self.shouldStop?() == true
                    || self.fileIndex.discoveryIsPending(sessionId: sessionId)
                {
                    return .stopped
                }
                CostUsageScanner.log.warning(
                    "Codex cost usage parent session file not found",
                    metadata: ["sessionId": sessionId])
                return .unresolved
            }
            if self.shouldStop?() == true { return .stopped }
            let root = self.fileIndex.containingRoot(for: fileURL)
            let metadata = CostUsageScanner.codexFileMetadata(
                fileURL: fileURL,
                withinRoot: root)
            let resumable = self.pendingParentScans[queryKey].flatMap { journal in
                self.compatibleJournal(
                    journal,
                    sessionId: sessionId,
                    cutoffTimestamp: cutoffTimestamp,
                    metadata: metadata,
                    fileURL: fileURL,
                    withinRoot: root)
                    ? journal
                    : nil
            }
            let target: CodexFrozenFile
            if let resumable {
                target = CodexFrozenFile(
                    fileId: resumable.fileId,
                    mtimeUnixMs: resumable.mtimeUnixMs,
                    observedSize: resumable.observedSize ?? resumable.size,
                    targetEOF: resumable.size,
                    contentFingerprint: resumable.contentFingerprint)
            } else if let captured = CostUsageScanner.codexFrozenFile(
                fileURL: fileURL,
                withinRoot: root)
            {
                target = captured
            } else {
                return .stopped
            }
            guard CostUsageScanner.codexFrozenFileIsReadable(
                target,
                current: metadata,
                fileURL: fileURL,
                withinRoot: root)
            else {
                self.pendingParentScans.removeValue(forKey: queryKey)
                return .stopped
            }
            if let resumable, resumable.scanComplete {
                return self.rememberResolved(
                    queryKey: queryKey, totals: resumable.cutoffTotals)
            }
            let startOffset = resumable?.parsedBytes ?? 0
            self.resumeOffsetsBySessionId[sessionId] = startOffset
            let parsed = try CostUsageScanner.parseCodexTokenSnapshots(
                fileURL: fileURL,
                cutoffTimestamp: cutoffTimestamp,
                startOffset: startOffset,
                initialSessionId: resumable?.sessionId,
                initialPreviousTotals: resumable?.previousTotals,
                initialRawTotalsBaseline: resumable?.rawTotalsBaseline,
                initialHasDivergentTotals: resumable?.hasDivergentTotals ?? false,
                initialCutoffTotals: resumable?.cutoffTotals,
                initialDiscardingTruncatedLine: resumable?.discardingTruncatedLine == true,
                checkCancellation: self.checkCancellation,
                shouldStop: self.shouldStop,
                endOffset: target.targetEOF,
                withinRoot: root)
            guard let parsedSessionId = parsed.sessionId, parsedSessionId == sessionId else {
                // A bounded stop or non-cancellation read failure can occur
                // before session_meta is journaled. It is retryable work, not
                // evidence that the parent is genuinely missing.
                if !parsed.scanComplete { return .stopped }
                self.pendingParentScans.removeValue(forKey: queryKey)
                return .unresolved
            }
            guard let coverage = CostUsageScanner.codexParsedCoverage(
                fileURL: fileURL,
                target: target,
                parsedBytes: parsed.parsedBytes,
                scanComplete: parsed.scanComplete,
                withinRoot: root)
            else {
                if resumable == nil {
                    self.pendingParentScans.removeValue(forKey: queryKey)
                }
                return .stopped
            }
            let journal = CodexParentSnapshotJournal(
                generation: self.generation,
                sessionId: parsedSessionId,
                fileId: target.fileId,
                mtimeUnixMs: coverage.mtimeUnixMs,
                size: coverage.size,
                observedSize: target.observedSize,
                contentFingerprint: target.contentFingerprint,
                parsedBytes: parsed.parsedBytes,
                previousTotals: parsed.previousTotals,
                rawTotalsBaseline: parsed.rawTotalsBaseline,
                hasDivergentTotals: parsed.hasDivergentTotals,
                cutoffTimestamp: cutoffTimestamp,
                cutoffTotals: parsed.cutoffTotals,
                snapshots: nil,
                scanComplete: coverage.scanComplete,
                discardingTruncatedLine: parsed.discardingTruncatedLine)
            self.pendingParentScans[queryKey] = journal
            guard coverage.scanComplete else { return .stopped }
            return self.rememberResolved(queryKey: queryKey, totals: parsed.cutoffTotals)
        }

        private func rememberResolved(
            queryKey: String,
            totals: CostUsageCodexTotals?) -> CodexForkBaseline
        {
            if let totals {
                self.resolvedTotalsByQuery[queryKey] = totals
            } else {
                self.resolvedEmptyQueries.insert(queryKey)
            }
            return .resolved(totals)
        }

        private func compatibleJournal(
            _ journal: CodexParentSnapshotJournal,
            sessionId: String,
            cutoffTimestamp: String,
            metadata: CodexFileMetadata,
            fileURL: URL,
            withinRoot root: URL?) -> Bool
        {
            let target = CodexFrozenFile(
                fileId: journal.fileId,
                mtimeUnixMs: journal.mtimeUnixMs,
                observedSize: journal.observedSize ?? journal.size,
                targetEOF: journal.size,
                contentFingerprint: journal.contentFingerprint)
            return journal.generation == self.generation
                && journal.sessionId == sessionId
                && journal.cutoffTimestamp == cutoffTimestamp
                && journal.snapshots == nil
                && CostUsageScanner.codexFrozenFileIsReadable(
                    target,
                    current: metadata,
                    fileURL: fileURL,
                    withinRoot: root)
                && journal.parsedBytes >= 0
                && journal.parsedBytes <= journal.size
        }
    }

    struct ClaudeParseResult {
        let days: [String: [String: [Int]]]
        let rows: [ClaudeUsageRow]
        let parsedBytes: Int64
    }

    enum ClaudePathRole: String, Codable {
        case parent
        case subagent
    }

    struct ClaudeUsageRow: Codable {
        let dayKey: String
        let model: String
        let sessionId: String?
        let messageId: String?
        let requestId: String?
        let timestampUnixMs: Int64?
        let isSidechain: Bool
        let pathRole: ClaudePathRole
        let input: Int
        let cacheRead: Int
        let cacheCreate: Int
        let cacheCreate1h: Int?
        let output: Int
        let costNanos: Int
        let costPriced: Bool?
    }

    static func loadDailyReport(
        provider: UsageProvider,
        since: Date,
        until: Date,
        now: Date = Date(),
        options: Options = Options()) -> CostUsageDailyReport
    {
        (
            try? self.loadDailyReportCancellable(
                provider: provider,
                since: since,
                until: until,
                now: now,
                options: options,
                checkCancellation: nil)) ?? CostUsageDailyReport(data: [], summary: nil)
    }

    static func loadDailyReportCancellable(
        provider: UsageProvider,
        since: Date,
        until: Date,
        now: Date = Date(),
        options: Options = Options(),
        checkCancellation: CancellationCheck?) throws -> CostUsageDailyReport
    {
        let range = CostUsageDayRange(since: since, until: until)
        let emptyReport = CostUsageDailyReport(data: [], summary: nil)
        try checkCancellation?()

        switch provider {
        case .codex:
            return try self.loadCodexDaily(
                range: range,
                now: now,
                options: options,
                checkCancellation: checkCancellation)
        case .claude:
            return try self.loadClaudeDaily(
                provider: .claude,
                range: range,
                now: now,
                options: options,
                checkCancellation: checkCancellation)
        case .vertexai:
            var filtered = options
            if filtered.claudeLogProviderFilter == .all {
                filtered.claudeLogProviderFilter = .vertexAIOnly
            }
            return try self.loadClaudeDaily(
                provider: .vertexai,
                range: range,
                now: now,
                options: filtered,
                checkCancellation: checkCancellation)
        case .openai, .azureopenai, .zai, .gemini, .antigravity, .cursor, .opencode, .opencodego, .alibaba,
             .alibabatokenplan, .factory,
             .copilot, .devin, .minimax, .manus, .kilo, .kiro, .kimi, .kimik2, .moonshot, .augment, .jetbrains, .amp,
             .ollama, .t3chat, .synthetic, .openrouter, .elevenlabs, .warp, .perplexity, .mimo, .doubao, .abacus,
             .mistral, .deepseek, .codebuff, .crof, .windsurf, .zed, .venice, .commandcode, .stepfun, .bedrock, .grok,
             .groq, .llmproxy, .litellm, .deepgram, .poe, .chutes:
            return emptyReport
        }
    }

    // MARK: - Day keys

    struct CostUsageDayRange {
        let sinceKey: String
        let untilKey: String
        let scanSinceKey: String
        let scanUntilKey: String

        init(since: Date, until: Date) {
            self.sinceKey = Self.dayKey(from: since)
            self.untilKey = Self.dayKey(from: until)
            self.scanSinceKey = Self.dayKey(from: Calendar.current.date(byAdding: .day, value: -1, to: since) ?? since)
            self.scanUntilKey = Self.dayKey(from: Calendar.current.date(byAdding: .day, value: 1, to: until) ?? until)
        }

        init(scanSinceKey: String, scanUntilKey: String) {
            self.scanSinceKey = scanSinceKey
            self.scanUntilKey = scanUntilKey
            self.sinceKey = Self.shiftedDayKey(scanSinceKey, by: 1) ?? scanSinceKey
            self.untilKey = Self.shiftedDayKey(scanUntilKey, by: -1) ?? scanUntilKey
        }

        private static func shiftedDayKey(_ key: String, by days: Int) -> String? {
            let parts = key.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            var calendar = Calendar.current
            calendar.timeZone = .current
            guard let date = calendar.date(from: DateComponents(
                year: parts[0], month: parts[1], day: parts[2])),
                  let shifted = calendar.date(byAdding: .day, value: days, to: date)
            else { return nil }
            return Self.dayKey(from: shifted)
        }

        static func dayKey(from date: Date) -> String {
            let cal = Calendar.current
            let comps = cal.dateComponents([.year, .month, .day], from: date)
            let y = comps.year ?? 1970
            let m = comps.month ?? 1
            let d = comps.day ?? 1
            return String(format: "%04d-%02d-%02d", y, m, d)
        }

        static func isInRange(dayKey: String, since: String, until: String) -> Bool {
            if dayKey < since { return false }
            if dayKey > until { return false }
            return true
        }
    }

    // MARK: - Codex

    private static func defaultCodexSessionsRoot(options: Options) -> URL {
        if let override = options.codexSessionsRoot { return override }
        let env = ProcessInfo.processInfo.environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let env, !env.isEmpty {
            return URL(fileURLWithPath: env).appendingPathComponent("sessions", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    private static func codexSessionsRoots(options: Options) -> [URL] {
        let root = self.defaultCodexSessionsRoot(options: options).standardizedFileURL
        if let archived = self.codexArchivedSessionsRoot(sessionsRoot: root) {
            return [root, archived.standardizedFileURL]
        }
        return [root]
    }

    private static func codexArchivedSessionsRoot(sessionsRoot: URL) -> URL? {
        guard sessionsRoot.lastPathComponent == "sessions" else { return nil }
        return sessionsRoot
            .deletingLastPathComponent()
            .appendingPathComponent("archived_sessions", isDirectory: true)
    }

    private static func listCodexSessionFiles(
        root: URL,
        scanSinceKey: String,
        scanUntilKey: String,
        includeRecursive: Bool) -> [URL]
    {
        let partitioned = self.listCodexSessionFilesByDatePartition(
            root: root,
            scanSinceKey: scanSinceKey,
            scanUntilKey: scanUntilKey)
        let flat = self.listCodexSessionFilesFlat(root: root, scanSinceKey: scanSinceKey, scanUntilKey: scanUntilKey)
        let recursive = includeRecursive ? self.listCodexLegacySessionFilesRecursive(root: root) : []
        var seen: Set<String> = []
        var out: [URL] = []
        for item in partitioned + flat + recursive {
            let canonicalItem = item.standardizedFileURL
            guard seen.insert(canonicalItem.path).inserted else { continue }
            out.append(canonicalItem)
        }
        return out
    }

    private static func cachedCodexSessionFiles(
        cache: CostUsageCache,
        range: CostUsageDayRange,
        roots: [URL],
        excludingPaths: Set<String>) -> [URL]
    {
        cache.files.compactMap { path, usage in
            let fileURL = URL(fileURLWithPath: path).standardizedFileURL
            guard !excludingPaths.contains(fileURL.path) else { return nil }
            let hasRelevantDay = usage.days.keys.contains {
                CostUsageDayRange.isInRange(dayKey: $0, since: range.scanSinceKey, until: range.scanUntilKey)
            }
            guard hasRelevantDay else { return nil }
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
            guard Self.isWithinCodexRoots(fileURL: fileURL, roots: roots) else { return nil }
            return fileURL
        }
    }

    private static func cachedCodexSessionIndex(
        cache: CostUsageCache,
        roots: [URL],
        knownExistingPaths: Set<String>) -> [String: URL]
    {
        var out: [String: URL] = [:]
        for (path, usage) in cache.files {
            guard let sessionId = usage.sessionId, !sessionId.isEmpty else { continue }
            let fileURL = URL(fileURLWithPath: path).standardizedFileURL
            if knownExistingPaths.contains(fileURL.path) {
                out[sessionId] = fileURL
                continue
            }
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }
            guard Self.isWithinCodexRoots(fileURL: fileURL, roots: roots) else { continue }
            out[sessionId] = fileURL
        }
        return out
    }

    private static func codexRootsFingerprint(_ roots: [URL]) -> [String: Int64] {
        var out: [String: Int64] = [:]
        for root in roots {
            out[root.standardizedFileURL.path] = 0
        }
        return out
    }

    static func codexRootsFingerprint(options: Options) -> [String: Int64] {
        self.codexRootsFingerprint(self.codexSessionsRoots(options: options))
    }

    private static func codexPricingKey(modelsDevArtifact: ModelsDevCacheArtifact?) -> String {
        guard let modelsDevArtifact else {
            let fingerprint = CostUsagePricing.codexBuiltInPricingFingerprint()
            return "builtin-\(Self.sha256Hex(Data(fingerprint.utf8)))"
        }
        let fingerprint = self.modelsDevPricingFingerprint(modelsDevArtifact.catalog)
        return "models-dev-v\(modelsDevArtifact.version)-\(Self.sha256Hex(Data(fingerprint.utf8)))"
    }

    private static func modelsDevPricingFingerprint(_ catalog: ModelsDevCatalog) -> String {
        var parts: [String] = []
        for providerID in catalog.providers.keys.sorted() {
            guard let provider = catalog.providers[providerID] else { continue }
            parts.append("provider=\(providerID)|\(provider.id ?? "")")
            for modelKey in provider.models.keys.sorted() {
                guard let model = provider.models[modelKey] else { continue }
                let cost = model.cost
                let contextOver200K = cost?.contextOver200K
                parts.append([
                    "model=\(modelKey)",
                    model.id,
                    Self.optionalDoubleFingerprint(cost?.input),
                    Self.optionalDoubleFingerprint(cost?.output),
                    Self.optionalDoubleFingerprint(cost?.cacheRead),
                    Self.optionalDoubleFingerprint(cost?.cacheWrite),
                    Self.optionalDoubleFingerprint(contextOver200K?.input),
                    Self.optionalDoubleFingerprint(contextOver200K?.output),
                    Self.optionalDoubleFingerprint(contextOver200K?.cacheRead),
                    Self.optionalDoubleFingerprint(contextOver200K?.cacheWrite),
                    model.limit?.context.map(String.init) ?? "nil",
                ].joined(separator: "|"))
            }
        }
        return parts.joined(separator: "\n")
    }

    private static func optionalDoubleFingerprint(_ value: Double?) -> String {
        guard let value else { return "nil" }
        return String(format: "%.17g", value)
    }

    private static func codexPriorityMetadataKey(databaseURL: URL?) -> String {
        let url = databaseURL ?? self.defaultCodexPriorityDatabaseURL()
        let path = url.standardizedFileURL.path
        return FileManager.default.fileExists(atPath: path) ? "sqlite:\(path)" : "missing:\(path)"
    }

    private static func codexPriorityMetadataChanged(old: String?, new: String) -> Bool {
        guard let old, old != new else { return false }
        return new.hasPrefix("sqlite:")
    }

    private static func codexPriorityTurnKeys(
        _ priorityTurns: [String: CodexPriorityTurnMetadata]) -> [String: String]
    {
        var partsByDay: [String: [String]] = [:]
        for (turnID, turn) in priorityTurns {
            guard let dayKey = self.codexPriorityDayKey(turn) else { continue }
            partsByDay[dayKey, default: []].append([
                turnID,
                turn.model ?? "",
                turn.timestamp ?? "",
                turn.threadID ?? "",
            ].joined(separator: "|"))
        }
        var out: [String: String] = [:]
        for (dayKey, parts) in partsByDay {
            out[dayKey] = self.sha256Hex(Data(parts.sorted().joined(separator: "\n").utf8))
        }
        return out
    }

    private static func codexPriorityTurnIDsByDay(
        _ priorityTurns: [String: CodexPriorityTurnMetadata]) -> [String: [String]]
    {
        var out: [String: Set<String>] = [:]
        for (turnID, turn) in priorityTurns {
            guard let dayKey = self.codexPriorityDayKey(turn) else { continue }
            out[dayKey, default: []].insert(turnID)
        }
        return out.mapValues { $0.sorted() }
    }

    private static func codexPriorityDayKey(_ turn: CodexPriorityTurnMetadata) -> String? {
        guard let timestamp = turn.timestamp else { return nil }
        let dayKeyFromEpoch = Int64(timestamp).map {
            CostUsageDayRange.dayKey(from: Date(timeIntervalSince1970: TimeInterval($0)))
        }
        return dayKeyFromEpoch ?? self.dayKeyFromTimestamp(timestamp) ?? self.dayKeyFromParsedISO(timestamp)
    }

    private static func codexPriorityTurnKeysChanged(
        old: [String: String]?,
        new: [String: String],
        range: CostUsageDayRange) -> Bool
    {
        for dayKey in self.dayKeys(sinceKey: range.scanSinceKey, untilKey: range.scanUntilKey)
            where old?[dayKey] != new[dayKey]
        {
            return true
        }
        return false
    }

    private static func changedPriorityTurnIDs(
        old: [String: [String]]?,
        new: [String: [String]],
        oldKeys: [String: String]?,
        newKeys: [String: String],
        range: CostUsageDayRange) -> Set<String>
    {
        var out = Set<String>()
        for dayKey in self.dayKeys(sinceKey: range.scanSinceKey, untilKey: range.scanUntilKey) {
            let oldIDs = Set(old?[dayKey] ?? [])
            let newIDs = Set(new[dayKey] ?? [])
            if oldIDs != newIDs || oldKeys?[dayKey] != newKeys[dayKey] {
                out.formUnion(oldIDs)
                out.formUnion(newIDs)
            }
        }
        return out
    }

    private static func mergePriorityTurnKeys(
        existing: [String: String]?,
        new: [String: String],
        range: CostUsageDayRange,
        retainedSinceKey: String,
        retainedUntilKey: String) -> [String: String]?
    {
        var out = existing ?? [:]
        for dayKey in self.dayKeys(sinceKey: range.scanSinceKey, untilKey: range.scanUntilKey) {
            out[dayKey] = new[dayKey]
        }
        out = out.filter { key, _ in
            CostUsageDayRange.isInRange(dayKey: key, since: retainedSinceKey, until: retainedUntilKey)
        }
        return out.isEmpty ? nil : out
    }

    private static func mergePriorityTurnIDsByDay(
        existing: [String: [String]]?,
        new: [String: [String]],
        range: CostUsageDayRange,
        retainedSinceKey: String,
        retainedUntilKey: String) -> [String: [String]]?
    {
        var out = existing ?? [:]
        for dayKey in self.dayKeys(sinceKey: range.scanSinceKey, untilKey: range.scanUntilKey) {
            out[dayKey] = new[dayKey] ?? []
        }
        out = out.filter { key, _ in
            CostUsageDayRange.isInRange(dayKey: key, since: retainedSinceKey, until: retainedUntilKey)
        }
        return out.isEmpty ? nil : out
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func codexOpaquePendingGeneration(_ generation: String) -> String {
        "codex-\(Self.sha256Hex(Data(("pending-v1\0" + generation).utf8)))"
    }

    static func codexPendingProgressFingerprint(_ cache: CostUsageCache) -> String {
        var parts = ["generation:\(cache.codexPendingScanGeneration ?? "")"]
        // Queue membership is durable progress, but queue rotation alone is
        // not. Sorting here mirrors CodexBar's no-progress contract and stops
        // an unproductive partial file from creating an infinite cycle.
        for path in Set(cache.codexPendingFileOrder ?? []).sorted() {
            parts.append("queue:\(Self.sha256Hex(Data(path.utf8)))")
        }
        for (root, offset) in (cache.codexPendingFlatDiscoveryOffsets ?? [:])
            .sorted(by: { $0.key < $1.key })
        {
            parts.append("flat:\(Self.sha256Hex(Data(root.utf8))):\(offset)")
        }
        for (root, token) in (cache.codexPendingFlatDiscoveryProgress ?? [:])
            .sorted(by: { $0.key < $1.key })
        {
            parts.append("flat-progress:\(Self.sha256Hex(Data(root.utf8))):\(token)")
        }
        for (path, target) in (cache.codexPendingFileManifest ?? [:]).sorted(by: { $0.key < $1.key }) {
            parts.append([
                "target", Self.sha256Hex(Data(path.utf8)), target.fileId,
                String(target.observedSize), String(target.targetEOF),
                target.contentFingerprint ?? "",
            ].joined(separator: ":"))
        }
        for (path, usage) in (cache.codexPendingFiles ?? [:]).sorted(by: { $0.key < $1.key }) {
            parts.append([
                "file", Self.sha256Hex(Data(path.utf8)),
                String(usage.parsedBytes ?? 0), String(usage.codexScanTargetSize ?? 0),
                String(usage.codexScanComplete == true),
            ].joined(separator: ":"))
        }
        for (key, journal) in (cache.codexPendingParentScans ?? [:]).sorted(by: { $0.key < $1.key }) {
            parts.append([
                "parent", key, String(journal.parsedBytes), String(journal.size),
                String(journal.scanComplete),
            ].joined(separator: ":"))
        }
        for (sessionId, journal) in (cache.codexPendingParentDiscoveries ?? [:])
            .sorted(by: { $0.key < $1.key })
        {
            var discovery = [
                "discovery", Self.sha256Hex(Data(sessionId.utf8)), String(journal.rootIndex),
                String(journal.resolvedRootIndex ?? -1), journal.resolvedRelativePath ?? "",
            ]
            for cursor in journal.directoryStack {
                discovery.append(cursor.relativePath)
                discovery.append(cursor.lastEntryName ?? "")
                discovery.append(String(cursor.nextEntryIndex ?? 0))
                discovery.append(Self.sha256Hex(Data(
                    (cursor.frozenEntryNames ?? []).joined(separator: "\n").utf8)))
            }
            parts.append(discovery.joined(separator: ":"))
        }
        return "codex-progress-\(Self.sha256Hex(Data(parts.joined(separator: "\n").utf8)))"
    }

    /// Reconciles a persisted FIFO with the current frozen manifest without
    /// reordering existing waiters. New work keeps BirdNion's established
    /// newest-path admission order because duplicate-session attribution is
    /// order-sensitive in this finite-generation scanner; fairness comes from
    /// durable rotation after the first service.
    static func reconciledCodexPendingFileOrder(
        persistedOrder: [String]?,
        eligiblePaths: Set<String>) -> [String]
    {
        var seen: Set<String> = []
        var order: [String] = []
        for path in persistedOrder ?? [] {
            let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
            guard eligiblePaths.contains(canonical), seen.insert(canonical).inserted else { continue }
            order.append(canonical)
        }

        let newlyEligible = eligiblePaths.filter { !seen.contains($0) }.sorted(by: >)
        order.append(contentsOf: newlyEligible)
        return order
    }

    /// Removes exact completions and moves only serviced partial files behind
    /// all waiters, including paths outside this pass's candidate prefix.
    static func finalizedCodexPendingFileOrder(
        _ order: [String],
        completedPaths: Set<String>,
        servicedIncompletePaths: Set<String>) -> [String]
    {
        let remaining = order.filter { !completedPaths.contains($0) }
        let rotated = remaining.filter { servicedIncompletePaths.contains($0) }
        guard !rotated.isEmpty else { return remaining }
        let rotatedSet = Set(rotated)
        return remaining.filter { !rotatedSet.contains($0) } + rotated
    }

    private static func listCodexRecentlyModifiedFiles(
        root: URL,
        scanSinceKey: String,
        scanUntilKey: String,
        modifiedSince: Date,
        includeLegacyRecursive: Bool) -> [URL]
    {
        let lookbackSinceKey = self.dayKey(scanSinceKey, addingDays: -self.codexActiveSessionLookbackDays)
            ?? scanSinceKey
        let partitioned = self.listCodexSessionFilesByDatePartition(
            root: root,
            scanSinceKey: lookbackSinceKey,
            scanUntilKey: scanUntilKey)
        let partitionedModified = self.filterRecentlyModified(files: partitioned, modifiedSince: modifiedSince)

        let legacyRecursive = includeLegacyRecursive
            ? self.listCodexRecentlyModifiedFilesRecursive(root: root, modifiedSince: modifiedSince)
            : []
        var seen = Set(partitionedModified.map(\.path))
        var out = partitionedModified
        for fileURL in legacyRecursive where !seen.contains(fileURL.path) {
            seen.insert(fileURL.path)
            out.append(fileURL)
        }
        return out
    }

    private static func filterRecentlyModified(files: [URL], modifiedSince: Date) -> [URL] {
        files.filter { fileURL in
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else { return false }
            guard let modifiedAt = values?.contentModificationDate else { return false }
            return modifiedAt >= modifiedSince
        }
    }

    private static func isDatePartitionComponent(_ value: String, length: Int) -> Bool {
        value.count == length && value.allSatisfy(\.isNumber)
    }

    private static func dayKey(_ dayKey: String, addingDays days: Int) -> String? {
        guard let date = self.parseDayKey(dayKey) else { return nil }
        guard let shifted = Calendar.current.date(byAdding: .day, value: days, to: date) else { return nil }
        return CostUsageDayRange.dayKey(from: shifted)
    }

    private static func dayKeys(sinceKey: String, untilKey: String) -> [String] {
        guard let since = self.parseDayKey(sinceKey),
              self.parseDayKey(untilKey) != nil
        else { return sinceKey <= untilKey ? [sinceKey] : [] }

        var out: [String] = []
        var cursor = since
        let calendar = Calendar.current
        while CostUsageDayRange.dayKey(from: cursor) <= untilKey {
            out.append(CostUsageDayRange.dayKey(from: cursor))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            if next <= cursor { break }
            cursor = next
        }
        return out
    }

    private static func listCodexRecentlyModifiedFilesRecursive(root: URL, modifiedSince: Date) -> [URL] {
        Self.listCodexFilesInFiniteTree(root: root).filter { fileURL in
            guard fileURL.pathExtension.lowercased() == "jsonl" else { return false }
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else { return false }
            guard let modifiedAt = values?.contentModificationDate else { return false }
            return modifiedAt >= modifiedSince
        }
    }

    private static func isWithinCodexRoots(fileURL: URL, roots: [URL]) -> Bool {
        let filePath = fileURL.standardizedFileURL.path
        return roots.contains { root in
            let rootPath = root.standardizedFileURL.path
            if filePath == rootPath { return true }
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            return filePath.hasPrefix(prefix)
        }
    }

    private static func listCodexSessionFilesByDatePartition(
        root: URL,
        scanSinceKey: String,
        scanUntilKey: String) -> [URL]
    {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        var out: [URL] = []
        var date = Self.parseDayKey(scanSinceKey) ?? Date()
        let untilDate = Self.parseDayKey(scanUntilKey) ?? date

        while date <= untilDate {
            let comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
            let y = String(format: "%04d", comps.year ?? 1970)
            let m = String(format: "%02d", comps.month ?? 1)
            let d = String(format: "%02d", comps.day ?? 1)

            let dayDir = root.appendingPathComponent(y, isDirectory: true)
                .appendingPathComponent(m, isDirectory: true)
                .appendingPathComponent(d, isDirectory: true)

            if let items = try? FileManager.default.contentsOfDirectory(
                at: dayDir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles])
            {
                for item in items where item.pathExtension.lowercased() == "jsonl"
                    && Self.codexFileMetadata(fileURL: item).fileId != nil
                {
                    out.append(item)
                }
            }

            date = Calendar.current.date(byAdding: .day, value: 1, to: date) ?? untilDate.addingTimeInterval(1)
        }

        return out
    }

    private static func listCodexSessionFilesFlat(root: URL, scanSinceKey: String, scanUntilKey: String) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }

        var out: [URL] = []
        for item in items where item.pathExtension.lowercased() == "jsonl"
            && Self.codexFileMetadata(fileURL: item).fileId != nil
        {
            if let dayKey = Self.dayKeyFromFilename(item.lastPathComponent) {
                if !CostUsageDayRange.isInRange(dayKey: dayKey, since: scanSinceKey, until: scanUntilKey) {
                    continue
                }
            }
            out.append(item)
        }
        return out
    }

    private struct CodexFlatDirectoryPage {
        let files: [URL]
        let nextOffset: Int64?
        let visits: Int
        let continuationToken: String?
    }

    #if os(Linux)
    private typealias CodexFlatDirectoryHandle = OpaquePointer
    #else
    private typealias CodexFlatDirectoryHandle = UnsafeMutablePointer<DIR>
    #endif

    private final class CodexFlatDirectoryCursor: @unchecked Sendable {
        let directory: CodexFlatDirectoryHandle
        let identity = UUID().uuidString
        var logicalOffset: Int64 = 0

        init(directory: CodexFlatDirectoryHandle) {
            self.directory = directory
        }

        deinit { closedir(directory) }
    }

    private final class CodexFlatDirectoryCursorRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var cursors: [String: CodexFlatDirectoryCursor] = [:]

        func page(
            directoryURL: URL,
            resumeOffset: Int64,
            visitLimit: Int,
            filter: (String) -> Bool) -> CodexFlatDirectoryPage
        {
            lock.lock()
            defer { lock.unlock() }

            let path = directoryURL.standardizedFileURL.path
            let resumeOffset = max(0, resumeOffset)
            if resumeOffset == 0 || (cursors[path]?.logicalOffset ?? 0) > resumeOffset {
                cursors.removeValue(forKey: path)
            }
            if cursors[path] == nil {
                guard let directory = opendir(path) else {
                    // A configured archive root commonly does not exist yet;
                    // that is an empty directory. A root that still exists but
                    // cannot be opened is not EOF: retain the ordinal so a
                    // later pass retries without allowing final prune.
                    let rootStillExists = FileManager.default.fileExists(atPath: path)
                    return CodexFlatDirectoryPage(
                        files: [],
                        nextOffset: rootStillExists ? resumeOffset : nil,
                        visits: 0,
                        continuationToken: nil)
                }
                cursors[path] = CodexFlatDirectoryCursor(directory: directory)
            }
            guard let cursor = cursors[path] else {
                return CodexFlatDirectoryPage(
                    files: [],
                    nextOffset: resumeOffset,
                    visits: 0,
                    continuationToken: nil)
            }

            var files: [URL] = []
            var visits = 0
            while visits < max(0, visitLimit) {
                guard let entry = readdir(cursor.directory) else {
                    cursors.removeValue(forKey: path)
                    return CodexFlatDirectoryPage(
                        files: files,
                        nextOffset: nil,
                        visits: visits,
                        continuationToken: nil)
                }
                let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: 1024) {
                        String(cString: $0)
                    }
                }
                guard name != ".", name != ".." else { continue }
                cursor.logicalOffset += 1
                visits += 1
                guard cursor.logicalOffset > resumeOffset, filter(name) else { continue }
                files.append(directoryURL.appendingPathComponent(name, isDirectory: false))
            }
            return CodexFlatDirectoryPage(
                files: files,
                nextOffset: max(resumeOffset, cursor.logicalOffset),
                visits: visits,
                continuationToken: "\(cursor.identity):\(cursor.logicalOffset)")
        }

        func reset() {
            lock.lock()
            cursors.removeAll()
            lock.unlock()
        }
    }

    private static let codexFlatDirectoryCursorRegistry = CodexFlatDirectoryCursorRegistry()

    /// Test seam for the process-restart contract. The durable cache remains
    /// intact while every in-memory DIR cursor is discarded.
    static func resetCodexFlatDirectoryCursorsForTesting() {
        self.codexFlatDirectoryCursorRegistry.reset()
    }

    private static func listCodexFlatDirectoryPage(
        root: URL,
        scanSinceKey: String,
        scanUntilKey: String,
        resumeOffset: Int64,
        visitLimit: Int) -> CodexFlatDirectoryPage
    {
        self.codexFlatDirectoryCursorRegistry.page(
            directoryURL: root,
            resumeOffset: resumeOffset,
            visitLimit: visitLimit)
        { name in
            guard name.lowercased().hasSuffix(".jsonl") else { return false }
            guard let dayKey = Self.dayKeyFromFilename(name) else { return true }
            return CostUsageDayRange.isInRange(
                dayKey: dayKey,
                since: scanSinceKey,
                until: scanUntilKey)
        }
    }

    private static func listCodexLegacySessionFilesRecursive(root: URL) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let rootPath = root.standardizedFileURL.path
        return Self.listCodexFilesInFiniteTree(root: root) { directory in
            !Self.isCodexDatePartitionAncestor(directory, rootPath: rootPath)
        }.filter { $0.pathExtension.lowercased() == "jsonl" }
    }

    /// Snapshot each directory once and cap depth so corpus discovery itself
    /// remains finite even while another process creates new files/directories.
    private static func listCodexFilesInFiniteTree(
        root: URL,
        maximumDepth: Int = 32,
        shouldDescend: (URL) -> Bool = { _ in true }) -> [URL]
    {
        guard maximumDepth > 0,
              FileManager.default.fileExists(atPath: root.path)
        else { return [] }

        var files: [URL] = []
        var directories: [(url: URL, depth: Int)] = [(root.standardizedFileURL, 0)]
        while let directory = directories.popLast() {
            guard directory.depth < maximumDepth else { continue }
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: directory.url,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }

            for entry in entries.sorted(by: { $0.path > $1.path }) {
                let values = try? entry.resourceValues(
                    forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values?.isSymbolicLink != true else { continue }
                if values?.isDirectory == true {
                    if shouldDescend(entry) {
                        directories.append((entry.standardizedFileURL, directory.depth + 1))
                    }
                } else if values?.isRegularFile == true {
                    files.append(entry.standardizedFileURL)
                }
            }
        }
        return files
    }

    private static func isCodexDatePartitionAncestor(_ url: URL, rootPath: String) -> Bool {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return false }
        let relative = String(path.dropFirst(rootPath.count + 1))
        let parts = relative.split(separator: "/")
        guard parts.count == 1 else { return false }
        return Self.isDatePartitionComponent(String(parts[0]), length: 4)
    }

    private static let codexFilenameDateRegex = try? NSRegularExpression(pattern: "(\\d{4}-\\d{2}-\\d{2})")

    private static func dayKeyFromFilename(_ filename: String) -> String? {
        guard let regex = self.codexFilenameDateRegex else { return nil }
        let range = NSRange(filename.startIndex..<filename.endIndex, in: filename)
        guard let match = regex.firstMatch(in: filename, range: range) else { return nil }
        guard let matchRange = Range(match.range(at: 1), in: filename) else { return nil }
        return String(filename[matchRange])
    }

    private struct CodexSessionMetadata {
        let sessionId: String?
        let forkedFromId: String?
        let forkTimestamp: String?
        let cliVersion: String?
        let projectKey: String?
        let projectName: String?
        let projectAttributionAmbiguous: Bool
    }

    private struct CodexTokenCountRecord {
        let timestamp: String
        let model: String?
        let turnID: String?
        let last: CostUsageCodexTotals?
        let total: CostUsageCodexTotals?
    }

    private enum CodexFastLine {
        case sessionMeta(CodexSessionMetadata)
        case turnContext(model: String?)
        case taskStarted(turnID: String?)
        case tokenCount(CodexTokenCountRecord)
    }

    private static let codexJSONFieldCachedInputTokens = Array("cached_input_tokens".utf8)
    private static let codexJSONFieldCacheReadInputTokens = Array("cache_read_input_tokens".utf8)
    private static let codexJSONFieldCliVersion = Array("cli_version".utf8)
    private static let codexJSONFieldForkedFromId = Array("forked_from_id".utf8)
    private static let codexJSONFieldForkedFromIdCamel = Array("forkedFromId".utf8)
    private static let codexJSONFieldId = Array("id".utf8)
    private static let codexJSONFieldInfo = Array("info".utf8)
    private static let codexJSONFieldInputTokens = Array("input_tokens".utf8)
    private static let codexJSONFieldLastTokenUsage = Array("last_token_usage".utf8)
    private static let codexJSONFieldModel = Array("model".utf8)
    private static let codexJSONFieldModelName = Array("model_name".utf8)
    private static let codexJSONFieldOutputTokens = Array("output_tokens".utf8)
    private static let codexJSONFieldParentSessionId = Array("parent_session_id".utf8)
    private static let codexJSONFieldParentSessionIdCamel = Array("parentSessionId".utf8)
    private static let codexJSONFieldPayload = Array("payload".utf8)
    private static let codexJSONFieldSessionId = Array("session_id".utf8)
    private static let codexJSONFieldSessionIdCamel = Array("sessionId".utf8)
    private static let codexJSONFieldTimestamp = Array("timestamp".utf8)
    private static let codexJSONFieldTotalTokenUsage = Array("total_token_usage".utf8)
    private static let codexJSONFieldTurnId = Array("turn_id".utf8)
    private static let codexJSONFieldTurnIdCamel = Array("turnId".utf8)
    private static let codexJSONFieldType = Array("type".utf8)
    private static let codexJSONFieldCwd = Array("cwd".utf8)

    private static func codexProjectIdentity(cwd: String?) -> (key: String, name: String)? {
        guard let cwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cwd.isEmpty,
              (cwd as NSString).isAbsolutePath,
              !cwd.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        let path = URL(fileURLWithPath: cwd).standardizedFileURL.path
        let digest = SHA256.hash(data: Data("codex:cwd-v1\0\(path)".utf8))
        let key = digest.map { String(format: "%02x", $0) }.joined()
        let rawName = URL(fileURLWithPath: path).lastPathComponent
        let basename = rawName.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last
            .map(String.init) ?? ""
        let cleaned = String(basename.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }).trimmingCharacters(in: .whitespacesAndNewlines)
        let name = cleaned.isEmpty ? "Codex Project \(key.prefix(8))" : String(cleaned.prefix(48))
        return (key, name)
    }

    private static func codexForkParentId(from payload: [String: Any]?) -> String? {
        guard let payload else { return nil }
        for key in ["forked_from_id", "forkedFromId", "parent_session_id", "parentSessionId"] {
            guard let value = payload[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private static func codexForkParentId(
        from bytes: UnsafeBufferPointer<UInt8>,
        in payloadRange: Range<Int>) -> String?
    {
        for key in [
            self.codexJSONFieldForkedFromId,
            self.codexJSONFieldForkedFromIdCamel,
            self.codexJSONFieldParentSessionId,
            self.codexJSONFieldParentSessionIdCamel,
        ] {
            guard let value = extractJSONByteStringField(key, from: bytes, in: payloadRange, atDepth: 1)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !value.isEmpty
            else { continue }
            return value
        }
        return nil
    }

    private static func codexTurnID(from bytes: UnsafeBufferPointer<UInt8>, in payloadRange: Range<Int>) -> String? {
        for key in [self.codexJSONFieldTurnId, self.codexJSONFieldTurnIdCamel, self.codexJSONFieldId] {
            if let value = extractJSONByteStringField(key, from: bytes, in: payloadRange, atDepth: 1), !value.isEmpty {
                return value
            }
        }
        if let infoRange = extractJSONByteObjectField(codexJSONFieldInfo, from: bytes, in: payloadRange, atDepth: 1) {
            for key in [self.codexJSONFieldTurnId, self.codexJSONFieldTurnIdCamel, self.codexJSONFieldId] {
                if let value = extractJSONByteStringField(key, from: bytes, in: infoRange, atDepth: 1), !value.isEmpty {
                    return value
                }
            }
        }
        return nil
    }

    /// Extracts THIS FILE's own session identity. `id` must be checked before
    /// `session_id`/`sessionId`: for a normal top-level session the two match,
    /// but a spawned-subagent thread's `session_meta.payload` carries its OWN
    /// identity in `id` while `session_id` points at the ROOT conversation it
    /// belongs to. Preferring `session_id` there made every subagent file
    /// belonging to the same root index under the ROOT's id — collapsing
    /// distinct files onto one key (last-enumerated file silently wins) and
    /// corrupting anything keyed by session id, notably
    /// `CodexInheritedTotalsResolver`'s fork-baseline lookup (it would parse
    /// a random subagent transcript instead of the true parent, computing a
    /// baseline orders of magnitude too small and inflating the fork's
    /// counted usage by its entire replayed history).
    private static func codexSessionId(
        from bytes: UnsafeBufferPointer<UInt8>,
        in rootRange: Range<Int>,
        payloadRange: Range<Int>?) -> String?
    {
        if let payloadRange {
            for key in [self.codexJSONFieldId, self.codexJSONFieldSessionId, self.codexJSONFieldSessionIdCamel] {
                if let value = extractJSONByteStringField(key, from: bytes, in: payloadRange, atDepth: 1),
                   !value.isEmpty
                {
                    return value
                }
            }
        }
        for key in [Self.codexJSONFieldId, Self.codexJSONFieldSessionId, Self.codexJSONFieldSessionIdCamel] {
            if let value = Self.extractJSONByteStringField(key, from: bytes, in: rootRange, atDepth: 1),
               !value.isEmpty
            {
                return value
            }
        }
        return nil
    }

    private static func codexTotals(
        from bytes: UnsafeBufferPointer<UInt8>,
        in objectRange: Range<Int>?) -> CostUsageCodexTotals?
    {
        guard let objectRange else { return nil }
        let input = max(
            0,
            Self.extractJSONByteIntField(Self.codexJSONFieldInputTokens, from: bytes, in: objectRange, atDepth: 1) ?? 0)
        let cached = max(
            0,
            Self.extractJSONByteIntField(Self.codexJSONFieldCachedInputTokens, from: bytes, in: objectRange, atDepth: 1)
                ?? Self.extractJSONByteIntField(
                    Self.codexJSONFieldCacheReadInputTokens,
                    from: bytes,
                    in: objectRange,
                    atDepth: 1)
                ?? 0)
        let output = max(
            0,
            Self
                .extractJSONByteIntField(Self.codexJSONFieldOutputTokens, from: bytes, in: objectRange, atDepth: 1) ??
                0)
        return CostUsageCodexTotals(input: input, cached: cached, output: output)
    }

    private static func codexUsesCompactForkTotals(cliVersion: String?) -> Bool {
        guard let cliVersion else { return false }
        let components = cliVersion.split(separator: ".", maxSplits: 2).map { component in
            Int(component.prefix(while: { $0.isNumber })) ?? 0
        }
        guard components.count >= 2 else { return false }
        if components[0] != 0 { return components[0] > 0 }
        if components[1] != 150 { return components[1] > 150 }
        return (components.count > 2 ? components[2] : 0) >= 0
    }

    private static func parseCodexFastLine(_ bytes: Data) -> CodexFastLine? {
        bytes.withUnsafeBytes { rawBytes in
            let rawBuffer = rawBytes.bindMemory(to: UInt8.self)
            guard !rawBuffer.isEmpty else { return nil }
            let objectRange = 0..<rawBuffer.count
            guard let type = Self.extractJSONByteStringField(
                Self.codexJSONFieldType,
                from: rawBuffer,
                in: objectRange,
                atDepth: 1)
            else { return nil }

            switch type {
            case "session_meta":
                let payloadRange = Self.extractJSONByteObjectField(
                    Self.codexJSONFieldPayload,
                    from: rawBuffer,
                    in: objectRange,
                    atDepth: 1)
                let cwd = payloadRange.flatMap {
                    Self.extractJSONByteStringField(
                        Self.codexJSONFieldCwd, from: rawBuffer, in: $0, atDepth: 1)
                }
                let project = Self.codexProjectIdentity(cwd: cwd)
                let cwdPresent = payloadRange.map {
                    Self.containsJSONByteField(
                        Self.codexJSONFieldCwd, from: rawBuffer, in: $0, atDepth: 1)
                } ?? false
                return .sessionMeta(CodexSessionMetadata(
                    sessionId: Self.codexSessionId(from: rawBuffer, in: objectRange, payloadRange: payloadRange),
                    forkedFromId: payloadRange.flatMap { Self.codexForkParentId(from: rawBuffer, in: $0) },
                    forkTimestamp: payloadRange.flatMap {
                        Self.extractJSONByteStringField(
                            Self.codexJSONFieldTimestamp,
                            from: rawBuffer,
                            in: $0,
                            atDepth: 1)
                    } ?? Self.extractJSONByteStringField(
                        Self.codexJSONFieldTimestamp,
                        from: rawBuffer,
                        in: objectRange,
                        atDepth: 1),
                    cliVersion: payloadRange.flatMap {
                        Self.extractJSONByteStringField(
                            Self.codexJSONFieldCliVersion,
                            from: rawBuffer,
                            in: $0,
                            atDepth: 1)
                    },
                    projectKey: project?.key,
                    projectName: project?.name,
                    projectAttributionAmbiguous: cwdPresent && project == nil))

            case "turn_context":
                guard let payloadRange = Self.extractJSONByteObjectField(
                    Self.codexJSONFieldPayload,
                    from: rawBuffer,
                    in: objectRange,
                    atDepth: 1)
                else { return .turnContext(model: nil) }
                let model = Self.extractJSONByteStringField(
                    Self.codexJSONFieldModel,
                    from: rawBuffer,
                    in: payloadRange,
                    atDepth: 1)
                    ?? Self.extractJSONByteStringField(
                        Self.codexJSONFieldModelName,
                        from: rawBuffer,
                        in: payloadRange,
                        atDepth: 1)
                    ?? Self.extractJSONByteObjectField(
                        Self.codexJSONFieldInfo,
                        from: rawBuffer,
                        in: payloadRange,
                        atDepth: 1).flatMap {
                        Self.extractJSONByteStringField(
                            Self.codexJSONFieldModel,
                            from: rawBuffer,
                            in: $0,
                            atDepth: 1)
                            ?? Self.extractJSONByteStringField(
                                Self.codexJSONFieldModelName,
                                from: rawBuffer,
                                in: $0,
                                atDepth: 1)
                    }
                return .turnContext(model: model)

            case "event_msg":
                guard let payloadRange = Self.extractJSONByteObjectField(
                    Self.codexJSONFieldPayload,
                    from: rawBuffer,
                    in: objectRange,
                    atDepth: 1),
                    let payloadType = Self.extractJSONByteStringField(
                        Self.codexJSONFieldType,
                        from: rawBuffer,
                        in: payloadRange,
                        atDepth: 1)
                else { return nil }

                if payloadType == "task_started" {
                    return .taskStarted(turnID: Self.codexTurnID(from: rawBuffer, in: payloadRange))
                }

                guard payloadType == "token_count",
                      let timestamp = Self.extractJSONByteStringField(
                          Self.codexJSONFieldTimestamp,
                          from: rawBuffer,
                          in: objectRange,
                          atDepth: 1),
                      let infoRange = Self.extractJSONByteObjectField(
                          Self.codexJSONFieldInfo,
                          from: rawBuffer,
                          in: payloadRange,
                          atDepth: 1)
                else { return nil }

                let model = Self.extractJSONByteStringField(
                    Self.codexJSONFieldModel,
                    from: rawBuffer,
                    in: infoRange,
                    atDepth: 1)
                    ?? Self.extractJSONByteStringField(
                        Self.codexJSONFieldModelName,
                        from: rawBuffer,
                        in: infoRange,
                        atDepth: 1)
                    ?? Self.extractJSONByteStringField(
                        Self.codexJSONFieldModel,
                        from: rawBuffer,
                        in: payloadRange,
                        atDepth: 1)
                    ?? Self.extractJSONByteStringField(
                        Self.codexJSONFieldModel,
                        from: rawBuffer,
                        in: objectRange,
                        atDepth: 1)
                let total = Self.codexTotals(
                    from: rawBuffer,
                    in: Self.extractJSONByteObjectField(
                        Self.codexJSONFieldTotalTokenUsage,
                        from: rawBuffer,
                        in: infoRange,
                        atDepth: 1))
                let last = Self.codexTotals(
                    from: rawBuffer,
                    in: Self.extractJSONByteObjectField(
                        Self.codexJSONFieldLastTokenUsage,
                        from: rawBuffer,
                        in: infoRange,
                        atDepth: 1))
                return .tokenCount(CodexTokenCountRecord(
                    timestamp: timestamp,
                    model: model,
                    turnID: Self.codexTurnID(from: rawBuffer, in: payloadRange),
                    last: last,
                    total: total))

            default:
                return nil
            }
        }
    }

    enum CodexSessionIdentityLookup: Equatable {
        case found(String)
        case definitivelyAbsent
        case retryableIOFailure
    }

    static func parseCodexSessionIdentifier(
        fileURL: URL,
        checkCancellation: CancellationCheck? = nil,
        maximumBytes: Int = 512 * 1024,
        withinRoot root: URL? = nil) throws -> CodexSessionIdentityLookup
    {
        guard Self.codexFileMetadata(fileURL: fileURL, withinRoot: root).fileId != nil else {
            return .definitivelyAbsent
        }
        do {
            let metadata = try self.parseCodexSessionMetadata(
                fileURL: fileURL,
                checkCancellation: checkCancellation,
                maximumBytes: max(0, min(512 * 1024, maximumBytes)),
                propagateIOFailure: true,
                withinRoot: root)
            guard let sessionId = metadata?.sessionId, !sessionId.isEmpty else {
                return .definitivelyAbsent
            }
            return .found(sessionId)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            self.log.warning(
                "Codex cost usage could not classify session identity; retrying later",
                metadata: ["path": fileURL.path, "error": error.localizedDescription])
            return .retryableIOFailure
        }
    }

    private static func parseCodexSessionMetadata(
        fileURL: URL,
        checkCancellation: CancellationCheck? = nil,
        shouldStop: (() -> Bool)? = nil,
        maximumBytes: Int? = nil,
        propagateIOFailure: Bool = false,
        withinRoot root: URL? = nil) throws -> CodexSessionMetadata?
    {
        let handle: FileHandle
        do {
            handle = try Self.codexOpenRegularFileForReading(
                fileURL: fileURL,
                withinRoot: root)
        } catch {
            if propagateIOFailure { throw error }
            self.log.warning(
                "Codex cost usage failed to open session file for session id parsing",
                metadata: ["path": fileURL.path, "error": error.localizedDescription])
            return nil
        }
        defer { try? handle.close() }

        var buffer = Data()
        let newline = Data([0x0A])
        // Canonical Codex rollout identity lives in an early session_meta.
        // Bound dependency lookup independently of the scan deadline so each
        // candidate is classified atomically and a bad file cannot pin the
        // durable discovery cursor forever.
        var bytesRead = 0

        func parseSessionMetadata(from lineData: Data) -> CodexSessionMetadata? {
            guard !lineData.isEmpty else { return nil }
            if case let .sessionMeta(metadata) = Self.parseCodexFastLine(lineData) {
                return metadata
            }
            return autoreleasepool {
                guard let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any]
                else { return nil }
                guard obj["type"] as? String == "session_meta" else { return nil }
                let payload = obj["payload"] as? [String: Any]
                let project = Self.codexProjectIdentity(cwd: payload?["cwd"] as? String)
                let cwdPresent = payload?.keys.contains("cwd") == true
                return CodexSessionMetadata(
                    // `id` first: it's this file's own identity for every
                    // session_meta shape. `session_id` matches `id` for a
                    // normal/forked top-level session but points at the ROOT
                    // conversation for a spawned-subagent thread — preferring
                    // it there collapses every subagent file belonging to the
                    // same root onto one key (see `codexSessionId` above).
                    sessionId: payload?["id"] as? String
                        ?? payload?["session_id"] as? String
                        ?? payload?["sessionId"] as? String
                        ?? obj["id"] as? String
                        ?? obj["session_id"] as? String
                        ?? obj["sessionId"] as? String,
                    forkedFromId: Self.codexForkParentId(from: payload),
                    forkTimestamp: payload?["timestamp"] as? String
                        ?? obj["timestamp"] as? String,
                    cliVersion: payload?["cli_version"] as? String,
                    projectKey: project?.key,
                    projectName: project?.name,
                    projectAttributionAmbiguous: cwdPresent && project == nil)
            }
        }

        do {
            while maximumBytes.map({ bytesRead < $0 }) ?? true {
                try checkCancellation?()
                if shouldStop?() == true { return nil }
                let readCount = maximumBytes.map { min(64 * 1024, $0 - bytesRead) }
                    ?? (64 * 1024)
                guard let chunk = try handle.read(upToCount: readCount), !chunk.isEmpty
                else { break }
                bytesRead += chunk.count
                buffer.append(chunk)
                while let newlineRange = buffer.range(of: newline) {
                    let lineData = buffer.subdata(in: 0..<newlineRange.lowerBound)
                    buffer.removeSubrange(0..<newlineRange.upperBound)
                    if let metadata = parseSessionMetadata(from: lineData) {
                        return metadata
                    }
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if propagateIOFailure { throw error }
            self.log.warning(
                "Codex cost usage failed while reading session file for session id parsing",
                metadata: ["path": fileURL.path, "error": error.localizedDescription])
            return nil
        }

        if let metadata = parseSessionMetadata(from: buffer) {
            return metadata
        }
        return nil
    }

    private static func parseCodexTokenSnapshots(
        fileURL: URL,
        cutoffTimestamp: String,
        startOffset: Int64 = 0,
        initialSessionId: String? = nil,
        initialPreviousTotals: CostUsageCodexTotals? = nil,
        initialRawTotalsBaseline: CostUsageCodexTotals? = nil,
        initialHasDivergentTotals: Bool = false,
        initialCutoffTotals: CostUsageCodexTotals? = nil,
        initialDiscardingTruncatedLine: Bool = false,
        checkCancellation: CancellationCheck? = nil,
        shouldStop: (() -> Bool)? = nil,
        endOffset: Int64? = nil,
        withinRoot root: URL? = nil) throws -> (
        sessionId: String?,
        cutoffTotals: CostUsageCodexTotals?,
        parsedBytes: Int64,
        previousTotals: CostUsageCodexTotals?,
        rawTotalsBaseline: CostUsageCodexTotals?,
        hasDivergentTotals: Bool,
        discardingTruncatedLine: Bool,
        scanComplete: Bool)
    {
        var sessionId = initialSessionId
        var previousTotals = initialPreviousTotals
        var rawTotalsBaseline = initialRawTotalsBaseline
        var sawDivergentTotals = initialHasDivergentTotals
        var cutoffTotals = initialCutoffTotals
        var parsedBytes = startOffset
        var discardingTruncatedLine = initialDiscardingTruncatedLine
        var warnedAboutUnparsedTimestamp = false
        let parsedCutoffDate = Self.dateFromTimestamp(cutoffTimestamp)

        func parsedSnapshotDate(timestamp: String) -> Date? {
            let date = Self.dateFromTimestamp(timestamp)
            if date == nil, !warnedAboutUnparsedTimestamp {
                warnedAboutUnparsedTimestamp = true
                self.log.warning(
                    "Codex cost usage could not parse parent token snapshot timestamp; "
                        + "falling back to lexical comparison",
                    metadata: ["path": fileURL.path, "timestamp": timestamp])
            }
            return date
        }

        func appendSnapshot(timestamp: String, last: CostUsageCodexTotals?, total: CostUsageCodexTotals?) {
            if let last {
                let rawDelta = last
                let base = previousTotals ?? .init(input: 0, cached: 0, output: 0)
                var countedDelta = rawDelta

                if let total {
                    let rawTotals = total
                    let totalDelta = Self.codexTotalDelta(from: rawTotalsBaseline, to: rawTotals)
                    if Self.codexShouldPreferTotalDelta(
                        rawBaseline: rawTotalsBaseline,
                        currentTotal: rawTotals,
                        totalDelta: totalDelta,
                        lastDelta: rawDelta,
                        sawDivergentTotals: sawDivergentTotals)
                    {
                        countedDelta = totalDelta
                    }
                    let next = Self.codexAddTotals(base, countedDelta)
                    previousTotals = next
                    rawTotalsBaseline = rawTotals
                    if !Self.codexTotalsEqual(rawTotals, next) {
                        sawDivergentTotals = true
                    }
                } else {
                    let next = Self.codexAddTotals(base, countedDelta)
                    previousTotals = next
                    rawTotalsBaseline = next
                }

            } else if let total {
                let next = total
                let delta = sawDivergentTotals
                    ? Self.codexDivergentTotalDelta(
                        rawBaseline: rawTotalsBaseline,
                        countedBaseline: previousTotals,
                        current: next)
                    : Self.codexTotalDelta(from: rawTotalsBaseline, to: next)
                let base = previousTotals ?? .init(input: 0, cached: 0, output: 0)
                let countedTotals = Self.codexAddTotals(base, delta)
                previousTotals = countedTotals
                rawTotalsBaseline = next
                if !Self.codexTotalsEqual(next, countedTotals) {
                    sawDivergentTotals = true
                }
            }
            let snapshotDate = parsedSnapshotDate(timestamp: timestamp)
            let isAtOrBefore: Bool = if let snapshotDate, let parsedCutoffDate {
                snapshotDate <= parsedCutoffDate
            } else {
                timestamp <= cutoffTimestamp
            }
            if isAtOrBefore { cutoffTotals = previousTotals }
        }

        do {
            let outcome = try CostUsageJsonl.scanResumable(
                fileURL: fileURL,
                offset: startOffset,
                endOffset: endOffset,
                maxLineBytes: 512 * 1024,
                prefixBytes: 512 * 1024,
                checkCancellation: checkCancellation,
                shouldStop: shouldStop,
                discardingTruncatedLine: discardingTruncatedLine,
                withinRoot: root,
                onLine: { line in
                    guard !line.bytes.isEmpty, !line.wasTruncated else { return }
                    if let fastLine = Self.parseCodexFastLine(line.bytes) {
                        switch fastLine {
                        case let .sessionMeta(metadata):
                            if sessionId == nil {
                                sessionId = metadata.sessionId
                            }
                        case let .tokenCount(record):
                            appendSnapshot(timestamp: record.timestamp, last: record.last, total: record.total)
                        case .turnContext, .taskStarted:
                            break
                        }
                        return
                    }

                    autoreleasepool {
                        guard let obj = (try? JSONSerialization.jsonObject(with: line.bytes)) as? [String: Any]
                        else { return }

                        if obj["type"] as? String == "session_meta" {
                            let payload = obj["payload"] as? [String: Any]
                            if sessionId == nil {
                                sessionId = payload?["session_id"] as? String
                                    ?? payload?["sessionId"] as? String
                                    ?? payload?["id"] as? String
                                    ?? obj["session_id"] as? String
                                    ?? obj["sessionId"] as? String
                                    ?? obj["id"] as? String
                            }
                            return
                        }

                        guard obj["type"] as? String == "event_msg" else { return }
                        guard let payload = obj["payload"] as? [String: Any] else { return }
                        guard payload["type"] as? String == "token_count" else { return }
                        guard let info = payload["info"] as? [String: Any] else { return }
                        guard let timestamp = obj["timestamp"] as? String else { return }

                        func toInt(_ value: Any?) -> Int {
                            if let number = value as? NSNumber { return number.intValue }
                            return 0
                        }

                        let total = (info["total_token_usage"] as? [String: Any]).map {
                            CostUsageCodexTotals(
                                input: toInt($0["input_tokens"]),
                                cached: toInt($0["cached_input_tokens"] ?? $0["cache_read_input_tokens"]),
                                output: toInt($0["output_tokens"]))
                        }
                        let last = (info["last_token_usage"] as? [String: Any]).map {
                            CostUsageCodexTotals(
                                input: max(0, toInt($0["input_tokens"])),
                                cached: max(0, toInt($0["cached_input_tokens"] ?? $0["cache_read_input_tokens"])),
                                output: max(0, toInt($0["output_tokens"])))
                        }
                        appendSnapshot(timestamp: timestamp, last: last, total: total)
                    }
                })
            parsedBytes = outcome.parsedBytes
            discardingTruncatedLine = outcome.discardingTruncatedLine
            if outcome.stoppedEarly {
                return (
                    sessionId, cutoffTotals, outcome.parsedBytes, previousTotals,
                    rawTotalsBaseline, sawDivergentTotals,
                    outcome.discardingTruncatedLine, false)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            self.log.warning(
                "Codex cost usage failed while scanning parent token snapshots",
                metadata: ["path": fileURL.path, "error": error.localizedDescription])
            // The scanner does not expose a durable offset on an I/O failure.
            // Roll back accumulator state to the last journaled offset so a
            // subsequent pass cannot append the same parent totals twice.
            return (
                initialSessionId, initialCutoffTotals, startOffset, initialPreviousTotals,
                initialRawTotalsBaseline, initialHasDivergentTotals,
                initialDiscardingTruncatedLine, false)
        }

        return (
            sessionId, cutoffTotals, parsedBytes,
            previousTotals, rawTotalsBaseline, sawDivergentTotals,
            discardingTruncatedLine, true)
    }

    static func parseCodexFile(
        fileURL: URL,
        range: CostUsageDayRange,
        startOffset: Int64 = 0,
        initialModel: String? = nil,
        initialTotals: CostUsageCodexTotals? = nil,
        initialRawTotalsBaseline: CostUsageCodexTotals? = nil,
        initialHasDivergentTotals: Bool = false,
        initialCodexTurnID: String? = nil,
        inheritedTotalsResolver: ((String, String) -> CodexForkBaseline)? = nil) -> CodexParseResult
    {
        let throwingResolver: ((String, String) throws -> CodexForkBaseline)? = inheritedTotalsResolver
            .map { resolver in
                { sessionId, timestamp in resolver(sessionId, timestamp) }
            }
        return (
            try? Self.parseCodexFileCancellable(
                fileURL: fileURL,
                range: range,
                startOffset: startOffset,
                initialModel: initialModel,
                initialTotals: initialTotals,
                initialRawTotalsBaseline: initialRawTotalsBaseline,
                initialHasDivergentTotals: initialHasDivergentTotals,
                initialCodexTurnID: initialCodexTurnID,
                inheritedTotalsResolver: throwingResolver,
                checkCancellation: nil)) ?? CodexParseResult(
            days: [:],
            parsedBytes: startOffset,
            lastModel: initialModel,
            lastTotals: initialTotals,
            lastCountedTotals: initialTotals,
            lastRawTotalsBaseline: initialRawTotalsBaseline ?? initialTotals,
            hasDivergentTotals: initialHasDivergentTotals,
            lastCodexTurnID: initialCodexTurnID,
            sessionId: nil,
            forkedFromId: nil,
            projectKey: nil,
            projectName: nil,
            projectAttributionAmbiguous: false,
            rows: [],
            scanComplete: true,
            resumeState: CodexParseResumeState(
                currentModel: initialModel,
                lastCountedTotals: initialTotals,
                lastRawTotalsBaseline: initialRawTotalsBaseline ?? initialTotals,
                lastCodexTurnID: initialCodexTurnID,
                sessionId: nil,
                forkedFromId: nil,
                projectKey: nil,
                projectName: nil,
                projectAttributionAmbiguous: false,
                inheritedTotals: nil,
                remainingInheritedTotals: nil,
                forkBaselineResolved: false,
                hasUnresolvedForkBaseline: false,
                usesCompactForkTotals: false,
                compactForkBaselineApplied: false,
                unresolvedForkTotalWatermark: nil,
                hasDivergentTotals: initialHasDivergentTotals))
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func parseCodexFileCancellable(
        fileURL: URL,
        range: CostUsageDayRange,
        startOffset: Int64 = 0,
        initialModel: String? = nil,
        initialTotals: CostUsageCodexTotals? = nil,
        initialRawTotalsBaseline: CostUsageCodexTotals? = nil,
        initialHasDivergentTotals: Bool = false,
        initialCodexTurnID: String? = nil,
        initialResumeState: CodexParseResumeState? = nil,
        inheritedTotalsResolver: ((String, String) throws -> CodexForkBaseline)? = nil,
        checkCancellation: CancellationCheck? = nil,
        shouldStop: (() -> Bool)? = nil,
        endOffset: Int64? = nil,
        withinRoot root: URL? = nil) throws -> CodexParseResult
    {
        let rollbackState = initialResumeState ?? CodexParseResumeState(
            currentModel: initialModel,
            lastCountedTotals: initialTotals,
            lastRawTotalsBaseline: initialRawTotalsBaseline ?? initialTotals,
            lastCodexTurnID: initialCodexTurnID,
            sessionId: nil,
            forkedFromId: nil,
            projectKey: nil,
            projectName: nil,
            projectAttributionAmbiguous: false,
            inheritedTotals: nil,
            remainingInheritedTotals: nil,
            forkBaselineResolved: false,
            hasUnresolvedForkBaseline: false,
            usesCompactForkTotals: false,
            compactForkBaselineApplied: false,
            unresolvedForkTotalWatermark: nil,
            hasDivergentTotals: initialHasDivergentTotals)

        func rollbackResult() -> CodexParseResult {
            let counted = rollbackState.lastCountedTotals
            let raw = rollbackState.lastRawTotalsBaseline
            return CodexParseResult(
                days: [:],
                parsedBytes: startOffset,
                lastModel: rollbackState.currentModel,
                lastTotals: rollbackState.hasDivergentTotals && !Self.codexTotalsEqual(raw, counted)
                    ? nil
                    : counted,
                lastCountedTotals: counted,
                lastRawTotalsBaseline: raw,
                hasDivergentTotals: rollbackState.hasDivergentTotals
                    && !Self.codexTotalsEqual(raw, counted),
                lastCodexTurnID: rollbackState.lastCodexTurnID,
                sessionId: rollbackState.sessionId,
                forkedFromId: rollbackState.forkedFromId,
                projectKey: rollbackState.projectKey,
                projectName: rollbackState.projectName,
                projectAttributionAmbiguous: rollbackState.projectAttributionAmbiguous,
                rows: [],
                scanComplete: false,
                resumeState: rollbackState)
        }

        var currentModel = initialResumeState?.currentModel ?? initialModel
        var previousTotals = initialResumeState?.lastCountedTotals ?? initialTotals
        var sessionId = initialResumeState?.sessionId
        var forkedFromId = initialResumeState?.forkedFromId
        var projectKey = initialResumeState?.projectKey
        var projectName = initialResumeState?.projectName
        var projectAttributionAmbiguous = initialResumeState?.projectAttributionAmbiguous ?? false
        var inheritedTotals = initialResumeState?.inheritedTotals
        var remainingInheritedTotals = initialResumeState?.remainingInheritedTotals
        var forkBaselineResolved = initialResumeState?.forkBaselineResolved ?? false
        var hasUnresolvedForkBaseline = initialResumeState?.hasUnresolvedForkBaseline ?? false
        var usesCompactForkTotals = initialResumeState?.usesCompactForkTotals ?? false
        var compactForkBaselineApplied = initialResumeState?.compactForkBaselineApplied ?? false
        var unresolvedForkTotalWatermark = initialResumeState?.unresolvedForkTotalWatermark
        var forkBaselineStopped = false
        var currentTurnID = initialResumeState?.lastCodexTurnID ?? initialCodexTurnID
        var rawTotalsBaseline = initialResumeState?.lastRawTotalsBaseline
            ?? initialRawTotalsBaseline
            ?? initialTotals
        var sawDivergentTotals = initialResumeState?.hasDivergentTotals ?? initialHasDivergentTotals
        var deferredError: Error?

        var days: [String: [String: [Int]]] = [:]
        var rows: [CodexUsageRow] = []

        func add(dayKey: String, model: String, input: Int, cached: Int, output: Int) {
            guard CostUsageDayRange.isInRange(dayKey: dayKey, since: range.scanSinceKey, until: range.scanUntilKey)
            else { return }
            let normModel = CostUsagePricing.normalizeCodexModel(model)

            var dayModels = days[dayKey] ?? [:]
            var packed = dayModels[normModel] ?? [0, 0, 0]
            packed[0] = (packed[safe: 0] ?? 0) + input
            packed[1] = (packed[safe: 1] ?? 0) + cached
            packed[2] = (packed[safe: 2] ?? 0) + output
            dayModels[normModel] = packed
            days[dayKey] = dayModels
        }

        func resolveForkBaseline(parentSessionId: String, forkedAt: String) throws {
            guard !forkBaselineResolved else { return }
            guard let inheritedTotalsResolver else { return }
            forkBaselineResolved = true
            switch try inheritedTotalsResolver(parentSessionId, forkedAt) {
            case let .resolved(totals):
                inheritedTotals = totals
                remainingInheritedTotals = totals
                hasUnresolvedForkBaseline = false
            case .unresolved:
                hasUnresolvedForkBaseline = true
            case .stopped:
                forkBaselineStopped = true
                forkBaselineResolved = false
            }
        }

        func handleProjectIdentity(key: String?, name: String?) {
            guard !projectAttributionAmbiguous, let key else { return }
            if let current = projectKey, current != key {
                projectKey = nil
                projectName = nil
                projectAttributionAmbiguous = true
            } else if projectKey == nil {
                projectKey = key
                projectName = name
            }
        }

        func invalidateProjectIdentity() {
            projectKey = nil
            projectName = nil
            projectAttributionAmbiguous = true
        }

        func handleSessionMetadata(_ metadata: CodexSessionMetadata) throws {
            if sessionId == nil {
                sessionId = metadata.sessionId
            }
            if forkedFromId == nil {
                forkedFromId = metadata.forkedFromId
            }
            usesCompactForkTotals = usesCompactForkTotals
                || Self.codexUsesCompactForkTotals(cliVersion: metadata.cliVersion)
            if metadata.projectAttributionAmbiguous {
                invalidateProjectIdentity()
            } else {
                handleProjectIdentity(key: metadata.projectKey, name: metadata.projectName)
            }
            if let forkedFromId {
                try resolveForkBaseline(parentSessionId: forkedFromId, forkedAt: metadata.forkTimestamp ?? "")
            }
        }

        func applyCompactForkBaseline(total: CostUsageCodexTotals, last: CostUsageCodexTotals?) {
            guard usesCompactForkTotals,
                  !compactForkBaselineApplied,
                  let inherited = inheritedTotals,
                  let last
            else { return }
            compactForkBaselineApplied = true
            let preTurnTotals = CostUsageCodexTotals(
                input: max(0, total.input - last.input),
                cached: max(0, total.cached - last.cached),
                output: max(0, total.output - last.output))
            inheritedTotals = Self.codexMinTotals(inherited, preTurnTotals)
            remainingInheritedTotals = remainingInheritedTotals.map {
                Self.codexMinTotals($0, preTurnTotals)
            }
        }

        // swiftlint:disable:next function_body_length
        func handleTokenCount(_ record: CodexTokenCountRecord) throws {
            guard let dayKey = Self.dayKeyFromTimestamp(record.timestamp) ?? Self.dayKeyFromParsedISO(record.timestamp)
            else { return }

            let model = currentModel ?? record.model ?? "gpt-5"
            let total = record.total
            let last = record.last

            var deltaInput = 0
            var deltaCached = 0
            var deltaOutput = 0

            func adjustedLastDelta(_ rawDelta: CostUsageCodexTotals) -> CostUsageCodexTotals {
                guard var remaining = remainingInheritedTotals else { return rawDelta }

                let adjusted = CostUsageCodexTotals(
                    input: max(0, rawDelta.input - remaining.input),
                    cached: max(0, rawDelta.cached - remaining.cached),
                    output: max(0, rawDelta.output - remaining.output))

                remaining.input = max(0, remaining.input - rawDelta.input)
                remaining.cached = max(0, remaining.cached - rawDelta.cached)
                remaining.output = max(0, remaining.output - rawDelta.output)
                remainingInheritedTotals = if remaining.input == 0, remaining.cached == 0,
                                              remaining.output == 0
                {
                    nil
                } else {
                    remaining
                }

                return adjusted
            }

            if let total {
                applyCompactForkBaseline(total: total, last: last)
            }

            let handledUnresolvedForkTotal = hasUnresolvedForkBaseline && total != nil
            if hasUnresolvedForkBaseline, let total {
                let currentRawTotals = total
                defer {
                    unresolvedForkTotalWatermark = currentRawTotals
                }
                guard let last,
                      let watermark = unresolvedForkTotalWatermark
                else {
                    return
                }

                let rawLastDelta = last
                let rawTotalDelta = Self.codexTotalDelta(from: watermark, to: currentRawTotals)
                let adjustedDelta = Self.codexMinTotals(rawLastDelta, rawTotalDelta)
                deltaInput = adjustedDelta.input
                deltaCached = adjustedDelta.cached
                deltaOutput = adjustedDelta.output
                let prev = previousTotals ?? .init(input: 0, cached: 0, output: 0)
                previousTotals = Self.codexAddTotals(prev, adjustedDelta)
                rawTotalsBaseline = previousTotals
            }

            if !handledUnresolvedForkTotal,
               let total,
               forkedFromId != nil,
               !hasUnresolvedForkBaseline
            {
                let rawTotals = total
                let currentTotals: CostUsageCodexTotals = if let inheritedTotals {
                    CostUsageCodexTotals(
                        input: max(0, rawTotals.input - inheritedTotals.input),
                        cached: max(0, rawTotals.cached - inheritedTotals.cached),
                        output: max(0, rawTotals.output - inheritedTotals.output))
                } else {
                    rawTotals
                }
                let delta = sawDivergentTotals
                    ? Self.codexDivergentTotalDelta(
                        rawBaseline: rawTotalsBaseline,
                        countedBaseline: previousTotals,
                        current: currentTotals)
                    : Self.codexTotalDelta(from: rawTotalsBaseline, to: currentTotals)
                deltaInput = delta.input
                deltaCached = delta.cached
                deltaOutput = delta.output
                let prev = previousTotals ?? .init(input: 0, cached: 0, output: 0)
                previousTotals = Self.codexAddTotals(prev, delta)
                rawTotalsBaseline = currentTotals
                if !Self.codexTotalsEqual(rawTotalsBaseline, previousTotals) {
                    sawDivergentTotals = true
                }
                remainingInheritedTotals = nil
            } else if !handledUnresolvedForkTotal, let last {
                let rawDelta = last
                let hadRemainingInheritedTotals = remainingInheritedTotals != nil
                var adjustedDelta = adjustedLastDelta(rawDelta)
                deltaInput = adjustedDelta.input
                deltaCached = adjustedDelta.cached
                deltaOutput = adjustedDelta.output
                let prev = previousTotals ?? .init(input: 0, cached: 0, output: 0)

                if let total, !hasUnresolvedForkBaseline {
                    let rawTotals = total
                    let currentTotals: CostUsageCodexTotals = if let inheritedTotals {
                        CostUsageCodexTotals(
                            input: max(0, rawTotals.input - inheritedTotals.input),
                            cached: max(0, rawTotals.cached - inheritedTotals.cached),
                            output: max(0, rawTotals.output - inheritedTotals.output))
                    } else {
                        rawTotals
                    }
                    let totalDelta = Self.codexTotalDelta(from: rawTotalsBaseline, to: currentTotals)
                    if !hadRemainingInheritedTotals,
                       Self.codexShouldPreferTotalDelta(
                           rawBaseline: rawTotalsBaseline,
                           currentTotal: currentTotals,
                           totalDelta: totalDelta,
                           lastDelta: rawDelta,
                           sawDivergentTotals: sawDivergentTotals)
                    {
                        adjustedDelta = totalDelta
                        deltaInput = adjustedDelta.input
                        deltaCached = adjustedDelta.cached
                        deltaOutput = adjustedDelta.output
                        remainingInheritedTotals = nil
                    }
                    let countedTotals = Self.codexAddTotals(prev, adjustedDelta)
                    previousTotals = countedTotals
                    rawTotalsBaseline = currentTotals
                    if !Self.codexTotalsEqual(currentTotals, countedTotals) {
                        sawDivergentTotals = true
                    }
                } else {
                    let countedTotals = Self.codexAddTotals(prev, adjustedDelta)
                    previousTotals = countedTotals
                    rawTotalsBaseline = countedTotals
                }
            } else if !handledUnresolvedForkTotal, let total {
                let rawTotals = total

                let currentTotals: CostUsageCodexTotals = if let inheritedTotals {
                    CostUsageCodexTotals(
                        input: max(0, rawTotals.input - inheritedTotals.input),
                        cached: max(0, rawTotals.cached - inheritedTotals.cached),
                        output: max(0, rawTotals.output - inheritedTotals.output))
                } else {
                    rawTotals
                }

                let delta = sawDivergentTotals
                    ? Self.codexDivergentTotalDelta(
                        rawBaseline: rawTotalsBaseline,
                        countedBaseline: previousTotals,
                        current: currentTotals)
                    : Self.codexTotalDelta(from: rawTotalsBaseline, to: currentTotals)
                deltaInput = delta.input
                deltaCached = delta.cached
                deltaOutput = delta.output
                let prev = previousTotals ?? .init(input: 0, cached: 0, output: 0)
                previousTotals = Self.codexAddTotals(prev, delta)
                rawTotalsBaseline = currentTotals
                if !Self.codexTotalsEqual(rawTotalsBaseline, previousTotals) {
                    sawDivergentTotals = true
                }
                remainingInheritedTotals = nil
            } else if !handledUnresolvedForkTotal {
                return
            }

            if deltaInput == 0, deltaCached == 0, deltaOutput == 0 { return }
            let cachedClamp = min(deltaCached, deltaInput)
            let normModel = CostUsagePricing.normalizeCodexModel(model)
            add(
                dayKey: dayKey,
                model: normModel,
                input: deltaInput,
                cached: cachedClamp,
                output: deltaOutput)
            if CostUsageDayRange.isInRange(
                dayKey: dayKey,
                since: range.scanSinceKey,
                until: range.scanUntilKey)
            {
                rows.append(CodexUsageRow(
                    day: dayKey,
                    model: normModel,
                    turnID: record.turnID ?? currentTurnID,
                    input: deltaInput,
                    cached: cachedClamp,
                    output: deltaOutput))
            }
        }

        func handleFastLine(_ fastLine: CodexFastLine) throws {
            switch fastLine {
            case let .sessionMeta(metadata):
                try handleSessionMetadata(metadata)
            case let .turnContext(model):
                if let model {
                    currentModel = model
                }
            case let .taskStarted(turnID):
                currentTurnID = turnID
            case let .tokenCount(record):
                try handleTokenCount(record)
            }
        }

        let maxLineBytes = 256 * 1024
        let prefixBytes = maxLineBytes

        if startOffset == 0,
           let metadata = try Self.parseCodexSessionMetadata(
               fileURL: fileURL,
               checkCancellation: checkCancellation,
               shouldStop: shouldStop,
               maximumBytes: Int(min(Int64(512 * 1024), max(0, endOffset ?? Int64(512 * 1024)))),
               withinRoot: root)
        {
            sessionId = metadata.sessionId
            forkedFromId = metadata.forkedFromId
            usesCompactForkTotals = Self.codexUsesCompactForkTotals(cliVersion: metadata.cliVersion)
            if metadata.projectAttributionAmbiguous {
                invalidateProjectIdentity()
            } else {
                handleProjectIdentity(key: metadata.projectKey, name: metadata.projectName)
            }
            if let forkedFromId = metadata.forkedFromId,
               inheritedTotals == nil
            {
                let forkedAt = metadata.forkTimestamp ?? ""
                try resolveForkBaseline(parentSessionId: forkedFromId, forkedAt: forkedAt)
            }
        }

        var parsedBytes: Int64
        var scanComplete = true
        var discardingTruncatedLine = initialResumeState?.discardingTruncatedLine == true
        do {
            let scanOutcome = try CostUsageJsonl.scanResumable(
                fileURL: fileURL,
                offset: startOffset,
                endOffset: endOffset,
                maxLineBytes: maxLineBytes,
                prefixBytes: prefixBytes,
                checkCancellation: checkCancellation,
                shouldStop: shouldStop,
                discardingTruncatedLine: discardingTruncatedLine,
                withinRoot: root,
                onLine: { line in
                    if deferredError != nil || forkBaselineStopped { return }
                    guard !line.bytes.isEmpty else { return }
                    if line.wasTruncated {
                        // `turn_context` can carry very large prompts, but its model usually appears near the start.
                        if let model = Self.extractCodexTurnContextModel(from: line.bytes) {
                            currentModel = model
                        }
                        return
                    }

                    guard
                        line.bytes.containsAscii(#""type":"event_msg""#)
                        || line.bytes.containsAscii(#""type":"turn_context""#)
                        || line.bytes.containsAscii(#""type":"session_meta""#)
                    else { return }

                    if line.bytes.containsAscii(#""type":"event_msg""#),
                       !line.bytes.containsAscii(#""token_count""#),
                       !line.bytes.containsAscii(#""task_started""#)
                    {
                        return
                    }

                    if let fastLine = Self.parseCodexFastLine(line.bytes) {
                        do {
                            try handleFastLine(fastLine)
                        } catch {
                            deferredError = error
                        }
                        return
                    }

                    autoreleasepool {
                        guard
                            let obj = (try? JSONSerialization.jsonObject(with: line.bytes)) as? [String: Any],
                            let type = obj["type"] as? String
                        else { return }

                        if type == "session_meta" {
                            let payload = obj["payload"] as? [String: Any]
                            if sessionId == nil {
                                sessionId = payload?["session_id"] as? String
                                    ?? payload?["sessionId"] as? String
                                    ?? payload?["id"] as? String
                                    ?? obj["session_id"] as? String
                                    ?? obj["sessionId"] as? String
                                    ?? obj["id"] as? String
                            }
                            if forkedFromId == nil {
                                forkedFromId = Self.codexForkParentId(from: payload)
                            }
                            let project = Self.codexProjectIdentity(cwd: payload?["cwd"] as? String)
                            if let project {
                                handleProjectIdentity(key: project.key, name: project.name)
                            } else if payload?.keys.contains("cwd") == true {
                                invalidateProjectIdentity()
                            }
                            if let forkedFromId {
                                let forkedAt = payload?["timestamp"] as? String
                                    ?? obj["timestamp"] as? String
                                    ?? ""
                                do {
                                    try resolveForkBaseline(parentSessionId: forkedFromId, forkedAt: forkedAt)
                                } catch {
                                    deferredError = error
                                    return
                                }
                            }
                            return
                        }

                        guard let tsText = obj["timestamp"] as? String else { return }
                        guard let dayKey = Self.dayKeyFromTimestamp(tsText) ?? Self.dayKeyFromParsedISO(tsText)
                        else { return }

                        if type == "turn_context" {
                            if let payload = obj["payload"] as? [String: Any] {
                                if let model = payload["model"] as? String {
                                    currentModel = model
                                } else if let info = payload["info"] as? [String: Any],
                                          let model = info["model"] as? String
                                {
                                    currentModel = model
                                }
                            }
                            return
                        }

                        guard type == "event_msg" else { return }
                        guard let payload = obj["payload"] as? [String: Any] else { return }
                        if (payload["type"] as? String) == "task_started" {
                            currentTurnID = Self.codexTurnID(from: payload)
                            return
                        }
                        guard (payload["type"] as? String) == "token_count" else { return }

                        let info = payload["info"] as? [String: Any]
                        let modelFromInfo = info?["model"] as? String
                            ?? info?["model_name"] as? String
                            ?? payload["model"] as? String
                            ?? obj["model"] as? String
                        let model = currentModel ?? modelFromInfo ?? "gpt-5"

                        func toInt(_ v: Any?) -> Int {
                            if let n = v as? NSNumber { return n.intValue }
                            return 0
                        }

                        func tokenTotals(_ usage: [String: Any]) -> CostUsageCodexTotals {
                            CostUsageCodexTotals(
                                input: max(0, toInt(usage["input_tokens"])),
                                cached: max(0, toInt(usage["cached_input_tokens"] ?? usage["cache_read_input_tokens"])),
                                output: max(0, toInt(usage["output_tokens"])))
                        }

                        let total = (info?["total_token_usage"] as? [String: Any])
                        let last = (info?["last_token_usage"] as? [String: Any])

                        var deltaInput = 0
                        var deltaCached = 0
                        var deltaOutput = 0

                        func adjustedLastDelta(_ rawDelta: CostUsageCodexTotals) -> CostUsageCodexTotals {
                            guard var remaining = remainingInheritedTotals else { return rawDelta }

                            let adjusted = CostUsageCodexTotals(
                                input: max(0, rawDelta.input - remaining.input),
                                cached: max(0, rawDelta.cached - remaining.cached),
                                output: max(0, rawDelta.output - remaining.output))

                            remaining.input = max(0, remaining.input - rawDelta.input)
                            remaining.cached = max(0, remaining.cached - rawDelta.cached)
                            remaining.output = max(0, remaining.output - rawDelta.output)
                            remainingInheritedTotals = if remaining.input == 0, remaining.cached == 0,
                                                          remaining.output == 0
                            {
                                nil
                            } else {
                                remaining
                            }

                            return adjusted
                        }

                        if let total {
                            applyCompactForkBaseline(
                                total: tokenTotals(total),
                                last: last.map(tokenTotals))
                        }

                        let handledUnresolvedForkTotal = hasUnresolvedForkBaseline && total != nil
                        if hasUnresolvedForkBaseline, let total {
                            let currentRawTotals = tokenTotals(total)
                            defer {
                                unresolvedForkTotalWatermark = currentRawTotals
                            }
                            guard let last,
                                  let watermark = unresolvedForkTotalWatermark
                            else {
                                return
                            }

                            let rawLastDelta = tokenTotals(last)
                            let rawTotalDelta = Self.codexTotalDelta(from: watermark, to: currentRawTotals)
                            let adjustedDelta = Self.codexMinTotals(rawLastDelta, rawTotalDelta)
                            deltaInput = adjustedDelta.input
                            deltaCached = adjustedDelta.cached
                            deltaOutput = adjustedDelta.output
                            let prev = previousTotals ?? .init(input: 0, cached: 0, output: 0)
                            previousTotals = Self.codexAddTotals(prev, adjustedDelta)
                            rawTotalsBaseline = previousTotals
                        }

                        if !handledUnresolvedForkTotal,
                           let total,
                           forkedFromId != nil,
                           !hasUnresolvedForkBaseline
                        {
                            let rawTotals = tokenTotals(total)
                            let currentTotals: CostUsageCodexTotals = if let inheritedTotals {
                                CostUsageCodexTotals(
                                    input: max(0, rawTotals.input - inheritedTotals.input),
                                    cached: max(0, rawTotals.cached - inheritedTotals.cached),
                                    output: max(0, rawTotals.output - inheritedTotals.output))
                            } else {
                                rawTotals
                            }
                            let delta = sawDivergentTotals
                                ? Self.codexDivergentTotalDelta(
                                    rawBaseline: rawTotalsBaseline,
                                    countedBaseline: previousTotals,
                                    current: currentTotals)
                                : Self.codexTotalDelta(from: rawTotalsBaseline, to: currentTotals)
                            deltaInput = delta.input
                            deltaCached = delta.cached
                            deltaOutput = delta.output
                            let prev = previousTotals ?? .init(input: 0, cached: 0, output: 0)
                            previousTotals = Self.codexAddTotals(prev, delta)
                            rawTotalsBaseline = currentTotals
                            if !Self.codexTotalsEqual(rawTotalsBaseline, previousTotals) {
                                sawDivergentTotals = true
                            }
                            remainingInheritedTotals = nil
                        } else if !handledUnresolvedForkTotal, let last {
                            let rawDelta = CostUsageCodexTotals(
                                input: max(0, toInt(last["input_tokens"])),
                                cached: max(0, toInt(last["cached_input_tokens"] ?? last["cache_read_input_tokens"])),
                                output: max(0, toInt(last["output_tokens"])))
                            let hadRemainingInheritedTotals = remainingInheritedTotals != nil
                            var adjustedDelta = adjustedLastDelta(rawDelta)
                            deltaInput = adjustedDelta.input
                            deltaCached = adjustedDelta.cached
                            deltaOutput = adjustedDelta.output
                            let prev = previousTotals ?? .init(input: 0, cached: 0, output: 0)

                            if let total, !hasUnresolvedForkBaseline {
                                let rawTotals = tokenTotals(total)
                                let currentTotals: CostUsageCodexTotals = if let inheritedTotals {
                                    CostUsageCodexTotals(
                                        input: max(0, rawTotals.input - inheritedTotals.input),
                                        cached: max(0, rawTotals.cached - inheritedTotals.cached),
                                        output: max(0, rawTotals.output - inheritedTotals.output))
                                } else {
                                    rawTotals
                                }
                                let totalDelta = Self.codexTotalDelta(from: rawTotalsBaseline, to: currentTotals)
                                if !hadRemainingInheritedTotals,
                                   Self.codexShouldPreferTotalDelta(
                                       rawBaseline: rawTotalsBaseline,
                                       currentTotal: currentTotals,
                                       totalDelta: totalDelta,
                                       lastDelta: rawDelta,
                                       sawDivergentTotals: sawDivergentTotals)
                                {
                                    adjustedDelta = totalDelta
                                    deltaInput = adjustedDelta.input
                                    deltaCached = adjustedDelta.cached
                                    deltaOutput = adjustedDelta.output
                                    remainingInheritedTotals = nil
                                }
                                let countedTotals = Self.codexAddTotals(prev, adjustedDelta)
                                previousTotals = countedTotals
                                rawTotalsBaseline = currentTotals
                                if !Self.codexTotalsEqual(currentTotals, countedTotals) {
                                    sawDivergentTotals = true
                                }
                            } else {
                                let countedTotals = Self.codexAddTotals(prev, adjustedDelta)
                                previousTotals = countedTotals
                                rawTotalsBaseline = countedTotals
                            }
                        } else if !handledUnresolvedForkTotal, let total {
                            let rawTotals = tokenTotals(total)

                            let currentTotals: CostUsageCodexTotals = if let inheritedTotals {
                                CostUsageCodexTotals(
                                    input: max(0, rawTotals.input - inheritedTotals.input),
                                    cached: max(0, rawTotals.cached - inheritedTotals.cached),
                                    output: max(0, rawTotals.output - inheritedTotals.output))
                            } else {
                                rawTotals
                            }

                            let delta = sawDivergentTotals
                                ? Self.codexDivergentTotalDelta(
                                    rawBaseline: rawTotalsBaseline,
                                    countedBaseline: previousTotals,
                                    current: currentTotals)
                                : Self.codexTotalDelta(from: rawTotalsBaseline, to: currentTotals)
                            deltaInput = delta.input
                            deltaCached = delta.cached
                            deltaOutput = delta.output
                            let prev = previousTotals ?? .init(input: 0, cached: 0, output: 0)
                            previousTotals = Self.codexAddTotals(prev, delta)
                            rawTotalsBaseline = currentTotals
                            if !Self.codexTotalsEqual(rawTotalsBaseline, previousTotals) {
                                sawDivergentTotals = true
                            }
                            remainingInheritedTotals = nil
                        } else if !handledUnresolvedForkTotal {
                            return
                        }

                        if deltaInput == 0, deltaCached == 0, deltaOutput == 0 { return }
                        let cachedClamp = min(deltaCached, deltaInput)
                        let normModel = CostUsagePricing.normalizeCodexModel(model)
                        add(
                            dayKey: dayKey,
                            model: normModel,
                            input: deltaInput,
                            cached: cachedClamp,
                            output: deltaOutput)
                        if CostUsageDayRange.isInRange(
                            dayKey: dayKey,
                            since: range.scanSinceKey,
                            until: range.scanUntilKey)
                        {
                            rows.append(CodexUsageRow(
                                day: dayKey,
                                model: normModel,
                                turnID: Self.codexTurnID(from: payload) ?? currentTurnID,
                                input: deltaInput,
                                cached: cachedClamp,
                                output: deltaOutput))
                        }
                    }
                })
            parsedBytes = scanOutcome.parsedBytes
            discardingTruncatedLine = scanOutcome.discardingTruncatedLine
            scanComplete = !scanOutcome.stoppedEarly
                && !scanOutcome.discardingTruncatedLine
                && !forkBaselineStopped
            if forkBaselineStopped {
                // Parent lookup/baseline is still pending. Keep the child at
                // its safe checkpoint until that dependency resolves.
                parsedBytes = startOffset
            }
            if let deferredError {
                throw deferredError
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            self.log.warning(
                "Codex cost usage failed while scanning session file",
                metadata: ["path": fileURL.path, "error": error.localizedDescription])
            return rollbackResult()
        }

        return CodexParseResult(
            days: days,
            parsedBytes: parsedBytes,
            lastModel: currentModel,
            lastTotals: sawDivergentTotals && !Self.codexTotalsEqual(rawTotalsBaseline, previousTotals)
                ? nil
                : previousTotals,
            lastCountedTotals: previousTotals,
            lastRawTotalsBaseline: rawTotalsBaseline,
            hasDivergentTotals: sawDivergentTotals && !Self.codexTotalsEqual(rawTotalsBaseline, previousTotals),
            lastCodexTurnID: currentTurnID,
            sessionId: sessionId,
            forkedFromId: forkedFromId,
            projectKey: projectKey,
            projectName: projectName,
            projectAttributionAmbiguous: projectAttributionAmbiguous,
            rows: rows,
            scanComplete: scanComplete,
            resumeState: CodexParseResumeState(
                currentModel: currentModel,
                lastCountedTotals: previousTotals,
                lastRawTotalsBaseline: rawTotalsBaseline,
                lastCodexTurnID: currentTurnID,
                sessionId: sessionId,
                forkedFromId: forkedFromId,
                projectKey: projectKey,
                projectName: projectName,
                projectAttributionAmbiguous: projectAttributionAmbiguous,
                inheritedTotals: inheritedTotals,
                remainingInheritedTotals: remainingInheritedTotals,
                forkBaselineResolved: forkBaselineResolved,
                hasUnresolvedForkBaseline: hasUnresolvedForkBaseline,
                usesCompactForkTotals: usesCompactForkTotals,
                compactForkBaselineApplied: compactForkBaselineApplied,
                unresolvedForkTotalWatermark: unresolvedForkTotalWatermark,
                hasDivergentTotals: sawDivergentTotals,
                discardingTruncatedLine: discardingTruncatedLine))
    }

    private static func codexTurnID(from payload: [String: Any]) -> String? {
        if let turnID = payload["turn_id"] as? String ?? payload["turnId"] as? String ?? payload["id"] as? String {
            return turnID
        }
        if let info = payload["info"] as? [String: Any] {
            return info["turn_id"] as? String ?? info["turnId"] as? String ?? info["id"] as? String
        }
        return nil
    }

    private enum CodexFileScanOutcome {
        case complete
        case incomplete
        case unavailable
    }

    private static func scanCodexFile(
        fileURL: URL,
        target: CodexFrozenFile,
        context: CodexFileScanContext,
        cache: inout CostUsageCache,
        state: inout CodexScanState) throws -> CodexFileScanOutcome
    {
        try context.checkCancellation?()
        let root = Self.codexContainingRoot(fileURL: fileURL, roots: context.roots)
        guard context.roots.isEmpty || root != nil else { return .unavailable }
        let metadata = Self.codexFileMetadata(fileURL: fileURL, withinRoot: root)
        // The captured bytes are no longer available (replace/truncate/rewrite).
        // Keep last-good state; the post-pass manifest comparison will seed a
        // fresh catch-up generation instead of pinning this generation forever.
        guard Self.codexFrozenFileIsReadable(
            target,
            current: metadata,
            fileURL: fileURL,
            withinRoot: root)
        else { return .unavailable }
        if let fileId = metadata.fileId, state.seenFileIds.contains(fileId) {
            Self.dropCachedCodexFile(path: metadata.path, cached: cache.files[metadata.path], cache: &cache)
            return .complete
        }

        let cached = cache.files[metadata.path]
        if let cachedSessionId = cached?.sessionId, state.seenSessionIds.contains(cachedSessionId) {
            Self.reconcileDuplicateCodexProject(
                sessionId: cachedSessionId,
                projectKey: cached?.projectKey,
                projectName: cached?.projectName,
                projectAttributionAmbiguous: cached?.projectAttributionAmbiguous == true,
                cache: &cache,
                state: &state)
            Self.dropCachedCodexFile(path: metadata.path, cached: cached, cache: &cache)
            return .complete
        }

        let input = CodexFileScanInput(
            fileURL: fileURL,
            metadata: metadata,
            target: target,
            cached: cached)
        if Self.keepCachedCodexFileIfFresh(input: input, context: context, cache: &cache, state: &state) {
            return .complete
        }
        if try Self.appendCodexFileIncrementIfPossible(input: input, context: context, cache: &cache, state: &state) {
            return cache.files[metadata.path]?.codexScanComplete == false ? .incomplete : .complete
        }
        try Self.rescanCodexFile(input: input, context: context, cache: &cache, state: &state)
        return cache.files[metadata.path]?.codexScanComplete == false ? .incomplete : .complete
    }

    private static func makeCodexRefreshPlan(
        cache: CostUsageCache,
        range: CostUsageDayRange,
        now: Date,
        nowMs: Int64,
        options: Options) -> CodexRefreshPlan
    {
        let refreshMs = Int64(max(0, options.refreshMinIntervalSeconds) * 1000)
        let roots = self.codexSessionsRoots(options: options)
        let rootsFingerprint = Self.codexRootsFingerprint(roots)
        let rootsChanged = cache.roots != rootsFingerprint
        let windowExpanded = Self.requestedWindowExpandsCache(range: range, cache: cache)
        let needsCostCacheMigration = cache.files.values.contains { Self.needsCodexCostCache($0, range: range) }
        let modelsDevLoad = ModelsDevCache.load(now: now, cacheRoot: options.cacheRoot)
        let modelsDevCatalog = modelsDevLoad.artifact?.catalog
        let codexPricingKey = Self.codexPricingKey(modelsDevArtifact: modelsDevLoad.artifact)
        let codexPriorityMetadataKey = Self.codexPriorityMetadataKey(databaseURL: options.codexTraceDatabaseURL)
        let hasPriorityMetadata = codexPriorityMetadataKey.hasPrefix("sqlite:")
        let pricingChanged = cache.codexPricingKey != nil && cache.codexPricingKey != codexPricingKey
        let priorityMetadataChanged = Self.codexPriorityMetadataChanged(
            old: cache.codexPriorityMetadataKey,
            new: codexPriorityMetadataKey)
        let needsTurnIDCacheMigration = hasPriorityMetadata && cache.files.values.contains {
            $0.codexTurnIDs == nil && $0.touchesCodexScanWindow(
                sinceKey: range.scanSinceKey,
                untilKey: range.scanUntilKey)
        }
        let shouldInspectPriorityTurns = options.forceRescan
            || cache.codexPendingScanGeneration != nil
            || windowExpanded
            || rootsChanged
            || needsCostCacheMigration
            || needsTurnIDCacheMigration
            || pricingChanged
            || priorityMetadataChanged
            || refreshMs == 0
            || cache.lastScanUnixMs == 0
            || nowMs - cache.lastScanUnixMs > refreshMs
        let priorityTurns = shouldInspectPriorityTurns ? Self.codexPriorityTurns(
            databaseURL: options.codexTraceDatabaseURL,
            sinceDayKey: range.scanSinceKey,
            untilDayKey: range.scanUntilKey) : [:]
        let priorityTurnKeys = Self.codexPriorityTurnKeys(priorityTurns)
        let priorityTurnIDsByDay = Self.codexPriorityTurnIDsByDay(priorityTurns)
        let priorityTurnsChanged = shouldInspectPriorityTurns
            && hasPriorityMetadata
            && Self.codexPriorityTurnKeysChanged(
                old: cache.codexPriorityTurnKeys,
                new: priorityTurnKeys,
                range: range)
        let changedPriorityTurnIDs = shouldInspectPriorityTurns && hasPriorityMetadata
            ? Self.changedPriorityTurnIDs(
                old: cache.codexPriorityTurnIDsByDay,
                new: priorityTurnIDsByDay,
                oldKeys: cache.codexPriorityTurnKeys,
                newKeys: priorityTurnKeys,
                range: range)
            : []
        let shouldRefresh = options.forceRescan
            || cache.codexPendingScanGeneration != nil
            || windowExpanded
            || rootsChanged
            || needsCostCacheMigration
            || needsTurnIDCacheMigration
            || pricingChanged
            || priorityMetadataChanged
            || priorityTurnsChanged
            || refreshMs == 0
            || cache.lastScanUnixMs == 0
            || nowMs - cache.lastScanUnixMs > refreshMs

        return CodexRefreshPlan(
            refreshMs: refreshMs,
            roots: roots,
            rootsFingerprint: rootsFingerprint,
            rootsChanged: rootsChanged,
            windowExpanded: windowExpanded,
            needsCostCacheMigration: needsCostCacheMigration,
            modelsDevCatalog: modelsDevCatalog,
            codexPricingKey: codexPricingKey,
            codexPriorityMetadataKey: codexPriorityMetadataKey,
            hasPriorityMetadata: hasPriorityMetadata,
            priorityTurns: priorityTurns,
            priorityTurnKeys: priorityTurnKeys,
            priorityTurnIDsByDay: priorityTurnIDsByDay,
            pricingChanged: pricingChanged,
            priorityMetadataChanged: priorityMetadataChanged,
            priorityTurnsChanged: priorityTurnsChanged,
            needsTurnIDCacheMigration: needsTurnIDCacheMigration,
            changedPriorityTurnIDs: changedPriorityTurnIDs,
            shouldRefresh: shouldRefresh)
    }

    private static func loadCodexDaily(
        range: CostUsageDayRange,
        now: Date,
        options: Options,
        checkCancellation: CancellationCheck?) throws -> CostUsageDailyReport
    {
        var committedCache = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: options.cacheRoot,
            calendar: Calendar.current)
        var cache = committedCache
        // Đặt true khi vòng lặp file dừng sớm vì hết ngân sách thời gian → còn
        // file chưa quét; caller sẽ lên lịch quét tiếp ngay.
        var scanTruncated = false
        var committedGenerationCompleted = false
        var committedGenerationPersisted = false
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let requestedPlan = Self.makeCodexRefreshPlan(
            cache: committedCache,
            range: range,
            now: now,
            nowMs: nowMs,
            options: options)

        func semanticGeneration(for plan: CodexRefreshPlan) -> String {
            let rootsGeneration = plan.rootsFingerprint.keys.sorted().map {
                "\($0)=\(plan.rootsFingerprint[$0] ?? 0)"
            }.joined(separator: ",")
            return [
                plan.codexPricingKey,
                plan.codexPriorityMetadataKey,
                rootsGeneration,
            ].joined(separator: "|")
        }

        func canUseWarmDeltaManifest(
            plan: CodexRefreshPlan,
            cache: CostUsageCache) -> Bool
        {
            !options.forceRescan
                && !cache.files.isEmpty
                && cache.lastScanUnixMs > 0
                && cache.scanSinceKey != nil
                && cache.scanUntilKey != nil
                && !plan.rootsChanged
                && !plan.windowExpanded
                && !plan.needsCostCacheMigration
                && !plan.needsTurnIDCacheMigration
                && !plan.pricingChanged
                && !plan.priorityMetadataChanged
                && !plan.priorityTurnsChanged
        }

        func frozenManifest(
            files: [URL],
            plan: CodexRefreshPlan,
            cache: CostUsageCache) -> [String: CodexFrozenFile]
        {
            var manifest: [String: CodexFrozenFile] = [:]
            for candidate in files {
                let fileURL = candidate.standardizedFileURL
                guard let root = Self.codexContainingRoot(fileURL: fileURL, roots: plan.roots)
                else { continue }
                let metadata = Self.codexFileMetadata(fileURL: fileURL, withinRoot: root)
                let cached = cache.files[fileURL.path]
                let cachedFingerprint = cached?.codexScanContentFingerprint
                let minimumKnownCompleteEOF: Int64
                if metadata.fileId != nil,
                   cached?.codexScanFileId == metadata.fileId,
                   let cachedFingerprint,
                   let cachedSize = cached?.size,
                   cachedSize >= 0,
                   cachedSize <= metadata.size,
                   Self.codexFrozenPrefixFingerprint(
                       fileURL: fileURL,
                       targetEOF: cachedSize,
                       withinRoot: root) == cachedFingerprint
                {
                    minimumKnownCompleteEOF = cachedSize
                } else {
                    minimumKnownCompleteEOF = 0
                }
                guard let target = Self.codexFrozenFile(
                    fileURL: fileURL,
                    withinRoot: root,
                    minimumKnownCompleteEOF: minimumKnownCompleteEOF)
                else { continue }
                manifest[fileURL.path] = target
            }
            return manifest
        }

        func captureFileManifest(
            range: CostUsageDayRange,
            plan: CodexRefreshPlan,
            cache: CostUsageCache,
            useWarmDelta: Bool) -> [String: CodexFrozenFile]
        {
            var seenPaths: Set<String> = []
            var files: [URL] = []
            func appendUnique(_ candidates: [URL]) {
                for candidate in candidates.sorted(by: { $0.path < $1.path }) {
                    let fileURL = candidate.standardizedFileURL
                    guard seenPaths.insert(fileURL.path).inserted else { continue }
                    files.append(fileURL)
                }
            }
            if useWarmDelta {
                let currentDayKey = CostUsageDayRange.dayKey(from: now)
                let lastSuccessfulScan = Date(
                    timeIntervalSince1970: Double(max(Int64(0), cache.lastScanUnixMs)) / 1000)
                // Existing cache already owns the historical total. Only files
                // written since the last published scan need a content pass;
                // the small overlap tolerates coarse filesystem timestamps.
                let modifiedSince = lastSuccessfulScan.addingTimeInterval(-2)
                for root in plan.roots {
                    appendUnique(Self.listCodexRecentlyModifiedFiles(
                        root: root,
                        scanSinceKey: range.scanSinceKey,
                        scanUntilKey: range.scanUntilKey,
                        modifiedSince: modifiedSince,
                        includeLegacyRecursive: false))
                    appendUnique(Self.listCodexSessionFiles(
                        root: root,
                        scanSinceKey: currentDayKey,
                        scanUntilKey: currentDayKey,
                        includeRecursive: false))
                }
                appendUnique(cache.files.compactMap { path, usage in
                    guard usage.days[currentDayKey] != nil || usage.codexScanComplete == false
                    else { return nil }
                    let fileURL = URL(fileURLWithPath: path).standardizedFileURL
                    guard FileManager.default.fileExists(atPath: fileURL.path),
                          Self.isWithinCodexRoots(fileURL: fileURL, roots: plan.roots)
                    else { return nil }
                    return fileURL
                })
            } else {
                let shouldRunColdCacheLookback = cache.files.isEmpty || plan.rootsChanged
                let coldCacheLookbackStart = Self.parseDayKey(range.scanSinceKey)
                    .map { Calendar.current.startOfDay(for: $0) }
                for root in plan.roots {
                    appendUnique(Self.listCodexSessionFiles(
                        root: root,
                        scanSinceKey: range.scanSinceKey,
                        scanUntilKey: range.scanUntilKey,
                        includeRecursive: options.forceRescan))

                    if shouldRunColdCacheLookback, let coldCacheLookbackStart {
                        appendUnique(Self.listCodexRecentlyModifiedFiles(
                            root: root,
                            scanSinceKey: range.scanSinceKey,
                            scanUntilKey: range.scanUntilKey,
                            modifiedSince: coldCacheLookbackStart,
                            includeLegacyRecursive: true))
                    }
                }
                appendUnique(Self.cachedCodexSessionFiles(
                    cache: cache,
                    range: range,
                    roots: plan.roots,
                    excludingPaths: seenPaths))
            }

            return frozenManifest(files: files, plan: plan, cache: cache)
        }

        let requestedGeneration = semanticGeneration(for: requestedPlan)
        let usesWarmDeltaManifest = canUseWarmDeltaManifest(
            plan: requestedPlan,
            cache: committedCache)
        let hasResumablePendingEpisode = !options.forceRescan
            && committedCache.codexPendingScanGeneration == requestedGeneration
            && committedCache.codexPendingScanSinceKey != nil
            && committedCache.codexPendingScanUntilKey != nil
            && committedCache.codexPendingFileManifest != nil
            && committedCache.codexPendingFiles != nil
            && committedCache.codexPendingDays != nil
            && Self.codexFrozenManifestUsesCanonicalPaths(
                committedCache.codexPendingFileManifest ?? [:])
        let scanRange = if hasResumablePendingEpisode {
            CostUsageDayRange(
                scanSinceKey: committedCache.codexPendingScanSinceKey!,
                scanUntilKey: committedCache.codexPendingScanUntilKey!)
        } else {
            range
        }
        let plan = hasResumablePendingEpisode
            ? Self.makeCodexRefreshPlan(
                cache: committedCache,
                range: scanRange,
                now: now,
                nowMs: nowMs,
                options: options)
            : requestedPlan

        if plan.shouldRefresh {
            try checkCancellation?()
            let scanSemanticGeneration = semanticGeneration(for: plan)
            let scanGeneration = [
                scanSemanticGeneration,
                scanRange.scanSinceKey,
                scanRange.scanUntilKey,
            ].joined(separator: "|")
            let resumesPendingGeneration = hasResumablePendingEpisode
                && committedCache.codexPendingScanGeneration == scanSemanticGeneration
            if resumesPendingGeneration {
                cache.files = committedCache.codexPendingFiles ?? [:]
                cache.days = committedCache.codexPendingDays ?? [:]
            } else if options.forceRescan {
                cache = CostUsageCache()
            }
            cache.codexPendingScanGeneration = nil
            cache.codexPendingScanSinceKey = nil
            cache.codexPendingScanUntilKey = nil
            cache.codexPendingFileManifest = nil
            cache.codexPendingFileOrder = nil
            cache.codexPendingFlatDiscoveryOffsets = nil
            cache.codexPendingFlatDiscoveryProgress = nil
            cache.codexPendingFiles = nil
            cache.codexPendingDays = nil
            cache.codexPendingParentScans = nil
            cache.codexPendingParentDiscoveries = nil

            let cachedSinceKey = cache.scanSinceKey
            let cachedUntilKey = cache.scanUntilKey
            var fileManifest = resumesPendingGeneration
                ? (committedCache.codexPendingFileManifest ?? [:])
                : captureFileManifest(
                    range: scanRange,
                    plan: plan,
                    cache: cache,
                    useWarmDelta: usesWarmDeltaManifest)
            var flatDiscoveryOffsets: [String: Int64]? = if resumesPendingGeneration {
                committedCache.codexPendingFlatDiscoveryOffsets
            } else if usesWarmDeltaManifest {
                Dictionary(uniqueKeysWithValues: plan.roots.map {
                    ($0.standardizedFileURL.path, Int64(0))
                })
            } else {
                nil
            }
            var flatDiscoveryProgress: [String: String]? = resumesPendingGeneration
                ? committedCache.codexPendingFlatDiscoveryProgress
                : nil
            if var offsets = flatDiscoveryOffsets {
                var progress = flatDiscoveryProgress ?? [:]
                var remainingVisits = Self.codexCatchUpScanCandidateLimit
                for rootPath in offsets.keys.sorted() where remainingVisits > 0 {
                    let root = URL(fileURLWithPath: rootPath, isDirectory: true)
                    let page = Self.listCodexFlatDirectoryPage(
                        root: root,
                        scanSinceKey: scanRange.scanSinceKey,
                        scanUntilKey: scanRange.scanUntilKey,
                        resumeOffset: offsets[rootPath] ?? 0,
                        visitLimit: remainingVisits)
                    remainingVisits -= page.visits
                    let changedFiles = page.files.filter { candidate in
                        let fileURL = candidate.standardizedFileURL
                        let metadata = Self.codexFileMetadata(fileURL: fileURL)
                        guard metadata.fileId != nil else { return false }
                        guard let cached = cache.files[fileURL.path] else { return true }
                        return cached.codexScanFileId != metadata.fileId
                            || cached.mtimeUnixMs != metadata.mtimeUnixMs
                            || cached.size != metadata.size
                    }
                    fileManifest.merge(
                        frozenManifest(files: changedFiles, plan: plan, cache: cache),
                        uniquingKeysWith: { _, latest in latest })
                    if let nextOffset = page.nextOffset {
                        offsets[rootPath] = nextOffset
                        if let continuationToken = page.continuationToken {
                            progress[rootPath] = continuationToken
                        }
                    } else {
                        offsets.removeValue(forKey: rootPath)
                        progress.removeValue(forKey: rootPath)
                    }
                }
                flatDiscoveryOffsets = offsets.isEmpty ? nil : offsets
                flatDiscoveryProgress = offsets.isEmpty ? nil : progress
            }
            if flatDiscoveryOffsets == nil {
                flatDiscoveryProgress = nil
            }
            let flatDiscoveryIncomplete = flatDiscoveryOffsets != nil
            let files = fileManifest.keys.sorted().map { URL(fileURLWithPath: $0) }
            let filePathsInScan = Set(fileManifest.keys)
            let scanDeadline = options.maxScanWallClock.map { Date().addingTimeInterval($0) }
            let shouldStop = scanDeadline.map { deadline in { Date() >= deadline } }
            let filesToScan = files.filter { fileURL in
                guard resumesPendingGeneration,
                      let target = fileManifest[fileURL.path],
                      let usage = cache.files[fileURL.path]
                else { return true }
                return usage.codexScanGeneration != scanGeneration
                    || usage.codexScanComplete != true
                    || usage.codexScanTargetSize != target.targetEOF
                    || usage.codexScanFileId != target.fileId
                    || usage.codexScanContentFingerprint != target.contentFingerprint
            }
            var pendingFileOrder = Self.reconciledCodexPendingFileOrder(
                persistedOrder: resumesPendingGeneration
                    ? committedCache.codexPendingFileOrder
                    : nil,
                eligiblePaths: Set(filesToScan.map(\.path)))
            let scheduledFilePaths = flatDiscoveryIncomplete
                ? pendingFileOrder.prefix(0)
                : pendingFileOrder.prefix(Self.codexCatchUpScanCandidateLimit)
            let scheduledFiles = scheduledFilePaths.map { URL(fileURLWithPath: $0) }
            let pathsRequiringScan = Set(filesToScan.map(\.path))
            var scanState = CodexScanState()
            // Rehydrate dedupe/project state from trusted cached entries without
            // reopening their JSONL content. Current-generation complete files
            // are therefore skipped on resume instead of consuming every pass.
            for path in cache.files.keys.sorted() where !pathsRequiringScan.contains(path) {
                guard let usage = cache.files[path] else { continue }
                let fileURL = URL(fileURLWithPath: path).standardizedFileURL
                guard FileManager.default.fileExists(atPath: fileURL.path),
                      Self.isWithinCodexRoots(fileURL: fileURL, roots: plan.roots)
                else { continue }
                if let sessionId = usage.sessionId, !sessionId.isEmpty {
                    scanState.seenSessionIds.insert(sessionId)
                    if scanState.sessionFilePaths[sessionId] == nil {
                        scanState.sessionFilePaths[sessionId] = fileURL.path
                    }
                    if usage.projectAttributionAmbiguous == true {
                        scanState.ambiguousProjectSessionIds.insert(sessionId)
                    }
                }
                if let fileId = usage.codexScanFileId, !fileId.isEmpty {
                    scanState.seenFileIds.insert(fileId)
                }
            }
            var sawUnavailableFrozenTarget = false
            var unavailableFrozenPaths: Set<String> = []
            var unavailableFrozenPathIdentities: Set<String> = []
            let fileIndex = CodexSessionFileIndex(
                files: files,
                roots: plan.roots,
                targetEOFByPath: fileManifest.mapValues(\.targetEOF),
                cachedSessionFiles: Self.cachedCodexSessionIndex(
                    cache: cache,
                    roots: plan.roots,
                    knownExistingPaths: filePathsInScan),
                checkCancellation: checkCancellation,
                shouldStop: shouldStop,
                generation: scanGeneration,
                pendingParentDiscoveries: resumesPendingGeneration
                    ? (committedCache.codexPendingParentDiscoveries ?? [:])
                    : [:])
            let inheritedResolver = CodexInheritedTotalsResolver(
                fileIndex: fileIndex,
                checkCancellation: checkCancellation,
                shouldStop: shouldStop,
                generation: scanGeneration,
                pendingParentScans: resumesPendingGeneration
                    ? (committedCache.codexPendingParentScans ?? [:])
                    : [:])
            let resources = CodexScanResources(
                fileIndex: fileIndex,
                inheritedResolver: inheritedResolver,
                modelsDevCatalog: plan.modelsDevCatalog,
                modelsDevCacheRoot: options.cacheRoot,
                priorityTurns: plan.priorityTurns)
            var completedFilePaths: Set<String> = []
            var servicedIncompleteFilePaths: Set<String> = []
            if flatDiscoveryIncomplete {
                scanTruncated = true
            }
            for fileURL in scheduledFiles {
                if let scanDeadline, Date() >= scanDeadline { scanTruncated = true; break }
                guard let target = fileManifest[fileURL.path] else { continue }
                let fileOutcome = try Self.scanCodexFile(
                    fileURL: fileURL,
                    target: target,
                    context: CodexFileScanContext(
                        range: scanRange,
                        forceFullScan: options
                            .forceRescan || plan.windowExpanded || plan.pricingChanged || plan.priorityMetadataChanged
                            || plan.needsCostCacheMigration,
                        dropDeferredCodexRows: options.forceRescan || plan.pricingChanged || plan
                            .priorityMetadataChanged
                            || plan.needsTurnIDCacheMigration
                            || plan.needsCostCacheMigration,
                        requiresTurnIDCache: plan.needsTurnIDCacheMigration,
                        changedPriorityTurnIDs: plan.changedPriorityTurnIDs,
                        resources: resources,
                        checkCancellation: checkCancellation,
                        shouldStop: shouldStop,
                        scanGeneration: scanGeneration,
                        roots: plan.roots),
                    cache: &cache,
                    state: &scanState)
                if case .unavailable = fileOutcome {
                    // The immutable target disappeared or changed. Finish the
                    // bounded pass, then roll the whole publishable snapshot
                    // back to last-good and seed a fresh catch-up manifest.
                    let unavailablePath = fileURL.standardizedFileURL.path
                    unavailableFrozenPaths.insert(unavailablePath)
                    unavailableFrozenPathIdentities.insert(
                        Self.codexCachePathIdentity(unavailablePath))
                    sawUnavailableFrozenTarget = true
                    // This immutable target cannot become readable again. Drain
                    // it from the old FIFO so the generation can roll back and
                    // seed a fresh manifest after the remaining waiters finish.
                    completedFilePaths.insert(unavailablePath)
                    continue
                }
                if case .incomplete = fileOutcome {
                    servicedIncompleteFilePaths.insert(fileURL.path)
                    scanTruncated = true
                    break
                }
                completedFilePaths.insert(fileURL.path)
            }
            pendingFileOrder = Self.finalizedCodexPendingFileOrder(
                pendingFileOrder,
                completedPaths: completedFilePaths,
                servicedIncompletePaths: servicedIncompleteFilePaths)
            if !pendingFileOrder.isEmpty {
                scanTruncated = true
            }
            try checkCancellation?()

            if scanTruncated, !sawUnavailableFrozenTarget {
                committedCache.codexPendingScanGeneration = scanSemanticGeneration
                committedCache.codexPendingScanSinceKey = scanRange.scanSinceKey
                committedCache.codexPendingScanUntilKey = scanRange.scanUntilKey
                committedCache.codexPendingFileManifest = fileManifest
                committedCache.codexPendingFileOrder = pendingFileOrder
                committedCache.codexPendingFlatDiscoveryOffsets = flatDiscoveryOffsets
                committedCache.codexPendingFlatDiscoveryProgress = flatDiscoveryProgress
                committedCache.codexPendingFiles = cache.files
                committedCache.codexPendingDays = cache.days
                committedCache.codexPendingParentScans = inheritedResolver.pendingParentScans
                committedCache.codexPendingParentDiscoveries = fileIndex.pendingParentDiscoveries
            } else if sawUnavailableFrozenTarget {
                // Never promote a mixed generation. Keep every global trust
                // marker and every accessible file at the previous committed
                // snapshot, canonicalizing only aliases of unavailable paths.
                let lastGoodFiles = committedCache.files
                for path in unavailableFrozenPaths.sorted() {
                    Self.restoreCommittedCodexFile(
                        path: path,
                        committedFiles: lastGoodFiles,
                        cache: &committedCache)
                }

                let currentManifest = captureFileManifest(
                    range: range,
                    plan: requestedPlan,
                    cache: committedCache,
                    useWarmDelta: usesWarmDeltaManifest)
                var catchUpFiles = committedCache.files
                for key in currentManifest.keys {
                    catchUpFiles[key]?.codexScanGeneration = nil
                    catchUpFiles[key]?.codexScanComplete =
                        unavailableFrozenPathIdentities.contains(
                            Self.codexCachePathIdentity(key)) ? false : nil
                }
                // A vanished frozen path may no longer appear in the newly
                // captured manifest. Preserve its explicit incomplete marker
                // in the last-good working map so recovery cannot mistake it
                // for a trusted completion receipt.
                for key in catchUpFiles.keys where unavailableFrozenPathIdentities.contains(
                    Self.codexCachePathIdentity(key))
                {
                    catchUpFiles[key]?.codexScanGeneration = nil
                    catchUpFiles[key]?.codexScanComplete = false
                }
                committedCache.codexPendingScanGeneration = requestedGeneration
                committedCache.codexPendingScanSinceKey = range.scanSinceKey
                committedCache.codexPendingScanUntilKey = range.scanUntilKey
                committedCache.codexPendingFileManifest = currentManifest
                committedCache.codexPendingFileOrder = Self.reconciledCodexPendingFileOrder(
                    persistedOrder: nil,
                    eligiblePaths: Set(currentManifest.keys))
                committedCache.codexPendingFlatDiscoveryOffsets = Dictionary(
                    uniqueKeysWithValues: requestedPlan.roots.map {
                        ($0.standardizedFileURL.path, Int64(0))
                    })
                committedCache.codexPendingFlatDiscoveryProgress = nil
                committedCache.codexPendingFiles = catchUpFiles
                committedCache.codexPendingDays = committedCache.days
                committedCache.codexPendingParentScans = [:]
                committedCache.codexPendingParentDiscoveries = [:]
                scanTruncated = true
                committedGenerationCompleted = true
            } else {
                Self.pruneForceRescanFilesOutsideWindow(
                    cache: &cache,
                    range: scanRange,
                    isForceRescan: options.forceRescan)

                let shouldDropAllUnscannedFiles = options.forceRescan || plan.rootsChanged || cache.files.isEmpty
                if shouldDropAllUnscannedFiles {
                    for key in cache.files.keys where !filePathsInScan.contains(key) {
                        guard let old = cache.files[key] else { continue }
                        Self.applyFileDays(cache: &cache, fileDays: old.days, sign: -1)
                        cache.files.removeValue(forKey: key)
                    }
                }

                if !shouldDropAllUnscannedFiles {
                    for key in cache.files.keys {
                        guard let old = cache.files[key] else { continue }
                        guard old.touchesCodexScanWindow(
                            sinceKey: scanRange.scanSinceKey,
                            untilKey: scanRange.scanUntilKey)
                        else { continue }
                        guard FileManager.default.fileExists(atPath: key) else {
                            Self.applyFileDays(cache: &cache, fileDays: old.days, sign: -1)
                            cache.files.removeValue(forKey: key)
                            continue
                        }
                    }
                }

                let shouldRetainWiderWindow = !options.forceRescan && !plan.pricingChanged && !plan
                    .priorityMetadataChanged && !plan.needsTurnIDCacheMigration
                let retainedSinceKey = shouldRetainWiderWindow
                    ? [cachedSinceKey, scanRange.scanSinceKey].compactMap(\.self).min()
                        ?? scanRange.scanSinceKey
                    : scanRange.scanSinceKey
                let retainedUntilKey = shouldRetainWiderWindow
                    ? [cachedUntilKey, scanRange.scanUntilKey].compactMap(\.self).max()
                        ?? scanRange.scanUntilKey
                    : scanRange.scanUntilKey
                Self.pruneDays(cache: &cache, sinceKey: retainedSinceKey, untilKey: retainedUntilKey)
                cache.roots = plan.rootsFingerprint
                cache.scanSinceKey = retainedSinceKey
                cache.scanUntilKey = retainedUntilKey
                cache.codexPricingKey = plan.codexPricingKey
                cache.codexPriorityMetadataKey = plan.codexPriorityMetadataKey
                if plan.hasPriorityMetadata {
                    cache.codexPriorityTurnKeys = Self.mergePriorityTurnKeys(
                        existing: shouldRetainWiderWindow ? cache.codexPriorityTurnKeys : nil,
                        new: plan.priorityTurnKeys,
                        range: scanRange,
                        retainedSinceKey: retainedSinceKey,
                        retainedUntilKey: retainedUntilKey)
                    cache.codexPriorityTurnIDsByDay = Self.mergePriorityTurnIDsByDay(
                        existing: shouldRetainWiderWindow ? cache.codexPriorityTurnIDsByDay : nil,
                        new: plan.priorityTurnIDsByDay,
                        range: scanRange,
                        retainedSinceKey: retainedSinceKey,
                        retainedUntilKey: retainedUntilKey)
                }
                cache.lastScanUnixMs = nowMs
                cache.codexPendingScanGeneration = nil
                cache.codexPendingScanSinceKey = nil
                cache.codexPendingScanUntilKey = nil
                cache.codexPendingFileManifest = nil
                cache.codexPendingFileOrder = nil
                cache.codexPendingFlatDiscoveryOffsets = nil
                cache.codexPendingFlatDiscoveryProgress = nil
                cache.codexPendingFiles = nil
                cache.codexPendingDays = nil
                cache.codexPendingParentScans = nil
                cache.codexPendingParentDiscoveries = nil
                committedCache = cache
                committedGenerationCompleted = true

                // A warm delta publishes exactly the EOF captured for this
                // refresh. Later appends belong to the next bounded warm pass
                // instead of creating an endless live chase.
                if !usesWarmDeltaManifest {
                    let currentRequestIsCovered = range.scanSinceKey >= (cache.scanSinceKey ?? "")
                        && range.untilKey <= (cache.scanUntilKey ?? "")
                    let currentManifest = captureFileManifest(
                        range: range,
                        plan: requestedPlan,
                        cache: cache,
                        useWarmDelta: false)
                    if !currentRequestIsCovered
                        || !Self.codexFrozenManifestsHaveSameFrontier(fileManifest, currentManifest)
                    {
                        let catchUpManifest = captureFileManifest(
                            range: range,
                            plan: requestedPlan,
                            cache: cache,
                            useWarmDelta: true)
                        var catchUpFiles = cache.files
                        for key in catchUpManifest.keys {
                            catchUpFiles[key]?.codexScanGeneration = nil
                            catchUpFiles[key]?.codexScanComplete = nil
                        }
                        committedCache.codexPendingScanGeneration = requestedGeneration
                        committedCache.codexPendingScanSinceKey = range.scanSinceKey
                        committedCache.codexPendingScanUntilKey = range.scanUntilKey
                        committedCache.codexPendingFileManifest = catchUpManifest
                        committedCache.codexPendingFileOrder = Self.reconciledCodexPendingFileOrder(
                            persistedOrder: nil,
                            eligiblePaths: Set(catchUpManifest.keys))
                        committedCache.codexPendingFlatDiscoveryOffsets = Dictionary(
                            uniqueKeysWithValues: requestedPlan.roots.map {
                                ($0.standardizedFileURL.path, Int64(0))
                            })
                        committedCache.codexPendingFlatDiscoveryProgress = nil
                        committedCache.codexPendingFiles = catchUpFiles
                        committedCache.codexPendingDays = cache.days
                        committedCache.codexPendingParentScans = [:]
                        committedCache.codexPendingParentDiscoveries = [:]
                        scanTruncated = true
                    }
                }
            }
            try checkCancellation?()
            let cachePersisted = CostUsageCacheIO.save(
                provider: .codex,
                cache: committedCache,
                cacheRoot: options.cacheRoot)
            if committedGenerationCompleted {
                committedGenerationPersisted = cachePersisted && !sawUnavailableFrozenTarget
            }
        }

        if scanTruncated {
            if committedGenerationCompleted {
                let committedReport = Self.buildCodexReportFromCache(
                    cache: committedCache,
                    range: range,
                    modelsDevCatalog: requestedPlan.modelsDevCatalog,
                    modelsDevCacheRoot: options.cacheRoot,
                    priorityTurns: requestedPlan.priorityTurns)
                return CostUsageDailyReport(
                    data: committedReport.data,
                    summary: committedReport.summary,
                    projectBreakdown: committedReport.projectBreakdown,
                    projectRetractions: committedReport.projectRetractions,
                    scanIncomplete: true,
                    completedFiniteScanGeneration: committedGenerationPersisted)
            }
            return CostUsageDailyReport(data: [], summary: nil, scanIncomplete: true)
        }
        return Self.buildCodexReportFromCache(
            cache: committedCache,
            range: range,
            modelsDevCatalog: plan.modelsDevCatalog,
            modelsDevCacheRoot: options.cacheRoot,
            priorityTurns: plan.priorityTurns)
    }
}

// swiftlint:enable type_body_length
