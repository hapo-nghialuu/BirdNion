# Task 05 — Claude parallel source race + two-phase

Status: done

## Outcome

`ClaudeUsageOrchestrator` replaces sequential `executionSteps` with staged execution for `.auto`: stage 1 races OAuth and Web concurrently (first trusted result wins the core; the other result feeds extras merge), stage 2 runs the CLI chain only when stage 1 yields nothing. `ClaudeProvider` emits core first, then an enrichment emission (serviceStatus + detectedClaudeVersion). Pinned sources (`api`/`oauth`/`web`/`cli`) keep single-source behavior.

## Scope

- In: `ClaudeSourcePlanner.swift`, `ClaudeUsageOrchestrator.swift`, `ClaudeProvider.swift`, new `BirdNionTests/ClaudeRacePlanTests.swift`, `project.pbxproj`.
- Out: `ClaudeOAuth`, `ClaudeWebAPIFetcher`, `ClaudeCLISession`, `ClaudeCLIRateLimitGate`, `ClaudeCLIQuotaUnsupportedGate`, cookie/Keychain internals — gates unchanged, only sequencing.

## Coverage

- CP-04, CP-01

## Ownership

- modify `BirdNion/Providers/Claude/Core/ClaudeSourcePlanner.swift`
- modify `BirdNion/Providers/Claude/Core/ClaudeUsageOrchestrator.swift`
- modify `BirdNion/Providers/ClaudeProvider.swift`
- create `BirdNionTests/ClaudeRacePlanTests.swift`
- modify `BirdNion.xcodeproj/project.pbxproj`

## Acceptance

- AC-04, AC-09
- Planner emits `executionStages`: `.auto` → `[[.race([.oauth, .web])], [.single(.cli)]]` filtered by availability; explicit sources → single stage/step. `orderLabel`/`debugLines` updated to show `oauth‖web→cli`.
- Race semantics: launch available HTTP sources concurrently; first trusted `ClaudeUsagePayload` wins the core; cancellation-safe losers are dropped. If both resolve, OAuth outranks Web; the non-winning web result is reused for `applyWebExtras` merge instead of a second scrape when it lands within the extras window.
- CLI stage keeps existing chain verbatim: `CLIAccessGate` → PTY probe (`ClaudeCLISession.probe`/`runDirectUsageProbe`) → 60s retry when `.userInitiated`, gated by `isInteractive`/forced.
- Budgets: per-source request timeouts unchanged but clamped to remaining core budget (60s background / 120s manual); worst-case `.auto` core ≤ 60s background.
- Keychain prompt policy `ClaudeKeychainPromptGate` (`never`/`always`/`onlyOnUserAction`) untouched — background race never prompts.
- `ClaudeProvider` emissions: core = windows + accountLabel + plan + webExtras-merged; enrichment = + serviceStatus + version. `fetchServiceStatus` already runs concurrent via `async let` (`ClaudeProvider.swift:69-70`) — it moves to the extras emission instead of gating the return.
- Failure emission path unchanged (`failure(:http:)`).
- CLI starvation guard: if remaining core budget < ~10s when the CLI stage is reached in background interaction, skip the stage entirely (emit last-good/error core) rather than spawn a PTY probe that will time out. Manual interaction keeps the full retry path.
- Test seam: `loadLatestUsage` is a static func reading UserDefaults + static fetchers (`ClaudeUsageOrchestrator.swift:16-30`) — this task adds a minimal injectable-source seam (fetcher closures or equivalent) so the race is unit-testable; `session:` param already injectable for URLProtocol stubs of OAuth/Web.

## Dependencies

- task-03

## Verification Plan

- Command: `cd /Users/nghialuutrung/Desktop/birdnion && xcodebuild test -scheme BirdNion -destination 'platform=macOS' -only-testing:BirdNionTests/ClaudeRacePlanTests -only-testing:BirdNionTests/ClaudeNativeTests`
- Named probe: `StubClaudeSources` — OAuth resolves trusted at t=20s, Web at t=5s, CLI records invocation. Assert core resolves from the first trusted result and CLI is not invoked; second run with both HTTP sources failing asserts CLI runs once.
- Reachability: planner stage tests reachable directly (`ClaudeSourcePlanner.resolve` is pure); orchestrator race test reachable via the fetcher-injection seam added in this task + URLProtocol stubs on the injectable `session:` param; `ClaudeNativeTests` exists as a harness.
- Oracle: planner emits race stage for `.auto`; race picks first trusted with OAuth>Web tie-break; CLI only when stage 1 empty; pinned sources unchanged.
- Counterexample: a test where the orchestrator awaits OAuth before starting Web, or invokes CLI while a trusted HTTP result exists — must fail.
- Artifacts: planner/orchestrator/provider diffs, new test file, test log.

## Receipt

- Command: `cd /Users/nghialuutrung/Desktop/birdnion && xcodebuild test -scheme BirdNion -destination 'platform=macOS' -only-testing:BirdNionTests/ClaudeRacePlanTests -only-testing:BirdNionTests/ClaudeNativeTests`
- Exit: 0
- Verification: PASS
- Base: `bb3569005810c9a4de2b3580981fbc0de8ca4915`
- Head: `bb3569005810c9a4de2b3580981fbc0de8ca4915` + working-tree changes (planner stages, orchestrator `Fetchers` seam + `raceHTTPSources`, provider two-phase, `ClaudeRacePlanTests`, `ClaudeNativeTests` assertion update, pbxproj registration)
- Output:

```text
Test Suite 'ClaudeNativeTests' passed — Executed 39 tests, 0 failures
Test Suite 'ClaudeRacePlanTests' passed — Executed 13 tests, 0 failures
Test Suite 'Selected tests' passed — Executed 52 tests, 0 failures
** TEST SUCCEEDED **
```

- Negative/reachability proof: `testRaceResolvesFromFirstTrustedWebWithoutWaitingForOAuth` records `oauth.start`/`web.start`/`web.done` event order — Web resolves (~0.2s) and locks after the 0.75s OAuth grace while a 30s OAuth stub is cancelled, so an awaited-before-Web implementation cannot produce that ordering (elapsed < 15s asserted). `testBothHTTPFailuresInvokeCLIExactlyOnce` fails if CLI runs while a trusted HTTP result exists or runs twice — caught a real bug pre-fix: the race's failed Web scrape was re-attempted by the CLI stage's `applyWebExtras` (`prefetched: nil`), fixed by plumbing `raceWebOutcome` through. `testCLIStarvationGuardSkipsDoomedProbe` (virtual clock, remaining ≈5s) and `testManualInteractionStillRunsCLIStage` pin the F-09 background-only guard.
- Limitations: `ProviderFetchPhaseBudgets` is static so the 60s core deadline itself is not time-travel-tested — covered indirectly by the starvation-guard clock test; statuspage probe and CLI version detection are excluded from the provider test via `statusChecksEnabled=false` (real network not exercised).
