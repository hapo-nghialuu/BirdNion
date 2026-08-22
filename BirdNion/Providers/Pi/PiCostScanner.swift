import Foundation

/// One model's slice of a single Pi Agent day.
struct PiDailyModel: Equatable, Identifiable, Sendable {
    let name: String
    let usd: Double
    let tokens: Int
    var id: String { name }
}

/// One calendar day (local tz) of Pi Agent usage.
struct PiDailyUsage: Equatable, Identifiable, Sendable {
    let date: Date
    let usd: Double
    let tokens: Int
    let models: [PiDailyModel]
    var id: Date { date }
}

/// Full report for the Pi Agent usage chart.
struct PiUsageReport: Equatable, Sendable {
    let todayUSD: Double
    let todayTokens: Int
    let last30USD: Double
    let last30Tokens: Int
    let daily: [PiDailyUsage]
    let topModel: String?
    var scanConfidence: CostHistoryStore.UsageScanConfidence = .unavailable

    var isEmpty: Bool { last30Tokens == 0 && todayTokens == 0 }
}

/// Rolls up Pi Agent token and USD spend from streaming JSONL session logs.
///
/// Discovers sessions at `~/.pi/agent/sessions/` (or `PI_CODING_AGENT_SESSION_DIR` / `PI_CODING_AGENT_DIR`).
/// Attributes usage strictly to `Source.pi` and `ProjectUsageSource.pi`.
enum PiCostScanner {

    static let chartWindowDays = 120
    static let incrementalDays = 3
    private static let cacheTTL: TimeInterval = 300 // 5 minutes

    private actor Cache {
        static let shared = Cache()
        private var reportEntry: (at: Date, value: PiUsageReport)?

        func validReport(now: Date, ttl: TimeInterval) -> PiUsageReport? {
            guard let reportEntry, now.timeIntervalSince(reportEntry.at) < ttl else { return nil }
            return reportEntry.value
        }
        func storeReport(_ value: PiUsageReport, at: Date) { reportEntry = (at, value) }
    }

    // MARK: - Path Resolution

    static var defaultSessionsDirectory: URL {
        if let custom = ProcessInfo.processInfo.environment["PI_CODING_AGENT_SESSION_DIR"],
           !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        if let custom = ProcessInfo.processInfo.environment["PI_CODING_AGENT_DIR"],
           !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true).appendingPathComponent("sessions", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    // MARK: - Public API

    static func loadReport(
        now: Date = Date(),
        calendar: Calendar = .current,
        forceRescan: Bool = false
    ) async -> PiUsageReport {
        if !forceRescan, let report = await Cache.shared.validReport(now: now, ttl: cacheTTL) {
            return report
        }

        let root = defaultSessionsDirectory
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            let window = CostHistoryStore.apply(
                source: .pi,
                liveDays: [],
                now: now,
                calendar: calendar,
                windowDays: chartWindowDays,
                liveScanSucceeded: false)
            let confidence = CostHistoryStore.confidence(source: .pi, liveScanSucceeded: false)
            return CostHistoryStore.makePiReport(window: window, confidence: confidence)
        }

        let scanDays = CostHistoryStore.scanBackDays(
            source: .pi,
            now: now,
            calendar: calendar,
            minDays: incrementalDays,
            maxDays: chartWindowDays)

        let result = await scanSessions(
            root: root,
            scanDays: scanDays,
            now: now,
            calendar: calendar)

        let liveDays = result.dailyBuckets.map {
            ($0.date, $0.usd, $0.tokens, $0.models.map { ($0.name, $0.usd, $0.tokens) })
        }

        let window = CostHistoryStore.apply(
            source: .pi,
            liveDays: liveDays,
            now: now,
            calendar: calendar,
            windowDays: chartWindowDays,
            liveScanSucceeded: true)
        let confidence = CostHistoryStore.confidence(source: .pi, liveScanSucceeded: true)
        let report = CostHistoryStore.makePiReport(window: window, confidence: confidence)

        await Cache.shared.storeReport(report, at: now)
        return report
    }

    // MARK: - Internal Scanner

    struct ScanResult: Sendable {
        let dailyBuckets: [CostHistoryStore.DayBucket]
        let projectRecords: [ProjectUsageRecord]
    }

    private struct TurnKey: Hashable {
        let id: String
        let timestamp: String
    }

    private struct TurnRecord {
        let date: Date
        let model: String
        let tokens: Int
        let usd: Double
        let cwd: String?
    }

    static func scanSessions(
        root: URL,
        scanDays: Int,
        now: Date = Date(),
        calendar: Calendar = .current,
        fileManager: FileManager = .default
    ) async -> ScanResult {
        let cutoff = calendar.date(byAdding: .day, value: -scanDays, to: calendar.startOfDay(for: now)) ?? now

        return await Task.detached(priority: .utility) {
            var turns: [TurnRecord] = []
            var seenTurns: Set<TurnKey> = []

            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles])
            else {
                return ScanResult(dailyBuckets: [], projectRecords: [])
            }

            while let nextObj = enumerator.nextObject() {
                guard let fileURL = nextObj as? URL else { continue }
                guard fileURL.pathExtension.lowercased() == "jsonl" else { continue }
                guard let attrs = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                      attrs.isRegularFile == true,
                      let mtime = attrs.contentModificationDate,
                      mtime >= cutoff
                else { continue }

                parseSessionFile(
                    fileURL: fileURL,
                    cutoff: cutoff,
                    seenTurns: &seenTurns,
                    turns: &turns)
            }

