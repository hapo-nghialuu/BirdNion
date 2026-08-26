import CryptoKit
import Foundation

enum ProjectUsageSource: String, Codable, CaseIterable, Sendable {
    case claude, codex, grok, kiro, omp, pi

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .grok: return "Grok"
        case .kiro: return "Kiro"
        case .omp: return "Oh My Pi"
        case .pi: return "Pi"
        }
    }
}

enum ProjectAttribution: String, Codable, Sendable {
    case exact
    case derived
    case unknown
}

enum InsightsSegment: String, CaseIterable, Identifiable, Sendable {
    case overview
    case activity
    case projects

    static let defaultsKey = "birdnion.insightsSegment"
    var id: String { rawValue }

    static func restored(_ raw: String?) -> InsightsSegment {
        raw.flatMap(InsightsSegment.init(rawValue:)) ?? .overview
    }
}

struct ProjectIdentity: Equatable, Sendable {
    let key: String
    let displayName: String
    let attribution: ProjectAttribution

    static func claude(cwd: String?, fallbackDirectory: String) -> ProjectIdentity {
        let key = hash("claude:session-directory:\(fallbackDirectory)")
        if let cwd = verifiedAbsolutePath(cwd) {
            return ProjectIdentity(
                key: key,
                displayName: safeDisplayName(URL(fileURLWithPath: cwd).lastPathComponent, key: key),
                attribution: .derived)
        }
        return ProjectIdentity(
            key: key,
            displayName: "Claude Project \(key.prefix(8))",
            attribution: .derived)
    }

    static func codex(cwd: String?) -> ProjectIdentity? {
        guard let path = verifiedAbsolutePath(cwd) else { return nil }
        let key = hash("codex:cwd-v1\0\(path)")
        return ProjectIdentity(
            key: key,
            displayName: safeDisplayName(URL(fileURLWithPath: path).lastPathComponent, key: key),
            attribution: .exact)
    }

    static func grok(encodedDirectory: String, gitRootDir: String?) -> ProjectIdentity? {
        guard isSafeDirectoryToken(encodedDirectory) else { return nil }
        let key = hash("grok:encoded-cwd-v1\0\(encodedDirectory)")
        let displayName = verifiedAbsolutePath(gitRootDir).map {
            safeDisplayName(URL(fileURLWithPath: $0).lastPathComponent, key: key)
        } ?? "Grok Project \(key.prefix(8))"
        return ProjectIdentity(
            key: key, displayName: displayName, attribution: .derived)
    }

    static func omp(cwd: String?) -> ProjectIdentity? {
        guard let path = verifiedAbsolutePath(cwd) else { return nil }
        let key = hash("omp:cwd-v1\0\(path)")
        return ProjectIdentity(
            key: key,
            displayName: safeDisplayName(URL(fileURLWithPath: path).lastPathComponent, key: key),
            attribution: .exact)
    }

    static func pi(cwd: String?) -> ProjectIdentity? {
        guard let path = verifiedAbsolutePath(cwd) else { return nil }
        let key = hash("pi:cwd-v1\0\(path)")
        return ProjectIdentity(
            key: key,
            displayName: safeDisplayName(URL(fileURLWithPath: path).lastPathComponent, key: key),
            attribution: .exact)
    }

    static func safeKey(_ raw: String) -> String {
        let valid = raw.count == 64 && raw.allSatisfy { $0.isHexDigit && !$0.isUppercase }
        return valid ? raw : hash("project-key:\(raw)")
    }

    static func safeDisplayName(_ raw: String, key: String) -> String {
        let tail = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? raw
        let clean = WeeklyDigest.sanitizeLabel(tail, maxLength: 48)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "Project \(key.prefix(8))" : clean
    }

    static func safeModelName(_ raw: String) -> String {
        let tail = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? raw
        let clean = WeeklyDigest.sanitizeLabel(tail, maxLength: 80)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "Unknown" : clean
    }

