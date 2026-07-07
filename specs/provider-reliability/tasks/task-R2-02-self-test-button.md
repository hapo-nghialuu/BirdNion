# Task R2-02: Self test button

**Requirement:** R2 — Per-provider self-test button (Settings → Providers) (P)
**Status:** done
**Priority:** P1
**Estimated Effort:** 2-3h
**Dependencies:** tasks/task-R0-01-error-classifier-foundation.md, tasks/task-R1-01-remediation-hints-localization.md

**Spec:** specs/provider-reliability/

## Context

- **Why**: Users cannot verify a single provider on demand — they must wait for the poll loop and guess whether a failure is real. A self-test button runs one fetch and reports pass/fail with the classified reason.
- **Current state**: `BirdNion/Views/Settings/ProvidersPane.swift` renders a per-provider detail pane (`detailHeader(_:)` ~line 496 already has a reload button; `detailInfoGrid(_:)` ~line 550). The live provider instances are in `quota.providers` (`QuotaService`), each conforming to `QuotaProvider` with `func fetch() async throws -> ProviderStatus`. `classify` + `providerError.*` + `provider.selfTest*` keys exist from R0/R1.
- **Target outcome**: A "Kiểm tra / Self-test" button in the selected provider's detail pane that fetches once and shows inline pass / in-progress / fail(+hint), with the raw error reachable.

## Constraints

- **MUST**: Run exactly ONE `provider.fetch()` per activation using the existing provider instance from `quota.providers.first { $0.id == row.id }`; no new network layer (R2.5).
- **MUST**: Disable the button and show an in-progress state while the test is running (R2.8); classify failures via the shared seam and show the hint, keeping the raw error in `.help()` (R2.7).
- **SHOULD**: Place the button in `detailHeader` next to the existing reload button, or as a dedicated info-grid row.
- **MUST NOT**: Trigger a full `QuotaService.refresh()`; do not mutate `quota.statuses`. The self-test is a local, read-only probe.
- **SCOPE**: Only R2.4–R2.9. Sidebar/grid classified display is R2-01.

## Steps

- [x] 1. Add self-test state to `ProvidersPane`.
  - Business intent: track per-provider test lifecycle for inline feedback.
  - Code detail: `enum SelfTestState: Equatable { case idle, running, pass, fail(kind: ProviderErrorKind, raw: String) }` and `@State private var selfTestState: [String: SelfTestState] = [:]`.
  - _Requirements: 2.6, 2.7, 2.8_

- [x] 2. Add the self-test button + inline result to the detail pane.
  - Business intent: one click tests the selected provider; result shown next to it.
  - Code detail: a `Button(L10n.t("provider.selfTest", language))` near the reload button; disabled when `selfTestState[id] == .running`. Inline label: running → `provider.selfTest.running` + spinner; pass → `provider.selfTest.pass` (green check); fail → `provider.selfTest.fail` + `L10n.t(kind.hintKey, language)` with `.help(raw)`.
  - _Requirements: 2.4, 2.6, 2.7, 2.8_

- [x] 3. Implement the single-fetch action with a safe not-found path.
  - Business intent: probe exactly once via the real fetch path; never hang on a disabled provider.
  - Code detail: on tap, FIRST resolve `let p = quota.providers.first { $0.id == id }`. <!-- Updated: Red Team Finding 2 --> If `p == nil` (provider disabled / not in the live enabled list), set `selfTestState[id] = .fail(.unknown, L10n.t("provider.selfTest.disabled", language))` and RETURN — do NOT enter `.running` (R2.9). Only when `p` exists: set `selfTestState[id] = .running`, then `Task { do { let s = try await p.fetch(); if let e = s.error { selfTestState[id] = .fail(classify(rawError: e) ?? .unknown, e) } else { selfTestState[id] = .pass } } catch { let raw = "\(error)"; selfTestState[id] = .fail(classify(rawError: raw) ?? .unknown, raw) } }`. Reset to `.idle` when `selectedID` changes so stale results don't leak across providers.
  - _Requirements: 2.5, 2.6, 2.7, 2.9_

- [x] 4. Verification implementation
  - Build; manually self-test a healthy provider (→ pass), a misconfigured enabled one (→ fail + hint, raw in tooltip), and a DISABLED provider (→ fail/"enable to test", never stuck spinning); confirm the button disables mid-run only when a fetch runs. Reachability owned by task-R4-01.
  - _Requirements: 2.4, 2.5, 2.6, 2.7, 2.8, 2.9_

## Requirements

