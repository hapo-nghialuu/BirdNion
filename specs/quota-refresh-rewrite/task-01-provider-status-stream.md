# Task 01 — Provider status stream contract

Status: done

## Outcome

`QuotaProvider` gains `statuses(interaction:) -> AsyncStream<ProviderStatus>`: first emission is the core quota status, later emissions are enrichment patches. Providers that do not override keep working via a default implementation wrapping `fetch()`. `ProviderStatus` gains `withEnrichment(from:)` for merge-safe enrichment.

## Scope

- In: `BirdNion/Providers/QuotaProvider.swift`, `BirdNion/Models/ProviderStatus.swift`, new `BirdNionTests/ProviderStatusStreamTests.swift`, `BirdNion.xcodeproj/project.pbxproj`.
- Out: any provider's internals; `QuotaService` (rewire is task-03); Linux.

## Coverage

- CP-01

## Ownership

- modify `BirdNion/Providers/QuotaProvider.swift`
- modify `BirdNion/Models/ProviderStatus.swift`
- create `BirdNionTests/ProviderStatusStreamTests.swift`
- modify `BirdNion.xcodeproj/project.pbxproj`

## Acceptance

- AC-01, AC-05, AC-09 (contract level)
- Contract invariants (must be written into the protocol doc + tests):
  - Emission 0 = core: windows, account, plan, source label, error.
  - Emissions 1+ = enrichment: complete `ProviderStatus` snapshots with `error == nil`; the scheduler publishes them as-is.
  - An enrichment emission carrying `error != nil` is invalid and droppable by the consumer (defensive log, no publish).
  - Emitters must observe `Task.isCancelled` between phases; the stream ends on cancellation or provider completion.
  - Deadlines: consumer bounds time-to-first-emission (`coreDeadline`: 60s background / 120s userInitiated) and time-to-stream-end (`extrasDeadline`: 30s after first emission). Contract exposes these via the interaction/context, defaults centralized.
- `withEnrichment(from:)` merges only enrichment fields (version, serviceStatus, resetCredits, web extras, extraWindows/extraLabels); never overwrites core windows or error.
- Default `statuses(interaction:)` wraps `fetch()` into a single emission — every existing provider compiles and behaves identically.

## Dependencies

- none

## Verification Plan

- Command: `cd /Users/nghialuutrung/Desktop/birdnion && xcodebuild test -scheme BirdNion -destination 'platform=macOS' -only-testing:BirdNionTests/ProviderStatusStreamTests`
- Named probe: a `StubStreamProvider` emitting core then a delayed enrichment; a `StubWrappedProvider` using the default `fetch()` wrapper; a violating stub emitting `error` on emission 1.
- Reachability: unit-level; `ProviderStatusStreamTests` constructs stubs and a test consumer implementing the drop/merge rules.
- Oracle: consumer publishes core at emission 0 without awaiting enrichment; enrichment emission merges fields; error-carrying enrichment is dropped with core intact; wrapped provider yields exactly one emission.
- Counterexample: a test asserting the consumer blocks until stream end, or that an error-carrying enrichment overwrites the core status — must fail.
- Artifacts: new test file; xcodebuild test log.

## Receipt

- Command: `cd /Users/nghialuutrung/Desktop/birdnion && xcodebuild test -scheme BirdNion -destination 'platform=macOS' -only-testing:BirdNionTests/ProviderStatusStreamTests`
- Exit: 0
- Verification: PASS
- Base: `b7a2c34aeedcf9bd7aa6d46417a063b73cad2825`
- Head: working tree (uncommitted) — `QuotaProvider.swift` +`statuses(interaction:)` requirement; new `BirdNion/Providers/ProviderStatusStream.swift` (default impl + `ProviderFetchPhaseBudgets` 60s/120s core, 30s extras + `ProviderStatusEmissionPolicy`); `ProviderStatus.withEnrichment(from:)`; new `BirdNionTests/ProviderStatusStreamTests.swift`; pbxproj refs `PSTR…`/`PSTS…`.
- Current output:

```text
Test Suite 'ProviderStatusStreamTests' passed at 2026-09-22 23:05:06.999.
	 Executed 7 tests, with 0 failures (0 unexpected) in 0.174 (0.178) seconds
Test Suite 'BirdNionTests.xctest' passed at 2026-09-22 23:05:07.001.
** TEST SUCCEEDED **
```

- Negative/reachability proof: `testEnrichmentEmissionWithErrorIsDropped` proves index≥1 error emissions are dropped (AC-05); `testCoreEmissionArrivesBeforeEnrichmentResolves` proves emission 0 resolves while extras gate is closed (AC-01); `testCancellationEndsStream` proves termination cancels the inner task; `testDefaultWrapperMapsThrowToErrorStatus` proves the `fetch()` wrapper maps throws to error statuses identical to `fetchWithDeadline` semantics.
- Note: contract ships as non-throwing `AsyncStream` per spec; thrown `fetch()` errors become error statuses in the default impl. AC-09's deadline constants are defined in `ProviderFetchPhaseBudgets` — enforcement lands with the lane (task-02).
