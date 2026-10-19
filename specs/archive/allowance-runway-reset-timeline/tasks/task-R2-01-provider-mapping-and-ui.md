# Task R2-01: Provider mapping and cross-platform UI

**Requirement:** R2 — Exact Provider Mapping and Rendering
**Status:** done
**Priority:** P1
**Estimated Effort:** M
**Dependencies:** R1-01
**Spec:** specs/allowance-runway-reset-timeline/

## Context
- **Why**: The typed contract must produce visible value on both products.
- **Current state**: Hapo and ElevenLabs stringify exact source numbers into subtitles.
- **Target outcome**: Exact USD/character allowance lines and explicit-reset-only timeline text on macOS and Linux.

## Constraints
- **MUST**: Populate only values present in the parsed source contract or exact arithmetic over them.
- **SHOULD**: Keep legacy subtitles unchanged for unmigrated providers.
- **MUST NOT**: Infer reset from fetch time, window length, or label.
- **SCOPE**: Implement only R2 and the approved scope lock.

## Steps
- [x] 1. Populate Hapo USD and ElevenLabs character allowances in Swift and Rust.
  - _Requirements: 2.1, 2.2_
- [x] 2. Render native allowance in macOS popover and Settings quota rows.
  - _Requirements: 2.3, 2.5_
- [x] 3. Render the same semantics in Linux provider card and Settings rows.
  - _Requirements: 2.4, 2.5_

## Requirements
- 2.1 — Exact Hapo USD mapping.
- 2.2 — Exact ElevenLabs character mapping.
- 2.3 — macOS rendering.
- 2.4 — Linux rendering.
- 2.5 — Explicit reset only.

## Related Files
| Path | Action | Description |
|---|---|---|
| `BirdNion/Providers/{HapoHub,ElevenLabs}Provider.swift` | Modify | Exact mappings |
| `BirdNion/Views/QuotaPanel.swift` | Modify | Popover rendering |
| `BirdNion/Views/Settings/ProviderCostSection.swift` | Modify | Settings rendering |
| `linux/src-tauri/src/providers/{hapo,elevenlabs}.rs` | Modify | Exact mappings |
| `linux/src/{provider-tab,settings-provider-detail}.ts` | Modify | Linux rendering |

## Completion Criteria
- [x] Hapo shows USD used/remaining/limit from the same source payload on both platforms.
- [x] ElevenLabs shows character usage/limit on both platforms.
- [x] Missing allowance emits no invented native value.
- [x] Reset text appears only with explicit reset timestamps.

## Evidence
Verification: PASS (2026-09-21)
- [x] Swift focused provider tests (`HapoHubProviderTests/testRealReturns2xxParsed`, `NewProviderTests/testElevenLabsParse`) passed in the 4-test xcodebuild run.
- [x] Rust Hapo/ElevenLabs assertions passed inside the 698-test serial Cargo suite.
- [x] `linux/test/allowance-format.test.mjs` exercises the real `providerCard` renderer: exact USD/characters, absent invalid values, and no reset from `windowSeconds`.
- [x] Chromium runtime at `http://127.0.0.1:5175/` rendered `$5.80 REMAINING OF $10.00` with an explicit three-day reset; screenshot inspected at 650×950.
- [x] Runtime reachability verification: real `providerCard` entrypoint rendered the mapped Hapo window; built macOS application launched successfully.

## Risk Assessment
| Risk | Severity | Mitigation |
|---|---|---|
| Duplicate subtitle and allowance | Medium | Typed allowance supersedes subtitle line only for mapped windows |
| Unit formatting diverges | Medium | Shared semantic labels and platform-local formatters |
