import Foundation

/// Local cost source: GitHub Copilot CLI usage.
///
/// Two inputs, same as ccusage:
/// 1. `~/.copilot/session-state/<session>/events.jsonl` — written by default.
///    Only `session.shutdown` events count; `data.modelMetrics.<model>.usage`
///    is cumulative per session+model, so each snapshot reports the delta
///    from its predecessor (resumed sessions emit another snapshot).
/// 2. `~/.copilot/otel/**/*.jsonl` (+ the file `COPILOT_OTEL_FILE_EXPORTER_PATH`
///    points at) — opt-in OpenTelemetry export. Rows for a session+model
///    already covered by session-state are suppressed.
///
/// USD is a per-model price-table estimate: Claude-family models go through
/// `ClaudeModelPrice`, GPT-family through `CopilotGPTPrice`; unknown models
/// still count tokens at $0.
enum CopilotCostSource {

    static let descriptor = LocalCostSource(
        source: .copilot,
        displayName: "Copilot CLI",
        countingRevision: 2,
        roots: { CopilotCostSource.dataRoots() },
        turnReader: { roots, cutoff in
            CopilotCostSource.turns(roots: roots, cutoff: cutoff)
        })

    private static func dataRoots() -> [URL] {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".copilot")
        return FileManager.default.fileExists(atPath: dir.path) ? [dir] : []
    }

    private static func turns(roots: [URL], cutoff: Date) -> [LocalTurnRecord] {
        var out: [LocalTurnRecord] = []
        var coveredPairs: Set<String> = []
        for root in roots {
            let stateRoot = root.appendingPathComponent("session-state")
            for file in LocalCostParsing.files(
                under: stateRoot, extensions: ["jsonl"], modifiedSince: cutoff) {
                let result = sessionStateTurns(file: file, cutoff: cutoff)
                coveredPairs.formUnion(result.pairs)
                out.append(contentsOf: result.turns)
            }
            let otelRoot = root.appendingPathComponent("otel")
            var otelFiles = LocalCostParsing.files(
                under: otelRoot, extensions: ["jsonl"], modifiedSince: cutoff)
            if let explicit = ProcessInfo.processInfo.environment["COPILOT_OTEL_FILE_EXPORTER_PATH"],
               !explicit.isEmpty {
                otelFiles.append(URL(fileURLWithPath: explicit))
            }
            for file in otelFiles {
                out.append(contentsOf: otelTurns(file: file, cutoff: cutoff, covered: coveredPairs))
            }
        }
        return out
    }

    // MARK: - session-state events.jsonl

    private static func sessionStateTurns(
        file: URL, cutoff: Date
    ) -> (turns: [LocalTurnRecord], pairs: Set<String>) {
        let session = file.deletingLastPathComponent().lastPathComponent
        var last: [String: CopilotTokenCounts] = [:]   // model -> cumulative counts seen
        var snapshotOrdinal = 0
        var pairs: Set<String> = []
        var out: [LocalTurnRecord] = []
        for event in LocalCostParsing.jsonLines(url: file) {
            let type = (event["type"] as? String) ?? ""
            guard type == "session.shutdown" || type == "session_shutdown" else { continue }
            defer { snapshotOrdinal += 1 }
            let data = event["data"] as? [String: Any] ?? event
            // A snapshot without its own timestamp has no honest day: drop it.
            let date = LocalCostParsing.timestamp(in: event)
                ?? LocalCostParsing.timestamp(in: data)
            let metrics = (data["modelMetrics"] as? [String: Any])
                ?? (data["model_metrics"] as? [String: Any]) ?? [:]
            for (model, raw) in metrics {
                guard let metric = raw as? [String: Any] else { continue }
                let usage = (metric["usage"] as? [String: Any]) ?? metric
                let counts = CopilotTokenCounts(usage: usage)
                guard counts.total > 0 else { continue }
                pairs.insert("\(session)|\(model)")
                let delta = counts.delta(from: last[model] ?? CopilotTokenCounts())
                last[model] = counts
                guard delta.total > 0, let date, date >= cutoff else { continue }
                out.append(LocalTurnRecord(
                    date: date, model: model, tokens: delta.total,
                    usd: CopilotModelPrice.estimate(model: model, counts: delta),
                    dedupeKey: "copilot:\(session):\(model):s\(snapshotOrdinal)"))
            }
        }
        return (out, pairs)
    }

    // MARK: - OpenTelemetry jsonl

    /// Best-effort walk of OTel log records: any nested object carrying a
    /// numeric `*_tokens` attribute is treated as a usage row. Session/model
    /// pairs already covered by session-state are skipped.
    private static func otelTurns(file: URL, cutoff: Date, covered: Set<String>) -> [LocalTurnRecord] {
        LocalCostParsing.jsonLines(url: file).enumerated().compactMap { index, line -> LocalTurnRecord? in
            var flat: [String: Any] = [:]
            flattenAttributes(object: line, into: &flat)
            let input = flatToken(flat, ["gen_ai.usage.input_tokens", "input_tokens", "inputTokens"]) ?? 0
            let output = flatToken(flat, ["gen_ai.usage.output_tokens", "output_tokens", "outputTokens"]) ?? 0
            let cached = flatToken(flat, ["gen_ai.usage.cache_read_input_tokens", "cache_read_tokens"]) ?? 0
            let reasoning = flatToken(flat, ["gen_ai.usage.reasoning_tokens", "reasoning_tokens"]) ?? 0
            let total = input + output + cached + reasoning
            guard total > 0 else { return nil }
            let model = (flat["gen_ai.request.model"] as? String)
                ?? (flat["gen_ai.response.model"] as? String)
                ?? (flat["model"] as? String) ?? "unknown"
            let session = (flat["session.id"] as? String)
                ?? (flat["service.session.id"] as? String) ?? file.deletingPathExtension().lastPathComponent
            if covered.contains("\(session)|\(model)") { return nil }
            guard let date = LocalCostParsing.timestamp(
                in: flat, keys: ["timestamp", "timeUnixNano", "observedTimeUnixNano"]),
                date >= cutoff else { return nil }
            let counts = CopilotTokenCounts(
                input: input, output: output + reasoning, cacheRead: cached)
            return LocalTurnRecord(
                date: date, model: model, tokens: total,
                usd: CopilotModelPrice.estimate(model: model, counts: counts),
                dedupeKey: "copilot-otel:\(file.lastPathComponent):\(index)")
        }
    }

    /// Walk nested arrays/dicts and merge every "attributes" entry
    /// (`{"key":…,"value":{…}}` OTel shape or plain dict) into `flat`.
    private static func flattenAttributes(object: Any, into flat: inout [String: Any]) {
        switch object {
        case let dict as [String: Any]:
            for (key, value) in dict {
                if key == "attributes" {
                    flattenAttributes(object: value, into: &flat)
                } else if let nested = value as? [String: Any] {
                    flattenAttributes(object: nested, into: &flat)
                } else if let array = value as? [Any] {
                    flattenAttributes(object: array, into: &flat)
                } else if flat[key] == nil {
                    flat[key] = value
                }
            }
        case let array as [Any]:
            for element in array {
                if let pair = element as? [String: Any],
                   let key = pair["key"] as? String,
                   let value = pair["value"] {
                    if let inner = value as? [String: Any],
                       let first = inner.values.first {
                        flat[key] = first
                    } else {
                        flat[key] = value
                    }
                } else {
                    flattenAttributes(object: element, into: &flat)
                }
            }
        default:
            break
        }
    }

    private static func flatToken(_ flat: [String: Any], _ keys: [String]) -> Int? {
        for key in keys {
            if let value = LocalCostParsing.int(flat[key]) { return value }
        }
        return nil
    }
}

