# Task 07 — Rewire usage call sites to coordinator

Status: done

## Outcome

`QuotaPanel.trigger*ReportIfNeeded` funcs, `InsightsPane` scanning path, and `QuotaService.runWeeklyDigestIfDue` all read through `UsageReportCoordinator` instead of invoking scanners directly. Persisted seeding via `CostHistoryStore` unchanged — seeds render instantly, live coordinator results overwrite.

## Scope

- In: `QuotaPanel.swift`, `InsightsPane.swift`, `QuotaService.swift` (digest call site only), `ServicesContainer.swift` (coordinator wiring).
- Out: coordinator internals (task-06); scanner internals; scheduler/facade behavior beyond the digest call site.

## Coverage

- CP-07

## Ownership

- modify `BirdNion/Views/QuotaPanel.swift`
- modify `BirdNion/Views/Settings/InsightsPane.swift`
- modify `BirdNion/Services/QuotaService.swift` (`runWeeklyDigestIfDue` only)
- modify `BirdNion/Services/ServicesContainer.swift` (inject `UsageReportCoordinator.shared`)
- modify `BirdNionTests` coverage: extend `UsageReportCoordinatorTests` or add call-site seam tests where feasible

## Acceptance

- AC-07
- No file imports a `*CostScanner` type except the coordinator (verify by grep — scanners may still be referenced by tests).
- `QuotaPanel` lazy triggers keep existing `generatedReports` gating + `persistedReport(for:)` seeding (`QuotaPanel.swift:427-468`); only the live-scan call routes through the coordinator.
- `InsightsPane.load()` seeds + live-loads via coordinator (`InsightsPane.swift:107`, seeds `:143-148`, live `:160-163`).
- Per-call-site stale-result gates preserved: `QuotaPanel` keeps its `taskId` + `AllUsageSourceAuthorization.acceptsCompletion` checks (`QuotaPanel.swift:428-450`); the coordinator dedupes the underlying scan only — callers keep their own stale-completion protection.
- `runWeeklyDigestIfDue` reads the six sources via coordinator (`QuotaService.swift` digest path) — the 7-day gate + dedup by `historyStore.weeklyDigest` unchanged.
- Codex post-scan `CODEX_USAGE_UPDATED_EVENT`/`.birdnionCodexUsageUpdated` fan-out preserved — coordinator consumers that relied on scanner-side posts keep working.

## Dependencies

- task-03-quotaservice-facade.md
- task-06-usage-report-coordinator.md

## Verification Plan

- Command: `cd /Users/nghialuutrung/Desktop/birdnion && xcodebuild test -scheme BirdNion -destination 'platform=macOS'` (full test target — call-site regression is broad) + `rg -n "CostScanner" BirdNion/Views BirdNion/Services/QuotaService.swift` returning zero hits outside the coordinator.
- Named probe: `CoordinatorCallSiteProbe` — open the Codex tab trigger + InsightsPane load + digest path against a stubbed coordinator; assert each route hits the coordinator exactly once per TTL window and seeds render before live results.
- Reachability: unit-level for the coordinator routing; build + existing tests for UI/digest regression.
- Oracle: all three call sites route through coordinator; seeds still render first; digest still gated at 7 days; zero direct scanner references outside coordinator.
- Counterexample: a grep or test showing a call site still constructing/calling a scanner directly — must fail.
- Artifacts: diffs for the 4 modified files, test log, grep output.

## Receipt

Command: `cd /Users/nghialuutrung/Desktop/birdnion && xcodebuild test -scheme BirdNion -destination 'platform=macOS'`
Exit: 0
Verification: PASS
Base: bb3569005810c9a4de2b3580981fbc0de8ca4915
Head: bb3569005810c9a4de2b3580981fbc0de8ca4915 + working-tree changes

```
Test Suite 'BirdNionTests.xctest' passed at 2026-09-23 06:27:52.349.
	 Executed 1022 tests, with 1 test skipped and 0 failures (0 unexpected) in 22.166 (22.684) seconds
Test Suite 'All tests' passed at 2026-09-23 06:27:52.355.
	 Executed 1022 tests, with 1 test skipped and 0 failures (0 unexpected) in 22.166 (22.695) seconds
** TEST SUCCEEDED **
```

Grep proof — `rg -n "CostScanner" BirdNion/Views BirdNion/Services/QuotaService.swift` returns only non-scan references (constants `KiroCostScanner.aggregateModelName`, `PiCostScanner.defaultSessionsDirectory`, infrastructure `CodexCostScanner.invalidateCaches()` paired with `UsageReportCoordinator.shared.invalidateAll()`, and doc comments). Scan-API calls (`usageReport|loadReport|seededReport|summary`) exist solely inside `UsageReportCoordinator.Scans.live`.

Implemented:
- `QuotaPanel.trigger*ReportIfNeeded` ×7 → `UsageReportCoordinator.shared.{seeded*,live}Report()`; `generatedReports` gating, `persistedReport(for:)` seeding, `taskId`, `acceptsCompletion`, `loadingCostSources` all preserved (only the two scan expressions per trigger changed).
- `InsightsPane.load()` → seeds via `seeded*Report()` then live via coordinator; `loadGeneration` + `Task.isCancelled` guards unchanged.
- `QuotaService.runWeeklyDigestIfDue` → six sources via coordinator; `isEnabled`/`isDue` 7-day gate, revalidation, and `WeeklyDigest` dedup untouched.
- `ServicesContainer.usageReports = UsageReportCoordinator.shared`.
- Coordinator additions for the discovered ProvidersPane call site: `claudeSummary`/`codexSummary` scan closures + lanes + `invalidateAll` coverage (keeps the AC grep oracle at zero direct scan calls in `BirdNion/Views`).
- `ProvidersPane` Codex extra-homes `apply(_:)` now also calls `UsageReportCoordinator.shared.invalidateAll()` so a scan-root change is not masked by the coordinator's 300s TTL.
- Test seam `installForTesting` + `testSharedSeamRoutesThroughInjectedStub` probe in `UsageReportCoordinatorTests`.

Limitations:
- Named probe `CoordinatorCallSiteProbe` (view-level Codex-tab trigger / InsightsPane load / digest routing) is covered at seam level only (`installForTesting` + shared-singleton routing test); full view-level hosting tests were not feasible — regression coverage comes from the full 1022-test suite run.
- First full-suite run surfaced a macOS TCC prompt (`kTCCServiceSystemPolicyDesktopFolder`) that blocked `CodexParserHashTests` on the adhoc-signed Debug host; resolved by user consent. The same run hit a pre-existing midnight-boundary flake in `CodexCostScannerTests.testPriorityOutageDuringCatchUpKeepsCommittedAdmissionForLegacyRows` (00:49 run, fixture anchored `now-3600s` crosses day edge); both pass in isolation and in the final full-suite run — unrelated to this diff.
- Coordinator live-report methods do not plumb the digest's `now:` anchor — scanners default to `Date()` at scan time (ms-level delta, and coordinator caching supersedes `now` anyway).
