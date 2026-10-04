import Foundation
import SQLite3

/// Local cost source: Antigravity's offline conversation databases at
/// `~/.gemini/antigravity-cli/conversations/*.db` (plus the app data and
/// tokscale-cache variants CodexBar scans). Each `gen_metadata` row's `data`
/// blob is a protobuf generation record; this decodes the usage + timestamp
/// + model fields only (compact port of upstream's `AntigravityProtoReader`,
/// without its cross-table timestamp recovery — timestamp-less rows are
/// skipped, so the result stays a lower bound).
///
/// input = systemPrompt + newInput; total adds cacheRead + output + reasoning.
/// USD prices Claude-family models via `ClaudeModelPrice` and Gemini-family
/// via `GeminiModelPrice`; unknown models count tokens at $0.
enum AntigravityCostSource {

    static let descriptor = LocalCostSource(
        source: .antigravity,
        displayName: "Antigravity",
        countingRevision: 1,
        roots: { AntigravityCostSource.dataRoots() },
        turnReader: { roots, cutoff in
            AntigravityCostSource.turns(roots: roots, cutoff: cutoff)
        })

    private static func dataRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".gemini/antigravity-cli/conversations"),
            home.appendingPathComponent(".gemini/antigravity/conversations"),
            home.appendingPathComponent(".config/tokscale/antigravity-cache/sessions"),
        ]
        return candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func turns(roots: [URL], cutoff: Date) -> [LocalTurnRecord] {
        roots.flatMap { root in
            LocalCostParsing.files(
                under: root, extensions: ["db"], modifiedSince: cutoff
            ).flatMap { turns(database: $0, cutoff: cutoff) }
        }
    }

    private static func turns(database url: URL, cutoff: Date) -> [LocalTurnRecord] {
        let session = url.deletingPathExtension().lastPathComponent
        guard let rows = readRows(database: url) else { return [] }
        return rows.compactMap { row in
            guard let turn = AntigravityTurnDecoder.parseTurn(row.data),
                  let usage = turn.usage, let timestampMs = turn.timestampMs
            else { return nil }
            let date = Date(timeIntervalSince1970: Double(timestampMs) / 1000)
            guard date >= cutoff else { return nil }
            let input = usage.systemPrompt + usage.newInput
            let total = input + usage.output + usage.cacheRead + usage.reasoning
            guard total > 0 else { return nil }
            let model = turn.model ?? "unknown"
            return LocalTurnRecord(
                date: date, model: model, tokens: total,
                usd: cost(model: model, input: input, cacheRead: usage.cacheRead,
                          output: usage.output + usage.reasoning),
                dedupeKey: "agv:\(session):\(row.idx)")
        }
    }

    private static func cost(model: String, input: Int, cacheRead: Int, output: Int) -> Double {
        let m = model.lowercased()
        if m.contains("claude"), let price = ClaudeModelPrice.price(for: m) {
            return (Double(input) * price.inputPerM
                + Double(cacheRead) * price.cacheReadPerM
                + Double(output) * price.outputPerM) / 1_000_000
        }
        if m.contains("gemini"), let price = GeminiModelPrice.price(for: m) {
            return (Double(input) * price.inputPerM
                + Double(cacheRead) * price.cachedPerM
                + Double(output) * price.outputPerM) / 1_000_000
        }
        return 0
    }

    // MARK: - SQLite

    private struct DBRow {
        let idx: Int64
        let data: [UInt8]
    }

    /// Opens read-only; retries through `?immutable=1` when the WAL sidecars
    /// are absent (same fallback as the OpenCode source). Returns nil when
    /// the database can't be opened or has no `gen_metadata` table.
    private static func readRows(database url: URL) -> [DBRow]? {
        var handle: OpaquePointer?
        if sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            if handle != nil { sqlite3_close(handle) }
            handle = nil
            var allowed = CharacterSet.urlPathAllowed
            allowed.remove(charactersIn: "%?#")
            guard let path = url.path.addingPercentEncoding(withAllowedCharacters: allowed),
                  sqlite3_open_v2(
                    "file:\(path)?immutable=1",
                    &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK
            else {
                if handle != nil { sqlite3_close(handle) }
                return nil
            }
        }
        guard let database = handle else { return nil }
        defer { sqlite3_close(database) }

        var hasTable = false
        var check: OpaquePointer?
        if sqlite3_prepare_v2(
            database,
            "SELECT 1 FROM main.sqlite_master WHERE type='table' AND name='gen_metadata' LIMIT 1",
            -1, &check, nil) == SQLITE_OK {
            hasTable = sqlite3_step(check) == SQLITE_ROW
        }
        sqlite3_finalize(check)
        guard hasTable else { return nil }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT idx, data FROM main.gen_metadata LIMIT 10000",
            -1, &statement, nil) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(statement) }

        var rows: [DBRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard sqlite3_column_type(statement, 1) == SQLITE_BLOB,
                  let blob = sqlite3_column_blob(statement, 1)
            else { continue }
            let count = Int(sqlite3_column_bytes(statement, 1))
            guard count > 0 else { continue }
            rows.append(DBRow(
                idx: sqlite3_column_int64(statement, 0),
                data: Array(UnsafeBufferPointer(start: blob.assumingMemoryBound(to: UInt8.self), count: count))))
        }
        return rows
    }
}

/// Minimal protobuf wire decoder for Antigravity's `gen_metadata.data`
/// generation records. Layout (from upstream `AntigravityProtoReader`):
/// root {1: chat, 4: stepUUID}; chat {4: usage, 9: generation, 19: model,
/// 21: label}; usage {1: systemPrompt, 2: newInput, 5: cacheRead, 9: output,
/// 10: reasoning, 11: responseID}; generation {4: timestamp {1: sec, 2: ns}}.
struct AntigravityTurnDecoder {

