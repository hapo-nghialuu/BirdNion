import Foundation
import Darwin

/// One model's slice of a single Devin CLI day.
struct DevinCLIDailyModel: Equatable, Identifiable, Sendable {
    let name: String
    let usd: Double
    let tokens: Int
    var id: String { name }
}

/// One calendar day (local tz) of Devin CLI usage.
struct DevinCLIDailyUsage: Equatable, Identifiable, Sendable {
    let date: Date
    let usd: Double
    let tokens: Int
    let models: [DevinCLIDailyModel]
    var id: Date { date }
}

/// Full report for the Devin CLI usage chart / All-tab cost row.
struct DevinCLIUsageReport: Equatable, Sendable {
    let todayUSD: Double
    let todayTokens: Int
    let last30USD: Double
    let last30Tokens: Int
    let daily: [DevinCLIDailyUsage]
    let topModel: String?
    var scanConfidence: CostHistoryStore.UsageScanConfidence = .unavailable

    var isEmpty: Bool { last30Tokens == 0 && todayTokens == 0 }
}

/// Rolls up Devin CLI token usage from local session transcripts at
/// `~/.local/share/devin/cli/transcripts/<session>.json`.
///
/// Each transcript carries `steps[]` with an RFC3339 `timestamp`, a
/// `model_name`, and `metrics.prompt_tokens` / `completion_tokens` /
/// `cached_tokens`. `cached_tokens` is a subset of `prompt_tokens` (verified
/// against `final_metrics` on real transcripts), so a step's token count is
/// prompt + completion — adding cached would double count.
///
/// USD is estimated at the per-token API rates Devin publishes on
/// docs.devin.ai/desktop/models (`input/output/cache_read` per million —
/// the same rates billed for usage beyond plan quota). Models missing
/// from the table keep `usd = 0`; tokens are still counted and the UI
/// falls back to showing them.
enum DevinCostScanner {

    static let chartWindowDays = 120
    /// Bump when the counting formula changes — same migration rule as the
    /// other scanners (`CostHistoryStore` never shrinks a day on its own).
    /// 2 = first revision carrying per-model USD estimates.
    static let countingRevision = 2
    private static let countingRevisionKey = "devinCostCountingRevision"
    private static let cacheTTL: TimeInterval = 300 // 5 minutes
    static let maxTranscriptFileBytes = 64 * 1024 * 1024
    static let maxScanReadBytes = 256 * 1024 * 1024
    static let maxScanDirectoryEntries = 20_000
    static let maxScanReadFiles = 10_000
    static let maxTranscriptSteps = 100_000
    static let maxModelNameScalars = 64

    private actor Cache {
        static let shared = Cache()

        struct Key: Hashable, Sendable {
            let historyPath: String
            let transcriptsPath: String
        }

        enum Lookup: Sendable {
            case cached(DevinCLIUsageReport)
            case operation(
                task: Task<DevinCLIUsageReport, Never>,
                generation: UInt,
                owner: Bool)
        }

        private var reportEntries: [Key: (at: Date, value: DevinCLIUsageReport)] = [:]
        private var inFlight: [Key: (generation: UInt, task: Task<DevinCLIUsageReport, Never>)] = [:]
        private var generation: UInt = 0

        func lookup(
            key: Key,
            now: Date,
            ttl: TimeInterval,
            forceRescan: Bool,
            loader: @escaping @Sendable () async -> DevinCLIUsageReport
        ) -> Lookup {
            if !forceRescan,
               let entry = reportEntries[key],
               now.timeIntervalSince(entry.at) < ttl {
                return .cached(entry.value)
            }
            if let operation = inFlight[key] {
                return .operation(
                    task: operation.task,
                    generation: operation.generation,
                    owner: false)
            }

            generation &+= 1
            let currentGeneration = generation
            let task = Task { await loader() }
            inFlight[key] = (currentGeneration, task)
            return .operation(task: task, generation: currentGeneration, owner: true)
        }

        func finish(
            key: Key,
            generation: UInt,
            value: DevinCLIUsageReport,
            cacheable: Bool,
            at: Date
        ) {
            guard inFlight[key]?.generation == generation else { return }
            inFlight[key] = nil
            if cacheable {
                reportEntries[key] = (at, value)
            }
        }
    }