    private static func verifiedAbsolutePath(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              (raw as NSString).isAbsolutePath,
              !raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        return URL(fileURLWithPath: raw).standardizedFileURL.path
    }

    private static func isSafeDirectoryToken(_ raw: String) -> Bool {
        !raw.isEmpty
            && raw != "."
            && raw != ".."
            && !raw.contains("/")
            && !raw.contains("\\")
            && !raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct ProjectModelUsage: Codable, Equatable, Sendable, Identifiable {
    let name: String
    let usd: Double
    let tokens: Int
    var id: String { name }
}

struct ProjectDailyUsage: Equatable, Sendable, Identifiable {
    let date: Date
    let usd: Double
    let tokens: Int
    let models: [ProjectModelUsage]
    var id: Date { date }
}

struct ProjectUsageRecord: Equatable, Sendable, Identifiable {
    let source: ProjectUsageSource
    let projectKey: String
    let displayName: String
    let attribution: ProjectAttribution
    let daily: [ProjectDailyUsage]
    var id: String { "\(source.rawValue):\(projectKey)" }
}

struct ProjectRankingRow: Equatable, Sendable, Identifiable {
    let id: String
    let source: ProjectUsageSource
    let projectKey: String
    let displayName: String
    let attribution: ProjectAttribution
    let usd: Double
    let tokens: Int
}

struct ProjectInsightsConfidence: Equatable, Sendable {
    let live: [ProjectUsageSource]
    let historyOnly: [ProjectUsageSource]
    let unavailable: [ProjectUsageSource]
}

struct ProjectInsightsOverview: Equatable, Sendable {
    let currentUSD: Double
    let currentTokens: Int
    let priorUSD: Double
    let priorTokens: Int
    let changePercent: Double?
    let topSource: WeeklyDigest.SourceID?
    let topModel: CombinedModelCost?
    let confidence: ProjectInsightsConfidence
}

struct ProjectInsightsReport: Equatable, Sendable {
    static let rankingLimit = 100
    let overview: ProjectInsightsOverview
    let projects: [ProjectUsageRecord]

    func ranking(days: Int, now: Date = Date(), calendar: Calendar = .current) -> [ProjectRankingRow] {
        let start = windowStart(days: days, now: now, calendar: calendar)
        let sorted: [ProjectRankingRow] = projects.compactMap { project -> ProjectRankingRow? in
            let rows = project.daily.filter { $0.date >= start && $0.date <= calendar.startOfDay(for: now) }
            let usd = rows.reduce(0) { $0 + $1.usd }
            let tokens = rows.reduce(0) { $0 + $1.tokens }
            guard usd > 0 || tokens > 0 else { return nil }
            return ProjectRankingRow(
                id: project.id, source: project.source, projectKey: project.projectKey,
                displayName: project.displayName, attribution: project.attribution,
                usd: usd, tokens: tokens)
        }.sorted {
            if $0.usd != $1.usd { return $0.usd > $1.usd }
            if $0.tokens != $1.tokens { return $0.tokens > $1.tokens }
            if $0.source != $1.source { return $0.source.rawValue < $1.source.rawValue }
            return $0.projectKey < $1.projectKey
        }
        return Array(sorted.prefix(Self.rankingLimit))
    }

    func detail(id: String, days: Int, now: Date = Date(), calendar: Calendar = .current)
        -> ProjectUsageRecord? {
        guard let project = projects.first(where: { $0.id == id }) else { return nil }
        let start = windowStart(days: days, now: now, calendar: calendar)
        return ProjectUsageRecord(
            source: project.source, projectKey: project.projectKey,
            displayName: project.displayName, attribution: project.attribution,
            daily: project.daily.filter { $0.date >= start && $0.date <= calendar.startOfDay(for: now) })
    }

    private func windowStart(days: Int, now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -(max(days, 1) - 1), to: today) ?? today
    }
}
