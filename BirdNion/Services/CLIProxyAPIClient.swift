import Foundation

/// Synchronizes BirdNion's private, loopback CLIProxyAPI core. The helper owns
/// protocol conversion; BirdNion only supplies its generated configuration.
struct CLIProxyAPIClient {
    enum ClientError: Error, Equatable {
        case invalidProxyURL
        case network
        case http(Int)
        case invalidResponse
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// The embedded helper is exclusively managed by BirdNion, so each PUT
    /// replaces the whole corresponding list instead of merging user-owned
    /// entries from another CLIProxyAPI instance.
    func synchronize(_ configuration: CLIProxyAPIConfiguration) async throws {
        try await put(configuration.apiKeys, route: "api-keys", configuration: configuration)
        try await put(configuration.claudeAPIKeys, route: "claude-api-key", configuration: configuration)
        try await put(configuration.openAICompatibility, route: "openai-compatibility", configuration: configuration)
    }

    private func put<T: Encodable>(_ value: T,
                                   route: String,
                                   configuration: CLIProxyAPIConfiguration) async throws {
        let body: Data
        do {
            body = try JSONEncoder().encode(value)
        } catch {
            throw ClientError.invalidResponse
        }
        let endpoint = try managementEndpoint(baseURL: configuration.baseURL, route: route)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "PUT"
        request.timeoutInterval = 12
        request.httpBody = body
        request.setValue("Bearer \(configuration.managementKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let response: URLResponse
        do {
            let (_, receivedResponse) = try await session.data(for: request)
            response = receivedResponse
        } catch {
            throw ClientError.network
        }
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw ClientError.http(http.statusCode) }
    }

    private func managementEndpoint(baseURL: String, route: String) throws -> URL {
        guard var components = URLComponents(string: baseURL),
              components.scheme != nil, components.host != nil else { throw ClientError.invalidProxyURL }
        var path = components.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        components.path = path + "/v0/management/\(route)"
        components.query = nil
        components.fragment = nil
        guard let endpoint = components.url else { throw ClientError.invalidProxyURL }
        return endpoint
    }
}
