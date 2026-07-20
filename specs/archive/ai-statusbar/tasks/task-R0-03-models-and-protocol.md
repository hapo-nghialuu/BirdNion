# Task R0-03: Models + QuotaProvider protocol

**Requirement:** Foundation — shared data types + provider contract
**Status:** pending
**Priority:** P0
**Estimated Effort:** S
**Dependencies:** none
**Spec:** specs/ai-statusbar/

## Context

- **Why**: Every provider, view, and service uses `QuotaWindow` and `ProviderStatus`. The `QuotaProvider` protocol is the contract that lets `QuotaService` treat MiniMax, Hapo, and any future provider uniformly.
- **Current state**: Greenfield. Xcode project from R0-01 + `KeychainService` from R0-02 exist.
- **Target outcome**: `AIStatusbar/Models/ProviderStatus.swift` containing `QuotaWindow` and `ProviderStatus` structs (matching the contracts in `design.md`); `AIStatusbar/Providers/QuotaProvider.swift` defining the protocol. Both compile clean and have a parser test for `QuotaWindow` decoding.

## Constraints

- **MUST**: `QuotaWindow` and `ProviderStatus` shapes MUST match the `<!-- contract:QuotaWindow -->` and `<!-- contract:ProviderStatus -->` blocks in `design.md` verbatim.
- **MUST**: `QuotaProvider.fetch()` is `async throws -> ProviderStatus`.
- **MUST NOT**: Import `Foundation` from `QuotaProvider`; keep it pure Swift so the protocol is testable in isolation.
- **SCOPE**: Two source files + one test file. No networking, no UI.

## Steps

- [x] 1. Add `AIStatusbar/Models/ProviderStatus.swift` with `QuotaWindow` and `ProviderStatus` structs.
  - Business intent: shared data type used by every layer.
  - Code detail: `struct QuotaWindow: Identifiable, Codable, Equatable { let id: UUID = UUID(); let label: String; let usedPct: Int; let remainingPct: Int }`; `struct ProviderStatus: Identifiable, Equatable { let id: String; let displayName: String; let windows: [QuotaWindow]; let lastUpdated: Date; let error: String? }`.
  - _Requirements: 2.1, 5.3_

- [x] 2. Add `AIStatusbar/Providers/QuotaProvider.swift` defining the protocol.
  - Business intent: contract for QuotaService and adapters.
  - Code detail: `protocol QuotaProvider: AnyObject { var id: String { get }; var displayName: String { get }; func fetch() async throws -> ProviderStatus }`.
  - _Requirements: 2.1_

- [ ] 3. Add `AIStatusbarTests/ProviderStatusTests.swift` with 3 cases: encode/decode round-trip of `QuotaWindow`, two `QuotaWindow` arrays in `ProviderStatus.windows` preserve order, `error` field round-trips both nil and a string.
  - Business intent: locks the contract so provider drift is caught early.
  - Code detail: use `JSONEncoder` / `JSONDecoder` with default strategies.
  - _Requirements: 2.1, 12.1_

- [ ] 4. Verification.
  - _Requirements: 2.1_

## Requirements

- 2.1 — Define `QuotaProvider` protocol with `id`, `displayName`, and async `fetch() throws -> ProviderStatus`.
- 5.3 — Provider row shows name + relative timestamp + per-window bars.
- 12.1 — Provider failures do not crash; recorded on the status.

## Related Files

| Path | Action | Description |
|---|---|---|
| `AIStatusbar/Models/ProviderStatus.swift` | Create | `QuotaWindow` and `ProviderStatus` |
| `AIStatusbar/Providers/QuotaProvider.swift` | Create | `QuotaProvider` protocol |
| `AIStatusbarTests/ProviderStatusTests.swift` | Create | Encode/decode round-trip tests |
| `AIStatusbar.xcodeproj/project.pbxproj` | Modify | Add new sources + test file |

## Completion Criteria

- [ ] `xcodebuild -scheme AIStatusbar build` exits 0 after adding the files.
- [ ] `xcodebuild test` reports 3/3 in `ProviderStatusTests` passing.
- [ ] `QuotaWindow` and `ProviderStatus` shapes match the contract blocks in `design.md` byte-for-byte.
- [ ] No source file in `Providers/` or `Models/` imports `Foundation` (grep clean).
- [ ] `QuotaProvider.fetch()` is `async throws`; the keyword is present in the protocol declaration (grep clean).

## Evidence

- [ ] Automated verification
  - Command(s): `xcodebuild test -scheme AIStatusbar -destination 'platform=macOS' 2>&1 | tail -30`
  - Expected proof: 3/3 `ProviderStatusTests` pass, 0 failures, exit 0.
- [ ] Artifact / runtime verification
  - Inspect: `AIStatusbar/Models/ProviderStatus.swift` and `AIStatusbar/Providers/QuotaProvider.swift` (Read tool).
  - Expect: shape matches the `<!-- contract:... -->` blocks; no `import Foundation` in protocol file.
- [ ] Runtime reachability verification
  - Entrypoint/caller: `AIStatusbarApp` will reference `ProviderStatus` once a provider lands; for now, the test target imports it.
  - Expect: test target can `import` the `AIStatusbar` product module and reference `QuotaWindow` symbols.
- [ ] Contract / negative-path verification
  - Check: construct a `ProviderStatus` with a 7th field, encode, decode.
  - Expect: decoder fails (or ignores extra fields, depending on policy). Document the choice in a comment.

## Risk Assessment

| Risk | Severity | Mitigation |
|---|---|---|
| Contract drift between spec and code | Medium | Tests pin the exact JSON; same strings used in design.md and tasks. |
| Future provider needs richer status (e.g. lastError) | Low | `error: String?` is the escape hatch; add fields later without breaking `Codable` round-trip. |
