#if canImport(Darwin)
import Darwin
#endif
import Foundation

// Native port of CodexBarCore's ClaudeCLISession + ClaudeStatusProbe.
// Zero dependency on CodexBarCore — Foundation + Darwin (POSIX PTY) only.
// Internal access — app module, not a library.

// MARK: - Snapshot types

/// Mirrors CodexBarCore's ClaudeStatusSnapshot + ClaudeAccountIdentity.
/// All fields are optional — missing data from the CLI renders as nil.
struct ClaudeStatusSnapshot: Sendable {
    struct Identity: Sendable {
        let accountEmail: String?
        let accountOrganization: String?
        let loginMethod: String?
    }

    let sessionPercentLeft: Int?
    let weeklyPercentLeft: Int?
    let opusPercentLeft: Int?
    let identity: Identity
    let primaryResetDescription: String?
    let secondaryResetDescription: String?
    let opusResetDescription: String?
    let rawText: String

    // Flat accessors kept for call-site convenience
    var accountEmail: String? { identity.accountEmail }
    var accountOrganization: String? { identity.accountOrganization }
    var loginMethod: String? { identity.loginMethod }
}

// MARK: - Errors

enum ClaudeStatusProbeError: LocalizedError, Sendable {
    case claudeNotInstalled
    case parseFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .claudeNotInstalled:
            return "Claude CLI is not installed or not on PATH."
        case let .parseFailed(msg):
            return "Could not parse Claude usage: \(msg)"
        case .timedOut:
            return "Claude usage probe timed out."
        }
    }
}

// MARK: - ANSI stripping

private func stripANSICodes(_ text: String) -> String {
    // CSI sequences: ESC[ ... letter. OSC sequences and bare ESC too.
    var out = ""
    out.reserveCapacity(text.count)
    var i = text.startIndex
    while i < text.endIndex {
        let c = text[i]
        if c == "\u{1B}" {
            let next = text.index(after: i)
            if next < text.endIndex {
                let nextChar = text[next]
                if nextChar == "[" {
                    // CSI: skip until letter
                    var j = text.index(after: next)
                    while j < text.endIndex, !text[j].isLetter { j = text.index(after: j) }
                    if j < text.endIndex { i = text.index(after: j); continue }
                } else if nextChar == "]" {
                    // OSC: skip until BEL or ST (ESC\)
                    var j = text.index(after: next)
                    while j < text.endIndex {
                        let ch = text[j]
                        if ch == "\u{07}" { j = text.index(after: j); break }
                        if ch == "\u{1B}" {
                            let jNext = text.index(after: j)
                            if jNext < text.endIndex, text[jNext] == "\\" {
                                j = text.index(after: jNext); break
                            }
                        }
                        j = text.index(after: j)
                    }
                    i = j; continue
                } else {
                    // Bare ESC + single char (e.g. ESC M)
                    i = text.index(after: next); continue
                }
            }
        }
        out.append(c)
        i = text.index(after: i)
    }
    return out
}

// MARK: - ClaudeStatusProbe (parsing)

/// Parses raw PTY text from `claude /usage` + `claude /status` into a snapshot.
/// All methods are static so they are testable without instantiation.
enum ClaudeStatusProbe {

    // MARK: Public entry points

    /// Parse raw PTY capture into a snapshot.
    /// - Parameters:
    ///   - text: Raw output from `claude /usage` (may contain ANSI).
    ///   - statusText: Optional raw output from `claude /status`.
    static func parse(text: String, statusText: String? = nil) throws -> ClaudeStatusSnapshot {
        let clean = stripANSICodes(text)
        let statusClean = statusText.map(stripANSICodes)
        guard !clean.isEmpty else { throw ClaudeStatusProbeError.timedOut }

        let shouldDump = ProcessInfo.processInfo.environment["DEBUG_CLAUDE_DUMP"] == "1"

        if let usageError = extractUsageError(text: clean) {
            dumpIfNeeded(enabled: shouldDump, reason: "usageError: \(usageError)", usage: clean, status: statusText)
            throw ClaudeStatusProbeError.parseFailed(usageError)
        }

        let latestUsagePanel = trimToLatestUsagePanel(clean)
        if isUsageStillLoading(text: latestUsagePanel ?? clean) {
            dumpIfNeeded(enabled: shouldDump, reason: "usage still loading", usage: clean, status: statusText)
            throw ClaudeStatusProbeError.parseFailed("Claude CLI /usage is still loading usage data.")
        }

        let usagePanelText = latestUsagePanel ?? clean
        let labelContext = LabelSearchContext(text: usagePanelText)

        var sessionPct = extractPercent(labelSubstring: "Current session", context: labelContext)
        var weeklyPct = extractPercent(labelSubstring: "Current week (all models)", context: labelContext)
        var opusPct = extractPercent(
            labelSubstrings: ["Current week (Opus)", "Current week (Sonnet only)", "Current week (Sonnet)"],
            context: labelContext)

        let compactContext = usagePanelText.lowercased().filter { !$0.isWhitespace }
        let hasWeeklyLabel = labelContext.contains("currentweek") || compactContext.contains("currentweek")
        let hasOpusLabel = labelContext.contains("opus") || labelContext.contains("sonnet")

        if sessionPct == nil || (hasWeeklyLabel && weeklyPct == nil) || (hasOpusLabel && opusPct == nil) {
            let ordered = allPercents(usagePanelText)
            if sessionPct == nil, ordered.indices.contains(0) { sessionPct = ordered[0] }
            if hasWeeklyLabel, weeklyPct == nil, ordered.indices.contains(1) { weeklyPct = ordered[1] }
            if hasOpusLabel, opusPct == nil, ordered.indices.contains(2) { opusPct = ordered[2] }
        }

        let identity = parseIdentityInternal(usageText: clean, statusText: statusClean)

        guard let sessionPct else {
            dumpIfNeeded(enabled: shouldDump, reason: "missing session label", usage: clean, status: statusText)
            if shouldDump {
                let tail = usagePanelText.suffix(1800)
                let snippet = tail.isEmpty ? "(empty)" : String(tail)
                throw ClaudeStatusProbeError.parseFailed(
                    "Missing Current session.\n\n--- Clean usage tail ---\n\(snippet)")
            }
            throw ClaudeStatusProbeError.parseFailed("Missing Current session.")
        }

        let sessionReset = extractReset(labelSubstring: "Current session", context: labelContext)
        let weeklyReset = hasWeeklyLabel
            ? extractReset(labelSubstring: "Current week (all models)", context: labelContext)
            : nil
        let opusReset = hasOpusLabel
            ? extractReset(
                labelSubstrings: ["Current week (Opus)", "Current week (Sonnet only)", "Current week (Sonnet)"],
                context: labelContext)
            : nil

        return ClaudeStatusSnapshot(
            sessionPercentLeft: sessionPct,
            weeklyPercentLeft: weeklyPct,
            opusPercentLeft: opusPct,
            identity: identity,
            primaryResetDescription: sessionReset,
            secondaryResetDescription: weeklyReset,
            opusResetDescription: opusReset,
            rawText: text + (statusText ?? ""))
    }

