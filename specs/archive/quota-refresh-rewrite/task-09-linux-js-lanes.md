# Task 09 — Linux JS lanes + extras merge + settings cache

Status: done

## Outcome

`linux/src/main.ts` lane-shaped state (`inFlightProviderIds`, `lastFetched`, `adaptiveFailureStreaks`, `dueProviderIds` at `main.ts:623-731`) is formalized into a `ProviderLane` module with the same dedup/force-follow-up semantics as macOS task-02. The frontend subscribes to `birdnion-provider-extras` and merges enrichment fields onto the provider card. `get_settings` results are cached 30s inside `tick()` instead of an IPC call every 10s.

## Scope

- In: new `linux/src/provider-lanes.ts`, `linux/src/main.ts`, `linux/test/` additions, `linux/package.json` only if a new test file needs registration (it doesn't — `test/*.test.mjs` glob covers it).
- Out: Rust side (task-08 owns the event payload shape — this task consumes it); provider UI markup.

## Coverage

- CP-08, CP-02 (Linux parity)

## Ownership

- create `linux/src/provider-lanes.ts`
- modify `linux/src/main.ts`
- create `linux/test/provider-lanes.test.mjs`

## Acceptance

- AC-10 (JS half); AC-02, AC-03 parity
- `ProviderLane`: `{id, lastFetched, failureStreak, inFlight: Promise|null, kick(force, interaction)}` — in-flight join, forced follow-up after background in-flight completes, backoff ×1/×2/×4/×8 capped, per-provider `refreshInterval.<id>` honored (existing `providerIntervalMs` logic `main.ts:638-658` moves into the lane).
- `tick()`: due check + kicks via lanes; `refreshProviders`/`runManualRefresh`/`fetchSingleProvider` route through lanes; `initialProviderReadsStarted` gate preserved.
- `listen("birdnion-provider-extras")` merges enrichment fields (version, serviceStatus, resetCredits, web extras) onto `statuses[id]` and re-renders that card only; core fields (windows/error/label) untouched by extras payloads.
- `get_settings` cached for 30s inside the tick loop — max 1 IPC per 3 ticks.
- `isRefreshing`/`refreshInFlight` UI flag semantics preserved (`main.ts:1144-1168`).

## Dependencies

- task-08-linux-two-phase-fetch.md

## Verification Plan

- Command: `cd /Users/nghialuutrung/Desktop/birdnion/linux && npm test && npm run build`
- Named probe: `ProbeLaneDedup` in `provider-lanes.test.mjs` — kick the same provider id 3× concurrently; assert one underlying fetch; force-kick during a background in-flight; assert exactly one follow-up. `ProbeExtrasMerge` — feed an extras payload; assert enrichment fields merge, core fields unchanged.
- Reachability: unit-level via `node --test` (existing harness); `npm run build` (tsc) for typecheck of `main.ts` integration.
- Oracle: lane dedup + follow-up counts correct; extras merge is field-scoped; settings IPC invoked ≤1 per 30s of ticks.
- Counterexample: a test where two concurrent kicks on one lane run two fetches, or an extras payload overwrites `windows`/`error` — must fail.
- Artifacts: `provider-lanes.ts`, `main.ts` diff, `provider-lanes.test.mjs`, `npm test` + `npm run build` logs.

## Receipt

Command: `cd /Users/nghialuutrung/Desktop/birdnion/linux && npm test && npm run build`
Exit: 0
Verification: PASS
Base: bb3569005810c9a4de2b3580981fbc0de8ca4915
Head: bb3569005810c9a4de2b3580981fbc0de8ca4915 + working-tree changes

```
✔ ProbeLaneDedup: three concurrent kicks run one underlying fetch (15.640542ms)
✔ ProbeLaneDedup: force kick during in-flight queues exactly one follow-up (3.377708ms)
✔ lane clears inFlight after rejection so the next kick refetches (0.835917ms)
✔ joiner waits for the owner's fetch to settle (0.302ms)
✔ backoff multiplies the provider's own interval x1/x2/x4/x8 capped (0.365541ms)
✔ isDue honors lastFetched + backoff-adjusted interval (0.192292ms)
✔ manual-kick failure starts a fresh streak instead of inheriting backoff (13.074042ms)
✔ ProbeExtrasMerge: enrichment fills gaps, core fields untouched (0.390084ms)
✔ ProbeExtrasMerge: missing enrichment fields never clobber existing ones (23.36425ms)
✔ ProviderLanes: registry shares lanes by id and reports in-flight ids (0.848709ms)
✔ createTtlCache: at most one IPC per ttl window of ticks (11.36925ms)
ℹ tests 105  ℹ pass 105  ℹ fail 0
✓ built in 1.19s   (tsc --noEmit clean + vite build)
```

Implemented:
- `linux/src/provider-lanes.ts` (new): `ProviderLane {id, lastFetched, failureStreak, inFlight, kick(force, interaction, run)}` — non-force kicks join the in-flight promise; a force kick during in-flight queues exactly one follow-up (extra forces coalesce); a settled/rejected promise is cleared so later kicks refetch; `intervalMs`/`isDue` carry the x1/x2/x4/x8 capped backoff and per-provider `refreshInterval` honoring (former `adaptiveIntervalMs`/`dueProviderIds` math moved in); `recordOutcome` uses the lane's `lastInteraction` for manual streak reset; `resetSchedule` for disable/identity-clear; `ProviderLanes` registry (`lane`/`isInFlight`/`inFlightIds`/`ids`); `mergeStatusExtras` — field-scoped gap-fill mirroring the Rust merge (windows/error/labels/credits/lastUpdated never touched); `createTtlCache`.
- `linux/src/main.ts`: `lastFetched`/`inFlightProviderIds`/`adaptiveFailureStreaks`/`adaptiveBackoffMultiplier`/`adaptiveIntervalMs`/`withProviderInFlightGuard` replaced by `providerLanes` + `laneKick` (calls `onFetchReleased` once per real fetch); `load()` fanout → non-force `laneKick` (interaction from `manual`); `refetchProvider` → force `laneKick` "manual" (queues one follow-up behind an in-flight fetch — spec-intended change from the old silent no-op); `tick()` → `dueProviderIds` via lanes then one detached `laneKick` per due provider (per-provider fetch+publish, matching the load-fanout pattern); `recordFetchOutcomes` drops the `manual` param (lane interaction tag decides); `dueProviderIds` uses `tickSettings = createTtlCache(30_000, get_settings)` — ≤1 IPC per 3 ticks; `listen(PROVIDER_EXTRAS_EVENT)` registered inside `awaitProviderCoordinatorListeners` before `load()` → `applyProviderExtras` merges enrichment fields onto `state.statuses[id]`, bumps `providerStatusStateRevision`, re-renders only when that provider's card is on screen + refreshes the agenda panel; `clearProviderIdentityState`/disable cleanup/`observedProviderIds`/canonical-reconciliation now read lane state.
- `linux/test/provider-lanes.test.mjs` (new): 11 tests — dedup/forced-follow-up/rejection-recovery/join-wait, backoff cap + isDue + manual-streak-reset, extras gap-fill + core-field preservation (counterexample: extras carrying hostile `windows`/`error` values cannot clobber core), registry, and the 30s settings TTL (2 fetches across 60s of ticks).

Limits:
- `state.refreshing`/`paintRefreshChrome` semantics unchanged — the spinner still tracks `load()` only, exactly as before (lane kicks in `tick()` never toggled it previously either).
- Non-force join now awaits the owner's in-flight fetch (previously `withProviderInFlightGuard` returned immediately); the owner's result is still published by the owner — `load()`/`refetchProvider` merely wait for it, which matches the spec's in-flight-join contract.
- Extras merge applies field-scoped gap-fill only; a stale extras tail can fill enrichment gaps but cannot regress core quota data (bounded by the Rust 30s `EXTRAS_DEADLINE`).
