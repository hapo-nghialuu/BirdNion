import Foundation

enum InstalledAgentID: String, CaseIterable, Codable, Identifiable, Sendable {
    case claude
    case codex
    case gemini
    case grok
    case opencode
    case omp
    case pi
    case kiro
    case antigravity
    case copilot
    case auggie
    case amp
    case cursor
    case aider
    case qwen
    case goose

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex CLI"
        case .gemini: "Gemini CLI"
        case .grok: "Grok CLI"
        case .opencode: "OpenCode"
        case .omp: "Oh My Pi"
        case .pi: "Pi Agent"
        case .kiro: "Kiro"
        case .antigravity: "Antigravity"
        case .copilot: "Copilot CLI"
        case .auggie: "Auggie"
        case .amp: "Amp"
        case .cursor: "Cursor"
        case .aider: "Aider"
        case .qwen: "Qwen Code"
        case .goose: "Goose"
        }
    }

    var iconName: String {
        switch self {
        case .claude: "sparkles"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .gemini: "diamond"
        case .grok: "xmark"
        case .opencode: "terminal"
        case .omp: "bolt.horizontal.circle"
        case .pi: "command"
        case .kiro: "wand.and.stars"
        case .antigravity: "triangle"
        case .copilot: "airplane"
        case .auggie: "gearshape.2"
        case .amp: "bolt"
        case .cursor: "cursorarrow"
        case .aider: "ellipsis.message"
        case .qwen: "cpu"
        case .goose: "bird"
        }
    }

    var costHistorySource: CostHistoryStore.Source? {
        switch self {
        case .claude: .claude
        case .codex: .codex
        case .grok: .grok
        case .kiro: .kiro
        case .omp: .omp
        case .pi: .pi
        default: nil
        }
    }
}

enum InstalledAgentCapability: String, CaseIterable, Codable, Hashable, Sendable {
    case quota
    case localCost
    case nativeConfig
    case sessionInventory
    case activityDetail
}

enum InstalledAgentEvidenceKind: String, Codable, Sendable {
    case executable
    case configuration
    case applicationState
}

struct InstalledAgentEvidence: Equatable, Codable, Sendable {
    let kind: InstalledAgentEvidenceKind
    let token: String
}

struct InstalledAgentRecord: Identifiable, Equatable, Codable, Sendable {
    let id: InstalledAgentID
    let evidence: [InstalledAgentEvidence]
    let capabilities: Set<InstalledAgentCapability>
    let providerIDs: [String]

    var displayName: String { id.displayName }
    var iconName: String { id.iconName }
    var costHistorySource: CostHistoryStore.Source? { id.costHistorySource }
}