            return aggregateTurns(turns: turns, now: now, calendar: calendar)
        }.value
    }

    private static func parseSessionFile(
        fileURL: URL,
        cutoff: Date,
        seenTurns: inout Set<TurnKey>,
        turns: inout [TurnRecord]
    ) {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let content = String(data: data, encoding: .utf8) else { return }

        var sessionCWD: String?

        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let lineData = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            if let type = json["type"] as? String {
                if type == "session" {
                    if let cwd = json["cwd"] as? String, !cwd.isEmpty {
                        sessionCWD = cwd
                    }
                } else if type == "message" {
                    parseMessageEntry(
                        json: json,
                        sessionCWD: sessionCWD,
                        cutoff: cutoff,
                        seenTurns: &seenTurns,
                        turns: &turns)
                }
            }
        }
    }

    private static func parseMessageEntry(
        json: [String: Any],
        sessionCWD: String?,
        cutoff: Date,
        seenTurns: inout Set<TurnKey>,
        turns: inout [TurnRecord]
    ) {
        guard let message = json["message"] as? [String: Any] else { return }
        let role = message["role"] as? String ?? ""
        guard role == "assistant" else { return }

        let entryID = (json["id"] as? String) ?? (message["id"] as? String) ?? UUID().uuidString
        let timestampStr = (message["timestamp"] as? String) ?? (json["timestamp"] as? String) ?? ""
        let turnKey = TurnKey(id: entryID, timestamp: timestampStr)
        guard !seenTurns.contains(turnKey) else { return }
        seenTurns.insert(turnKey)

        guard let date = parseISO8601(timestampStr), date >= cutoff else { return }

        let model = (message["model"] as? String) ?? (json["model"] as? String) ?? "unknown"
        let usage = (message["usage"] as? [String: Any]) ?? (json["usage"] as? [String: Any]) ?? [:]
        let totalTokens = (usage["totalTokens"] as? Int) ?? (usage["total_tokens"] as? Int) ?? 0

        var costUSD: Double = 0
        if let costObj = usage["cost"] as? [String: Any], let totalCost = costObj["total"] as? Double {
            costUSD = max(0, totalCost)
        } else if let totalCost = usage["costUSD"] as? Double ?? usage["cost_usd"] as? Double {
            costUSD = max(0, totalCost)
        }

        turns.append(TurnRecord(
            date: date,
            model: model,
            tokens: totalTokens,
            usd: costUSD,
            cwd: sessionCWD))
    }

    private static func parseISO8601(_ str: String) -> Date? {
        if str.isEmpty { return nil }
        let formatterWithFraction = ISO8601DateFormatter()
        formatterWithFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = formatterWithFraction.date(from: str) { return d }
        let plainFormatter = ISO8601DateFormatter()
        plainFormatter.formatOptions = [.withInternetDateTime]
        return plainFormatter.date(from: str)
    }

    private static func aggregateTurns(
        turns: [TurnRecord],
        now: Date,
        calendar: Calendar
    ) -> ScanResult {
        var dailyMap: [Date: [String: (usd: Double, tokens: Int)]] = [:]
        var projectDailyMap: [String: (name: String, days: [Date: [String: (usd: Double, tokens: Int)]])] = [:]

        for turn in turns {
            let day = calendar.startOfDay(for: turn.date)

            var modelMap = dailyMap[day] ?? [:]
            var current = modelMap[turn.model] ?? (0, 0)
            current.usd += turn.usd
            current.tokens += turn.tokens
            modelMap[turn.model] = current
            dailyMap[day] = modelMap

            if let identity = ProjectIdentity.pi(cwd: turn.cwd) {
                var projectEntry = projectDailyMap[identity.key] ?? (name: identity.displayName, days: [:])
                var pDayModels = projectEntry.days[day] ?? [:]
                var pModelTotal = pDayModels[turn.model] ?? (0, 0)
                pModelTotal.usd += turn.usd
                pModelTotal.tokens += turn.tokens
                pDayModels[turn.model] = pModelTotal
                projectEntry.days[day] = pDayModels
                projectDailyMap[identity.key] = projectEntry
            }
        }

        let dailyBuckets = dailyMap.map { date, models in
            let totalUSD = models.values.map(\.usd).reduce(0, +)
            let totalTokens = models.values.map(\.tokens).reduce(0, +)
            let modelEntries = models.map { CostHistoryStore.Model(name: $0.key, usd: $0.value.usd, tokens: $0.value.tokens) }
                .sorted { $0.usd > $1.usd }
            return CostHistoryStore.DayBucket(date: date, usd: totalUSD, tokens: totalTokens, models: modelEntries)
        }.sorted { $0.date < $1.date }

        let projectRecords: [ProjectUsageRecord] = projectDailyMap.map { key, entry in
            let dailyUsage = entry.days.map { dayDate, models in
                let dayUSD = models.values.map(\.usd).reduce(0, +)
                let dayTokens = models.values.map(\.tokens).reduce(0, +)
                let modelEntries = models.map { ProjectModelUsage(name: $0.key, usd: $0.value.usd, tokens: $0.value.tokens) }
                return ProjectDailyUsage(date: dayDate, usd: dayUSD, tokens: dayTokens, models: modelEntries)
            }.sorted { $0.date < $1.date }

            return ProjectUsageRecord(
                source: .pi,
                projectKey: key,
                displayName: entry.name,
                attribution: .exact,
                daily: dailyUsage)
        }

        return ScanResult(dailyBuckets: dailyBuckets, projectRecords: projectRecords)
    }
}
