# Task R1-03: QuotaService

**Requirement:** R2 + R5 — Polling, cache, parallel fetch, error isolation
**Status:** pending
**Priority:** P1
**Estimated Effort:** M
**Dependencies:** tasks/task-R0-03-models-and-protocol.md, tasks/task-R1-01-minimax-provider.md, tasks/task-R1-02-hapo-hub-provider.md
**Spec:** specs/ai-statusbar/

## Context

- **Why**: The popover must refresh quota every 120s (Validate interview) without blocking the UI. `QuotaService` owns the timer, calls providers in parallel, isolates errors, and publishes the latest snapshot to SwiftUI views.
- **Current state**: Providers from R1-01 and R1-02 exist; no orchestrator.
- **Target outcome**: `AIStatusbar/Services/QuotaService.swift` with `@MainActor final class QuotaService: ObservableObject` exposing `@Published private(set) var statuses: [ProviderStatus]`. `start()` launches a 60s loop, `stop()` cancels it, `refresh()` forces an immediate poll. One integration test runs 2 cycles against 2 fake providers and asserts the cache updates.

## Constraints

- **MUST**: Loop period 120s with ±10s jitter.
- **MUST**: Use `TaskGroup` to call every provider's `fetch()` in parallel.
- **MUST**: A throwing provider is caught and recorded as `ProviderStatus(error: ...)`; never propagates.
- **MUST NOT**: Run polling when the popover has been closed for > 5 minutes (battery). Acceptable simplification: keep polling in v1; revisit if battery is an issue.
- **SCOPE**: Service file + 1 integration test. UI consumption is R2-02.

## Steps

- [ ] 1. Add `AIStatusbar/Services/QuotaService.swift` with the `@MainActor ObservableObject` and `@Published statuses`.
  - Business intent: single source of truth for quota in the UI.
  - Code detail: `init(providers: [QuotaProvider], interval: TimeInterval = 120)` (Validate interview: 120s + 10s jitter); `start()` spawns a detached `Task` that loops with `try? await Task.sleep(...)`; `stop()` cancels the task.
  - _Requirements: 2.1, 2.2, 5.1, 5.2, 12.1_

- [ ] 2. Implement `refresh()` using `withTaskGroup`: each provider runs in a child task; on completion (or throw) update `statuses` on the main actor.
  - Business intent: parallel fetch, error isolation.
  - Code detail: `for await result in group { ... }`; throwing providers fall back to `ProviderStatus(id: p.id, displayName: p.displayName, windows: [], lastUpdated: Date(), error: "...")`.
  - _Requirements: 2.3, 5.1, 5.2, 12.1_

- [ ] 3. Add jitter: `interval + Double.random(in: -5...5)` per cycle.
  - Business intent: prevents synchronized spikes from many users.
  - Code detail: `let jittered = max(10, interval + Double.random(in: -5...5))`.
  - _Requirements: 5.1, 10.2_

- [ ] 4. Add `AIStatusbarTests/QuotaServicePollingTests.swift` with 1 integration test: instantiate `QuotaService` with 2 fake providers (one always returns 2 windows, one always throws), run 2 cycles with interval = 0.1s, assert `statuses.count == 2`, the happy provider has 2 windows, the throwing provider has `error != nil`.
  - Business intent: proves the orchestration contract.
  - Code detail: `await service.refresh(); await service.refresh()` (faster than waiting for the timer).
  - _Requirements: 2.3, 5.1, 12.1_

- [ ] 5. Verification.
  - _Requirements: 5.1, 5.2, 12.1_

## Requirements

- 2.1 — `QuotaProvider` protocol.
- 2.2 — `QuotaService` instantiates every enabled provider from the persisted list.
- 2.3 — A throwing `fetch()` records the error on the `ProviderStatus`.
- 5.1 — Parallel fetch every 120s ±10s jitter.
- 5.2 — `@Published [ProviderStatus]` updates within 200ms of fetch.
- 10.2 — At most 2 HTTP calls per cycle.
- 12.1 — Provider failures do not crash.

## Related Files

| Path | Action | Description |
|---|---|---|
| `AIStatusbar/Services/QuotaService.swift` | Create | `QuotaService` `ObservableObject` |
| `AIStatusbarTests/QuotaServicePollingTests.swift` | Create | 1 integration test |
| `AIStatusbar.xcodeproj/project.pbxproj` | Modify | Add new sources + test file |

## Completion Criteria

- [ ] `xcodebuild test` reports 1/1 in `QuotaServicePollingTests` passing.
- [ ] `QuotaService` is annotated `@MainActor` (grep `@MainActor` in service file).
- [ ] `refresh()` uses `withTaskGroup` (grep `withTaskGroup` in service file).
- [ ] `start()` spawns a single detached `Task`; calling `start()` twice does not spawn a second loop (the previous task is cancelled).

## Evidence

- [ ] Automated verification
  - Command(s): `xcodebuild test -scheme AIStatusbar -destination 'platform=macOS' -only-testing:AIStatusbarTests/QuotaServicePollingTests 2>&1 | tail -30`
  - Expected proof: 1/1 pass, exit 0.
- [ ] Artifact / runtime verification
  - Inspect: `AIStatusbar/Services/QuotaService.swift` (Read tool).
  - Expect: `@MainActor`, `@Published`, `withTaskGroup`, jitter math.
- [ ] Runtime reachability verification
  - Entrypoint/caller: `QuotaPanel` (R2-02) will observe `QuotaService.statuses`.
  - Expect: `statuses` is readable from a SwiftUI view bound via `@StateObject` or `@ObservedObject`.
- [ ] Contract / negative-path verification
  - Check: provider that always throws → status with `error` set, no crash.
  - Expect: `statuses.first(where: { $0.error != nil }) != nil`.

## Risk Assessment

| Risk | Severity | Mitigation |
|---|---|---|
| Timer task leaks if `stop()` not called | Medium | `start()` stores the `Task` and `stop()` calls `cancel()`; `deinit` also calls `cancel()`. |
| Many providers in the future | Low | `withTaskGroup` scales; rate limiting is a future concern. |
| Sleep cancellation races | Low | `Task.sleep(...)` is cancellation-aware; on cancel the loop exits cleanly. |
