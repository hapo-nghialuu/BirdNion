# Vendored CodexBarCore — provenance

## Baseline

Vendored from upstream **CodexBar `d8ce86980`** (2026-06-18, "build: add musl CLI
source compatibility (#1620)").

The baseline was recovered by blob comparison, not from any recorded metadata: all
11 files under `Sources/CodexBarCore/Vendored/CostUsage/` at BirdNion's vendoring
commit `ff5ae420` match the upstream tree at `d8ce86980` byte-for-byte
(`CostUsageScanner.swift` = blob `aff14a6d9add11d251cae652e57fcc5cbf178d80`).

**Record the upstream SHA here on every sync.** Without it the next person has to
redo that archaeology.

## This is a fork, not a mirror

Thirteen BirdNion commits have edited the vendored tree since it was imported, so it
cannot be refreshed by overwriting it with upstream:

| Commit | Subject |
|---|---|
| `ff5ae420` | build: vendor CodexBarCore into Vendor/CodexBar |
| `bb80dd0b` | feat(pricing): add gpt-5.6 family rates for Codex cost |
| `37dee091` | fix(codex): resolve session id by id before session_id in scanner |
| `749d72f0` | feat(codex): add resumable 120-day cost scan |
| `86b876aa` | feat(insights): add project usage attribution |
| `e146a2b7` | fix(codex): time-bound cost scan so huge histories don't hang the app |
| `c2791f7e` | fix(codex): make bounded scans resumable |
| `bc21ce3b` | fix(codex): stop forked sessions dropping today's tokens to zero |
| `196b5bd5` | fix(codex): preserve legacy and compact fork totals |
| `4fca0874` | fix(codex): make local usage scans converge reliably |
| `b5f0554a` | fix(codex): make usage scans incremental and restart-safe |
| `eeaf4a32` | perf(codex): make usage scans fast and resilient |
| `70742fe4` | fix(codex): canonicalize pending priority state |

## Why a wholesale re-vendor breaks the build

- Upstream `26fd0bbd7` **deleted `CostUsageCacheIO`** when Codex cost persistence
  moved to SQLite (`CostUsageStore`). BirdNion still reads and writes the JSON
  artifact, including from ~15 test call sites.
- Eleven symbols exist only in BirdNion, so the test target stops compiling — which
  costs the safety net exactly when it is needed: `codexFrozenFile`,
  `codexFrozenFileIsReadable`, `codexFrozenPrefixSampleOffsets`,
  `codexParentQueryKey`, `codexPendingManifestContractVersion`,
  `codexPendingProgressFingerprint`, `finalizedCodexPendingFileOrder`,
  `reconciledCodexPendingFileOrder`, `codexPriorityTurnsCursorIsValid`,
  `codexTurnIDBackfillFileLimit`, `resetCodexFlatDirectoryCursorsForTesting`,
  plus the `CodexForkBaseline.stopped` case.
- `CostUsageScanner.CodexUsageRow` carries 6 fields here and 14 upstream.
- Upstream's tree pulls in `CostUsageStore*`, `OpenCodexRouteDispatcher`,
  `ClaudeConfigPaths`, `ClaudeDesktopProjectsLocator`, `CostProvenance` and
  `CodexPriorityDatabasePath`, none of which are vendored.

## Deliberate divergences

**Codex CLI forks keep their own counter.** Upstream decides counter semantics
(`CodexSubagentRolloutShape`) only for subagent threads — the classifier is gated
behind `metadata.isSubagentThread`. A `source: "cli"` rollout that names a
`forked_from_id` therefore always has the parent's lifetime totals subtracted.
`codex resume` writes exactly that shape while running its own counter from zero,
so the subtraction erased whole sessions: on this user's machine the main rollout
counted 263M of the 904M it actually reported, and the current day showed nothing
at all.

BirdNion bypasses the inherited baseline when two independent signals agree, the
same discipline upstream applies to subagents:

1. no `session_meta` for an ancestor (every copied-prefix rollout observed on
   disk carries that metadata, always ahead of its first `token_count`);
2. the first `token_count` reports `total == last`, which holds only when the
   cumulative counter started at zero.

A rollout with no `source` field is untouched, so upstream-shaped fixtures keep
their behavior. Upstream has the same bug for CLI forks; drop this divergence if
it ever fixes it.

**Interleave containment stays off the streaming path — on purpose.**
`CodexTotalsTracker`, `codexContainedTotalDelta` and `codexPostLatchEventDelta`
are wired into the `JSONSerialization` parser only. Real rollouts are read by the
fast byte parser, so that guard does not run, and it must not be "fixed" by
wiring it in: measured on this user's logs it cut the main rollout from
903,403,399 to 643,884,558 (71% of the 904,469,133 the file actually reports) and
collapsed the current day from 3,205,117 tokens to 31,291.

The guard is built for ultra-mode, where several fork lineages interleave inside
one file and the gap between them is not real work. A rollout resumed eight times
by `codex resume` looks identical to the watermark — every restart dips below it —
but there each dip *is* real work. Upstream accepts that trade ("smaller lineage
below the watermark is an accepted Phase 1 undercount"); at this scale it is not
acceptable. The `cached`/`reasoning` parsing fixes from the same change do run on
the streaming path and are unaffected.

## Sync policy

Cherry-pick individual upstream changes; do not overwrite the tree. Keep the
BirdNion-only symbols above, and keep the divergences that are deliberate — Claude
dedup keyed on `messageId` alone counts more accurately here than upstream's
`messageId:requestId` (upstream double-counts lines that carry no `requestId`).

Any change to counting semantics must also rotate
`Sources/CodexBarCore/Generated/CodexParserHash.generated.swift`; the cache is keyed
on that hash, so a fix that skips the rotation silently never runs against files
already recorded as fully parsed. Run `Scripts/regenerate-codex-parser-hash.sh`
and commit the result with the change — `CodexParserHashTests` fails the build
until you do.
