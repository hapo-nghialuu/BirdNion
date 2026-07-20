# Research & Design Decisions

---
**Purpose**: Capture discovery findings and rationale for the `codex-quota-auto-prime` feature.
**Usage**: Evidence trail backing requirements, design, and tasks.
---

## Summary
- **Feature**: `codex-quota-auto-prime`
- **Discovery Scope**: Extension (adds an opt-in scheduled action to an existing macOS menu-bar app)
- **Key Findings**:
  - The Codex 5-hour rate-limit window only begins counting from the *first* request after a reset. A single `codex exec "<prompt>"` starts that clock.
  - `codex-cli 0.143.0` is installed at `/opt/homebrew/bin/codex`; `codex exec` supports `-s read-only` and `--skip-git-repo-check`, which is enough for a harmless non-interactive prime.
  - The existing `QuotaService.refresh(forceProviderIDs:)` cadence already exposes the codex 5h window (`ProviderStatus(id:"codex").windows` → `QuotaWindow(label:"5 giờ", usedPct:)`) and already reconciles codex state on the codex path — a natural, no-new-timer host for `tick()`.
  - `CodexAccountStore.runLogin` is a ready-made off-main `Process` spawn pattern to copy for `codex exec`.

## Evidence Summary
This section is mandatory and was written before finalizing requirements, design, and tasks.

- **Codebase Scout**: Required
  - Result: All cited integration points verified against source on 2026-07-09.
  - Relevant files/modules:
    - `BirdNion/Providers/Codex/CodexAccountStore.swift` — `codexBinary()` (line 229) returns the codex path from a fixed candidate list; `runLogin(homePath:)` (line 242) is the canonical off-main `Process` spawn (`Task.detached(priority:.userInitiated)`, `executableURL`, `arguments`, env mutation, `Pipe()` stdout/stderr, `waitUntilExit()`, `terminationStatus == 0`); `systemAuthURL()` (line 36) = `~/.codex/auth.json`; `cliSwitchedID()` (line 279) tracks the currently installed CLI account.
    - `BirdNion/Services/QuotaService.swift` — `@MainActor final class QuotaService`; `refresh(forceProviderIDs:)` (line 209); codex-only sync-back already runs at line 232 (`if due.contains(where: { $0.id == "codex" })`); `import UserNotifications` (line 4); `QuotaNotifier.post(id:title:body:)` (line 483) is the notification helper; `statuses`/`displayStatuses` published.
    - `BirdNion/Models/ProviderStatus.swift` — `QuotaWindow` (line 10) has `label`, `usedPct: Int`, `remainingPct: Int`, `resetDate: Date?`; `ProviderStatus` (line 86) has `windows: [QuotaWindow]`. Codex 5h window label is the literal `"5 giờ"` (`CodexProvider.swift:165`, `CodexAppServerRPC.swift:69`).
    - `BirdNion/Services/SettingsStore.swift` — `@AppStorage("key") var … = default` pattern (lines 59–92), e.g. `sessionQuotaNotificationsEnabled`.
    - `BirdNion/Views/Settings/ProvidersPane.swift` — `CodexAccountsCard()` rendered under `if rows[idx].id == "codex"` (line 537) inside the provider `detail` view.
    - `BirdNion/Views/Settings/GeneralPane.swift` — existing `SettingsLabeledRow` + `Toggle(...).labelsHidden().toggleStyle(.switch)` + `Picker` rows (lines 13–142) — the exact idiom to reuse.
    - `BirdNion/Views/Settings/SettingsSceneRoot.swift` — `SettingsCard` (164), `SettingsRowDivider` (196), `SettingsLabeledRow` (220).
    - `BirdNion/Services/AppLocalizer.swift` — `enum L10n` (3); `t(_:_:)` (16); `f(_:_:_:)` (21); `vi` table (307); `en` table (657). Keys are namespaced (`settings.*`, `notification.*`).
    - `BirdNionTests/CodexProviderTests.swift` — XCTest, `@testable import BirdNion`; existing target for the pure-decision unit tests.
  - Existing patterns/contracts: off-main `Process` spawn; `QuotaNotifier.post`; `@AppStorage` settings; `SettingsLabeledRow` UI; `L10n` vi+en tables.
  - Tests affected: `BirdNionTests/CodexProviderTests.swift` (extended, not broken). No existing test relies on the new keys.
