# Task R1-02: HapoHubProvider (real + mock)

**Requirement:** R4 — Hapo AI Hub quota adapter
**Status:** pending
**Priority:** P1
**Estimated Effort:** M
**Dependencies:** tasks/task-R0-02-keychain-service.md, tasks/task-R0-03-models-and-protocol.md
**Spec:** specs/ai-statusbar/

## Context

- **Why**: Hapo Hub is the second quota source. BOSS controls the backend so the exact endpoint + auth + JSON shape will be supplied later; the MVP ships a Mock first so the UI is testable, and the real provider is a thin URLSession wrapper that the same factory selects when configuration is present.
- **Current state**: `KeychainService` and `QuotaProvider` exist. No provider implementations.
- **Target outcome**: `AIStatusbar/Providers/HapoHubProvider.swift` (real) and `MockHapoHubProvider.swift` (fake), both conforming to `QuotaProvider`. A factory `HapoHubFactory.make(config:keychain:)` returns the mock when `config.baseURL == "TODO_BOSS"` and the real adapter otherwise. Three parser tests cover both paths.

## Constraints

- **MUST**: `HapoHubProvider` uses `config.baseURL`, `config.authHeaderTemplate` (e.g. `"Bearer \{token\}"` with the literal `{token}` replaced from Keychain), and `config.jsonPath` (dot-separated key path into the response JSON, e.g. `"data.quota.remaining"`).
- **MUST**: `URLSession` is default-shared with no custom `URLSessionDelegate`; no certificate-validation override.
- **MUST**: Mock returns two fixed windows of 80% and 60% (per design.md §3.3).
- **MUST NOT**: Bypass Keychain for the token.
- **SCOPE**: One real provider + one mock + one factory + 3 tests. Polling in R1-03.

## Steps

- [ ] 1. Add `AIStatusbar/Providers/HapoHubConfig.swift` with `struct HapoHubConfig: Codable { let id: String; let displayName: String; let baseURL: String; let authHeaderTemplate: String; let jsonPath: String }`.
  - Business intent: type-safe configuration block.
  - Code detail: `Codable` so it can be loaded from `providers.json` later.
  - _Requirements: 4.1, 8.1_

- [ ] 2. Add `AIStatusbar/Providers/HapoHubProvider.swift` with `final class HapoHubProvider: QuotaProvider` and `init(session: URLSession = .shared, config: HapoHubConfig, keychain: KeychainService)`. The token is validated against `^[A-Za-z0-9._\-]+$` before substitution; any token containing CR/LF or other characters outside the set is rejected with `error: "Token chứa ký tự không hợp lệ"` (Finding F1: header injection).
  - Business intent: real adapter.
  - Code detail: `id = config.id`, `displayName = config.displayName`. The parser uses `JSONSerialization` to walk the dot path and casts to `Int`. 2xx with `Content-Type: application/json` and valid path → 1 `QuotaWindow` labeled "Quota" with `remainingPct`. 2xx but `Content-Type` is not JSON (HTML captive portal, WAF page) → `error: "Endpoint trả về non-JSON (Content-Type: \(ct))"`. 2xx JSON with path missing → `error: "Response thiếu trường \(jsonPath)"`. Non-2xx → `error: "HTTP \(code)"`.
  - _Requirements: 4.1, 4.4, 11.3, 11.4_

- [ ] 3. Add `AIStatusbar/Providers/MockHapoHubProvider.swift` that always returns two fixed windows.
  - Business intent: UI testability before real endpoint is known.
  - Code detail: `id = "hapo"`, `displayName = "Hapo AI Hub (mock)"`, `windows = [QuotaWindow(label: "5 giờ", usedPct: 20, remainingPct: 80), QuotaWindow(label: "Tuần", usedPct: 40, remainingPct: 60)]`, `lastUpdated = Date()`, `error = nil`.
  - _Requirements: 4.2_

- [ ] 4. Add `AIStatusbar/Providers/HapoHubFactory.swift` with `static func make(config: HapoHubConfig, keychain: KeychainService) -> QuotaProvider`.
  - Business intent: single decision point: real vs mock.
  - Code detail: `return config.baseURL == "TODO_BOSS" ? MockHapoHubProvider() : HapoHubProvider(config: config, keychain: keychain)`.
  - _Requirements: 4.3_

