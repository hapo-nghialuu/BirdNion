import Foundation

/// Shared lenient JSON helpers for the local-log cost sources. Everything
/// fails soft: a drifting record shape yields nil, not a crash — the
/// scanner just counts fewer turns.
enum LocalCostParsing {

    /// Best-effort timestamp from a log record: tries ISO-8601 strings,
    /// epoch seconds and epoch milliseconds across common key names.
    static func timestamp(
        in record: [String: Any],
        keys: [String] = ["timestamp", "time", "created", "createdAt", "created_at", "startTime", "lastUpdated"],
        fallback: Date
    ) -> Date {
        for key in keys {
            if let date = parseTimestamp(record[key]) { return date }
        }
        return fallback
    }

    static func parseTimestamp(_ value: Any?) -> Date? {
        if let seconds = value as? Double {
            // Heuristic: values above 1e12 are milliseconds.
            return Date(timeIntervalSince1970: seconds > 1e12 ? seconds / 1000 : seconds)
        }
        if let int = value as? Int {
            return Date(timeIntervalSince1970: int > 1_000_000_000_000 ? Double(int) / 1000 : Double(int))
        }
        if let string = value as? String {
            if let date = isoFormatterWithFractional.date(from: string)
                ?? isoFormatter.date(from: string) {
                return date
            }
            if let seconds = Double(string) {
                return Date(timeIntervalSince1970: seconds > 1e12 ? seconds / 1000 : seconds)
            }
        }
        return nil
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

    /// Sum of every numeric field whose key contains `needle` (case-insensitive).
    static func tokenSum(_ dict: [String: Any], keyContains needle: String) -> Int {
        dict.reduce(0) { acc, pair in
            pair.key.lowercased().contains(needle) ? acc + (int(pair.value) ?? 0) : acc
        }
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
}
