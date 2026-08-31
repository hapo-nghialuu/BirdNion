#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#else
import Darwin
#endif

extension CostUsageScanner {
    static func codexRowsByDayModel(
        cache: CostUsageCache,
        range: CostUsageDayRange) -> [String: [String: [CodexUsageRow]]]
    {
        var rowsByDayModel: [String: [String: [CodexUsageRow]]] = [:]
        for usage in cache.files.values {
            for row in usage.codexRows ?? [] {
                guard CostUsageDayRange.isInRange(dayKey: row.day, since: range.sinceKey, until: range.untilKey)
                else { continue }
                rowsByDayModel[row.day, default: [:]][row.model, default: []].append(row)
            }
        }
        return rowsByDayModel
    }

    static func codexRowsByDayModel(
        rows: [CodexUsageRow],
        range: CostUsageDayRange) -> [String: [String: [CodexUsageRow]]]
    {
        var rowsByDayModel: [String: [String: [CodexUsageRow]]] = [:]
        for row in rows {
            guard CostUsageDayRange.isInRange(dayKey: row.day, since: range.sinceKey, until: range.untilKey)
            else { continue }
            rowsByDayModel[row.day, default: [:]][row.model, default: []].append(row)
        }
        return rowsByDayModel
    }

    static func codexCostNanosByDayModel(
        cache: CostUsageCache,
        range: CostUsageDayRange) -> [String: [String: Int64]]
    {
        self.codexNanosByDayModel(cache: cache, range: range) { $0.codexCostNanos }
    }

    static func codexPrioritySurchargeNanosByDayModel(
        cache: CostUsageCache,
        range: CostUsageDayRange) -> [String: [String: Int64]]
    {
        self.codexNanosByDayModel(cache: cache, range: range) { $0.codexPrioritySurchargeNanos }
    }

    static func codexStandardCostNanosByDayModel(
        cache: CostUsageCache,
        range: CostUsageDayRange) -> [String: [String: Int64]]
    {
        self.codexNanosByDayModel(cache: cache, range: range) { $0.codexStandardCostNanos }
    }

    static func codexPriorityCostNanosByDayModel(
        cache: CostUsageCache,
        range: CostUsageDayRange) -> [String: [String: Int64]]
    {
        self.codexNanosByDayModel(cache: cache, range: range) { $0.codexPriorityCostNanos }
    }

    static func codexStandardTokensByDayModel(
        cache: CostUsageCache,
        range: CostUsageDayRange) -> [String: [String: Int]]
    {
        self.codexIntByDayModel(cache: cache, range: range) { $0.codexStandardTokens }
    }

    static func codexPriorityTokensByDayModel(
        cache: CostUsageCache,
        range: CostUsageDayRange) -> [String: [String: Int]]
    {
        self.codexIntByDayModel(cache: cache, range: range) { $0.codexPriorityTokens }
    }

    static func codexNanosByDayModel(
        cache: CostUsageCache,
        range: CostUsageDayRange,
        keyPath: (CostUsageFileUsage) -> [String: [String: Int64]]?) -> [String: [String: Int64]]
    {
        var out: [String: [String: Int64]] = [:]
        for usage in cache.files.values {
            for (day, models) in keyPath(usage) ?? [:] {
                guard CostUsageDayRange.isInRange(dayKey: day, since: range.sinceKey, until: range.untilKey)
                else { continue }
                for (model, value) in models {
                    out[day, default: [:]][model, default: 0] += value
                }
            }
        }
        return out
    }

    static func codexIntByDayModel(
        cache: CostUsageCache,
        range: CostUsageDayRange,
        keyPath: (CostUsageFileUsage) -> [String: [String: Int]]?) -> [String: [String: Int]]
    {
        var out: [String: [String: Int]] = [:]
        for usage in cache.files.values {
            for (day, models) in keyPath(usage) ?? [:] {
                guard CostUsageDayRange.isInRange(dayKey: day, since: range.sinceKey, until: range.untilKey)
                else { continue }
                for (model, value) in models {
                    out[day, default: [:]][model, default: 0] += value
                }
            }
        }
        return out
    }

    static func codexRowsCostUSD(
        rows: [CodexUsageRow],
        modelsDevCatalog: ModelsDevCatalog?,
        modelsDevCacheRoot: URL?) -> Double?
    {
        var total: Double = 0
        var seen = false
        for row in rows {
            guard let cost = CostUsagePricing.codexCostUSD(
                model: row.model,
                inputTokens: row.input,
                cachedInputTokens: row.cached,
                outputTokens: row.output,
                modelsDevCatalog: modelsDevCatalog,
                modelsDevCacheRoot: modelsDevCacheRoot)
            else { continue }
            total += cost
            seen = true
        }
        return seen ? total : nil
    }

    static func codexPrioritySurchargeUSD(
        rows: [CodexUsageRow],
        priorityTurns: [String: CodexPriorityTurnMetadata],
        modelsDevCatalog: ModelsDevCatalog?,
        modelsDevCacheRoot: URL?) -> Double?
    {
        var total: Double = 0
        var seen = false
        for row in rows {
            guard let turnID = row.turnID, let priorityMetadata = priorityTurns[turnID] else { continue }
            let pricedModel = Self.codexPriorityPricingModel(for: row, priorityMetadata: priorityMetadata)
            guard let baseCost = CostUsagePricing.codexCostUSD(
                model: pricedModel,
                inputTokens: row.input,
                cachedInputTokens: row.cached,
                outputTokens: row.output,
                modelsDevCatalog: modelsDevCatalog,
                modelsDevCacheRoot: modelsDevCacheRoot),
                let priorityCost = CostUsagePricing.codexPriorityCostUSD(
                    model: pricedModel,
                    inputTokens: row.input,
                    cachedInputTokens: row.cached,
                    outputTokens: row.output)
            else { continue }
            total += max(priorityCost - baseCost, 0)
            seen = true
        }
        return seen ? total : nil
    }

    private static func codexPriorityPricingModel(
        for row: CodexUsageRow,
        priorityMetadata: CodexPriorityTurnMetadata) -> String
    {
        guard let model = priorityMetadata.model,
              CostUsagePricing.codexPriorityCostUSD(
                  model: model,
                  inputTokens: row.input,
                  cachedInputTokens: row.cached,
                  outputTokens: row.output) != nil
        else { return row.model }
        return model
    }

    struct CodexRowCostBreakdown {
        var standardCostUSD: Double = 0
        var priorityCostUSD: Double = 0
        var standardTokens: Int = 0
        var priorityTokens: Int = 0
        var sawStandardCost = false
        var sawPriorityCost = false

        var optionalStandardCostUSD: Double? {
            self.sawStandardCost ? self.standardCostUSD : nil
        }

        var optionalPriorityCostUSD: Double? {
            self.sawPriorityCost ? self.priorityCostUSD : nil
        }

        var optionalStandardTokens: Int? {
            self.standardTokens > 0 ? self.standardTokens : nil
        }

        var optionalPriorityTokens: Int? {
            self.priorityTokens > 0 ? self.priorityTokens : nil
        }

        var totalCostUSD: Double? {
            guard self.sawStandardCost || self.sawPriorityCost else { return nil }
            return self.standardCostUSD + self.priorityCostUSD
        }

        var hasModeSplit: Bool {
            self.sawPriorityCost || self.priorityTokens > 0
        }
    }

    static func codexRowCostBreakdown(
        rows: [CodexUsageRow],
        priorityTurns: [String: CodexPriorityTurnMetadata],
        modelsDevCatalog: ModelsDevCatalog?,
        modelsDevCacheRoot: URL?) -> CodexRowCostBreakdown
    {
        var breakdown = CodexRowCostBreakdown()
        for row in rows {
            let tokenCount = row.input + row.output
            let priorityMetadata = row.turnID.flatMap { priorityTurns[$0] }
            let isPriority = priorityMetadata != nil
            if isPriority {
                breakdown.priorityTokens += tokenCount
            } else {
                breakdown.standardTokens += tokenCount
            }
            let pricedModel = priorityMetadata.map { Self.codexPriorityPricingModel(for: row, priorityMetadata: $0) }
                ?? row.model

            let baseCost = CostUsagePricing.codexCostUSD(
                model: pricedModel,
                inputTokens: row.input,
                cachedInputTokens: row.cached,
                outputTokens: row.output,
                modelsDevCatalog: modelsDevCatalog,
                modelsDevCacheRoot: modelsDevCacheRoot)
            if isPriority, let priorityCost = CostUsagePricing.codexPriorityCostUSD(
                model: pricedModel,
                inputTokens: row.input,
                cachedInputTokens: row.cached,
                outputTokens: row.output)
            {
                breakdown.priorityCostUSD += max(priorityCost, baseCost ?? priorityCost)
                breakdown.sawPriorityCost = true
            } else if isPriority, let baseCost {
                breakdown.priorityCostUSD += baseCost
                breakdown.sawPriorityCost = true
            } else if let baseCost {
                breakdown.standardCostUSD += baseCost
                breakdown.sawStandardCost = true
            }
        }
        return breakdown
    }

    // MARK: - File cache construction

