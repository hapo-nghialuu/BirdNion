# Task R0-01: Error classifier foundation

**Requirement:** R0 — Foundation: pure error classifier
**Status:** done
**Priority:** P1
**Estimated Effort:** 2-3h
**Dependencies:** none
**Spec:** specs/provider-reliability/
**Contracts:** ProviderErrorKind, classify

## Context

- **Why**: Providers surface ad-hoc bilingual raw error strings (`"HTTP 401"`, `"timeout sau 12s"`, `"Chưa cấu hình token"`, `"Không tìm thấy cookie"`). Users cannot act on them. This task creates the single pure seam that maps a raw error to an actionable group, consumed by the UI (R2) and the failure notification (R3).
- **Current state**: `BirdNion/Providers/QuotaProvider.swift` returns `ProviderStatus` whose `error: String?` carries the raw string. `QuotaService.refresh()` builds `error: "\(error)"` on a thrown fetch. No classifier exists. Tests live in `BirdNionTests/` (XCTest); the project has no synced groups, so a new `.swift` file needs manual pbxproj edits.
- **Target outcome**: A new pure file exposes `ProviderErrorKind` + `classify(rawError:)` with a fixed precedence, added to the app target AND test target, unit-tested in isolation.

## Constraints

- **MUST**: `classify` is a pure function — no I/O, no global state, no UI/network imports (R0.2). Implement the exact precedence from the `classify` contract below.
- **MUST**: Add the new file to `BirdNion.xcodeproj/project.pbxproj` for BOTH the app target (`BirdNion`) and the unit-test target so `@testable import BirdNion` resolves the type.
- **SHOULD**: Match case-insensitively on stable substrings + HTTP codes; keep marker sets centralized so future strings are one-line additions.
- **MUST NOT**: Change `ProviderStatus`, `QuotaProvider.fetch()` signatures, or the quota-warning system. No new dependency.
- **SCOPE**: Implement only R0 (classifier + kinds). Localization strings are R1; UI/notification wiring is R2/R3.

## Steps

- [x] 1. Create `BirdNion/Services/ProviderErrorClassifier.swift` with the `ProviderErrorKind` enum (copy the contract block verbatim).
  - Business intent: fixed, testable vocabulary of actionable error groups shared by every surface.
  - Code detail: `enum ProviderErrorKind: String, CaseIterable, Equatable, Sendable` with cases `cookieExpiredOrMissing`, `tokenInvalidOrMissing`, `apiSchemaChanged`, `networkUnreachableOrTimeout`, `rateLimited`, `unknown`; computed `titleKey`/`hintKey` returning `"providerError.\(rawValue).title"` / `".hint"`.
  - _Requirements: 0.1_

- [x] 2. Implement `func classify(rawError: String?) -> ProviderErrorKind?` with the fixed precedence.
  - Business intent: map any raw string to exactly one actionable kind; ambiguous strings resolve to the most useful remediation.
  - Code detail: return `nil` on nil/empty (R0.7); lowercase once; ordered checks — cookie markers (R0.3) → `429`/rate markers (R0.4) → timeout/network markers (R0.5) → `401`/`403`/token markers → invalid-response/`5xx` schema markers → `.unknown` fallback (R0.6). <!-- Updated: Red Team Finding 5 --> HTTP codes are matched ONLY in an HTTP context (`"http NNN"`, `"(NNN)"`, `"status NNN"`, or an `NNN` token not embedded in a longer digit run/decimal) — a bare `"5000 tokens"`, `"0.140.0"`, `"429ms"` MUST NOT be read as an HTTP code. The ordered marker checks (cookie/rate/timeout-network) run BEFORE bare HTTP-code inference so `"timeout sau 429ms"` classifies as network. Marker sets per `design.md` §4 (illustrative/non-exhaustive; ambiguous single-word markers like `"đăng nhập"`/`"connection"` excluded).
  - _Requirements: 0.1, 0.3, 0.4, 0.5, 0.6, 0.7_

- [x] 3. Register the new file in `BirdNion.xcodeproj/project.pbxproj` (PBXBuildFile + PBXFileReference + app-target Sources phase + test-target Sources phase).
  - Business intent: the type compiles into the app and is importable by tests.
  - Code detail: add one PBXFileReference for the file, a PBXBuildFile entry for the app target's Sources build phase, and a second PBXBuildFile referencing the same file in the test target's Sources build phase (so `@testable import` sees it).
  - _Requirements: 0.2_

- [x] 4. Verification implementation
  - Create `BirdNionTests/ProviderErrorClassifierTests.swift`: one assertion per kind from representative raw strings, precedence cases, nil/empty, AND digit-in-text negative cases: `classify("timeout sau 429ms") == .networkUnreachableOrTimeout`, `classify("5000 tokens used") != .apiSchemaChanged` (from the `500`), `classify("account id 140399") == .unknown`. Register in pbxproj test target. <!-- Updated: Red Team Finding 5 -->
  - _Requirements: 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7_

## Requirements

