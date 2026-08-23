import Foundation

struct AgentDetailSnapshot: Equatable, Sendable {
    struct CostSummary: Equatable, Sendable {
        let todayUSD: Double
        let todayTokens: Int
        let last30USD: Double
        let last30Tokens: Int
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

extension AgentDetailSnapshot.ActivityWindow {
    static func build(label: String, usd: Double, tokens: Int) -> Self {
        Self(label: label, usd: usd, tokens: tokens, hasData: usd > 0 || tokens > 0)
    }
}