    static func makeFileUsage(
        mtimeUnixMs: Int64,
        size: Int64,
        days: [String: [String: [Int]]],
        parsedBytes: Int64?,
        lastModel: String? = nil,
        lastTotals: CostUsageCodexTotals? = nil,
        lastCountedTotals: CostUsageCodexTotals? = nil,
        lastRawTotalsBaseline: CostUsageCodexTotals? = nil,
        hasDivergentTotals: Bool? = nil,
        lastCodexTurnID: String? = nil,
        sessionId: String? = nil,
        forkedFromId: String? = nil,
        projectKey: String? = nil,
        projectName: String? = nil,
        projectAttributionAmbiguous: Bool? = nil,
        projectRetractionID: String? = nil,
        projectRetractionKey: String? = nil,
        codexCostNanos: [String: [String: Int64]]? = nil,
        codexPrioritySurchargeNanos: [String: [String: Int64]]? = nil,
        codexStandardCostNanos: [String: [String: Int64]]? = nil,
        codexPriorityCostNanos: [String: [String: Int64]]? = nil,
        codexStandardTokens: [String: [String: Int]]? = nil,
        codexPriorityTokens: [String: [String: Int]]? = nil,
        codexTurnIDs: [String]? = nil,
        codexRows: [CodexUsageRow]? = nil,
        claudeRows: [ClaudeUsageRow]? = nil,
        codexScanFileId: String? = nil,
        codexScanTargetSize: Int64? = nil,
        codexScanContentFingerprint: String? = nil,
        codexScanComplete: Bool? = nil,
        codexScanGeneration: String? = nil,
        codexParseResumeState: CodexParseResumeState? = nil) -> CostUsageFileUsage
    {
        CostUsageFileUsage(
            mtimeUnixMs: mtimeUnixMs,
            size: size,
            days: days,
            parsedBytes: parsedBytes,
            lastModel: lastModel,
            lastTotals: lastTotals,
            lastCountedTotals: lastCountedTotals,
            lastRawTotalsBaseline: lastRawTotalsBaseline,
            hasDivergentTotals: hasDivergentTotals,
            lastCodexTurnID: lastCodexTurnID,
            sessionId: sessionId,
            forkedFromId: forkedFromId,
            projectKey: projectKey,
            projectName: projectName,
            projectAttributionAmbiguous: projectAttributionAmbiguous,
            projectRetractionID: projectRetractionID,
            projectRetractionKey: projectRetractionKey,
            codexCostNanos: codexCostNanos,
            codexPrioritySurchargeNanos: codexPrioritySurchargeNanos,
            codexStandardCostNanos: codexStandardCostNanos,
            codexPriorityCostNanos: codexPriorityCostNanos,
            codexStandardTokens: codexStandardTokens,
            codexPriorityTokens: codexPriorityTokens,
            codexTurnIDs: codexTurnIDs,
            codexRows: codexRows,
            claudeRows: claudeRows,
            codexScanFileId: codexScanFileId,
            codexScanTargetSize: codexScanTargetSize,
            codexScanContentFingerprint: codexScanContentFingerprint,
            codexScanComplete: codexScanComplete,
            codexScanGeneration: codexScanGeneration,
            codexParseResumeState: codexParseResumeState)
    }

    static func needsCodexCostCache(_ usage: CostUsageFileUsage) -> Bool {
        !(usage.codexRows?.isEmpty ?? true)
            && (usage.codexCostNanos == nil || self.needsCodexModeSplitCache(usage))
    }

    static func needsCodexCostCache(_ usage: CostUsageFileUsage, range: CostUsageDayRange) -> Bool {
        guard let rows = usage.codexRows, !rows.isEmpty else { return false }
        return rows.contains {
            CostUsageDayRange.isInRange(dayKey: $0.day, since: range.sinceKey, until: range.untilKey)
        } && (usage.codexCostNanos == nil || Self.needsCodexModeSplitCache(usage))
    }

    static func needsCodexModeSplitCache(_ usage: CostUsageFileUsage) -> Bool {
        usage.codexStandardCostNanos == nil
            || usage.codexPriorityCostNanos == nil
            || usage.codexStandardTokens == nil
            || usage.codexPriorityTokens == nil
    }

    static func codexFileUsageWithCostCache(
        _ usage: CostUsageFileUsage,
        context: CodexFileScanContext) -> CostUsageFileUsage
    {
        guard let rows = usage.codexRows, !rows.isEmpty else { return usage }
        var migratedRows: [CodexUsageRow] = []
        var retainedRows: [CodexUsageRow] = []
        for row in rows {
            if CostUsageDayRange.isInRange(
                dayKey: row.day,
                since: context.range.scanSinceKey,
                until: context.range.scanUntilKey)
            {
                migratedRows.append(row)
            } else {
                retainedRows.append(row)
            }
        }
        guard !migratedRows.isEmpty else { return usage }

        let splitMaps = Self.codexModeSplitMaps(
            rows: migratedRows,
            range: context.range,
            priorityTurns: context.resources.priorityTurns,
            modelsDevCatalog: context.resources.modelsDevCatalog,
            modelsDevCacheRoot: context.resources.modelsDevCacheRoot)
        var updated = usage
        updated.codexCostNanos = Self.mergeMissingCostMaps(
            usage.codexCostNanos,
            Self.codexCostNanos(
                rows: migratedRows,
                range: context.range,
                modelsDevCatalog: context.resources.modelsDevCatalog,
                modelsDevCacheRoot: context.resources.modelsDevCacheRoot))
        updated.codexPrioritySurchargeNanos = Self.mergeMissingCostMaps(
            usage.codexPrioritySurchargeNanos,
            Self.codexPrioritySurchargeNanos(
                rows: migratedRows,
                range: context.range,
                priorityTurns: context.resources.priorityTurns,
                modelsDevCatalog: context.resources.modelsDevCatalog,
                modelsDevCacheRoot: context.resources.modelsDevCacheRoot))
        updated.codexStandardCostNanos = Self.mergeMissingCostMaps(
            usage.codexStandardCostNanos,
            splitMaps.standardCostNanos)
        updated.codexPriorityCostNanos = Self.mergeMissingCostMaps(
            usage.codexPriorityCostNanos,
            splitMaps.priorityCostNanos)
        updated.codexStandardTokens = Self.mergeMissingIntMaps(
            usage.codexStandardTokens,
            splitMaps.standardTokens)
        updated.codexPriorityTokens = Self.mergeMissingIntMaps(
            usage.codexPriorityTokens,
            splitMaps.priorityTokens)
        updated.codexTurnIDs = Self.mergeCodexTurnIDs(usage.codexTurnIDs, rows: migratedRows)
        updated.codexRows = retainedRows.isEmpty ? nil : retainedRows
        return updated
    }

    static func codexMergedCostMap(
        _ existing: [String: [String: Int64]]?,
        deltaRows: [CodexUsageRow],
        context: CodexFileScanContext) -> [String: [String: Int64]]?
    {
        self.mergeCostMaps(
            existing,
            self.codexCostNanos(
                rows: deltaRows,
                range: context.range,
                modelsDevCatalog: context.resources.modelsDevCatalog,
                modelsDevCacheRoot: context.resources.modelsDevCacheRoot))
    }

    static func codexMergedPrioritySurchargeMap(
        _ existing: [String: [String: Int64]]?,
        deltaRows: [CodexUsageRow],
        context: CodexFileScanContext) -> [String: [String: Int64]]?
    {
        self.mergeCostMaps(
            existing,
            self.codexPrioritySurchargeNanos(
                rows: deltaRows,
                range: context.range,
                priorityTurns: context.resources.priorityTurns,
                modelsDevCatalog: context.resources.modelsDevCatalog,
                modelsDevCacheRoot: context.resources.modelsDevCacheRoot))
    }

    static func codexCostNanos(
        rows: [CodexUsageRow],
        range: CostUsageDayRange,
        modelsDevCatalog: ModelsDevCatalog?,
        modelsDevCacheRoot: URL?) -> [String: [String: Int64]]?
    {
        let rowsByDayModel = Self.codexRowsByDayModel(rows: rows, range: range)
        var out: [String: [String: Int64]] = [:]
        for (day, models) in rowsByDayModel {
            for (model, rows) in models {
                guard let cost = Self.codexRowsCostUSD(
                    rows: rows,
                    modelsDevCatalog: modelsDevCatalog,
                    modelsDevCacheRoot: modelsDevCacheRoot)
                else { continue }
                out[day, default: [:]][model] = Int64((cost * Self.costScale).rounded())
            }
        }
        return out.isEmpty ? nil : out
    }

    static func codexPrioritySurchargeNanos(
        rows: [CodexUsageRow],
        range: CostUsageDayRange,
        priorityTurns: [String: CodexPriorityTurnMetadata],
        modelsDevCatalog: ModelsDevCatalog?,
        modelsDevCacheRoot: URL?) -> [String: [String: Int64]]?
    {
        guard !priorityTurns.isEmpty else { return nil }
        let rowsByDayModel = Self.codexRowsByDayModel(rows: rows, range: range)
        var out: [String: [String: Int64]] = [:]
        for (day, models) in rowsByDayModel {
            for (model, rows) in models {
                guard let surcharge = Self.codexPrioritySurchargeUSD(
                    rows: rows,
                    priorityTurns: priorityTurns,
                    modelsDevCatalog: modelsDevCatalog,
                    modelsDevCacheRoot: modelsDevCacheRoot)
                else { continue }
                out[day, default: [:]][model] = Int64((surcharge * Self.costScale).rounded())
            }
        }
        return out.isEmpty ? nil : out
    }

