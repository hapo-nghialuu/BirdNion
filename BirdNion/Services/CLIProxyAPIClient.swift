import Foundation

/// Configures one BirdNion-owned OpenAI-compatible upstream in a running
/// CLIProxyAPI process. The proxy, not BirdNion, performs protocol conversion.
struct CLIProxyAPIClient {
    enum ClientError: Error, Equatable {
        case incompleteConfiguration
        case invalidProxyURL
        case network
        case http(Int)
        case invalidResponse

    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Replace only this profile's stable, BirdNion-owned entry. All unrelated
    /// entries returned by CLIProxyAPI are sent back unchanged in the PUT body.
    func configure(profile: BirdNionConfigStore.ClaudeCodeProfile) async throws {
        guard profile.isOpenAICompatible else { return }
        guard let input = Input(profile: profile) else { throw ClientError.incompleteConfiguration }
        let endpoint = try managementEndpoint(proxyBaseURL: input.proxyBaseURL)

        var entries = try await getEntries(at: endpoint, managementKey: input.managementKey)
        entries.removeAll { ($0["name"] as? String) == input.providerName }
        entries.append(try entryObject(input: input))
        try await put(entries: entries, at: endpoint, managementKey: input.managementKey)
    }

    private struct Input {
        let providerName: String
        let proxyBaseURL: String
        let managementKey: String
        let upstreamBaseURL: String
        let upstreamAPIKey: String
        let models: [String]

        init?(profile: BirdNionConfigStore.ClaudeCodeProfile) {
            guard let proxyBaseURL = profile.normalizedCLIProxyBaseURL,
                  let managementKey = cleaned(profile.cliProxyManagementKey),
                  let upstreamBaseURL = cleaned(profile.openAIBaseURL),
                  let upstreamAPIKey = cleaned(profile.openAIAPIKey) else { return nil }
            let uniqueModels = profile.openAIModelNames.reduce(into: [String]()) { result, model in
                if !result.contains(model) { result.append(model) }
            }
            guard !uniqueModels.isEmpty else { return nil }
            self.providerName = profile.cliProxyProviderName
            self.proxyBaseURL = proxyBaseURL
            self.managementKey = managementKey
            self.upstreamBaseURL = upstreamBaseURL
            self.upstreamAPIKey = upstreamAPIKey
            self.models = uniqueModels
        }
    }

    private struct Entry: Encodable {
        struct APIKey: Encodable {
            let apiKey: String

            enum CodingKeys: String, CodingKey {
                case apiKey = "api-key"
            }
        }

        struct Model: Encodable {
            let name: String
            let alias: String
        }

        let name: String
        let prefix: String
        let baseURL: String
        let apiKeyEntries: [APIKey]
        let models: [Model]

        enum CodingKeys: String, CodingKey {
            case name
            case prefix
            case baseURL = "base-url"
            case apiKeyEntries = "api-key-entries"
            case models
        }
    }

    private func entryObject(input: Input) throws -> [String: Any] {
        let entry = Entry(
            name: input.providerName,
            prefix: input.providerName,
            baseURL: input.upstreamBaseURL,
            apiKeyEntries: [.init(apiKey: input.upstreamAPIKey)],
            models: input.models.map { .init(name: $0, alias: $0) }
        )
        let data = try JSONEncoder().encode(entry)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClientError.invalidResponse
        }
        return object
    }

    private func getEntries(at endpoint: URL, managementKey: String) async throws -> [[String: Any]] {
        let (data, response) = try await send(request(at: endpoint, method: "GET", managementKey: managementKey))
        try requireSuccess(response)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawEntries = root["openai-compatibility"] else {
            throw ClientError.invalidResponse
        }
        if rawEntries is NSNull { return [] }
        guard let entries = rawEntries as? [[String: Any]] else { throw ClientError.invalidResponse }
        return entries
    }

    private func put(entries: [[String: Any]], at endpoint: URL, managementKey: String) async throws {
        let body: Data
        do {
            body = try JSONSerialization.data(withJSONObject: entries)
        } catch {
            throw ClientError.invalidResponse
        }
        let (data, response) = try await send(request(at: endpoint, method: "PUT", managementKey: managementKey, body: body))
        _ = data
        try requireSuccess(response)
    }

    private func request(at endpoint: URL, method: String, managementKey: String, body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.timeoutInterval = 12
        request.httpBody = body
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw ClientError.network
        }
    }

    private func requireSuccess(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw ClientError.http(http.statusCode) }
    }

    private func managementEndpoint(proxyBaseURL: String) throws -> URL {
        guard var components = URLComponents(string: proxyBaseURL),
              components.scheme != nil, components.host != nil else { throw ClientError.invalidProxyURL }
        var path = components.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        components.path = path + "/v0/management/openai-compatibility"
        components.query = nil
        components.fragment = nil
        guard let endpoint = components.url else { throw ClientError.invalidProxyURL }
        return endpoint
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
