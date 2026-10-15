import Foundation
import Network

/// Headless CLI mode for the BirdNion app binary, in the spirit of
/// CodexBar's `codexbar` CLI: `birdnion usage --json`, `birdnion serve`,
/// `birdnion config import`, … Running with a recognized subcommand skips
/// the status-item/GUI path entirely; unknown arguments still boot the app
/// normally so a stray flag can't brick the menu-bar experience.
enum BirdNionCLI {
    static private(set) var active = false

    static let defaultServePort = 8080
    static let serveRefreshInterval: TimeInterval = 60
    static let fetchTimeoutSeconds: TimeInterval = 30

    static func wantsCLIMode(_ arguments: [String]) -> Bool {
        guard let first = arguments.dropFirst().first else { return false }
        return [
            "usage", "providers", "config", "serve",
            "help", "--help", "-h", "version", "--version",
        ].contains(first)
    }

    static func activate() { active = true }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    static let helpText = """
    birdnion — AI quota on the menu bar, scripted.

    usage:
      birdnion usage [--json]         Fetch quota for every enabled provider
      birdnion providers              List providers and their enabled state
      birdnion config import <file>   Queue a portable-preferences JSON import
                                      for the running app to consume
      birdnion serve [--port N]       Local HTTP JSON feed (default port \(defaultServePort)):
                                      GET /usage → same payload as `usage --json`
      birdnion version                Print version
      birdnion help                   This text
    """

    @MainActor
    static func run(arguments: [String]) async -> Int32 {
        var args = Array(arguments.dropFirst())
        let command = args.isEmpty ? "help" : args.removeFirst()
        switch command {
        case "usage":
            return await runUsage(json: args.contains("--json"))
        case "providers":
            return runProviders()
        case "config":
            return runConfig(args)
        case "serve":
            return await runServe(args)
        case "version", "--version":
            FileHandle.standardOutput.write(Data((versionString + "\n").utf8))
            return 0
        case "help", "--help", "-h":
            FileHandle.standardOutput.write(Data((helpText + "\n").utf8))
            return 0
        default:
            stderr("unknown command: \(command)\n\n\(helpText)\n")
            return 64
        }
    }

    // MARK: - usage

    @MainActor
    private static func fetchStatuses() async -> [ProviderStatus] {
        let providers = ServicesContainer.makeProviders()
        return await withTaskGroup(of: ProviderStatus?.self) { group in
            for provider in providers {
                group.addTask {
                    await Self.fetchWithTimeout(provider)
                }
            }
            var statuses: [ProviderStatus] = []
            for await status in group {
                if let status { statuses.append(status) }
            }
            return statuses
        }
    }

    /// Per-provider fetch bounded by `fetchTimeoutSeconds` so one hung probe
    /// can't stall the CLI forever.
    private static func fetchWithTimeout(_ provider: QuotaProvider) async -> ProviderStatus? {
        await withTaskGroup(of: ProviderStatus?.self) { group in
            group.addTask {
                try? await provider.fetch()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(fetchTimeoutSeconds * 1_000_000_000))
                return nil
            }
            defer { group.cancelAll() }
            for await status in group {
                return status ?? ProviderStatus(
                    id: provider.id,
                    displayName: provider.displayName,
                    windows: [],
                    lastUpdated: Date(),
                    error: "Timed out after \(Int(fetchTimeoutSeconds))s")
            }
            return nil
        }
    }

    private static func runUsage(json: Bool) async -> Int32 {
        let statuses = await fetchStatuses()
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(statuses) else {
                stderr("usage: failed to encode statuses\n")
                return 1
            }
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            return 0
        }
        var lines: [String] = []
        for status in statuses {
            if let error = status.error {
                lines.append("\(status.displayName): error — \(error)")
                continue
            }
            for window in status.windows {
                var parts = ["\(status.displayName) \(window.label): \(window.usedPct)% used"]
                if let reset = window.resetDate {
                    parts.append("reset \(reset.formatted())")
                }
                lines.append(parts.joined(separator: " · "))
            }
            if status.windows.isEmpty {
                lines.append("\(status.displayName): no quota data")
            }
        }
        FileHandle.standardOutput.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        return 0
    }

    // MARK: - providers

    private static func runProviders() -> Int32 {
        let providers = BirdNionConfigStore.allProviders()
        let lines = providers.map { "\($0.id)\t\(($0.enabled ?? false) ? "enabled" : "disabled")" }
        FileHandle.standardOutput.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        return 0
    }

    // MARK: - config import

    private static func runConfig(_ args: [String]) -> Int32 {
        guard args.first == "import", let path = args.dropFirst().first else {
            stderr("usage: birdnion config import <preferences.json>\n")
            return 64
        }
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url) else {
            stderr("config import: cannot read \(path)\n")
            return 1
        }
        do {
            let document = try PreferencesDocument(data: data)
            try document.queueImport(in: .standard)
            FileHandle.standardOutput.write(Data(
                "Queued import for the running app (\(document.preferences.count) preferences).\n".utf8))
            return 0
        } catch {
            stderr("config import: \(error.localizedDescription)\n")
            return 1
        }
    }

    // MARK: - serve

    private static func runServe(_ args: [String]) async -> Int32 {
        var port = defaultServePort
        var iterator = args.makeIterator()
        while let arg = iterator.next() {
            if arg == "--port", let value = iterator.next(), let parsed = Int(value),
               (1...65535).contains(parsed) {
                port = parsed
            }
        }
        guard let listener = try? NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: UInt16(port))!)
        else {
            stderr("serve: cannot bind 127.0.0.1:\(port)\n")
            return 1
        }
        let state = ServeState()
        listener.newConnectionHandler = { connection in
            state.handle(connection)
        }
        listener.start(queue: .main)
        stderr("BirdNion serving on http://127.0.0.1:\(port) (GET /usage)\n")

        // Refresh loop keeps the served snapshot warm.
        Task { @MainActor in
            while !Task.isCancelled {
                let statuses = await Self.fetchStatuses()
                state.update(statuses)
                try? await Task.sleep(nanoseconds: UInt64(serveRefreshInterval * 1_000_000_000))
            }
        }
        await withCheckedContinuation { (_: CheckedContinuation<Never, Never>) in }
        return 0
    }

    /// Snapshot holder + per-connection HTTP responder for `serve`.
    /// 127.0.0.1 only: quota payloads never leave the machine.
    private final class ServeState {
        private let lock = NSLock()
        private var payload: Data = "[]".data(using: .utf8)!

        func update(_ statuses: [ProviderStatus]) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(statuses) else { return }
            lock.withLock { payload = data }
        }

        func handle(_ connection: NWConnection) {
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
                [weak self] data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let wantsUsage = request.hasPrefix("GET /usage")
                let body: Data = wantsUsage ? (self?.currentPayload() ?? Data()) : "not found".data(using: .utf8)!
                let status = wantsUsage ? "200 OK" : "404 Not Found"
                let contentType = wantsUsage ? "application/json" : "text/plain"
                let response = """
                HTTP/1.1 \(status)\r
                Content-Type: \(contentType)\r
                Content-Length: \(body.count)\r
                Connection: close\r
                \r

                """
                connection.send(
                    content: Data(response.utf8) + body,
                    completion: .contentProcessed { _ in connection.cancel() })
            }
        }

        private func currentPayload() -> Data {
            lock.withLock { payload }
        }
    }

    private static func stderr(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}
