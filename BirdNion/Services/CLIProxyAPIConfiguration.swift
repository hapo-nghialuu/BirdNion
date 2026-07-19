import Foundation

/// Typed subset of CLIProxyAPI's configuration that BirdNion owns. Keeping the
/// JSON and YAML representation here ensures the local helper and its runtime
/// management API receive the exact same profile mapping.
struct CLIProxyAPIConfiguration: Encodable {
    struct Model: Encodable, Equatable {
        let name: String
        let alias: String
    }

    struct ClaudeKey: Encodable, Equatable {
        let apiKey: String
        let prefix: String
        let baseURL: String
        let models: [Model]

        enum CodingKeys: String, CodingKey {
            case apiKey = "api-key"
            case prefix
            case baseURL = "base-url"
            case models
        }
    }

    struct OpenAIAPIKey: Encodable, Equatable {
        let apiKey: String

        enum CodingKeys: String, CodingKey {
            case apiKey = "api-key"
        }
    }

    struct OpenAICompatibility: Encodable, Equatable {
        let name: String
        let prefix: String
        let baseURL: String
        let apiKeyEntries: [OpenAIAPIKey]
        let models: [Model]
        let format: String?

        enum CodingKeys: String, CodingKey {
            case name
            case prefix
            case baseURL = "base-url"
            case apiKeyEntries = "api-key-entries"
            case models
            case format
        }
    }

    private enum UpstreamKind {
        case anthropic
        case openAI(format: String?)
    }

    private struct ManagedProfile {
        let providerName: String
        let kind: UpstreamKind
        let baseURL: String
        let apiKey: String
        let localAPIKey: String
        let managementKey: String
        let models: [Model]
    }

    /// Keep BirdNion's embedded helper away from CLIProxyAPI's documented
    /// default port so it does not collide with a separately installed server.
    static let localPort = 24_323
    static let legacyLocalPort = 8_317
    static let localBaseURL = "http://127.0.0.1:\(localPort)"

    let baseURL: String
    let authDirectory: String
    let managementKey: String
    let apiKeys: [String]
    let claudeAPIKeys: [ClaudeKey]
    let openAICompatibility: [OpenAICompatibility]

    init?(profiles: [BirdNionConfigStore.ClaudeCodeProfile], authDirectory: URL) {
        self.init(claudeProfiles: profiles, codexProfiles: [], authDirectory: authDirectory)
    }

    init?(claudeProfiles: [BirdNionConfigStore.ClaudeCodeProfile],
          codexProfiles: [BirdNionConfigStore.CodexProfile],
          authDirectory: URL) {
        let managed = Self.managedProfiles(claudeProfiles: claudeProfiles, codexProfiles: codexProfiles)
        guard let managementKey = managed.map(\.managementKey).first(where: { !$0.isEmpty }) else {
            return nil
        }
        let compatible = managed.filter { $0.managementKey == managementKey }
        guard !compatible.isEmpty else { return nil }

        self.baseURL = Self.localBaseURL
        self.authDirectory = authDirectory.path
        self.managementKey = managementKey
        self.apiKeys = Self.unique(compatible.map(\.localAPIKey))
        self.claudeAPIKeys = compatible.compactMap { profile in
            guard case .anthropic = profile.kind else { return nil }
            return ClaudeKey(
                apiKey: profile.apiKey,
                prefix: "",
                baseURL: profile.baseURL,
                models: profile.models
            )
        }
        self.openAICompatibility = compatible.compactMap { profile in
            guard case let .openAI(format) = profile.kind else { return nil }
            return OpenAICompatibility(
                name: profile.providerName,
                prefix: "",
                baseURL: profile.baseURL,
                apiKeyEntries: [.init(apiKey: profile.apiKey)],
                models: profile.models,
                format: format
            )
        }
    }

