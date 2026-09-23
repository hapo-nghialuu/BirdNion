# Quota refresh pipeline rewrite (lane scheduler + two-phase fetch)

Specs-Contract: process-first-ready-v1

## Scope decision (C1 — 2026-09-22)

- Existing: `QuotaProvider` contract `BirdNion/Providers/QuotaProvider.swift:4-8`; poll loop + backoff + stale machinery `BirdNion/Services/QuotaService.swift:31-48,347-362,447-479,615-840`; resume-once deadline `QuotaService.swift:1237-1320`; disk cache `QuotaService.swift:1329-1361,405-417`; merge pattern `BirdNion/Models/ProviderStatus.swift:278-287`; task-locals `QuotaProvider.swift:14-23`, `BirdNion/Providers/Codex/CodexCLILaunchGate.swift:7-9`; scanner TTL caches `BirdNion/Providers/Claude/ClaudeCostScanner.swift:224`, `BirdNion/Providers/Codex/CodexCostScanner.swift:74-77`, `Grok/Kiro/OMP/Pi/Devin` same pattern; Linux lane-shaped state `linux/src/main.ts:623-731`; Rust fetch+deadline `linux/src-tauri/src/providers/mod.rs:184-291`.
- Minimum change: 9 tasks / 4 phases — stream contract, lane scheduler, facade rewire, Codex+Claude two-phase & source race, usage-report coordinator, Linux parity.
- Expansion signals: >8 touched files, >2 new types, 4 independently shippable subsystems — expansion accepted at brainstorm (user chose full rewrite, both platforms).
- User decision: KEEP — approved design scope retained.

## Out of scope

- Provider credential internals (OAuth flow, Keychain reads, cookie import, PTY probe mechanics) — re-sequenced only, never rewritten.
- `ProviderStatus` breaking schema changes; `status-cache.json` stays decodable by older builds.
- Notification / failure-episode / quota-warning semantics — moved into lanes, not redesigned.
- UI redesign beyond a per-card fetching indicator.
- Linux provider fetch internals beyond the core/extras split.
- XPC/daemon process isolation.

## Coverage profile

| ID | Outcome | Change kinds | Material surfaces | Ambiguity/action | Risk/evidence | Required proof |
|---|---|---|---|---|---|---|
| CP-01 | Provider fetch emits core quota status before enrichment settles | modify | `QuotaProvider` contract, Codex/Claude providers, `QuotaService` publish path | none — stream contract fixed by task-01 | elevated — concurrency, emission ordering | source |
| CP-02 | Per-provider lanes: forced fetch starts without waiting for other providers; at most one in-flight fetch per provider | refactor | `QuotaService` scheduling, refresh triggers | none — dedup/follow-up semantics fixed by task-02 | elevated — race/cancellation | source |
| CP-03 | `QuotaService` public surface + behavior invariants preserved (statuses, displayStatuses, isRefreshing, staleWarning, refresh, notifications, disk cache, context invalidation) | refactor | popover, Settings panes, menu-bar icon, all existing tests | none — regression is the existing suite | elevated — compatibility | source + installed |
| CP-04 | Claude `auto` races OAuth and Web concurrently; CLI probe only when no HTTP source yields trusted data; background core budget ≤60s | modify | `ClaudeSourcePlanner`, `ClaudeUsageOrchestrator`, `ClaudeProvider` | none — race order fixed at C1 (D-004) | elevated — behavior change in source priority (Web now outranks CLI) | source |
| CP-05 | Codex publishes windows before version/resetCredits/webExtras/status probes settle | modify | `CodexProvider` | none | routine | source |
| CP-06 | Per-provider fetching state exposed via `fetchingIDs`; `isRefreshing` = any lane in flight | add | `QuotaService`, popover card indicator | none | routine | source |
| CP-07 | `UsageReportCoordinator` owns single-flight + TTL for 7 local cost scanners; QuotaPanel/InsightsPane/WeeklyDigest read through it | add + refactor | `QuotaPanel`, `InsightsPane`, `QuotaService` digest path | none | routine — disk I/O dedup | source |
| CP-08 | Linux parity: Rust `fetch_core`/`fetch_extras` + extras event; JS formal lanes + settings cache | modify | `linux/src-tauri/src/providers/*`, `linux/src/main.ts` | none | elevated — IPC/event contract | source + installed |

## Acceptance criteria

