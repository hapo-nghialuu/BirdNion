import XCTest
@testable import BirdNion

final class LocalCostSourceTests: XCTestCase {

    func testISODateParsesWithAndWithoutFractionalSeconds() {
        XCTAssertEqual(LocalCostParsing.isoDate("2026-07-15T06:20:44.636Z")?.timeIntervalSince1970 ?? 0,
                       1_784_096_444.636, accuracy: 0.001)
        XCTAssertEqual(LocalCostParsing.isoDate("2026-07-15T06:20:44Z")?.timeIntervalSince1970, 1_784_096_444)
        XCTAssertNil(LocalCostParsing.isoDate("not a date"))
    }


    private func turns(_ object: Any, cutoff: Date = .distantPast) -> [LocalTurnRecord] {
        GenericJsonCostSource.turns(in: object, cutoff: cutoff, dedupePrefix: "t")
    }

    // Each message is attributed to its own timestamp and model, not its parent's.
    func testWalkerUsesTheRecordOwningTheUsage() {
        let thread: [String: Any] = [
            "model": "parent-model",
            "timestamp": "2026-03-10T09:00:00Z",
            "messages": [
                ["timestamp": "2026-03-01T10:00:00Z", "model": "model-a",
                 "usage": ["input_tokens": 100, "output_tokens": 50]],
                ["timestamp": "2026-03-05T10:00:00Z", "model": "model-b",
                 "usage": ["input_tokens": 200, "output_tokens": 20]],
            ],
        ]
        let out = turns(thread).sorted { $0.date < $1.date }
        XCTAssertEqual(out.map(\.model), ["model-a", "model-b"])
        XCTAssertEqual(out.map(\.tokens), [150, 220])
        XCTAssertEqual(
            Calendar.current.dateComponents([.day], from: out[0].date, to: out[1].date).day, 4)
    }

    // A record missing a field inherits it from the parent.
    func testWalkerFallsBackToParentForMissingFields() {
        let thread: [String: Any] = [
            "model": "parent-model",
            "messages": [["timestamp": "2026-03-01T10:00:00Z",
                          "usage": ["input_tokens": 10, "output_tokens": 5]]],
        ]
        XCTAssertEqual(turns(thread).first?.model, "parent-model")
    }

    // Records without a real timestamp are dropped instead of landing on a guessed day.
    func testTurnsWithoutTimestampAreDropped() {
        let record: [String: Any] = ["model": "m", "usage": ["input_tokens": 10, "output_tokens": 5]]
        XCTAssertTrue(turns(record).isEmpty)
    }

    // Timestamp / aggregate / credit keys never count as tokens.
    func testSplitTokensIgnoresNonTokenKeys() {
        let usage: [String: Any] = [
            "input_tokens": 100, "output_tokens": 50,
            "timestamp": 1_760_000_000_000, "totalInputTokens": 999,
            "credits": 7, "cost": 3, "messageId": 42,
        ]
        let tokens = GenericJsonCostSource.splitTokens(usage, spec: .default)
        XCTAssertEqual(tokens.input, 100)
        XCTAssertEqual(tokens.output, 50)
        XCTAssertEqual(tokens.total, 150)
    }

    // Gemini-shaped prompt counts include the cached part; it is priced once.
    func testSplitTokensSubtractsCachedFromPrompt() {
        let usage: [String: Any] = [
            "promptTokenCount": 1000, "cachedContentTokenCount": 400,
            "candidatesTokenCount": 100,
        ]
        let tokens = GenericJsonCostSource.splitTokens(usage, spec: .default)
        XCTAssertEqual(tokens.input, 600)
        XCTAssertEqual(tokens.cacheRead, 400)
        XCTAssertEqual(tokens.output, 100)
    }

    func testParseTimestampDetectsEpochUnit() throws {
        let expected = 1_760_000_000.0
        for raw in [expected, expected * 1e3, expected * 1e6, expected * 1e9] {
            let date = try XCTUnwrap(LocalCostParsing.parseTimestamp(raw))
            XCTAssertEqual(date.timeIntervalSince1970, expected, accuracy: 1)
        }
        let nanoString = try XCTUnwrap(LocalCostParsing.parseTimestamp("1760000000000000000"))
        XCTAssertEqual(nanoString.timeIntervalSince1970, expected, accuracy: 1)
    }

