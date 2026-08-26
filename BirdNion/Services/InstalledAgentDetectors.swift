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
                if markerExists(marker.relativePath, url: url, fileManager: fileManager) {
                    let kind = descriptor.id == .kiro
                        && marker.relativePath == ".kiro_sessions"
                        && !containsRegularJSONFile(url, fileManager: fileManager)
                        ? InstalledAgentEvidenceKind.configuration
                        : marker.kind
                    evidence.append(.init(kind: kind, token: "~/\(marker.relativePath)"))
                }
            }
            if descriptor.id == .kiro,
               let xdg = context.environment["XDG_DATA_HOME"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
               !xdg.isEmpty,
               (xdg as NSString).isAbsolutePath
            {
                let database = URL(fileURLWithPath: xdg)
                    .appendingPathComponent("kiro-cli/data.sqlite3")
                if regularFileExists(at: database) {
                    evidence.append(.init(
                        kind: .applicationState,
                        token: "$XDG_DATA_HOME/kiro-cli/data.sqlite3"))
                }
            }
            guard !evidence.isEmpty else { return nil }
            return InstalledAgentRecord(
                id: descriptor.id,
                evidence: evidence,
                capabilities: InstalledAgentRecord.detectedCapabilities(
                    id: descriptor.id,
                    evidence: evidence),
                providerIDs: descriptor.providerIDs
            )
        }
    }

    private static func containsRegularJSONFile(
        _ directory: URL,
        fileManager: FileManager
    ) -> Bool {
        let files = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])) ?? []
        return files.contains { url in
            url.pathExtension == "json"
                && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
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

    private static let fileOnlyMarkers: Set<String> = [
        "Library/Application Support/kiro-cli/data.sqlite3",
        ".local/share/kiro-cli/data.sqlite3",
    ]

    private static func markerExists(
        _ relativePath: String,
        url: URL,
        fileManager: FileManager
    ) -> Bool {
        guard fileOnlyMarkers.contains(relativePath) else {
            return fileManager.fileExists(atPath: url.path)
        }
        return regularFileExists(at: url)
    }

    /// Checks the concrete directory entry rather than following symlinks.
    /// Kiro's detector and scanner share this exact evidence predicate.
    static func regularFileExists(at url: URL) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
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
            providerIDs: ["claude"]
        ),
        .init(
            id: .codex,
            binaries: ["codex"],
            markers: [
                (".codex", .configuration),
                (".codex/sessions", .applicationState)
            ],
            providerIDs: ["codex"]
        ),
        .init(
            id: .gemini,
            binaries: ["gemini"],
            markers: [
                (".gemini/settings.json", .configuration),
                (".gemini/oauth_creds.json", .configuration)
            ],
            providerIDs: ["gemini"]
        ),
        .init(
            id: .grok,
            binaries: ["grok"],
            markers: [
                (".grok/auth.json", .configuration),
                (".grok/sessions", .applicationState)
            ],
            providerIDs: ["grok"]
        ),
        .init(
            id: .opencode,
            binaries: ["opencode"],
            markers: [
                (".config/opencode", .configuration),
                (".local/share/opencode", .applicationState)
            ],
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
            providerIDs: []
        ),
        .init(
            id: .kiro,
            binaries: ["kiro-cli", "kiro"],
            markers: [
                (".kiro", .configuration),
                ("Library/Application Support/Kiro", .applicationState),
                ("Library/Application Support/kiro-cli/data.sqlite3", .applicationState),
                (".local/share/kiro-cli/data.sqlite3", .applicationState),
                (".kiro_sessions", .applicationState)
            ],
            providerIDs: ["kiro"]
        ),
        .init(
            id: .antigravity,
            binaries: ["agy"],
            markers: [
                ("Library/Application Support/Antigravity", .applicationState),
                (".gemini/antigravity", .configuration)
            ],
            providerIDs: ["antigravity"]
        ),
        .init(
            id: .copilot,
            binaries: ["copilot"],
            markers: [
                (".copilot/config.json", .configuration)
            ],
            providerIDs: ["copilot"]
        ),
        .init(
            id: .auggie,
            binaries: ["auggie"],
            markers: [
                (".augment", .configuration)
            ],
            providerIDs: []
        ),
        .init(
            id: .amp,
            binaries: ["amp"],
            markers: [
                (".config/amp/settings.json", .configuration)
            ],
            providerIDs: []
        ),
        .init(
            id: .cursor,
            binaries: ["cursor", "cursor-agent"],
            markers: [
                (".cursor", .configuration),
                ("Library/Application Support/Cursor", .applicationState)
            ],
            providerIDs: ["cursor"]
        ),
        .init(
            id: .aider,
            binaries: ["aider"],
            markers: [
                (".aider", .configuration),
                (".aider/analytics.jsonl", .applicationState)
            ],
            providerIDs: []
        ),
        .init(
            id: .qwen,
            binaries: ["qwen"],
            markers: [
                (".qwen", .configuration)
            ],
            providerIDs: []
        ),
        .init(
            id: .goose,
            binaries: ["goose"],
            markers: [
                (".config/goose", .configuration)
            ],
            providerIDs: []
        )
    ]
}
