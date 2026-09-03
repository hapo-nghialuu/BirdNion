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

## Sync policy

Cherry-pick individual upstream changes; do not overwrite the tree. Keep the
BirdNion-only symbols above, and keep the divergences that are deliberate — Claude
dedup keyed on `messageId` alone counts more accurately here than upstream's
`messageId:requestId` (upstream double-counts lines that carry no `requestId`).

Any change to counting semantics must also rotate
`Sources/CodexBarCore/Generated/CodexParserHash.generated.swift`; the cache is keyed
on that hash, so a fix that skips the rotation silently never runs against files
already recorded as fully parsed.