- **External / Current Research**: Required
  - Result: `codex exec --help` on the installed `codex-cli 0.143.0` confirms `codex exec [OPTIONS] [PROMPT]` with `-s/--sandbox <read-only|workspace-write|danger-full-access>`, `--skip-git-repo-check`, `-m/--model`, `-C/--cd <DIR>`, and the forbidden `--dangerously-bypass-approvals-and-sandbox`.
  - Primary sources: `codex exec --help` output (local, 2026-07-09); `codex --version` → `codex-cli 0.143.0`.
  - Current constraints: `read-only` is the safest sandbox that still runs a request; a trivial prompt (e.g. `"say ok"`) suffices to start the 5h clock. The dangerous bypass flag must never be used.
- **Selected Decision**:
  - Decision: A pure `shouldPrime(now:lastRun:scheduledMinutes:windowUsedPct:enabled:) -> Bool` gate + a `prime() async` that runs `codex exec -s read-only --skip-git-repo-check "<tiny prompt>"` off-main against the current `~/.codex` (no `CODEX_HOME` override), then stamps `codexAutoPrimeLastRun`. Driven by a `tick()` called from the existing `QuotaService` codex refresh path.
  - Why it fits the codebase: reuses the existing refresh cadence (no new Timer), the existing `Process` spawn idiom, the existing notification helper, and the existing `@AppStorage`/`SettingsLabeledRow`/`L10n` conventions. Hosting `CodexQuotaPrimer` inside `CodexAccountStore.swift` avoids pbxproj edits (no synced groups).
  - Why it fits external constraints: `codex exec -s read-only --skip-git-repo-check` is a supported, safe, non-interactive invocation on the installed CLI.
- **Rejected Alternatives**:
  - Dedicated `Timer`/polling loop for priming — rejected (YAGNI): the refresh cadence already ticks while the app is awake and gives catch-up for free.
  - New `CodexQuotaPrimer.swift` file — rejected: pbxproj has no synced groups, so a new file needs manual pbxproj surgery; hosting in `CodexAccountStore.swift` avoids that risk.
  - Redeem/POST of Codex "reset-credit" — rejected: out of scope; a different mechanism than window priming and explicitly not requested.
  - Priming multiple accounts — rejected: out of scope; prime only the current CLI identity at `~/.codex/auth.json`.
  - `--dangerously-bypass-approvals-and-sandbox` — rejected: unsafe; `read-only` runs the request fine.
- **Remaining Gaps / Questions**:
  - Exact wall-clock the machine is awake determines catch-up timing; accepted by design (only primes while awake).
  - Whether `usedPct == 0` can transiently misreport right after a reset — mitigated by the "already primed today" dedup so at most one prime per calendar day.
- **Downstream Task & Test Implications**:
  - Task implication: R1 settings+UI, R2 primer engine + pure decision + unit tests, R3 QuotaService wiring + optional notification, R4 integration/reachability + build/test.
  - Test/verification implication: the pure `shouldPrime(...)` is unit-tested in `BirdNionTests/CodexProviderTests.swift`; wiring/reachability proven by build + a grep/trace of the `tick()` call from `refresh(...)`.

## Codebase Scout

