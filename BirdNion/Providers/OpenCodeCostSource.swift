import Foundation
import SQLite3

/// OpenCode local cost source — reads `~/.local/share/opencode/opencode.db`,
/// the sqlite store OpenCode keeps per assistant message/part with `tokens`
/// and `cost` already computed. Ported from CodexBar's
/// `OpenCodeGoLocalUsageReader`; upstream only counts rows whose
/// `providerID` is `opencode-go` (the Zen proxy messages carry real costs).
enum OpenCodeCostSource {

    static let descriptor = LocalCostSource(
        source: .opencode,
        displayName: "OpenCode",
        countingRevision: 1,
        roots: {
            let dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local", isDirectory: true)
                .appendingPathComponent("share", isDirectory: true)
                .appendingPathComponent("opencode", isDirectory: true)
            return FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("opencode.db").path)
                ? [dir] : []
        },
        turnReader: { roots, cutoff in
            roots.flatMap { root in
                Self.turns(
                    database: root.appendingPathComponent("opencode.db"),
                    cutoff: cutoff)
            }
        })

    // MARK: - SQLite reader

    private struct UsageRow {
        let key: String
        let createdMs: Int64
        let cost: Double
        let model: String
        let tokens: Int
    }

    static func turns(database: URL, cutoff: Date) -> [LocalTurnRecord] {
        guard FileManager.default.fileExists(atPath: database.path) else { return [] }
        let rows = (try? readRows(database: database, immutable: false))
            ?? (try? readRows(database: database, immutable: true))
            ?? []
        let cutoffMs = Int64(cutoff.timeIntervalSince1970 * 1_000)
        return rows.compactMap { row in
            guard row.createdMs >= cutoffMs else { return nil }
            return LocalTurnRecord(
                date: Date(timeIntervalSince1970: Double(row.createdMs) / 1_000),
                model: row.model.isEmpty ? "opencode" : row.model,
                tokens: row.tokens,
                usd: row.cost,
                dedupeKey: row.key)
        }
    }

    /// Normal open first; when a clean WAL shutdown left no sidecars the
    /// header still claims WAL mode, so retry with `immutable=1` (reads the
    /// idle main file without recreating sidecars).
    private static func readRows(database: URL, immutable: Bool) throws -> [UsageRow] {
        var db: OpaquePointer?
        let filename = immutable
            ? "\(database.absoluteURL.absoluteString)?immutable=1"
            : database.path
        let flags = immutable ? SQLITE_OPEN_READONLY | SQLITE_OPEN_URI : SQLITE_OPEN_READONLY
        guard sqlite3_open_v2(filename, &db, flags, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw SQLiteReadFailure(code: SQLITE_CANTOPEN, message: "open failed")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        let sql = try hasTable(named: "part", db: db)
            ? messageAndPartUsageSQL
            : "SELECT key, createdMs, cost, modelID, tokens FROM (\(providerMessagesSQL)) WHERE hasCost"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteReadFailure(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var rows: [UsageRow] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw SQLiteReadFailure(code: step, message: String(cString: sqlite3_errmsg(db)))
            }
            let key = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? UUID().uuidString
            let createdMs = sqlite3_column_int64(stmt, 1)
            let cost = sqlite3_column_double(stmt, 2)
            guard createdMs > 0, cost >= 0, cost.isFinite else { continue }
            let model = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            let tokens = sqlite3_column_text(stmt, 4).flatMap { json in
                TokenCounts(data: Data(String(cString: json).utf8))?.resolvedTotal
            }
            rows.append(UsageRow(
                key: key, createdMs: createdMs, cost: cost,
                model: model, tokens: tokens ?? 0))
        }
        return rows
    }

    private static func hasTable(named name: String, db: OpaquePointer?) throws -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
            -1, &stmt, nil) == SQLITE_OK
        else { throw SQLiteReadFailure(code: sqlite3_errcode(db), message: "prepare failed") }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT_CURSOR)
        let step = sqlite3_step(stmt)
        if step == SQLITE_ROW { return true }
        guard step == SQLITE_DONE else {
            throw SQLiteReadFailure(code: step, message: String(cString: sqlite3_errmsg(db)))
        }
        return false
    }

    /// Assistant messages attributed to the `opencode-go` Zen proxy.
    private static let providerMessagesSQL = """
        SELECT
          id AS key,
          CAST(COALESCE(json_extract(data, '$.time.created'), time_created) AS INTEGER) AS createdMs,
          CAST(json_extract(data, '$.cost') AS REAL) AS cost,
          json_type(data, '$.cost') IN ('integer', 'real') AS hasCost,
          COALESCE(json_extract(data, '$.modelID'), '') AS modelID,
          CASE WHEN json_type(data, '$.tokens') = 'object'
            THEN json_extract(data, '$.tokens') END AS tokens
        FROM message
        WHERE json_valid(data)
          AND json_extract(data, '$.providerID') = 'opencode-go'
          AND json_extract(data, '$.role') = 'assistant'
    """

    /// step-finish parts carry the real per-turn cost; messages with no such
    /// part fall back to their own cost field.
    private static let messageAndPartUsageSQL = """
        WITH provider_messages AS (\(providerMessagesSQL))
        SELECT
          'p:' || p.id AS key,
          CAST(COALESCE(json_extract(p.data, '$.time.created'), p.time_created, m.createdMs) AS INTEGER)
            AS createdMs,
          CAST(json_extract(p.data, '$.cost') AS REAL) AS cost,
          m.modelID AS modelID,
          CASE WHEN json_type(p.data, '$.tokens') = 'object'
            THEN json_extract(p.data, '$.tokens') END AS tokens
        FROM part p
        JOIN provider_messages m ON m.key = p.message_id
        WHERE json_valid(p.data)
          AND json_extract(p.data, '$.type') = 'step-finish'
          AND json_type(p.data, '$.cost') IN ('integer', 'real')
        UNION ALL
        SELECT 'm:' || key, createdMs, cost, modelID, tokens
        FROM provider_messages m
        WHERE hasCost
          AND NOT EXISTS (
            SELECT 1
            FROM part p
            WHERE p.message_id = m.key
              AND json_valid(p.data)
              AND json_extract(p.data, '$.type') = 'step-finish'
              AND json_type(p.data, '$.cost') IN ('integer', 'real')
          )
    """

    private struct TokenCounts: Decodable {
        struct Cache: Decodable {
            let read: Int?
            let write: Int?
        }

        let total: Int?
        let input: Int?
        let output: Int?
        let reasoning: Int?
        let cache: Cache?

        init?(data: Data) {
            guard let decoded = try? JSONDecoder().decode(TokenCounts.self, from: data)
            else { return nil }
            self = decoded
        }

        /// OpenCode separates output/reasoning and input/cache counts — the
        /// full total needs every component present, else the explicit total.
        var resolvedTotal: Int? {
            if let total { return total }
            let parts = [input, output, reasoning, cache?.read, cache?.write]
            guard parts.allSatisfy({ $0 != nil }) else { return nil }
            return parts.compactMap(\.self).reduce(0, +)
        }
    }

    private struct SQLiteReadFailure: Error {
        let code: Int32
        let message: String
    }
}

private let SQLITE_TRANSIENT_CURSOR = unsafeBitCast(-1 as Int, to: sqlite3_destructor_type.self)
