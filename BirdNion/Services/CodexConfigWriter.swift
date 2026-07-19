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

    // MARK: - Per-project profile files (`codex --profile <name>`)
    //
    // Codex ignores provider keys in project-local `.codex/config.toml` (a
    // deliberate security boundary), so the only per-project mechanism is a
    // user-level profile overlay file `~/.codex/<name>.config.toml` selected
    // with `codex --profile <name>`. One file per BirdNion profile, tracked in
    // a sidecar map so rename/delete never leaves stale credential files.

    private struct ProfileFilesState: Codable, Equatable {
        var files: [String: String] = [:]   // BirdNion profile id → file name
    }

    /// Codex profile names allow ASCII letters, digits, hyphens, underscores.
    static func profileFlagName(for profile: BirdNionConfigStore.CodexProfile) -> String {
        let slug = profile.name.lowercased().map { ch -> String in
            (ch.isASCII && (ch.isLetter || ch.isNumber)) ? String(ch) : "-"
        }.joined()
        var collapsed = ""
        for ch in slug where !(ch == "-" && collapsed.hasSuffix("-")) { collapsed.append(ch) }
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let base = trimmed.isEmpty ? String(profile.id.prefix(8)).lowercased() : trimmed
        return "bn-" + base
    }

    /// Write/refresh this profile's overlay file with the same managed block
    /// the global apply produces. Returns the `--profile` flag value.
    @discardableResult
    static func writeProfileFile(for profile: BirdNionConfigStore.CodexProfile,
                                 configURL: URL = targetURL()) throws -> String {
        let configuration = try providerConfiguration(for: profile)
        let directory = configURL.deletingLastPathComponent()
        var state = loadProfileFilesState(configURL: configURL)

        var flag = profileFlagName(for: profile)
        // Two profiles sharing one display name must not share one file.
        if state.files.contains(where: { $0.key != profile.id && $0.value == flag + ".config.toml" }) {
            flag += "-" + String(profile.id.prefix(4)).lowercased()
        }
        let fileName = flag + ".config.toml"

        if let previous = state.files[profile.id], previous != fileName {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(previous))
        }
        try write(CodexConfigDocument.applying(configuration, to: ""),
                  to: directory.appendingPathComponent(fileName))
        state.files[profile.id] = fileName
        try writeProfileFilesState(state, configURL: configURL)
        return flag
    }

    /// The flag to pass to `codex --profile`, or nil when no overlay file has
    /// been written for this profile yet.
    static func profileFlag(forProfileID id: String, configURL: URL = targetURL()) -> String? {
        guard let name = loadProfileFilesState(configURL: configURL).files[id],
              name.hasSuffix(".config.toml") else { return nil }
        return String(name.dropLast(".config.toml".count))
    }

    static func removeProfileFile(profileID: String, configURL: URL = targetURL()) {
        var state = loadProfileFilesState(configURL: configURL)
        guard let name = state.files.removeValue(forKey: profileID) else { return }
        try? FileManager.default.removeItem(
            at: configURL.deletingLastPathComponent().appendingPathComponent(name))
        try? writeProfileFilesState(state, configURL: configURL)
    }

    private static func profileFilesStateURL(configURL: URL) -> URL {
        configURL.deletingLastPathComponent().appendingPathComponent("birdnion-profile-files.json")
    }

    private static func loadProfileFilesState(configURL: URL) -> ProfileFilesState {
        guard let data = try? Data(contentsOf: profileFilesStateURL(configURL: configURL)),
              let state = try? JSONDecoder().decode(ProfileFilesState.self, from: data) else {
            return ProfileFilesState()
        }
        return state
    }

    private static func writeProfileFilesState(_ state: ProfileFilesState, configURL: URL) throws {
        try writeData(try JSONEncoder().encode(state), to: profileFilesStateURL(configURL: configURL))
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
