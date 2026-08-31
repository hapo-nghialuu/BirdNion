import Foundation

enum CostUsageCacheIO {
    /// Producer keys from older parser hashes whose caches are still valid under the current
    /// delta semantics. Cleared for #2037: interleave containment changed how cumulative
    /// totals are counted, so every earlier cache must be rebuilt.
    private static let compatibleCodexProducerKeys: Set<String> = []

    /// v11 could contain raw Codex session paths. Remove that exact obsolete
    /// artifact during migration so an upgrade cannot leave sensitive data at rest.
    private static let sensitiveObsoleteCodexArtifactVersions = [11]

    /// Parsing and attribution changes rotate the Codex parser producer key.
    /// Increment this artifact version only when the stored schema or cache layout becomes incompatible.
    private static func artifactVersion(for provider: UsageProvider) -> Int {
        switch provider {
        case .codex:
            12
        case .claude, .vertexai:
            6
        default:
            1
        }
    }

    private static func defaultCacheRoot() -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return root.appendingPathComponent("CodexBar", isDirectory: true)
    }

    static func cacheFileURL(provider: UsageProvider, cacheRoot: URL? = nil) -> URL {
        let root = cacheRoot ?? self.defaultCacheRoot()
        let artifactVersion = self.artifactVersion(for: provider)
        return root
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent("\(provider.rawValue)-v\(artifactVersion).json", isDirectory: false)
    }

    static func load(
        provider: UsageProvider,
        cacheRoot: URL? = nil,
        producerKey: String? = nil,
        calendar: Calendar? = nil) -> CostUsageCache
    {
        try? self.removeSensitiveObsoleteCaches(provider: provider, cacheRoot: cacheRoot)
        let url = self.cacheFileURL(provider: provider, cacheRoot: cacheRoot)
        let expectedProducerKey = producerKey ?? self.currentProducerKey(provider: provider)
        let compatibleProducerKeys = producerKey == nil && provider == .codex
            ? self.compatibleCodexProducerKeys
            : []
        if var decoded = self.loadCache(
            at: url,
            expectedProducerKey: expectedProducerKey,
            compatibleProducerKeys: compatibleProducerKeys)
        {
            if let calendar, decoded.timeZoneIdentifier != calendar.timeZone.identifier {
                return CostUsageCache()
            }
            if provider == .codex {
                decoded.migrateLegacyCodexPendingJournalIfNeeded()
            }
            return decoded
        }
        return CostUsageCache()
    }

    private static func loadCache(
        at url: URL,
        expectedProducerKey: String?,
        compatibleProducerKeys: Set<String>) -> CostUsageCache?
    {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let decoded = try? JSONDecoder().decode(CostUsageCache.self, from: data)
        else { return nil }
        guard decoded.version == 1 else { return nil }
        if let expectedProducerKey {
            guard decoded.producerKey == expectedProducerKey
                || decoded.producerKey.map(compatibleProducerKeys.contains) == true
            else { return nil }
        }
        return decoded
    }

    @discardableResult
    static func save(
        provider: UsageProvider,
        cache: CostUsageCache,
        cacheRoot: URL? = nil,
        producerKey: String? = nil,
        calendar: Calendar = .current) -> Bool
    {
        try? self.removeSensitiveObsoleteCaches(provider: provider, cacheRoot: cacheRoot)
        let url = self.cacheFileURL(provider: provider, cacheRoot: cacheRoot)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var cache = cache
        cache.producerKey = producerKey ?? self.currentProducerKey(provider: provider)
        cache.timeZoneIdentifier = calendar.timeZone.identifier

        let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString).json", isDirectory: false)
        guard let data = try? JSONEncoder().encode(cache) else { return false }
        do {
            try data.write(to: tmp, options: [.atomic])
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
    }

    static func removeSensitiveObsoleteCaches(
        provider: UsageProvider,
        cacheRoot: URL?)
        throws
    {
        guard provider == .codex else { return }
        let root = cacheRoot ?? self.defaultCacheRoot()
        let directory = root.appendingPathComponent("cost-usage", isDirectory: true)
        for version in self.sensitiveObsoleteCodexArtifactVersions {
            let url = directory.appendingPathComponent("codex-v\(version).json", isDirectory: false)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    static func currentProducerKey(
        provider: UsageProvider,
        parserHash: String = CodexParserHash.value) -> String?
    {
        guard provider == .codex else { return nil }
        return "\(provider.rawValue):cu:p\(parserHash)"
    }
}

struct CostUsageCache: Codable {
    var version: Int = 1
    var producerKey: String?
    var lastScanUnixMs: Int64 = 0
    var scanSinceKey: String?
    var scanUntilKey: String?
    var timeZoneIdentifier: String?
    var codexPricingKey: String?
    var codexPriorityMetadataKey: String?
    var codexProjectMetadataVersion: Int?
    var codexPriorityTurnKeys: [String: String]?
    var codexPriorityTurnIDsByDay: [String: [String]]?
    /// Multi-pass bounded scan that has not finalized global metadata yet.
    var codexPendingScanGeneration: String?
    /// Immutable scan window for the pending episode. A caller may move its
    /// requested window while this episode runs; the episode still finishes
    /// against these bounds before a catch-up episode is seeded.
    var codexPendingScanSinceKey: String?
    var codexPendingScanUntilKey: String?
    /// Immutable file membership and byte frontier for one bounded episode.
    /// Appends and newly-created files are captured by a later catch-up episode.
    var codexPendingFileManifest: [String: CodexFrozenFile]?
    /// Working state for an unfinished generation. These fields are never used
    /// to build a publishable report; completion promotes them atomically.
    var codexPendingFiles: [String: CostUsageFileUsage]?
    var codexPendingDays: [String: [String: [Int]]]?
    /// Resumable parent-baseline parsers for the same pending generation.
    /// Keys are opaque parent dependency query IDs; no paths are persisted.
    var codexPendingParentScans: [String: CodexParentSnapshotJournal]?
    /// Bounded, relative-only DFS cursors for cold parent lookup.
    var codexPendingParentDiscoveries: [String: CodexParentDiscoveryJournal]?

    /// filePath -> file usage
    var files: [String: CostUsageFileUsage] = [:]

    /// dayKey -> model -> packed usage
    var days: [String: [String: [Int]]] = [:]

    /// rootPath -> mtime (for Claude roots)
    var roots: [String: Int64]?

    mutating func migrateLegacyCodexPendingJournalIfNeeded() {
        guard self.codexPendingScanGeneration != nil else { return }
        let hasCompleteFiniteJournal = self.codexPendingScanSinceKey != nil
            && self.codexPendingScanUntilKey != nil
            && self.codexPendingFileManifest != nil
            && self.codexPendingFileManifest?.values.allSatisfy {
                $0.contentFingerprint?.hasPrefix("sha256-sample-v2:") == true
            } == true
            && self.codexPendingFiles != nil
            && self.codexPendingDays != nil
        guard !hasCompleteFiniteJournal else { return }

        if self.codexPendingFiles == nil || self.codexPendingDays == nil {
            // Legacy writers mixed unfinished work into the main maps. Keep
            // those maps as a rescan baseline, but remove publishable coverage
            // so callers cannot mistake the mixed state for a committed report.
            self.scanSinceKey = nil
            self.scanUntilKey = nil
            self.lastScanUnixMs = 0
        }

        // An incomplete journal has no trustworthy immutable corpus boundary.
        // Discard only journal state and seed a new finite generation next time.
        self.codexPendingScanGeneration = nil
        self.codexPendingScanSinceKey = nil
        self.codexPendingScanUntilKey = nil
        self.codexPendingFileManifest = nil
        self.codexPendingFiles = nil
        self.codexPendingDays = nil
        self.codexPendingParentScans = nil
        self.codexPendingParentDiscoveries = nil
    }
}

/// One append-only JSONL target captured for a finite Codex scan generation.
struct CodexFrozenFile: Codable, Equatable {
    var fileId: String
    var mtimeUnixMs: Int64
    var observedSize: Int64
    var targetEOF: Int64
    /// Privacy-safe bounded digest of the frozen prefix. File identity, size,
    /// mtime and distributed samples reject ordinary rewrite/regrow without
    /// persisting raw data or defeating the scan wall-clock budget.
    var contentFingerprint: String? = nil
}

struct CostUsageFileUsage: Codable {
    var mtimeUnixMs: Int64
    var size: Int64
    var days: [String: [String: [Int]]]
    var parsedBytes: Int64?
    var lastModel: String?
    var lastTotals: CostUsageCodexTotals?
    var lastCountedTotals: CostUsageCodexTotals?
    var lastRawTotalsBaseline: CostUsageCodexTotals?
    var lastRawTotalsWatermark: CostUsageCodexTotals?
    var seenRawTotals: [CostUsageCodexTotals]?
    var hasDivergentTotals: Bool?
    var hasInterleavedTotals: Bool?
    var lastCodexTurnID: String?
    var sessionId: String?
    var forkedFromId: String?
    var forkBaselineDependencyKey: String?
    /// Privacy-safe project attribution. Raw `session_meta.payload.cwd` is
    /// normalized and hashed during parsing, then discarded before caching.
    var projectKey: String?
    var projectName: String?
    var projectAttributionAmbiguous: Bool?
    var projectRetractionID: String?
    var projectRetractionKey: String?
    var codexCostCacheComplete: Bool?
    var codexCostNanos: [String: [String: Int64]]?
    var codexPrioritySurchargeNanos: [String: [String: Int64]]?
    var codexStandardCostNanos: [String: [String: Int64]]?
    var codexPriorityCostNanos: [String: [String: Int64]]?
    var codexStandardTokens: [String: [String: Int]]?
    var codexPriorityTokens: [String: [String: Int]]?
    var codexTurnIDs: [String]?
    var codexRows: [CostUsageScanner.CodexUsageRow]?
    var claudeRows: [CostUsageScanner.ClaudeUsageRow]?
    /// Identity and target size for an in-progress bounded Codex parse.
    var codexScanFileId: String?
    var codexScanTargetSize: Int64?
    /// Bounded digest of the prefix that produced this cached usage.
    var codexScanContentFingerprint: String?
    var codexScanComplete: Bool?
    var codexScanGeneration: String?
    var codexParseResumeState: CodexParseResumeState?
}

/// Parser locals that influence Codex cumulative/fork delta semantics. A byte
/// offset is resumable only when this complete state accompanies it.
struct CodexParseResumeState: Codable {
    var currentModel: String?
    var lastCountedTotals: CostUsageCodexTotals?
    var lastRawTotalsBaseline: CostUsageCodexTotals?
    var lastCodexTurnID: String?
    var sessionId: String?
    var forkedFromId: String?
    var projectKey: String?
    var projectName: String?
    var projectAttributionAmbiguous: Bool
    var inheritedTotals: CostUsageCodexTotals?
    var remainingInheritedTotals: CostUsageCodexTotals?
    var forkBaselineResolved: Bool
    var hasUnresolvedForkBaseline: Bool
    var usesCompactForkTotals: Bool
    var compactForkBaselineApplied: Bool
    var unresolvedForkTotalWatermark: CostUsageCodexTotals?
    var hasDivergentTotals: Bool
    /// Resume inside an oversized record that has already been classified as
    /// ignored. Bytes are discarded until its newline, never parsed as suffix.
    var discardingTruncatedLine: Bool? = nil
}

struct CodexParentSnapshot: Codable, Equatable {
    var timestamp: String
    var totals: CostUsageCodexTotals
}

struct CodexParentSnapshotJournal: Codable, Equatable {
    var generation: String
    var sessionId: String
    var fileId: String
    var mtimeUnixMs: Int64
    var size: Int64
    /// Physical size observed when `size` (the frozen EOF) was captured.
    var observedSize: Int64? = nil
    var contentFingerprint: String? = nil
    var parsedBytes: Int64
    var previousTotals: CostUsageCodexTotals?
    var rawTotalsBaseline: CostUsageCodexTotals?
    var hasDivergentTotals: Bool
    /// The one fork query this checkpoint resolves. New writers never retain
    /// the full token timeline; `snapshots` is decode-only v12 compatibility.
    var cutoffTimestamp: String?
    var cutoffTotals: CostUsageCodexTotals?
    var snapshots: [CodexParentSnapshot]?
    var scanComplete: Bool
    var discardingTruncatedLine: Bool? = nil
}

struct CodexParentDiscoveryDirectoryCursor: Codable, Equatable {
    var relativePath: String
    var lastEntryName: String?
    /// Snapshot of this directory's entry names. Once populated, later passes
    /// never re-enumerate the live directory for the same generation.
    var frozenEntryNames: [String]? = nil
    var nextEntryIndex: Int? = nil
}

struct CodexParentDiscoveryJournal: Codable, Equatable {
    var generation: String
    var rootIndex: Int
    var directoryStack: [CodexParentDiscoveryDirectoryCursor]
    /// Durable privacy-safe locator retained after discovery so a bounded
    /// parent parse does not rediscover the same file on every pass.
    var resolvedRootIndex: Int?
    var resolvedRelativePath: String?
}

struct CostUsageCodexTotals: Codable, Equatable {
    var input: Int
    var cached: Int
    var output: Int
    var reasoning: Int?

    init(input: Int, cached: Int, output: Int, reasoning: Int? = nil) {
        self.input = input
        self.cached = cached
        self.output = output
        self.reasoning = reasoning
    }
}
