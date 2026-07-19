import Foundation

struct CodexProviderConfiguration: Equatable {
    let profileID: String
    let providerID: String
    let providerName: String
    let model: String
    let baseURL: String
    let bearerToken: String
    let signature: String
}

/// Writes a BirdNion-owned third-party provider into Codex's user-level
/// config. Provider configuration is intentionally never written to a project
/// `.codex/config.toml`: Codex ignores those keys outside user-level config.
enum CodexConfigWriter {
    enum WriteError: LocalizedError, Equatable {
        case incompleteConfiguration

        var errorDescription: String? {
            switch self {
            case .incompleteConfiguration:
                return "Thiếu Base URL, API key hoặc model cho Codex"
            }
        }
    }

    struct ManagedState: Codable, Equatable {
        let profileID: String
        let configPath: String
        let signature: String
        let originalModelLine: String?
        let originalModelProviderLine: String?
    }

    static func targetURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".codex/config.toml")
    }

    static func activeProfileID(configURL: URL = targetURL()) -> String? {
        loadState(configURL: configURL)?.profileID
    }

    static func isApplied(_ profile: BirdNionConfigStore.CodexProfile,
                          configURL: URL = targetURL()) -> Bool {
        guard let configuration = try? providerConfiguration(for: profile),
              let state = loadState(configURL: configURL),
              state.profileID == profile.id,
              state.signature == configuration.signature,
              let contents = try? String(contentsOf: configURL, encoding: .utf8)
        else { return false }
        return CodexConfigDocument.containsManagedConfiguration(contents, configuration: configuration)
    }

    static func apply(profile: BirdNionConfigStore.CodexProfile,
                      configURL: URL = targetURL()) throws {
        let configuration = try providerConfiguration(for: profile)
        let contents = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let previousState = loadState(configURL: configURL)
        let cleanContents = CodexConfigDocument.removeManagedSections(from: contents)
        let original = previousState.map {
            ($0.originalModelLine, $0.originalModelProviderLine)
        } ?? CodexConfigDocument.rootAssignments(in: cleanContents)
        let withoutRootSelection = CodexConfigDocument.removeRootAssignments(from: cleanContents)
        let updated = CodexConfigDocument.applying(configuration, to: withoutRootSelection)

        try write(updated, to: configURL)
        let state = ManagedState(
            profileID: profile.id,
            configPath: configURL.path,
            signature: configuration.signature,
            originalModelLine: original.0,
            originalModelProviderLine: original.1
        )
        try writeState(state, configURL: configURL)
    }

    @discardableResult
    static func deactivate(configURL: URL = targetURL()) throws -> Bool {
        guard let state = loadState(configURL: configURL) else { return false }
        let contents = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        guard CodexConfigDocument.hasManagedSections(contents) else {
            try? FileManager.default.removeItem(at: stateURL(configURL: configURL))
            return false
        }
        var restored = CodexConfigDocument.removeManagedSections(from: contents)
        restored = CodexConfigDocument.removeRootAssignments(from: restored)
        restored = CodexConfigDocument.insertingRootAssignments(
            modelLine: state.originalModelLine,
            providerLine: state.originalModelProviderLine,
            into: restored
        )

        if restored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? FileManager.default.removeItem(at: configURL)
        } else {
            try write(restored, to: configURL)
        }
        try? FileManager.default.removeItem(at: stateURL(configURL: configURL))
        return true
    }

    private static func providerConfiguration(for profile: BirdNionConfigStore.CodexProfile) throws -> CodexProviderConfiguration {
        guard let model = cleaned(profile.model),
              let signature = profile.codexConfigurationSignature else {
            throw WriteError.incompleteConfiguration
        }

        let endpoint: String
        let bearerToken: String
        if profile.usesEmbeddedCLIProxy {
            guard let localBase = profile.normalizedCLIProxyBaseURL,
                  let localKey = cleaned(profile.cliProxyAPIKey) else {
                throw WriteError.incompleteConfiguration
            }
            endpoint = localBase + "/v1"
            bearerToken = localKey
        } else {
            guard let baseURL = cleaned(profile.baseURL),
                  let apiKey = cleaned(profile.apiKey) else {
                throw WriteError.incompleteConfiguration
            }
            endpoint = baseURL
            bearerToken = apiKey
        }

        return CodexProviderConfiguration(
            profileID: profile.id,
            providerID: profile.cliProxyProviderName,
            providerName: cleaned(profile.name) ?? "BirdNion provider",
            model: model,
            baseURL: endpoint,
            bearerToken: bearerToken,
            signature: signature
        )
    }

    private static func stateURL(configURL: URL) -> URL {
        configURL.deletingLastPathComponent().appendingPathComponent("birdnion-provider-state.json")
    }

    private static func loadState(configURL: URL) -> ManagedState? {
        let url = stateURL(configURL: configURL)
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(ManagedState.self, from: data),
              state.configPath == configURL.path else { return nil }
        return state
    }

    private static func writeState(_ state: ManagedState, configURL: URL) throws {
        let data = try JSONEncoder().encode(state)
        try writeData(data, to: stateURL(configURL: configURL))
    }

    private static func write(_ contents: String, to url: URL) throws {
        try writeData(Data(contents.utf8), to: url)
    }

    private static func writeData(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