| ID | EARS criterion | Proof |
|---|---|---|
| AC-01 | When a provider has pending enrichment work, the system shall publish the core quota status before enrichment completes. | `xcodebuild test -scheme BirdNion -destination 'platform=macOS' -only-testing:BirdNionTests/ProviderStatusStreamTests` |
| AC-02 | When a forced refresh targets provider A while provider B's fetch is in flight, the system shall start provider A's fetch without waiting for provider B. | `xcodebuild test -scheme BirdNion -destination 'platform=macOS' -only-testing:BirdNionTests/ProviderSchedulerTests` |
| AC-03 | When concurrent refresh requests target the same provider, the system shall execute at most one fetch for that provider at a time. | same suite as AC-02 |
| AC-04 | When Claude data source is `auto`, the system shall fetch OAuth and Web concurrently and shall run the CLI probe only when no HTTP source produced trusted data. | `xcodebuild test -scheme BirdNion -destination 'platform=macOS' -only-testing:BirdNionTests/ClaudeRacePlanTests` |
| AC-05 | If an enrichment emission carries a non-nil error, the system shall discard that emission and keep the published core status. | same suite as AC-01 |
| AC-06 | While at least one provider fetch is in flight, `isRefreshing` shall be true and `fetchingIDs` shall equal the in-flight provider id set; when none are in flight, `isRefreshing` shall be false. | same suite as AC-02 |
| AC-07 | When two callers request the same source's usage report concurrently, the system shall execute at most one underlying scan. | `xcodebuild test -scheme BirdNion -destination 'platform=macOS' -only-testing:BirdNionTests/UsageReportCoordinatorTests` |
| AC-08 | When the app launches with a persisted snapshot younger than the provider's effective interval, the system shall render it and skip that provider's first fetch. | `xcodebuild test -scheme BirdNion -destination 'platform=macOS' -only-testing:BirdNionTests/QuotaServicePollingTests` |
| AC-09 | While a fetch runs in background interaction, the system shall bound the core emission to 60s; a fetch exceeding the deadline shall publish a timeout status, not hang the lane. | same suite as AC-02 |
| AC-10 | When a Linux provider produces core and extras phases, the system shall deliver the core status first and merge extras on arrival. | `cd linux/src-tauri && cargo test providers` + `cd linux && npm test` |

## Tasks

Note on shared ownership: `BirdNion.xcodeproj/project.pbxproj` appears in several tasks' ownership. This is safe because the develop flow executes one unblocked task at a time (serial) — each task appends its own file references; no parallel writes occur.



| # | Task | Criteria | Primary ownership | Dependencies | Status |
|---|---|---|---|---|---|
| 01 | Provider status stream contract + merge helper | AC-01, AC-05, AC-09 | `BirdNion/Providers/QuotaProvider.swift`, `BirdNion/Models/ProviderStatus.swift` | - | done |
| 02 | ProviderLane + ProviderScheduler | AC-02, AC-03, AC-06, AC-09 | `BirdNion/Services/ProviderScheduler.swift` (new) | task-01 | done |
| 03 | QuotaService facade rewire + fetchingIDs | AC-06, AC-08, CP-03 | `BirdNion/Services/QuotaService.swift` | task-02 | done |
| 04 | Codex two-phase fetch | AC-01, AC-05 | `BirdNion/Providers/Codex/CodexProvider.swift` | task-03 | done |
| 05 | Claude source race + two-phase | AC-04, AC-09 | `BirdNion/Providers/Claude/Core/*` | task-03 | done |
| 06 | UsageReportCoordinator module | AC-07 | `BirdNion/Services/UsageReportCoordinator.swift` (new) | - | done |
| 07 | Rewire usage call sites to coordinator | AC-07 | `BirdNion/Views/QuotaPanel.swift`, `BirdNion/Views/Settings/InsightsPane.swift`, `BirdNion/Services/QuotaService.swift` | task-03, task-06 | done |
| 08 | Linux Rust two-phase fetch + extras event | AC-10 | `linux/src-tauri/src/providers/mod.rs`, `linux/src-tauri/src/lib.rs`, `providers/codex.rs`, `providers/claude.rs` | - | done |
| 09 | Linux JS lanes + extras merge + settings cache | AC-10 | `linux/src/provider-lanes.ts` (new), `linux/src/main.ts` | task-08 | done |

## Review log

- Round 1 (C2, author self-review with fresh citation re-verification — no fresh-context reviewer; user declined the optional independent pass by batch-accepting): 10 findings, all accepted by user and applied.
  - F-01/F-02/F-04/F-05/F-10 (low): citation drift fixed in task-02/03/04/05/07/08 (`credentialDocumentIsCurrent` → CodexProvider:98-110/163-167/194-232; `async let` → ClaudeProvider:69-70; self-test → lib.rs:991, command → lib.rs:826-827; InsightsPane `load()` → :107/:143-163; context generation → QuotaService:115/548-558/682-768).
  - F-03 (high): `ClaudeUsageOrchestrator` is static, not DI-driven — task-05 now includes a fetcher-injection seam in scope and corrected reachability.
  - F-06 (med): task-07 pins preservation of per-call-site `taskId`/`acceptsCompletion` stale gates.
  - F-07 (med): task-02 pins `onBatchSettled` firing on every tick including zero-lane ticks.
  - F-08 (med): task-02 pins lane in-flight = kick→stream end/extrasDeadline.
  - F-09 (med): task-05 pins CLI starvation guard (<10s remaining budget ⇒ skip CLI in background).