    func testCopilotPricesComponentsAndConservativeTotal() throws {
        let model = "claude-sonnet-4-5"
        let price = try XCTUnwrap(ClaudeModelPrice.price(for: model))
        let split = CopilotModelPrice.estimate(
            model: model,
            counts: CopilotTokenCounts(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000))
        XCTAssertEqual(split, price.inputPerM + price.outputPerM + price.cacheReadPerM, accuracy: 1e-9)

        let totalOnly = CopilotModelPrice.estimate(
            model: model, counts: CopilotTokenCounts(totalOnly: 1_000_000))
        XCTAssertEqual(totalOnly, price.inputPerM, accuracy: 1e-9)
    }

    func testCopilotTokenCountsDoNotDoubleCountTotalPlusComponents() {
        let counts = CopilotTokenCounts(usage: [
            "inputTokens": 100, "outputTokens": 50, "totalTokens": 150])
        XCTAssertEqual(counts.total, 150)
        let delta = CopilotTokenCounts(usage: ["inputTokens": 160, "outputTokens": 60])
            .delta(from: counts)
        XCTAssertEqual(delta.input, 60)
        XCTAssertEqual(delta.output, 10)
    }

    // Gemini: cached tokens are inside `input`; only the rest is fresh input.
    func testGeminiPricesCachedOnce() throws {
        let record: [String: Any] = [
            "timestamp": "2026-03-01T10:00:00Z", "model": "gemini-2.5-pro",
            "tokens": ["input": 1000, "cached": 400, "output": 100, "total": 1100],
        ]
        let turn = try XCTUnwrap(GeminiCostSource.turn(
            record: record, session: "s", ordinal: 0, cutoff: .distantPast))
        let price = try XCTUnwrap(GeminiModelPrice.price(for: "gemini-2.5-pro"))
        let expected = (600 * price.inputPerM + 400 * price.cachedPerM + 100 * price.outputPerM) / 1_000_000
        XCTAssertEqual(turn.usd, expected, accuracy: 1e-12)
        XCTAssertEqual(turn.tokens, 1100)
    }

    // Gemini 4 Carbon doubles its card on 1 Dec 2026; a turn keeps the card
    // in force on its own day.
    func testGeminiDatedCardFollowsTurnDate() throws {
        let iso = ISO8601DateFormatter()
        let before = try XCTUnwrap(iso.date(from: "2026-11-30T12:00:00Z"))
        let after = try XCTUnwrap(iso.date(from: "2026-12-01T12:00:00Z"))
        XCTAssertEqual(GeminiModelPrice.price(for: "gemini-4-carbon", on: before)?.inputPerM, 2.0)
        XCTAssertEqual(GeminiModelPrice.price(for: "gemini-4-carbon", on: after)?.inputPerM, 4.0)
    }

    // Flash models must not fall through to the generic Gemini 3 (Pro) card.
    func testGeminiFlashModelsUseTheirOwnCards() {
        XCTAssertEqual(GeminiModelPrice.price(for: "gemini-3-flash-preview")?.outputPerM, 3.0)
        XCTAssertEqual(GeminiModelPrice.price(for: "gemini-3.1-flash-lite")?.outputPerM, 1.5)
        XCTAssertEqual(GeminiModelPrice.price(for: "gemini-3.5-flash-lite")?.outputPerM, 2.5)
    }

    func testGemini31ProLongPromptUsesLongCard() {
        XCTAssertEqual(GeminiModelPrice.price(for: "gemini-3.1-pro-preview", promptTokens: 200_000)?.inputPerM, 2.0)
        XCTAssertEqual(GeminiModelPrice.price(for: "gemini-3.1-pro-preview", promptTokens: 200_001)?.inputPerM, 4.0)
    }

    // Antigravity: newer builds leave the generation record without a time;
    // it is recovered from `steps.metadata` through the shared step id.
    private func pbVarint(_ value: UInt64) -> [UInt8] {
        var v = value; var out: [UInt8] = []
        repeat { var b = UInt8(v & 0x7F); v >>= 7; if v != 0 { b |= 0x80 }; out.append(b) } while v != 0
        return out
    }
    private func pbField(_ number: Int, _ value: UInt64) -> [UInt8] {
        pbVarint(UInt64(number << 3)) + pbVarint(value)
    }
    private func pbField(_ number: Int, _ bytes: [UInt8]) -> [UInt8] {
        pbVarint(UInt64(number << 3 | 2)) + pbVarint(UInt64(bytes.count)) + bytes
    }