- [ ] 5. Add `AIStatusbarTests/HapoHubProviderTests.swift` with 3 cases: mock returns 2 windows with 80/60 percent, real returns 2xx with valid JSON parsed via `jsonPath`, real returns non-2xx → `error`.
  - Business intent: locks both paths.
  - Code detail: `URLProtocol` stub for the real cases; factory is exercised for both branches.
  - _Requirements: 4.2, 4.3, 4.4, 12.1_

- [ ] 6. Verification.
  - _Requirements: 4.1, 4.2, 4.3, 4.4_

## Requirements

- 4.1 — `HapoHubProvider` is gated by `HapoHubConfig` (endpoint, auth header template, json path).
- 4.2 — Missing config → MockHapoHubProvider with fixed 80% / 60% windows.
- 4.3 — Real endpoint integration is a registry swap, no UI/protocol change.
- 4.4 — Non-2xx → `error` records status code.
- 8.1 — Provider config persists in `~/Library/Application Support/AIStatusbar/providers.json`.
- 11.3 — No outbound network call except to the configured provider endpoint.
- 11.4 — `URLSession` with default TLS validation; no certificate check override.
- 12.1 — Provider failures do not crash.

## Related Files

| Path | Action | Description |
|---|---|---|
| `AIStatusbar/Providers/HapoHubConfig.swift` | Create | `HapoHubConfig` struct |
| `AIStatusbar/Providers/HapoHubProvider.swift` | Create | Real adapter |
| `AIStatusbar/Providers/MockHapoHubProvider.swift` | Create | Fixed-window mock |
| `AIStatusbar/Providers/HapoHubFactory.swift` | Create | Real-vs-mock selector |
| `AIStatusbarTests/HapoHubProviderTests.swift` | Create | 3 cases (mock, real-2xx, real-5xx) |
| `AIStatusbar.xcodeproj/project.pbxproj` | Modify | Add new sources + test files |

## Completion Criteria

- [ ] `xcodebuild test` reports 3/3 in `HapoHubProviderTests` passing.
- [ ] `HapoHubFactory.make(config: with baseURL "TODO_BOSS", ...)` returns a `MockHapoHubProvider`.
- [ ] `HapoHubFactory.make(config: with baseURL "https://<HAPO_HOST>", ...)` returns a `HapoHubProvider`.
- [ ] Real adapter extracts an int at the configured jsonPath (test asserts 73 from a fixture with `{"data": {"quota": {"remaining": 73}}}` and `jsonPath = "data.quota.remaining"`).

## Evidence

- [ ] Automated verification
  - Command(s): `xcodebuild test -scheme AIStatusbar -destination 'platform=macOS' -only-testing:AIStatusbarTests/HapoHubProviderTests 2>&1 | tail -30`
  - Expected proof: 3/3 pass, exit 0.
- [ ] Artifact / runtime verification
  - Inspect: `AIStatusbar/Providers/HapoHubFactory.swift` (Read tool).
  - Expect: factory contains a single ternary returning mock or real based on `baseURL == "TODO_BOSS"`.
- [ ] Runtime reachability verification
  - Entrypoint/caller: `QuotaService` (R1-03) will call `HapoHubFactory.make(...)`.
  - Expect: factory is a public, testable symbol reachable from the test target.
- [ ] Contract / negative-path verification
  - Check: real adapter with `jsonPath = "missing.path"` against a fixture `{"foo": 1}`.
  - Expect: `ProviderStatus.error` set, no throw.

## Risk Assessment

| Risk | Severity | Mitigation |
|---|---|---|
| JSONPath resolver mis-parses keys containing dots | Low | Document the limitation: simple dot path only; reject keys with dots via a test case. |
| Mock is mistaken for real data | Medium | `displayName = "Hapo AI Hub (mock)"` makes it visible in the popover. |
| BOSS supplies unexpected auth shape (e.g. cookie, custom header) | Low | `authHeaderTemplate` is a string template, so any `"X-Auth: \{token\}"` works. |
