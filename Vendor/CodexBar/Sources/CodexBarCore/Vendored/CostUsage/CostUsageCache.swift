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
    /// Exact request window completed by the most recent finite Codex episode.
    /// `scanSinceKey`/`scanUntilKey` may retain a wider historical cache, so
    /// they cannot decide whether a later request expands into uninventoried
    /// history after a wide -> narrow -> wide sequence.
    var codexLastSuccessfulRequestScanSinceKey: String?
    var codexLastSuccessfulRequestScanUntilKey: String?
    /// One-shot compatibility barrier for caches written before exact request
    /// coverage was persisted. The live delta publishes first; the following
    /// background pass performs the complete legacy inventory before this is
    /// cleared and exact coverage is trusted.
    var codexNeedsLegacyColdInventory: Bool?
    var timeZoneIdentifier: String?
    var codexPricingKey: String?
    var codexPriorityMetadataKey: String?
    var codexProjectMetadataVersion: Int?
    var codexPriorityTurnKeys: [String: String]?
    var codexPriorityTurnIDsByDay: [String: [String]]?
    /// JSON-wrapped durable cursor for `logs_2.sqlite`. Keeping the payload as
    /// a string makes cursor decoding best-effort: a malformed/newer cursor
    /// cannot make the complete usage cache fail to decode.
    var codexPriorityTurnsCursorPayload: String?
    /// Multi-pass bounded scan that has not finalized global metadata yet.
    var codexPendingScanGeneration: String?
    /// Identifies the admission rules used to build the pending manifest.
    /// Missing means an older writer whose oversized queue cannot be resumed
    /// safely; the scanner will rebuild it from the last committed snapshot.
    var codexPendingManifestContractVersion: Int?
    /// Frozen trace cursor whose Priority turns define this finite episode's
    /// admission and pricing context. Later trace rows belong to a catch-up
    /// episode instead of invalidating already-checkpointed file progress.
    var codexPendingPriorityTurnsCursorPayload: String?
    /// Always-present frozen turn map, including for bounded historical trace
    /// queries that intentionally do not create an incremental SQLite cursor.
    var codexPendingPriorityTurnsPayload: String?
    /// Immutable scan window for the pending episode. A caller may move its
    /// requested window while this episode runs; the episode still finishes
    /// against these bounds before a catch-up episode is seeded.
    var codexPendingScanSinceKey: String?
    var codexPendingScanUntilKey: String?
    /// Wall-clock frontier captured before the immutable manifest was built.
    /// A post-episode warm reconciliation must look back to this timestamp,
    /// not the newly published `lastScanUnixMs`, or writes during a long
    /// multi-pass episode can be skipped.
    var codexPendingManifestCapturedUnixMs: Int64?
    /// One-shot marker for a warm episode whose flat archived roots must be
    /// inventoried again after its immutable snapshot is published.
    var codexPendingNeedsFlatReconciliation: Bool?
    /// Immutable file membership and byte frontier for one bounded episode.
    /// Appends and newly-created files are captured by a later catch-up episode.
    var codexPendingFileManifest: [String: CodexFrozenFile]?
    /// Durable FIFO for the frozen manifest. Dictionaries do not preserve the
    /// scheduling contract: a partial file must move behind every waiter so a
    /// continuously-growing session cannot starve the rest of the generation.
    var codexPendingFileOrder: [String]?
    /// Explicit lane receipt for metadata-only turn-ID work. An empty array is
    /// meaningful: v7 journals never infer this semantic lane after relaunch.
    var codexPendingTurnIDBackfillPaths: [String]?
    /// Flat-root inventory cursors. A key remains until that root reaches EOF;
    /// scanning/pruning starts only after every cursor has drained.
    var codexPendingFlatDiscoveryOffsets: [String: Int64]?
    /// Opaque identity of the live bounded directory cursor plus its replay
    /// position. After an app restart the ordinal can temporarily stay fixed
    /// while the new cursor catches up; this token proves that bounded replay
    /// is advancing so the background no-progress guard does not stop early.
    var codexPendingFlatDiscoveryProgress: [String: String]?
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
        self.codexPendingManifestContractVersion = nil
        self.codexPendingPriorityTurnsCursorPayload = nil
        self.codexPendingPriorityTurnsPayload = nil
        self.codexPendingScanSinceKey = nil
        self.codexPendingScanUntilKey = nil
        self.codexPendingManifestCapturedUnixMs = nil
        self.codexPendingNeedsFlatReconciliation = nil
        self.codexPendingFileManifest = nil
        self.codexPendingFileOrder = nil
        self.codexPendingTurnIDBackfillPaths = nil
        self.codexPendingFlatDiscoveryOffsets = nil
        self.codexPendingFlatDiscoveryProgress = nil
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
    /// Pending-only cursor state for metadata-only turn-ID backfill. A complete
    /// backfill restores the original numeric/parser fields and clears this.
    var codexTurnIDBackfillDiscardingTruncatedLine: Bool? = nil
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
    /// Monotonic high watermark of observed cumulative totals, and whether a drop
    /// below it has latched interleaved mode. Both must survive an incremental
    /// resume, otherwise a fragmented scan recounts the gap that a single-pass
    /// scan contains. Optional so older cached states still decode.
    var rawTotalsWatermark: CostUsageCodexTotals? = nil
    var sawInterleavedTotals: Bool? = nil
    /// Settled counter semantics for a `source: "cli"` fork: true when the
    /// rollout runs its own counter from zero, so the parent's lifetime totals
    /// must not be subtracted. Nil means not classified yet.
    var countsItsOwnTokens: Bool? = nil
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