    func testAntigravityTurnTimeComesFromStepMetadata() throws {
        let stepID = Array("6e2dd6f4-9c3a-4b9d-9d3a-762500a3e778".utf8)
        let usage = pbField(2, 100) + pbField(9, 50)
        let chat = pbField(4, usage) + pbField(19, Array("gemini-flash-worker-agy".utf8))
        let generation = pbField(1, chat) + pbField(4, stepID)

        let turn = try XCTUnwrap(AntigravityTurnDecoder.parseTurn(generation))
        XCTAssertNil(turn.timestampMs, "the generation record carries no time")
        XCTAssertEqual(turn.stepID, String(decoding: stepID, as: UTF8.self))

        let created = pbField(1, 1_795_000_000) + pbField(2, 500_000_000)
        let step = try XCTUnwrap(AntigravityTurnDecoder.parseStepTime(pbField(1, created) + pbField(12, stepID)))
        XCTAssertEqual(step.id, turn.stepID)
        XCTAssertEqual(step.timestampMs, 1_795_000_000_500)
    }

    func testAntigravityPlanNamePrefersThePaidTier() {
        let paid = Data(#"{"currentTier":{"id":"free-tier","name":"Antigravity"},"paidTier":{"id":"g1-ultra-lite-tier","name":"Google AI Ultra"}}"#.utf8)
        XCTAssertEqual(AntigravityAccountCloudQuota.planName(from: paid), "Google AI Ultra")
        let free = Data(#"{"currentTier":{"id":"free-tier","name":"Antigravity"}}"#.utf8)
        XCTAssertEqual(AntigravityAccountCloudQuota.planName(from: free), "Antigravity")
        XCTAssertNil(AntigravityAccountCloudQuota.planName(from: Data("{}".utf8)))
    }

    func testModelIdsReadAsNames() {
        XCTAssertEqual(AllUsageFormat.modelDisplayName("gemini-pro-orchestrator"), "Gemini Pro (Orchestrator)")
        XCTAssertEqual(AllUsageFormat.modelDisplayName("gemini-flash-worker-agy"), "Gemini Flash (Worker)")
        XCTAssertEqual(AllUsageFormat.modelDisplayName("gemini-4-carbon"), "Gemini 4 Carbon")
        XCTAssertEqual(AllUsageFormat.modelDisplayName("gemini-3.1-flash-lite"), "Gemini 3.1 Flash Lite")
        XCTAssertEqual(AllUsageFormat.modelDisplayName("claude-opus-4-6-thinking"), "Claude Opus 4.6 Thinking")
        XCTAssertEqual(AllUsageFormat.modelDisplayName("claude-opus-5-5"), "Claude Opus 5.5")
        XCTAssertEqual(AllUsageFormat.modelDisplayName("claude-opus-5-5[1m]"), "Claude Opus 5.5 [1m]")
        XCTAssertEqual(AllUsageFormat.modelDisplayName("claude-haiku-4-5-20251001"), "Claude Haiku 4.5")
        XCTAssertEqual(AllUsageFormat.modelDisplayName("gpt-6.2-astra"), "GPT 6.2 Astra")
        XCTAssertEqual(AllUsageFormat.modelDisplayName("gpt-5.4-mini"), "GPT 5.4 Mini")
        XCTAssertEqual(AllUsageFormat.modelDisplayName("openai.gpt-5.6-luna"), "GPT 5.6 Luna")
        XCTAssertEqual(AllUsageFormat.modelDisplayName("grok-4.5"), "Grok 4.5")
        XCTAssertEqual(AllUsageFormat.modelDisplayName("deepseek/deepseek-v4-flash-0731"), "DeepSeek V4 Flash 0731")
        XCTAssertEqual(AllUsageFormat.modelDisplayName("nvidia/nemotron-3-ultra-550b-a55b:free"), "Nemotron 3 Ultra 550b A55b (free)")
        XCTAssertEqual(AllUsageFormat.modelDisplayName("MiniMax-M3"), "MiniMax M3")
        // Already readable or synthetic values pass through.
        XCTAssertEqual(AllUsageFormat.modelDisplayName("Gemini Pro (Orchestrator)"), "Gemini Pro (Orchestrator)")
        XCTAssertEqual(AllUsageFormat.modelDisplayName("<synthetic>"), "<synthetic>")
    }
}
