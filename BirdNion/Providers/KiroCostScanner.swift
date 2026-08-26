import Foundation
import SQLite3
import Darwin

// MARK: - Models

/// Token/cost rolled up from local Kiro CLI conversation history. Three
/// storage generations are scanned:
///   - `~/.kiro/sessions/cli/<id>.json` — current TUI kiro-cli; per-turn
///     REAL billed credits (`metering_usage`) + context percentages, while
///     the old SQLite tables stay empty.
///   - `~/Library/Application Support/kiro-cli/data.sqlite3` — older CLIs.
///   - `~/.kiro_sessions/*.json` archives (optional).
/// USD is real (credits × Kiro's $0.04 add-on price) for the sessions
/// source; SQLite-era numbers stay estimates (chars÷4 + price table).
struct KiroCostSummary: Equatable, Sendable {
    let todayUSD: Double
    let todayTokens: Int
    let last30USD: Double
    let last30Tokens: Int

    var isEmpty: Bool { todayTokens == 0 && last30Tokens == 0 }
}

struct KiroDailyModel: Equatable, Identifiable, Sendable {
    let name: String
    let usd: Double
    let tokens: Int
    var id: String { name }
}

struct KiroDailyUsage: Equatable, Identifiable, Sendable {
    let date: Date
    let usd: Double
    let tokens: Int
    let models: [KiroDailyModel]
    var id: Date { date }
}

/// Full report for the Kiro tab chart. Shape mirrors `GrokUsageReport`.
struct KiroUsageReport: Equatable, Sendable {
    let todayUSD: Double
    let todayTokens: Int
    let last30USD: Double
    let last30Tokens: Int
    /// Contiguous `chartWindowDays` daily buckets, oldest → newest.
    let daily: [KiroDailyUsage]
    let topModel: String?
    var scanConfidence: CostHistoryStore.UsageScanConfidence = .unavailable

    var isEmpty: Bool {
        last30Tokens == 0 && last30USD <= 0 && todayTokens == 0 && todayUSD <= 0
    }
    var asSummary: KiroCostSummary {
        KiroCostSummary(todayUSD: todayUSD, todayTokens: todayTokens,
                        last30USD: last30USD, last30Tokens: last30Tokens)
    }
}

// MARK: - Pricing

/// Cache-aware Anthropic-style rates ($/MTok) for models Kiro commonly hosts.
/// Write / read / output — 5-minute cache write pricing.
struct KiroModelPrice: Sendable {
    let writePerM: Double
    let readPerM: Double
    let outputPerM: Double

    static func price(for model: String?) -> KiroModelPrice {
        let m = (model ?? "").lowercased()
        if m.contains("opus-4.6") || m.contains("opus-4-6")
            || m.contains("opus-4.5") || m.contains("opus-4-5")
        {
            return KiroModelPrice(writePerM: 6.25, readPerM: 0.50, outputPerM: 25)
        }
        if m.contains("opus") {
            return KiroModelPrice(writePerM: 18.75, readPerM: 1.50, outputPerM: 75)
        }
        if m.contains("sonnet") {
            return KiroModelPrice(writePerM: 3.75, readPerM: 0.30, outputPerM: 15)
        }
        if m.contains("haiku") {
            return KiroModelPrice(writePerM: 1.25, readPerM: 0.10, outputPerM: 5)
        }
        // Default: Opus 4.5 rates so free/unknown models stay visible.
        return KiroModelPrice(writePerM: 6.25, readPerM: 0.50, outputPerM: 25)
    }

    static func estimateUSD(cacheWrite: Int, cacheRead: Int, output: Int, model: String?) -> Double {
        let p = price(for: model)
        return (Double(cacheWrite) * p.writePerM
                + Double(cacheRead) * p.readPerM
                + Double(output) * p.outputPerM) / 1_000_000.0
    }

    /// Kiro bills in credits; add-on/overage credits are $0.04 each
    /// (kiro.dev/pricing) — converts real metered credits to USD.
    static let usdPerCredit = 0.04
}

// MARK: - Scanner

/// Walks Kiro CLI SQLite conversations (+ optional archive) and builds a
/// 120-day daily usage report for the Kiro tab chart.
enum KiroCostScanner {
    private static let cacheTTL: TimeInterval = 300
    static let chartWindowDays = 120
    static let charsPerToken = 4
    static let countingRevision = 2
    private static let countingRevisionKey = "kiroCostCountingRevision"
    private static let maxCLITokensPerField = 10_000_000_000
    private static let maxCLIContextWindowTokens = 10_000_000_000
    private static let maxCLIContextUsagePercentage = 100.0
    private static let maxCLICreditsPerTurn = 1_000_000_000.0
    private static let maxJSONFileBytes = 64 * 1024 * 1024
    private static let maxScanJSONBytes = 256 * 1024 * 1024
    private static let maxRowsPerTable = 20_000
    private static let maxJSONStructureUnits = 100_000
    private static let maxJSONNestingDepth = 64
    private static let maxSemanticLabelBytes = 512
    /// Reserved synthetic model label; real source labels may not claim it.
    static let aggregateModelName = "Other"
    /// Allow minor clock drift without accepting usage from later today.
    private static let maxFutureClockSkew: TimeInterval = 5 * 60

    actor Cache {
        static let shared = Cache()
        private var reportEntry: (at: Date, value: KiroUsageReport)?
        private var generation: UInt = 0
        private var inFlight: (generation: UInt, task: Task<KiroUsageReport?, Never>)?

        func report(
            now: Date,
            ttl: TimeInterval,
            loader: @escaping @Sendable () async -> KiroUsageReport?
        ) async -> KiroUsageReport? {
            if let reportEntry, now.timeIntervalSince(reportEntry.at) < ttl {
                return reportEntry.value
            }
            if let inFlight { return await inFlight.task.value }

            generation &+= 1
            let currentGeneration = generation
            let task = Task<KiroUsageReport?, Never> { await loader() }
            inFlight = (currentGeneration, task)
            let value = await task.value
            if inFlight?.generation == currentGeneration {
                inFlight = nil
                if let value {
                    reportEntry = (now, value)
                }
            }
            return value
        }
    }

    struct ScanResult: Sendable {
        let report: KiroUsageReport
        let completed: Bool
        let availableSources: [String]
        let failures: [String]
    }

    private struct SourceLoad<Value> {
        let values: [Value]
        let available: Bool
        let completed: Bool
    }

    /// Cached full report. Merges with `CostHistoryStore` so cleared sessions
    /// do not wipe past bars.
    static func usageReport(now: Date = Date()) async -> KiroUsageReport? {
        await Cache.shared.report(now: now, ttl: cacheTTL) {
            let incrementalDays = CostHistoryStore.scanBackDays(
                source: .kiro, now: now, maxDays: chartWindowDays)
            let plan = countingScanPlan(
                storedRevision: max(
                    UserDefaults.standard.integer(forKey: countingRevisionKey),
                    CostHistoryStore.storedCountingRevision(source: .kiro)),
                incrementalDays: incrementalDays)
            if plan.historyOnly {
                // A newer app already owns the persisted counting semantics.
                // Do not reinterpret or stamp those days with this build's
                // older revision; surface only the durable history.
                return await seededReport(now: now)
            }
            let scan = await Task.detached(priority: .utility) {
                scanFullResult(now: now, windowDays: plan.windowDays)
            }.value
            let report = mergeLiveReport(
                scan.report,
                now: now,
                replacingSource: plan.replacing,
                liveScanSucceeded: scan.completed)
            if plan.replacing, report.scanConfidence.live {
                UserDefaults.standard.set(countingRevision, forKey: countingRevisionKey)
            }
            return report
        }
    }