    static func codexModeSplitMaps(
        rows: [CodexUsageRow],
        range: CostUsageDayRange,
        priorityTurns: [String: CodexPriorityTurnMetadata],
        modelsDevCatalog: ModelsDevCatalog?,
        modelsDevCacheRoot: URL?) -> (
        standardCostNanos: [String: [String: Int64]]?,
        priorityCostNanos: [String: [String: Int64]]?,
        standardTokens: [String: [String: Int]]?,
        priorityTokens: [String: [String: Int]]?)
    {
        var standardCostNanos: [String: [String: Int64]] = [:]
        var priorityCostNanos: [String: [String: Int64]] = [:]
        var standardTokens: [String: [String: Int]] = [:]
        var priorityTokens: [String: [String: Int]] = [:]

        for row in rows {
            guard CostUsageDayRange.isInRange(dayKey: row.day, since: range.sinceKey, until: range.untilKey)
            else { continue }

            let tokenCount = row.input + row.output
            let priorityMetadata = row.turnID.flatMap { priorityTurns[$0] }
            let pricedModel = priorityMetadata.map { Self.codexPriorityPricingModel(for: row, priorityMetadata: $0) }
                ?? row.model
            let isPriority = priorityMetadata != nil

            if isPriority {
                priorityTokens[row.day, default: [:]][row.model, default: 0] += tokenCount
            } else {
                standardTokens[row.day, default: [:]][row.model, default: 0] += tokenCount
            }

            let baseCost = CostUsagePricing.codexCostUSD(
                model: pricedModel,
                inputTokens: row.input,
                cachedInputTokens: row.cached,
                outputTokens: row.output,
                modelsDevCatalog: modelsDevCatalog,
                modelsDevCacheRoot: modelsDevCacheRoot)

            if isPriority, let priorityCost = CostUsagePricing.codexPriorityCostUSD(
                model: pricedModel,
                inputTokens: row.input,
                cachedInputTokens: row.cached,
                outputTokens: row.output)
            {
                priorityCostNanos[row.day, default: [:]][row.model, default: 0] += Int64(
                    (max(priorityCost, baseCost ?? priorityCost) * Self.costScale).rounded())
            } else if isPriority, let baseCost {
                priorityCostNanos[row.day, default: [:]][row.model, default: 0] += Int64(
                    (baseCost * Self.costScale).rounded())
            } else if let baseCost {
                standardCostNanos[row.day, default: [:]][row.model, default: 0] += Int64(
                    (baseCost * Self.costScale).rounded())
            }
        }

        return (
            standardCostNanos.isEmpty ? nil : standardCostNanos,
            priorityCostNanos.isEmpty ? nil : priorityCostNanos,
            standardTokens.isEmpty ? nil : standardTokens,
            priorityTokens.isEmpty ? nil : priorityTokens)
    }

    static func codexTurnIDs(rows: [CodexUsageRow]) -> [String]? {
        let ids = Set(rows.compactMap(\.turnID))
        return ids.sorted()
    }

    static func mergeCodexTurnIDs(_ existing: [String]?, rows: [CodexUsageRow]) -> [String]? {
        var ids = Set(existing ?? [])
        ids.formUnion(rows.compactMap(\.turnID))
        return ids.sorted()
    }

    static func mergeCostMaps(
        _ existing: [String: [String: Int64]]?,
        _ delta: [String: [String: Int64]]?) -> [String: [String: Int64]]?
    {
        var out = existing ?? [:]
        for (day, models) in delta ?? [:] {
            for (model, value) in models {
                out[day, default: [:]][model, default: 0] += value
            }
        }
        return out.isEmpty ? nil : out
    }

    static func mergeMissingCostMaps(
        _ existing: [String: [String: Int64]]?,
        _ delta: [String: [String: Int64]]?) -> [String: [String: Int64]]?
    {
        var out = existing ?? [:]
        for (day, models) in delta ?? [:] {
            for (model, value) in models where out[day]?[model] == nil {
                out[day, default: [:]][model] = value
            }
        }
        return out.isEmpty ? nil : out
    }

    static func mergeIntMaps(
        _ existing: [String: [String: Int]]?,
        _ delta: [String: [String: Int]]?) -> [String: [String: Int]]?
    {
        var out = existing ?? [:]
        for (day, models) in delta ?? [:] {
            for (model, value) in models {
                out[day, default: [:]][model, default: 0] += value
            }
        }
        return out.isEmpty ? nil : out
    }

    static func mergeMissingIntMaps(
        _ existing: [String: [String: Int]]?,
        _ delta: [String: [String: Int]]?) -> [String: [String: Int]]?
    {
        var out = existing ?? [:]
        for (day, models) in delta ?? [:] {
            for (model, value) in models where out[day]?[model] == nil {
                out[day, default: [:]][model] = value
            }
        }
        return out.isEmpty ? nil : out
    }

    static func costMapOutsideScanWindow(
        _ map: [String: [String: Int64]]?,
        range: CostUsageDayRange) -> [String: [String: Int64]]?
    {
        let filtered = (map ?? [:]).filter {
            !CostUsageDayRange.isInRange(dayKey: $0.key, since: range.scanSinceKey, until: range.scanUntilKey)
        }
        return filtered.isEmpty ? nil : filtered
    }

    static func intMapOutsideScanWindow(
        _ map: [String: [String: Int]]?,
        range: CostUsageDayRange) -> [String: [String: Int]]?
    {
        let filtered = (map ?? [:]).filter {
            !CostUsageDayRange.isInRange(dayKey: $0.key, since: range.scanSinceKey, until: range.scanUntilKey)
        }
        return filtered.isEmpty ? nil : filtered
    }

    // MARK: - File scan orchestration

    struct CodexFileMetadata {
        let path: String
        let mtimeUnixMs: Int64
        let size: Int64
        let fileId: String?
    }

    struct CodexFileScanInput {
        let fileURL: URL
        let metadata: CodexFileMetadata
        let target: CodexFrozenFile
        let cached: CostUsageFileUsage?
    }

    struct CodexParsedCoverage: Equatable {
        let mtimeUnixMs: Int64
        let size: Int64
        let scanComplete: Bool
    }

    private static func codexModeIsRegular(_ mode: mode_t) -> Bool {
        (mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
    }

    private static func codexRelativeComponents(
        fileURL: URL,
        withinRoot root: URL) -> [String]?
    {
        let rootPath = root.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard filePath.hasPrefix(prefix) else { return nil }
        let relative = String(filePath.dropFirst(prefix.count))
        let components = relative.split(separator: "/").map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { return nil }
        return components
    }

    static func codexContainingRoot(fileURL: URL, roots: [URL]) -> URL? {
        roots
            .filter { Self.codexRelativeComponents(fileURL: fileURL, withinRoot: $0) != nil }
            .max { $0.standardizedFileURL.path.count < $1.standardizedFileURL.path.count }
    }

    /// Foundation can expose the same macOS temporary file as `/var/...` or
    /// `/private/var/...` depending on which directory API produced the URL.
    /// Pending manifests must use one spelling or a single inode can be scanned
    /// twice and keep seeding catch-up generations forever.
    static func codexFrozenManifestUsesCanonicalPaths(
        _ manifest: [String: CodexFrozenFile]) -> Bool
    {
        var seen: Set<String> = []
        for path in manifest.keys {
            let canonicalPath = URL(fileURLWithPath: path).standardizedFileURL.path
            guard path == canonicalPath, seen.insert(canonicalPath).inserted else {
                return false
            }
        }
        return true
    }

    /// Produces a stable identity for cache keys even after the leaf vanished.
    /// Foundation can spell the same macOS temporary tree as `/var/...` or
    /// `/private/var/...`; resolving the nearest existing ancestor makes those
    /// aliases comparable without requiring the frozen file to remain present.
    static func codexCachePathIdentity(_ path: String) -> String {
        var existingAncestor = URL(fileURLWithPath: path).standardizedFileURL
        var missingComponents: [String] = []
        while existingAncestor.path != "/",
              !FileManager.default.fileExists(atPath: existingAncestor.path)
        {
            missingComponents.append(existingAncestor.lastPathComponent)
            existingAncestor.deleteLastPathComponent()
        }

        var identity = existingAncestor.resolvingSymlinksInPath().standardizedFileURL
        for component in missingComponents.reversed() {
            identity.appendPathComponent(component)
        }
        return identity.standardizedFileURL.path
    }

    /// Replaces every partial/aliased working contribution for one frozen path
    /// with exactly one committed last-good contribution. This prevents a
    /// transient delete, replace, or read failure during resume from shrinking
    /// the snapshot that is published while a catch-up generation is seeded.
    @discardableResult
    static func restoreCommittedCodexFile(
        path: String,
        committedFiles: [String: CostUsageFileUsage],
        cache: inout CostUsageCache) -> CostUsageFileUsage?
    {
        let canonicalPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let pathIdentity = Self.codexCachePathIdentity(canonicalPath)
        let workingKeys = cache.files.keys.filter {
            Self.codexCachePathIdentity($0) == pathIdentity
        }
        for key in workingKeys {
            guard let partial = cache.files.removeValue(forKey: key) else { continue }
            Self.applyFileDays(cache: &cache, fileDays: partial.days, sign: -1)
        }

        let committedCandidates = committedFiles
            .filter { Self.codexCachePathIdentity($0.key) == pathIdentity }
            .sorted { lhs, rhs in
                let lhsExact = lhs.key == canonicalPath
                let rhsExact = rhs.key == canonicalPath
                if lhsExact != rhsExact { return lhsExact }
                return lhs.key < rhs.key
            }
        guard let committed = committedCandidates.first?.value else { return nil }
        cache.files[canonicalPath] = committed
        Self.applyFileDays(cache: &cache, fileDays: committed.days, sign: 1)
        return committed
    }

    /// Open without following any symlink below a trusted sessions root and
    /// without ever waiting on a FIFO. Directory descriptors close path-swap
    /// races; the final fstat rejects every non-regular input.
    static func codexOpenRegularFileForReading(
        fileURL: URL,
        withinRoot root: URL? = nil) throws -> FileHandle
    {
        let descriptor: Int32
        if let root {
            guard let components = Self.codexRelativeComponents(
                fileURL: fileURL,
                withinRoot: root)
            else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) }

            let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
            var current = resolvedRoot.path.withCString {
                open($0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC | O_DIRECTORY)
            }
            guard current >= 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }

