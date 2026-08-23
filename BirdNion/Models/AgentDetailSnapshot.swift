import Foundation

struct AgentDetailSnapshot: Equatable, Sendable {
    struct CostSummary: Equatable, Sendable {
        let todayUSD: Double
        let todayTokens: Int
        let periodUSD: Double
        let periodTokens: Int
        let periodDays: Int
        let topModel: String?
        let confidence: CostHistoryStore.UsageScanConfidence?
    }

    struct ModelItem: Equatable, Identifiable, Sendable {
        let name: String
        let tokens: Int
        let usd: Double
        let percentage: Int

        var id: String { name }
    }

    struct ActivityWindow: Equatable, Identifiable, Sendable {
        let label: String
        let usd: Double
        let tokens: Int
        let hasData: Bool

        var id: String { label }
    }

    struct ActivityDay: Equatable, Identifiable, Sendable {
        let date: Date
        let usd: Double
        let tokens: Int
        let topModel: String?

        var id: Date { date }
    }

    let record: InstalledAgentRecord
    let providerStatus: ProviderStatus?
    let configuredProviders: [String]
    let costSummary: CostSummary?
    let models: [ModelItem]
    let activityWindows: [ActivityWindow]
    let recentActivity: [ActivityDay]
    let sourceName: String
    let sourceType: String
    let logPath: String?
    let configPath: String?
    let connectionStatus: String
    let subtitle: String

    var id: InstalledAgentID { record.id }
    var displayName: String { record.displayName }
    var iconName: String { record.iconName }
    var capabilities: [InstalledAgentCapability] { record.capabilities.sorted { $0.rawValue < $1.rawValue } }
    var evidence: [InstalledAgentEvidence] { record.evidence }
    var lastUpdated: Date? { providerStatus?.lastUpdated }
    var hasQuota: Bool { capabilities.contains(.quota) }
    var hasLocalCost: Bool { capabilities.contains(.localCost) }

    init(
        record: InstalledAgentRecord,
        providerStatus: ProviderStatus?,
        configuredProviders: [String],
        costSummary: CostSummary?,
        models: [ModelItem] = [],
        activityWindows: [ActivityWindow] = [],
        recentActivity: [ActivityDay] = [],
        sourceName: String = "",
        sourceType: String = "",
        logPath: String? = nil,
        configPath: String? = nil,
        connectionStatus: String = "Đã kiểm tra · vừa xong",
        subtitle: String = ""
    ) {
        self.record = record
        self.providerStatus = providerStatus
        self.configuredProviders = configuredProviders
        self.costSummary = costSummary
        self.models = models
        self.activityWindows = activityWindows
        self.recentActivity = recentActivity
        self.sourceName = sourceName
        self.sourceType = sourceType
        self.logPath = logPath
        self.configPath = configPath
        self.connectionStatus = connectionStatus
        self.subtitle = subtitle
    }
}

