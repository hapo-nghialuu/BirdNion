# Task R4-01: Integration reachability

**Requirement:** R4 — Integration, reachability & non-functional gates
**Status:** done
**Priority:** P1
**Estimated Effort:** 1-2h
**Dependencies:** tasks/task-R2-01-providers-pane-classified-display.md, tasks/task-R2-02-self-test-button.md, tasks/task-R3-01-failure-transition-notification.md

**Spec:** specs/provider-reliability/

## Context

- **Why**: The classifier must be reachable from every scoped surface, the non-functional gates (no-crash, no threshold-system change, no new dep, tests build+pass) must be proven, and no orphan code may remain. This is the final integration/reachability task for a runtime feature spanning UI + service.
- **Current state**: After R0–R3, `ProviderErrorClassifier.swift` exists and is consumed by `ProvidersPane` (sidebar subtitle, detail grid, self-test) and `QuotaService.refresh()` (failure episode). This task audits the wiring end-to-end and runs the full suite.
- **Target outcome**: Full `xcodebuild` build + test pass on macOS; every new surface wired to a real entrypoint; scope constraints verified.

## Constraints

- **MUST**: Confirm `classify` is invoked from BOTH `ProvidersPane` (all three surfaces) and `QuotaService` (failure episode) — no dead code (R4.4).
- **MUST**: Confirm `QuotaWarnConfig`/`evaluateWarnings`, `ProviderStatus` invariant, and provider `fetch()` signatures are unchanged; no new SPM/dependency added (R4.3).
- **MUST**: Full test target builds and passes, including the R0 classifier tests and the R3 episode tests (R4.5); a throwing provider does not crash (R4.1).
- **SHOULD**: Spot-check refresh-loop overhead is negligible (classify is O(n) over the error string, called at most once per provider per cycle) (R4.2).
- **MUST NOT**: Add new behavior beyond wiring/verification.
- **SCOPE**: Integration + verification only.

## Steps

- [x] 1. Reachability audit.
  - Business intent: prove no orphan classifier/notification/self-test code.
  - Code detail: grep `classify(` — expect call sites in `ProvidersPane.swift` (`classifiedMessage` + self-test action) and `QuotaService.swift` (`evaluateFailureEpisode`). Confirm `evaluateFailureEpisode` is called from the `refresh()` loop and `QuotaService.start()` drives that loop; confirm the self-test button is rendered in the live detail pane.
  - _Requirements: 4.4_

- [x] 2. Scope/regression audit.
  - Business intent: guarantee the change stayed surgical.
  - Code detail: `git diff` review — `QuotaWarnConfig`, `evaluateWarnings`, `ProviderStatus`, and every `QuotaProvider.fetch()` signature unchanged; no new dependency in the Xcode project / no new SPM package.
  - _Requirements: 4.3_

- [x] 3. Verification implementation
  - Run the FULL test suite + a clean build (Debug). Confirm the existing 111+ tests still pass alongside the new classifier + episode tests, and the throwing-provider test still passes (no crash).
  - _Requirements: 4.1, 4.2, 4.5_

## Requirements

- 4.1 — Self-test + classification never crash; throwing fetch caught.
- 4.2 — Classification is O(n) and adds no measurable refresh overhead.
- 4.3 — No change to quota-warning system, `ProviderStatus` invariant, fetch signatures; no new dependency.
- 4.4 — All new surfaces wired to real entrypoints; no orphan code.
- 4.5 — Classifier + episode unit tests exist; full suite builds and passes.

## Related Files

| Path | Action | Description |
|---|---|---|
| `BirdNion/Views/Settings/ProvidersPane.swift` | Read | Confirm classify call sites (subtitle, grid, self-test) |
| `BirdNion/Services/QuotaService.swift` | Read | Confirm `evaluateFailureEpisode` wired into `refresh()` loop |
| `BirdNion/Services/ProviderErrorClassifier.swift` | Read | Confirm module-visible, referenced, no orphan |
| `BirdNionTests/ProviderErrorClassifierTests.swift` | Read | R0/R1 tests present + passing |
| `BirdNionTests/QuotaServicePollingTests.swift` | Read | R3 episode tests present + passing |
| `BirdNion.xcodeproj/project.pbxproj` | Read | Confirm new files in app + test targets; no new dependency |

