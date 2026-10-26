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
}