    static func countingScanPlan(
        storedRevision: Int,
        incrementalDays: Int
    ) -> (windowDays: Int, replacing: Bool, historyOnly: Bool) {
        if storedRevision > countingRevision {
            return (incrementalDays, false, true)
        }
        let replacing = storedRevision < countingRevision
        return (replacing ? chartWindowDays : incrementalDays, replacing, false)
    }

    static func mergeLiveReport(
        _ live: KiroUsageReport,
        now: Date,
        historyURL: URL = CostHistoryStore.historyURL(),
        replacingSource: Bool = false,
        liveScanSucceeded: Bool = true
    ) -> KiroUsageReport {
        let receipt: CostHistoryStore.ApplyReceipt?
        let window: [CostHistoryStore.DayBucket]
        if liveScanSucceeded {
            let liveDays = live.daily.map {
                ($0.date, $0.usd, $0.tokens,
                 $0.models.map { (name: $0.name, usd: $0.usd, tokens: $0.tokens) })
            }
            let applied = CostHistoryStore.applyWithReceipt(
                source: .kiro,
                liveDays: liveDays,
                now: now,
                windowDays: chartWindowDays,
                url: historyURL,
                replacingSource: replacingSource,
                liveScanSucceeded: true,
                updateTopModel: true,
                topModel: live.topModel,
                countingRevision: countingRevision)
            receipt = applied
            window = applied.window
        } else {
            receipt = nil
            window = CostHistoryStore.window(
                source: .kiro,
                now: now,
                windowDays: chartWindowDays,
                url: historyURL)
        }
        let confidence = CostHistoryStore.confidence(
            source: .kiro,
            liveScanSucceeded: receipt?.persisted == true,
            url: historyURL)
        let persistedTopModel = CostHistoryStore.storedTopModel(
            source: .kiro, url: historyURL)
        return CostHistoryStore.makeKiroReport(
            window: window,
            persistedTopModel: persistedTopModel,
            confidence: confidence)
    }

    /// Instant seed from persisted history — no SQLite scan.
    static func seededReport(now: Date = Date(),
                             url: URL = CostHistoryStore.historyURL()) async -> KiroUsageReport? {
        await Task.detached(priority: .userInitiated) {
            let window = CostHistoryStore.window(
                source: .kiro, now: now, windowDays: chartWindowDays, url: url)
            guard window.contains(where: { $0.tokens > 0 || $0.usd > 0 }) else { return nil }
            let confidence = CostHistoryStore.confidence(
                source: .kiro,
                liveScanSucceeded: false,
                url: url)
            let persistedTopModel = CostHistoryStore.storedTopModel(source: .kiro, url: url)
            return CostHistoryStore.makeKiroReport(
                window: window,
                persistedTopModel: persistedTopModel,
                confidence: confidence)
        }.value
    }

    // MARK: - Paths

    /// Overrideable for tests. Defaults: CLI SQLite + archive dir.
    static func defaultCLIDatabaseURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let macOS = home.appendingPathComponent(
            "Library/Application Support/kiro-cli/data.sqlite3", isDirectory: false)
        let local = home.appendingPathComponent(
            ".local/share/kiro-cli/data.sqlite3", isDirectory: false)
        var candidates = [macOS]
        if let xdg = environment["XDG_DATA_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !xdg.isEmpty,
           (xdg as NSString).isAbsolutePath
        {
            candidates.append(
                URL(fileURLWithPath: xdg).appendingPathComponent("kiro-cli/data.sqlite3"))
        }
        candidates.append(local)
        return candidates.first(where: InstalledAgentDetectors.regularFileExists) ?? macOS
    }