    struct ParsedUsage {
        var systemPrompt = 0
        var newInput = 0
        var cacheRead = 0
        var output = 0
        var reasoning = 0
    }

    struct ParsedTurn {
        var usage: ParsedUsage?
        var timestampMs: Int64?
        var model: String?
    }

    private struct Reader {
        let bytes: ArraySlice<UInt8>
        var offset: Int
        var malformed = false

        mutating func readVarint() -> UInt64? {
            var result: UInt64 = 0
            for index in 0..<10 {
                guard offset < bytes.endIndex else { break }
                let byte = bytes[offset]
                offset += 1
                if index == 9, byte > 1 { break }
                result |= UInt64(byte & 0x7F) << (index * 7)
                if byte & 0x80 == 0 { return result }
            }
            malformed = true
            return nil
        }

        mutating func nextField() -> (number: Int, wire: Int, data: ArraySlice<UInt8>?, value: UInt64?)? {
            guard offset < bytes.endIndex else { return nil }
            guard let tag = readVarint(), tag >> 3 > 0, tag >> 3 <= 536_870_911 else {
                malformed = true
                return nil
            }
            let number = Int(tag >> 3)
            let wire = Int(tag & 7)
            if wire == 0 {
                guard let value = readVarint() else { return nil }
                return (number, wire, nil, value)
            }
            let count: Int? = switch wire {
            case 1: 8
            case 2: readVarint().flatMap(Int.init(exactly:))
            case 5: 4
            default: nil
            }
            guard let count, count <= bytes.endIndex - offset else {
                malformed = true
                return nil
            }
            let fieldData = bytes[offset..<offset + count]
            offset += count
            return (number, wire, fieldData, nil)
        }
    }

    private static func eachField(
        _ bytes: ArraySlice<UInt8>,
        visit: (Int, Int, ArraySlice<UInt8>?, UInt64?) -> Void
    ) -> Bool {
        var reader = Reader(bytes: bytes, offset: bytes.startIndex)
        while reader.offset < reader.bytes.endIndex {
            guard let field = reader.nextField() else { break }
            visit(field.number, field.wire, field.data, field.value)
        }
        return !reader.malformed
    }

    private static func message(_ wire: Int, _ data: ArraySlice<UInt8>?) -> ArraySlice<UInt8>? {
        wire == 2 ? data : nil
    }

    private static func string(_ wire: Int, _ data: ArraySlice<UInt8>?) -> String? {
        guard let bytes = message(wire, data) else { return nil }
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func integer(_ wire: Int, _ value: UInt64?) -> Int? {
        guard wire == 0, let value else { return nil }
        return Int(exactly: value)
    }

    static func parseTurn(_ rootBytes: [UInt8]) -> ParsedTurn? {
        var turn = ParsedTurn()
        var seconds: UInt64?
        var nanos: UInt64 = 0
        var foundChat = false
        let valid = eachField(rootBytes[...]) { number, wire, data, value in
            switch number {
            case 1:
                foundChat = true
                if let chat = message(wire, data) {
                    parseChat(chat, turn: &turn, seconds: &seconds, nanos: &nanos)
                }
            default:
                break
            }
        }
        guard valid, foundChat else { return nil }
        if let seconds, seconds > 0, seconds <= 253_402_300_799, nanos <= 999_999_999 {
            turn.timestampMs = Int64(seconds) * 1000 + Int64(nanos) / 1_000_000
        }
        return turn
    }

    private static func parseChat(
        _ bytes: ArraySlice<UInt8>, turn: inout ParsedTurn,
        seconds: inout UInt64?, nanos: inout UInt64
    ) {
        _ = eachField(bytes) { number, wire, data, value in
            switch number {
            case 4:
                var usage = turn.usage ?? ParsedUsage()
                if let body = message(wire, data) { parseUsage(body, usage: &usage) }
                turn.usage = usage
            case 9:
                if let generation = message(wire, data) {
                    parseGeneration(generation, seconds: &seconds, nanos: &nanos)
                }
            case 19:
                turn.model = string(wire, data)
            default:
                break
            }
        }
    }

    private static func parseUsage(_ bytes: ArraySlice<UInt8>, usage: inout ParsedUsage) {
        _ = eachField(bytes) { number, wire, _, value in
            guard let int = integer(wire, value) else { return }
            switch number {
            case 1: usage.systemPrompt = int
            case 2: usage.newInput = int
            case 5: usage.cacheRead = int
            case 9: usage.output = int
            case 10: usage.reasoning = int
            default: break
            }
        }
    }

    private static func parseGeneration(
        _ bytes: ArraySlice<UInt8>, seconds: inout UInt64?, nanos: inout UInt64
    ) {
        _ = eachField(bytes) { number, wire, data, _ in
            guard number == 4, let stamp = message(wire, data) else { return }
            parseTimestamp(stamp, seconds: &seconds, nanos: &nanos)
        }
    }

    private static func parseTimestamp(
        _ bytes: ArraySlice<UInt8>, seconds: inout UInt64?, nanos: inout UInt64
    ) {
        _ = eachField(bytes) { number, wire, _, value in
            guard let int = integer(wire, value), int >= 0 else { return }
            switch number {
            case 1:
                let s = UInt64(int)
                if s > 0 && s <= 253_402_300_799 { seconds = s }
            case 2:
                let n = UInt64(int)
                if n <= 999_999_999 { nanos = n }
            default: break
            }
        }
    }
}