extension AgentDetailSnapshot {
    static func build(
        record: InstalledAgentRecord,
        providerStatuses: [ProviderStatus],
        combined: CombinedUsageReport,
        configuredProviders: [String] = [],
        sourceName explicitSourceName: String? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> AgentDetailSnapshot {
        let status = providerStatuses.first {
            record.providerIDs.contains($0.id) || $0.id == record.id.rawValue
        }
        let sourceID = record.id.rawValue
        let days = combined.daily.map { day -> ActivityDay in
            let values = sourceValues(for: record.id, day: day)
            let topModel = day.models
                .filter { $0.source == sourceID }
                .max { $0.tokens < $1.tokens }?.name
            return ActivityDay(
                date: day.date,
                usd: values.usd,
                tokens: values.tokens,
                topModel: topModel)
        }
        let periodDays = min(90, days.count)
        let period = days.suffix(periodDays)
        let today = days.last

        var modelTotals: [String: (usd: Double, tokens: Int)] = [:]
        for model in combined.daily.flatMap(\.models).filter({ $0.source == sourceID }) {
            var total = modelTotals[model.name] ?? (0, 0)
            total.usd += model.usd
            total.tokens += model.tokens
            modelTotals[model.name] = total
        }
        let sortedModels = modelTotals.sorted {
            if $0.value.tokens != $1.value.tokens { return $0.value.tokens > $1.value.tokens }
            return $0.value.usd > $1.value.usd
        }
        let totalModelTokens = max(sortedModels.reduce(0) { $0 + $1.value.tokens }, 1)
        let models = sortedModels.prefix(6).map { name, value in
            ModelItem(
                name: name,
                tokens: value.tokens,
                usd: value.usd,
                percentage: Int((Double(value.tokens) / Double(totalModelTokens) * 100).rounded()))
        }

        let sourceConfidence = confidence(for: record.id, combined: combined)
        let hasCostEvidence = period.contains { $0.usd > 0 || $0.tokens > 0 }
        let canShowCostNumbers = sourceConfidence?.included == true || hasCostEvidence
        let costSummary = !canShowCostNumbers ? nil : CostSummary(
            todayUSD: today?.usd ?? 0,
            todayTokens: today?.tokens ?? 0,
            periodUSD: period.reduce(0) { $0 + $1.usd },
            periodTokens: period.reduce(0) { $0 + $1.tokens },
            periodDays: periodDays,
            topModel: models.first?.name,
            confidence: sourceConfidence)

        let configEvidence = record.evidence.first { $0.kind == .configuration }?.token
        let logEvidence = record.evidence.first { $0.kind == .applicationState }?.token
        let sourceName = explicitSourceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveSourceName: String
        if let sourceName, !sourceName.isEmpty {
            effectiveSourceName = sourceName
        } else if let label = status?.sourceLabel, !label.isEmpty {
            effectiveSourceName = label
        } else {
            effectiveSourceName = status?.displayName ?? ""
        }
        let connectionStatus: String
        if let error = status?.error, !error.isEmpty {
            connectionStatus = error
        } else if status != nil || hasCostEvidence {
            connectionStatus = "Available"
        } else {
            connectionStatus = "Detected locally"
        }

        return AgentDetailSnapshot(
            record: record,
            providerStatus: status,
            configuredProviders: configuredProviders,
            costSummary: costSummary,
            models: models,
            activityWindows: [
                window(label: "7 days", days: days.suffix(7)),
                window(label: "30 days", days: days.suffix(30)),
                window(label: "90 days", days: days.suffix(90)),
            ],
            recentActivity: Array(days.suffix(90)),
            sourceName: effectiveSourceName,
            sourceType: status == nil ? "Local evidence" : "Provider status",
            logPath: logEvidence,
            configPath: configEvidence,
            connectionStatus: connectionStatus,
            subtitle: effectiveSourceName.isEmpty ? record.displayName : "\(record.displayName) · \(effectiveSourceName)")
    }

    private static func window<S: Sequence>(
        label: String,
        days: S
    ) -> ActivityWindow where S.Element == ActivityDay {
        let values = Array(days)
        return .build(
            label: label,
            usd: values.reduce(0) { $0 + $1.usd },
            tokens: values.reduce(0) { $0 + $1.tokens })
    }

    private static func sourceValues(
        for id: InstalledAgentID,
        day: CombinedDailyUsage
    ) -> (usd: Double, tokens: Int) {
        switch id {
        case .claude: return (day.claudeUSD, day.claudeTokens)
        case .codex: return (day.codexUSD, day.codexTokens)
        case .grok: return (day.grokUSD, day.grokTokens)
        case .kiro: return (day.kiroUSD, day.kiroTokens)
        case .omp: return (day.ompUSD, day.ompTokens)
        case .pi: return (day.piUSD, day.piTokens)
        default: return (0, 0)
        }
    }

    private static func confidence(
        for id: InstalledAgentID,
        combined: CombinedUsageReport
    ) -> CostHistoryStore.UsageScanConfidence? {
        switch id {
        case .claude: return combined.claudeConfidence
        case .codex: return combined.codexConfidence
        case .grok: return combined.grokConfidence
        case .kiro: return combined.kiroConfidence
        case .omp: return combined.ompConfidence
        case .pi: return combined.piConfidence
        default: return nil
        }
    }
}

extension AgentDetailSnapshot.ActivityWindow {
    static func build(label: String, usd: Double, tokens: Int) -> Self {
        Self(label: label, usd: usd, tokens: tokens, hasData: usd > 0 || tokens > 0)
    }
}