    static func defaultArchiveURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".kiro_sessions", isDirectory: true)
    }

    /// Current TUI kiro-cli session store (`cli/<id>.json` sidecars).
    static func defaultSessionsURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".kiro/sessions", isDirectory: true)
    }

    // MARK: - Session points

    struct SessionPoint: Equatable, Sendable {
        let day: Date
        let tokens: Int
        let usd: Double
        let model: String
    }

    /// Pure filesystem + SQLite scan — unit-testable via path overrides.
    static func scanFull(
        cliDBURL: URL? = nil,
        archiveURL: URL? = nil,
        sessionsURL: URL? = nil,
        fileManager: FileManager = .default,
        now: Date = Date(),
        windowDays: Int = chartWindowDays,
        calendar: Calendar = .current) -> KiroUsageReport
    {
        scanFullResult(
            cliDBURL: cliDBURL,
            archiveURL: archiveURL,
            sessionsURL: sessionsURL,
            fileManager: fileManager,
            now: now,
            windowDays: windowDays,
            calendar: calendar).report
    }

    static func scanFullResult(
        cliDBURL: URL? = nil,
        archiveURL: URL? = nil,
        sessionsURL: URL? = nil,
        fileManager: FileManager = .default,
        now: Date = Date(),
        windowDays: Int = chartWindowDays,
        calendar: Calendar = .current) -> ScanResult
    {
        let home = fileManager.homeDirectoryForCurrentUser
        let db = cliDBURL ?? defaultCLIDatabaseURL(home: home)
        let archive = archiveURL ?? defaultArchiveURL(home: home)
        let sessions = sessionsURL ?? defaultSessionsURL(home: home)
        let loaded = loadPointsResult(
            cliDBURL: db,
            archiveURL: archive,
            sessionsURL: sessions,
            fileManager: fileManager,
            now: now,
            windowDays: windowDays,
            calendar: calendar)
        return ScanResult(
            report: buildReport(
                sessions: loaded.points,
                now: now,
                windowDays: windowDays,
                calendar: calendar),
            completed: !loaded.availableSources.isEmpty && loaded.failures.isEmpty,
            availableSources: loaded.availableSources,
            failures: loaded.failures)
    }

    static func loadPoints(
        cliDBURL: URL,
        archiveURL: URL,
        sessionsURL: URL,
        fileManager: FileManager = .default,
        now: Date = Date(),
        windowDays: Int = chartWindowDays,
        calendar: Calendar = .current) -> [SessionPoint]
    {
        loadPointsResult(
            cliDBURL: cliDBURL,
            archiveURL: archiveURL,
            sessionsURL: sessionsURL,
            fileManager: fileManager,
            now: now,
            windowDays: windowDays,
            calendar: calendar).points
    }

    private static func loadPointsResult(
        cliDBURL: URL,
        archiveURL: URL,
        sessionsURL: URL,
        fileManager: FileManager,
        now: Date,
        windowDays: Int,
        calendar: Calendar
    ) -> (points: [SessionPoint], availableSources: [String], failures: [String]) {
        let startOfToday = calendar.startOfDay(for: now)
        let cutoff = calendar.date(byAdding: .day, value: -(windowDays - 1), to: startOfToday)
            ?? startOfToday.addingTimeInterval(-Double(windowDays) * 86_400)
        let cutoffMs = Int64(cutoff.timeIntervalSince1970 * 1000)
        let latestAcceptedActivity = activityDeadline(now: now)

        // Deduplicate by conversation/session id (prefer newer updated_at).
        var byID: [String: (updated: Int64, points: [SessionPoint])] = [:]
        var availableSources: [String] = []
        var failures: [String] = []
        var scanBytes = 0
        var structureUnits = 0

        let archived = loadArchived(
            archiveURL: archiveURL,
            fileManager: fileManager,
            latestAcceptedActivity: latestAcceptedActivity,
            scanBytes: &scanBytes,
            structureUnits: &structureUnits)
        if archived.available { availableSources.append("archive") }
        var archiveCompleted = archived.completed
        for snap in archived.values {
            guard let cid = snap.conversationID, !cid.isEmpty else { continue }
            guard snap.updatedAtMs >= cutoffMs else { continue }
            guard let points = parseConversation(
                data: snap.value,
                fallbackCreatedMs: snap.createdAtMs,
                cutoff: cutoff,
                now: now,
                calendar: calendar)
            else {
                archiveCompleted = false
                continue
            }
            guard !points.isEmpty else { continue }
            if let existing = byID[cid], existing.updated >= snap.updatedAtMs { continue }
            byID[cid] = (snap.updatedAtMs, points)
        }
        if archived.available, !archiveCompleted { failures.append("archive") }

        let sqlite = loadFromSQLite(
            dbURL: cliDBURL,
            cutoffMs: cutoffMs,
            latestAcceptedActivity: latestAcceptedActivity,
            scanBytes: &scanBytes,
            structureUnits: &structureUnits)
        if sqlite.available { availableSources.append("sqlite") }
        var sqliteCompleted = sqlite.completed
        for snap in sqlite.values {
            guard let cid = snap.conversationID, !cid.isEmpty else { continue }
            guard let points = parseConversation(
                data: snap.value,
                fallbackCreatedMs: snap.createdAtMs,
                cutoff: cutoff,
                now: now,
                calendar: calendar)
            else {
                sqliteCompleted = false
                continue
            }
            guard !points.isEmpty else { continue }
            if let existing = byID[cid], existing.updated >= snap.updatedAtMs { continue }
            byID[cid] = (snap.updatedAtMs, points)
        }
        if sqlite.available, !sqliteCompleted { failures.append("sqlite") }

        // Current TUI kiro-cli: ~/.kiro/sessions/cli/<id>.json sidecars.
        let cli = loadCLISessions(
            sessionsURL: sessionsURL, fileManager: fileManager,
            cutoff: cutoff, cutoffMs: cutoffMs, now: now, calendar: calendar,
            scanBytes: &scanBytes, structureUnits: &structureUnits)
        if cli.available { availableSources.append("cli") }
        if cli.available, !cli.completed { failures.append("cli") }
        for snap in cli.values {
            if let existing = byID[snap.id], existing.updated >= snap.updatedMs { continue }
            byID[snap.id] = (snap.updatedMs, snap.points)
        }

        let points = byID.values.flatMap(\.points)
        var totalTokens = 0
        var totalUSD = 0.0
        for point in points {
            let (nextTokens, overflow) = totalTokens.addingReportingOverflow(point.tokens)
            let nextUSD = totalUSD + point.usd
            guard !overflow, nextUSD.isFinite else {
                return ([], availableSources, failures + ["aggregate"])
            }
            totalTokens = nextTokens
            totalUSD = nextUSD
        }
        return (points, availableSources, failures)
    }

    // MARK: - Sources

    private struct ConversationSnapshot {
        let conversationID: String?
        let createdAtMs: Int64
        let updatedAtMs: Int64
        let value: [String: Any]
    }

    /// Opens the concrete directory entry and reads at most one byte beyond
    /// the active limits. The descriptor stays pinned if the path is replaced,
    /// while `O_NOFOLLOW` prevents a symlink from escaping the scanned root.
    private static func readBoundedJSONFile(_ url: URL, remainingBudget: Int) -> Data? {
        guard remainingBudget >= 0 else { return nil }
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size >= 0,
              metadata.st_size <= maxJSONFileBytes,
              metadata.st_size <= remainingBudget
        else { return nil }

        let readLimit = min(maxJSONFileBytes, remainingBudget)
        guard let data = try? handle.read(upToCount: readLimit + 1),
              data.count <= readLimit
        else { return nil }
        return data
    }

    static func admitSourceBytes(_ length: Int, consumed: inout Int, maximum: Int) -> Bool {
        guard length >= 0, consumed >= 0, consumed <= maximum,
              length <= maximum - consumed
        else { return false }
        consumed += length
        return true
    }

    /// Counts JSON containers and separators without decoding. This bounds
    /// object/array cardinality and nesting before Foundation materializes a
    /// much larger object graph than the raw file.
    private static func admitJSONStructure(_ data: Data, consumed: inout Int) -> Bool {
        guard consumed >= 0, consumed <= maxJSONStructureUnits else { return false }
        var units = 0
        var depth = 0
        var inString = false
        var escaped = false
        for byte in data {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                }
                continue
            }
            if byte == 0x22 {
                inString = true
                continue
            }
            switch byte {
            case 0x7B, 0x5B: // { [
                depth += 1
                guard depth <= maxJSONNestingDepth else { return false }
                units += 1
            case 0x7D, 0x5D: // } ]
                guard depth > 0 else { return false }
                depth -= 1
            case 0x2C: // one additional object member / array element
                units += 1
            default:
                break
            }
            guard units <= maxJSONStructureUnits - consumed else { return false }
        }
        guard !inString, depth == 0 else { return false }
        consumed += units
        return true
    }

    private struct SQLiteFileSnapshot {
        let role: SQLiteFileRole
        let device: UInt64
        let inode: UInt64

        func hasSameIdentity(as other: SQLiteFileSnapshot) -> Bool {
            role == other.role && device == other.device && inode == other.inode
        }
    }

    private enum SQLiteFileRole {
        case database
        case wal
        case shm
    }

    private struct SQLiteStorageSnapshot {
        let files: [SQLiteFileSnapshot]
        let total: Int

        func preservesIdentities(from previous: SQLiteStorageSnapshot) -> Bool {
            previous.files.allSatisfy { old in
                files.contains { $0.hasSameIdentity(as: old) }
            }
        }
    }

    private enum DirectoryEntryState {
        case missing
        case directory
        case invalid
    }

    private static func directoryEntryState(_ url: URL) -> DirectoryEntryState {
        var metadata = stat()
        let result = url.path.withCString { lstat($0, &metadata) }
        guard result == 0 else {
            return errno == ENOENT || errno == ENOTDIR ? .missing : .invalid
        }
        return metadata.st_mode & S_IFMT == S_IFDIR ? .directory : .invalid
    }

    private static func canonicalFileURL(_ url: URL) -> URL? {
        guard let resolved = url.path.withCString({ realpath($0, nil) }) else { return nil }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    private static func sqliteStorageSnapshot(dbURL: URL) -> SQLiteStorageSnapshot? {
        let entries: [(SQLiteFileRole, URL)] = [
            (.database, dbURL),
            (.wal, URL(fileURLWithPath: dbURL.path + "-wal")),
            (.shm, URL(fileURLWithPath: dbURL.path + "-shm")),
        ]
        var total = 0
        var files: [SQLiteFileSnapshot] = []
        for (index, entry) in entries.enumerated() {
            let (role, url) = entry
            var metadata = stat()
            let result = url.path.withCString { lstat($0, &metadata) }
            if result != 0 {
                if index > 0, errno == ENOENT { continue }
                return nil
            }
            guard metadata.st_mode & S_IFMT == S_IFREG,
                  metadata.st_size >= 0,
                  metadata.st_size <= Int64(Int.max)
            else { return nil }
            let size = Int(metadata.st_size)
            let (next, overflow) = total.addingReportingOverflow(size)
            guard !overflow else { return nil }
            total = next
            files.append(SQLiteFileSnapshot(
                role: role,
                device: UInt64(metadata.st_dev),
                inode: UInt64(metadata.st_ino)))
        }
        return SQLiteStorageSnapshot(files: files, total: total)
    }

    private static func reconcileSQLiteStorage(
        previous: SQLiteStorageSnapshot,
        current: SQLiteStorageSnapshot,
        chargedBytes: inout Int,
        scanBytes: inout Int
    ) -> Bool {
        guard current.preservesIdentities(from: previous) else { return false }
        let additional = max(0, current.total - chargedBytes)
        guard additional == 0 || admitSourceBytes(
            additional, consumed: &scanBytes, maximum: maxScanJSONBytes)
        else { return false }
        chargedBytes = max(chargedBytes, current.total)
        return true
    }

    private static func normalizedSemanticLabel(_ raw: String) -> String? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.utf8.count <= maxSemanticLabelBytes,
              !normalized.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        return normalized
    }

    private static func normalizedModelID(_ raw: Any?) -> String? {
        guard let raw else { return "kiro" }
        guard let value = raw as? String else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty { return "kiro" }
        guard normalized != aggregateModelName else { return nil }
        return normalizedSemanticLabel(normalized)
    }

    private static func loadArchived(
        archiveURL: URL,
        fileManager: FileManager,
        latestAcceptedActivity: Date,
        scanBytes: inout Int,
        structureUnits: inout Int
    ) -> SourceLoad<ConversationSnapshot> {
        switch directoryEntryState(archiveURL) {
        case .missing:
            return SourceLoad(values: [], available: false, completed: true)
        case .invalid:
            return SourceLoad(values: [], available: true, completed: false)
        case .directory:
            break
        }
        var enumerationFailed = false
        guard let files = fileManager.enumerator(
            at: archiveURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
            errorHandler: { _, _ in
                enumerationFailed = true
                return false
            })
        else {
            return SourceLoad(values: [], available: true, completed: false)
        }
        var out: [ConversationSnapshot] = []
        var completed = true
        var visitedEntries = 0
        var sawCandidate = false
        for case let url as URL in files {
            guard visitedEntries < maxRowsPerTable else {
                completed = false
                break
            }
            visitedEntries += 1
            guard url.pathExtension == "json" else { continue }
            sawCandidate = true
            guard !Task.isCancelled else {
                completed = false
                break
            }
            guard let data = readBoundedJSONFile(
                url, remainingBudget: maxScanJSONBytes - scanBytes)
            else {
                completed = false
                continue
            }
            guard admitSourceBytes(
                data.count, consumed: &scanBytes, maximum: maxScanJSONBytes)
            else {
                completed = false
                break
            }
            guard admitJSONStructure(data, consumed: &structureUnits) else {
                completed = false
                break
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                completed = false
                continue
            }
            let cid = json["conversation_id"] as? String
            let created: Int64
            if let rawCreated = json["created_at"] {
                guard let timestamp = positiveTimestampMilliseconds(rawCreated),
                      Date(timeIntervalSince1970: Double(timestamp) / 1_000)
                        <= latestAcceptedActivity
                else {
                    completed = false
                    continue
                }
                created = timestamp
            } else {
                created = 0
            }
            guard let rawUpdated = json["updated_at"],
                  let updated = positiveTimestampMilliseconds(rawUpdated),
                  Date(timeIntervalSince1970: Double(updated) / 1_000)
                    <= latestAcceptedActivity
            else {
                completed = false
                continue
            }
            let value: [String: Any]
            if let nested = json["value"] as? [String: Any] {
                value = nested
            } else {
                value = json
            }
            let resolvedID = (cid ?? (value["conversation_id"] as? String))
                .flatMap(normalizedSemanticLabel)
            guard let resolvedID,
                  hasConversationSchema(
                    value, latestAcceptedActivity: latestAcceptedActivity)
            else {
                completed = false
                continue
            }
            out.append(ConversationSnapshot(
                conversationID: resolvedID,
                createdAtMs: created,
                updatedAtMs: updated,
                value: value))
        }
        completed = completed && !enumerationFailed
        return SourceLoad(values: out, available: sawCandidate, completed: completed)
    }

    private static func loadFromSQLite(
        dbURL: URL,
        cutoffMs: Int64,
        latestAcceptedActivity: Date,
        scanBytes: inout Int,
        structureUnits: inout Int
    ) -> SourceLoad<ConversationSnapshot> {
        var databaseMetadata = stat()
        let databaseStatus = dbURL.path.withCString { lstat($0, &databaseMetadata) }
        guard databaseStatus == 0 else {
            if errno == ENOENT || errno == ENOTDIR {
                return SourceLoad(values: [], available: false, completed: true)
            }
            return SourceLoad(values: [], available: true, completed: false)
        }
        guard databaseMetadata.st_mode & S_IFMT == S_IFREG else {
            return SourceLoad(values: [], available: true, completed: false)
        }
        // A WHERE scan can traverse every page even when it returns no rows.
        // Bound the physical DB + WAL/SHM before SQLite starts that work.
        guard let initialStorage = sqliteStorageSnapshot(dbURL: dbURL),
              admitSourceBytes(
                initialStorage.total, consumed: &scanBytes, maximum: maxScanJSONBytes)
        else {
            return SourceLoad(values: [], available: true, completed: false)
        }
        var chargedStorageBytes = initialStorage.total
        // SQLite NOFOLLOW rejects symlinks in any path component (`/var` on
        // macOS included). Resolve only after lstat, then prove role/inode
        // identity before opening the canonical path.
        guard let resolvedDBURL = canonicalFileURL(dbURL) else {
            return SourceLoad(values: [], available: true, completed: false)
        }
        guard let resolvedStorage = sqliteStorageSnapshot(dbURL: resolvedDBURL),
              reconcileSQLiteStorage(
                previous: initialStorage,
                current: resolvedStorage,
                chargedBytes: &chargedStorageBytes,
                scanBytes: &scanBytes)
        else {
            return SourceLoad(values: [], available: true, completed: false)
        }
        var db: OpaquePointer?
        // Read-only still observes committed WAL pages; BUSY/error fails closed.
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW
        guard sqlite3_open_v2(resolvedDBURL.path, &db, flags, nil) == SQLITE_OK,
              let db
        else {
            if db != nil { sqlite3_close(db) }
            return SourceLoad(values: [], available: true, completed: false)
        }
        defer { sqlite3_close(db) }
        guard let openedStorage = sqliteStorageSnapshot(dbURL: resolvedDBURL),
              reconcileSQLiteStorage(
                previous: resolvedStorage,
                current: openedStorage,
                chargedBytes: &chargedStorageBytes,
                scanBytes: &scanBytes)
        else {
            return SourceLoad(values: [], available: true, completed: false)
        }
        sqlite3_busy_timeout(db, 200)

        // conversations_v2 (older kiro-cli)
        // Physical storage is charged to the shared source budget above.
        // Keep a separate decoded-payload guard to avoid counting the same DB
        // pages twice while still bounding materialized JSON.
        var sqlitePayloadBytes = 0
        let v2 = queryConversationsV2(
            db: db,
            cutoffMs: cutoffMs,
            latestAcceptedActivity: latestAcceptedActivity,
            scanBytes: &sqlitePayloadBytes,
            structureUnits: &structureUnits)
        // conversations (kiro-cli 2.0.1+)
        let v1 = queryConversationsV1(
            db: db,
            cutoffMs: cutoffMs,
            latestAcceptedActivity: latestAcceptedActivity,
            scanBytes: &sqlitePayloadBytes,
            structureUnits: &structureUnits)
        let recognizedSchema = (sqliteTableExists(db: db, name: "conversations_v2") == true)
            || (sqliteTableExists(db: db, name: "conversations") == true)
        guard recognizedSchema else {
            return SourceLoad(values: [], available: true, completed: false)
        }
        // Never publish rows if identity changed or storage growth exceeded
        // the shared scan budget while the query was executing.
        guard let finalStorage = sqliteStorageSnapshot(dbURL: resolvedDBURL),
              reconcileSQLiteStorage(
                previous: openedStorage,
                current: finalStorage,
                chargedBytes: &chargedStorageBytes,
                scanBytes: &scanBytes)
        else {
            return SourceLoad(values: [], available: true, completed: false)
        }
        let available = v2.available || v1.available
        return SourceLoad(
            values: v2.values + v1.values,
            available: available,
            completed: v2.completed && v1.completed)
    }

    private static func queryConversationsV2(db: OpaquePointer,
                                             cutoffMs: Int64,
                                             latestAcceptedActivity: Date,
                                             scanBytes: inout Int,
                                             structureUnits: inout Int) -> SourceLoad<ConversationSnapshot> {
        guard let tableExists = sqliteTableExists(db: db, name: "conversations_v2") else {
            return SourceLoad(values: [], available: true, completed: false)
        }
        guard tableExists else {
            return SourceLoad(values: [], available: false, completed: true)
        }
        let sql = """
        SELECT conversation_id, created_at, updated_at, value, length(CAST(value AS BLOB))
        FROM conversations_v2
        WHERE updated_at >= ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt
        else { return SourceLoad(values: [], available: true, completed: false) }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, cutoffMs)
        var out: [ConversationSnapshot] = []
        var completed = true
        var visitedRows = 0
        var sawRow = false
        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            sawRow = true
            guard visitedRows < maxRowsPerTable else {
                completed = false
                break
            }
            visitedRows += 1
            let cid = stringColumn(stmt, 0)
            let created = sqlite3_column_int64(stmt, 1)
            let updated = sqlite3_column_int64(stmt, 2)
            let valueBytes = sqlite3_column_int64(stmt, 4)
            guard sqlite3_column_type(stmt, 1) == SQLITE_INTEGER,
                  sqlite3_column_type(stmt, 2) == SQLITE_INTEGER,
                  created > 0,
                  updated > 0,
                  Date(timeIntervalSince1970: Double(created) / 1_000)
                    <= latestAcceptedActivity,
                  Date(timeIntervalSince1970: Double(updated) / 1_000)
                    <= latestAcceptedActivity,
                  valueBytes >= 0, valueBytes <= Int64(maxJSONFileBytes),
                  let payloadBytes = Int(exactly: valueBytes)
            else {
                completed = false
                step = sqlite3_step(stmt)
                continue
            }
            guard admitSourceBytes(
                payloadBytes, consumed: &scanBytes, maximum: maxScanJSONBytes)
            else {
                completed = false
                break
            }
            guard let raw = stringColumn(stmt, 3),
                  let data = raw.data(using: .utf8),
                  admitJSONStructure(data, consumed: &structureUnits),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cid = cid.flatMap(normalizedSemanticLabel),
                  hasConversationSchema(
                    value, latestAcceptedActivity: latestAcceptedActivity)
            else {
                completed = false
                step = sqlite3_step(stmt)
                continue
            }
            out.append(ConversationSnapshot(
                conversationID: cid,
                createdAtMs: created,
                updatedAtMs: updated,
                value: value))
            step = sqlite3_step(stmt)
        }
        completed = completed && step == SQLITE_DONE
        return SourceLoad(values: out, available: sawRow || !completed, completed: completed)
    }

    private static func queryConversationsV1(db: OpaquePointer,
                                             cutoffMs: Int64,
                                             latestAcceptedActivity: Date,
                                             scanBytes: inout Int,
                                             structureUnits: inout Int) -> SourceLoad<ConversationSnapshot> {
        guard let tableExists = sqliteTableExists(db: db, name: "conversations") else {
            return SourceLoad(values: [], available: true, completed: false)
        }
        guard tableExists else {
            return SourceLoad(values: [], available: false, completed: true)
        }
        let sql = "SELECT value, length(CAST(value AS BLOB)) FROM conversations"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt
        else { return SourceLoad(values: [], available: true, completed: false) }
        defer { sqlite3_finalize(stmt) }
        var out: [ConversationSnapshot] = []
        var completed = true
        var visitedRows = 0
        var sawRow = false
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                completed = false
                break
            }
            sawRow = true
            guard visitedRows < maxRowsPerTable else {
                completed = false
                break
            }
            visitedRows += 1
            let valueBytes = sqlite3_column_int64(stmt, 1)
            guard valueBytes >= 0, valueBytes <= Int64(maxJSONFileBytes),
                  let payloadBytes = Int(exactly: valueBytes)
            else {
                completed = false
                continue
            }
            guard admitSourceBytes(
                payloadBytes, consumed: &scanBytes, maximum: maxScanJSONBytes)
            else {
                completed = false
                break
            }
            guard let raw = stringColumn(stmt, 0),
                  let data = raw.data(using: .utf8),
                  admitJSONStructure(data, consumed: &structureUnits),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                completed = false
                continue
            }
            let cid = (value["conversation_id"] as? String)
                .flatMap(normalizedSemanticLabel)
            guard let cid,
                  hasConversationSchema(
                    value, latestAcceptedActivity: latestAcceptedActivity),
                  let history = value["history"] as? [[String: Any]]
            else {
                completed = false
                continue
            }
            guard !history.isEmpty else { continue }
            let first = (history.first?["request_metadata"] as? [String: Any])
                .flatMap { int64Value($0["request_start_timestamp_ms"]) } ?? 0
            let last = (history.last?["request_metadata"] as? [String: Any])
                .flatMap { int64Value($0["request_start_timestamp_ms"]) } ?? first
            if last > 0, last < cutoffMs { continue }
            out.append(ConversationSnapshot(
                conversationID: cid,
                createdAtMs: first,
                updatedAtMs: last,
                value: value))
        }
        return SourceLoad(values: out, available: sawRow || !completed, completed: completed)
    }

    // MARK: - TUI kiro-cli sessions (~/.kiro/sessions/cli)

    /// Current TUI kiro-cli stores each session as `cli/<id>.json` (metadata +
    /// per-turn metering) next to a `<id>.jsonl` transcript; the old SQLite
    /// tables stay empty on those builds.
    private static func loadCLISessions(
        sessionsURL: URL,
        fileManager: FileManager,
        cutoff: Date,
        cutoffMs: Int64,
        now: Date,
        calendar: Calendar,
        scanBytes: inout Int,
        structureUnits: inout Int
    ) -> SourceLoad<(id: String, updatedMs: Int64, points: [SessionPoint])>
    {
        let cliDir = sessionsURL.appendingPathComponent("cli", isDirectory: true)
        switch directoryEntryState(cliDir) {
        case .missing:
            return SourceLoad(values: [], available: false, completed: true)
        case .invalid:
            return SourceLoad(values: [], available: true, completed: false)
        case .directory:
            break
        }
        var enumerationFailed = false
        guard let files = fileManager.enumerator(
            at: cliDir,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
            errorHandler: { _, _ in
                enumerationFailed = true
                return false
            })
        else {
            return SourceLoad(values: [], available: true, completed: false)
        }
        var out: [(id: String, updatedMs: Int64, points: [SessionPoint])] = []
        var completed = true
        var visitedEntries = 0
        var sawCandidate = false
        for case let url as URL in files {
            guard visitedEntries < maxRowsPerTable else {
                completed = false
                break
            }
            visitedEntries += 1
            guard url.pathExtension == "json" else { continue }
            sawCandidate = true
            guard !Task.isCancelled else {
                completed = false
                break
            }
            guard let data = readBoundedJSONFile(
                url, remainingBudget: maxScanJSONBytes - scanBytes)
            else {
                completed = false
                continue
            }
            guard admitSourceBytes(
                data.count, consumed: &scanBytes, maximum: maxScanJSONBytes)
            else {
                completed = false
                break
            }
            guard admitJSONStructure(data, consumed: &structureUnits) else {
                completed = false
                break
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                completed = false
                continue
            }
            let sid: String?
            if let rawID = json["session_id"] {
                sid = (rawID as? String).flatMap(normalizedSemanticLabel)
            } else {
                sid = normalizedSemanticLabel(url.deletingPathExtension().lastPathComponent)
            }
            guard let sid, hasCLISessionSchema(json, now: now, calendar: calendar) else {
                completed = false
                continue
            }
            guard let updatedMs = cliSidecarActivityMilliseconds(
                json, now: now, calendar: calendar)
            else {
                completed = false
                continue
            }
            if updatedMs > 0, updatedMs < cutoffMs { continue }
            let points = parseCLISessionSidecar(
                json, cutoff: cutoff, now: now, calendar: calendar)
            guard !points.isEmpty else { continue }
            out.append((sid, updatedMs, points))
        }
        completed = completed && !enumerationFailed
        return SourceLoad(values: out, available: sawCandidate, completed: completed)
    }

    private static func cliSidecarActivityMilliseconds(
        _ value: [String: Any],
        now: Date,
        calendar: Calendar
    ) -> Int64? {
        let latestAcceptedActivity = activityDeadline(now: now)
        if let rawUpdated = value["updated_at"] {
            guard let updated = rawUpdated as? String,
                  let parsed = parseISODate(updated), parsed <= latestAcceptedActivity
            else { return nil }
            return Int64(parsed.timeIntervalSince1970 * 1_000)
        }

        var candidates: [Date] = []
        if let rawCreated = value["created_at"] {
            guard let created = rawCreated as? String,
                  let parsed = parseISODate(created), parsed <= latestAcceptedActivity
            else { return nil }
            candidates.append(parsed)
        }
        let turns = ((value["session_state"] as? [String: Any])?["conversation_metadata"]
            as? [String: Any])?["user_turn_metadatas"] as? [[String: Any]] ?? []
        for turn in turns where turn.keys.contains("end_timestamp") {
            guard let timestamp = turn["end_timestamp"] as? String,
                  let parsed = parseISODate(timestamp), parsed <= latestAcceptedActivity
            else { return nil }
            candidates.append(parsed)
        }
        return candidates.max().map { Int64($0.timeIntervalSince1970 * 1_000) } ?? 0
    }

    private static let cliIntegerTurnKeys = [
        "input_token_count",
        "output_token_count",
    ]

    /// These names have no verified parser contract. Reject them explicitly so
    /// schema drift cannot be reported as a successful zero-usage scan.
    private static let unsupportedCLITurnKeys = [
        "input_tokens_count",
        "output_tokens_count",
        "cache_read_input_token_count",
        "cache_creation_input_token_count",
        "cache_read_input_tokens_count",
        "cache_creation_input_tokens_count",
    ]

    private static let conversationTurnIdentityKeys = [
        "user",
        "assistant",
        "request_metadata",
    ]

    private static func hasCLISessionSchema(
        _ value: [String: Any],
        now: Date,
        calendar: Calendar
    ) -> Bool {
        guard let state = value["session_state"] as? [String: Any],
              let metadata = state["conversation_metadata"] as? [String: Any],
              let turns = metadata["user_turn_metadatas"] as? [Any],
              !turns.isEmpty
        else { return false }
        let latestAcceptedActivity = activityDeadline(now: now)
        let sessionCreated: Date?
        if let rawCreated = value["created_at"] {
            guard let created = rawCreated as? String,
                  let parsed = parseISODate(created),
                  parsed <= latestAcceptedActivity
            else { return false }
            sessionCreated = parsed
        } else {
            sessionCreated = nil
        }
        if let modelInfo = (state["rts_model_state"] as? [String: Any])?["model_info"]
            as? [String: Any]
        {
            guard normalizedModelID(modelInfo["model_id"]) != nil else { return false }
            if let contextWindow = modelInfo["context_window_tokens"],
               boundedNonnegativeInteger(
                   contextWindow, maximum: maxCLIContextWindowTokens) == nil
            {
                return false
            }
        }
        return turns.allSatisfy { rawTurn in
            guard let turn = rawTurn as? [String: Any] else { return false }
            return hasSemanticCLITurn(
                turn,
                fallbackActiveAt: sessionCreated,
                latestAcceptedActivity: latestAcceptedActivity)
        }
    }

    private static func hasConversationSchema(
        _ value: [String: Any],
        latestAcceptedActivity: Date
    ) -> Bool {
        guard let history = value["history"] as? [Any], !history.isEmpty else { return false }
        return history.allSatisfy { rawTurn in
            guard let turn = rawTurn as? [String: Any] else { return false }
            var recognized = false
            for key in conversationTurnIdentityKeys where turn.keys.contains(key) {
                let field = turn[key]
                if key == "request_metadata" {
                    guard let metadata = field as? [String: Any] else { return false }
                    if let rawTimestamp = metadata["request_start_timestamp_ms"] {
                        guard let timestamp = positiveTimestampMilliseconds(rawTimestamp),
                              Date(timeIntervalSince1970: Double(timestamp) / 1_000)
                                <= latestAcceptedActivity
                        else { return false }
                    }
                    if let model = metadata["model_id"] {
                        guard normalizedModelID(model) != nil
                        else { return false }
                    }
                    if let chunks = metadata["time_between_chunks"] {
                        guard let chunks = chunks as? [Any] else { return false }
                        recognized = recognized || !chunks.isEmpty
                    }
                } else {
                    guard isConversationContentContainer(field) else { return false }
                    recognized = recognized || hasMeaningfulConversationContent(field)
                }
            }
            return recognized
        }
    }

    private static func isConversationContentContainer(_ value: Any?) -> Bool {
        value is String || value is [Any] || value is [String: Any]
    }

    private static func hasMeaningfulConversationContent(_ value: Any?) -> Bool {
        switch value {
        case let text as String:
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case let values as [Any]:
            return values.contains(where: hasMeaningfulConversationContent)
        case let values as [String: Any]:
            return values.values.contains(where: hasMeaningfulConversationContent)
        default:
            return false
        }
    }

    private static func hasSemanticCLITurn(
        _ turn: [String: Any],
        fallbackActiveAt: Date?,
        latestAcceptedActivity: Date
    ) -> Bool {
        guard !unsupportedCLITurnKeys.contains(where: turn.keys.contains) else { return false }
        var recognized = false
        var hasUsage = false
        var activeAt = fallbackActiveAt
        if let timestamp = turn["end_timestamp"] {
            recognized = true
            guard let timestamp = timestamp as? String,
                  let parsed = parseISODate(timestamp),
                  parsed <= latestAcceptedActivity
            else { return false }
            activeAt = parsed
        }
        for key in cliIntegerTurnKeys where turn.keys.contains(key) {
            recognized = true
            guard let tokens = boundedNonnegativeInteger(
                turn[key], maximum: maxCLITokensPerField)
            else { return false }
            hasUsage = hasUsage || tokens > 0
        }
        if let percentage = turn["context_usage_percentage"] {
            recognized = true
            guard let value = boundedNonnegativeNumber(
                percentage, maximum: maxCLIContextUsagePercentage)
            else { return false }
            hasUsage = hasUsage || value > 0
        }
        if let usage = turn["metering_usage"] {
            recognized = true
            var billedCredits = 0.0
            guard let entries = usage as? [Any], entries.allSatisfy({ rawEntry in
                guard let entry = rawEntry as? [String: Any],
                      let unit = entry["unit"] as? String,
                      !unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let value = boundedNonnegativeNumber(
                          entry["value"], maximum: maxCLICreditsPerTurn)
                else { return false }
                guard unit.localizedCaseInsensitiveContains("credit") else { return true }
                guard billedCredits <= maxCLICreditsPerTurn - value else { return false }
                billedCredits += value
                hasUsage = hasUsage || value > 0
                return true
            }) else { return false }
        }
        return recognized && (!hasUsage || activeAt != nil)
    }

    private static func boundedNonnegativeInteger(_ raw: Any?, maximum: Int) -> Int? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value >= 0, value <= Double(maximum),
              value.rounded(.towardZero) == value
        else { return nil }
        return Int(value)
    }

    private static func boundedNonnegativeNumber(_ raw: Any?, maximum: Double) -> Double? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let value = number.doubleValue
        return value.isFinite && value >= 0 && value <= maximum ? value : nil
    }

    /// One sidecar → per-day SessionPoints. USD is REAL (per-turn
    /// `metering_usage` credits × $0.04); tokens prefer the CLI's exact
    /// counts and fall back to context-window growth
    /// (Δ`context_usage_percentage` × window size) when they are zeroed.
    static func parseCLISessionSidecar(
        _ json: [String: Any],
        cutoff: Date,
        now: Date = Date(),
        calendar: Calendar = .current) -> [SessionPoint]
    {
        guard hasCLISessionSchema(json, now: now, calendar: calendar),
              let state = json["session_state"] as? [String: Any],
              let convMeta = state["conversation_metadata"] as? [String: Any],
              let turns = convMeta["user_turn_metadatas"] as? [[String: Any]],
              !turns.isEmpty
        else { return [] }

        let modelInfo = (state["rts_model_state"] as? [String: Any])?["model_info"] as? [String: Any]
        guard let model = normalizedModelID(modelInfo?["model_id"]) else { return [] }
        let rawWindow = boundedNonnegativeInteger(
            modelInfo?["context_window_tokens"], maximum: maxCLIContextWindowTokens) ?? 0
        let contextWindow = rawWindow > 0 ? rawWindow : 200_000

        let sessionCreated = parseISODate(json["created_at"] as? String)

        var prevPct = 0.0
        var buckets: [Date: (tokens: Int, usd: Double)] = [:]
        for turn in turns {
            // Real billed credits for the turn (one entry per request).
            var credits = 0.0
            for entry in (turn["metering_usage"] as? [[String: Any]] ?? []) {
                let unit = (entry["unit"] as? String ?? "").lowercased()
                guard unit.contains("credit") else { continue }
                guard let value = boundedNonnegativeNumber(
                    entry["value"], maximum: maxCLICreditsPerTurn),
                    credits <= maxCLICreditsPerTurn - value
                else { return [] }
                credits += value
            }
            let usd = credits * KiroModelPrice.usdPerCredit
            guard usd.isFinite else { return [] }

            // Exact token counts when the CLI populates them; else grow-of-
            // context estimate. `context_usage_percentage` is cumulative, so
            // the per-turn delta is what this turn added (clamped: compaction
            // can shrink it).
            let inputTokens = boundedNonnegativeInteger(
                turn["input_token_count"], maximum: maxCLITokensPerField) ?? 0
            let outputTokens = boundedNonnegativeInteger(
                turn["output_token_count"], maximum: maxCLITokensPerField) ?? 0
            let (exactTokens, tokenOverflow) = inputTokens.addingReportingOverflow(outputTokens)
            guard !tokenOverflow else { return [] }
            var tokens = exactTokens
            let pct = boundedNonnegativeNumber(
                turn["context_usage_percentage"], maximum: maxCLIContextUsagePercentage) ?? 0
            if tokens == 0, pct > 0 {
                let delta = max(0, pct - prevPct)
                tokens = Int((delta / 100.0 * Double(contextWindow)).rounded())
            }
            if pct > 0 { prevPct = pct }

            guard let activeAt = parseISODate(turn["end_timestamp"] as? String) ?? sessionCreated,
                  activeAt <= activityDeadline(now: now)
            else { continue }
            let day = calendar.startOfDay(for: activeAt)
            guard day >= calendar.startOfDay(for: cutoff) else { continue }
            guard tokens > 0 || usd > 0 else { continue }

            var acc = buckets[day] ?? (0, 0)
            let (dayTokens, dayTokenOverflow) = acc.tokens.addingReportingOverflow(tokens)
            let dayUSD = acc.usd + usd
            guard !dayTokenOverflow, dayUSD.isFinite else { return [] }
            acc.tokens = dayTokens
            acc.usd = dayUSD
            buckets[day] = acc
        }

        return buckets.map {
            SessionPoint(day: $0.key, tokens: $0.value.tokens, usd: $0.value.usd, model: model)
        }
    }

    /// ISO8601 with or without fractional seconds ("2026-07-15T06:20:44.636576Z").
    static func parseISODate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: raw) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: raw)
    }

    private static func activityDeadline(now: Date) -> Date {
        now.addingTimeInterval(maxFutureClockSkew)
    }

    private static func doubleValue(_ raw: Any?) -> Double {
        switch raw {
        case let d as Double: return d
        case let n as NSNumber: return n.doubleValue
        case let i as Int: return Double(i)
        case let s as String: return Double(s) ?? 0
        default: return 0
        }
    }

    // MARK: - Parse conversation turns

    /// Expand one conversation into per-day SessionPoints (one per model/day).
    static func parseConversation(
        data: [String: Any],
        fallbackCreatedMs: Int64,
        cutoff: Date,
        now: Date = Date(),
        calendar: Calendar = .current) -> [SessionPoint]?
    {
        let turns = data["history"] as? [[String: Any]] ?? []
        guard !turns.isEmpty else { return [] }

        // Compact summary is re-sent after compaction — seed cumulative cache.
        let summary = data["latest_summary"]
        var cumulative = textTokenEstimate(summary)
        var prevAsst = 0

        // day → model → (tokens, usd)
        var buckets: [Date: [String: (tokens: Int, usd: Double)]] = [:]

        for (i, turn) in turns.enumerated() {
            let meta = turn["request_metadata"] as? [String: Any] ?? [:]
            guard let modelName = normalizedModelID(meta["model_id"]) else { return nil }

            let userTok = textTokenEstimate(turn["user"]) + imageTokenEstimate(turn["user"])
            let asstTok = textTokenEstimate(turn["assistant"])
            // Output tokens: accurate chunk count when present.
            let outTok: Int
            if let chunks = meta["time_between_chunks"] as? [Any] {
                outTok = chunks.count
            } else {
                outTok = asstTok
            }

            let cr = i > 0 ? cumulative : 0
            let cw = userTok + (i > 0 ? prevAsst : 0)
            let totalTokens = cw + cr + outTok
            let usd = KiroModelPrice.estimateUSD(
                cacheWrite: cw, cacheRead: cr, output: outTok, model: modelName)

            cumulative += userTok + asstTok
            prevAsst = asstTok

            guard totalTokens > 0 || usd > 0 else { continue }
            let activeAt: Date
            if let rawTimestamp = meta["request_start_timestamp_ms"] {
                guard let tsMs = positiveTimestampMilliseconds(rawTimestamp) else { return nil }
                activeAt = Date(timeIntervalSince1970: Double(tsMs) / 1000.0)
            } else if fallbackCreatedMs > 0 {
                activeAt = Date(timeIntervalSince1970: Double(fallbackCreatedMs) / 1000.0)
            } else {
                return nil
            }
            guard activeAt <= activityDeadline(now: now) else { return nil }
            let day = calendar.startOfDay(for: activeAt)
            guard day >= calendar.startOfDay(for: cutoff) else { continue }

            var models = buckets[day] ?? [:]
            var acc = models[modelName] ?? (0, 0)
            acc.tokens += totalTokens
            acc.usd += usd
            models[modelName] = acc
            buckets[day] = models
        }

        var points: [SessionPoint] = []
        for (day, models) in buckets {
            for (model, stats) in models where stats.tokens > 0 || stats.usd > 0 {
                points.append(SessionPoint(
                    day: day, tokens: stats.tokens, usd: stats.usd, model: model))
            }
        }
        return points
    }

    // MARK: - Report build

    static func buildReport(
        sessions: [SessionPoint],
        now: Date = Date(),
        windowDays: Int = chartWindowDays,
        calendar: Calendar = .current) -> KiroUsageReport
    {
        let startOfToday = calendar.startOfDay(for: now)
        final class Acc {
            var usd: Double = 0
            var tokens: Int = 0
            var models: [String: (usd: Double, tokens: Int)] = [:]
        }
        var buckets: [Date: Acc] = [:]
        for s in sessions {
            let day = calendar.startOfDay(for: s.day)
            let acc = buckets[day] ?? Acc()
            acc.usd += s.usd
            acc.tokens += s.tokens
            var m = acc.models[s.model] ?? (0, 0)
            m.usd += s.usd
            m.tokens += s.tokens
            acc.models[s.model] = m
            buckets[day] = acc
        }

        // Rank the full 30-day model set before bounding each day's chart
        // payload. Otherwise a steady sixth-place model can disappear from
        // every day even when it is the true top model across the month.
        let last30Start = calendar.date(
            byAdding: .day, value: -29, to: startOfToday) ?? startOfToday
        var fullModelTotals: [String: (usd: Double, tokens: Int)] = [:]
        for (day, acc) in buckets where day >= last30Start && day <= startOfToday {
            for (name, stats) in acc.models where stats.tokens > 0 || stats.usd > 0 {
                var total = fullModelTotals[name] ?? (0, 0)
                total.usd += stats.usd
                total.tokens += stats.tokens
                fullModelTotals[name] = total
            }
        }
        let topModel = fullModelTotals.max { lhs, rhs in
            if lhs.value.tokens != rhs.value.tokens {
                return lhs.value.tokens < rhs.value.tokens
            }
            if lhs.value.usd != rhs.value.usd {
                return lhs.value.usd < rhs.value.usd
            }
            return lhs.key > rhs.key
        }?.key

        var daily: [KiroDailyUsage] = []
        daily.reserveCapacity(windowDays)
        for offset in stride(from: windowDays - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: startOfToday)
            else { continue }
            let acc = buckets[day]
            var dayModels: [KiroDailyModel] = []
            if let models = acc?.models {
                var allModels = models.compactMap { name, stats in
                    stats.tokens > 0 || stats.usd > 0
                        ? KiroDailyModel(name: name, usd: stats.usd, tokens: stats.tokens)
                        : nil
                }
                // Token-first ranking (matches All chart preference).
                allModels.sort { lhs, rhs in
                    if lhs.tokens == rhs.tokens {
                        if lhs.usd == rhs.usd { return lhs.name < rhs.name }
                        return lhs.usd > rhs.usd
                    }
                    return lhs.tokens > rhs.tokens
                }
                dayModels = Array(allModels.prefix(5))
                if let topModel,
                   let globalTop = allModels.first(where: { $0.name == topModel }),
                   !dayModels.contains(where: { $0.name == topModel })
                {
                    dayModels.append(globalTop)
                }

                let selectedNames = Set(dayModels.map(\.name))
                let omitted = allModels.filter { !selectedNames.contains($0.name) }
                if !omitted.isEmpty {
                    dayModels.append(KiroDailyModel(
                        name: aggregateModelName,
                        usd: omitted.map(\.usd).reduce(0, +),
                        tokens: omitted.map(\.tokens).reduce(0, +)))
                }
            }
            daily.append(KiroDailyUsage(
                date: day,
                usd: acc?.usd ?? 0,
                tokens: acc?.tokens ?? 0,
                models: dayModels))
        }

        let last30 = daily.suffix(30)
        let todayBucket = daily.last

        return KiroUsageReport(
            todayUSD: todayBucket?.usd ?? 0,
            todayTokens: todayBucket?.tokens ?? 0,
            last30USD: last30.map(\.usd).reduce(0, +),
            last30Tokens: last30.map(\.tokens).reduce(0, +),
            daily: daily,
            topModel: topModel)
    }

    // MARK: - Text / token helpers

    /// Approximate tokens from textual content (UTF-8 bytes ÷ 4), excluding base64 images.
    static func textTokenEstimate(_ field: Any?) -> Int {
        guard let field else { return 0 }
        if let s = field as? String {
            return max(0, s.utf8.count / charsPerToken)
        }
        if let dict = field as? [String: Any] {
            var total = 0
            for (k, v) in dict where k != "images" {
                total += textTokenEstimate(v)
            }
            return total
        }
        if let arr = field as? [Any] {
            return arr.reduce(0) { $0 + textTokenEstimate($1) }
        }
        // Numbers / bools — ignore
        if field is NSNumber { return 0 }
        return max(0, "\(field)".utf8.count / charsPerToken)
    }

    /// Rough vision tokens for images (~1600 each when dimensions unknown).
    static func imageTokenEstimate(_ field: Any?) -> Int {
        guard let dict = field as? [String: Any],
              let images = dict["images"] as? [Any], !images.isEmpty
        else { return 0 }
        return images.count * 1600
    }

    private static func stringColumn(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        guard let cStr = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: cStr)
    }

    private static func sqliteTableExists(db: OpaquePointer, name: String) -> Bool? {
        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = '\(name)' LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt
        else { return nil }
        defer { sqlite3_finalize(stmt) }
        switch sqlite3_step(stmt) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: return nil
        }
    }

    private static func int64Value(_ raw: Any?) -> Int64 {
        switch raw {
        case let i as Int: return Int64(i)
        case let i as Int64: return i
        case let n as NSNumber: return n.int64Value
        case let d as Double: return Int64(d)
        case let s as String: return Int64(s) ?? 0
        default: return 0
        }
    }

    private static func positiveTimestampMilliseconds(_ raw: Any) -> Int64? {
        if let value = raw as? String {
            guard let timestamp = Int64(value), timestamp > 0 else { return nil }
            return timestamp
        }
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let value = number.doubleValue
        guard value.isFinite,
              value > 0,
              value < Double(Int64.max),
              value.rounded(.towardZero) == value
        else { return nil }
        return Int64(value)
    }
}
