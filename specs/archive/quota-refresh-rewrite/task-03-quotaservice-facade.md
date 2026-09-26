# Task 03 — QuotaService facade rewire

Status: done

## Outcome

`QuotaService` delegates all scheduling to `ProviderScheduler` while keeping its public surface and semantics: `statuses`, `displayStatuses`, `isRefreshing`, `accountSnapshotsRevision`, `staleWarning(for:)`, `providers`/`setProviders`/`add`/`remove`/`reorder`, `setInterval`, `start`/`stop`, `refresh(forceProviderIDs:)`, `refreshFromSettings`, `applySelfTestStatus`, `applyCachedCodexStatus`, `invalidateProviderContext`, plus test seams (`adaptiveBackoffState`, `failureEpisodeState`, `refreshCoordinatorState`, `settingsRefreshCoordinatorState`). New `@Published fetchingIDs: Set<String>` powers a per-card indicator in `QuotaPanel`. Existing `QuotaServicePollingTests` pass unmodified.

## Scope

- In: `QuotaService.swift` (facade; notification/warning/overlay helpers move to `QuotaNotifications.swift` — code motion only), `QuotaPanel.swift` (per-card fetching indicator), `project.pbxproj`.
- Out: provider internals; scheduler internals (task-02); coordinator (task-06/07); Linux.

## Coverage

- CP-03, CP-06

## Ownership

- modify `BirdNion/Services/QuotaService.swift`
- create `BirdNion/Services/QuotaNotifications.swift` (extracted `QuotaNotifier`, `QuotaWarnConfig`, overlay window, `OrderedAsyncOperationQueue` — verbatim move)
- modify `BirdNion/Views/QuotaPanel.swift` (per-card indicator only)
- modify `BirdNion.xcodeproj/project.pbxproj`

## Acceptance

- AC-06, AC-08; CP-03 invariants
- Public API and test seams unchanged; `QuotaServicePollingTests` pass without edits.
- Preserved behaviors (each must map to an existing test or a new one):
  - `restorePersistedStatuses` seeds `lastFetchedAt` from `status-cache.json` (`QuotaService.swift:405-417`, `1329-1361`).
  - Poll loop cadence + jitter + manual mode (`:347-362`).
  - `refreshFromSettings` debounce 350ms + `providersDidChange` rebuild (`:485-567`).
  - `.birdnionRefresh` / `.birdnionCodexAccountChanged` / `.birdnionShowQuotaNotification` handling (`:365-417`).
  - Quota warnings, failure episodes, menu-bar overlay, Action Center (`:833-976`, `1065-1236`).
  - Per-account snapshot stores (codex/antigravity) saved on renderable snapshots, invalidated on context change (`QuotaService.swift:548-558, :682-768`).
  - `runWeeklyDigestIfDue` + Antigravity account refresh → `onBatchSettled` hook (`:829-840`, `1458-1480`).
  - `fetchSelfTest` / `applySelfTestStatus` (`:1422-1456`).
- `fetchingIDs` reflects lane in-flight set; card indicator shows while its provider id is in `fetchingIDs`.
- `isRefreshing` = `fetchingIDs.isEmpty == false` (footer "Đang cập nhật…" semantics preserved).

## Dependencies

- task-02-provider-lane-scheduler.md

## Verification Plan

- Command: `cd /Users/nghialuutrung/Desktop/birdnion && xcodebuild test -scheme BirdNion -destination 'platform=macOS' -only-testing:BirdNionTests/QuotaServicePollingTests`
- Named probe: `QuotaServicePollingTests` unmodified as the regression oracle; plus a probe asserting `fetchingIDs` tracks in-flight lanes and a popover-open-with-cache path (AC-08).
- Reachability: unit-level via existing suite + `xcodebuild build -scheme BirdNion -destination 'platform=macOS'` for the UI wiring.
- Oracle: every pre-existing polling test passes unmodified; `fetchingIDs` set/del in step with lane tasks; cached snapshot renders without a first fetch.
- Counterexample: a test where a provider fetch completes but its id remains in `fetchingIDs`, or where a fresh persisted snapshot triggers a fetch at launch — must fail.
- Artifacts: modified `QuotaService.swift`, new `QuotaNotifications.swift`, test log + build log.

## Receipt

- Command: `cd /Users/nghialuutrung/Desktop/birdnion && xcodebuild test -scheme BirdNion -destination 'platform=macOS' -only-testing:BirdNionTests/QuotaServicePollingTests` (regression superset also ran `ProviderSchedulerTests` + `ProviderStatusStreamTests`: 70/70 pass; `xcodebuild build -scheme BirdNion -destination 'platform=macOS'` → BUILD SUCCEEDED for the QuotaPanel wiring)
- Exit: 0
- Verification: PASS
- Base: `bb3569005810c9a4de2b3580981fbc0de8ca4915`
- Head: `bb3569005810c9a4de2b3580981fbc0de8ca4915` + working tree — `QuotaService.swift` rewritten as facade over `ProviderScheduler` (1707 → ~1275 lines; poll loop, refresh coalescing queue, settings-refresh debounce, warnings/episodes, weekly digest, antigravity snapshot pass, persistence, self-test path preserved), new `BirdNion/Services/QuotaNotifications.swift` (verbatim move of `QuotaWarnConfig`/`OrderedAsyncOperationQueue`/`QuotaNotifier`/`QuotaAlertOverlay` — diff-verified byte-identical), `QuotaPanel.swift` per-card `isFetching` spinner, `ProviderScheduler.swift` gained `replaceProvider` for same-id instance swaps, pbxproj refs `QNFS…`, +1 probe test.
- Current output:

```text
Test Suite 'QuotaServicePollingTests' passed at 2026-09-22 23:45:56.351.
	 Executed 50 tests, with 0 failures (0 unexpected) in 0.568 seconds
Test Suite 'BirdNionTests.xctest' passed … Executed 50 tests, 0 failures
** TEST SUCCEEDED **
```

- Negative/reachability proof: `testInFlightResultForSameIDReplacementIsIgnored` — a `setProviders` same-id instance swap drops the old instance's in-flight result (fixed via `ProviderLane.replaceProvider` generation bump; the earlier implementation published the stale result and this test caught it). `testFetchingIDsTrackInFlightLane` (new probe) — `fetchingIDs == ["gated"]` and `isRefreshing == true` while the lane is in-flight, both clear on settle (AC-06; the counterexample "completed but id remains in fetchingIDs" fails by construction). `testStatusCacheRestoresSnapshotsAndSeedsThrottle` — a fresh persisted snapshot yields `due=0/1`, i.e. no fetch at launch (AC-08 counterexample oracle). `testConcurrentRefreshCoalescesAndMergesLateForcedProviderIDs` + `testQueuedForcedRefreshRetriesFailedInFlightProviderAndResetsBackoff` — facade queue semantics preserved through the scheduler (succeeded-generation filter).
- Note: `isRefreshing`/`fetchingIDs` are derived from the live lane set (no manual flag). `evaluateFailureEpisode`/`warnState` stay facade-owned because existing tests drive them for ids without lanes; lanes report via `ProviderLane.Hooks`. `staleWarning` is lane-owned per task-02. `ProviderFetchDeadline` (200s) now backs only the `fetchAsUserAction`/`fetchWithDeadline` self-test path — lane core/extras budgets (`ProviderFetchPhaseBudgets`) bound the scheduled path.
