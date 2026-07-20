# Research & Design Decisions

## Summary
- **Feature**: `ai-statusbar` — macOS menu bar app for AI quota tracking + Claude Code config editing
- **Discovery Scope**: Extension (greenfield, integrates with 2 external APIs and local files)
- **Key Findings**:
  - MiniMax publishes `/v1/token_plan/remains` with rolling 5h + weekly windows; same `Subscription Key` used for inference works
  - macOS Keychain is the right store for tokens; menu bar apps run as `LSUIElement` (no Dock icon) and are sandboxed
  - Writing to `~/.claude/settings.json` must be atomic with a `.bak` to avoid corrupting Claude Code's runtime config
  - Provider abstraction needed because gateway formats differ (MiniMax: 2 windows; Hapo: TBD shape)

## Evidence Summary

- **Codebase Scout**: Required
  - Result: Empty repo, greenfield. Only `CLAUDE.md`, `docs/system-architecture.md`, `docs/development-roadmap.md` exist.
  - Relevant files: design doc + roadmap pre-codified the architecture.
  - Existing patterns: None yet.
  - Tests or checks affected: N/A.
- **External / Current Research**: Required (third-party APIs, platform policies)
  - Result: MiniMax quota endpoint found via `MiniMax-M2.7` GitHub issue #48; CodexBar pattern verified.
  - Primary sources: MiniMax issue #48 (response shape), CodexBar repo (Swift/SwiftUI architecture pattern), Apple docs (Keychain Services, MenuBarExtra).
  - Current constraints: macOS 13+ required for `MenuBarExtra`; Xcode 15+ for SwiftUI.
- **Selected Decision**:
  - Decision: Swift + SwiftUI app with `MenuBarExtra`, `QuotaProvider` protocol, Keychain for tokens, atomic write with backup for settings.json.
  - Why it fits the current codebase: Greenfield, so any clean SwiftUI pattern works; chosen pattern mirrors CodexBar (reference) and reuses `@Published` for state.
  - Why it fits current external constraints: macOS-native APIs only, no third-party runtime; works offline; Keychain is system-mandated for secure secret storage on macOS.
- **Rejected Alternatives**:
  - Tauri/Electron — rejected (heavier runtime, not "menu bar" native feel; rejected by user explicitly).
  - Hard-coding provider URLs in source — rejected (BOSS uses multiple gateways; config-driven providers).
  - Plaintext token storage — rejected (security + macOS guideline).
  - Direct `JSONSerialization` for settings.json with no backup — rejected (Claude Code would crash on malformed file).
- **Remaining Gaps / Questions**:
  - Hapo Hub endpoint exact URL + auth header + JSON response fields — BOSS will provide during task R1-02. Mock provider allows UI to run before that.
  - Number of `model_remains[]` entries per account — observed 1 in issue; MVP takes first.
- **Downstream Task & Test Implications**:
  - Task R1-01 (MiniMaxProvider) needs unit tests for the 2-window JSON parser using a fixture of the issue #48 payload.
  - Task R0-02 (KeychainService) needs an integration check that round-trips a fake token.
  - Task R2-01 (ConfigService) needs a property test that read → write → read produces equal JSON for valid input.

## Codebase Scout

| Area | Finding | Evidence / Path | Implication |
|------|---------|-----------------|-------------|
| Project surface | Greenfield Swift app | `ls /Users/nghialuutrung/Desktop/statusbar` → only docs + CLAUDE.md | Full design freedom |
| Relevant files/modules | None | n/a | Scaffold fresh Xcode project |
| Existing patterns | None | n/a | Adopt standard SwiftUI app structure |
| Contracts | `docs/system-architecture.md` defines Provider protocol + data model | docs/ | Carry forward verbatim into design.md |
| Tests and verification | None | n/a | Set up Swift Testing / XCTest in scaffold |
| Blast radius | Local to user home + Keychain | n/a | No other consumers; backup is the only safety net |
| Staleness / conflicts | None | n/a | n/a |

## External / Current Research

| Question | Source | Finding | Decision Impact |
|----------|--------|---------|-----------------|
| How to query MiniMax quota? | MiniMax-M2.7 issue #48 (community-verified) | `GET /v1/token_plan/remains` with `Authorization: Bearer <Subscription Key>`; response has `model_remains[].{current_interval_remaining_percent, current_weekly_remaining_percent}` | Direct fetch in `MiniMaxProvider.fetch()`; two `QuotaWindow` results |
| CodexBar architecture? | github.com/steipete/CodexBar | Swift + SwiftUI, `MenuBarExtra`, provider abstraction, polls local files / CLI rather than hidden APIs | Use as reference for app shell + polling model |
| Secure token storage on macOS? | Apple Keychain Services | `kSecClassGenericPassword` items per provider id; no sandbox entitlement needed for non-App-Sandbox apps | Wrap in `KeychainService`; service = `AIStatusbar` |
| Atomic settings file write? | Conventional macOS pattern | Write to temp file in same dir, then `rename(2)`; on error restore from `.bak` | Apply in `ConfigService.write()` |
| Hapo Hub quota endpoint? | <HAPO_HOST> probing (HTTP 401/308) | Endpoint + auth shape unknown; need BOSS to supply | `HapoHubProvider` deferred behind mock |

## Research Log

### MiniMax quota discovery
- **Context**: BOSS uses MiniMax platform officially; need to know if/where quota is queryable.
- **Sources Consulted**: GitHub `MiniMax-AI/MiniMax-M2.7` issues (community probing), web search.
- **Findings**: `/v1/token_plan/remains` exists and returns rolling-window percent (5h + weekly). Issue #48 exposes exact JSON shape with field names.
- **Implications**: No need to scrape the dashboard; we can use the same `Subscription Key` already in `~/.claude/settings.json` for `ANTHROPIC_BASE_URL=https://api.minimax.io/...` style providers — but MiniMax key is separate. So `MiniMaxProvider` needs its own token slot in Keychain.

