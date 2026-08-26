import Foundation

enum ProjectInsightsBuilder {
    static func build(
        combined: CombinedUsageReport,
        history: ProjectCostHistoryStore.Document,
        enabledSources: Set<ProjectUsageSource>,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ProjectInsightsReport {
        var projects = storedProjects(
            history, includedSources: enabledSources, calendar: calendar)
        projects = reconcileKnownProjects(
            projects, combined: combined, includedSources: enabledSources, calendar: calendar)
        appendUnknownProjects(
            to: &projects, combined: combined,
            includedSources: enabledSources, calendar: calendar)

        let pulse = WeeklyDigest.pulse(daily: combined.daily, now: now, calendar: calendar)
        let topModel = pulse.topModel.map {
            CombinedModelCost(
                name: ProjectIdentity.safeModelName($0.name),
                usd: $0.usd, tokens: $0.tokens, source: $0.source)
        }
        let overview = ProjectInsightsOverview(
            currentUSD: pulse.currentUSD, currentTokens: pulse.currentTokens,
            priorUSD: pulse.priorUSD, priorTokens: pulse.priorTokens,
            changePercent: pulse.changePercent, topSource: pulse.topSource,
            topModel: topModel, confidence: confidence(combined, enabledSources: enabledSources))
        return ProjectInsightsReport(overview: overview, projects: projects)
    }

    static func copySummary(_ report: ProjectInsightsReport, language: String?) -> String {
        let vi = L10n.languageCode(language) == "vi"
        let overview = report.overview
        let change: String = overview.changePercent.map {
            String(format: "%@%.0f%%", $0 >= 0 ? "+" : "", $0)
        } ?? "—"
        var lines = [
            vi ? "BirdNion Insights (7 ngày)" : "BirdNion Insights (7 days)",
            "\(AllUsageFormat.usd(overview.currentUSD)) / \(AllUsageFormat.tokens(overview.currentTokens)) · \(change)",
        ]
        if let source = overview.topSource {
            lines.append((vi ? "Nguồn hàng đầu: " : "Top source: ") + source.displayName)
        }
        if let model = overview.topModel {
            lines.append((vi ? "Model hàng đầu: " : "Top model: ")
                         + WeeklyDigest.sanitizeLabel(AllUsageFormat.shortName(model.name)))
        }
        if let project = report.ranking(days: 7).first {
            lines.append((vi ? "Dự án hàng đầu: " : "Top project: ") + project.displayName)
        }
        return lines.joined(separator: "\n")
    }

    private static func storedProjects(
        _ history: ProjectCostHistoryStore.Document,
        includedSources: Set<ProjectUsageSource>,
        calendar: Calendar
    ) -> [ProjectUsageRecord] {
        var rows: [ProjectUsageRecord] = []
        for (sourceRaw, projects) in history.sources ?? [:] {
            guard let source = ProjectUsageSource(rawValue: sourceRaw) else { continue }
            guard includedSources.contains(source) else { continue }
            for (rawKey, project) in projects {
                let key = ProjectIdentity.safeKey(rawKey)
                let daily = project.days.compactMap { dayKey, day -> ProjectDailyUsage? in
                    guard let date = CostHistoryStore.parseDayKey(dayKey, calendar: calendar) else { return nil }
                    return ProjectDailyUsage(
                        date: date, usd: day.usd, tokens: day.tokens,
                        models: day.models.map {
                            ProjectModelUsage(
                                name: ProjectIdentity.safeModelName($0.name),
                                usd: $0.usd, tokens: $0.tokens)
                        })
                }.sorted { $0.date < $1.date }
                guard daily.contains(where: { $0.usd > 0 || $0.tokens > 0 }) else { continue }
                rows.append(ProjectUsageRecord(
                    source: source, projectKey: key,
                    displayName: ProjectIdentity.safeDisplayName(project.displayName, key: key),
                    attribution: project.attribution, daily: daily))
            }
        }
        return rows
    }

    private static func appendUnknownProjects(
        to projects: inout [ProjectUsageRecord],
        combined: CombinedUsageReport,
        includedSources: Set<ProjectUsageSource>,
        calendar: Calendar
    ) {
        let sources: [ProjectUsageSource] = [.claude, .codex, .grok, .kiro, .omp, .pi]
        for source in sources where includedSources.contains(source) {
            let knownByDay = knownDailyTotals(
                projects.filter { $0.source == source }, calendar: calendar)
            let daily = combined.daily.compactMap { day -> ProjectDailyUsage? in
                let aggregate = sourceTotals(source, day: day)
                let known = knownByDay[calendar.startOfDay(for: day.date)] ?? (usd: 0, tokens: 0)
                let usd = max(0, aggregate.usd - known.usd)
                let tokens = max(0, aggregate.tokens - known.tokens)
                guard usd > 0 || tokens > 0 else { return nil }
                let models = known.usd == 0 && known.tokens == 0
                    ? day.models.filter {
                        $0.source == source.rawValue
                            && (source != .kiro
                                || $0.name != KiroCostScanner.aggregateModelName)
                    }.map {
                        ProjectModelUsage(
                            name: ProjectIdentity.safeModelName($0.name),
                            usd: $0.usd, tokens: $0.tokens)
                    } : []
                return ProjectDailyUsage(date: day.date, usd: usd, tokens: tokens, models: models)
            }
            guard !daily.isEmpty else { continue }
            projects.append(ProjectUsageRecord(
                source: source, projectKey: "unknown-\(source.rawValue)",
                displayName: "Unknown", attribution: .unknown, daily: daily))
        }
    }

    private struct SourceDayKey: Hashable {
        let source: ProjectUsageSource
        let date: Date
    }

    /// Project history is high-water per project, while aggregate history is
    /// high-water per source. Constrain the derived project projection to the
    /// authoritative source/day total so old and newly observed identities can
    /// never double-count usage after raw logs move or disappear.
    private static func reconcileKnownProjects(
        _ projects: [ProjectUsageRecord],
        combined: CombinedUsageReport,
        includedSources: Set<ProjectUsageSource>,
        calendar: Calendar
    ) -> [ProjectUsageRecord] {
        var aggregates: [SourceDayKey: (usd: Double, tokens: Int)] = [:]
        for day in combined.daily {
            let date = calendar.startOfDay(for: day.date)
            for source in includedSources {
                aggregates[SourceDayKey(source: source, date: date)] = sourceTotals(source, day: day)
            }
        }

        var overrides: [String: [Date: ProjectDailyUsage]] = [:]
        for source in includedSources {
            let sourceProjects = projects.filter { $0.source == source }
            let dates = Set(sourceProjects.flatMap(\.daily).map {
                calendar.startOfDay(for: $0.date)
            })
            for date in dates {
                let entries = sourceProjects.compactMap { project -> (String, ProjectDailyUsage)? in
                    project.daily.first { calendar.startOfDay(for: $0.date) == date }
                        .map { (project.id, $0) }
                }.sorted { $0.0 < $1.0 }
                guard !entries.isEmpty else { continue }
                let target = aggregates[SourceDayKey(source: source, date: date)] ?? (0, 0)
                let knownUSD = entries.reduce(0) { $0 + max(0, $1.1.usd) }
                let usdScale = knownUSD > target.usd && knownUSD > 0
                    ? max(0, target.usd) / knownUSD : 1
                let tokenValues = entries.map { (key: $0.0, value: max(0, $0.1.tokens)) }
                let tokenTargets = proportionalTokenTargets(
                    tokenValues, target: max(0, target.tokens))
                var assignedUSD = 0.0

                for (index, entry) in entries.enumerated() {
                    let originalUSD = max(0, entry.1.usd)
                    let scaledUSD: Double
                    if usdScale < 1, index == entries.count - 1 {
                        scaledUSD = max(0, target.usd - assignedUSD)
                    } else {
                        scaledUSD = originalUSD * usdScale
                    }
                    assignedUSD += scaledUSD
                    let effectiveUSDScale = originalUSD > 0 ? scaledUSD / originalUSD : usdScale
                    let targetTokens = tokenTargets[index]
                    let models = scaleModels(
                        entry.1.models,
                        usdScale: effectiveUSDScale,
                        originalDayTokens: max(0, entry.1.tokens),
                        targetDayTokens: targetTokens)
                    overrides[entry.0, default: [:]][date] = ProjectDailyUsage(
                        date: entry.1.date, usd: scaledUSD, tokens: targetTokens, models: models)
                }
            }
        }

        return projects.map { project in
            ProjectUsageRecord(
                source: project.source,
                projectKey: project.projectKey,
                displayName: project.displayName,
                attribution: project.attribution,
                daily: project.daily.map { day in
                    overrides[project.id]?[calendar.startOfDay(for: day.date)] ?? day
                })
        }
    }

    private static func proportionalTokenTargets(
        _ values: [(key: String, value: Int)], target: Int
    ) -> [Int] {
        let normalized = values.map { UInt64(max(0, $0.value)) }
        var total: UInt64 = 0
        for value in normalized {
            let sum = total.addingReportingOverflow(value)
            guard !sum.overflow else {
                return proportionalTokenTargetsDecimal(values, target: target)
            }
            total = sum.partialValue
        }
        let target = min(UInt64(max(0, target)), total)
        guard total > 0, target < total else { return normalized.map(Int.init) }
        var result: [Int] = []
        var remainders: [UInt64] = []
        result.reserveCapacity(normalized.count)
        remainders.reserveCapacity(normalized.count)
        for value in normalized {
            let division = total.dividingFullWidth(value.multipliedFullWidth(by: target))
            result.append(Int(division.quotient))
            remainders.append(division.remainder)
        }
        let remaining = Int(target) - result.reduce(0, +)
        let order = values.indices.sorted {
            let left = remainders[$0]
            let right = remainders[$1]
            if left != right { return left > right }
            if values[$0].key != values[$1].key { return values[$0].key < values[$1].key }
            return $0 < $1
        }
        for index in order.prefix(max(0, remaining)) {
            result[index] += 1
        }
        return result
    }

    private static func proportionalTokenTargetsDecimal(
        _ values: [(key: String, value: Int)], target: Int
    ) -> [Int] {
        let normalized = values.map { Decimal(max(0, $0.value)) }
        let total = normalized.reduce(Decimal.zero, +)
        let target = min(Decimal(max(0, target)), total)
        guard total > 0, target < total else {
            return values.map { max(0, $0.value) }
        }
        var result: [Int] = []
        var remainders: [Decimal] = []
        for value in normalized {
            let product = value * target
            var quotient = product / total
            var rounded = Decimal.zero
            NSDecimalRound(&rounded, &quotient, 0, .down)
            result.append(NSDecimalNumber(decimal: rounded).intValue)
            remainders.append(product - rounded * total)
        }
        let integerTarget = NSDecimalNumber(decimal: target).intValue
        let remaining = integerTarget - result.reduce(0, +)
        let order = values.indices.sorted {
            if remainders[$0] != remainders[$1] { return remainders[$0] > remainders[$1] }
            if values[$0].key != values[$1].key { return values[$0].key < values[$1].key }
            return $0 < $1
        }
        for index in order.prefix(max(0, remaining)) {
            result[index] += 1
        }
        return result
    }

    private static func scaleModels(
        _ models: [ProjectModelUsage],
        usdScale: Double,
        originalDayTokens: Int,
        targetDayTokens: Int
    ) -> [ProjectModelUsage] {
        let modelTotal = models.reduce(0) { $0 + max(0, $1.tokens) }
        let modelTarget = originalDayTokens > 0
            ? scaledTokenTarget(
                value: modelTotal,
                target: targetDayTokens,
                divisor: originalDayTokens)
            : 0
        let targets = proportionalTokenTargets(
            models.map { (key: $0.name, value: $0.tokens) }, target: modelTarget)
        return models.enumerated().map { index, model in
            ProjectModelUsage(
                name: model.name,
                usd: max(0, model.usd) * usdScale,
                tokens: targets[index])
        }
    }

    private static func scaledTokenTarget(value: Int, target: Int, divisor: Int) -> Int {
        let divisor = UInt64(max(0, divisor))
        guard divisor > 0 else { return 0 }
        let value = UInt64(max(0, value))
        let target = min(UInt64(max(0, target)), divisor)
        guard value > 0, target > 0 else { return 0 }
        guard value < divisor else { return Int(target) }
        let division = divisor.dividingFullWidth(value.multipliedFullWidth(by: target))
        return Int(min(target, division.quotient))
    }

    private static func knownDailyTotals(
        _ projects: [ProjectUsageRecord], calendar: Calendar
    ) -> [Date: (usd: Double, tokens: Int)] {
        var result: [Date: (usd: Double, tokens: Int)] = [:]
        for project in projects {
            for day in project.daily {
                let key = calendar.startOfDay(for: day.date)
                var value = result[key] ?? (0, 0)
                value.usd += day.usd
                value.tokens += day.tokens
                result[key] = value
            }
        }
        return result
    }

    private static func sourceTotals(
        _ source: ProjectUsageSource, day: CombinedDailyUsage
    ) -> (usd: Double, tokens: Int) {
        switch source {
        case .claude: return (day.claudeUSD, day.claudeTokens)
        case .codex: return (day.codexUSD, day.codexTokens)
        case .grok: return (day.grokUSD, day.grokTokens)
        case .kiro: return (day.kiroUSD, day.kiroTokens)
        case .omp: return (day.ompUSD, day.ompTokens)
        case .pi: return (day.piUSD, day.piTokens)
        }
    }

    private static func confidence(
        _ combined: CombinedUsageReport,
        enabledSources: Set<ProjectUsageSource>
    ) -> ProjectInsightsConfidence {
        let entries: [(ProjectUsageSource, CostHistoryStore.UsageScanConfidence?)] = [
            (.claude, combined.claudeConfidence), (.codex, combined.codexConfidence),
            (.grok, combined.grokConfidence), (.kiro, combined.kiroConfidence),
            (.omp, combined.ompConfidence),
            (.pi, combined.piConfidence),
        ].filter { enabledSources.contains($0.0) }
        return ProjectInsightsConfidence(
            live: entries.compactMap { $0.1?.live == true ? $0.0 : nil },
            historyOnly: entries.compactMap {
                $0.1?.included == true && $0.1?.live == false ? $0.0 : nil
            },
            unavailable: entries.compactMap {
                $0.1?.included == true ? nil : $0.0
            })
    }
}
