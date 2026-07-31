import XCTest
@testable import BirdNion

final class XAIBillingFetcherTests: XCTestCase {
    func testRequestsUseNestedContractStableUTCAndTimeout() throws {
        let fetcher = try XAIBillingFetcher(apiKey: " 'key' ", teamID: " \" team_1 \" ", transport: StubTransport(outcomes: []))
        let balance = fetcher.balanceRequest()
        XCTAssertEqual(balance.httpMethod, "GET")
        XCTAssertEqual(balance.url?.path, "/v1/billing/teams/team_1/prepaid/balance")
        XCTAssertEqual(balance.value(forHTTPHeaderField: "Authorization"), "Bearer key")
        XCTAssertEqual(balance.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNil(balance.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertEqual(balance.timeoutInterval, 15)
        XCTAssertFalse(balance.url?.absoluteString.contains("key") == true)

        let now = Date(timeIntervalSince1970: 1_751_356_800)
        let usage = try fetcher.usageRequest(historyDays: 2, now: now)
        XCTAssertEqual(usage.httpMethod, "POST")
        XCTAssertEqual(usage.url?.path, "/v1/billing/teams/team_1/usage")
        XCTAssertEqual(usage.value(forHTTPHeaderField: "Authorization"), "Bearer key")
        XCTAssertEqual(usage.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(usage.timeoutInterval, 15)
        let bodyData = try XCTUnwrap(usage.httpBody)
        guard let root = try bodyData.jsonObject() as? [String: Any],
              let request = root["analyticsRequest"] as? [String: Any],
              let timeRange = request["timeRange"] as? [String: Any] else {
            XCTFail("missing nested analytics request")
            return
        }
        XCTAssertEqual(timeRange["startTime"] as? String, "2025-06-30 00:00:00")
        XCTAssertEqual(timeRange["endTime"] as? String, "2025-07-01 08:00:00")
        XCTAssertEqual(timeRange["timezone"] as? String, "Etc/GMT")
        XCTAssertEqual(request["timeUnit"] as? String, "TIME_UNIT_DAY")
        let values = try XCTUnwrap(request["values"] as? [[String: String]])
        XCTAssertEqual(values, [["name": "usd", "aggregation": "AGGREGATION_SUM"]])
        XCTAssertTrue((request["groupBy"] as? [Any])?.isEmpty == true)
        XCTAssertTrue((request["filters"] as? [Any])?.isEmpty == true)
    }

    func testUsageRequestUsesUTCAcrossDSTBoundary() throws {
        let original = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "America/New_York")!
        defer { NSTimeZone.default = original }

        let fetcher = try XAIBillingFetcher(apiKey: "key", teamID: "team", transport: StubTransport(outcomes: []))
        let now = ISO8601DateFormatter().date(from: "2025-11-03T00:30:00Z")!
        let usage = try fetcher.usageRequest(historyDays: 2, now: now)
        let bodyData = try XCTUnwrap(usage.httpBody)
        guard let root = try bodyData.jsonObject() as? [String: Any],
              let request = root["analyticsRequest"] as? [String: Any],
              let timeRange = request["timeRange"] as? [String: Any] else {
            XCTFail("missing nested analytics request")
            return
        }
        XCTAssertEqual(timeRange["startTime"] as? String, "2025-11-02 00:00:00")
        XCTAssertEqual(timeRange["endTime"] as? String, "2025-11-03 00:30:00")
    }

    func testFetchSendsActualRequestsWithoutKeyInURL() async throws {
        let transport = StubTransport(outcomes: [
            .response(Data(#"{"total":{"val":"-1000"}}"#.utf8), 200),
            .response(Data(#"{"limitReached":false,"timeSeries":[]}"#.utf8), 200)
        ])
        let fetcher = try XAIBillingFetcher(apiKey: "secret-key", teamID: "team", transport: transport)
        _ = try await fetcher.fetch()
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url?.path, "/v1/billing/teams/team/prepaid/balance")
        XCTAssertEqual(requests[1].url?.path, "/v1/billing/teams/team/usage")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer secret-key")
        XCTAssertTrue(requests.allSatisfy { $0.url?.absoluteString.contains("secret-key") == false })
    }

    func testFetchAggregatesUTCAndInvertsCents() async throws {
        let transport = StubTransport(outcomes: [
            .response(Data(#"{"total":{"val":"-1000"}}"#.utf8), 200),
            .response(Data(#"{"limitReached":true,"timeSeries":[{"dataPoints":[{"timestamp":"2025-07-01T23:00:00Z","values":[1.25]},{"timestamp":"2025-07-02T01:00:00Z","values":[2.0]}]},{"dataPoints":[{"timestamp":"2025-07-01T05:00:00Z","values":[0.75]}]}]}"#.utf8), 200)
        ])
        let fetcher = try XAIBillingFetcher(apiKey: "key", teamID: "team", transport: transport)
        let snapshot = try await fetcher.fetch()
        XCTAssertEqual(snapshot.balanceUSD, 10)
        XCTAssertEqual(snapshot.daily.map(\.usd), [2.0, 2.0])
        XCTAssertTrue(snapshot.limitReached)
    }

    func testMalformedUsageIsBestEffort() async throws {
        let transport = StubTransport(outcomes: [
            .response(Data(#"{"total":{"val":"-300"}}"#.utf8), 200),
            .response(Data(#"{"timeSeries":[{"dataPoints":[{"timestamp":"bad","values":[1]}]}]}"#.utf8), 200)
        ])
        let fetcher = try XAIBillingFetcher(apiKey: "key", teamID: "team", transport: transport)
        let snapshot = try await fetcher.fetch()
        XCTAssertEqual(snapshot.balanceUSD, 3)
        XCTAssertTrue(snapshot.daily.isEmpty)
        XCTAssertFalse(snapshot.limitReached)
    }

    func testOverflowingUsageDailySumFallsBackToEmptyDaily() async throws {
        let transport = StubTransport(outcomes: [
            .response(Data(#"{"total":{"val":"-300"}}"#.utf8), 200),
            .response(Data(#"{"timeSeries":[{"dataPoints":[{"timestamp":"2025-07-01T00:00:00Z","values":[1e308]},{"timestamp":"2025-07-01T12:00:00Z","values":[1e308]}]}]}"#.utf8), 200)
        ])
        let fetcher = try XAIBillingFetcher(apiKey: "key", teamID: "team", transport: transport)
        let snapshot = try await fetcher.fetch()
        XCTAssertEqual(snapshot.balanceUSD, 3)
        XCTAssertTrue(snapshot.daily.isEmpty)
        XCTAssertFalse(snapshot.limitReached)
    }

    func testMalformedBalancePropagatesParseError() async throws {
        for literal in ["bad", "1e3", "+100"] {
            let transport = StubTransport(outcomes: [.response(Data(#"{"total":{"val":"\#(literal)"}}"#.utf8), 200)])
            let fetcher = try XAIBillingFetcher(apiKey: "key", teamID: "team", transport: transport)
            do {
                _ = try await fetcher.fetch()
                XCTFail("malformed balance must fail")
            } catch {
                XCTAssertEqual(error as? XAIBillingError, .parseError)
            }
        }
    }

    func testHTTPSRedirectDowngradeIsBlocked() {
        let delegate = XAIHTTPSOnlyRedirectDelegate()
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: URL(string: "https://example.test")!)
        let response = HTTPURLResponse(url: URL(string: "https://example.test/redirect")!, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://example.test/final"])!

        var sameOriginRequest: URLRequest?
        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "https://example.test/final")!)
        ) { request in
            sameOriginRequest = request
        }
        XCTAssertNotNil(sameOriginRequest)

        var downgradeRequest: URLRequest?
        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "http://example.test/final")!)
        ) { request in
            downgradeRequest = request
        }
        XCTAssertNil(downgradeRequest)

        var crossOriginRequest: URLRequest?
        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "https://attacker.example/final")!)
        ) { request in
            crossOriginRequest = request
        }
        XCTAssertNil(crossOriginRequest)
    }

    func testHTTPStatusMatrixAndUsageAuthPropagation() async throws {
        let balanceCases: [(Int, XAIBillingError)] = [
            (401, .authenticationRejected), (403, .authenticationRejected),
            (404, .teamNotFound), (429, .rateLimited), (503, .apiError(503))
        ]
        for (status, expected) in balanceCases {
            let transport = StubTransport(outcomes: [.response(Data(), status)])
            let fetcher = try XAIBillingFetcher(apiKey: "key", teamID: "team", transport: transport)
            do {
                _ = try await fetcher.fetch()
                XCTFail("status \(status) must fail")
            } catch {
                XCTAssertEqual(error as? XAIBillingError, expected)
            }
        }

        for (status, expected) in [(401, XAIBillingError.authenticationRejected), (403, .authenticationRejected)] {
            let transport = StubTransport(outcomes: [
                .response(Data(#"{"total":{"val":"-100"}}"#.utf8), 200),
                .response(Data(), status)
            ])
            let fetcher = try XAIBillingFetcher(apiKey: "key", teamID: "team", transport: transport)
            do {
                _ = try await fetcher.fetch()
                XCTFail("usage status \(status) must propagate")
            } catch {
                XCTAssertEqual(error as? XAIBillingError, expected)
            }
        }
    }

    func testUsageNonAuthFailuresReturnBalanceAndEmptyDaily() async throws {
        for outcome in [
            StubTransport.Outcome.response(Data(), 404),
            .response(Data(), 429),
            .response(Data(), 503),
            .failure(.network)
        ] {
            let transport = StubTransport(outcomes: [
                .response(Data(#"{"total":{"val":"-250"}}"#.utf8), 200),
                outcome
            ])
            let fetcher = try XAIBillingFetcher(apiKey: "key", teamID: "team", transport: transport)
            let snapshot = try await fetcher.fetch()
            XCTAssertEqual(snapshot.balanceUSD, 2.5)
            XCTAssertTrue(snapshot.daily.isEmpty)
            XCTAssertFalse(snapshot.limitReached)
        }
    }

    func testTeamAndBaseURLValidation() {
        XCTAssertThrowsError(try XAIBillingFetcher(apiKey: "", teamID: "team")) { XCTAssertEqual($0 as? XAIBillingError, .missingCredentials) }
        for teamID in ["../escape", "/escape", "\\escape", ".", "..", "   ", "\u{1F}", "'   '"] {
            XCTAssertThrowsError(try XAIBillingFetcher(apiKey: "key", teamID: teamID), "invalid team \(teamID)") { XCTAssertEqual($0 as? XAIBillingError, .invalidTeamID) }
        }
        XCTAssertThrowsError(try XAIBillingFetcher(apiKey: "key", teamID: "team", baseURL: URL(string: "http://example.test")!)) {
            XCTAssertEqual($0 as? XAIBillingError, .invalidBaseURL)
        }
    }

    func testCancellationPropagates() async throws {
        let transport = BlockingTransport()
        let fetcher = try XAIBillingFetcher(apiKey: "key", teamID: "team", transport: transport)
        let task = Task { try await fetcher.fetch() }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancellation must propagate")
        } catch is CancellationError {
            // Expected.
        }
    }
}

private actor StubTransport: XAITransport {
    enum Failure: Error, Sendable { case network }
    enum Outcome: Sendable {
        case response(Data, Int)
        case failure(Failure)
    }

    private var outcomes: [Outcome]
    private var requests: [URLRequest] = []

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let outcome = outcomes.isEmpty ? .response(Data(), 200) : outcomes.removeFirst()
        switch outcome {
        case let .response(data, status):
            return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        case let .failure(error):
            throw error
        }
    }

    func recordedRequests() -> [URLRequest] { requests }
}

private actor BlockingTransport: XAITransport {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await Task.sleep(nanoseconds: 60_000_000_000)
        fatalError("unreachable")
    }
}

private extension Data {
    func jsonObject() throws -> Any { try JSONSerialization.jsonObject(with: self) }
}
