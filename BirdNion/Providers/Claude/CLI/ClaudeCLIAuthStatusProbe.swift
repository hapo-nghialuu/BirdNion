import Foundation

/// Cheap `claude auth status --json` gate run before the expensive PTY
/// `/usage` probe — port of CodexBarCore's ClaudeCLIAuthStatusProbe. Any
/// non-`loggedIn` verdict (logged out, timeout, unparsable output) counts as
/// "not logged in" so the auto plan falls through to the next source instead
/// of burning the core budget on a doomed TUI session.
enum ClaudeCLIAuthStatusProbe {
    private struct Response: Decodable {
        let loggedIn: Bool
    }

    static func isLoggedIn(timeout: TimeInterval = 5) async -> Bool {
        guard let binary = ClaudeCLIResolver.resolvedBinaryPath() else { return false }
        guard let output = try? await ClaudeCLISession.runDirectProcess(
            binary: binary, arguments: ["auth", "status", "--json"], timeout: timeout),
            let data = output.data(using: .utf8),
            let response = try? JSONDecoder().decode(Response.self, from: data)
        else { return false }
        return response.loggedIn
    }
}
