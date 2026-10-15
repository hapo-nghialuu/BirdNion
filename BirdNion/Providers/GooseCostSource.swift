import Foundation
import SQLite3

/// Local cost source: Goose's session SQLite database —
/// `~/.local/share/goose/sessions/sessions.db`, the macOS Application
/// Support variant, and the Block install path (same databases ccusage
/// reads). Token columns are mapped leniently: `accumulated_*` first,
/// plain `input_tokens`/`output_tokens`/`total_tokens` as aliases; any
/// positive `total - input - output` remainder counts as output-priced
/// usage (ccusage's reasoning convention). USD estimates price the model
/// through `LocalCostPricing`.
enum GooseCostSource {

    static let descriptor = LocalCostSource(
        source: .goose,
        displayName: "Goose",
        countingRevision: 2,
        roots: { GooseCostSource.dataRoots() },
        turnReader: { roots, cutoff in
            GooseCostSource.turns(roots: roots, cutoff: cutoff)
        })

    /// Roots are the directories that contain a `sessions.db`.
    private static func dataRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/share/goose/sessions"),
            home.appendingPathComponent("Library/Application Support/goose/sessions"),
            home.appendingPathComponent(".local/share/Block/goose/sessions"),
        ]
        return candidates.filter {
            FileManager.default.fileExists(
                atPath: $0.appendingPathComponent("sessions.db").path)
        }
    }

    private static func turns(roots: [URL], cutoff: Date) -> [LocalTurnRecord] {
        roots.flatMap { turns(database: $0.appendingPathComponent("sessions.db"), cutoff: cutoff) }
    }

    private static func turns(database url: URL, cutoff: Date) -> [LocalTurnRecord] {
        guard let database = LocalCostParsing.openReadOnlyDatabase(url) else { return [] }
        defer { sqlite3_close(database) }

        guard let table = sessionsTable(database) else { return [] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database, "SELECT rowid, * FROM main.\(table) ORDER BY rowid DESC LIMIT 5000",
            -1, &statement, nil) == SQLITE_OK
        else { return [] }
        defer { sqlite3_finalize(statement) }

        var out: [LocalTurnRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let columnCount = Int(sqlite3_column_count(statement))
            var columns: [String: Any] = [:]
            for index in 1..<columnCount {
                let name = String(cString: sqlite3_column_name(statement, Int32(index)))
                switch sqlite3_column_type(statement, Int32(index)) {
                case SQLITE_INTEGER:
                    columns[name] = Int(sqlite3_column_int64(statement, Int32(index)))
                case SQLITE_FLOAT:
                    columns[name] = sqlite3_column_double(statement, Int32(index))
                case SQLITE_TEXT:
                    if let text = sqlite3_column_text(statement, Int32(index)) {
                        columns[name] = String(cString: text)
                    }
                default:
                    break
                }
            }
            let input = first(columns, ["accumulated_input_tokens", "input_tokens"]) ?? 0
            let output = first(columns, ["accumulated_output_tokens", "output_tokens"]) ?? 0
            let explicitTotal = first(columns, ["accumulated_total_tokens", "total_tokens"])
            let total = explicitTotal ?? (input + output)
            guard total > 0 else { continue }
            // The remainder beyond input+output is output-priced reasoning.
            let extra = max(0, total - input - output)
            let model = modelName(columns)
            guard let date = sessionStart(columns), date >= cutoff else { continue }
            out.append(LocalTurnRecord(
                date: date, model: model, tokens: total,
                usd: LocalCostPricing.estimate(
                    model: model, input: input, cacheRead: 0,
                    cacheWrite: 0, output: output + extra),
                dedupeKey: "goose:\(url.path):\(sqlite3_column_int64(statement, 0))"))
        }
        return out
    }

    /// First table whose columns mention tokens — normally `sessions`.
    private static func sessionsTable(_ database: OpaquePointer) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT name, sql FROM main.sqlite_master WHERE type='table'",
            -1, &statement, nil) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(statement) }
        var fallback: String?
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let namePtr = sqlite3_column_text(statement, 0),
                  let sqlPtr = sqlite3_column_text(statement, 1)
            else { continue }
            let name = String(cString: namePtr)
            let sql = String(cString: sqlPtr).lowercased()
            if name == "sessions" { return name }
            if fallback == nil, sql.contains("token") { fallback = name }
        }
        return fallback
    }

    private static func first(_ columns: [String: Any], _ keys: [String]) -> Int? {
        for key in keys {
            if let value = LocalCostParsing.int(columns[key]) { return value }
        }
        return nil
    }

    private static func modelName(_ columns: [String: Any]) -> String {
        if let json = columns["model_config_json"] as? String,
           let data = json.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let name = object["model_name"] as? String { return name }
            if let name = object["model"] as? String { return name }
        }
        if let provider = columns["provider_name"] as? String { return provider }
        return (columns["model"] as? String) ?? "unknown"
    }

    /// Goose stores session-cumulative totals, so the whole total is
    /// attributed to the session's own start day: that date never moves,
    /// whereas `updated_at` would shift the same tokens to a new day on every
    /// scan and the history high-water merge would then keep both. Rows with
    /// no start timestamp are dropped rather than guessed.
    private static func sessionStart(_ columns: [String: Any]) -> Date? {
        for key in ["created_at", "start_timestamp", "timestamp"] {
            if let date = LocalCostParsing.parseTimestamp(columns[key]) { return date }
        }
        return nil
    }
}