/// Token counters of one Copilot usage snapshot. Component fields are
/// preferred; `totalOnly` carries a bare total when the log has no breakdown
/// (never added on top of components, which would double count).
struct CopilotTokenCounts: Equatable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    var totalOnly = 0

    init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, totalOnly: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.totalOnly = totalOnly
    }

    init(usage: [String: Any]) {
        func pick(_ keys: [String]) -> Int {
            for key in keys { if let v = LocalCostParsing.int(usage[key]) { return v } }
            return 0
        }
        input = pick(["inputTokens", "input_tokens"])
        output = pick(["outputTokens", "output_tokens"])
        cacheRead = pick(["cacheReadTokens", "cache_read_tokens", "cacheReadInputTokens"])
        cacheWrite = pick(["cacheWriteTokens", "cache_write_tokens", "cacheCreationTokens"])
        totalOnly = input + output + cacheRead + cacheWrite == 0
            ? pick(["totalTokens", "total_tokens", "total"]) : 0
    }

    var total: Int { input + output + cacheRead + cacheWrite + totalOnly }

    /// Per-component growth since `previous` (counters are cumulative).
    func delta(from previous: CopilotTokenCounts) -> CopilotTokenCounts {
        CopilotTokenCounts(
            input: max(0, input - previous.input),
            output: max(0, output - previous.output),
            cacheRead: max(0, cacheRead - previous.cacheRead),
            cacheWrite: max(0, cacheWrite - previous.cacheWrite),
            totalOnly: max(0, totalOnly - previous.totalOnly))
    }
}

/// USD estimate for Copilot CLI models: Claude-family via the shared Claude
/// price table, GPT-family via the table below, else $0 (tokens still count).
enum CopilotModelPrice {
    static func estimate(model: String, counts: CopilotTokenCounts) -> Double {
        let m = model.lowercased()
        if m.contains("claude") {
            guard let price = ClaudeModelPrice.price(for: m) else { return 0 }
            // A bare total has no input/output split; price it at the input
            // rate (the lower bound) instead of inventing a split.
            return (Double(counts.input + counts.totalOnly) * price.inputPerM
                + Double(counts.cacheWrite) * price.inputPerM
                + Double(counts.cacheRead) * price.cacheReadPerM
                + Double(counts.output) * price.outputPerM) / 1_000_000
        }
        guard let perM = gptPerMTok(for: m) else { return 0 }
        return Double(counts.total) * perM / 1_000_000
    }

    /// Blended per-million rate for GPT-family models (input+output mixed).
    private static func gptPerMTok(for model: String) -> Double? {
        let m = model
        if m.hasPrefix("gpt-5") { return 3.75 }
        if m.hasPrefix("gpt-4.1") || m.hasPrefix("gpt-4o") { return 4.00 }
        if m.hasPrefix("gpt-4") { return 15.00 }
        if m.hasPrefix("o3") || m.hasPrefix("o4") { return 6.00 }
        if m.hasPrefix("gemini") { return 2.00 }
        return nil
    }
}
