import Foundation

struct AgentActivityDay: Equatable, Identifiable, Sendable {
    let date: Date
    let usd: Double
    let tokens: Int
    let hasEvidence: Bool

    var id: Date { date }
    var isActive: Bool { usd > 0 || tokens > 0 }
}

struct AgentActivityWeek: Equatable, Identifiable, Sendable {
    let startDate: Date
    let days: [AgentActivityDay]

    var id: Date { startDate }
    var usd: Double { days.reduce(0) { $0 + $1.usd } }
    var tokens: Int { days.reduce(0) { $0 + $1.tokens } }
    var activeDays: Int { days.filter(\.isActive).count }
    var hasEvidence: Bool { days.contains(where: \.hasEvidence) }
}

struct AgentActivityWindow: Equatable, Sendable {
    let weeks: [AgentActivityWeek]
    let currentStreak: Int
    let longestStreak: Int

    init(weeks: [AgentActivityWeek], currentStreak: Int = 0, longestStreak: Int = 0) {
        self.weeks = weeks
        self.currentStreak = currentStreak
        self.longestStreak = longestStreak
    }

    var days: [AgentActivityDay] {
        weeks.flatMap(\.days).sorted { $0.date < $1.date }
    }

    var totalUSD: Double {
        weeks.reduce(0) { $0 + $1.usd }
    }

    var totalTokens: Int {
        weeks.reduce(0) { $0 + $1.tokens }
    }

    var activeDays: Int {
        days.filter(\.isActive).count
    }

    var hasData: Bool {
        days.contains(where: \.isActive)
    }

    var peakDay: AgentActivityDay? {
        days.filter(\.isActive).max { lhs, rhs in
            if lhs.usd != rhs.usd { return lhs.usd < rhs.usd }
            return lhs.tokens < rhs.tokens
        }
    }
}

struct AgentActivitySnapshot: Equatable, Sendable {
    let overall: AgentActivityWindow
    let byAgent: [InstalledAgentID: AgentActivityWindow]
}
