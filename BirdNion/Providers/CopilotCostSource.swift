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
        countingRevision: 1,
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
        var lastTotals: [String: Int] = [:]   // model -> cumulative tokens seen
        var snapshotOrdinal = 0
        var pairs: Set<String> = []
        var out: [LocalTurnRecord] = []
        for event in LocalCostParsing.jsonLines(url: file) {
            let type = (event["type"] as? String) ?? ""
            guard type == "session.shutdown" || type == "session_shutdown" else { continue }
            let date = LocalCostParsing.timestamp(in: event, fallback: cutoff)
            let data = event["data"] as? [String: Any] ?? event
            let metrics = (data["modelMetrics"] as? [String: Any])
                ?? (data["model_metrics"] as? [String: Any]) ?? [:]
            for (model, raw) in metrics {
                guard let usage = raw as? [String: Any] else { continue }
                let total = LocalCostParsing.tokenSum(usage, keyContains: "token")
                guard total > 0 else { continue }
                pairs.insert("\(session)|\(model)")
                let previous = lastTotals[model] ?? 0
                let delta = max(0, total - previous)
                lastTotals[model] = total
                guard delta > 0 else { continue }
                guard date >= cutoff else { continue }
                out.append(LocalTurnRecord(
                    date: date, model: model, tokens: delta,
                    usd: CopilotModelPrice.estimate(model: model, tokens: delta),
                    dedupeKey: "copilot:\(session):\(model):s\(snapshotOrdinal)"))
            }
            snapshotOrdinal += 1
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
            let date = LocalCostParsing.timestamp(
                in: flat, keys: ["timestamp", "timeUnixNano", "observedTimeUnixNano"], fallback: cutoff)
            guard date >= cutoff else { return nil }
            return LocalTurnRecord(
                date: date, model: model, tokens: total,
                usd: CopilotModelPrice.estimate(model: model, tokens: total),
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

/// USD estimate for Copilot CLI models: Claude-family via the shared Claude
/// price table, GPT-family via the table below, else $0 (tokens still count).
enum CopilotModelPrice {
    static func estimate(model: String, tokens: Int) -> Double {
        let m = model.lowercased()
        if m.contains("claude") {
            if let price = ClaudeModelPrice.price(for: m) {
                // Split the cumulative token count evenly across input/output
                // — session-state doesn't break it down.
                let half = Double(tokens) / 2
                return (half * price.inputPerM + half * price.outputPerM) / 1_000_000
            }
            return 0
        }
        guard let perM = gptPerMTok(for: m) else { return 0 }
        return Double(tokens) * perM / 1_000_000
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
