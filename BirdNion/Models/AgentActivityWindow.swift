import Foundation

struct AgentActivityWeek: Equatable, Identifiable, Sendable {
    let startDate: Date
    let usd: Double
    let tokens: Int
    let activeDays: Int
    let hasEvidence: Bool

    var id: Date { startDate }
}

struct AgentActivityWindow: Equatable, Sendable {
    let weeks: [AgentActivityWeek]

    var totalUSD: Double {
        weeks.reduce(0) { $0 + $1.usd }
    }

    var totalTokens: Int {
        weeks.reduce(0) { $0 + $1.tokens }
    }

    var activeDays: Int {
        weeks.reduce(0) { $0 + $1.activeDays }
    }

    var hasData: Bool {
        weeks.contains { $0.hasEvidence && ($0.usd > 0 || $0.tokens > 0) }
    }
}

struct AgentActivitySnapshot: Equatable, Sendable {
    let overall: AgentActivityWindow
    let byAgent: [InstalledAgentID: AgentActivityWindow]
}