    /// Report built purely from persisted history — instant seed while the
    /// live scan runs in the background (same pattern as `PiCostScanner`).
    static func seededReport(
        now: Date = Date(),
        calendar: Calendar = .current,
        url: URL = CostHistoryStore.historyURL()
    ) async -> DevinCLIUsageReport? {
        await Task.detached(priority: .userInitiated) {
            let window = CostHistoryStore.window(
                source: .devin, now: now, calendar: calendar,
                windowDays: chartWindowDays, url: url)
            guard window.contains(where: { $0.tokens > 0 || $0.usd > 0 }) else { return nil }
            let confidence = CostHistoryStore.confidence(
                source: .devin, liveScanSucceeded: false, url: url)
            return CostHistoryStore.makeDevinReport(window: window, confidence: confidence)
        }.value
    }

    // MARK: - Path resolution

    /// `~/.local/share/devin/cli/transcripts` — the CLI's session transcript
    /// directory. `DEVIN_CLI_TRANSCRIPTS_DIR` overrides for tests/tools.
    static var defaultTranscriptsDirectory: URL {
        if let custom = ProcessInfo.processInfo.environment["DEVIN_CLI_TRANSCRIPTS_DIR"],
           !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("devin", isDirectory: true)
            .appendingPathComponent("cli", isDirectory: true)
            .appendingPathComponent("transcripts", isDirectory: true)
    }

    // MARK: - Public API

    /// Same revision/plan contract as `PiCostScanner.countingScanPlan`.
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

