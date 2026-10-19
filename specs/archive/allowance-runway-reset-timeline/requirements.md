# Requirements Document

## Introduction

This spec starts the approved P1 roadmap with one complete cross-platform vertical slice: a typed native allowance attached to quota windows, exact source mapping for Hapo Hub USD and ElevenLabs character quotas, and native-unit rendering in macOS and Linux provider surfaces. It deliberately does not claim full P1 completion; behavior semantics for overage, top-up, hard-stop, and forecast confidence remain follow-up work.

## Requirements

### Requirement 1: Typed Native Allowance Contract
**Objective:** As a BirdNion user, I want quota amounts represented in their source-native unit so that display code never needs to parse prose or invent a percentage.

#### Acceptance Criteria
- **R1.1** A quota window shall optionally carry independently nullable `used`, `remaining`, and `limit` values plus a required native unit when allowance data is present.
- **R1.2** Missing allowance data shall remain absent and render as unavailable rather than as zero, 100%, or an estimated limit.
- **R1.3** Persisted macOS snapshots without the new allowance field shall continue to decode, and Rust-to-TypeScript payloads shall omit the field when unavailable.
- **R1.4** The contract shall not parse `subtitle` or other display copy to reconstruct numeric allowance values.

### Requirement 2: Exact Provider Mapping and Rendering
**Objective:** As a user of macOS or Linux, I want exact Hapo Hub and ElevenLabs allowance values rendered consistently so that the first P1 slice is observable on both products.

#### Acceptance Criteria
- **R2.1** Hapo Hub weekly windows shall expose exact USD used, remaining, and limit values derived only from the source-provided remaining and weekly budget values.
- **R2.2** ElevenLabs credit windows shall expose exact used and limit values in characters; remaining may be derived by exact subtraction only when both source values are present.
- **R2.3** macOS popover and Settings quota rows shall render the typed native values without changing legacy subtitle behavior for other providers.
- **R2.4** Linux provider cards and Settings quota rows shall render the same semantic values and units.
- **R2.5** Reset text shall use only an explicit source reset timestamp; a nominal window length or label shall not fabricate a reset time.

### Requirement 3: Verification and Roadmap Integrity
**Objective:** As a maintainer, I want the contract proven across serialization, provider mapping, and runtime rendering without falsely declaring the full P1 milestone complete.

#### Acceptance Criteria
- **R3.1** Automated tests shall prove macOS round-trip/backward-compatible decoding and Linux Rust provider mapping.
- **R3.2** Linux TypeScript tests or runtime smoke verification shall prove native-unit rendering and missing-allowance omission.
- **R3.3** macOS and Linux builds shall pass for the changed surfaces.
- **R3.4** The roadmap P1 checkboxes shall remain unchecked until overage/top-up/hard-stop and forecast-confidence semantics are implemented and separately verified.
