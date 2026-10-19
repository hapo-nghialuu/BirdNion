# Task R1-01: Native allowance contract

**Requirement:** R1 — Typed Native Allowance Contract
**Status:** done
**Priority:** P1
**Estimated Effort:** S
**Dependencies:** none
**Spec:** specs/allowance-runway-reset-timeline/

## Context
- **Why**: Native values currently survive only as localized subtitle prose.
- **Current state**: `QuotaWindow` has percentage/reset fields on Swift, Rust, and TypeScript.
- **Target outcome**: One backward-compatible optional native allowance contract crosses cache and IPC boundaries.

## Constraints
- **MUST**: Preserve each numeric field independently and omit unavailable data.
- **SHOULD**: Reuse the existing `QuotaWindow` boundary.
- **MUST NOT**: Parse subtitles or synthesize a limit.
- **SCOPE**: Implement only R1 and the approved scope lock.

## Steps
- [x] 1. Add `QuotaAllowance` and optional `allowance` to the Swift model with legacy decoding.
  - _Requirements: 1.1, 1.2, 1.3_
- [x] 2. Add the equivalent serde contract and TypeScript type.
  - _Requirements: 1.1, 1.3_
- [x] 3. Add focused serialization checks proving absent fields stay absent.
  - _Requirements: 1.2, 1.3, 1.4_

## Requirements
- 1.1 — Optional used/remaining/limit and native unit.
- 1.2 — Missing remains unavailable.
- 1.3 — Cache/IPC compatibility.
- 1.4 — No display-string parsing.

## Related Files
| Path | Action | Description |
|---|---|---|
| `BirdNion/Models/ProviderStatus.swift` | Modify | Swift contract and decoder |
| `linux/src-tauri/src/providers/mod.rs` | Modify | Rust serde contract |
| `linux/src/provider-tab.ts` | Modify | TypeScript contract |

## Completion Criteria
- [x] Legacy Swift JSON decodes with `allowance == nil`.
- [x] Round-trip preserves every provided native field.
- [x] Rust and TypeScript compile with omitted allowances.
- [x] No subtitle parser is added.

## Evidence
Verification: PASS (2026-09-21)
- [x] `xcodebuild test -project BirdNion.xcodeproj -scheme BirdNion -configuration Debug -destination 'platform=macOS' -only-testing:BirdNionTests/ProviderStatusTests/testQuotaWindowRoundTripPreservesNativeAllowance -only-testing:BirdNionTests/ProviderStatusTests/testQuotaWindowLegacyJSONDecodesWithoutAllowance` — 2 tests, 0 failures.
- [x] `cargo test --manifest-path linux/src-tauri/Cargo.toml -- --test-threads=1` — 698 tests passed.
- [x] `cd linux && npm test && npm run build` — 97 tests passed; TypeScript/Vite production build passed.
- [x] Rust serde emits optional camelCase `allowance`; Swift legacy fixture proves absence decodes to nil.
- [x] Runtime reachability verification: Rust IPC payload reaches the TypeScript `ProviderStatus`/`providerCard` path; Swift `QuotaWindow` reaches existing SwiftUI rows.

## Risk Assessment
| Risk | Severity | Mitigation |
|---|---|---|
| Old cache fails decoding | High | `decodeIfPresent` and legacy fixture |
| Rust literal churn introduces omissions | Medium | defaulted optional plus cargo build/tests |
