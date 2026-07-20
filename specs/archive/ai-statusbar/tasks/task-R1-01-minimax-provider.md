# Task R1-01: MiniMaxProvider

**Requirement:** R3 — MiniMax Token Plan quota adapter
**Status:** pending
**Priority:** P1
**Estimated Effort:** M
**Dependencies:** tasks/task-R0-02-keychain-service.md, tasks/task-R0-03-models-and-protocol.md
**Spec:** specs/ai-statusbar/

## Context

- **Why**: MiniMax is one of the two quota sources BOSS wants visible. The endpoint `/v1/token_plan/remains` returns rolling 5-hour and weekly percent remaining — these map directly onto two `QuotaWindow` rows in the popover.
- **Current state**: `KeychainService` (R0-02) and `QuotaProvider` protocol (R0-03) exist. No provider implementations yet.
- **Target outcome**: `AIStatusbar/Providers/MiniMaxProvider.swift` conforming to `QuotaProvider`, calling `https://api.minimax.io/v1/token_plan/remains` with a bearer token from Keychain, and emitting a `ProviderStatus` with two windows labeled "5 giờ" and "Tuần". Four parser tests against a recorded fixture prove the contract.

## Constraints

- **MUST**: Endpoint = `https://api.minimax.io/v1/token_plan/remains`, GET, header `Authorization: Bearer <Keychain.read("minimax")>`.
- **MUST**: Tolerate extra fields in the response; require `model_remains[0].current_interval_remaining_percent` and `current_weekly_remaining_percent`.
- **MUST**: `ProviderStatus.error` is set (not thrown) on non-2xx, missing fields, or missing token; `QuotaService` will catch throws separately.
- **MUST**: `URLSession` is the default-shared instance with no custom `URLSessionDelegate`; no `URLSessionDelegate.urlSession(_:didReceive:completionHandler:)` override that disables certificate validation.
- **MUST NOT**: Log or print the bearer token.
- **MUST NOT**: Make any outbound network call other than `GET https://api.minimax.io/v1/token_plan/remains`.
- **SCOPE**: One provider + one parser-test file. Polling lives in R1-03.

## Steps

- [ ] 1. Add `AIStatusbar/Providers/MiniMaxProvider.swift` with `final class MiniMaxProvider: QuotaProvider`, an `init(session: URLSession = .shared, keychain: KeychainService)` constructor, and a small private `RemainsResponse` Decodable struct. The endpoint URL is a `private static let endpoint = URL(string: "https://api.minimax.io/v1/token_plan/remains")!` compile-time constant (Finding F2: not overridable from `providers.json`).
  - Business intent: turns HTTP + JSON into a `ProviderStatus`; supports test injection.
  - Code detail: `id = "minimax"`, `displayName = "MiniMax"`, `fetch()` calls `session.data(for:)` using the injected session, then runs the parser.
  - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 11.3, 11.4_

- [ ] 2. Implement the parser: 2xx with valid JSON → 2 `QuotaWindow`; missing `model_remains` or missing percent fields → `error: "Response thiếu trường"`; **HTTP 401/403 → `error: "Token bị từ chối — kiểm tra loại key (inference key, không phải Subscription Key)"`** (Finding F6); other non-2xx → `error: "HTTP \(code)"`; missing keychain item → `error: "Chưa cấu hình token"`. The `URLRequest` value passed to `session.data(for:)` is wrapped in a `RedactedURLRequest` whose `description` returns `"<request to api.minimax.io>"` and never includes the `Authorization` header (Finding F11/security).
  - Business intent: matches the error categories in design.md Error Handling, with a distinct message for token-type mismatch.
  - Code detail: helper `func parse(_ data: Data) -> Result<ProviderStatus, String>`; uses `JSONDecoder` with `keyDecodingStrategy = .useDefaultKeys`.
  - _Requirements: 3.2, 3.3, 3.4, 3.5, 3.6, 11.2_

