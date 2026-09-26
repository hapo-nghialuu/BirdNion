# Task 02 — ProviderLane + ProviderScheduler

Status: done

## Outcome

New `ProviderScheduler` owns one `ProviderLane` per provider id. Each lane owns `lastFetchedAt`, `adaptiveFailureStreak`, `errorSurfaceGate`, `contextGeneration`, `warnState`, `staleWarning`, `failureEpisode` state, an in-flight task, and a pending force-follow-up flag. Lanes run independently — no whole-pass serialization. `MainActor`-isolated, matching the current `QuotaService` threading model.

## Scope

- In: new `BirdNion/Services/ProviderScheduler.swift` (Lane + Scheduler in one file), new `BirdNionTests/ProviderSchedulerTests.swift`, `project.pbxproj`.
- Out: `QuotaService` rewire (task-03); provider internals; UI.

## Coverage

- CP-02

## Ownership

- create `BirdNion/Services/ProviderScheduler.swift`
- create `BirdNionTests/ProviderSchedulerTests.swift`
- modify `BirdNion.xcodeproj/project.pbxproj`
- read `BirdNion/Services/QuotaService.swift` (semantics source only — no edit)

## Acceptance

- AC-02, AC-03, AC-06, AC-09
- Lane semantics (ported, not redesigned):
  - `kick(force:interaction:)` — in-flight ⇒ return existing task; if a forced request lands on a background in-flight fetch, mark `pendingForce` and re-kick after it completes (unless the in-flight fetch already succeeded as userInitiated).
  - Adaptive backoff ×1/×2/×4/×8 on core-emission outcomes only; enrichment outcomes never affect the streak.
  - Error-surface gate + per-provider interval override (`refreshInterval.<id>` UserDefaults) preserved.
  - Deadline: time-to-first-emission bounded (60s background / 120s manual) via resume-once wrapper; overrun ⇒ timeout status published as the lane's result. Stream tail bounded by extrasDeadline (30s).
  - Context generation: emissions stamped with the generation at kick; stale-generation results are dropped (account-switch protection — machinery at `QuotaService.swift:115, :548-558, :682-768`).
  - Lane in-flight = kick → stream end or `extrasDeadline`: a second kick must not start a parallel fetch while extras are still pending; the card publishes core at emission 0 while the lane (and indicator) stays active until the stream settles.
  - `onBatchSettled` fires once per scheduler tick — including zero-due-lane ticks — after that tick's kicked lanes all settle (preserves the current every-pass WeeklyDigest call at `QuotaService.swift:838` gated by `WeeklyDigest.isDue` `:888-891`).
  - Last-good preservation on error emissions (`QuotaService.swift:695-726` semantics) moves into lane merge.
- Scheduler: `tick(dueProviderIDs)` kicks due lanes; `refreshAll(force:)`; `refresh(ids:force:)`; `isRefreshing`/`fetchingIDs` derived; `onBatchSettled` callback when a tick's kicked lanes all settle (hook for WeeklyDigest/Antigravity, replacing post-pass hooks).
- Single-flight guarantee per lane, cancellation-safe, resume-once.

## Dependencies

- task-01-provider-status-stream.md

## Verification Plan

- Command: `cd /Users/nghialuutrung/Desktop/birdnion && xcodebuild test -scheme BirdNion -destination 'platform=macOS' -only-testing:BirdNionTests/ProviderSchedulerTests`
- Named probe: `ProbeScheduler` driving `StubStreamProvider`s with scripted delays/outcomes — one hangs > coreDeadline, one emits core+enrichment, one fails then succeeds.
- Reachability: unit-level; tests inject stub providers and a virtual clock seam for backoff/due math.
- Oracle: (a) forced kick on lane A completes while lane B still hangs; (b) 3 concurrent kicks on one lane yield exactly one underlying fetch; (c) hang past coreDeadline yields a timeout status, lane unblocks; (d) stale-generation emission is dropped.
- Counterexample: a test where lane B's in-flight fetch delays lane A's forced kick, or a lane runs two fetches concurrently — must fail.
- Artifacts: scheduler file + test file; xcodebuild log.

## Receipt

- Command: `cd /Users/nghialuutrung/Desktop/birdnion && xcodebuild test -scheme BirdNion -destination 'platform=macOS' -only-testing:BirdNionTests/ProviderSchedulerTests` (superset run also included `ProviderStatusStreamTests` + `QuotaServicePollingTests` for regression)
- Exit: 0
- Verification: PASS
- Base: `b7a2c34aeedcf9bd7aa6d46417a063b73cad2825`
- Head: `bb3569005810c9a4de2b3580981fbc0de8ca4915` + working tree — new `BirdNion/Services/ProviderScheduler.swift` (`ProviderLane` + `ProviderScheduler` + `ProviderFailureEpisode`), new `BirdNionTests/ProviderSchedulerTests.swift` (14 tests), pbxproj refs `PSCH…`/`PSCT…`. `QuotaService.swift` untouched (net-zero diff — ownership was read-only).
- Current output:

```text
Test Suite 'ProviderSchedulerTests' passed at 2026-09-22 23:24:…
	 Executed 14 tests, with 0 failures (0 unexpected) in 1.378 seconds
Test Suite 'QuotaServicePollingTests' passed …  Executed 49 tests, 0 failures
Test Suite 'BirdNionTests.xctest' passed … Executed 70 tests, 0 failures
** TEST SUCCEEDED **
```

- Negative/reachability proof: `testConcurrentKicksRunOneFetchPerLane` — 3 kicks (2 scheduler + 1 direct) yield `fetchCount == 1` (AC-03, counterexample oracle). `testForcedLaneCompletesWhileOtherLaneHangs` — forced lane resolves while sibling lane hangs until its own deadline (AC-02). `testCoreDeadlinePublishesTimeoutAndUnblocks` + `testTickDoesNotWaitAcrossLanes` — hang past core deadline publishes a `Timeout:` status and unblocks the lane (AC-09). `testStaleGenerationEmissionsDropped` — post-`invalidateContext` emission is dropped (AC-08). `testForceFollowUpAfterFailedInflight` / `testForceSatisfiedBySuccessfulInflight` — pending-force re-kicks only when the in-flight run didn't succeed (AC-04). `testExtrasEmissionMergesOntoCore` / `testExtrasAfterErrorCoreDropped` — enrichment merges via `withEnrichment`, extras after error core dropped (AC-10). `testAdaptiveBackoffGrowsWithFailures` + `testFailedLaneBacksOffUntilInterval` — ×1/×4 backoff on core-emission failures only (AC-05). `testTransientErrorPreservesLastGoodSnapshot` — transient error keeps last-good + sets `staleWarning` (AC-11). `testBatchSettledFiresEvenWhenNothingDue` — zero-due tick still settles (F-07). `testFetchingIDsTracksInFlightLanes` — derived refresh state (AC-06).
- Note: deadline enforcement uses a watchdog `Task.sleep` + in-flight cancel instead of a continuation wrapper — resume-once is inherent (no continuation to double-resume); same observable timeout-status semantics. `laneRenderableSnapshot` is a private mirror of `QuotaService.isRenderableSnapshot` (file-private there); task-03 unifies when it rewires the facade.
