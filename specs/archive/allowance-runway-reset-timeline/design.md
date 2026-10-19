# Design Document

## Overview

This slice introduces a typed, optional per-window allowance across Swift, Rust, and TypeScript. It maps two existing providers with exact source values—Hapo Hub USD and ElevenLabs characters—and renders those values in macOS and Linux provider surfaces. Existing percentage behavior remains for percent-capable sources; absent allowance data stays absent.

### Goals
- Preserve source-native values without parsing localized display strings.
- Prove the same semantic contract on macOS and Linux.
- Stop provider-card reset text from inventing reset timestamps.

### Non-Goals
- Full P1 completion.
- Overage, top-up, hard-stop, and forecast-confidence semantics.
- Bulk provider migration or new provider APIs.
- Menu-bar, agenda, all-agents, or notification redesign.

## Architecture

```mermaid
flowchart LR
  S[Provider source payload] --> M[Provider mapper]
  M --> Q[QuotaWindow.allowance]
  Q --> C[Swift cache / Rust JSON IPC]
  C --> U[Popover and Settings renderers]
```

### Existing Architecture Analysis
- `QuotaWindow` is already the cross-platform per-window boundary.
- Swift cache decoding is explicitly backward compatible.
- Rust serializes `QuotaWindow` to camelCase JSON consumed by the TypeScript contract.
- Subtitles are presentation copy and may be localized; they are not data.

## Canonical Contracts & Invariants

| Contract Area | Canonical Decision | Applies To | Must Stay Consistent In |
|---|---|---|---|
| Native allowance | Optional per-window object; fields are independently optional | macOS/Linux | Swift model, Rust serde model, TS type |
| Missing values | Omit/Unknown; never synthesize zero, 100%, or limit | all providers | mappers and renderers |
| Exact derivation | `remaining = max(0, limit - used)` only from exact source used+limit | mapped providers | Hapo/ElevenLabs mappings |
| Reset timeline | Render only explicit source timestamp | popover/settings | Swift and TS renderers |
| Legacy copy | Never parse `subtitle` into numbers | all layers | projection and UI code |

<!-- contract:QuotaAllowance -->
```json
{
  "used": "number|null",
  "remaining": "number|null",
  "limit": "number|null",
  "unit": "usd|characters|requests|credits|tokens|count"
}
```

## Components and Interfaces

| Component | Layer | Intent | Requirements |
|---|---|---|---|
| `QuotaAllowance` | Domain | Preserve exact native fields and unit | 1.1–1.4 |
| Hapo/ElevenLabs mappers | Provider adapters | Populate exact source values | 2.1–2.2 |
| macOS quota renderers | SwiftUI | Display native values and explicit resets | 2.3, 2.5 |
| Linux quota renderers | TypeScript DOM | Display equivalent values and explicit resets | 2.4, 2.5 |

### QuotaAllowance
- `used`, `remaining`, and `limit` are optional `Double`/`f64`/`number`.
- `unit` is a closed Swift enum and validated string in Rust/TypeScript.
- At least one numeric field must be present at construction sites.
- Formatting is presentation-only; no formatted value is persisted.

### Rendering
- Preferred line: remaining + limit when both exist; otherwise used + limit; otherwise each available field.
- Currency uses the existing USD formatter/style.
- Count units use locale-aware integer/decimal formatting without coercing precision.
- Typed allowance replaces the mapped window's prose subtitle line to prevent duplicate information.
- Unknown allowance emits no native-value line. Percentage rendering is unchanged in this slice.

## Requirements Traceability

| Requirement | Components | Verification |
|---|---|---|
| 1.1–1.4 | cross-platform contract | Swift round-trip + legacy decode; Rust/TS build |
| 2.1–2.2 | provider mappers | Swift/Rust provider tests |
| 2.3–2.5 | four UI renderers | Linux DOM test, macOS build/runtime inspection |
| 3.1–3.4 | verification/docs | focused tests, builds, roadmap remains unchecked |

## Error Handling
- Invalid or non-finite source values result in absent allowance data, not placeholder zeroes.
- Missing reset timestamps render no reset text.
- Existing provider error handling remains authoritative.

## Testing Strategy
- Swift model round-trip and decoding of legacy JSON without allowance.
- Provider mapping assertions for exact Hapo/ElevenLabs values where existing seams permit.
- Rust inline provider mapping tests.
- Linux DOM renderer test for USD, characters, and absent allowance.
- macOS focused tests/build plus Linux Node/build/Cargo checks.

## Migration Strategy
- Add optional fields only; no persisted-data rewrite.
- Old Swift cache entries decode `allowance = nil`.
- Rust omits `allowance` in JSON when absent; TypeScript treats it as optional.
- Rollback safely ignores the new serialized field under normal Codable/serde unknown-field behavior.