    /// Extracts identity from raw usage + status text (with ANSI stripping).
    static func parseIdentity(usageText: String?, statusText: String?) -> ClaudeStatusSnapshot.Identity {
        let usageClean = usageText.map(stripANSICodes) ?? ""
        let statusClean = statusText.map(stripANSICodes)
        return extractIdentity(usageText: usageClean, statusText: statusClean)
    }

    /// Parses a reset description string into a Date, if possible.
    static func parseResetDate(from text: String?, now: Date = Date()) -> Date? {
        guard let normalized = normalizeResetInput(text) else { return nil }
        let (raw, timeZone) = normalized

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone ?? TimeZone.current
        formatter.defaultDate = now
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = formatter.timeZone

        if let date = parseDate(raw, formats: resetDateTimeWithMinutes, formatter: formatter) {
            var comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            comps.second = 0
            return calendar.date(from: comps)
        }
        if let date = parseDate(raw, formats: resetDateTimeHourOnly, formatter: formatter) {
            var comps = calendar.dateComponents([.year, .month, .day, .hour], from: date)
            comps.minute = 0; comps.second = 0
            return calendar.date(from: comps)
        }
        if let time = parseDate(raw, formats: resetTimeWithMinutes, formatter: formatter) {
            let comps = calendar.dateComponents([.hour, .minute], from: time)
            guard let anchored = calendar.date(
                bySettingHour: comps.hour ?? 0, minute: comps.minute ?? 0, second: 0, of: now)
            else { return nil }
            if anchored >= now { return anchored }
            return calendar.date(byAdding: .day, value: 1, to: anchored)
        }
        guard let time = parseDate(raw, formats: resetTimeHourOnly, formatter: formatter) else { return nil }
        let comps = calendar.dateComponents([.hour], from: time)
        guard let anchored = calendar.date(
            bySettingHour: comps.hour ?? 0, minute: 0, second: 0, of: now)
        else { return nil }
        if anchored >= now { return anchored }
        return calendar.date(byAdding: .day, value: 1, to: anchored)
    }

    // MARK: - Label search context

    private struct LabelSearchContext {
        let lines: [String]
        let normalizedLines: [String]
        let normalizedData: Data

        init(text: String) {
            self.lines = text.components(separatedBy: .newlines)
            self.normalizedLines = self.lines.map { ClaudeStatusProbe.normalizedForLabelSearch($0) }
            let normalized = ClaudeStatusProbe.normalizedForLabelSearch(text)
            self.normalizedData = Data(normalized.utf8)
        }

        func contains(_ needle: String) -> Bool {
            self.normalizedData.range(of: Data(needle.utf8)) != nil
        }
    }

    // MARK: - Percent extraction

    private static func extractPercent(labelSubstring: String, context: LabelSearchContext) -> Int? {
        let label = normalizedForLabelSearch(labelSubstring)
        for (idx, normalizedLine) in context.normalizedLines.enumerated() where normalizedLine.contains(label) {
            let window = context.lines.dropFirst(idx).prefix(12)
            for candidate in window {
                if let pct = percentFromLine(candidate) { return pct }
            }
        }
        return nil
    }

    private static func extractPercent(labelSubstrings: [String], context: LabelSearchContext) -> Int? {
        for label in labelSubstrings {
            if let value = extractPercent(labelSubstring: label, context: context) { return value }
        }
        return nil
    }

    private static func percentFromLine(_ line: String, assumeRemainingWhenUnclear: Bool = false) -> Int? {
        if isLikelyStatusContextLine(line) { return nil }
        let pattern = #"([0-9]{1,3}(?:\.[0-9]+)?)\p{Zs}*%"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, options: [], range: range),
              match.numberOfRanges >= 2,
              let valRange = Range(match.range(at: 1), in: line)
        else { return nil }
        let rawVal = Double(line[valRange]) ?? 0
        let clamped = max(0, min(100, rawVal))
        let lower = line.lowercased()
        if ["used", "spent", "consumed"].contains(where: lower.contains) {
            return Int(max(0, min(100, 100 - clamped)).rounded())
        }
        if ["left", "remaining", "available"].contains(where: lower.contains) {
            return Int(clamped.rounded())
        }
        return assumeRemainingWhenUnclear ? Int(clamped.rounded()) : nil
    }

    private static func isLikelyStatusContextLine(_ line: String) -> Bool {
        guard line.contains("|") else { return false }
        let lower = line.lowercased()
        return ["opus", "sonnet", "haiku", "default"].contains(where: lower.contains)
    }

    private static func allPercents(_ text: String) -> [Int] {
        let lines = text.components(separatedBy: .newlines)
        let normalized = text.lowercased().filter { !$0.isWhitespace }
        let hasUsageWindows = normalized.contains("currentsession") || normalized.contains("currentweek")
        let hasLoading = normalized.contains("loadingusage")
        let hasUsagePercentKeywords = normalized.contains("used") || normalized.contains("left")
            || normalized.contains("remaining") || normalized.contains("available")
        let loadingOnly = hasLoading && !hasUsageWindows
        guard hasUsageWindows || hasLoading else { return [] }
        if loadingOnly { return [] }
        guard hasUsagePercentKeywords else { return [] }
        return lines.compactMap { percentFromLine($0, assumeRemainingWhenUnclear: false) }
    }

