import Foundation

/// One model's slice of a single Oh My Pi (`omp`) day.
struct OMPDailyModel: Equatable, Identifiable, Sendable {
    let name: String
    let usd: Double
    let tokens: Int
    var id: String { name }
}

/// One calendar day (local tz) of OMP usage: token sum + USD spend,
/// plus per-model breakdown (top models by cost/tokens).
struct OMPDailyUsage: Equatable, Identifiable, Sendable {
    let date: Date
    let usd: Double
    let tokens: Int
    let models: [OMPDailyModel]
    var id: Date { date }
}

/// Full report for the Oh My Pi usage chart.
struct OMPUsageReport: Equatable, Sendable {
    let todayUSD: Double
    let todayTokens: Int
    let last30USD: Double
    let last30Tokens: Int
    let daily: [OMPDailyUsage]
    let topModel: String?
    var scanConfidence: CostHistoryStore.UsageScanConfidence = .unavailable

    var isEmpty: Bool { last30Tokens == 0 && todayTokens == 0 }
}

/// Rolls up Oh My Pi (`omp`) token and USD spend from streaming JSONL session logs.
///
/// Features:
/// - Multi-profile session root discovery via `OMPPaths.allSessionDirectories()`.
/// - Incremental scanning bounded by `scanBackDays`.
/// - Exact turn deduplication using `(entry.id, message.timestamp)` (prevents double-counting forked sessions).
/// - Subagent safety: skips `toolResult.details.usage` to prevent inflating parent session totals.
/// - Streaming line parsing: tolerates in-flight unclosed tail lines without crashing.
/// - Merges into `CostHistoryStore` (never-shrink high-water) and `ProjectCostHistoryStore`.
/// - Single-flight cache (300s) to avoid redundant disk I/O.
enum OMPCostScanner {

    static let chartWindowDays = 120
    static let incrementalDays = 3
    private static let cacheTTL: TimeInterval = 300 // 5 minutes
    private static let sessionReadChunkBytes = 64 * 1024
    private static let maxSessionFileBytes = 64 * 1024 * 1024

    private actor Cache {
        static let shared = Cache()
        private var reportEntry: (at: Date, value: OMPUsageReport)?

        func validReport(now: Date, ttl: TimeInterval) -> OMPUsageReport? {
            guard let reportEntry, now.timeIntervalSince(reportEntry.at) < ttl else { return nil }
            return reportEntry.value
        }
        func storeReport(_ value: OMPUsageReport, at: Date) { reportEntry = (at, value) }
    }

    // MARK: - Public API

    /// Load or scan the OMP usage report.
    static func loadReport(
        now: Date = Date(),
        calendar: Calendar = .current,
        forceRescan: Bool = false
    ) async -> OMPUsageReport {
        if !forceRescan, let report = await Cache.shared.validReport(now: now, ttl: cacheTTL) {
            return report
        }
        let scanRoots = OMPPaths.allSessionDirectories()
        guard !scanRoots.isEmpty else {
            let window = CostHistoryStore.apply(
                source: .omp,
                liveDays: [],
                now: now,
                calendar: calendar,
                windowDays: chartWindowDays,
                liveScanSucceeded: false)
            let confidence = CostHistoryStore.confidence(source: .omp, liveScanSucceeded: false)
            return CostHistoryStore.makeOMPReport(window: window, confidence: confidence)
        }

        let scanDays = CostHistoryStore.scanBackDays(
            source: .omp,
            now: now,
            calendar: calendar,
            minDays: incrementalDays,
            maxDays: chartWindowDays)

        let result = await scanSessions(
            roots: scanRoots,
            scanDays: scanDays,
            now: now,
            calendar: calendar)

        let receipt: CostHistoryStore.ApplyReceipt?
        let window: [CostHistoryStore.DayBucket]
        if result.completed {
            let liveDays = result.dailyBuckets.map {
                ($0.date, $0.usd, $0.tokens, $0.models.map { ($0.name, $0.usd, $0.tokens) })
            }
            let applied = CostHistoryStore.applyWithReceipt(
                source: .omp,
                liveDays: liveDays,
                now: now,
                calendar: calendar,
                windowDays: chartWindowDays,
                liveScanSucceeded: true)
            receipt = applied
            window = applied.window
        } else {
            receipt = nil
            window = CostHistoryStore.window(
                source: .omp,
                now: now,
                calendar: calendar,
                windowDays: chartWindowDays)
        }

        let confidence = CostHistoryStore.confidence(
            source: .omp,
            liveScanSucceeded: receipt?.persisted == true)
        let report = CostHistoryStore.makeOMPReport(window: window, confidence: confidence)

        if receipt?.persisted == true {
            await Cache.shared.storeReport(report, at: now)
        }
        return report
    }

