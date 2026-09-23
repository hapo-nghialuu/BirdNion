# Task 08 — Linux Rust two-phase fetch

Status: done

## Outcome

`linux/src-tauri` providers gain a core/extras split mirroring the macOS stream contract: `provider_statuses` returns core statuses fast; extras (version/service status/reset credits/web extras for Codex; service status/version for Claude) are emitted afterward via a Tauri event `birdnion-provider-extras` carrying the enriched `ProviderStatus`. Non-split providers emit a single phase.

## Scope

- In: `linux/src-tauri/src/providers/mod.rs`, `linux/src-tauri/src/lib.rs` (`provider_statuses` command + event emit), `linux/src-tauri/src/providers/codex.rs`, `linux/src-tauri/src/providers/claude.rs`.
- Out: other Rust providers' internals; JS (task-09); credential internals; `codex_scanner`.

## Coverage

- CP-08

## Ownership

- modify `linux/src-tauri/src/providers/mod.rs`
- modify `linux/src-tauri/src/lib.rs`
- modify `linux/src-tauri/src/providers/codex.rs`
- modify `linux/src-tauri/src/providers/claude.rs`

## Acceptance

- AC-10 (Rust half)
- Provider trait shape: `fetch_core(&ProviderCfg) -> ProviderStatus` + `fetch_extras(&ProviderCfg) -> ProviderStatus` (extras = a status carrying only enrichment fields, merged by `merge_status_extras`). Default `fetch_extras` returns the core unchanged or an empty-extras status — non-split providers work untouched.
- `provider_statuses` per provider: run core, return it in the command result; spawn extras; on completion `app.emit("birdnion-provider-extras", status)`.
- `FETCH_DEADLINE` (200s) still bounds each provider's total fetch; extras phase gets its own bounded tail (≤30s) — deadline breach ⇒ same timeout classification as today.
- `provider_statuses` command (`lib.rs:826-827` → `providers::fetch_filtered`) and the self-test path (`providers::fetch(&cfg)` at `lib.rs:991`) preserved; unsupported-provider statuses unchanged.
- Shared `Client::builder().timeout(15s)` unchanged.

## Dependencies

- none

## Verification Plan

- Command: `cd /Users/nghialuutrung/Desktop/birdnion/linux/src-tauri && cargo test`
- Named probe: `ProbeTwoPhase` — a fixture provider whose extras sleep; assert `provider_statuses` resolves with core before extras settle and that an extras emit occurs with the enriched status. Run under the existing `cargo test` harness in `providers/mod.rs` tests module.
- Reachability: unit-level in `providers/mod.rs` tests; `lib.rs` command path verified by `cargo check` + existing tests.
- Oracle: core returned with `extras_pending` semantics (or equivalent flag); extras event payload merges onto the same provider id; non-split providers emit once.
- Counterexample: a test where `provider_statuses` awaits the extras sleep before returning — must fail.
- Artifacts: modified Rust files, `cargo test` log.

## Receipt

Command: `cd /Users/nghialuutrung/Desktop/birdnion/linux/src-tauri && cargo test`
Exit: 0
Verification: PASS
Base: bb3569005810c9a4de2b3580981fbc0de8ca4915
Head: bb3569005810c9a4de2b3580981fbc0de8ca4915 + working-tree changes

```
test providers::tests::extras_has_fields_gates_emit ... ok
test providers::tests::merge_status_extras_fills_gaps_never_overwrites_core ... ok
test providers::tests::non_split_provider_never_emits_extras ... ok
test providers::tests::pipeline_returns_core_before_extras_settle ... ok
test providers::tests::two_phase_core_ships_before_extras_and_emits_merged ... ok

test result: ok. 713 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 7.69s
```

Command-path check: `cargo check --tests` — exit 0 (lib.rs `provider_statuses` signature change compiles; `use tauri::Emitter as _` scoped inside the command, matching the existing emit pattern at `lib.rs:132`).

Implemented:
- `providers/mod.rs`: `EXTRAS_DEADLINE` (30s tail budget), `PROVIDER_EXTRAS_EVENT` (`birdnion-provider-extras`), `merge_status_extras` (enrichment fills gaps only — windows/account/error/source/credits/last_updated from core always win; `credits_unlimited` OR-merges), `extras_has_fields` emit gate, `fetch_core`/`fetch_extras` (both via `with_deadline`), `dispatch_core`/`dispatch_extras`, `spawn_extras` (detached tail, emits merged status only when enrichment fields exist), `fetch_core_and_spawn_extras` pipeline (extracted so tests can drive it without mutating the global config env). `fetch_filtered` now takes an `emit_extras` closure, returns core statuses, spawns detached tails. Non-split providers run their unchanged single-phase `fetch` via `dispatch_core`'s `_` arm and produce field-less extras → no emit.
- `providers/codex.rs`: `fetch_core`/`fetch_extras`/`fetch` + `resolve_auth` shared prelude (`ResolvedAuth::{Creds,CookieOnly,Done}`) extracted from the former `fetch_uncached` auth block; `fetch_phases(include_extras)` preserves the 2-attempt stale-retry loop + bound snapshot save. Core skips side_info/cookie-enrichment/reset-credits probes. Extras re-resolves auth detached and returns an enrichment-only status via `extras_status`; a stale mid-flight auth change drops the extras (no retry — next refresh picks them up). `fetch` stays the combined single-shot path for the self-test.
- `providers/claude.rs`: `fetch_core`/`fetch_extras`/`fetch` + `fetch_inner(include_extras)`; web/api/cli paths unchanged; OAuth joins CLI-version + statuspage probes only when `include_extras`; `fetch_extras` is a credential-independent enrichment-only status (version + service status).
- `lib.rs`: `provider_statuses` accepts `tauri::AppHandle`, passes an emit closure mapping merged extras onto `app.emit(PROVIDER_EXTRAS_EVENT, status)`.

Tests (in `providers/mod.rs` tests module):
- `two_phase_core_ships_before_extras_and_emits_merged` — ProbeTwoPhase: core resolves immediately (no extras fields), no emit within 100ms while the 300ms extras sleeps, merged emit lands on the same provider id with `version` + core `windows`.
- `pipeline_returns_core_before_extras_settle` — counterexample: `fetch_core_and_spawn_extras` over the probe returns in <250ms (< 300ms extras sleep); if the pipeline awaited extras this fails. Emit then arrives with the merged status.
- `merge_status_extras_fills_gaps_never_overwrites_core` — gap-fill semantics incl. core-credits precedence and `last_updated` immutability.
- `extras_has_fields_gates_emit` — empty tail never emits.
- `non_split_provider_never_emits_extras` — unknown/single-phase provider emits once (core only).

Limitations:
- Codex extras re-resolves auth (`resolve_auth` re-reads + may re-refresh `auth.json`) once per refresh — bounded by `EXTRAS_DEADLINE`; a stale selection mid-extras yields an empty tail instead of retrying.
- `lib.rs` command path is covered by `cargo check` + suite compile only (no Tauri runtime harness for `app.emit`); the emit closure itself is exercised through `spawn_extras`/`fetch_core_and_spawn_extras` at unit level.
- JS listener for `birdnion-provider-extras` lands in task-09; until then extras events are emitted but unconsumed (core statuses remain correct standalone).
