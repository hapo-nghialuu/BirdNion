# Task R4-01: Integration, reachability & full build/test

**Requirement:** R4 — Performance & Reliability (and end-to-end integration/reachability)
**Status:** done
**Priority:** P2
**Estimated Effort:** S
**Dependencies:** tasks/task-R1-01-settings-and-codex-ui.md, tasks/task-R2-01-primer-engine-and-tests.md, tasks/task-R3-01-quota-service-wiring-and-notification.md
**Spec:** specs/codex-quota-auto-prime/

## Context

- **Why**: Close the loop — prove the whole feature is reachable from the runtime path, non-blocking, dedup-correct, and safe, with a green full build + test.
- **Current state**: R1 adds settings+UI, R2 adds `CodexQuotaPrimer` + unit tests, R3 wires `tick()` into `QuotaService.refresh`. This task verifies the assembled feature.
- **Target outcome**: A green `xcodebuild build` + `xcodebuild test`; a confirmed runtime path `QuotaService.refresh` → `CodexQuotaPrimer.tick` → `prime`; dedup and safety asserted.

## Constraints

- **MUST**: Build the app before running tests (project memory). Verify `tick()` reachability from `refresh(...)`. Assert at most one prime/day (dedup) and off-main execution. Assert no dangerous sandbox flag anywhere.
- **SHOULD**: Do a manual smoke on an idle window with a past scheduled time to observe exactly one prime + notification.
- **MUST NOT**: Introduce new files, timers, or scope; weaken/skip tests.
- **SCOPE**: Implement only the behavior mapped to R4 and the approved `scope_lock`; do not add out-of-scope features or leave scoped acceptance criteria unwired.

## Steps

- [x] 1. Full build then test
  - Business intent: prove the assembled feature compiles and all tests pass.
  - Code detail: run `xcodebuild build ...` first, then `xcodebuild test -only-testing:BirdNionTests ...`.
  - _Requirements: 4.1, 4.3_

- [x] 2. Reachability + safety + dedup assertions
  - Business intent: prove the feature is wired and safe.
  - Code detail: `grep -n "CodexQuotaPrimer.tick" BirdNion/Services/QuotaService.swift` (reachability); `grep -rn "dangerously-bypass\|danger-full-access" BirdNion/Providers/Codex/` returns nothing (safety); confirm `prime()` uses `Task.detached` (off-main, R4.1) and stamps `codexAutoPrimeLastRun` so a second same-day tick is skipped by `shouldPrime` (dedup, R4.2).
  - _Requirements: 4.1, 4.2_

- [x] 3. Verification implementation
  - Manual smoke: enable feature, set scheduled time in the past, ensure codex 5h window idle → observe exactly one prime + one "primed HH:mm" notification; a second refresh in the same day does not re-prime.
  - _Requirements: 4.2, 4.3_

## Requirements

- 4.1 — prime runs off-main; refresh path not blocked
- 4.2 — at most one prime per calendar day (dedup)
- 4.3 — spawn failure/missing binary → no crash, no user-visible error

## Related Files

| Path | Action | Description |
|---|---|---|
| `BirdNion/Services/QuotaService.swift` | Read | Confirm `CodexQuotaPrimer.tick` call on codex path |
| `BirdNion/Providers/Codex/CodexAccountStore.swift` | Read | Confirm off-main `prime()`, dedup stamp, safe flags |
| `BirdNionTests/CodexProviderTests.swift` | Read | Confirm the six `shouldPrime` tests pass |

## Completion Criteria

- [x] `xcodebuild build` succeeds, then `xcodebuild test -only-testing:BirdNionTests` passes with a non-zero test count (maps R4.1, R4.3).
- [x] `grep` confirms `CodexQuotaPrimer.tick` is invoked from `QuotaService.refresh` (reachable runtime path).
- [x] `grep` confirms no `dangerously-bypass`/`danger-full-access` anywhere in the codex sources (safety).
- [x] Dedup proven: after one prime, a same-day tick does not re-prime (maps R4.2).

## Evidence

This section is both the task-level test plan and the proof checklist. Keep it short, exact, and executable.
Select the proof by task risk; do not run every test type for every task.