### Reference app (CodexBar)
- **Context**: Confirm Swift/SwiftUI menu bar pattern is canonical.
- **Sources Consulted**: CodexBar README, repo file tree.
- **Findings**: Swift, SwiftUI, `MenuBarExtra` (macOS 13+), no web wrapper. Provider abstraction is internal.
- **Implications**: Match style — single Xcode project, `App` + `Views` + `Services` + `Models` + `Providers` group.

### Claude Code settings.json safety
- **Context**: Writing to `~/.claude/settings.json` could break Claude Code if done wrong.
- **Sources Consulted**: Project's own `~/.claude/settings.json` (current state), conventional macOS atomic-write pattern.
- **Findings**: Claude Code parses settings on each spawn; partial file = immediate failure.
- **Implications**: Atomic write (temp + rename) + `.bak` rotation on every save.

## Architecture Pattern Evaluation

| Option | Description | Strengths | Risks / Limitations | Notes |
|--------|-------------|-----------|---------------------|-------|
| A. SwiftUI `MenuBarExtra` + `@StateObject` services | Native app, observed state via `ObservableObject` | Simplest native path, no lifecycle juggling | macOS 13+ only | **Selected** |
| B. AppKit `NSStatusItem` with manual SwiftUI hosting | Works on older macOS | Wider compat | More boilerplate, weaker integration with SwiftUI updates | Deferred unless BOSS needs <13 |
| C. Tauri/Electron | Web stack | Reuse web skills | Heavy runtime, not native feel | Rejected by BOSS |

## Design Decisions

### Decision: `MenuBarExtra` shell with popover (Option A)
- **Context**: macOS 13+ available on BOSS machine; simpler than `NSStatusItem`.
- **Alternatives Considered**:
  1. `NSStatusItem` (works on older macOS)
  2. Tauri/Electron (web stack)
- **Selected Approach**: `MenuBarExtra` with attached `Popover` SwiftUI view; icon shows lowest remaining % or ⚠️.
- **Rationale**: Native, small, matches CodexBar pattern, BOSS approved.
- **Status**: Accepted
- **Trade-offs**: macOS 13+ only — acceptable since BOSS is on current macOS.
- **Follow-up**: Verify deployment target on BOSS machine during scaffold.

### Decision: Protocol-based provider abstraction
- **Context**: MiniMax and Hapo have different response shapes; future providers likely too.
- **Alternatives Considered**:
  1. One big `QuotaService` with provider-specific code
  2. JSONPath-style field configuration per provider
- **Selected Approach**: `QuotaProvider` protocol; each adapter owns its own response parsing.
- **Rationale**: Compile-time safety + BOSS can add providers later without touching UI.
- **Status**: Accepted
- **Trade-offs**: Slightly more code than JSONPath; clearer than hard-coding.
- **Follow-up**: Defer 3rd provider until BOSS needs one.

### Decision: Keychain for tokens, masked display
- **Context**: API keys in plaintext on disk = leak risk.
- **Alternatives Considered**:
  1. Encrypted file in app support dir
  2. macOS Keychain
- **Selected Approach**: `KeychainService` wraps `kSecClassGenericPassword` items keyed by provider id.
- **Rationale**: System-managed, no extra crypto needed.
- **Status**: Accepted
- **Trade-offs**: Keychain failures (e.g., user keychain locked) need graceful degradation; service has to surface the error.
- **Follow-up**: Test on first launch with empty keychain.

### Decision: Atomic write with `.bak` for settings.json
- **Context**: Claude Code crashes on malformed settings.
- **Alternatives Considered**:
  1. Best-effort write
  2. Atomic write + `.bak` rotation
- **Selected Approach**: Read current → write to `settings.json.tmp` in same dir → `rename` → if `rename` fails, restore from previous `.bak`; rotate `.bak` on every successful save.
- **Rationale**: Survives mid-write power loss; keeps one prior good copy.
- **Status**: Accepted
- **Trade-offs**: One extra file in `~/.claude/` (`.bak`); acceptable.
- **Follow-up**: Verify Claude Code picks up changes after save (kill-restart? or hot reload? — out of MVP scope).

## Risks & Mitigations

- **R1: Token leak in logs** — Mitigation: never `print` / `os_log` raw key, even in debug builds; CI lint to grep for `print.*key`.
- **R2: settings.json write corruption** — Mitigation: atomic write + `.bak` rotation (above).
- **R3: Hapo Hub endpoint unknown** — Mitigation: `HapoHubProvider` shipped as mock for MVP; real endpoint swapped in once BOSS provides spec.
- **R4: MiniMax response schema drift** — Mitigation: parser tolerates extra fields, fails soft into `error` rather than crash; integration test against recorded fixture.
- **R5: User configures wrong scope (project vs global)** — Mitigation: UI shows full file path being edited; project picker is explicit.

## References

- MiniMax token plan issue #48 — https://github.com/MiniMax-AI/MiniMax-M2.7/issues/48 — response shape
- CodexBar — https://github.com/steipete/CodexBar — Swift/SwiftUI menu bar reference
- Apple: MenuBarExtra — https://developer.apple.com/documentation/swiftui/menubarextra
- Apple: Keychain Services — https://developer.apple.com/documentation/security/keychain_services
- Project's own docs: `/Users/nghialuutrung/Desktop/statusbar/docs/system-architecture.md`
