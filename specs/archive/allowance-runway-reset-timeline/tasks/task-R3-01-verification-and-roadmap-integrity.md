# Task R3-01: Verification and roadmap integrity

**Requirement:** R3 — Verification and Roadmap Integrity
**Status:** done
**Priority:** P1
**Estimated Effort:** S
**Dependencies:** R1-01, R2-01
**Spec:** specs/allowance-runway-reset-timeline/

## Context
- **Why**: This cross-platform contract must be proven without claiming unfinished P1 semantics.
- **Current state**: P1 roadmap boxes are unchecked.
- **Target outcome**: Focused automated and runtime proof; roadmap remains truthful.

## Constraints
- **MUST**: Run focused tests and both changed builds.
- **SHOULD**: Record exact commands and observed results.
- **MUST NOT**: Mark P1 complete or rewrite unrelated roadmap items.
- **SCOPE**: Implement only R3 and the approved scope lock.

## Steps
- [x] 1. Add contract/provider/rendering regression coverage.
  - _Requirements: 3.1, 3.2_
- [x] 2. Run macOS and Linux build/test commands plus runtime smoke checks.
  - _Requirements: 3.3_
- [x] 3. Keep P1 unchecked and record remaining semantic work.
  - _Requirements: 3.4_

## Requirements
- 3.1 — Serialization/provider mapping proof.
- 3.2 — Linux renderer and absence proof.
- 3.3 — Passing platform builds.
- 3.4 — Honest roadmap state.

## Related Files
| Path | Action | Description |
|---|---|---|
| `BirdNionTests/ProviderStatusTests.swift` | Modify | Contract regression tests |
| `linux/test/` | Modify | Rendering regression coverage |
| `docs/development-roadmap.md` | Inspect | P1 remains unchecked |

## Completion Criteria
- [x] Focused Swift tests pass.
- [x] Linux Node tests, TypeScript build, and Rust tests pass.
- [x] Runtime surface shows native units without fabricated reset text.
- [x] P1 roadmap remains unchecked.

## Evidence
Verification: PASS (2026-09-21)
- [x] macOS xcodebuild selected suite — 4 tests, 0 failures; app build completed.
- [x] Linux `npm test && npm run build` — 97 tests and production build passed; serial Cargo suite — 698 tests passed.
- [x] Actual Linux provider-card surface rendered in Chromium; actual built macOS binary launched and remained running during smoke verification.
- [x] `docs/development-roadmap.md` P1 boxes remain unchecked; `docs/system-architecture.md` documents this typed-allowance slice and its limits.
- [x] Runtime reachability verification: Linux Chromium surface and built macOS executable were both exercised after implementation.

## Risk Assessment
| Risk | Severity | Mitigation |
|---|---|---|
| Build passes but UI is unreachable | High | Launch and inspect actual surface where runtime permits |
| Partial slice misreported as full P1 | High | Keep roadmap unchecked and state remaining work |
