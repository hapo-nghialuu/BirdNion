import Foundation

/// Regex helpers used by the Codex status probe. Ported from CodexBar's
/// `TextParsing` (the same regex set is needed to interpret the colored
/// output of `codex /status`).
enum TextParsing {
    /// Removes ANSI escape sequences so regex parsing works on colored
    /// terminal output.
    static func stripANSICodes(_ text: String) -> String {
        let pattern = #"\u{001B}\[[0-?]*[ -/]*[@-~]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }

    static func firstNumber(pattern: String, text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: text)
        else { return nil }
        return Self.parseNumber(String(text[r]))
    }

    static func firstInt(pattern: String, text: String) -> Int? {
        guard let v = firstNumber(pattern: pattern, text: text) else { return nil }
        return Int(v)
    }

    static func firstLine(matching pattern: String, text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let r = Range(match.range(at: 0), in: text)
        else { return nil }
        return String(text[r])
    }

    /// "67% left" → 67. Accepts the trailing word and any whitespace.
    static func percentLeft(fromLine line: String) -> Int? {
        firstInt(pattern: #"([0-9]{1,3})%\s+left"#, text: line)
    }

    /// "resets in 3h 12m" / "resets 12:34" → the trailing reset description.
    static func resetString(fromLine line: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"resets?\s+(.+)"#,
                                                    options: [.caseInsensitive])
        else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, options: [], range: range),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: line)
        else { return nil }
        return String(line[r]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseNumber(_ raw: String) -> Double? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: "\u{00A0}", with: "")
        text = text.replacingOccurrences(of: "\u{202F}", with: "")
        text = text.replacingOccurrences(of: " ", with: "")

        let hasComma = text.contains(",")
        let hasDot = text.contains(".")

        if hasComma, hasDot {
            if let lastComma = text.lastIndex(of: ","),
               let lastDot = text.lastIndex(of: "."),
               lastComma > lastDot
            {
                text = text.replacingOccurrences(of: ".", with: "")
                text = text.replacingOccurrences(of: ",", with: ".")
            } else {
                text = text.replacingOccurrences(of: ",", with: "")
            }
        } else if hasComma {
            if text.range(of: #"^\d{1,3}(,\d{3})+$"#, options: .regularExpression) != nil {
                text = text.replacingOccurrences(of: ",", with: "")
            } else {
                text = text.replacingOccurrences(of: ",", with: ".")
            }
        } else if hasDot,
                  text.range(of: #"^\d{1,3}(\.\d{3})+$"#, options: .regularExpression) != nil
        {
            text = text.replacingOccurrences(of: ".", with: "")
        }
        return Double(text)
    }
}