    // MARK: - Internal Session Scanner

    struct ScanResult: Sendable {
        let dailyBuckets: [CostHistoryStore.DayBucket]
        let projectRecords: [ProjectUsageRecord]
        let completed: Bool
        let wasTruncated: Bool

        init(
            dailyBuckets: [CostHistoryStore.DayBucket],
            projectRecords: [ProjectUsageRecord],
            completed: Bool = true,
            wasTruncated: Bool = false
        ) {
            self.dailyBuckets = dailyBuckets
            self.projectRecords = projectRecords
            self.completed = completed
            self.wasTruncated = wasTruncated
        }
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

    /// Pure scanner function reading all JSONL files across the given roots.
    static func scanSessions(
        roots: [URL],
        scanDays: Int,
        now: Date = Date(),
        calendar: Calendar = .current,
        fileManager: FileManager = .default,
        maxEntries: Int = 20_000
    ) async -> ScanResult {
        let cutoff = calendar.date(byAdding: .day, value: -scanDays, to: calendar.startOfDay(for: now)) ?? now

        let scanTask = Task.detached(priority: .utility) {
            var turns: [TurnRecord] = []
            var seenTurns: Set<TurnKey> = []
            var visitedEntries = 0
            var completed = true
            var wasTruncated = false

            for root in roots {
                guard !Task.isCancelled else {
                    completed = false
                    break
                }
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
                      isDirectory.boolValue
                else {
                    completed = false
                    continue
                }
                guard visitedEntries < maxEntries else {
                    completed = false
                    wasTruncated = true
                    break
                }
                guard let enumerator = fileManager.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants],
                    errorHandler: { _, _ in
                        completed = false
                        return false
                    })
                else {
                    completed = false
                    continue
                }

                while let nextObj = enumerator.nextObject() {
                    guard !Task.isCancelled else {
                        completed = false
                        enumerator.skipDescendants()
                        break
                    }
                    guard visitedEntries < maxEntries else {
                        completed = false
                        wasTruncated = true
                        enumerator.skipDescendants()
                        break
                    }
                    visitedEntries += 1
                    guard let fileURL = nextObj as? URL else { continue }
                    guard fileURL.pathExtension.lowercased() == "jsonl" else { continue }
                    guard let attrs = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                    else {
                        completed = false
                        continue
                    }
                    guard
                          attrs.isRegularFile == true,
                          let mtime = attrs.contentModificationDate,
                          mtime >= cutoff
                    else { continue }

                    if !parseSessionFile(
                        fileURL: fileURL,
                        cutoff: cutoff,
                        seenTurns: &seenTurns,
                        turns: &turns)
                    {
                        completed = false
                    }
                }
            }

