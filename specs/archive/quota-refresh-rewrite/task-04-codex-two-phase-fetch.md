# Task 04 — Codex two-phase fetch

Status: done

## Outcome

`CodexProvider.statuses(interaction:)` emits core quota status (windows, accountLabel, planType, creditsRemaining/creditsUnlimited from the usage response, accountID, sourceLabel) immediately after the usage call resolves — before version/resetCredits/webExtras/serviceStatus probes settle. Those probes become a second enrichment emission. Both the OAuth path and the `cliRPCSuccess` fallback path emit two phases.

## Scope

- In: `BirdNion/Providers/Codex/CodexProvider.swift`, new `BirdNionTests/CodexProviderTwoPhaseTests.swift`, `project.pbxproj`.
- Out: `CodexUsageAPI`, `CodexAppServerRPC`, `CodexWebDashboard`, `CodexResetCreditsAPI` internals; credential/auth flow; CLI launch gate.

## Coverage

- CP-05, CP-01

## Ownership

- modify `BirdNion/Providers/Codex/CodexProvider.swift`
- create `BirdNionTests/CodexProviderTwoPhaseTests.swift`
- modify `BirdNion.xcodeproj/project.pbxproj`

## Acceptance

- AC-01, AC-05
- Core emission (emission 0) for both `runOAuthFetch` success and `cliRPCSuccess`: everything derivable from the usage/RPC response — no probe awaits.
- Enrichment emission (emission 1): same status + `version`, `serviceStatus`, `resetCreditsAvailable`, `codexWeb`. Each probe failure ⇒ field nil; emission 1 never carries `error`.
- `credentialDocumentIsCurrent` re-checked before each emission (guards at `CodexProvider.swift:98-110, :163-167, :194-232`) — stale emissions dropped.
- Unchanged: OAuth → CLI RPC fallback order (`:344-358`), proactive token refresh + 401 retry (`:298-305`), `CodexCLILaunchGate` prompt logic (`:28-97`), PTY probe, failure emission paths, `statusCacheKey`/`CodexStatusCacheStore` writes.
- Emission cadence: extras emit once when all probes settle (or extrasDeadline hits) — not one emission per probe.

## Dependencies

- task-03

## Verification Plan

- Command: `cd /Users/nghialuutrung/Desktop/birdnion && xcodebuild test -scheme BirdNion -destination 'platform=macOS' -only-testing:BirdNionTests/CodexProviderTwoPhaseTests -only-testing:BirdNionTests/CodexProviderTests`
- Named probe: `StubCodexProbe` — usage stub resolves at t=100ms; version/reset/web/status stubs resolve at t=10s; consumer must see emission 0 ≤ t≈100ms carrying windows, emission 1 later carrying probe fields.
- Reachability: unit-level via existing provider test seams (`CodexProvider.swift:46-57` constructor injection of api/session/dashboard/status).
- Oracle: emission 0 has windows + label + plan with nil enrichment fields; emission 1 fills them; a failed probe leaves its field nil with `error == nil`.
- Counterexample: a test where emission 0 waits for the 10s probes, or a probe failure produces `error != nil` on emission 1 — must fail.
- Artifacts: modified `CodexProvider.swift`, new test file, test log.

## Receipt

- Command: `cd /Users/nghialuutrung/Desktop/birdnion && xcodebuild test -scheme BirdNion -destination 'platform=macOS' -only-testing:BirdNionTests/CodexProviderTwoPhaseTests -only-testing:BirdNionTests/CodexProviderTests`
- Exit: 0
- Verification: PASS
- Base: `bb3569005810c9a4de2b3580981fbc0de8ca4915`
- Head: `bb3569005810c9a4de2b3580981fbc0de8ca4915` + working tree — `CodexProvider.swift` overrides `statuses(interaction:)` (core emission = usage-derived fields only: windows, accountLabel, planType, credits from usage response, accountID, sourceLabel; extras emission adds version/serviceStatus/resetCreditsAvailable/codexWeb); `fetch()` drains the stream returning the last emission (self-test path preserved); new `BirdNionTests/CodexProviderTwoPhaseTests.swift` (5 tests, `ProbeGate` deterministic ordering); pbxproj refs `C2PT…`.
- Current output:

```text
Test Suite 'CodexProviderTests' passed … Executed 112 tests, 0 failures
Test Suite 'CodexProviderTwoPhaseTests' passed … Executed 5 tests, 0 failures
Test Suite 'Selected tests' passed … Executed 117 tests, 0 failures
** TEST SUCCEEDED **
```

- Negative/reachability proof: `testOAuthCoreEmissionArrivesBeforeExtrasSettle` — core arrives while version/status probes are still gated (counterexample oracle: awaiting probes would time out the poll); `testExtrasEmissionNeverCarriesErrorOnProbeFailure` — failed probes leave fields nil with `error == nil` (the counterexample "extras carries error" fails by construction + `ProviderStatusEmissionPolicy`); `testCLIPathEmitsCoreThenExtras` — CLI-RPC path also emits two phases; `testFetchReturnsEnrichedLastEmission` — `fetch()` returns the enriched status (self-test contract); `testFailurePathEmitsSingleError` — failure paths stay single-emission.
- Note: `credentialDocumentIsCurrent` is re-checked before each emission; a stale extras emission is dropped silently (the already-published core stays). The web-dashboard credits fallback no longer flattens into top-level `creditsRemaining` (enrichment cannot patch core fields per `withEnrichment`) — the value still arrives inside `codexWeb.creditsRemaining`; flattening it at view level is a follow-up outside this task's ownership. `resetCredits` runs only on the OAuth path (CLI path has no endpoint — unchanged).
