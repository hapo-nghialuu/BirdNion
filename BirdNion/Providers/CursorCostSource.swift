import Foundation
import SQLite3

/// Local cost source: Cursor's composer bubble records in
/// `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`
/// (`cursorDiskKV` rows keyed `bubbleId:<composer>:<id>`, JSON payloads with
/// explicit token totals + model + timestamps — the same rows Tokenize-style
/// readers use). Assistant bubbles carry the usage; each emitted turn is
/// keyed by the bubble id so resuming a conversation can't double count.
enum CursorCostSource {

    static let descriptor = LocalCostSource(
        source: .cursor,
        displayName: "Cursor",
        countingRevision: 1,
        roots: { CursorCostSource.dataRoots() },
        turnReader: { roots, cutoff in
            CursorCostSource.turns(roots: roots, cutoff: cutoff)
        })

    /// Roots are the globalStorage dirs that contain `state.vscdb`.
    private static func dataRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(
            "Library/Application Support/Cursor/User/globalStorage")
        return FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("state.vscdb").path) ? [dir] : []
    }

    private static func turns(roots: [URL], cutoff: Date) -> [LocalTurnRecord] {
        roots.flatMap { turns(database: $0.appendingPathComponent("state.vscdb"), cutoff: cutoff) }
    }

    private static func turns(database url: URL, cutoff: Date) -> [LocalTurnRecord] {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? cutoff
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "%?#")
        guard let path = url.path.addingPercentEncoding(withAllowedCharacters: allowed) else { return [] }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            "file:\(path)?immutable=1",
            &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK
        else {
            if handle != nil { sqlite3_close(handle) }
            return []
        }
        guard let database = handle else { return [] }
        defer { sqlite3_close(database) }

        var hasTable = false
        var check: OpaquePointer?
        if sqlite3_prepare_v2(
            database,
            "SELECT 1 FROM main.sqlite_master WHERE type='table' AND name='cursorDiskKV' LIMIT 1",
            -1, &check, nil) == SQLITE_OK {
            hasTable = sqlite3_step(check) == SQLITE_ROW
        }
        sqlite3_finalize(check)
        guard hasTable else { return [] }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT key, value FROM main.cursorDiskKV WHERE key LIKE 'bubbleId:%' LIMIT 20000",
            -1, &statement, nil) == SQLITE_OK
        else { return [] }
        defer { sqlite3_finalize(statement) }

        var out: [LocalTurnRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let keyPtr = sqlite3_column_text(statement, 0) else { continue }
            let key = String(cString: keyPtr)
            let data: Data
            if sqlite3_column_type(statement, 1) == SQLITE_BLOB,
               let blob = sqlite3_column_blob(statement, 1) {
                data = Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 1)))
            } else if let textPtr = sqlite3_column_text(statement, 1) {
                data = Data(String(cString: textPtr).utf8)
            } else {
                continue
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) else { continue }
            out.append(contentsOf: GenericJsonCostSource.turns(
                in: object, spec: .default, fallbackDate: mtime, cutoff: cutoff,
                dedupePrefix: "cursor:\(key)"))
        }
        return out
    }
}