            for (index, component) in components.enumerated() {
                let isLast = index == components.count - 1
                let flags = isLast
                    ? O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                    : O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC | O_DIRECTORY
                let next = component.withCString { openat(current, $0, flags) }
                let failure = errno
                close(current)
                guard next >= 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure))
                }
                current = next
            }
            descriptor = current
        } else {
            descriptor = fileURL.path.withCString {
                open($0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            }
        }
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              Self.codexModeIsRegular(info.st_mode)
        else {
            let failure = errno == 0 ? EINVAL : errno
            close(descriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure))
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    static func codexFileMetadata(
        fileURL: URL,
        withinRoot root: URL? = nil) -> CodexFileMetadata
    {
        let path = fileURL.standardizedFileURL.path
        var info = stat()
        let metadataResult: Int32
        if let handle = try? Self.codexOpenRegularFileForReading(
            fileURL: fileURL,
            withinRoot: root)
        {
            metadataResult = fstat(handle.fileDescriptor, &info)
            try? handle.close()
        } else {
            metadataResult = -1
        }
        guard metadataResult == 0,
            Self.codexModeIsRegular(info.st_mode)
        else {
            return CodexFileMetadata(path: path, mtimeUnixMs: 0, size: 0, fileId: nil)
        }
        #if os(Linux)
        let modifiedSeconds = Int64(info.st_mtim.tv_sec)
        let modifiedNanoseconds = Int64(info.st_mtim.tv_nsec)
        #else
        let modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
        let modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        #endif
        return CodexFileMetadata(
            path: path,
            mtimeUnixMs: modifiedSeconds * 1000 + modifiedNanoseconds / 1_000_000,
            size: Int64(info.st_size),
            fileId: "\(info.st_dev):\(info.st_ino)")
    }

    /// Capture a stable append-only JSONL boundary. A trailing partial record
    /// is deferred so the next generation can parse it from its first byte.
    static func codexFrozenFile(
        fileURL: URL,
        withinRoot root: URL? = nil,
        minimumKnownCompleteEOF: Int64 = 0) -> CodexFrozenFile?
    {
        let metadata = Self.codexFileMetadata(fileURL: fileURL, withinRoot: root)
        guard let fileId = metadata.fileId, metadata.size >= 0 else { return nil }
        let targetEOF = Self.codexCompleteRecordEOF(
            fileURL: fileURL,
            observedSize: metadata.size,
            withinRoot: root,
            minimumKnownCompleteEOF: minimumKnownCompleteEOF)
        guard let contentFingerprint = Self.codexFrozenPrefixFingerprint(
            fileURL: fileURL,
            targetEOF: targetEOF,
            withinRoot: root)
        else { return nil }
        return CodexFrozenFile(
            fileId: fileId,
            mtimeUnixMs: metadata.mtimeUnixMs,
            observedSize: metadata.size,
            targetEOF: targetEOF,
            contentFingerprint: contentFingerprint)
    }

    static func codexFrozenPrefixFingerprint(
        fileURL: URL,
        targetEOF: Int64,
        withinRoot root: URL? = nil) -> String?
    {
        guard targetEOF >= 0,
              let handle = try? Self.codexOpenRegularFileForReading(
                  fileURL: fileURL,
                  withinRoot: root)
        else { return nil }
        defer { try? handle.close() }

        let sampleSize = Int64(16 * 1024)
        let offsets = Self.codexFrozenPrefixSampleOffsets(
            targetEOF: targetEOF,
            sampleSize: sampleSize)
        var material = Data("codex-frozen-prefix-sample-v2\0\(targetEOF)\0".utf8)
        do {
            for offset in offsets where offset < targetEOF {
                let count = Int(min(sampleSize, targetEOF - offset))
                try handle.seek(toOffset: UInt64(offset))
                let sample = try handle.read(upToCount: count) ?? Data()
                guard sample.count == count else { return nil }
                material.append(Data("\(offset):\(count)\0".utf8))
                material.append(sample)
            }
            return "sha256-sample-v2:" + SHA256.hash(data: material)
                .map { String(format: "%02x", $0) }
                .joined()
        } catch {
            return nil
        }
    }

    /// Distributed sample positions without multiplying the potentially huge
    /// sparse-file EOF. Every intermediate stays inside signed Int64 bounds.
    static func codexFrozenPrefixSampleOffsets(
        targetEOF: Int64,
        sampleSize: Int64) -> [Int64]
    {
        guard targetEOF >= 0, sampleSize > 0 else { return [] }
        let halfSample = sampleSize / 2
        let quarter = targetEOF / 4
        let remainder = targetEOF % 4
        let threeQuarters = quarter * 3 + (remainder * 3) / 4
        func sampleStart(center: Int64) -> Int64 {
            center > halfSample ? center - halfSample : 0
        }
        let finalSample = targetEOF > sampleSize ? targetEOF - sampleSize : 0
        return Set([
            Int64(0),
            sampleStart(center: quarter),
            sampleStart(center: targetEOF / 2),
            sampleStart(center: threeQuarters),
            finalSample,
        ]).sorted()
    }

    private static func codexCompleteRecordEOF(
        fileURL: URL,
        observedSize: Int64,
        withinRoot root: URL? = nil,
        minimumKnownCompleteEOF: Int64 = 0) -> Int64
    {
        let safeKnownEOF = min(max(0, minimumKnownCompleteEOF), max(0, observedSize))
        guard observedSize > 0,
              let handle = try? Self.codexOpenRegularFileForReading(
                  fileURL: fileURL,
                  withinRoot: root)
        else { return safeKnownEOF }
        defer { try? handle.close() }
        do {
            let chunkSize = Int64(512 * 1024)
            let minimumOffset = max(safeKnownEOF, observedSize - 4 * 1024 * 1024)
            var end = observedSize
            var trailingRecord = Data()
            var canValidateTrailingRecord = true

            while end > minimumOffset {
                let start = max(minimumOffset, end - chunkSize)
                try handle.seek(toOffset: UInt64(start))
                let chunk = try handle.read(upToCount: Int(end - start)) ?? Data()
                guard Int64(chunk.count) == end - start else { return safeKnownEOF }

                if end == observedSize, chunk.last == 0x0A {
                    return observedSize
                }
                if let newline = chunk.lastIndex(of: 0x0A) {
                    let suffixStart = chunk.index(after: newline)
                    if canValidateTrailingRecord {
                        var candidate = Data(chunk[suffixStart...])
                        candidate.append(trailingRecord)
                        if !candidate.isEmpty,
                           (try? JSONSerialization.jsonObject(with: candidate)) != nil
                        {
                            return observedSize
                        }
                    }
                    return start + Int64(chunk.distance(
                        from: chunk.startIndex,
                        to: chunk.index(after: newline)))
                }

                if canValidateTrailingRecord,
                   trailingRecord.count + chunk.count <= Int(chunkSize)
                {
                    trailingRecord.insert(contentsOf: chunk, at: 0)
                } else {
                    trailingRecord.removeAll(keepingCapacity: false)
                    canValidateTrailingRecord = false
                }
                end = start
            }

            if minimumOffset == 0,
               canValidateTrailingRecord,
               (try? JSONSerialization.jsonObject(with: trailingRecord)) != nil
            {
                return observedSize
            }
            return safeKnownEOF
        } catch {
            return safeKnownEOF
        }
    }

    /// Compare the bytes that can affect a generation. Growth beyond the same
    /// complete-record EOF is only an unfinished append and must not create an
    /// endless series of catch-up generations.
    static func codexFrozenManifestsHaveSameFrontier(
        _ lhs: [String: CodexFrozenFile],
        _ rhs: [String: CodexFrozenFile]) -> Bool
    {
        guard lhs.count == rhs.count else { return false }
        return lhs.allSatisfy { path, old in
            guard let current = rhs[path],
                  old.fileId == current.fileId,
                  old.targetEOF == current.targetEOF,
                  old.contentFingerprint != nil,
                  old.contentFingerprint == current.contentFingerprint
            else { return false }

            if current.observedSize > old.observedSize {
                return true
            }
            return current.observedSize == old.observedSize
                && current.mtimeUnixMs == old.mtimeUnixMs
        }
    }

    static func codexFrozenFileIsReadable(
        _ target: CodexFrozenFile,
        current: CodexFileMetadata,
        fileURL: URL? = nil,
        withinRoot root: URL? = nil) -> Bool
    {
        guard current.fileId == target.fileId,
              target.targetEOF >= 0,
              target.targetEOF <= target.observedSize,
              current.size >= target.observedSize
        else { return false }
        guard current.size > target.observedSize || current.mtimeUnixMs == target.mtimeUnixMs
        else { return false }
        if let expected = target.contentFingerprint {
            guard let fileURL,
                  Self.codexFrozenPrefixFingerprint(
                      fileURL: fileURL,
                      targetEOF: target.targetEOF,
                      withinRoot: root) == expected
            else { return false }
        }
        return true
    }

    /// Normalize the persisted target to bytes the parser actually covered.
    /// A post-parse append remains pending instead of being marked fresh.
    static func codexParsedCoverage(
        fileURL: URL,
        target: CodexFrozenFile,
        parsedBytes: Int64,
        scanComplete: Bool,
        withinRoot root: URL? = nil) -> CodexParsedCoverage?
    {
        let current = Self.codexFileMetadata(fileURL: fileURL, withinRoot: root)
        guard Self.codexFrozenFileIsReadable(
            target,
            current: current,
            fileURL: fileURL,
            withinRoot: root),
              parsedBytes >= 0,
              parsedBytes <= target.targetEOF
        else { return nil }

        return CodexParsedCoverage(
            mtimeUnixMs: target.mtimeUnixMs,
            size: target.targetEOF,
            scanComplete: scanComplete && parsedBytes == target.targetEOF)
    }

    static func retainKnownGoodCodexFileAsIncomplete(
        input: CodexFileScanInput,
        context: CodexFileScanContext,
        cache: inout CostUsageCache)
    {
        if var cached = input.cached {
            cached.codexScanComplete = false
            cached.codexScanGeneration = context.scanGeneration
            cached.codexScanTargetSize = input.target.targetEOF
            cache.files[input.metadata.path] = cached
            return
        }
        cache.files[input.metadata.path] = Self.makeFileUsage(
            mtimeUnixMs: input.target.mtimeUnixMs,
            size: input.target.targetEOF,
            days: [:],
            parsedBytes: 0,
            codexScanFileId: input.target.fileId,
            codexScanTargetSize: input.target.targetEOF,
            codexScanContentFingerprint: input.target.contentFingerprint,
            codexScanComplete: false,
            codexScanGeneration: context.scanGeneration)
    }

    static func dropCachedCodexFile(
        path: String,
        cached: CostUsageFileUsage?,
        cache: inout CostUsageCache)
    {
        if let cached {
            self.applyFileDays(cache: &cache, fileDays: cached.days, sign: -1)
        }
        cache.files.removeValue(forKey: path)
    }

    static func rememberScannedCodexFile(
        fileURL: URL,
        metadata: CodexFileMetadata,
        sessionId: String?,
        context: CodexFileScanContext,
        state: inout CodexScanState)
    {
        if let sessionId {
            state.seenSessionIds.insert(sessionId)
            if state.sessionFilePaths[sessionId] == nil {
                state.sessionFilePaths[sessionId] = metadata.path
            }
            context.resources.fileIndex.remember(fileURL: fileURL, sessionId: sessionId)
        }
        if let fileId = metadata.fileId {
            state.seenFileIds.insert(fileId)
        }
    }

    static func reconcileDuplicateCodexProject(
        sessionId: String,
        projectKey: String?,
        projectName: String?,
        projectAttributionAmbiguous: Bool,
        cache: inout CostUsageCache,
        state: inout CodexScanState)
    {
        guard let retainedPath = state.sessionFilePaths[sessionId],
              var retained = cache.files[retainedPath]
        else { return }
        let conflict = retained.projectKey != nil
            && projectKey != nil
            && retained.projectKey != projectKey
        let ambiguous = state.ambiguousProjectSessionIds.contains(sessionId)
            || retained.projectAttributionAmbiguous == true
            || projectAttributionAmbiguous
            || conflict
        if ambiguous {
            if let oldKey = retained.projectKey ?? retained.projectRetractionKey {
                retained.projectRetractionKey = oldKey
                retained.projectRetractionID = retained.projectRetractionID
                    ?? Self.codexProjectRetractionID(sessionId: sessionId, projectKey: oldKey)
            }
            retained.projectKey = nil
            retained.projectName = nil
            retained.projectAttributionAmbiguous = true
            state.ambiguousProjectSessionIds.insert(sessionId)
        } else if retained.projectKey == nil, let projectKey {
            retained.projectKey = projectKey
            retained.projectName = projectName
        }
        cache.files[retainedPath] = retained
    }

    private static func codexProjectRetractionID(
        sessionId: String,
        projectKey: String) -> String
    {
        let value = "codex:project-retraction-v1\0\(sessionId)\0\(projectKey)"
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func keepCachedCodexFileIfFresh(
        input: CodexFileScanInput,
        context: CodexFileScanContext,
        cache: inout CostUsageCache,
        state: inout CodexScanState) -> Bool
    {
        guard let cached = input.cached else { return false }
        let needsSessionId = cached.sessionId == nil && cached.codexParseResumeState == nil
        let completedCurrentGeneration = cached.codexScanGeneration == context.scanGeneration
            && cached.codexScanComplete == true
        guard cached.mtimeUnixMs == input.target.mtimeUnixMs,
              cached.size == input.target.targetEOF,
              cached.codexScanFileId == input.target.fileId,
              cached.codexScanContentFingerprint != nil,
              cached.codexScanContentFingerprint == input.target.contentFingerprint,
              !needsSessionId,
              cached.codexScanComplete != false,
              (!context.forceFullScan || completedCurrentGeneration)
        else { return false }

        guard !Self.cachedCodexFileNeedsPriorityRescan(cached, context: context) else { return false }

        if Self.needsCodexCostCache(cached, range: context.range) {
            cache.files[input.metadata.path] = Self.codexFileUsageWithCostCache(cached, context: context)
        }
        Self.rememberScannedCodexFile(
            fileURL: input.fileURL,
            metadata: input.metadata,
            sessionId: cached.sessionId,
            context: context,
            state: &state)
        return true
    }

    static func cachedCodexFileNeedsPriorityRescan(
        _ cached: CostUsageFileUsage,
        context: CodexFileScanContext) -> Bool
    {
        if cached.codexTurnIDs == nil {
            return context.requiresTurnIDCache
        }
        guard !context.changedPriorityTurnIDs.isEmpty else { return false }
        return !(Set(cached.codexTurnIDs ?? []).isDisjoint(with: context.changedPriorityTurnIDs))
    }

    static func appendCodexFileIncrementIfPossible(
        input: CodexFileScanInput,
        context: CodexFileScanContext,
        cache: inout CostUsageCache,
        state: inout CodexScanState) throws -> Bool
    {
        try context.checkCancellation?()
        guard let cached = input.cached else { return false }
        let root = Self.codexContainingRoot(fileURL: input.fileURL, roots: context.roots)
        guard context.roots.isEmpty || root != nil else { return false }
        let sameFileId = cached.codexScanFileId != nil
            && cached.codexScanFileId == input.target.fileId
        let currentCachedPrefixFingerprint = cached.size == input.target.targetEOF
            ? input.target.contentFingerprint
            : Self.codexFrozenPrefixFingerprint(
                fileURL: input.fileURL,
                targetEOF: cached.size,
                withinRoot: root)
        let sameCachedPrefix = cached.codexScanContentFingerprint != nil
            && cached.codexScanContentFingerprint == currentCachedPrefixFingerprint
        let unchangedPendingFile = cached.codexScanTargetSize == input.target.targetEOF
            && cached.size == input.target.targetEOF
        let resumesCurrentGeneration = cached.codexScanGeneration == context.scanGeneration
            && cached.codexScanComplete == false
            && sameFileId
            && sameCachedPrefix
            && unchangedPendingFile
        guard !context.forceFullScan || resumesCurrentGeneration else { return false }
        guard !Self.cachedCodexFileNeedsPriorityRescan(cached, context: context) else { return false }
        let startOffset = cached.parsedBytes ?? cached.size
        let initialCountedTotals = cached.lastCountedTotals ?? cached.lastTotals
        let initialRawTotalsBaseline = cached.lastRawTotalsBaseline ?? cached.lastTotals
        let resumeState = cached.codexParseResumeState
        let hasCompatibleForkState = cached.forkedFromId == nil || (
            resumeState?.forkedFromId == cached.forkedFromId
                && resumeState?.sessionId == cached.sessionId)
        let canIncremental = (input.target.targetEOF > (cached.parsedBytes ?? 0) || resumesCurrentGeneration)
            && startOffset > 0
            && startOffset <= cached.size
            && startOffset <= input.target.targetEOF
            && sameFileId
            && sameCachedPrefix
            && (initialCountedTotals != nil || resumeState != nil)
            && hasCompatibleForkState
        guard canIncremental else { return false }

        let delta = try Self.parseCodexFileCancellable(
            fileURL: input.fileURL,
            range: context.range,
            startOffset: startOffset,
            initialModel: cached.lastModel,
            initialTotals: initialCountedTotals,
            initialRawTotalsBaseline: initialRawTotalsBaseline,
            initialHasDivergentTotals: cached.hasDivergentTotals ?? (cached.lastTotals == nil),
            initialCodexTurnID: cached.lastCodexTurnID,
            initialResumeState: resumeState,
            checkCancellation: context.checkCancellation,
            shouldStop: context.shouldStop,
            endOffset: input.target.targetEOF,
            withinRoot: root)
        if delta.forkedFromId != cached.forkedFromId {
            return false
        }
        guard let coverage = Self.codexParsedCoverage(
            fileURL: input.fileURL,
            target: input.target,
            parsedBytes: delta.parsedBytes,
            scanComplete: delta.scanComplete,
            withinRoot: root)
        else {
            Self.retainKnownGoodCodexFileAsIncomplete(
                input: input, context: context, cache: &cache)
            return true
        }
        let sessionId = delta.sessionId ?? cached.sessionId
        if let sessionId, state.seenSessionIds.contains(sessionId) {
            let projectConflict = cached.projectKey != nil
                && delta.projectKey != nil
                && cached.projectKey != delta.projectKey
            let projectAmbiguous = cached.projectAttributionAmbiguous == true
                || delta.projectAttributionAmbiguous
                || projectConflict
            Self.reconcileDuplicateCodexProject(
                sessionId: sessionId,
                projectKey: projectAmbiguous ? nil : (delta.projectKey ?? cached.projectKey),
                projectName: projectAmbiguous ? nil : (delta.projectName ?? cached.projectName),
                projectAttributionAmbiguous: projectAmbiguous,
                cache: &cache,
                state: &state)
            Self.dropCachedCodexFile(path: input.metadata.path, cached: cached, cache: &cache)
            return true
        }

        let migratedCached = Self.codexFileUsageWithCostCache(cached, context: context)
        if !delta.days.isEmpty {
            Self.applyFileDays(cache: &cache, fileDays: delta.days, sign: 1)
        }

        var mergedDays = migratedCached.days
        Self.mergeFileDays(existing: &mergedDays, delta: delta.days)
        let splitMaps = Self.codexModeSplitMaps(
            rows: delta.rows,
            range: context.range,
            priorityTurns: context.resources.priorityTurns,
            modelsDevCatalog: context.resources.modelsDevCatalog,
            modelsDevCacheRoot: context.resources.modelsDevCacheRoot)
        let projectConflict = migratedCached.projectKey != nil
            && delta.projectKey != nil
            && migratedCached.projectKey != delta.projectKey
        let projectAmbiguous = migratedCached.projectAttributionAmbiguous == true
            || delta.projectAttributionAmbiguous
            || projectConflict
        let retractionKey = migratedCached.projectRetractionKey
            ?? (projectAmbiguous ? migratedCached.projectKey : nil)
        let retractionID = migratedCached.projectRetractionID
            ?? retractionKey.flatMap { key in
                sessionId.map { Self.codexProjectRetractionID(sessionId: $0, projectKey: key) }
            }
        cache.files[input.metadata.path] = Self.makeFileUsage(
            mtimeUnixMs: coverage.mtimeUnixMs,
            size: coverage.size,
            days: mergedDays,
            parsedBytes: delta.parsedBytes,
            lastModel: delta.lastModel,
            lastTotals: delta.lastTotals,
            lastCountedTotals: delta.lastCountedTotals,
            lastRawTotalsBaseline: delta.lastRawTotalsBaseline,
            hasDivergentTotals: delta.hasDivergentTotals,
            lastCodexTurnID: delta.lastCodexTurnID,
            sessionId: sessionId,
            forkedFromId: delta.forkedFromId ?? migratedCached.forkedFromId,
            projectKey: projectAmbiguous ? nil : (delta.projectKey ?? migratedCached.projectKey),
            projectName: projectAmbiguous ? nil : (delta.projectName ?? migratedCached.projectName),
            projectAttributionAmbiguous: projectAmbiguous,
            projectRetractionID: retractionID,
            projectRetractionKey: retractionKey,
            codexCostNanos: Self.codexMergedCostMap(
                migratedCached.codexCostNanos,
                deltaRows: delta.rows,
                context: context),
            codexPrioritySurchargeNanos: Self.codexMergedPrioritySurchargeMap(
                migratedCached.codexPrioritySurchargeNanos,
                deltaRows: delta.rows,
                context: context),
            codexStandardCostNanos: Self.mergeCostMaps(
                migratedCached.codexStandardCostNanos,
                splitMaps.standardCostNanos),
            codexPriorityCostNanos: Self.mergeCostMaps(
                migratedCached.codexPriorityCostNanos,
                splitMaps.priorityCostNanos),
            codexStandardTokens: Self.mergeIntMaps(
                migratedCached.codexStandardTokens,
                splitMaps.standardTokens),
            codexPriorityTokens: Self.mergeIntMaps(
                migratedCached.codexPriorityTokens,
                splitMaps.priorityTokens),
            codexTurnIDs: Self.mergeCodexTurnIDs(migratedCached.codexTurnIDs, rows: delta.rows),
            codexRows: migratedCached.codexRows,
            codexScanFileId: input.target.fileId,
            codexScanTargetSize: input.target.targetEOF,
            codexScanContentFingerprint: input.target.contentFingerprint,
            codexScanComplete: coverage.scanComplete,
            codexScanGeneration: context.scanGeneration,
            codexParseResumeState: delta.resumeState)
        Self.rememberScannedCodexFile(
            fileURL: input.fileURL,
            metadata: input.metadata,
            sessionId: sessionId,
            context: context,
            state: &state)
        return true
    }

    static func rescanCodexFile(
        input: CodexFileScanInput,
        context: CodexFileScanContext,
        cache: inout CostUsageCache,
        state: inout CodexScanState) throws
    {
        try context.checkCancellation?()
        let root = Self.codexContainingRoot(fileURL: input.fileURL, roots: context.roots)
        guard context.roots.isEmpty || root != nil else {
            Self.retainKnownGoodCodexFileAsIncomplete(
                input: input,
                context: context,
                cache: &cache)
            return
        }
        if let cached = input.cached {
            self.applyFileDays(cache: &cache, fileDays: cached.days, sign: -1)
        }
        let migratedCached = input.cached.map { Self.codexFileUsageWithCostCache($0, context: context) }
        var usageDays = context.dropDeferredCodexRows
            ? [:]
            : Self.fileDaysOutsideScanWindow(migratedCached?.days ?? [:], range: context.range)

        let parsed = try Self.parseCodexFileCancellable(
            fileURL: input.fileURL,
            range: context.range,
            inheritedTotalsResolver: context.resources.inheritedResolver.inheritedTotals(for:atOrBefore:),
            checkCancellation: context.checkCancellation,
            shouldStop: context.shouldStop,
            endOffset: input.target.targetEOF,
            withinRoot: root)
        guard let coverage = Self.codexParsedCoverage(
            fileURL: input.fileURL,
            target: input.target,
            parsedBytes: parsed.parsedBytes,
            scanComplete: parsed.scanComplete,
            withinRoot: root)
        else {
            if let cached = input.cached {
                Self.applyFileDays(cache: &cache, fileDays: cached.days, sign: 1)
            }
            Self.retainKnownGoodCodexFileAsIncomplete(
                input: input, context: context, cache: &cache)
            return
        }
        let sessionId = parsed.sessionId ?? input.cached?.sessionId
        if let sessionId, state.seenSessionIds.contains(sessionId) {
            Self.reconcileDuplicateCodexProject(
                sessionId: sessionId,
                projectKey: parsed.projectKey,
                projectName: parsed.projectName,
                projectAttributionAmbiguous: parsed.projectAttributionAmbiguous,
                cache: &cache,
                state: &state)
            cache.files.removeValue(forKey: input.metadata.path)
            return
        }
        Self.mergeFileDays(existing: &usageDays, delta: parsed.days)
        let splitMaps = Self.codexModeSplitMaps(
            rows: parsed.rows,
            range: context.range,
            priorityTurns: context.resources.priorityTurns,
            modelsDevCatalog: context.resources.modelsDevCatalog,
            modelsDevCacheRoot: context.resources.modelsDevCacheRoot)

        let projectConflict = migratedCached?.projectKey != nil
            && parsed.projectKey != nil
            && migratedCached?.projectKey != parsed.projectKey
        let projectAmbiguous = parsed.projectAttributionAmbiguous || projectConflict
        let retractionKey = migratedCached?.projectRetractionKey
            ?? (projectAmbiguous ? migratedCached?.projectKey : nil)
        let retractionID = migratedCached?.projectRetractionID
            ?? retractionKey.flatMap { key in
                sessionId.map { Self.codexProjectRetractionID(sessionId: $0, projectKey: key) }
            }
        cache.files[input.metadata.path] = Self.makeFileUsage(
            mtimeUnixMs: coverage.mtimeUnixMs,
            size: coverage.size,
            days: usageDays,
            parsedBytes: parsed.parsedBytes,
            lastModel: parsed.lastModel,
            lastTotals: parsed.lastTotals,
            lastCountedTotals: parsed.lastCountedTotals,
            lastRawTotalsBaseline: parsed.lastRawTotalsBaseline,
            hasDivergentTotals: parsed.hasDivergentTotals,
            lastCodexTurnID: parsed.lastCodexTurnID,
            sessionId: sessionId,
            forkedFromId: parsed.forkedFromId,
            projectKey: projectAmbiguous ? nil : parsed.projectKey,
            projectName: projectAmbiguous ? nil : parsed.projectName,
            projectAttributionAmbiguous: projectAmbiguous,
            projectRetractionID: retractionID,
            projectRetractionKey: retractionKey,
            codexCostNanos: Self.mergeCostMaps(
                context.dropDeferredCodexRows
                    ? nil
                    : Self.costMapOutsideScanWindow(migratedCached?.codexCostNanos, range: context.range),
                Self.codexCostNanos(
                    rows: parsed.rows,
                    range: context.range,
                    modelsDevCatalog: context.resources.modelsDevCatalog,
                    modelsDevCacheRoot: context.resources.modelsDevCacheRoot)),
            codexPrioritySurchargeNanos: Self.mergeCostMaps(
                context.dropDeferredCodexRows
                    ? nil
                    : Self.costMapOutsideScanWindow(migratedCached?.codexPrioritySurchargeNanos, range: context.range),
                Self.codexPrioritySurchargeNanos(
                    rows: parsed.rows,
                    range: context.range,
                    priorityTurns: context.resources.priorityTurns,
                    modelsDevCatalog: context.resources.modelsDevCatalog,
                    modelsDevCacheRoot: context.resources.modelsDevCacheRoot)),
            codexStandardCostNanos: Self.mergeCostMaps(
                context.dropDeferredCodexRows
                    ? nil
                    : Self.costMapOutsideScanWindow(migratedCached?.codexStandardCostNanos, range: context.range),
                splitMaps.standardCostNanos),
            codexPriorityCostNanos: Self.mergeCostMaps(
                context.dropDeferredCodexRows
                    ? nil
                    : Self.costMapOutsideScanWindow(migratedCached?.codexPriorityCostNanos, range: context.range),
                splitMaps.priorityCostNanos),
            codexStandardTokens: Self.mergeIntMaps(
                context.dropDeferredCodexRows
                    ? nil
                    : Self.intMapOutsideScanWindow(migratedCached?.codexStandardTokens, range: context.range),
                splitMaps.standardTokens),
            codexPriorityTokens: Self.mergeIntMaps(
                context.dropDeferredCodexRows
                    ? nil
                    : Self.intMapOutsideScanWindow(migratedCached?.codexPriorityTokens, range: context.range),
                splitMaps.priorityTokens),
            codexTurnIDs: context.dropDeferredCodexRows
                ? Self.codexTurnIDs(rows: parsed.rows)
                : Self.mergeCodexTurnIDs(migratedCached?.codexTurnIDs, rows: parsed.rows),
            codexRows: context.dropDeferredCodexRows ? nil : migratedCached?.codexRows,
            codexScanFileId: input.target.fileId,
            codexScanTargetSize: input.target.targetEOF,
            codexScanContentFingerprint: input.target.contentFingerprint,
            codexScanComplete: coverage.scanComplete,
            codexScanGeneration: context.scanGeneration,
            codexParseResumeState: parsed.resumeState)
        Self.applyFileDays(cache: &cache, fileDays: cache.files[input.metadata.path]?.days ?? [:], sign: 1)
        Self.rememberScannedCodexFile(
            fileURL: input.fileURL,
            metadata: input.metadata,
            sessionId: sessionId,
            context: context,
            state: &state)
    }

    static func mergeFileDays(
        existing: inout [String: [String: [Int]]],
        delta: [String: [String: [Int]]])
    {
        for (day, models) in delta {
            var dayModels = existing[day] ?? [:]
            for (model, packed) in models {
                let existingPacked = dayModels[model] ?? []
                let merged = self.addPacked(a: existingPacked, b: packed, sign: 1)
                if merged.allSatisfy({ $0 == 0 }) {
                    dayModels.removeValue(forKey: model)
                } else {
                    dayModels[model] = merged
                }
            }

            if dayModels.isEmpty {
                existing.removeValue(forKey: day)
            } else {
                existing[day] = dayModels
            }
        }
    }

    static func fileDaysOutsideScanWindow(
        _ days: [String: [String: [Int]]],
        range: CostUsageDayRange) -> [String: [String: [Int]]]
    {
        days.filter {
            !CostUsageDayRange.isInRange(dayKey: $0.key, since: range.scanSinceKey, until: range.scanUntilKey)
        }
    }

    static func applyFileDays(cache: inout CostUsageCache, fileDays: [String: [String: [Int]]], sign: Int) {
        for (day, models) in fileDays {
            var dayModels = cache.days[day] ?? [:]
            for (model, packed) in models {
                let existing = dayModels[model] ?? []
                let merged = self.addPacked(a: existing, b: packed, sign: sign)
                if merged.allSatisfy({ $0 == 0 }) {
                    dayModels.removeValue(forKey: model)
                } else {
                    dayModels[model] = merged
                }
            }

            if dayModels.isEmpty {
                cache.days.removeValue(forKey: day)
            } else {
                cache.days[day] = dayModels
            }
        }
    }

    static func pruneDays(cache: inout CostUsageCache, sinceKey: String, untilKey: String) {
        for key in cache.days.keys where !CostUsageDayRange.isInRange(dayKey: key, since: sinceKey, until: untilKey) {
            cache.days.removeValue(forKey: key)
        }
    }

    static func pruneForceRescanFilesOutsideWindow(
        cache: inout CostUsageCache,
        range: CostUsageDayRange,
        isForceRescan: Bool)
    {
        guard isForceRescan else { return }
        for key in cache.files.keys {
            guard let old = cache.files[key] else { continue }
            guard !old.touchesCodexScanWindow(sinceKey: range.scanSinceKey, untilKey: range.scanUntilKey)
            else { continue }
            Self.applyFileDays(cache: &cache, fileDays: old.days, sign: -1)
            cache.files.removeValue(forKey: key)
        }
    }

    static func requestedWindowExpandsCache(range: CostUsageDayRange, cache: CostUsageCache) -> Bool {
        guard let cachedSince = cache.scanSinceKey,
              let cachedUntil = cache.scanUntilKey
        else {
            return cache.lastScanUnixMs != 0 || !cache.files.isEmpty || !cache.days.isEmpty
        }
        return range.scanSinceKey < cachedSince || range.scanUntilKey > cachedUntil
    }

    static func addPacked(a: [Int], b: [Int], sign: Int) -> [Int] {
        let len = max(a.count, b.count)
        var out: [Int] = Array(repeating: 0, count: len)
        for idx in 0..<len {
            let next = (a[safe: idx] ?? 0) + sign * (b[safe: idx] ?? 0)
            out[idx] = max(0, next)
        }
        return out
    }

    static func buildCodexReportFromCache(
        cache: CostUsageCache,
        range: CostUsageDayRange,
        modelsDevCatalog: ModelsDevCatalog? = nil,
        modelsDevCacheRoot: URL? = nil,
        priorityTurns: [String: CodexPriorityTurnMetadata] = [:]) -> CostUsageDailyReport
    {
        var entries: [CostUsageDailyReport.Entry] = []
        var totalInput = 0
        var totalOutput = 0
        var totalTokens = 0
        var totalCost: Double = 0
        var costSeen = false

        let dayKeys = cache.days.keys.sorted().filter {
            CostUsageDayRange.isInRange(dayKey: $0, since: range.sinceKey, until: range.untilKey)
        }
        let costNanosByDayModel = self.codexCostNanosByDayModel(cache: cache, range: range)
        let prioritySurchargeNanosByDayModel = self.codexPrioritySurchargeNanosByDayModel(cache: cache, range: range)
        let standardCostNanosByDayModel = self.codexStandardCostNanosByDayModel(cache: cache, range: range)
        let priorityCostNanosByDayModel = self.codexPriorityCostNanosByDayModel(cache: cache, range: range)
        let standardTokensByDayModel = self.codexStandardTokensByDayModel(cache: cache, range: range)
        let priorityTokensByDayModel = self.codexPriorityTokensByDayModel(cache: cache, range: range)

        let hasCodexRows = cache.files.values.contains {
            !($0.codexRows?.isEmpty ?? true)
        }
        let rowsByDayModel = hasCodexRows ? self.codexRowsByDayModel(cache: cache, range: range) : [:]

        for day in dayKeys {
            guard let models = cache.days[day] else { continue }
            let modelNames = models.keys.sorted()

            var dayInput = 0
            var dayOutput = 0
            var breakdown: [CostUsageDailyReport.ModelBreakdown] = []
            var dayCost: Double = 0
            var dayCostSeen = false

            for model in modelNames {
                let packed = models[model] ?? [0, 0, 0]
                let input = packed[safe: 0] ?? 0
                let cached = packed[safe: 1] ?? 0
                let output = packed[safe: 2] ?? 0
                let totalTokens = input + output

                dayInput += input
                dayOutput += output

                let rows = rowsByDayModel[day]?[model]
                let rowCostBreakdown = rows.map {
                    self.codexRowCostBreakdown(
                        rows: $0,
                        priorityTurns: priorityTurns,
                        modelsDevCatalog: modelsDevCatalog,
                        modelsDevCacheRoot: modelsDevCacheRoot)
                }
                let cachedBaseCost = costNanosByDayModel[day]?[model].map { Double($0) / Self.costScale }
                let rowTotalCost = cachedBaseCost == nil ? rowCostBreakdown?.totalCostUSD : nil
                let standardCost = standardCostNanosByDayModel[day]?[model].map { Double($0) / Self.costScale }
                    ?? (rowCostBreakdown?.hasModeSplit == true ? rowCostBreakdown?.optionalStandardCostUSD : nil)
                let priorityCost = priorityCostNanosByDayModel[day]?[model].map { Double($0) / Self.costScale }
                    ?? (rowCostBreakdown?.hasModeSplit == true ? rowCostBreakdown?.optionalPriorityCostUSD : nil)
                let splitTotalCost: Double? = if standardCost != nil || priorityCost != nil {
                    (standardCost ?? 0) + (priorityCost ?? 0)
                } else {
                    nil
                }
                var cost = splitTotalCost
                    ?? cachedBaseCost
                    ?? rowTotalCost
                    ?? CostUsagePricing.codexCostUSD(
                        model: model,
                        inputTokens: input,
                        cachedInputTokens: cached,
                        outputTokens: output,
                        modelsDevCatalog: modelsDevCatalog,
                        modelsDevCacheRoot: modelsDevCacheRoot)
                if splitTotalCost == nil,
                   let surchargeNanos = prioritySurchargeNanosByDayModel[day]?[model],
                   cachedBaseCost != nil
                {
                    cost = (cost ?? 0) + (Double(surchargeNanos) / Self.costScale)
                } else if splitTotalCost == nil,
                          rowTotalCost == nil,
                          !priorityTurns.isEmpty,
                          let rows,
                          let surcharge = self.codexPrioritySurchargeUSD(
                              rows: rows,
                              priorityTurns: priorityTurns,
                              modelsDevCatalog: modelsDevCatalog,
                              modelsDevCacheRoot: modelsDevCacheRoot)
                {
                    cost = (cost ?? 0) + surcharge
                }
                let standardModeTokens = standardTokensByDayModel[day]?[model]
                    ?? (rowCostBreakdown?.hasModeSplit == true ? rowCostBreakdown?.optionalStandardTokens : nil)
                let priorityModeTokens = priorityTokensByDayModel[day]?[model]
                    ?? (rowCostBreakdown?.hasModeSplit == true ? rowCostBreakdown?.optionalPriorityTokens : nil)
                let hasModeSplit = priorityCost != nil || priorityModeTokens != nil
                breakdown.append(
                    CostUsageDailyReport.ModelBreakdown(
                        modelName: model,
                        costUSD: cost,
                        totalTokens: totalTokens,
                        standardCostUSD: hasModeSplit ? standardCost : nil,
                        priorityCostUSD: hasModeSplit ? priorityCost : nil,
                        standardTokens: hasModeSplit ? standardModeTokens : nil,
                        priorityTokens: hasModeSplit ? priorityModeTokens : nil))
                if let cost {
                    dayCost += cost
                    dayCostSeen = true
                }
            }

            let dayTotal = dayInput + dayOutput
            let entryCost = dayCostSeen ? dayCost : nil
            entries.append(CostUsageDailyReport.Entry(
                date: day,
                inputTokens: dayInput,
                outputTokens: dayOutput,
                totalTokens: dayTotal,
                costUSD: entryCost,
                modelsUsed: modelNames,
                modelBreakdowns: Self.sortedModelBreakdowns(breakdown)))

            totalInput += dayInput
            totalOutput += dayOutput
            totalTokens += dayTotal
            if let entryCost {
                totalCost += entryCost
                costSeen = true
            }
        }

        let summary: CostUsageDailyReport.Summary? = entries.isEmpty
            ? nil
            : CostUsageDailyReport.Summary(
                totalInputTokens: totalInput,
                totalOutputTokens: totalOutput,
                totalTokens: totalTokens,
                totalCostUSD: costSeen ? totalCost : nil)

        return CostUsageDailyReport(
            data: entries,
            summary: summary,
            projectBreakdown: Self.codexProjectBreakdown(
                cache: cache,
                range: range,
                modelsDevCatalog: modelsDevCatalog,
                modelsDevCacheRoot: modelsDevCacheRoot),
            projectRetractions: Self.codexProjectRetractions(
                cache: cache,
                range: range,
                modelsDevCatalog: modelsDevCatalog,
                modelsDevCacheRoot: modelsDevCacheRoot))
    }

    private struct CodexProjectModelTotal {
        var costUSD: Double = 0
        var tokens: Int = 0
    }

    private struct CodexProjectTotal {
        var name: String
        var days: [String: [String: CodexProjectModelTotal]] = [:]
    }

    private static func codexProjectBreakdown(
        cache: CostUsageCache,
        range: CostUsageDayRange,
        modelsDevCatalog: ModelsDevCatalog?,
        modelsDevCacheRoot: URL?) -> [CostUsageProjectBreakdown]?
    {
        var projects: [String: CodexProjectTotal] = [:]
        for usage in cache.files.values {
            guard let key = usage.projectKey,
                  key.count == 64,
                  key.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) })
            else { continue }
            let name = Self.safeCodexProjectName(usage.projectName, key: key)
            var project = projects[key] ?? CodexProjectTotal(name: name)
            if name < project.name { project.name = name }

            for (day, models) in usage.days where CostUsageDayRange.isInRange(
                dayKey: day, since: range.sinceKey, until: range.untilKey)
            {
                var dayModels = project.days[day] ?? [:]
                for (model, packed) in models {
                    let input = packed[safe: 0] ?? 0
                    let cached = packed[safe: 1] ?? 0
                    let output = packed[safe: 2] ?? 0
                    let tokens = input + output
                    let splitCost = Self.costUSD(
                        standardNanos: usage.codexStandardCostNanos?[day]?[model],
                        priorityNanos: usage.codexPriorityCostNanos?[day]?[model])
                    var cost = splitCost
                        ?? usage.codexCostNanos?[day]?[model].map { Double($0) / Self.costScale }
                        ?? CostUsagePricing.codexCostUSD(
                            model: model,
                            inputTokens: input,
                            cachedInputTokens: cached,
                            outputTokens: output,
                            modelsDevCatalog: modelsDevCatalog,
                            modelsDevCacheRoot: modelsDevCacheRoot)
                        ?? 0
                    if splitCost == nil,
                       usage.codexCostNanos?[day]?[model] != nil,
                       let surcharge = usage.codexPrioritySurchargeNanos?[day]?[model]
                    {
                        cost += Double(surcharge) / Self.costScale
                    }
                    var total = dayModels[model] ?? CodexProjectModelTotal()
                    total.costUSD += cost
                    total.tokens += tokens
                    dayModels[model] = total
                }
                project.days[day] = dayModels
            }
            projects[key] = project
        }

        let result = projects.keys.sorted().compactMap { key -> CostUsageProjectBreakdown? in
            guard let project = projects[key] else { return nil }
            let daily = project.days.keys.sorted().compactMap { day -> CostUsageProjectBreakdown.Day? in
                guard let models = project.days[day] else { return nil }
                let rows = models.map {
                    CostUsageProjectBreakdown.Model(
                        name: $0.key, costUSD: $0.value.costUSD, totalTokens: $0.value.tokens)
                }.filter { $0.costUSD > 0 || $0.totalTokens > 0 }
                    .sorted {
                        if $0.costUSD != $1.costUSD { return $0.costUSD > $1.costUSD }
                        if $0.totalTokens != $1.totalTokens { return $0.totalTokens > $1.totalTokens }
                        return $0.name < $1.name
                    }
                let cost = rows.reduce(0) { $0 + $1.costUSD }
                let tokens = rows.reduce(0) { $0 + $1.totalTokens }
                guard cost > 0 || tokens > 0 else { return nil }
                return CostUsageProjectBreakdown.Day(
                    date: day, costUSD: cost, totalTokens: tokens, models: rows)
            }
            guard !daily.isEmpty else { return nil }
            return CostUsageProjectBreakdown(
                projectKey: key, projectName: project.name, daily: daily)
        }
        return result.isEmpty ? nil : result
    }

    private static func codexProjectRetractions(
        cache: CostUsageCache,
        range: CostUsageDayRange,
        modelsDevCatalog: ModelsDevCatalog?,
        modelsDevCacheRoot: URL?) -> [CostUsageProjectRetraction]?
    {
        var result: [String: CostUsageProjectRetraction] = [:]
        for (path, usage) in cache.files {
            guard let id = usage.projectRetractionID,
                  let key = usage.projectRetractionKey,
                  id.count == 64,
                  key.count == 64
            else { continue }
            var attributed = usage
            attributed.projectKey = key
            attributed.projectName = "Retracted"
            var isolated = CostUsageCache()
            isolated.files[path] = attributed
            guard let daily = Self.codexProjectBreakdown(
                cache: isolated,
                range: range,
                modelsDevCatalog: modelsDevCatalog,
                modelsDevCacheRoot: modelsDevCacheRoot)?.first?.daily,
                !daily.isEmpty
            else { continue }
            result[id] = CostUsageProjectRetraction(
                retractionID: id, projectKey: key, daily: daily)
        }
        let rows = result.keys.sorted().compactMap { result[$0] }
        return rows.isEmpty ? nil : rows
    }

    private static func costUSD(standardNanos: Int64?, priorityNanos: Int64?) -> Double? {
        guard standardNanos != nil || priorityNanos != nil else { return nil }
        return Double((standardNanos ?? 0) + (priorityNanos ?? 0)) / Self.costScale
    }

    private static func safeCodexProjectName(_ raw: String?, key: String) -> String {
        let candidate = raw?.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let cleaned = String(candidate.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Codex Project \(key.prefix(8))" : String(cleaned.prefix(48))
    }

    static func sortedModelBreakdowns(_ breakdowns: [CostUsageDailyReport.ModelBreakdown])
        -> [CostUsageDailyReport.ModelBreakdown]
    {
        breakdowns.sorted { lhs, rhs in
            let lhsCost = lhs.costUSD ?? -1
            let rhsCost = rhs.costUSD ?? -1
            if lhsCost != rhsCost {
                return lhsCost > rhsCost
            }

            let lhsTokens = lhs.totalTokens ?? -1
            let rhsTokens = rhs.totalTokens ?? -1
            if lhsTokens != rhsTokens {
                return lhsTokens > rhsTokens
            }

            return lhs.modelName > rhs.modelName
        }
    }

    static func parseDayKey(_ key: String) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3 else { return nil }
        guard
            let year = Int(parts[0]),
            let month = Int(parts[1]),
            let day = Int(parts[2])
        else { return nil }

        var comps = DateComponents()
        comps.calendar = Calendar.current
        comps.timeZone = TimeZone.current
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = 12
        return comps.date
    }
}

extension Data {
    func containsAscii(_ needle: String) -> Bool {
        guard let n = needle.data(using: .utf8) else { return false }
        return self.range(of: n) != nil
    }
}

extension [Int] {
    subscript(safe index: Int) -> Int? {
        if index < 0 { return nil }
        if index >= self.count { return nil }
        return self[index]
    }
}

extension [UInt8] {
    subscript(safe index: Int) -> UInt8? {
        if index < 0 { return nil }
        if index >= self.count { return nil }
        return self[index]
    }
}

extension CostUsageFileUsage {
    func touchesCodexScanWindow(sinceKey: String, untilKey: String) -> Bool {
        self.days.keys.contains {
            CostUsageScanner.CostUsageDayRange.isInRange(dayKey: $0, since: sinceKey, until: untilKey)
        }
    }
}