| Area | Finding | Evidence / Path | Implication |
|------|---------|-----------------|-------------|
| Project surface | macOS SwiftUI menu-bar app, 23 providers | `README.md` | Native Swift, XCTest, xcodebuild verification |
| Relevant files | Codex account/process store | `CodexAccountStore.swift:229,242,36,279` | Host `CodexQuotaPrimer` here; reuse spawn |
| Relevant files | Quota refresh cadence + codex path | `QuotaService.swift:209,232,483` | Call `tick()` here; reuse `QuotaNotifier` |
| Existing patterns | `@AppStorage` settings | `SettingsStore.swift:59-92` | Add 3 new keys |
| Existing patterns | Settings rows | `GeneralPane.swift:13-142`, `SettingsSceneRoot.swift:164,196,220` | Reuse `SettingsLabeledRow`/`SettingsCard` |
| Contracts | Codex 5h window shape | `ProviderStatus.swift:10,86`; label `"5 giờ"` | Read `usedPct` for the idle check |
| Tests | Codex XCTest target | `BirdNionTests/CodexProviderTests.swift` | Extend with `shouldPrime` cases |
| Blast radius | Additive; no signature changes | — | Low risk; opt-in default off |
| Staleness / conflicts | None; new keys unused elsewhere | — | No legacy breakage |

## External / Current Research

| Question | Source | Finding | Decision Impact |
|----------|--------|---------|-----------------|
| Does `codex exec` exist and with what flags? | `codex exec --help` (codex-cli 0.143.0, 2026-07-09) | `codex exec [OPTIONS] [PROMPT]`; `-s read-only`, `--skip-git-repo-check`, `-m`, `-C` present | Use `-s read-only --skip-git-repo-check` + tiny prompt |
| Safest sandbox that still runs a request? | `codex exec -s` possible values | `read-only \| workspace-write \| danger-full-access` | Choose `read-only` |
| Is the dangerous bypass needed? | `--help` | `--dangerously-bypass-approvals-and-sandbox` exists but is unsafe | Forbidden; `read-only` suffices |
| Does one request start the 5h clock? | Domain fact (user-verified) | Window counts from first request post-reset | Prime = one `codex exec` when window idle |

## Design Decisions

### Decision: Pure decision function + refresh-driven tick
- **Context**: Need a testable, deterministic prime gate with catch-up, no new polling.
- **Alternatives Considered**:
  1. New Timer loop — more code, duplicate cadence.
  2. Impure gate reading `Date()`/settings inside — not unit-testable.
- **Selected Approach**: `shouldPrime(now:lastRun:scheduledMinutes:windowUsedPct:enabled:) -> Bool` (pure) invoked by `tick()` on the existing refresh; `prime()` spawns `codex exec` off-main and stamps `codexAutoPrimeLastRun`.
- **Rationale**: Minimal surface, reuses proven idioms, free catch-up per awake refresh, fully unit-testable core.
- **Status**: Accepted
- **Trade-offs**: Catch-up timing bounded by app-awake refresh cadence (accepted). Each prime spends a small real quota (accepted).
- **Follow-up**: Confirm `tick()` is reachable from `refresh(...)` at integration.

### Decision: Host `CodexQuotaPrimer` in `CodexAccountStore.swift`
- **Context**: pbxproj has no synced groups; new files need manual pbxproj edits.
- **Selected Approach**: Add `CodexQuotaPrimer` as a new type inside the existing `CodexAccountStore.swift`.
- **Rationale**: Avoids pbxproj risk; co-locates with the reused `codexBinary()`/spawn pattern.
- **Status**: Accepted
- **Trade-offs**: Slightly larger file; acceptable and below the 200-line concern for the added type.

## Risks & Mitigations
- Transient `usedPct == 0` misread right after reset → per-calendar-day dedup caps to one prime/day.
- `codex` binary missing → `prime()` no-ops (guard like `runLogin`); no crash, no stamp.
- Priming spends real quota → opt-in, default off; documented and user-accepted.
- Notification spam → at most one prime/day, so at most one "primed" notification/day.

## References
- `codex exec --help` — codex-cli 0.143.0 (local, 2026-07-09) — flag set and sandbox modes.
- `CodexAccountStore.swift`, `QuotaService.swift`, `ProviderStatus.swift`, `SettingsStore.swift`, `GeneralPane.swift`, `ProvidersPane.swift`, `SettingsSceneRoot.swift`, `AppLocalizer.swift` — integration points (paths+lines above).