    // MARK: - Panel trimming / loading checks

    private static func trimToLatestUsagePanel(_ text: String) -> String? {
        guard let settingsRange = text.range(of: "Settings:", options: [.caseInsensitive, .backwards]) else {
            return nil
        }
        let tail = text[settingsRange.lowerBound...]
        guard tail.range(of: "Usage", options: .caseInsensitive) != nil else { return nil }
        let lower = tail.lowercased()
        let hasPercent = lower.contains("%")
        let hasUsageWords = lower.contains("used") || lower.contains("left")
            || lower.contains("remaining") || lower.contains("available")
        let hasLoading = lower.contains("loading usage")
        guard (hasPercent && hasUsageWords) || hasLoading else { return nil }
        return String(tail)
    }

    private static func isUsageStillLoading(text: String) -> Bool {
        let normalized = stripANSICodes(text).lowercased().filter { !$0.isWhitespace }
        guard normalized.contains("loadingusage") else { return false }
        return !usageCaptureHasSessionValue(normalized) && allPercents(text).isEmpty
    }

    private static func isSubscriptionNoticeOnly(text: String) -> Bool {
        let normalized = text.lowercased().filter { !$0.isWhitespace }
        guard normalized.contains("currentlyusingyoursubscription") else { return false }
        guard normalized.contains("claudecodeusage") else { return false }
        let hasQuotaData = normalized.contains("currentsession") || normalized.contains("currentweek")
            || normalized.contains("%used") || normalized.contains("%left")
            || normalized.contains("%remaining") || normalized.contains("%available")
        return !hasQuotaData
    }

