# Task 06 — UsageReportCoordinator module

Status: done

## Outcome

New `UsageReportCoordinator` owns cache TTL + single-flight for the 7 local cost scanners (Claude, Codex, Grok, Kiro, OMP, Pi, Devin). Typed methods per source (`claudeReport() async -> ClaudeUsageReport?`, …) backed by a generic `SingleFlightCache<T>` so concurrent callers share one scan. `MainActor`-isolated state, async scans off-main.

## Scope

- In: new `BirdNion/Services/UsageReportCoordinator.swift`, new `BirdNionTests/UsageReportCoordinatorTests.swift`, `project.pbxproj`.
- Out: scanner internals/parsers; call-site rewiring (task-07); `CostHistoryStore`; Linux.

## Coverage

- CP-07

## Ownership

- create `BirdNion/Services/UsageReportCoordinator.swift`
- create `BirdNionTests/UsageReportCoordinatorTests.swift`
- modify `BirdNion.xcodeproj/project.pbxproj`

## Acceptance

- AC-07
- Per-source: one in-flight scan max — concurrent callers await the same `Task`; result fans out to all waiters.
- TTL respected per scanner (300s Claude/Codex/Grok/Kiro/OMP/Pi/Devin — keep each scanner's existing constant as the coordinator's TTL source of truth; scanners' internal caches stay as a second layer, no conflict).
- Failed scan ⇒ no cache write; next caller retries (no poisoned cache).
- Typed API surface: one method per source returning the concrete report type — no `Any`/`AnyObject` erasure.
- `CombinedUsageReport.build` callers unchanged in task-06 (rewire is task-07).

## Dependencies

- none

## Verification Plan

- Command: `cd /Users/nghialuutrung/Desktop/birdnion && xcodebuild test -scheme BirdNion -destination 'platform=macOS' -only-testing:BirdNionTests/UsageReportCoordinatorTests`
- Named probe: `StubScan` counting invocations with a controllable delay — fire 5 concurrent `claudeReport()` calls; assert scan count == 1 and all callers receive the same value. Then fire a post-TTL call; assert a second scan.
- Reachability: unit-level; coordinator takes scanner closures via init injection for tests.
- Oracle: invocation counter == 1 under concurrency; == 2 after TTL expiry; == 2 after a failed first scan.
- Counterexample: a test asserting scan count > 1 for concurrent same-source callers — must fail.
- Artifacts: coordinator + test file, test log.

## Receipt

- Command: `cd /Users/nghialuutrung/Desktop/birdnion && xcodebuild test -scheme BirdNion -destination 'platform=macOS' -only-testing:BirdNionTests/UsageReportCoordinatorTests`
- Exit: 0
- Verification: PASS
- Base: `bb3569005810c9a4de2b3580981fbc0de8ca4915`
- Head: `bb3569005810c9a4de2b3580981fbc0de8ca4915` + working-tree changes (`UsageReportCoordinator.swift`, `UsageReportCoordinatorTests.swift`, pbxproj registration)
- Output:

```text
Test Suite 'UsageReportCoordinatorTests' passed — Executed 7 tests, 0 failures
** TEST SUCCEEDED **
```

- Negative/reachability proof: `testConcurrentCallersShareOneScan` fires 5 concurrent `claudeReport()` calls through a counting stub gated by a 100ms sleep — asserts scan count == 1 and all callers receive the identical report, so a non-deduped implementation fails. `testLateCallerJoinsInFlightScan` proves a caller arriving mid-scan shares the in-flight task. `testFailedScanIsNotCached` caught a fixture-level masking bug (nil stub swallowed by `?? report()` default) — fixed so the nil result propagates and the retry assertion is real. `testPostTTLCallRescans` uses an injected clock (299s hit / 301s miss) — TTL boundary verified without real waiting.
- Limitations: coordinator-level TTL is a single 300s constant mirroring the scanners' private `cacheTTL` values (they stay `private`, per out-of-scope); per-scanner divergence would need visibility widening in a later task. Call-site rewiring is task-07 — the coordinator is currently unused by production callers by design.
