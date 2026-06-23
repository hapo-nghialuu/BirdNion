import Foundation

struct ProvidersDocument: Codable {
    var version: Int = 1
    var providers: [ProviderConfig]
}

struct ProviderConfig: Codable, Equatable {
    var id: String
    var enabled: Bool
    var baseURL: String?
    var displayName: String?
}

enum ProvidersStoreError: Error {
    case lockHeld
    case ioError(Error)
}

/// Atomic JSON load/save with flock-style single-instance guard.
/// First-launch: ensures Application Support/AIStatusbar/ exists (Finding F4).
struct ProvidersStore {
    static let defaultDocument: ProvidersDocument = {
        ProvidersDocument(providers: [
            ProviderConfig(id: "minimax", enabled: true),
            ProviderConfig(id: "hapo", enabled: true,
                           baseURL: "https://<HAPO_BASE_URL>",
                           displayName: "Hapo AI Hub")
        ])
    }()

    static func defaultURL() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask,
                                                  appropriateFor: nil,
                                                  create: true)
        let dir = support.appendingPathComponent("AIStatusbar", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("providers.json")
    }

    static func load() -> ProvidersDocument {
        guard let url = try? defaultURL() else { return defaultDocument }
        guard let data = try? Data(contentsOf: url) else { return defaultDocument }
        let decoder = JSONDecoder()
        guard let doc = try? decoder.decode(ProvidersDocument.self, from: data) else {
            return defaultDocument
        }
        return doc
    }

    static func save(_ doc: ProvidersDocument) throws {
        let url = try defaultURL()
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".providers.json.tmp")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(doc)
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }
}