    static func usageCaptureHasSessionValue(_ normalizedText: String) -> Bool {
        guard let labelRange = normalizedText.range(of: "currentsession") else { return false }
        let tail = normalizedText[labelRange.upperBound...]
        return tail.range(of: #"[0-9]{1,3}(?:\.[0-9]+)?%"#, options: .regularExpression) != nil
    }

    static func usageCaptureHasSubscriptionNotice(_ normalizedText: String) -> Bool {
        normalizedText.contains("currentlyusingyoursubscription") && normalizedText.contains("claudecodeusage")
    }

    static func usageOutputLooksRelevant(_ text: String) -> Bool {
        let normalized = stripANSICodes(text).lowercased().filter { !$0.isWhitespace }
        return normalized.contains("currentsession")
            || normalized.contains("currentweek")
            || normalized.contains("loadingusage")
            || normalized.contains("failedtoloadusagedata")
            || usageCaptureHasSubscriptionNotice(normalized)
    }

    // MARK: - Error extraction

    private static func extractUsageError(text: String) -> String? {
        if let jsonHint = extractUsageErrorJSON(text: text) { return jsonHint }

        let lower = text.lowercased()
        let compact = lower.filter { !$0.isWhitespace }
        if lower.contains("do you trust the files in this folder?"), !lower.contains("current session") {
            let folder = extractFirst(
                pattern: #"Do you trust the files in this folder\?\s*(?:\r?\n)+\s*([^\r\n]+)"#,
                text: text)
            let folderHint = folder.flatMap { value -> String? in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            if let folderHint {
                return "Claude CLI is waiting for a folder trust prompt (\(folderHint)). BirdNion tries to auto-accept this, but if it keeps appearing run: `cd \"\(folderHint)\" && claude` and choose \"Yes, proceed\", then retry."
            }
            return "Claude CLI is waiting for a folder trust prompt. BirdNion tries to auto-accept this, but if it keeps appearing open `claude` once, choose \"Yes, proceed\", then retry."
        }
        if lower.contains("token_expired") || lower.contains("token has expired") {
            return "Claude CLI token expired. Run `claude login` to refresh."
        }
        if lower.contains("authentication_error") {
            return "Claude CLI authentication error. Run `claude login`."
        }
        if lower.contains("rate_limit_error") || lower.contains("rate limited") || compact.contains("ratelimited") {
            return "Claude CLI usage endpoint is rate limited right now. Please try again later."
        }
        if isSubscriptionNoticeOnly(text: text) {
            return "Claude CLI /usage returned a subscription notice without session quota data."
        }
        if lower.contains("failed to load usage data") || compact.contains("failedtoloadusagedata") {
            return "Claude CLI could not load usage data. Open the CLI and retry `/usage`."
        }
        return nil
    }

    private static func extractUsageErrorJSON(text: String) -> String? {
        let pattern = #"Failed\s*to\s*load\s*usage\s*data:\s*(\{.*\})"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 2,
              let jsonRange = Range(match.range(at: 1), in: text)
        else { return nil }

        let jsonString = String(text[jsonRange])
        let compactJSON = jsonString.replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        let data = (compactJSON.isEmpty ? jsonString : compactJSON).data(using: .utf8)
        guard let data,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = payload["error"] as? [String: Any]
        else { return nil }

        let message = (error["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let details = error["details"] as? [String: Any]
        let code = (details?["error_code"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let type = (error["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if type == "rate_limit_error" {
            return "Claude CLI usage endpoint is rate limited right now. Please try again later."
        }
        var parts: [String] = []
        if let message, !message.isEmpty { parts.append(message) }
        if let code, !code.isEmpty { parts.append("(\(code))") }
        guard !parts.isEmpty else { return nil }
        let hint = parts.joined(separator: " ")
        if let code, code.lowercased().contains("token") {
            return "\(hint). Run `claude login` to refresh."
        }
        return "Claude CLI error: \(hint)"
    }

    // MARK: - Reset extraction

    private static func extractReset(labelSubstring: String, context: LabelSearchContext) -> String? {
        let label = normalizedForLabelSearch(labelSubstring)
        for (idx, normalizedLine) in context.normalizedLines.enumerated() where normalizedLine.contains(label) {
            let window = context.lines.dropFirst(idx).prefix(14)
            for candidate in window {
                let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalized = normalizedForLabelSearch(trimmed)
                if normalized.hasPrefix("current"), !normalized.contains(label) { break }
                if let reset = resetFromLine(candidate) { return reset }
            }
        }
        return nil
    }

    private static func extractReset(labelSubstrings: [String], context: LabelSearchContext) -> String? {
        for label in labelSubstrings {
            if let value = extractReset(labelSubstring: label, context: context) { return value }
        }
        return nil
    }

    private static func resetFromLine(_ line: String) -> String? {
        guard let range = line.range(of: "Resets", options: [.caseInsensitive]) else { return nil }
        let raw = String(line[range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanResetLine(raw)
    }

    private static func cleanResetLine(_ raw: String) -> String {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: " )"))
        let openCount = cleaned.filter { $0 == "(" }.count
        let closeCount = cleaned.filter { $0 == ")" }.count
        if openCount > closeCount { cleaned.append(")") }
        return cleaned
    }

    // MARK: - Identity extraction

    private static func parseIdentityInternal(usageText: String, statusText: String?) -> ClaudeStatusSnapshot.Identity {
        extractIdentity(usageText: usageText, statusText: statusText)
    }

    private static func extractIdentity(usageText: String, statusText: String?) -> ClaudeStatusSnapshot.Identity {
        let emailPatterns = [
            #"(?i)Account:\s+([^\s@]+@[^\s@]+)"#,
            #"(?i)Email:\s+([^\s@]+@[^\s@]+)"#,
        ]
        let looseEmailPatterns = [
            #"(?i)Account:\s+(\S+)"#,
            #"(?i)Email:\s+(\S+)"#,
        ]
        let email = emailPatterns.compactMap { extractFirst(pattern: $0, text: usageText) }.first
            ?? emailPatterns.compactMap { extractFirst(pattern: $0, text: statusText ?? "") }.first
            ?? looseEmailPatterns.compactMap { extractFirst(pattern: $0, text: usageText) }.first
            ?? looseEmailPatterns.compactMap { extractFirst(pattern: $0, text: statusText ?? "") }.first
            ?? extractFirst(pattern: #"(?i)[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, text: usageText)
            ?? extractFirst(pattern: #"(?i)[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, text: statusText ?? "")

        let orgPatterns = [
            #"(?i)Org:\s*(.+)"#,
            #"(?i)Organization:\s*(.+)"#,
        ]
        let orgRaw = orgPatterns.compactMap { extractFirst(pattern: $0, text: usageText) }.first
            ?? orgPatterns.compactMap { extractFirst(pattern: $0, text: statusText ?? "") }.first
        let org: String? = {
            guard let orgText = orgRaw?.trimmingCharacters(in: .whitespacesAndNewlines), !orgText.isEmpty else {
                return nil
            }
            if let email, orgText.lowercased().hasPrefix(email.lowercased()) { return nil }
            return orgText
        }()

        let login = extractLoginMethod(text: statusText ?? "") ?? extractLoginMethod(text: usageText)
        return ClaudeStatusSnapshot.Identity(accountEmail: email, accountOrganization: org, loginMethod: login)
    }

    private static func extractLoginMethod(text: String) -> String? {
        guard !text.isEmpty else { return nil }
        if let explicit = extractFirst(pattern: #"(?i)login\s+method:\s*(.+)"#, text: text) {
            return cleanPlan(explicit)
        }
        // Match "Claude <plan>" phrases (Max/Pro/Ultra/Team etc.) using horizontal whitespace only
        // to avoid bridging lines after ANSI stripping.
        let planPattern = #"(?i)(claude[ \t]+[a-z0-9][a-z0-9 \t._-]{0,24})"#
        var candidates: [String] = []
        if let regex = try? NSRegularExpression(pattern: planPattern, options: []) {
            let nsrange = NSRange(text.startIndex..<text.endIndex, in: text)
            regex.enumerateMatches(in: text, options: [], range: nsrange) { match, _, _ in
                guard let match, match.numberOfRanges >= 2,
                      let r = Range(match.range(at: 1), in: text) else { return }
                candidates.append(cleanPlan(String(text[r])))
            }
        }
        return candidates.first(where: { cand in
            let lower = cand.lowercased()
            return !lower.contains("code v") && !lower.contains("code version") && !lower.contains("code")
        })
    }

    private static func cleanPlan(_ text: String) -> String {
        // Strip stray bracketed ANSI remnants like "[22m" that survive CLI output.
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let regex = try? NSRegularExpression(pattern: #"\[[\d;]*[a-zA-Z]"#) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..<result.endIndex, in: result),
                withTemplate: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Date parsing

    private static let resetTimeWithMinutes = ["h:mma", "h:mm a", "HH:mm", "H:mm"]
    private static let resetTimeHourOnly = ["ha", "h a"]
    private static let resetDateTimeWithMinutes = [
        "MMM d, h:mma", "MMM d, h:mm a", "MMM d h:mma", "MMM d h:mm a",
        "MMM d, HH:mm", "MMM d HH:mm",
    ]
    private static let resetDateTimeHourOnly = [
        "MMM d, ha", "MMM d, h a", "MMM d ha", "MMM d h a",
    ]

    private static func normalizeResetInput(_ text: String?) -> (String, TimeZone?)? {
        guard var raw = text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        raw = raw.replacingOccurrences(of: #"(?i)^resets?:?\s*"#, with: "", options: .regularExpression)
        raw = raw.replacingOccurrences(of: " at ", with: " ", options: .caseInsensitive)
        raw = raw.replacingOccurrences(of: #"(?i)\b([A-Za-z]{3})(\d)"#, with: "$1 $2", options: .regularExpression)
        raw = raw.replacingOccurrences(of: #",(\d)"#, with: ", $1", options: .regularExpression)
        raw = raw.replacingOccurrences(of: #"(?i)(\d)at(?=\d)"#, with: "$1 ", options: .regularExpression)
        raw = raw.replacingOccurrences(of: #"(?<=\d)\.(\d{2})\b"#, with: ":$1", options: .regularExpression)
        let timeZone = extractTimeZone(from: &raw)
        raw = raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : (raw, timeZone)
    }

    private static func extractTimeZone(from text: inout String) -> TimeZone? {
        guard let tzRange = text.range(of: #"\(([^)]+)\)"#, options: .regularExpression) else { return nil }
        let tzID = String(text[tzRange]).trimmingCharacters(in: CharacterSet(charactersIn: "() "))
        text.removeSubrange(tzRange)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return TimeZone(identifier: tzID)
    }

    private static func parseDate(_ text: String, formats: [String], formatter: DateFormatter) -> Date? {
        for pattern in formats {
            formatter.dateFormat = pattern
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    // MARK: - Generic regex helper

    private static func extractFirst(pattern: String, text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Label normalization

    private static func normalizedForLabelSearch(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }

    // MARK: - Debug dump (in-memory ring buffer, 5 entries)

    @MainActor private static var recentDumps: [String] = []

    @MainActor private static func recordDump(_ text: String) {
        if recentDumps.count >= 5 { recentDumps.removeFirst() }
        recentDumps.append(text)
    }

    static func latestDumps() async -> String {
        await MainActor.run {
            let result = recentDumps.joined(separator: "\n\n---\n\n")
            return result.isEmpty ? "No Claude parse dumps captured yet." : result
        }
    }

    private static func dumpIfNeeded(enabled: Bool, reason: String, usage: String, status: String?) {
        guard enabled else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        var parts = [
            "=== Claude parse dump @ \(stamp) ===",
            "Reason: \(reason)", "",
            "--- usage (clean) ---", usage, "",
        ]
        if let status { parts += ["--- status (raw/optional) ---", status, ""] }
        let body = parts.joined(separator: "\n")
        Task { @MainActor in recordDump(body) }
    }

    #if DEBUG
    static func replaceDumpsForTesting(_ dumps: [String]) async {
        await MainActor.run { recentDumps = dumps }
    }
    #endif
}

// MARK: - ClaudeCLISession (PTY spawn + capture)

/// Spawns `claude` inside a POSIX pseudo-terminal, sends a slash-command, and
/// captures the rendered TUI text. Uses Foundation Process + Darwin forkpty
/// (via `openpty`). No CodexBarCore dependency.
actor ClaudeCLISession {

    // MARK: Shared instance + DEBUG isolation

    static let shared = ClaudeCLISession()

    #if DEBUG
    @TaskLocal private static var sessionOverrideForTesting: ClaudeCLISession?

    static var current: ClaudeCLISession { sessionOverrideForTesting ?? shared }

    static func withIsolatedSessionForTesting<T>(operation: () async throws -> T) async rethrows -> T {
        let session = ClaudeCLISession()
        defer { Task { await session.reset() } }
        return try await $sessionOverrideForTesting.withValue(session) {
            try await operation()
        }
    }
    #else
    static var current: ClaudeCLISession { shared }
    #endif

    // MARK: Errors

    enum SessionError: LocalizedError {
        case launchFailed(String)
        case ioFailed(String)
        case timedOut
        case processExited

        var errorDescription: String? {
            switch self {
            case let .launchFailed(msg): return "Failed to launch Claude CLI session: \(msg)"
            case let .ioFailed(msg): return "Claude CLI PTY I/O failed: \(msg)"
            case .timedOut: return "Claude CLI session timed out."
            case .processExited: return "Claude CLI session exited."
            }
        }
    }

    // MARK: State

    private var process: Process?
    private var primaryFD: Int32 = -1
    private var primaryHandle: FileHandle?
    private var secondaryHandle: FileHandle?
    private var processGroup: pid_t?
    private var binaryPath: String?
    private var startedAt: Date?

    // Auto-accept interactive prompts that Claude may show on startup
    private let promptSends: [String: String] = [
        "Do you trust the files in this folder?": "y\r",
        "Quick safety check:": "\r",
        "Yes, I trust this folder": "\r",
        "Ready to code here?": "\r",
        "Press Enter to continue": "\r",
    ]

    // MARK: Rolling scan buffer

    private struct RollingBuffer {
        private let maxNeedle: Int
        private var tail = Data()

        init(maxNeedle: Int) { self.maxNeedle = max(0, maxNeedle) }

        mutating func append(_ data: Data) -> Data {
            guard !data.isEmpty else { return Data() }
            var combined = Data()
            combined.reserveCapacity(tail.count + data.count)
            combined.append(tail)
            combined.append(data)
            if maxNeedle > 1 {
                tail = combined.count >= maxNeedle - 1 ? combined.suffix(maxNeedle - 1) : combined
            } else {
                tail.removeAll(keepingCapacity: true)
            }
            return combined
        }
    }

    // MARK: - High-level API

    /// Resolves the binary, spawns a PTY session, sends `/usage` (and optionally
    /// `/status`), parses, and returns a `ClaudeStatusSnapshot`.
    static func loadSnapshot(timeout: TimeInterval = 20.0) async throws -> ClaudeStatusSnapshot {
        guard let binary = ClaudeCLIResolver.resolvedBinaryPath(),
              FileManager.default.isExecutableFile(atPath: binary)
        else {
            throw ClaudeStatusProbeError.claudeNotInstalled
        }
        return try await loadSnapshot(binary: binary, timeout: timeout)
    }

    /// `timeout` is the TOTAL budget for the whole probe (usage + retry +
    /// status), mirroring CodexBar's ClaudeStatusProbe semantics — previously
    /// it applied per capture, so a "12s" auto probe could legally burn ~38s.
    /// The PTY session is always torn down afterwards (success or failure):
    /// a kept-alive `claude` TUI burns CPU nonstop and, once wedged, makes
    /// every subsequent capture fail until app restart.
    static func loadSnapshot(binary: String, timeout: TimeInterval = 20.0) async throws -> ClaudeStatusSnapshot {
        do {
            let snapshot = try await runProbe(binary: binary, timeout: timeout)
            await current.reset()
            return snapshot
        } catch {
            await current.reset()
            throw error
        }
    }

    private static func runProbe(binary: String, timeout: TimeInterval) async throws -> ClaudeStatusSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        var usageText = try await captureUsageText(binary: binary, timeout: timeout)
        if !ClaudeStatusProbe.usageOutputLooksRelevant(usageText) {
            // Retry once with the remaining budget — the TUI may not have been
            // fully initialised. No budget left → treat as a probe timeout so
            // the orchestrator's retry (fresh session) takes over.
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 2 else { throw ClaudeStatusProbeError.timedOut }
            usageText = try await captureUsageText(binary: binary, timeout: remaining)
        }
        // Status capture (account email / login method) is best-effort and
        // never exceeds what's left of the budget.
        let statusBudget = min(deadline.timeIntervalSinceNow, 12)
        let statusText = statusBudget > 2
            ? try? await captureStatusText(binary: binary, timeout: statusBudget)
            : nil
        return try ClaudeStatusProbe.parse(text: usageText, statusText: statusText)
    }

    /// Spawns `claude` in a PTY, sends `/usage`, and returns the raw captured text.
    static func captureUsageText(binary: String, timeout: TimeInterval) async throws -> String {
        let stopWhenNormalized: (@Sendable (String) -> Bool) = { normalizedScan in
            ClaudeStatusProbe.usageCaptureHasSessionValue(normalizedScan)
                || ClaudeStatusProbe.usageCaptureHasSubscriptionNotice(normalizedScan)
        }
        return try await current.capture(
            subcommand: "/usage",
            binary: binary,
            timeout: timeout,
            idleTimeout: nil,
            stopOnSubstrings: [
                "Failed to load usage data",
                "failed to load usage data",
                "Failedto loadusagedata",
                "failedtoloadusagedata",
            ],
            stopWhenNormalized: stopWhenNormalized,
            settleAfterStop: 2.0,
            sendEnterEvery: 0.8)
    }

    /// Spawns `claude` in a PTY, sends `/status`, and returns the raw captured text.
    static func captureStatusText(binary: String, timeout: TimeInterval) async throws -> String {
        try await current.capture(
            subcommand: "/status",
            binary: binary,
            timeout: timeout,
            idleTimeout: 3.0,
            stopOnSubstrings: [],
            stopWhenNormalized: nil,
            settleAfterStop: 0.25,
            sendEnterEvery: nil)
    }

    // MARK: - Direct (non-PTY) fallback

    /// Runs `claude /usage` as a plain subprocess (stdin = /dev/null, no PTY)
    /// and parses stdout. Fallback for when the PTY probe times out or can't
    /// render the usage panel — mirrors CodexBar's `loadViaDirectCLI`.
    static func loadSnapshotDirect(timeout: TimeInterval) async throws -> ClaudeStatusSnapshot {
        guard let binary = ClaudeCLIResolver.resolvedBinaryPath(),
              FileManager.default.isExecutableFile(atPath: binary)
        else {
            throw ClaudeStatusProbeError.claudeNotInstalled
        }
        let text = try await runDirectUsageProcess(binary: binary, timeout: timeout)
        return try ClaudeStatusProbe.parse(text: text, statusText: nil)
    }

    private static func runDirectUsageProcess(binary: String,
                                              timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    try runDirectUsageProcessSync(binary: binary, timeout: timeout)
                })
            }
        }
    }

    /// Blocking subprocess run with a wall-clock timeout. Output is streamed
    /// into a locked buffer via `readabilityHandler` so a chatty CLI can't
    /// deadlock the 64KB pipe buffer while we wait for exit.
    private static func runDirectUsageProcessSync(binary: String,
                                                  timeout: TimeInterval) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = ["/usage"]
        proc.environment = launchEnvironment()
        proc.currentDirectoryURL = preparedProbeWorkingDirectoryURL()
        proc.standardInput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        let outPipe = Pipe()
        proc.standardOutput = outPipe
        let buffer = DirectRunOutputBuffer()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            buffer.append(chunk)
        }
        defer { outPipe.fileHandleForReading.readabilityHandler = nil }

        do {
            try proc.run()
        } catch {
            throw ClaudeStatusProbeError.parseFailed(
                "direct claude /usage launch failed: \(error.localizedDescription)")
        }
        let exited = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in exited.signal() }
        guard exited.wait(timeout: .now() + timeout) == .success else {
            proc.terminate()
            throw ClaudeStatusProbeError.timedOut
        }
        // Drain any bytes still buffered after exit.
        buffer.append(outPipe.fileHandleForReading.readDataToEndOfFile())
        let data = buffer.snapshot()
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) else {
            throw ClaudeStatusProbeError.parseFailed("direct claude /usage produced no decodable output")
        }
        return text
    }

    /// Lock-guarded accumulator for the direct-run readability handler, which
    /// fires on a background queue while the spawning thread waits for exit.
    private final class DirectRunOutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        func snapshot() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    // MARK: - Core capture loop

    func capture(
        subcommand: String,
        binary: String,
        timeout: TimeInterval,
        idleTimeout: TimeInterval?,
        stopOnSubstrings: [String],
        stopWhenNormalized: (@Sendable (String) -> Bool)?,
        settleAfterStop: TimeInterval,
        sendEnterEvery: TimeInterval?
    ) async throws -> String {
        try ensureStarted(binary: binary)

        // Wait for the TUI to initialise before sending the slash command
        if let startedAt {
            let sinceStart = Date().timeIntervalSince(startedAt)
            if sinceStart < 2.0 {
                let delay = UInt64((2.0 - sinceStart) * 1_000_000_000)
                try await Task.sleep(nanoseconds: delay)
            }
        }
        drainOutput()

        let trimmed = subcommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            try send(trimmed)
            try send("\r")
        }

        let stopNeedles = stopOnSubstrings.map { normalizedNeedle($0) }
        var sendMap = promptSends
        for (needle, keys) in commandPaletteSends(for: trimmed) { sendMap[needle] = keys }
        let sendNeedles = sendMap.map { (needle: normalizedNeedle($0.key), keys: $0.value) }

        let cursorQuery = Data([0x1B, 0x5B, 0x36, 0x6E])
        let maxNeedle = (stopOnSubstrings.map(\.utf8.count) + sendMap.keys.map(\.utf8.count) + [cursorQuery.count])
            .max() ?? cursorQuery.count
        var scanBuffer = RollingBuffer(maxNeedle: maxNeedle)
        var triggeredSends = Set<String>()

        var buffer = Data()
        var scanTailText = ""
        var normalizedScan = ""
        var utf8Carry = Data()
        let deadline = Date().addingTimeInterval(timeout)
        var lastOutputAt = Date()
        var lastEnterAt = Date()
        var stoppedEarly = false

        while Date() < deadline {
            let newData = readChunk()
            if !newData.isEmpty {
                buffer.append(newData)
                lastOutputAt = Date()
                Self.appendScanText(newData: newData, scanTailText: &scanTailText, utf8Carry: &utf8Carry)
                if scanTailText.count > 8192 { scanTailText = String(scanTailText.suffix(8192)) }
                normalizedScan = normalizedNeedle(stripANSICodes(scanTailText))

                let scanData = scanBuffer.append(newData)
                if scanData.range(of: cursorQuery) != nil { try? send("\u{1b}[1;1R") }

                for item in sendNeedles where !triggeredSends.contains(item.needle) {
                    if normalizedScan.contains(item.needle) {
                        try? send(item.keys)
                        triggeredSends.insert(item.needle)
                    }
                }

                if stopNeedles.contains(where: normalizedScan.contains)
                    || (stopWhenNormalized?(normalizedScan) == true)
                {
                    stoppedEarly = true
                    break
                }
            }

            if shouldStopForIdleTimeout(idleTimeout: idleTimeout, bufferIsEmpty: buffer.isEmpty, lastOutputAt: lastOutputAt) {
                stoppedEarly = true
                break
            }

            sendPeriodicEnterIfNeeded(every: sendEnterEvery, lastEnterAt: &lastEnterAt)

            if let proc = process, !proc.isRunning { throw SessionError.processExited }

            try await Task.sleep(nanoseconds: 60_000_000)
        }

        if stoppedEarly {
            let settle = max(0, min(settleAfterStop, deadline.timeIntervalSinceNow))
            if settle > 0 {
                let settleDeadline = Date().addingTimeInterval(settle)
                while Date() < settleDeadline {
                    let newData = readChunk()
                    if !newData.isEmpty { buffer.append(newData) }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
            }
        }

        guard !buffer.isEmpty, let text = String(data: buffer, encoding: .utf8) else {
            throw SessionError.timedOut
        }
        return text
    }

    // MARK: - Session lifecycle

    func reset() { cleanup() }

    // MARK: - PTY launch

    private func ensureStarted(binary: String) throws {
        if let proc = process, proc.isRunning, binaryPath == binary { return }
        cleanup()

        var pFD: Int32 = -1
        var sFD: Int32 = -1
        var win = winsize(ws_row: 50, ws_col: 160, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&pFD, &sFD, nil, nil, &win) == 0 else {
            throw SessionError.launchFailed("openpty failed: \(String(cString: strerror(errno)))")
        }
        _ = fcntl(pFD, F_SETFL, O_NONBLOCK)

        let pHandle = FileHandle(fileDescriptor: pFD, closeOnDealloc: true)
        let sHandle = FileHandle(fileDescriptor: sFD, closeOnDealloc: true)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        // --allowed-tools "" prevents Claude from registering tool sidecars that
        // produce extra output and can interfere with our capture.
        proc.arguments = ["--allowed-tools", ""]
        proc.standardInput = sHandle
        proc.standardOutput = sHandle
        proc.standardError = sHandle

        // Run inside a dedicated working directory with deeplink-registration
        // suppressed, mirroring CodexBar's probe isolation strategy.
        let workDir = Self.preparedProbeWorkingDirectoryURL()
        proc.currentDirectoryURL = workDir
        var env = Self.launchEnvironment()
        env["PWD"] = workDir.path
        proc.environment = env

        do {
            try proc.run()
        } catch {
            try? pHandle.close()
            try? sHandle.close()
            throw SessionError.launchFailed(error.localizedDescription)
        }

        let pid = proc.processIdentifier
        var pg: pid_t?
        if setpgid(pid, pid) == 0 { pg = pid }

        process = proc
        primaryFD = pFD
        primaryHandle = pHandle
        secondaryHandle = sHandle
        processGroup = pg
        binaryPath = binary
        startedAt = Date()
    }

    // MARK: - Cleanup / termination

    private func cleanup() {
        if let proc = process, proc.isRunning {
            try? writeAllToPrimary(Data("/exit\r".utf8))
        }
        try? primaryHandle?.close()
        try? secondaryHandle?.close()

        // Collect descendants before closing handles, then terminate the tree.
        let descendants = process.map { Self.descendantPIDs(of: $0.processIdentifier) } ?? []
        if let proc = process, proc.isRunning { proc.terminate() }
        if let proc = process {
            terminateProcessTree(
                rootPID: proc.processIdentifier,
                processGroup: processGroup,
                signal: SIGTERM,
                knownDescendants: descendants)
            // Give it 1 second to exit cleanly before SIGKILL
            let waitDeadline = Date().addingTimeInterval(1.0)
            while proc.isRunning, Date() < waitDeadline { usleep(100_000) }
            if proc.isRunning {
                terminateProcessTree(
                    rootPID: proc.processIdentifier,
                    processGroup: processGroup,
                    signal: SIGKILL,
                    knownDescendants: descendants)
            } else {
                for pid in descendants where pid > 0 { kill(pid, SIGKILL) }
            }
        }

        process = nil
        primaryHandle = nil
        secondaryHandle = nil
        primaryFD = -1
        processGroup = nil
        startedAt = nil
    }

    // MARK: - I/O helpers

    private func readChunk() -> Data {
        guard primaryFD >= 0 else { return Data() }
        var appended = Data()
        while true {
            var tmp = [UInt8](repeating: 0, count: 8192)
            let n = read(primaryFD, &tmp, tmp.count)
            if n > 0 { appended.append(contentsOf: tmp.prefix(n)); continue }
            break
        }
        return appended
    }

    private func drainOutput() { _ = readChunk() }

    private func shouldStopForIdleTimeout(idleTimeout: TimeInterval?, bufferIsEmpty: Bool, lastOutputAt: Date) -> Bool {
        guard let idleTimeout, !bufferIsEmpty else { return false }
        return Date().timeIntervalSince(lastOutputAt) >= idleTimeout
    }

    private func sendPeriodicEnterIfNeeded(every: TimeInterval?, lastEnterAt: inout Date) {
        guard let every, Date().timeIntervalSince(lastEnterAt) >= every else { return }
        try? send("\r")
        lastEnterAt = Date()
    }

    private func send(_ text: String) throws {
        guard let data = text.data(using: .utf8) else { return }
        guard primaryFD >= 0 else { throw SessionError.processExited }
        try writeAllToPrimary(data)
    }

    private func writeAllToPrimary(_ data: Data) throws {
        guard primaryFD >= 0 else { throw SessionError.processExited }
        try data.withUnsafeBytes { rawBytes in
            guard let base = rawBytes.baseAddress else { return }
            var offset = 0
            var retries = 0
            while offset < rawBytes.count {
                let written = write(primaryFD, base.advanced(by: offset), rawBytes.count - offset)
                if written > 0 { offset += written; retries = 0; continue }
                if written == 0 { break }
                let err = errno
                if err == EINTR || err == EAGAIN || err == EWOULDBLOCK {
                    retries += 1
                    if retries > 200 { throw SessionError.ioFailed("write to PTY would block") }
                    usleep(5000)
                    continue
                }
                throw SessionError.ioFailed("write to PTY failed: \(String(cString: strerror(err)))")
            }
        }
    }

    // MARK: - Scan text accumulator (handles split UTF-8 at PTY chunk boundaries)

    private static func appendScanText(newData: Data, scanTailText: inout String, utf8Carry: inout Data) {
        var combined = Data()
        combined.reserveCapacity(utf8Carry.count + newData.count)
        combined.append(utf8Carry)
        combined.append(newData)

        if let chunk = String(data: combined, encoding: .utf8) {
            scanTailText.append(chunk)
            utf8Carry.removeAll(keepingCapacity: true)
            return
        }
        for trimCount in 1...3 where combined.count > trimCount {
            let prefix = combined.dropLast(trimCount)
            if let chunk = String(data: prefix, encoding: .utf8) {
                scanTailText.append(chunk)
                utf8Carry = Data(combined.suffix(trimCount))
                return
            }
        }
        utf8Carry = Data(combined.suffix(12))
    }

    // MARK: - Command palette auto-confirms

    private func commandPaletteSends(for subcommand: String) -> [String: String] {
        let normalized = subcommand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "/usage":
            return ["Show plan": "\r", "Show plan usage limits": "\r"]
        case "/status":
            return ["Show Claude Code": "\r", "Show Claude Code status": "\r"]
        default:
            return [:]
        }
    }

    private func normalizedNeedle(_ text: String) -> String {
        String(text.lowercased().filter { !$0.isWhitespace })
    }

    // MARK: - Environment

    private static func launchEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // Remove any ANTHROPIC_ vars (tokens etc.) so the probe session uses
        // the user's own stored credentials, not injected overrides.
        for key in env.keys where key.hasPrefix("ANTHROPIC_") { env.removeValue(forKey: key) }
        // Remove OAuth env keys commonly set by CodexBar/BirdNion
        for key in ["CLAUDE_OAUTH_TOKEN", "CLAUDE_OAUTH_SCOPES"] { env.removeValue(forKey: key) }
        return env
    }

    // MARK: - Working directory

    private static func probeWorkingDirectoryURL() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        let dir = base
            .appendingPathComponent("BirdNion", isDirectory: true)
            .appendingPathComponent("ClaudeProbe", isDirectory: true)
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) } catch {}
        return dir
    }

    private static func preparedProbeWorkingDirectoryURL() -> URL {
        let directory = probeWorkingDirectoryURL()
        do { try prepareProbeWorkingDirectory(at: directory) } catch {}
        return directory
    }

    private static func prepareProbeWorkingDirectory(at directory: URL, fileManager fm: FileManager = .default) throws {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let claudeDir = directory.appendingPathComponent(".claude", isDirectory: true)
        try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        let settingsURL = claudeDir.appendingPathComponent("settings.local.json")
        var settings: [String: Any] = (try? readSettingsObject(from: settingsURL, fileManager: fm)) ?? [:]
        settings["disableDeepLinkRegistration"] = "disable"
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settingsURL, options: .atomic)
    }

    private static func readSettingsObject(from url: URL, fileManager fm: FileManager) throws -> [String: Any] {
        guard fm.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [:] }
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any] ?? [:]
    }

    // MARK: - Process tree termination (inlined from CodexBar's TTYProcessTreeTerminator)

    private static func descendantPIDs(of rootPID: pid_t) -> [pid_t] {
        // Use `pgrep -P` to collect direct children, then recurse.
        var result: [pid_t] = []
        var queue = [rootPID]
        var visited = Set<pid_t>()
        while !queue.isEmpty {
            let current = queue.removeFirst()
            guard visited.insert(current).inserted else { continue }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            proc.arguments = ["-P", "\(current)"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let text = String(data: data, encoding: .utf8) {
                let children = text.split(whereSeparator: \.isNewline)
                    .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
                for child in children where child != rootPID {
                    result.append(child)
                    queue.append(child)
                }
            }
        }
        return result
    }

    private func terminateProcessTree(
        rootPID: pid_t,
        processGroup: pid_t?,
        signal: Int32,
        knownDescendants: [pid_t])
    {
        kill(rootPID, signal)
        if let pg = processGroup { killpg(pg, signal) }
        for pid in knownDescendants where pid > 0 { kill(pid, signal) }
    }
}
