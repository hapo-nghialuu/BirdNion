import Foundation

struct InstalledAgentDetectionContext: Sendable {
    var homeURL: URL
    var environment: [String: String]

    static var current: InstalledAgentDetectionContext {
        InstalledAgentDetectionContext(
            homeURL: FileManager.default.homeDirectoryForCurrentUser,
            environment: ProcessInfo.processInfo.environment
        )
    }
}

enum InstalledAgentDetectors {
    private struct Descriptor {
        let id: InstalledAgentID
        let binaries: [String]
        let markers: [(relativePath: String, kind: InstalledAgentEvidenceKind)]
        let capabilities: Set<InstalledAgentCapability>
        let providerIDs: [String]
    }

    static func detect(
        context: InstalledAgentDetectionContext = .current,
        fileManager: FileManager = .default
    ) -> [InstalledAgentRecord] {
        descriptors.compactMap { descriptor in
            var evidence: [InstalledAgentEvidence] = []
            for binary in descriptor.binaries where executableExists(
                binary,
                context: context,
                fileManager: fileManager
            ) {
                evidence.append(.init(kind: .executable, token: "PATH:\(binary)"))
            }
            for marker in descriptor.markers {
                let url = context.homeURL.appendingPathComponent(marker.relativePath)
                if fileManager.fileExists(atPath: url.path) {
                    evidence.append(.init(kind: marker.kind, token: "~/\(marker.relativePath)"))
                }
            }
            guard !evidence.isEmpty else { return nil }
            return InstalledAgentRecord(
                id: descriptor.id,
                evidence: evidence,
                capabilities: descriptor.capabilities,
                providerIDs: descriptor.providerIDs
            )
        }
    }

    private static func executableExists(
        _ name: String,
        context: InstalledAgentDetectionContext,
        fileManager: FileManager
    ) -> Bool {
        let pathDirectories: [String]
        if let pathEnv = context.environment["PATH"] {
            pathDirectories = pathEnv.split(separator: ":").map(String.init).filter { !$0.isEmpty }
        } else if context.environment.isEmpty {
            pathDirectories = []
        } else {
            pathDirectories = [
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "/usr/bin",
                "/bin",
                context.homeURL.appendingPathComponent(".local/bin").path,
                context.homeURL.appendingPathComponent(".cargo/bin").path
            ]
        }
        for directory in pathDirectories {
            let path = URL(fileURLWithPath: directory).appendingPathComponent(name).path
            if fileManager.isExecutableFile(atPath: path) { return true }
        }
        return false
    }

    private static let descriptors: [Descriptor] = [
        .init(
            id: .claude,
            binaries: ["claude"],
            markers: [
                (".claude", .configuration),
                (".claude.json", .configuration),
                (".claude/projects", .applicationState)
            ],
            capabilities: [.quota, .localCost, .nativeConfig, .sessionInventory, .activityDetail],
            providerIDs: ["claude"]
        ),
        .init(
            id: .codex,
            binaries: ["codex"],
            markers: [
                (".codex", .configuration),
                (".codex/sessions", .applicationState)
            ],
            capabilities: [.quota, .localCost, .nativeConfig, .sessionInventory, .activityDetail],
            providerIDs: ["codex"]
        ),
        .init(
            id: .gemini,
            binaries: ["gemini"],
            markers: [
                (".gemini/settings.json", .configuration),
                (".gemini/oauth_creds.json", .configuration)
            ],
            capabilities: [.quota, .nativeConfig, .sessionInventory],
            providerIDs: ["gemini"]
        ),
        .init(
            id: .grok,
            binaries: ["grok"],
            markers: [
                (".grok/auth.json", .configuration),
                (".grok/sessions", .applicationState)
            ],
            capabilities: [.quota, .localCost, .nativeConfig, .sessionInventory, .activityDetail],
            providerIDs: ["grok"]
        ),
        .init(
            id: .opencode,
            binaries: ["opencode"],
            markers: [
                (".config/opencode", .configuration),
                (".local/share/opencode", .applicationState)
            ],
            capabilities: [.quota, .nativeConfig, .sessionInventory],
            providerIDs: ["opencode", "opencodego"]
        ),
        .init(
            id: .omp,
            binaries: ["omp"],
            markers: [
                (".omp/agent/config.yml", .configuration),
                (".omp/agent/sessions", .applicationState),
                (".omp/agent", .configuration)
            ],
            capabilities: [.localCost, .nativeConfig, .sessionInventory, .activityDetail],
            providerIDs: []
        ),
        .init(
            id: .pi,
            binaries: ["pi"],
            markers: [
                (".pi/agent/settings.json", .configuration),
                (".pi/agent/sessions", .applicationState),
                (".pi/agent", .configuration)
            ],
            capabilities: [.localCost, .nativeConfig, .sessionInventory, .activityDetail],
            providerIDs: []
        ),
        .init(
            id: .kiro,
            binaries: ["kiro-cli", "kiro"],
            markers: [
                (".kiro", .configuration),
                ("Library/Application Support/Kiro", .applicationState)
            ],
            capabilities: [.quota, .localCost, .sessionInventory, .activityDetail],
            providerIDs: ["kiro"]
        ),
        .init(
            id: .antigravity,
            binaries: ["agy"],
            markers: [
                ("Library/Application Support/Antigravity", .applicationState),
                (".gemini/antigravity", .configuration)
            ],
            capabilities: [.quota, .nativeConfig, .sessionInventory],
            providerIDs: ["antigravity"]
        ),
        .init(
            id: .copilot,
            binaries: ["copilot"],
            markers: [
                (".copilot/config.json", .configuration)
            ],
            capabilities: [.quota, .nativeConfig],
            providerIDs: ["copilot"]
        ),
        .init(
            id: .auggie,
            binaries: ["auggie"],
            markers: [
                (".augment", .configuration)
            ],
            capabilities: [.nativeConfig],
            providerIDs: []
        ),
        .init(
            id: .amp,
            binaries: ["amp"],
            markers: [
                (".config/amp/settings.json", .configuration)
            ],
            capabilities: [.nativeConfig],
            providerIDs: []
        ),
        .init(
            id: .cursor,
            binaries: ["cursor", "cursor-agent"],
            markers: [
                (".cursor", .configuration),
                ("Library/Application Support/Cursor", .applicationState)
            ],
            capabilities: [.quota, .nativeConfig, .sessionInventory],
            providerIDs: ["cursor"]
        ),
        .init(
            id: .aider,
            binaries: ["aider"],
            markers: [
                (".aider", .configuration),
                (".aider/analytics.jsonl", .applicationState)
            ],
            capabilities: [.nativeConfig],
            providerIDs: []
        ),
        .init(
            id: .qwen,
            binaries: ["qwen"],
            markers: [
                (".qwen", .configuration)
            ],
            capabilities: [.nativeConfig],
            providerIDs: []
        ),
        .init(
            id: .goose,
            binaries: ["goose"],
            markers: [
                (".config/goose", .configuration)
            ],
            capabilities: [.nativeConfig],
            providerIDs: []
        )
    ]
}
