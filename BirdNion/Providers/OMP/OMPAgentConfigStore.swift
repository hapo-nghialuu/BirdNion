import Foundation

/// Manages reading and writing Oh My Pi (`omp`) native runtime configuration (`~/.omp/agent/config.yml`).
///
/// Features:
/// - Preserves unrecognized YAML keys and lines.
/// - Atomic file writing with owner-only permissions (`0600`).
/// - Multi-profile support via `OMPPaths.configFile(profile:)`.
final class OMPAgentConfigStore: ObservableObject {

    struct ModelRoles: Equatable {
        var defaultRole: String = ""
        var plan: String = ""
        var slow: String = ""
        var smol: String = ""
        var task: String = ""
        var advisor: String = ""
    }

    struct Config: Equatable {
        var modelRoles: ModelRoles = ModelRoles()
        var prewalkEnabled: Bool = false
        var prewalkTarget: String = ""
        var rawLines: [String] = []
    }

    @Published var config: Config = Config()
    @Published var activeProfile: String = ""

    private let lock = NSLock()

    init(profile: String = "") {
        self.activeProfile = profile
        self.config = Self.load(profile: profile)
    }

    func reload() {
        self.config = Self.load(profile: activeProfile)
    }

    func save() throws {
        try Self.save(config: self.config, profile: activeProfile)
    }

    // MARK: - Parser & Serializer

    static func load(profile: String = "") -> Config {
        let fileURL = OMPPaths.configFile(profile: profile.isEmpty ? nil : profile)
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let content = try? String(contentsOf: fileURL, encoding: .utf8)
        else {
            return Config()
        }

        return parse(content: content)
    }

    static func parse(content: String) -> Config {
        var config = Config()
        let lines = content.components(separatedBy: "\n")
        config.rawLines = lines

        var inModelRoles = false
        var inPrewalk = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            if trimmed == "modelRoles:" || trimmed.hasPrefix("modelRoles:") {
                inModelRoles = true
                inPrewalk = false
                continue
            } else if trimmed == "prewalk:" || trimmed.hasPrefix("prewalk:") {
                inPrewalk = true
                inModelRoles = false
                continue
            } else if !line.hasPrefix(" ") && !line.hasPrefix("\t") && trimmed.contains(":") {
                inModelRoles = false
                inPrewalk = false
            }

            let parts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let value = String(parts[1]).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

            if inModelRoles {
                switch key {
                case "default": config.modelRoles.defaultRole = value
                case "plan": config.modelRoles.plan = value
                case "slow": config.modelRoles.slow = value
                case "smol": config.modelRoles.smol = value
                case "task": config.modelRoles.task = value
                case "advisor": config.modelRoles.advisor = value
                default: break
                }
            } else if inPrewalk {
                if key == "enabled" {
                    config.prewalkEnabled = (value.lowercased() == "true" || value == "1")
                } else if key == "target" || key == "into" {
                    config.prewalkTarget = value
                }
            }
        }

        return config
    }

    static func save(config: Config, profile: String = "") throws {
        let fileURL = OMPPaths.configFile(profile: profile.isEmpty ? nil : profile)
        let dir = fileURL.deletingLastPathComponent()

        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        var lines = config.rawLines

        func updateOrInsertKey(section: String, key: String, value: String) {
            guard !value.isEmpty else { return }
            var sectionFound = false
            var inserted = false

            for (idx, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == "\(section):" || trimmed.hasPrefix("\(section):") {
                    sectionFound = true
                    continue
                }
                if sectionFound {
                    if !line.hasPrefix(" ") && !line.hasPrefix("\t") && trimmed.contains(":") {
                        // Exited section
                        lines.insert("  \(key): \(value)", at: idx)
                        inserted = true
                        break
                    }
                    if trimmed.hasPrefix("\(key):") {
                        lines[idx] = "  \(key): \(value)"
                        inserted = true
                        break
                    }
                }
            }

            if !sectionFound {
                lines.append("\(section):")
                lines.append("  \(key): \(value)")
            } else if !inserted {
                lines.append("  \(key): \(value)")
            }
        }

        updateOrInsertKey(section: "modelRoles", key: "default", value: config.modelRoles.defaultRole)
        updateOrInsertKey(section: "modelRoles", key: "plan", value: config.modelRoles.plan)
        updateOrInsertKey(section: "modelRoles", key: "slow", value: config.modelRoles.slow)
        updateOrInsertKey(section: "modelRoles", key: "smol", value: config.modelRoles.smol)
        if !config.modelRoles.task.isEmpty {
            updateOrInsertKey(section: "modelRoles", key: "task", value: config.modelRoles.task)
        }
        if !config.modelRoles.advisor.isEmpty {
            updateOrInsertKey(section: "modelRoles", key: "advisor", value: config.modelRoles.advisor)
        }

        let content = lines.joined(separator: "\n") + "\n"
        let data = content.data(using: .utf8) ?? Data()
        try data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: fileURL.path)
    }
}
