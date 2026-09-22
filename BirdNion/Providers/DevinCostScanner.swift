import Foundation

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
    static let maxScanReadFiles = 10_000
    static let maxModelNameScalars = 64

    private actor Cache {
        static let shared = Cache()
        private var reportEntry: (at: Date, value: DevinCLIUsageReport)?
        func validReport(now: Date, ttl: TimeInterval) -> DevinCLIUsageReport? {
            guard let reportEntry, now.timeIntervalSince(reportEntry.at) < ttl else { return nil }
            return reportEntry.value
        }
        func storeReport(_ value: DevinCLIUsageReport, at: Date) { reportEntry = (at, value) }
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
        if !forceRescan, let report = await Cache.shared.validReport(now: now, ttl: cacheTTL) {
            return report
        }

        let root = transcriptsRoot ?? defaultTranscriptsDirectory
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
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

        let result = await Task.detached(priority: .utility) {
            scanTranscripts(
                root: root, scanDays: plan.windowDays,
                now: now, calendar: calendar)
        }.value

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
        if applied.persisted {
            await Cache.shared.storeReport(report, at: now)
        }
        return report
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
        fileManager: FileManager = .default
    ) -> ScanResult {
        let startOfToday = calendar.startOfDay(for: now)
        guard let oldest = calendar.date(byAdding: .day, value: -(scanDays - 1), to: startOfToday)
        else { return ScanResult(dailyBuckets: [], completed: true) }

        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: root.path)
                .filter { $0.hasSuffix(".json") }
                .sorted()
        } catch {
            return ScanResult(dailyBuckets: [], completed: false)
        }

        var byDay: [Date: StepAccumulator] = [:]
        var completed = true
        var readFiles = 0

        for name in names {
            guard readFiles < maxScanReadFiles else { completed = false; break }
            readFiles += 1
            let url = root.appendingPathComponent(name)
            guard let data = boundedData(at: url, fileManager: fileManager) else {
                completed = false
                continue
            }
            guard let steps = transcriptSteps(data: data) else {
                completed = false
                continue
            }
            for step in steps {
                guard let date = step.date else { continue }
                let day = calendar.startOfDay(for: date)
                guard day >= oldest, day <= startOfToday, step.tokens > 0 else { continue }
                var acc = byDay[day] ?? StepAccumulator()
                acc.tokens += step.tokens
                acc.usd += step.usd
                var model = acc.models[step.model] ?? (0, 0)
                model.usd += step.usd
                model.tokens += step.tokens
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
    private static func boundedData(at url: URL, fileManager: FileManager) -> Data? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize, size <= maxTranscriptFileBytes
        else { return nil }
        return fileManager.contents(atPath: url.path)
    }

    private struct TranscriptStep {
        let date: Date?
        let model: String
        let tokens: Int
        let usd: Double
    }

    /// Extracts metric-bearing steps: `(timestamp, model_name, tokens, usd)`.
    /// Steps without `metrics` (sysprompt, user turns) carry no usage and
    /// are skipped.
    private static func transcriptSteps(data: Data) -> [TranscriptStep]? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let rawSteps = root["steps"] as? [Any]
        else { return nil }
        let agentModel = (root["agent"] as? [String: Any])?["model_name"] as? String

        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        var steps: [TranscriptStep] = []
        steps.reserveCapacity(rawSteps.count)
        for raw in rawSteps {
            guard let step = raw as? [String: Any],
                  let metrics = step["metrics"] as? [String: Any]
            else { continue }
            let prompt = intValue(metrics["prompt_tokens"])
            let completion = intValue(metrics["completion_tokens"])
            let cached = min(intValue(metrics["cached_tokens"]), prompt)
            let tokens = prompt + completion
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
            steps.append(TranscriptStep(date: date, model: model, tokens: tokens, usd: usd))
        }
        return steps
    }

    private static func intValue(_ value: Any?) -> Int {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        return 0
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
