# Research & Design Decisions

## Summary
- **Feature**: `allowance-runway-reset-timeline`
- **Discovery Scope**: Cross-platform extension of the existing quota contract.
- **Key Findings**:
  - `QuotaWindow` is the only per-window semantic contract shared by macOS and Linux; native numbers currently become `subtitle` prose.
  - Reset/pace projections already exist, but provider-card renderers fabricate reset timestamps from `lastUpdated + windowSeconds` or labels.
  - Hapo Hub and ElevenLabs expose exact native values on both platforms and prove currency plus count units without adding new provider integrations.

## Evidence Summary
- **Codebase Scout**: Required
  - Result: completed by `AllowanceScout` on 2026-09-21.
  - Relevant files/modules: `BirdNion/Models/ProviderStatus.swift`, `BirdNion/Providers/HapoHubProvider.swift`, `BirdNion/Providers/ElevenLabsProvider.swift`, `BirdNion/Views/QuotaPanel.swift`, `BirdNion/Views/Settings/ProviderCostSection.swift`, `linux/src-tauri/src/providers/{mod,hapo,elevenlabs}.rs`, `linux/src/{provider-tab,settings-provider-detail}.ts`.
  - Existing patterns/contracts: optional Swift Codable fields with custom backward-compatible decoding; Rust serde camelCase IPC; TypeScript structural types.
  - Tests or checks affected: `ProviderStatusTests`, inline Rust provider tests, Linux Node/Vite UI tests, macOS/Linux builds.
- **External / Current Research**: Skipped
  - Rationale: the feature preserves already parsed source fields and does not introduce a vendor API, dependency, or protocol claim.
- **Selected Decision**:
  - Add one optional `QuotaAllowance` value to `QuotaWindow` in Swift, Rust, and TypeScript; map Hapo Hub and ElevenLabs only; render it in provider popover and Settings rows.
  - This fits the current codebase because it extends the existing canonical window contract and remains backward compatible.
- **Rejected Alternatives**:
  - Reuse macOS-only `ProviderCostSnapshot` — provider-level, currency-focused, and absent on Linux.
  - Parse existing subtitles — display copy is localized and cannot be authoritative data.
  - Migrate every provider at once — contradicts the roadmap's explicit provider-expansion defer and materially increases semantic risk.
- **Remaining Gaps / Questions**:
  - Overage, top-up, hard-stop, source-authority per field, and forecast-confidence semantics require a later P1 slice.
- **Downstream Task & Test Implications**:
  - The roadmap remains unchecked after this slice.
  - Serialization and UI omission behavior require permanent regression coverage.

## Codebase Scout

| Area | Finding | Evidence / Path | Implication |
|---|---|---|---|
| Canonical model | Native values are not typed per window | `BirdNion/Models/ProviderStatus.swift`; `linux/src-tauri/src/providers/mod.rs` | Extend `QuotaWindow`, not provider-specific UI state |
| Persistence | Swift uses custom decoding for cache compatibility | `QuotaWindow.init(from:)` | Decode new field with `decodeIfPresent` |
| IPC | Rust serializes camelCase into TS | `providers/mod.rs`; `provider-tab.ts` | Keep identical field semantics and optional omission |
| Source mappings | Hapo has remaining+budget USD; ElevenLabs has count+limit | provider files named above | No subtitle parsing or heuristic values |
| Reset UI | Provider rows infer reset from duration/labels | `QuotaPanel.WindowRow`; `provider-tab.windowRow` | Remove fabricated reset fallback |
| Tests | Existing model/provider/UI test seams exist | `BirdNionTests`; `linux/test`; inline Rust tests | Add focused contract and rendering proofs |

## Architecture Pattern Evaluation

| Option | Strengths | Risks / Limitations | Decision |
|---|---|---|---|
| Per-window typed allowance | Exact source ownership; cross-platform; extensible | First Rust field touches many literals | Selected |
| Provider-level cost snapshot | Existing macOS precedent | Wrong cardinality; no Linux contract | Rejected |
| Subtitle parsing | Small edit | Localized, lossy, unauthoritative | Rejected |

## Design Decisions

### Decision: Preserve missing fields as missing
- **Selected Approach**: `used`, `remaining`, and `limit` are independent optionals; the entire allowance is absent when no native value is authoritative.
- **Rationale**: Missing source data must not become zero, 100%, or an estimated ceiling.
- **Status**: Accepted.

### Decision: Exact arithmetic is allowed, estimation is not
- **Selected Approach**: remaining may be calculated as `limit - used` only when both source fields are exact. Reset timestamps may not be calculated from nominal duration.
- **Rationale**: Arithmetic preserves the source contract; a reset timestamp inferred from fetch time does not.
- **Status**: Accepted.

## Risks & Mitigations
- Rust `QuotaWindow` literal churn — use a defaulted optional field consistently and validate with `cargo test`.
- UI duplicate prose — typed allowance supersedes subtitle only on mapped windows; legacy providers retain subtitle.
- Milestone overclaim — keep P1 roadmap boxes unchecked and list remaining semantics explicitly.
