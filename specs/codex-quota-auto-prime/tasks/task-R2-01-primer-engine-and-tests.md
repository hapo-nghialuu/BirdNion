# Task R2-01: CodexQuotaPrimer engine (pure decision + executor) & unit tests

**Requirement:** R2 — Prime Decision Engine (Pure) & Executor
**Status:** done
**Priority:** P2
**Estimated Effort:** M
**Dependencies:** tasks/task-R1-01-settings-and-codex-ui.md
**Spec:** specs/codex-quota-auto-prime/

## Context

- **Why**: The prime timing must be deterministic and unit-testable, and the request must be harmless.
- **Current state**: `CodexAccountStore.swift` has `codexBinary()` (line 229) and the off-main `Process` spawn idiom in `runLogin(homePath:)` (line 242): `Task.detached(priority:.userInitiated)`, `executableURL`, `arguments`, env, `Pipe()`, `waitUntilExit()`, `terminationStatus`. `systemAuthURL()` (line 36) = `~/.codex/auth.json`. Settings keys land from R1. `codex-cli 0.143.0` supports `codex exec -s read-only --skip-git-repo-check <PROMPT>`.
- **Target outcome**: A new `CodexQuotaPrimer` type inside `CodexAccountStore.swift` with a pure `shouldPrime(...)`, an off-main `prime(now:)`, and a `tick(windowUsedPct:now:)`; plus unit tests for all six R2 decision cases.

## Constraints

- **MUST**: Host `CodexQuotaPrimer` inside the existing `CodexAccountStore.swift` (no new file). `shouldPrime` MUST be pure (no I/O, no ambient `Date()`; `now` injected). `prime()` MUST run off-main, target current `~/.codex` (no `CODEX_HOME`), use `-s read-only` + `--skip-git-repo-check` + a trivial prompt, and stamp `codexAutoPrimeLastRun = now` after the spawn attempt. Same-day dedup MUST use `Calendar.current.isDate(_:inSameDayAs:)`.
- **SHOULD**: Mirror `runLogin`'s spawn structure; guard `codexBinary()` and no-op if missing.
- **MUST NOT**: Use `--dangerously-bypass-approvals-and-sandbox` or any `danger-*` sandbox mode; log token/credential/response content; add a new `.swift` file.
- **SCOPE**: Implement only the behavior mapped to R2 and the approved `scope_lock`; do not add out-of-scope features or leave scoped acceptance criteria unwired.

Contracts: ShouldPrimeSignature

<!-- contract:ShouldPrimeSignature -->
```swift
// Pure decision: no I/O, no ambient Date(); `now` is injected.
// windowUsedPct: nil or 0 => idle (may prime). >0 => active (skip).
func shouldPrime(now: Date,
                 lastRun: Double,          // epoch seconds; 0 = never
                 scheduledMinutes: Int,    // 0..1439 minutes since midnight
                 windowUsedPct: Int?,      // codex 5h usedPct; nil = unknown/idle
                 enabled: Bool) -> Bool
```

## Steps

- [x] 1. Add the pure `shouldPrime(...)` decision to `CodexQuotaPrimer` in `CodexAccountStore.swift`
  - Business intent: deterministic gate covering enabled, idle-skip, before-time, already-primed, and on-time/catch-up.
  - Code detail: implement `ShouldPrimeSignature` verbatim. Order: return `false` if `!enabled`; `false` if `windowUsedPct != nil && windowUsedPct! > 0`; compute `nowMinutes = hour*60+minute` of `now` (via `Calendar.current`) and return `false` if `nowMinutes < scheduledMinutes`; return `false` if `lastRun > 0 && Calendar.current.isDate(Date(timeIntervalSince1970: lastRun), inSameDayAs: now)`; otherwise `true`.
  - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, 2.6_

- [x] 2. Add `prime(now:)` executor to `CodexQuotaPrimer`
  - Business intent: harmlessly start the 5h clock on the current CLI identity.
  - Code detail: `guard let binary = CodexAccountStore.codexBinary() else { return }`. Off-main `Task.detached(priority:.userInitiated)`: `process.executableURL = URL(fileURLWithPath: binary)`; `process.arguments = ["exec", "-s", "read-only", "--skip-git-repo-check", "say ok"]`; do NOT set `CODEX_HOME` (targets current `~/.codex`); `Pipe()` stdout/stderr; `try? process.run(); process.waitUntilExit()`. After the attempt, set `UserDefaults.standard.set(now.timeIntervalSince1970, forKey: "codexAutoPrimeLastRun")`. No token/response logging.
  - _Requirements: 2.7, 2.8, 2.9, 2.10, 5.1, 5.2_

- [x] 3. Add `tick(windowUsedPct:now:)` to `CodexQuotaPrimer`
  - Business intent: single entry from the refresh cycle.
  - Code detail: read `codexAutoPrimeEnabled`, `codexAutoPrimeMinutes`, `codexAutoPrimeLastRun` from `UserDefaults.standard`; if `shouldPrime(now:lastRun:scheduledMinutes:windowUsedPct:enabled:)` is `true`, `await prime(now:)`. (Notification is wired in R3.) Opt-in: when `codexAutoPrimeEnabled` is `false`, `shouldPrime` returns `false` so nothing is primed.
  - _Requirements: 2.1, 5.3_