- 0.1 — `classify(rawError:)` maps to exactly one of the six `ProviderErrorKind` values.
- 0.2 — Classifier is pure (no I/O/state/UI/network) and unit-testable in isolation.
- 0.3 — Cookie marker + 401 → `cookieExpiredOrMissing` (cookie precedence).
- 0.4 — `429`/rate marker → `rateLimited`, before 401/403 rule.
- 0.5 — timeout/network marker → `networkUnreachableOrTimeout`, before schema rule.
- 0.6 — unmatched → `unknown`.
- 0.7 — nil/empty raw error → `nil`.

## Related Files

| Path | Action | Description |
|---|---|---|
| `BirdNion/Services/ProviderErrorClassifier.swift` | Create | `ProviderErrorKind` enum + pure `classify(rawError:)` |
| `BirdNionTests/ProviderErrorClassifierTests.swift` | Create | Unit tests: per-kind + precedence + nil/empty |
| `BirdNion.xcodeproj/project.pbxproj` | Modify | Register both new files in app + test targets |
| `BirdNion/Providers/QuotaProvider.swift` | Read | Confirm `fetch() -> ProviderStatus` error surface |
| `BirdNion/Models/ProviderStatus.swift` | Read | Confirm `error: String?` shape |

## Completion Criteria

- [x] `ProviderErrorKind` has exactly the six cases and `titleKey`/`hintKey` computed properties (R0.1).
- [x] `classify(rawError:)` returns `nil` for nil/empty and the correct kind for each representative raw string per the precedence invariant (R0.3–R0.7).
- [x] The classifier file has no UI/network/Foundation-URL imports beyond what a pure string function needs; no global mutable state (R0.2).
- [x] Both new files are registered in pbxproj; the app + tests compile; no orphaned file (classifier will be consumed by R2/R3 — reachability owned by task-R4-01).

## Evidence

- [x] Automated verification (unit)
  - Command(s): `xcodebuild test -scheme BirdNion -destination 'platform=macOS' -only-testing:BirdNionTests/ProviderErrorClassifierTests`
  - Expected proof: test target builds; all `ProviderErrorClassifierTests` cases pass (exit 0), including `classify("HTTP 401 (cookie)") == .cookieExpiredOrMissing`, `classify("HTTP 429") == .rateLimited`, `classify("timeout sau 12s") == .networkUnreachableOrTimeout`, `classify("Response JSON không hợp lệ") == .apiSchemaChanged`, `classify("Chưa cấu hình token") == .tokenInvalidOrMissing`, `classify(nil) == nil`, `classify("") == nil`.
- [x] Artifact / runtime verification
  - Inspect: `BirdNion/Services/ProviderErrorClassifier.swift` and the two pbxproj build phases.
  - Expect: file present with the verbatim contract; pbxproj lists it under app + test Sources.
- [x] Runtime reachability verification
  - Entrypoint/caller: consumed later by `ProvidersPane` (R2-01/R2-02) and `QuotaService.refresh()` (R3-01); final wiring proven in task-R4-01.
  - Expect: `classify` is `internal` (module-visible) so those callers and `@testable import` reach it.
- [x] Contract / negative-path verification
  - Check: an ambiguous `"HTTP 401 (cookie)"` and a bare `"429"` both resolve per precedence; an unmatched string like `"weird gibberish"` → `.unknown`; digits embedded in text (`"timeout sau 429ms"`, `"5000 tokens used"`, `"account id 140399"`) are NOT misread as HTTP codes.
  - Expect: precedence + digit-in-text negative tests pin these exact cases (Finding 5).


### Verification Receipt (2026-07-07)

- `xcodebuild -project BirdNion.xcodeproj -scheme BirdNion -configuration Debug build` → **BUILD SUCCEEDED**
- `xcodebuild test ... -only-testing:BirdNionTests/ProviderErrorClassifierTests` → **12/12 passed, TEST SUCCEEDED** (per-kind, precedence pins incl. "HTTP 401 (cookie)"→cookie, "timeout — invalid"→network, nil/empty→nil, digit-in-text negatives "timeout sau 429ms"/"5000 tokens used"/"account id 140399"/"0.140.0")
- Artifact: `BirdNion/Services/ProviderErrorClassifier.swift` (contract verbatim, pure — Foundation only for NSRegularExpression); pbxproj registers classifier in app Sources + tests in test Sources.
- Reachability: internal visibility confirmed via @testable import; UI/notification wiring owned by R2/R3/R4.

## Risk Assessment

| Risk | Severity | Mitigation |
|---|---|---|
| Ambiguous raw string classified into wrong kind | Medium | Fixed precedence invariant; dedicated precedence unit tests |
| New file omitted from pbxproj test target → import fails | Medium | Step 3 explicitly registers app + test target Sources phases |
| Provider adds a new raw string later that falls through | Low | `.unknown` fallback keeps UX safe; marker sets are one-line additions |

---

> **Parallel marker**: Append `(P)` to the title if this task can run concurrently with another (usually when serving different requirements).
> **Test note**: If a test coverage sub-task can be deferred post-MVP, mark it with `- [ ]*`.
> **Requirement mapping**: Every sub-task MUST end with `_Requirements: X.X_`. No mapping = invalid task file.
> **Evidence rule**: No `## Evidence` section = invalid task file. Existing specs may use `## Task Test Plan & Verification Evidence` or legacy `## Verification & Evidence`; agents must support all three headings.
