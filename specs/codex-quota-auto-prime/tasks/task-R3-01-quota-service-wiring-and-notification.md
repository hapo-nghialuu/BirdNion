# Task R3-01: QuotaService wiring + optional prime notification

**Requirement:** R3 — QuotaService Wiring & Optional Notification
**Status:** done
**Priority:** P2
**Estimated Effort:** S
**Dependencies:** tasks/task-R2-01-primer-engine-and-tests.md
**Spec:** specs/codex-quota-auto-prime/

## Context

- **Why**: Priming must happen during normal operation with no new polling loop; catch-up comes free from the awake refresh cadence.
- **Current state**: `QuotaService.refresh(forceProviderIDs:)` (line 209) already runs a codex-only branch (`if due.contains(where: { $0.id == "codex" })`, line 232) and calls `CodexAccountStore.reconcileCLISyncBack()`. `statuses` holds `ProviderStatus(id:"codex")` with `QuotaWindow(label:"5 giờ", usedPct:)`. `QuotaNotifier.post(id:title:body:)` (line 483) + `import UserNotifications` (line 4) exist.
- **Target outcome**: One `await CodexQuotaPrimer.tick(...)` call on the codex refresh path, reading the codex 5h `usedPct`, plus an optional localized "primed HH:mm" notification after a successful prime.

## Constraints

- **MUST**: Call `CodexQuotaPrimer.tick(windowUsedPct:now:)` exactly once per refresh cycle on the codex-due path, reusing the existing cadence (no new Timer/polling loop). Read `usedPct` from the current codex `ProviderStatus.windows` where `label == "5 giờ"`. Post the notification via existing `QuotaNotifier`. Never log token/credential/response content.
- **SHOULD**: Pass `now = Date()` from the wiring layer (keeping `shouldPrime` pure). Derive `windowUsedPct` as `nil` when the codex window/usedPct is unavailable.
- **MUST NOT**: Add a new Timer, polling loop, or background task; block the UI-affecting refresh path; change `ProviderStatus`/`QuotaProvider` signatures.
- **SCOPE**: Implement only the behavior mapped to R3 and the approved `scope_lock`; do not add out-of-scope features or leave scoped acceptance criteria unwired.

## Steps

- [x] 1. Wire `tick()` into the codex refresh path in `QuotaService.swift`
  - Business intent: prime automatically on the existing cadence; catch-up for free.
  - Code detail: at/after the existing codex branch (line 232), compute `let codexUsed = statuses.first(where: { $0.id == "codex" })?.windows.first(where: { $0.label == "5 giờ" })?.usedPct` and `await CodexQuotaPrimer.tick(windowUsedPct: codexUsed, now: Date())`. Keep it on the codex-due path so it runs once per refresh cycle.
  - _Requirements: 3.1, 3.2, 3.3_

- [x] 2. Post the optional prime notification
  - Business intent: tell the user the 5h window was activated.
  - Code detail: after a successful prime (inside `CodexQuotaPrimer.prime` on `terminationStatus == 0`, or returned to the wiring layer), call `QuotaNotifier.post(id: "codex.autoPrime", title: <L10n>, body: L10n.f("notification.codexPrimed", nil, <HH:mm>))`. Use the `notification.codexPrimed` key added in R1 (vi+en). No token/response content in title/body/logs.
  - _Requirements: 3.4, 3.5_

- [x] 3. Verification implementation
  - Build + run tests; confirm via trace/grep that `CodexQuotaPrimer.tick` is invoked from `QuotaService.refresh`; manual smoke: enable feature with a past time on an idle window and observe one prime + notification.
  - _Requirements: 3.1, 3.4_

## Requirements

- 3.1 — `tick(...)` called once per refresh cycle on the codex path (no new loop)
- 3.2 — `tick` reads codex 5h `usedPct` + settings, evaluates `shouldPrime`, primes only when true
- 3.3 — catch-up: past-scheduled + not-primed-today + idle → primes on next awake tick
- 3.4 — optional localized "primed HH:mm" notification via `QuotaNotifier`
- 3.5 — no token/credential/response logging

## Related Files

| Path | Action | Description |
|---|---|---|
| `BirdNion/Services/QuotaService.swift` | Modify | Call `CodexQuotaPrimer.tick(...)` on codex path; post notification |
| `BirdNion/Providers/Codex/CodexAccountStore.swift` | Modify | `prime()` returns/triggers success signal for notification |
| `BirdNion/Models/ProviderStatus.swift` | Read | `QuotaWindow.label "5 giờ"` + `usedPct` source |

## Completion Criteria

- [x] `CodexQuotaPrimer.tick(...)` is invoked exactly once per refresh cycle from the codex-due path (maps R3.1).
- [x] `tick` reads codex 5h `usedPct` and settings and primes only when `shouldPrime` is true (maps R3.2).
- [x] Catch-up proven: with a past scheduled time, no prime today, idle window → the next tick primes (maps R3.3).
- [x] Successful prime posts a localized "primed HH:mm" notification; no secret content logged; no new polling loop (maps R3.4–3.5).

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

- [x] Automated verification (build + tests)
  - Command(s): `xcodebuild build -project BirdNion.xcodeproj -scheme BirdNion -configuration Debug -destination 'platform=macOS'` then `xcodebuild test -project BirdNion.xcodeproj -scheme BirdNion -only-testing:BirdNionTests -destination 'platform=macOS'`
  - Result: **BUILD SUCCEEDED** (`/tmp/birdnion_build_r3prime.log`). **191/191 tests pass, 0 failures** (`/tmp/birdnion_test_r3prime.log`) — no regressions vs. pre-wiring baseline.
- [x] Artifact / runtime verification
  - Inspect: `QuotaService.swift` codex-due branch (lines 232-256).
  - Expect: confirmed — `await CodexQuotaPrimer.tick(windowUsedPct: codexUsedPct, now: now)` present at line 250, reading `.windows.first(where: { $0.label == "5 giờ" })?.usedPct` at line 248.
- [x] Runtime reachability verification
  - Entrypoint/caller: `QuotaService.refresh(forceProviderIDs:)`.
  - Expect: `grep -n "CodexQuotaPrimer.tick" BirdNion/Services/QuotaService.swift` → line 250, on the codex-due path (guarded by `if due.contains(where: { $0.id == "codex" })`).
- [x] Contract / negative-path verification
  - Check: `tick()` (R2-01) returns `false` immediately when `enabled == false` or `windowUsedPct > 0`, before any process spawn — verified in R2-01's unit tests, unchanged here. Notification only posts when `tick` returns `true` (line 251).
  - Expect: no prime when disabled/active (confirmed by R2 unit tests + this wiring's `if` gate); no secret content logged — `QuotaNotifier.post` body is only a formatted `HH:mm` time string, never token/response content.

## Risk Assessment

| Risk | Severity | Mitigation |
|---|---|---|
| `tick` runs more than once per cycle | Medium | Place single call on the codex-due branch only |
| Reading wrong window (`usedPct`) | Low | Match `label == "5 giờ"` exactly |
| Blocking refresh path | Medium | `prime()` is off-main via `Task.detached` |

---

> **Parallel marker**: Append `(P)` to the title if this task can run concurrently with another (usually when serving different requirements).
> **Test note**: If a test coverage sub-task can be deferred post-MVP, mark it with `- [ ]*`.
> **Requirement mapping**: Every sub-task MUST end with `_Requirements: X.X_`. No mapping = invalid task file.
> **Evidence rule**: No `## Evidence` section = invalid task file. Existing specs may use `## Task Test Plan & Verification Evidence` or legacy `## Verification & Evidence`; agents must support all three headings.
