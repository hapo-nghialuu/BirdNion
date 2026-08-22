import Foundation

/// Manages reading and writing Pi Agent native configuration (`~/.pi/agent/settings.json`).
final class PiAgentConfigStore: ObservableObject {

    struct Config: Equatable, Codable {
        var defaultProvider: String = "token-plan"
        var defaultModel: String = "MiniMax-M3"
        var defaultThinkingLevel: String = "high"
        var hideThinkingBlock: Bool = true
        var theme: String = "light"
        var lastChangelogVersion: String = "0.84.2"
    }

    @Published var config: Config = Config()

    init() {
        self.config = Self.load()
    }

    func reload() {
        self.config = Self.load()
    }

    func save() throws {
        try Self.save(config: self.config)
    }

    static var configFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    static func load() -> Config {
        guard FileManager.default.fileExists(atPath: configFile.path),
              let data = try? Data(contentsOf: configFile),
              let config = try? JSONDecoder().decode(Config.self, from: data)
        else {
            return Config()
        }
        return config
    }

    static func save(config: Config) throws {
        let dir = configFile.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // Preserve unrecognized keys if original file exists
        var dict: [String: Any] = [:]
        if let existingData = try? Data(contentsOf: configFile),
           let existingDict = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] {
            dict = existingDict
        }

        dict["defaultProvider"] = config.defaultProvider
        dict["defaultModel"] = config.defaultModel
        dict["defaultThinkingLevel"] = config.defaultThinkingLevel
        dict["hideThinkingBlock"] = config.hideThinkingBlock
        dict["theme"] = config.theme
        dict["lastChangelogVersion"] = config.lastChangelogVersion

        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: configFile, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: configFile.path)
    }
}
