import Foundation

// Native port of CodexBarCore's ClaudeSourcePlanner. BirdNion is always an app
// runtime (no CLI runtime), so the auto plan is fixed: race(OAuth‖Web) → CLI.
// Pure branching logic, no side effects — drives which sources the
// orchestrator tries (and in what order) for `.auto`, and validates explicit
// selections.

/// Inputs that decide the fetch plan: the user's selected source, whether web
/// extras are enabled, and which sources are plausibly available right now.
struct ClaudeSourcePlanningInput: Equatable, Sendable {
    let selectedDataSource: ClaudeUsageDataSource
    let webExtrasEnabled: Bool
    let hasWebSession: Bool
    let hasCLI: Bool
    let hasOAuthCredentials: Bool

    init(selectedDataSource: ClaudeUsageDataSource,
         webExtrasEnabled: Bool,
         hasWebSession: Bool,
         hasCLI: Bool,
         hasOAuthCredentials: Bool) {
        self.selectedDataSource = selectedDataSource
        self.webExtrasEnabled = webExtrasEnabled
        self.hasWebSession = hasWebSession
        self.hasCLI = hasCLI
        self.hasOAuthCredentials = hasOAuthCredentials
    }
}

/// Why a step is part of the plan — surfaced in debug output.
enum ClaudeSourcePlanReason: String, Equatable, Sendable {
    case explicitSourceSelection = "explicit-source-selection"
    case appAutoPreferredOAuth = "app-auto-preferred-oauth"
    case appAutoFallbackCLI = "app-auto-fallback-cli"
    case appAutoFallbackWeb = "app-auto-fallback-web"
}

/// One ordered step in the plan, with its availability flag.
struct ClaudeFetchPlanStep: Equatable, Sendable {
    let dataSource: ClaudeUsageDataSource
    let inclusionReason: ClaudeSourcePlanReason
    let isPlausiblyAvailable: Bool

    init(dataSource: ClaudeUsageDataSource,
         inclusionReason: ClaudeSourcePlanReason,
         isPlausiblyAvailable: Bool) {
        self.dataSource = dataSource
        self.inclusionReason = inclusionReason
        self.isPlausiblyAvailable = isPlausiblyAvailable
    }
}

/// One execution stage. `.race` runs its HTTP sources concurrently — the
/// first trusted result wins the core; `.single` runs one source (the CLI
/// chain, or a pinned selection).
enum ClaudeFetchStage: Equatable, Sendable {
    case race([ClaudeFetchPlanStep])
    case single(ClaudeFetchPlanStep)

    var steps: [ClaudeFetchPlanStep] {
        switch self {
        case .race(let steps): steps
        case .single(let step): [step]
        }
    }
}

/// The resolved plan. `executionStages` is what the orchestrator actually
/// runs: for `.auto`, stage 1 races every plausibly-available HTTP source
/// (OAuth‖Web) and stage 2 falls back to the CLI chain; for an explicit source
/// the single chosen step regardless of availability (so the user sees a real
/// error instead of a silent skip).
struct ClaudeFetchPlan: Equatable, Sendable {
    let input: ClaudeSourcePlanningInput
    let orderedSteps: [ClaudeFetchPlanStep]

    init(input: ClaudeSourcePlanningInput, orderedSteps: [ClaudeFetchPlanStep]) {
        self.input = input
        self.orderedSteps = orderedSteps
    }

    var availableSteps: [ClaudeFetchPlanStep] {
        orderedSteps.filter(\.isPlausiblyAvailable)
    }

    var isNoSourceAvailable: Bool { availableSteps.isEmpty }

    var preferredStep: ClaudeFetchPlanStep? {
        switch input.selectedDataSource {
        case .auto: availableSteps.first
        case .api, .oauth, .web, .cli: orderedSteps.first
        }
    }