- [ ] 3. Add `AIStatusbarTests/MiniMaxProviderParserTests.swift` with 4 cases: happy path (fixture from issue #48), missing `model_remains`, missing percent fields, malformed JSON. Each test instantiates a `MiniMaxProvider` with a stubbed `URLProtocol` and a stubbed `KeychainService`.
  - Business intent: locks the parser contract.
  - Code detail: `URLProtocol` subclass that returns a canned `(HTTPURLResponse, Data)`. Test fixtures live in `AIStatusbarTests/Fixtures/minimax-*.json`.
  - _Requirements: 3.2, 3.3, 3.4, 3.5, 11.3, 11.4, 12.1_

- [ ] 4. Verification.
  - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 12.1_

## Requirements

- 3.1 — Call `GET https://api.minimax.io/v1/token_plan/remains` with bearer auth.
- 3.2 — 2xx valid JSON → 2 windows: "5 giờ" (interval %) and "Tuần" (weekly %).
- 3.3 — Missing `model_remains` or percent fields → `error` set, no crash.
- 3.4 — Non-2xx → `error` records status code.
- 3.5 — Missing Keychain token → `error: "Chưa cấu hình token"`, no network call.
- 3.6 — 401/403 → distinct error mentioning "inference key, không phải Subscription Key".
- 11.2 — `URLRequest.description` MUST be redacted to never expose `Authorization` header.
- 11.3 — No outbound network call except to the configured provider endpoint (compile-time constant).
- 11.4 — `URLSession` with default TLS validation; no certificate check override.
- 12.1 — Provider failures do not crash the polling loop.

## Related Files

| Path | Action | Description |
|---|---|---|
| `AIStatusbar/Providers/MiniMaxProvider.swift` | Create | Provider + private `RemainsResponse` |
| `AIStatusbarTests/MiniMaxProviderParserTests.swift` | Create | 4 parser cases |
| `AIStatusbarTests/Fixtures/minimax-happy.json` | Create | Recorded response fixture (issue #48 shape) |
| `AIStatusbarTests/Fixtures/minimax-missing-model.json` | Create | Edge fixture |
| `AIStatusbarTests/Fixtures/minimax-missing-pct.json` | Create | Edge fixture |
| `AIStatusbarTests/Fixtures/minimax-malformed.json` | Create | Edge fixture |
| `AIStatusbar.xcodeproj/project.pbxproj` | Modify | Add new sources + test files |

## Completion Criteria

- [ ] `xcodebuild test` reports 4/4 in `MiniMaxProviderParserTests` passing.
- [ ] No call site in `MiniMaxProvider.swift` contains the literal substring `print(` (grep clean).
- [ ] The happy-path test asserts `windows.count == 2`, `windows[0].label == "5 giờ"`, `windows[1].label == "Tuần"`, and the percent values match the fixture.
- [ ] The non-2xx test asserts `error` starts with `"HTTP "` and contains the status code.

## Evidence

- [ ] Automated verification
  - Command(s): `xcodebuild test -scheme AIStatusbar -destination 'platform=macOS' -only-testing:AIStatusbarTests/MiniMaxProviderParserTests 2>&1 | tail -30`
  - Expected proof: 4/4 pass, exit 0.
- [ ] Artifact / runtime verification
  - Inspect: `AIStatusbarTests/Fixtures/minimax-happy.json` (Read tool).
  - Expect: contains `"model_remains"` array with both percent fields.
- [ ] Runtime reachability verification
  - Entrypoint/caller: `QuotaService` (R1-03) will instantiate `MiniMaxProvider`; the parser test demonstrates the contract.
  - Expect: provider object is constructable and `fetch()` returns within 1s when URLProtocol returns synchronously.
- [ ] Contract / negative-path verification
  - Check: run the test with a `URLProtocol` that returns 503.
  - Expect: `ProviderStatus.error` is set, `windows` is empty, no throw.

## Risk Assessment

| Risk | Severity | Mitigation |
|---|---|---|
| MiniMax changes response shape | Medium | Parser tolerates extra fields; missing required fields → `error` not crash; fixture test catches the happy path. |
| Bearer token leaked to logs via URLRequest.description | Low | Override `URLRequest` description in debug builds, or construct via `URLRequest` without logging the value. |
| Network call from tests hits real MiniMax | High (privacy/cost) | All tests use `URLProtocol` stub — never `URLSession.shared` directly in tests. |