    static func loadReport(
        now: Date = Date(),
        calendar: Calendar = .current,
        forceRescan: Bool = false,
        historyURL: URL = CostHistoryStore.historyURL(),
        transcriptsRoot: URL? = nil
    ) async -> DevinCLIUsageReport {
        let root = transcriptsRoot ?? defaultTranscriptsDirectory
        let cacheKey = Cache.Key(
            historyPath: historyURL.standardizedFileURL.path,
            transcriptsPath: root.standardizedFileURL.path)
        let lookup = await Cache.shared.lookup(
            key: cacheKey,
            now: now,
            ttl: cacheTTL,
            forceRescan: forceRescan
        ) {
            await loadUncachedReport(
                now: now,
                calendar: calendar,
                historyURL: historyURL,
                root: root)
        }
        switch lookup {
        case .cached(let report):
            return report
        case .operation(let task, let generation, let owner):
            let report = await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                // Only the caller that created the shared operation owns its
                // cancellation. A canceled follower must not abort other users.
                if owner { task.cancel() }
            }
            await Cache.shared.finish(
                key: cacheKey,
                generation: generation,
                value: report,
                cacheable: !task.isCancelled && report.scanConfidence.live,
                at: now)
            return report
        }
    }

    private static func loadUncachedReport(
        now: Date,
        calendar: Calendar,
        historyURL: URL,
        root: URL
    ) async -> DevinCLIUsageReport {
        guard !Task.isCancelled else {
            return historyOnlyReport(now: now, calendar: calendar, historyURL: historyURL)
        }
        var isDir: ObjCBool = false
        guard isDirectoryWithoutFollowingSymlink(root),
              FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir),
              isDir.boolValue else {
            let window = CostHistoryStore.apply(
                source: .devin,
                liveDays: [],
                now: now,
                calendar: calendar,
                windowDays: chartWindowDays,
                url: historyURL,
                liveScanSucceeded: false)
            let confidence = CostHistoryStore.confidence(source: .devin, liveScanSucceeded: false, url: historyURL)
            return CostHistoryStore.makeDevinReport(window: window, confidence: confidence)
        }

        let storedRevision = max(
            UserDefaults.standard.integer(forKey: countingRevisionKey),
            CostHistoryStore.storedCountingRevision(source: .devin, url: historyURL))
        let scanBackPlan = CostHistoryStore.scanBackPlan(
            source: .devin,
            now: now,
            calendar: calendar,
            minDays: CostHistoryStore.routineScanDays,
            maxDays: chartWindowDays,
            url: historyURL)
        let plan = countingScanPlan(
            storedRevision: storedRevision, incrementalDays: scanBackPlan.days)
        if plan.historyOnly {
            let window = CostHistoryStore.window(
                source: .devin,
                now: now,
                calendar: calendar,
                windowDays: chartWindowDays,
                url: historyURL)
            let confidence = CostHistoryStore.confidence(
                source: .devin, liveScanSucceeded: false, url: historyURL)
            return CostHistoryStore.makeDevinReport(window: window, confidence: confidence)
        }

        let scanTask = Task.detached(priority: .utility) {
            scanTranscripts(
                root: root, scanDays: plan.windowDays,
                now: now, calendar: calendar)
        }
        let result = await withTaskCancellationHandler {
            await scanTask.value
        } onCancel: {
            scanTask.cancel()
        }

        // Cancellation may arrive after the final filesystem read. Never let
        // that partial pass persist, replace, stamp LIVE, or advance cadence.
        guard !Task.isCancelled, !scanTask.isCancelled else {
            return historyOnlyReport(now: now, calendar: calendar, historyURL: historyURL)
        }

        let liveDays = result.dailyBuckets.map {
            ($0.date, $0.usd, $0.tokens,
             $0.models.map { (name: $0.name, usd: $0.usd, tokens: $0.tokens) })
        }
        let applied = CostHistoryStore.applyWithReceipt(
            source: .devin,
            liveDays: liveDays,
            now: now,
            calendar: calendar,
            windowDays: chartWindowDays,
            url: historyURL,
            replacingSource: plan.replacing && result.completed,
            liveScanSucceeded: result.completed,
            countingRevision: countingRevision)
        if result.completed, applied.persisted {
            UserDefaults.standard.set(countingRevision, forKey: countingRevisionKey)
            if scanBackPlan.isDeep {
                CostHistoryStore.markDeepScanSucceeded(
                    source: .devin, at: now, url: historyURL)
            }
        }
        let confidence = CostHistoryStore.confidence(
            source: .devin,
            liveScanSucceeded: result.completed && applied.persisted,
            url: historyURL)
        let report = CostHistoryStore.makeDevinReport(window: applied.window, confidence: confidence)
        return report
    }

    private static func historyOnlyReport(
        now: Date,
        calendar: Calendar,
        historyURL: URL
    ) -> DevinCLIUsageReport {
        let window = CostHistoryStore.window(
            source: .devin,
            now: now,
            calendar: calendar,
            windowDays: chartWindowDays,
            url: historyURL)
        let confidence = CostHistoryStore.confidence(
            source: .devin, liveScanSucceeded: false, url: historyURL)
        return CostHistoryStore.makeDevinReport(window: window, confidence: confidence)
    }

    // MARK: - Scanner

    struct ScanResult: Equatable, Sendable {
        let dailyBuckets: [CostHistoryStore.DayBucket]
        /// `false` when any transcript failed to read/parse or a budget cap
        /// was hit — partial results still merge, but never claim LIVE.
        let completed: Bool
    }

    /// Per-token USD rates (per million) keyed by transcript `model_name`
    /// (= Devin's `model_uid`). Source: the `modelCostData` table on
    /// docs.devin.ai/desktop/models — `TEAMS_TIER_ENTERPRISE_SAAS` carries
    /// the real API prices that apply once plan quota is exhausted.
    private static let modelRates: [String: (input: Double, output: Double, cacheRead: Double)] = [
        "swe-2-max": (0.75, 3.75, 0.075),
        "swe-2-high": (0.75, 3.75, 0.075),
        "swe-2-medium": (0.75, 3.75, 0.075),
        "swe-1-7": (0.5, 2.5, 0.2),
        "swe-1-7-medium": (0.5, 2.5, 0.2),
        "swe-1-7-lightning": (2.5, 12.5, 1.0),
        "swe-1-7-lightning-medium": (2.5, 12.5, 1.0),
        "swe-1-6": (0.5, 2.5, 0.2),
        "swe-1-6-fast": (0.5, 2.5, 0.2),
    ]

    /// USD for one step: uncached prompt × input rate + cached prompt ×
    /// cache-read rate + completion × output rate. `cached_tokens` is a
    /// subset of `prompt_tokens` (verified against `final_metrics`), so
    /// uncached = prompt − cached.
    static func usdCost(
        model: String,
        promptTokens: Int,
        cachedTokens: Int,
        completionTokens: Int
    ) -> Double {
        guard let rates = modelRates[model] else { return 0 }
        let uncached = max(0, promptTokens - cachedTokens)
        return (Double(uncached) * rates.input
                + Double(cachedTokens) * rates.cacheRead
                + Double(completionTokens) * rates.output) / 1_000_000
    }

    private struct StepAccumulator {
        var tokens = 0
        var usd = 0.0
        var models: [String: (usd: Double, tokens: Int)] = [:]
    }

    /// Pure filesystem scan — unit-testable via `root` override.
    static func scanTranscripts(
        root: URL,
        scanDays: Int,
        now: Date = Date(),
        calendar: Calendar = .current,
        fileManager: FileManager = .default,
        maxDirectoryEntries: Int = maxScanDirectoryEntries,
        maxReadFiles: Int = maxScanReadFiles,
        maxReadBytes: Int = maxScanReadBytes
    ) -> ScanResult {
        guard !Task.isCancelled else {
            return ScanResult(dailyBuckets: [], completed: false)
        }
        let startOfToday = calendar.startOfDay(for: now)
        guard scanDays > 0 else {
            return ScanResult(dailyBuckets: [], completed: true)
        }
        guard maxDirectoryEntries > 0, maxReadFiles > 0, maxReadBytes > 0 else {
            return ScanResult(dailyBuckets: [], completed: false)
        }
        guard let oldest = calendar.date(
                byAdding: .day,
                value: -(min(scanDays, chartWindowDays) - 1),
                to: startOfToday)
        else { return ScanResult(dailyBuckets: [], completed: true) }

        guard isDirectoryWithoutFollowingSymlink(root) else {
            return ScanResult(dailyBuckets: [], completed: false)
        }
        var enumerationFailed = false
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [],
            errorHandler: { _, _ in
                enumerationFailed = true
                return false
            }) else {
            return ScanResult(dailyBuckets: [], completed: false)
        }

        var names: [String] = []
        names.reserveCapacity(min(maxDirectoryEntries, maxReadFiles))
        var visitedEntries = 0
        while let candidate = enumerator.nextObject() as? URL {
            if Task.isCancelled {
                return ScanResult(dailyBuckets: [], completed: false)
            }
            visitedEntries += 1
            guard visitedEntries <= maxDirectoryEntries else {
                enumerationFailed = true
                break
            }
            if (try? candidate.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                enumerator.skipDescendants()
            }
            guard candidate.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL,
                  candidate.pathExtension == "json"
            else { continue }
            names.append(candidate.lastPathComponent)
        }
        names.sort()

        var byDay: [Date: StepAccumulator] = [:]
        var completed = !enumerationFailed
        var readFiles = 0
        var readBytes = 0

        for name in names {
            guard !Task.isCancelled else { completed = false; break }
            guard readFiles < maxReadFiles, readBytes < maxReadBytes else {
                completed = false
                break
            }
            readFiles += 1
            let url = root.appendingPathComponent(name)
            guard let data = boundedData(
                at: url,
                maximumBytes: min(maxTranscriptFileBytes, maxReadBytes - readBytes)) else {
                completed = false
                continue
            }
            readBytes += data.count
            guard let parsed = transcriptSteps(data: data) else {
                completed = false
                continue
            }
            if !parsed.completed { completed = false }
            for step in parsed.steps {
                guard !Task.isCancelled else { completed = false; break }
                guard let date = step.date else { continue }
                let day = calendar.startOfDay(for: date)
                guard day >= oldest, day <= startOfToday, step.tokens > 0 else { continue }
                var acc = byDay[day] ?? StepAccumulator()
                var model = acc.models[step.model] ?? (0, 0)
                guard let accumulatedTokens = checkedAdd(acc.tokens, step.tokens),
                      let modelTokens = checkedAdd(model.tokens, step.tokens),
                      (acc.usd + step.usd).isFinite,
                      (model.usd + step.usd).isFinite
                else {
                    completed = false
                    continue
                }
                acc.tokens = accumulatedTokens
                acc.usd += step.usd
                model.usd += step.usd
                model.tokens = modelTokens
                acc.models[step.model] = model
                byDay[day] = acc
            }
        }

        let buckets = byDay.keys.sorted().map { day -> CostHistoryStore.DayBucket in
            let acc = byDay[day] ?? StepAccumulator()
            let models = acc.models
                .sorted { $0.value.tokens > $1.value.tokens }
                .map { CostHistoryStore.Model(name: $0.key, usd: $0.value.usd, tokens: $0.value.tokens) }
            return CostHistoryStore.DayBucket(date: day, usd: acc.usd, tokens: acc.tokens, models: models)
        }
        return ScanResult(dailyBuckets: buckets, completed: completed)
    }

    /// Read at most `maxTranscriptFileBytes` — bounded so a corrupt or
    /// adversarial file cannot force an unbounded allocation.
    private static func boundedData(at url: URL, maximumBytes: Int) -> Data? {
        guard maximumBytes >= 0 else { return nil }
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
              metadata.st_size <= maximumBytes
        else { return nil }
        guard let data = try? handle.read(upToCount: maximumBytes + 1),
              data.count <= maximumBytes
        else { return nil }
        return data
    }

    private struct TranscriptStep {
        let date: Date?
        let model: String
        let tokens: Int
        let usd: Double
    }

    private struct TranscriptParse {
        let steps: [TranscriptStep]
        let completed: Bool
    }

    /// Extracts metric-bearing steps: `(timestamp, model_name, tokens, usd)`.
    /// Steps without `metrics` (sysprompt, user turns) carry no usage and
    /// are skipped.
    private static func transcriptSteps(data: Data) -> TranscriptParse? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let rawSteps = root["steps"] as? [Any],
              rawSteps.count <= maxTranscriptSteps
        else { return nil }
        let agentModel = (root["agent"] as? [String: Any])?["model_name"] as? String

        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        var steps: [TranscriptStep] = []
        steps.reserveCapacity(rawSteps.count)
        var completed = true
        for raw in rawSteps {
            guard let step = raw as? [String: Any],
                  let metrics = step["metrics"] as? [String: Any]
            else { continue }
            let prompt = intValue(metrics["prompt_tokens"])
            let completion = intValue(metrics["completion_tokens"])
            let cached = min(intValue(metrics["cached_tokens"]), prompt)
            guard let tokens = checkedAdd(prompt, completion) else {
                completed = false
                continue
            }
            guard tokens > 0 else { continue }

            let rawTimestamp = step["timestamp"] as? String
            let date = rawTimestamp.flatMap {
                isoFractional.date(from: $0) ?? iso.date(from: $0)
            }
            let model = sanitizedModelName(
                (step["model_name"] as? String) ?? agentModel ?? "devin")
            let usd = self.usdCost(
                model: model, promptTokens: prompt,
                cachedTokens: cached, completionTokens: completion)
            guard usd.isFinite else {
                completed = false
                continue
            }
            steps.append(TranscriptStep(date: date, model: model, tokens: tokens, usd: usd))
        }
        return TranscriptParse(steps: steps, completed: completed)
    }

    private static func intValue(_ value: Any?) -> Int {
        if let int = value as? Int { return max(0, int) }
        if let number = value as? NSNumber {
            let numeric = number.doubleValue
            guard numeric.isFinite, numeric > 0 else { return 0 }
            if numeric >= Double(Int.max) { return Int.max }
            return Int(numeric)
        }
        return 0
    }

    private static func checkedAdd(_ lhs: Int, _ rhs: Int) -> Int? {
        guard lhs >= 0, rhs >= 0, lhs <= Int.max - rhs else { return nil }
        return lhs + rhs
    }

    private static func isDirectoryWithoutFollowingSymlink(_ url: URL) -> Bool {
        var metadata = stat()
        return url.path.withCString { lstat($0, &metadata) } == 0
            && metadata.st_mode & S_IFMT == S_IFDIR
    }

    /// Model names come from local files — clamp so garbage in a transcript
    /// cannot push unbounded names into `cost-history.json`.
    private static func sanitizedModelName(_ raw: String) -> String {
        let cleaned = String(raw.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }).trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return "devin" }
        return String(cleaned.prefix(maxModelNameScalars))
    }
}