- [x] 4. Verification implementation — unit tests in `BirdNionTests/CodexProviderTests.swift`
  - Add six `shouldPrime` cases: on-time+idle→true; window active (`usedPct>0`)→false; already-primed-today→false; before-scheduled→false; past-scheduled+not-primed+idle→true (catch-up); disabled→false. Use fixed injected `now`/`lastRun` dates (no ambient `Date()`).
  - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, 2.6_

## Requirements

- 2.1 — `shouldPrime` is pure (no I/O, `now` injected)
- 2.2 — disabled → false
- 2.3 — window active (`usedPct>0`) → false
- 2.4 — before scheduled time → false
- 2.5 — already primed today (same calendar day) → false
- 2.6 — enabled + at/after scheduled + not primed today + idle → true (on-time & catch-up)
- 2.7 — `prime()` off-main, current `~/.codex`, no `CODEX_HOME`
- 2.8 — `-s read-only` + `--skip-git-repo-check` + trivial prompt; never dangerous bypass
- 2.9 — missing binary → no-op, no stamp, no crash
- 2.10 — stamp `codexAutoPrimeLastRun = now` after spawn attempt
- 5.1 — read-only sandbox + `--skip-git-repo-check`; never dangerous bypass
- 5.2 — trivial harmless prompt ("say ok")
- 5.3 — opt-in: never prime while disabled

## Related Files

| Path | Action | Description |
|---|---|---|
| `BirdNion/Providers/Codex/CodexAccountStore.swift` | Modify | Add `CodexQuotaPrimer` type (shouldPrime/prime/tick) |
| `BirdNionTests/CodexProviderTests.swift` | Modify | Add six `shouldPrime` unit tests |

## Completion Criteria

- [x] `CodexQuotaPrimer.shouldPrime(...)` matches `ShouldPrimeSignature` verbatim and is pure (maps R2.1–2.6).
- [x] `prime(now:)` spawns `codex exec -s read-only --skip-git-repo-check "say ok"` off-main against current `~/.codex` and stamps `codexAutoPrimeLastRun` (maps R2.7–2.10, R5.1–5.2).
- [x] Missing `codex` binary → `prime()` no-ops without crash or stamp (maps R2.9).
- [x] Six unit tests pass; no orphaned type — `tick(...)` exists for the R3 caller (reachability completed in R3).

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

- [x] Automated verification (build + unit tests)
  - Command(s): `xcodebuild build -project BirdNion.xcodeproj -scheme BirdNion -configuration Debug -destination 'platform=macOS'` then `xcodebuild test -project BirdNion.xcodeproj -scheme BirdNion -only-testing:BirdNionTests/CodexProviderTests -destination 'platform=macOS'`
  - Result: **BUILD SUCCEEDED** (`/tmp/birdnion_build_r2prime.log`). **Test Suite 'CodexProviderTests' passed** (`/tmp/birdnion_test_r2prime.log`) — all six new tests pass: `testShouldPrimeOnTimeAndIdle`, `testShouldPrimeFalseWhenWindowActive`, `testShouldPrimeFalseWhenAlreadyPrimedToday`, `testShouldPrimeFalseBeforeScheduledTime`, `testShouldPrimeCatchUpPastScheduledNotYetPrimed`, `testShouldPrimeFalseWhenDisabled`.
- [x] Artifact / runtime verification
  - Inspect: `BirdNion/Providers/Codex/CodexAccountStore.swift` — `CodexQuotaPrimer` enum present (after `reconcileCLISyncBack`) with `shouldPrime`/`prime`/`tick`.
  - Expect: confirmed by `grep -n '"exec", "-s", "read-only"' BirdNion/Providers/Codex/CodexAccountStore.swift` → line 450, args array exactly `["exec", "-s", "read-only", "--skip-git-repo-check", "say ok"]`; no `CODEX_HOME` key set anywhere inside `prime()` (grep count 0).
- [x] Runtime reachability verification
  - Entrypoint/caller: `tick(windowUsedPct:now:)` exists as the R3 wiring entry (invoked from `QuotaService.refresh` in R3-01).
  - Expect: type compiles and `tick` is callable (confirmed by successful build); full reachability closed in R3-01.
- [x] Contract / negative-path verification
  - Check: `grep -n "dangerously-bypass\|danger-full-access" BirdNion/Providers/Codex/CodexAccountStore.swift` → zero matches.
  - Expect: confirmed; `prime()` guards `codexBinary()` first and returns before spawning/stamping when missing.

## Risk Assessment

| Risk | Severity | Mitigation |
|---|---|---|
| Impure `shouldPrime` (reads `Date()`) | Medium | Inject `now`; unit tests use fixed dates |
| Transient `usedPct==0` right after reset | Low | Same-day dedup caps to one prime/day |
| Wrong/unsafe codex flags | High | Assert exact args; forbid `danger-*`/bypass; grep in evidence |

---

> **Parallel marker**: Append `(P)` to the title if this task can run concurrently with another (usually when serving different requirements).
> **Test note**: If a test coverage sub-task can be deferred post-MVP, mark it with `- [ ]*`.
> **Requirement mapping**: Every sub-task MUST end with `_Requirements: X.X_`. No mapping = invalid task file.
> **Evidence rule**: No `## Evidence` section = invalid task file. Existing specs may use `## Task Test Plan & Verification Evidence` or legacy `## Verification & Evidence`; agents must support all three headings.