    func yamlData() -> Data {
        var lines = [
            "host: \(quote("127.0.0.1"))",
            "port: \(Self.localPort)",
            "auth-dir: \(quote(authDirectory))",
            "api-keys:",
        ]
        lines += apiKeys.map { "  - \(quote($0))" }
        lines += [
            "remote-management:",
            "  allow-remote: false",
            "  secret-key: \(quote(managementKey))",
            "  disable-control-panel: true",
            "  disable-auto-update-panel: true",
            "disable-claude-cloak-mode: true",
            "force-model-prefix: false",
            "debug: false",
        ]
        appendClaudeKeys(to: &lines)
        appendOpenAICompatibility(to: &lines)
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private func appendClaudeKeys(to lines: inout [String]) {
        guard !claudeAPIKeys.isEmpty else { return }
        lines.append("claude-api-key:")
        for entry in claudeAPIKeys {
            lines += [
                "  - api-key: \(quote(entry.apiKey))",
                "    prefix: \(quote(entry.prefix))",
                "    base-url: \(quote(entry.baseURL))",
            ]
            append(models: entry.models, indent: "    ", to: &lines)
        }
    }

    private func appendOpenAICompatibility(to lines: inout [String]) {
        guard !openAICompatibility.isEmpty else { return }
        lines.append("openai-compatibility:")
        for entry in openAICompatibility {
            var entryLines = [
                "  - name: \(quote(entry.name))",
                "    prefix: \(quote(entry.prefix))",
                "    base-url: \(quote(entry.baseURL))",
            ]
            if let format = entry.format?.trimmingCharacters(in: .whitespacesAndNewlines), !format.isEmpty {
                entryLines.append("    format: \(quote(format))")
            }
            entryLines.append("    api-key-entries:")
            lines += entryLines
            lines += entry.apiKeyEntries.map { "      - api-key: \(quote($0.apiKey))" }
            append(models: entry.models, indent: "    ", to: &lines)
        }
    }

    private func append(models: [Model], indent: String, to lines: inout [String]) {
        guard !models.isEmpty else { return }
        lines.append("\(indent)models:")
        for model in models {
            lines += [
                "\(indent)  - name: \(quote(model.name))",
                "\(indent)    alias: \(quote(model.alias))",
            ]
        }
    }

    private static func models(for profile: BirdNionConfigStore.ClaudeCodeProfile) -> [Model] {
        var aliases = Set<String>()
        return profile.openAIModelNames.compactMap { model in
            let alias = Self.localModelAlias(for: model)
            guard aliases.insert(alias).inserted else { return nil }
            return .init(name: model, alias: alias)
        }
    }

    private static func managedProfiles(
        claudeProfiles: [BirdNionConfigStore.ClaudeCodeProfile],
        codexProfiles: [BirdNionConfigStore.CodexProfile]
    ) -> [ManagedProfile] {
        let claude = claudeProfiles.compactMap { profile -> ManagedProfile? in
            guard profile.embeddedLocalProxy == true,
                  profile.isEmbeddedCLIProxyReady,
                  let baseURL = profile.upstreamBaseURL,
                  let apiKey = profile.upstreamAPIKey,
                  let localAPIKey = profile.cliProxyAPIKey,
                  let managementKey = profile.cliProxyManagementKey else { return nil }
            let kind: UpstreamKind = profile.compatibility == .anthropic
                ? .anthropic
                : .openAI(format: profile.openAIProxyFormat)
            return ManagedProfile(
                providerName: profile.cliProxyProviderName,
                kind: kind,
                baseURL: baseURL,
                apiKey: apiKey,
                localAPIKey: localAPIKey,
                managementKey: managementKey,
                models: Self.models(for: profile)
            )
        }
        let codex = codexProfiles.compactMap { profile -> ManagedProfile? in
            guard profile.usesEmbeddedCLIProxy,
                  profile.isEmbeddedCLIProxyReady,
                  let baseURL = Self.cleaned(profile.baseURL),
                  let apiKey = Self.cleaned(profile.apiKey),
                  let localAPIKey = profile.cliProxyAPIKey,
                  let managementKey = profile.cliProxyManagementKey,
                  let model = Self.cleaned(profile.model) else { return nil }
            let kind: UpstreamKind
            switch profile.upstreamProtocol {
            case .anthropic:
                kind = .anthropic
            case .openAIChat:
                kind = .openAI(format: nil)
            case .responses:
                kind = .openAI(format: "responses")
            }
            return ManagedProfile(
                providerName: profile.cliProxyProviderName,
                kind: kind,
                baseURL: baseURL,
                apiKey: apiKey,
                localAPIKey: localAPIKey,
                managementKey: managementKey,
                models: [.init(name: model, alias: model)]
            )
        }
        return claude + codex
    }

    /// Claude Code removes its documented `[1m]` model marker before sending a
    /// request. Keep the marker in the upstream name, but register the local
    /// alias without it so routing still resolves to the intended provider.
    static func localModelAlias(for model: String) -> String {
        let marker = "[1m]"
        guard model.lowercased().hasSuffix(marker) else { return model }
        return String(model.dropLast(marker.count))
    }

    private static func unique(_ values: [String]) -> [String] {
        values.reduce(into: [String]()) { result, value in
            if !result.contains(value) { result.append(value) }
        }
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private func quote(_ value: String) -> String {
        Self.quote(value)
    }

    private static func quote(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value), let string = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        // JSON permits `\/`, but YAML double-quoted scalars do not. JSONEncoder
        // emits that optional escape for slash-containing paths and URLs.
        return string.replacingOccurrences(of: "\\/", with: "/")
    }
}