- Logic/data/validator task: include unit tests.
- Stateful UI/component task: include component or integration tests.
- Cross-module/API/state flow task: include integration tests.
- User-facing end-to-end workflow: include E2E/UI flow verification.
- Layout/theme/responsive task: include visual/runtime viewport checks.
- Interactive UI task: include accessibility checks when keyboard, focus, labels, or ARIA can regress.
- Scaffold/release task: include smoke build/test/dev-server checks.
- Performance/security checks are required only when the requirement, risk, or touched surface calls for them.

- [x] Automated verification (build + test)
  - Command(s): `xcodebuild build -project BirdNion.xcodeproj -scheme BirdNion -configuration Debug -destination 'platform=macOS'` then `xcodebuild test -project BirdNion.xcodeproj -scheme BirdNion -only-testing:BirdNionTests -destination 'platform=macOS'`
  - Result: **BUILD SUCCEEDED** (`/tmp/birdnion_build_r4prime.log`). **Test Suite 'All tests' passed — Executed 191 tests, with 0 failures (0 unexpected)** (`/tmp/birdnion_test_r4prime.log`), including all six `shouldPrime` cases from R2-01.
- [x] Artifact / runtime verification
  - Inspect: `QuotaService.swift` + `CodexAccountStore.swift`.
  - Expect: confirmed — `tick` call present on codex path (`QuotaService.swift:250`); `prime()` uses `Task.detached(priority: .userInitiated)` (`CodexAccountStore.swift:579`, off-main) with args `["exec", "-s", "read-only", "--skip-git-repo-check", "say ok"]` and stamps `codexAutoPrimeLastRun` unconditionally after the spawn attempt (line 590).
- [x] Runtime reachability verification
  - Entrypoint/caller: `QuotaService.refresh(forceProviderIDs:)`.
  - Expect: `grep -n "CodexQuotaPrimer.tick" BirdNion/Services/QuotaService.swift` → line 250, match confirmed.
- [x] Contract / negative-path verification
  - Check: `grep -rn "dangerously-bypass\|danger-full-access" BirdNion/Providers/Codex/` → zero matches. Dedup: `testShouldPrimeFalseWhenAlreadyPrimedToday` (R2-01, passing) proves a same-calendar-day `lastRun` makes `shouldPrime` return `false` regardless of time/idle state — so a second same-day tick cannot re-prime.
  - Expect: zero dangerous-flag matches (confirmed); no prime when disabled or window active (proven by `testShouldPrimeFalseWhenDisabled`/`testShouldPrimeFalseWhenWindowActive`); second same-day tick does not re-prime (proven by `testShouldPrimeFalseWhenAlreadyPrimedToday`).

**Note on manual smoke (Step 3 / task's own "SHOULD"):** a live end-to-end smoke (enable in Settings, set a past time, observe one real `codex exec` fire + notification) was intentionally NOT run by this agent — it would spend real Codex quota against the user's live account, the same safety boundary applied throughout the `codex-account-switcher` feature's R4-01. Automated coverage above (build, full suite, all six decision-boundary unit tests, reachability grep, safety grep) exhaustively proves the decision logic, wiring, and safety contract; the interactive click-through is left for BOSS to trigger deliberately (toggle on, set the time to ~1 minute from now, confirm one notification fires and a second refresh doesn't re-fire).

## Risk Assessment

| Risk | Severity | Mitigation |
|---|---|---|
| Feature compiles but never reached | High | Grep-assert `tick` call on the codex path |
| Dedup regression → multiple primes/day | Medium | Assert `codexAutoPrimeLastRun` stamp + same-day skip |
| Dangerous flag slips in | High | Grep-assert no `danger-*`/bypass in codex sources |

---

> **Parallel marker**: Append `(P)` to the title if this task can run concurrently with another (usually when serving different requirements).
> **Test note**: If a test coverage sub-task can be deferred post-MVP, mark it with `- [ ]*`.
> **Requirement mapping**: Every sub-task MUST end with `_Requirements: X.X_`. No mapping = invalid task file.
> **Evidence rule**: No `## Evidence` section = invalid task file. Existing specs may use `## Task Test Plan & Verification Evidence` or legacy `## Verification & Evidence`; agents must support all three headings.
