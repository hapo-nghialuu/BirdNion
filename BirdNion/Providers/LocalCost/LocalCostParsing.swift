import Foundation
import SQLite3

/// Shared lenient JSON helpers for the local-log cost sources. Everything
/// fails soft: a drifting record shape yields nil, not a crash — the
/// scanner just counts fewer turns.
enum LocalCostParsing {

    /// Best-effort timestamp from a log record: ISO-8601 strings and epoch
    /// s/ms/µs/ns across common key names. Nil when the record has none —
    /// callers drop such turns instead of guessing a day.
    static func timestamp(
        in record: [String: Any],
        keys: [String] = ["timestamp", "time", "created", "createdAt", "created_at", "startTime", "lastUpdated"]
    ) -> Date? {
        for key in keys {
            if let date = parseTimestamp(record[key]) { return date }
        }
        return nil
    }

    static func parseTimestamp(_ value: Any?) -> Date? {
        if let seconds = value as? Double { return epochDate(seconds) }
        if let int = value as? Int { return epochDate(Double(int)) }
        if let string = value as? String {
            if let date = isoFormatterWithFractional.date(from: string)
                ?? isoFormatter.date(from: string) {
                return date
            }
            if let number = Double(string) { return epochDate(number) }
        }
        return nil
    }

    /// Epoch unit by magnitude: seconds (<1e11), milliseconds (<1e14),
    /// microseconds (<1e17), otherwise nanoseconds (OTel `timeUnixNano`).
    static func epochDate(_ value: Double) -> Date? {
        guard value > 0 else { return nil }
        let seconds: Double
        switch value {
        case ..<1e11: seconds = value
        case ..<1e14: seconds = value / 1e3
        case ..<1e17: seconds = value / 1e6
        default: seconds = value / 1e9
        }
        return Date(timeIntervalSince1970: seconds)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let isoFormatterWithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Lenient Int extraction: Int, Double (truncated), or numeric String.
    static func int(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double, d >= 0 { return Int(d) }
        if let s = value as? String, let d = Double(s) { return Int(d) }
        return nil
    }

    /// First non-empty dictionary under any of `keys`.
    static func dict(_ record: [String: Any], keys: [String]) -> [String: Any]? {
        for key in keys {
            if let dict = record[key] as? [String: Any], !dict.isEmpty { return dict }
        }
        return nil
    }

    /// Enumerate files under `root`, filtering by extension and parent-dir
    /// name, skipping files not modified since `cutoff`.
    static func files(
        under root: URL,
        extensions: Set<String>,
        parentDir: String? = nil,
        modifiedSince cutoff: Date
    ) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        var out: [URL] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                values.isRegularFile == true
            else { continue }
            guard extensions.contains(url.pathExtension.lowercased()) else { continue }
            if let parentDir, url.deletingLastPathComponent().lastPathComponent != parentDir {
                continue
            }
            if let mtime = values.contentModificationDate, mtime < cutoff {
                // Whole-file logs only gain new data when modified; files
                // untouched since the cutoff cannot contain newer turns.
                continue
            }
            out.append(url)
        }
        return out
    }

    /// Parse one JSONL file into an array of objects; malformed lines are
    /// skipped (fail soft).
    static func jsonLines(url: URL) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let d = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: d),
                  let dict = object as? [String: Any]
            else { return nil }
            return dict
        }
    }

    /// Opens a possibly live SQLite database read-only (`mode=ro`, never
    /// `immutable=1`, which would ignore a WAL the app is still writing).
    /// Nil when it can't be opened.
    static func openReadOnlyDatabase(_ url: URL) -> OpaquePointer? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "%?#")
        guard let path = url.path.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            "file:\(path)?mode=ro", &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK
        else {
            if handle != nil { sqlite3_close(handle) }
            return nil
        }
        return handle
    }
}