    /// Staged execution — `.auto` = `race(oauth‖web)` then `cli` (each filtered
    /// by availability); explicit sources = one single-source stage.
    var executionStages: [ClaudeFetchStage] {
        switch input.selectedDataSource {
        case .auto:
            var stages: [ClaudeFetchStage] = []
            let httpSteps = orderedSteps.filter {
                $0.isPlausiblyAvailable
                    && ($0.dataSource == .oauth || $0.dataSource == .web)
            }
            if !httpSteps.isEmpty { stages.append(.race(httpSteps)) }
            if let cli = orderedSteps.first(where: {
                $0.dataSource == .cli && $0.isPlausiblyAvailable
            }) {
                stages.append(.single(cli))
            }
            return stages
        case .api, .oauth, .web, .cli:
            return orderedSteps.map { .single($0) }
        }
    }

    /// Flattened stage steps (compat view of `executionStages`).
    var executionSteps: [ClaudeFetchPlanStep] {
        executionStages.flatMap(\.steps)
    }

    var orderLabel: String {
        executionStages.map { stage in
            switch stage {
            case .race(let steps):
                steps.map { $0.dataSource.sourceLabel }.joined(separator: "‖")
            case .single(let step):
                step.dataSource.sourceLabel
            }
        }.joined(separator: "→")
    }

    func debugLines() -> [String] {
        var lines = ["planner_order=\(orderLabel)"]
        lines.append("planner_selected=\(preferredStep?.dataSource.rawValue ?? "none")")
        lines.append("planner_no_source=\(isNoSourceAvailable)")
        for step in orderedSteps {
            let availability = step.isPlausiblyAvailable ? "available" : "unavailable"
            lines.append("planner_step.\(step.dataSource.rawValue)=\(availability) reason=\(step.inclusionReason.rawValue)")
        }
        return lines
    }
}

/// Resolves a plan from the inputs. App-auto plan = race(OAuth‖Web) → CLI.
enum ClaudeSourcePlanner {
    static func resolve(input: ClaudeSourcePlanningInput) -> ClaudeFetchPlan {
        ClaudeFetchPlan(input: input, orderedSteps: makeSteps(input: input))
    }

    private static func makeSteps(input: ClaudeSourcePlanningInput) -> [ClaudeFetchPlanStep] {
        switch input.selectedDataSource {
        case .auto:
            [
                step(.oauth, reason: .appAutoPreferredOAuth, input: input),
                step(.cli, reason: .appAutoFallbackCLI, input: input),
                step(.web, reason: .appAutoFallbackWeb, input: input),
            ]
        case .api:
            [step(.api, reason: .explicitSourceSelection, input: input)]
        case .oauth:
            [step(.oauth, reason: .explicitSourceSelection, input: input)]
        case .web:
            [step(.web, reason: .explicitSourceSelection, input: input)]
        case .cli:
            [step(.cli, reason: .explicitSourceSelection, input: input)]
        }
    }

    private static func step(_ dataSource: ClaudeUsageDataSource,
                             reason: ClaudeSourcePlanReason,
                             input: ClaudeSourcePlanningInput) -> ClaudeFetchPlanStep {
        ClaudeFetchPlanStep(
            dataSource: dataSource,
            inclusionReason: reason,
            isPlausiblyAvailable: isPlausiblyAvailable(dataSource, input: input))
    }

    private static func isPlausiblyAvailable(_ dataSource: ClaudeUsageDataSource,
                                             input: ClaudeSourcePlanningInput) -> Bool {
        switch dataSource {
        case .auto, .api: false
        case .oauth: input.hasOAuthCredentials
        case .web: input.hasWebSession
        case .cli: input.hasCLI
        }
    }
}

/// Resolves the `claude` CLI binary by scanning PATH + common install dirs.
/// Pure filesystem (no process spawn) so it's cheap to call from the planner's
/// `hasCLI` probe. Mirrors CodexBar's `ClaudeCLIResolver`.
enum ClaudeCLIResolver {
    static func resolvedBinaryPath(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let override = environment["CLAUDE_CLI_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty,
            FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        var dirs: [String] = []
        if let path = environment["PATH"] {
            dirs += path.split(separator: ":").map(String.init)
        }
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        if let home = environment["HOME"] {
            dirs += ["\(home)/.local/bin", "\(home)/.claude/local"]
        }
        let fm = FileManager.default
        for dir in dirs where !dir.isEmpty {
            let candidate = (dir as NSString).appendingPathComponent("claude")
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    static func isAvailable(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        resolvedBinaryPath(environment: environment) != nil
    }
}