            let aggregated = aggregateTurns(turns: turns, now: now, calendar: calendar)
            return ScanResult(
                dailyBuckets: aggregated.dailyBuckets,
                projectRecords: aggregated.projectRecords,
                completed: completed && !Task.isCancelled && !wasTruncated,
                wasTruncated: wasTruncated)
        }
        return await withTaskCancellationHandler {
            await scanTask.value
        } onCancel: {
            scanTask.cancel()
        }
    }

    // MARK: - Streaming JSONL Parser

    private static func parseSessionFile(
        fileURL: URL,
        cutoff: Date,
        seenTurns: inout Set<TurnKey>,
        turns: inout [TurnRecord]
    ) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return false }
        defer { try? handle.close() }
        var buffer = Data()
        var totalBytes = 0
        var lineStartOffset = 0
        var searchOffset = 0
        var sessionCWD: String?

        while true {
            guard !Task.isCancelled else { return false }
            let chunk: Data
            do {
                guard let next = try handle.read(upToCount: sessionReadChunkBytes), !next.isEmpty
                else { break }
                chunk = next
            } catch {
                return false
            }
            totalBytes += chunk.count
            guard totalBytes <= maxSessionFileBytes else { return false }
            buffer.append(chunk)

            while searchOffset < buffer.count {
                guard !Task.isCancelled else { return false }
                let searchStart = buffer.index(buffer.startIndex, offsetBy: searchOffset)
                guard let newline = buffer[searchStart...].firstIndex(of: 0x0A) else {
                    searchOffset = buffer.count
                    break
                }
                let lineStart = buffer.index(buffer.startIndex, offsetBy: lineStartOffset)
                let line = Data(buffer[lineStart..<newline])
                let nextLine = buffer.index(after: newline)
                lineStartOffset = buffer.distance(from: buffer.startIndex, to: nextLine)
                searchOffset = lineStartOffset
                guard parseSessionLine(
                    line,
                    cutoff: cutoff,
                    sessionCWD: &sessionCWD,
                    seenTurns: &seenTurns,
                    turns: &turns)
                else { return false }
            }

            if lineStartOffset >= sessionReadChunkBytes * 16 || lineStartOffset == buffer.count {
                buffer.removeSubrange(buffer.startIndex..<buffer.index(
                    buffer.startIndex, offsetBy: lineStartOffset))
                searchOffset -= lineStartOffset
                lineStartOffset = 0
            }
        }

        // A writer may be appending the final JSON object. Parse a valid tail,
        // but tolerate a malformed unterminated tail only.
        if lineStartOffset < buffer.count {
            let lineStart = buffer.index(buffer.startIndex, offsetBy: lineStartOffset)
            _ = parseSessionLine(
                Data(buffer[lineStart...]),
                cutoff: cutoff,
                sessionCWD: &sessionCWD,
                seenTurns: &seenTurns,
                turns: &turns)
        }
        return true
    }

    private static func parseSessionLine(
        _ lineData: Data,
        cutoff: Date,
        sessionCWD: inout String?,
        seenTurns: inout Set<TurnKey>,
        turns: inout [TurnRecord]
    ) -> Bool {
        guard let line = String(data: lineData, encoding: .utf8) else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }

        if let type = json["type"] as? String {
            if type == "session", let cwd = json["cwd"] as? String, !cwd.isEmpty {
                sessionCWD = cwd
            } else if type == "message" {
                parseMessageEntry(
                    json: json,
                    sessionCWD: sessionCWD,
                    cutoff: cutoff,
                    seenTurns: &seenTurns,
                    turns: &turns)
            }
        }
        return true
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

        // Deduplication by entry.id + timestamp
        let entryID = (json["id"] as? String) ?? (message["id"] as? String) ?? UUID().uuidString
        let timestampStr = (message["timestamp"] as? String) ?? (json["timestamp"] as? String) ?? ""
        let turnKey = TurnKey(id: entryID, timestamp: timestampStr)

        // Parse timestamp
        guard let date = parseISO8601(timestampStr), date >= cutoff else { return }

        // Model name
        let model = (message["model"] as? String) ?? (json["model"] as? String) ?? "unknown"

        // Tokens & Cost
        let usage = (message["usage"] as? [String: Any]) ?? (json["usage"] as? [String: Any]) ?? [:]
        let totalTokens = (usage["totalTokens"] as? Int) ?? (usage["total_tokens"] as? Int) ?? 0

        var costUSD: Double = 0
        if let costObj = usage["cost"] as? [String: Any], let totalCost = costObj["total"] as? Double {
            costUSD = max(0, totalCost)
        } else if let totalCost = usage["costUSD"] as? Double ?? usage["cost_usd"] as? Double {
            costUSD = max(0, totalCost)
        }
        guard totalTokens > 0 || costUSD > 0 else { return }
        guard seenTurns.insert(turnKey).inserted else { return }

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

    // MARK: - Aggregations

    private static func aggregateTurns(
        turns: [TurnRecord],
        now: Date,
        calendar: Calendar
    ) -> ScanResult {
        var dailyMap: [Date: [String: (usd: Double, tokens: Int)]] = [:]
        var projectDailyMap: [String: (name: String, days: [Date: [String: (usd: Double, tokens: Int)]])] = [:]

        for turn in turns {
            let day = calendar.startOfDay(for: turn.date)

            // Daily rollups
            var modelMap = dailyMap[day] ?? [:]
            var current = modelMap[turn.model] ?? (0, 0)
            current.usd += turn.usd
            current.tokens += turn.tokens
            modelMap[turn.model] = current
            dailyMap[day] = modelMap

            // Project rollups
            if let identity = ProjectIdentity.omp(cwd: turn.cwd) {
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
                source: .omp,
                projectKey: key,
                displayName: entry.name,
                attribution: .exact,
                daily: dailyUsage)
        }

        return ScanResult(dailyBuckets: dailyBuckets, projectRecords: projectRecords)
    }
}