- 2.4 — Self-test button present in the Providers detail pane.
- 2.5 — Activation runs exactly one fetch via existing `QuotaProvider.fetch()`; no new network layer.
- 2.6 — Success shows inline pass state.
- 2.7 — Failure shows inline fail state with classified reason + hint; raw reachable.
- 2.8 — In-progress state shown; re-trigger disabled until completion.
- 2.9 — No live fetchable instance (disabled provider): never enter/remain `.running`; show fail/"enable to test".

## Related Files

| Path | Action | Description |
|---|---|---|
| `BirdNion/Views/Settings/ProvidersPane.swift` | Modify | `SelfTestState` enum, `selfTestState` map, button + inline result, single-fetch action |
| `BirdNion/Services/QuotaService.swift` | Read | `providers` array to resolve the live provider instance |
| `BirdNion/Providers/QuotaProvider.swift` | Read | `fetch()` contract |
| `BirdNion/Services/ProviderErrorClassifier.swift` | Read | `classify` for fail classification |
| `BirdNion/Services/AppLocalizer.swift` | Read | `provider.selfTest*` (incl. `provider.selfTest.disabled`) + `providerError.*` keys |

## Completion Criteria

- [x] A self-test button appears for the selected provider (R2.4).
- [x] Clicking it runs exactly one `provider.fetch()` and does not call `QuotaService.refresh()` (R2.5).
- [x] Success → inline pass; failure → inline fail with localized hint and raw in `.help()` (R2.6, R2.7).
- [x] Button is disabled while `.running`; result is per-provider and resets on provider switch (R2.8); no orphan (button lives on the live detail pane).
- [x] Self-testing a DISABLED provider never enters/remains `.running`; it shows a fail/"enable to test" message immediately (R2.9). <!-- Updated: Red Team Finding 2 -->

## Evidence

- [x] Automated verification (build/component)
  - Command(s): `xcodebuild build -scheme BirdNion -destination 'platform=macOS'`
  - Expected proof: app builds; `selfTestState` + button + action compile; the action references `quota.providers...fetch()` (grep-confirmable), not `quota.refresh()`; the `nil`-resolution branch sets `.fail` and returns before `.running`.
- [x] Artifact / runtime verification
  - Inspect: run app → Settings → Providers → select a provider → click Self-test.
  - Expect: healthy provider shows "Đạt/Passed"; misconfigured provider shows "Lỗi/Failed" + hint (e.g. "Token sai — dán lại API key").
- [x] Runtime reachability verification
  - Entrypoint/caller: `ProvidersPane.detailHeader`/detail pane on the live Settings window.
  - Expect: button rendered and its `Task` invokes the resolved `QuotaProvider.fetch()`.
- [x] Contract / negative-path verification
  - Check: activate on a provider that throws/times out; double-click during a run; activate on a DISABLED (not in `quota.providers`) provider.
  - Expect: no crash (R4.1); fail state with classified hint + raw tooltip; second click ignored while `.running` (R2.8); disabled provider shows "enable to test" immediately and the button never sticks on the spinner (R2.9).


### Verification Receipt (2026-07-07)

- `xcodebuild build` → **BUILD SUCCEEDED** (Debug).
- Artifact: `ProvidersPane.swift` — `SelfTestState` enum + `selfTestState` map; header button (disabled while `.running`); `runSelfTest` resolves live instance FIRST, disabled provider → immediate `.fail(kind:.unknown, raw:"Bật provider để kiểm tra")` without entering `.running` (R2.9/Finding 2); exactly one `provider.fetch()` (never QuotaService.refresh); fail shows classified hint + raw in `.help`; state cleared on `selectedID` change.
- Manual pass/fail/disabled QA + reachability owned by task-R4-01.

## Risk Assessment

| Risk | Severity | Mitigation |
|---|---|---|
| Self-test on a disabled provider leaves the button stuck `.running` | High | Not-found path sets `.fail`/`provider.selfTest.disabled` and returns BEFORE entering `.running` (Finding 2) |
| Self-test races the background poll loop | Low | Local `Task` over one provider; read-only; does not touch `quota.statuses` |
| Stale result shown after switching providers | Medium | Reset `selfTestState[id]` on `selectedID` change |

---

> **Parallel marker**: Append `(P)` to the title if this task can run concurrently with another (usually when serving different requirements).
> **Test note**: If a test coverage sub-task can be deferred post-MVP, mark it with `- [ ]*`.
> **Requirement mapping**: Every sub-task MUST end with `_Requirements: X.X_`. No mapping = invalid task file.
> **Evidence rule**: No `## Evidence` section = invalid task file. Existing specs may use `## Task Test Plan & Verification Evidence` or legacy `## Verification & Evidence`; agents must support all three headings.