## Completion Criteria

- [x] `classify` reachable/invoked from ProvidersPane (3 surfaces) + QuotaService; no orphan (R4.4).
- [x] `QuotaWarnConfig`/`evaluateWarnings`/`ProviderStatus`/fetch signatures unchanged; no new dependency (R4.3).
- [x] Full `xcodebuild` build clean AND full test suite passes, including classifier + episode + throwing-provider tests (R4.1, R4.5).
- [x] Refresh-loop overhead unchanged in practice — classify runs at most once per provider per cycle (R4.2).

## Evidence

- [x] Automated verification (build + full test)
  - Command(s): `xcodebuild build -scheme BirdNion -destination 'platform=macOS'` then `xcodebuild test -scheme BirdNion -destination 'platform=macOS'`
  - Expected proof: build succeeds; test run reports all tests passing (existing 111+ plus new classifier/episode tests), exit 0. `NO_TESTS`/`0 tests + exit 0` is NOT acceptable.
- [x] Artifact / runtime verification
  - Inspect: `grep -n "classify(" BirdNion/Views/Settings/ProvidersPane.swift BirdNion/Services/QuotaService.swift`.
  - Expect: call sites in both files (classifiedMessage, self-test action, evaluateFailureEpisode).
- [x] Runtime reachability verification
  - Entrypoint/caller: `QuotaService.start()` → `refresh()` loop (failure episode); `SettingsSceneRoot` → `ProvidersPane` (subtitle, grid, self-test button).
  - Expect: every new surface invoked from a live runtime path; no unreferenced symbol.
- [x] Contract / negative-path verification
  - Check: `git diff` of `QuotaService.swift` shows `QuotaWarnConfig`/`evaluateWarnings` bodies unchanged; `ProviderStatus.swift` error invariant unchanged; throwing-provider test passes.
  - Expect: only additive `failureEpisode`/`evaluateFailureEpisode` diffs in the service; no regression.


### Verification Receipt (2026-07-07)

- Reachability: `classify(rawError:)` invoked at 5 real call sites — QuotaService.evaluateFailureEpisode (refresh loop ← start()), ProvidersPane classifiedMessage (sidebar+grid), detail-grid unknown branch, self-test action ×2. Self-test button renders in live detailHeader. No orphan symbol.
- Scope: `git diff` — QuotaWarnConfig/evaluateWarnings bodies untouched (only a doc-comment reference); ProviderStatus + fetch() signatures unchanged; pbxproj adds only 2 file refs, 0 new SPM packages.
- `xcodebuild build` → **BUILD SUCCEEDED**; full `xcodebuild test` → **176 tests, 0 failures, TEST SUCCEEDED** (incl. 12 classifier + 6 polling/episode + throwing-provider).

## Risk Assessment

| Risk | Severity | Mitigation |
|---|---|---|
| A new surface left unwired (orphan) | Medium | Step 1 grep audit + reachability evidence across both files |
| Existing tests regress from the loop hook | Medium | Full suite run; hook is additive and O(1) per provider |
| Hidden dependency/threshold-system drift | Low | Step 2 `git diff` scope audit; validators (Layer 1 + grounding) run at finalization |

---

> **Parallel marker**: Append `(P)` to the title if this task can run concurrently with another (usually when serving different requirements).
> **Test note**: If a test coverage sub-task can be deferred post-MVP, mark it with `- [ ]*`.
> **Requirement mapping**: Every sub-task MUST end with `_Requirements: X.X_`. No mapping = invalid task file.
> **Evidence rule**: No `## Evidence` section = invalid task file. Existing specs may use `## Task Test Plan & Verification Evidence` or legacy `## Verification & Evidence`; agents must support all three headings.
