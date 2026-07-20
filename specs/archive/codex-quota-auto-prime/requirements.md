# Requirements Document

## Introduction

BirdNion is a macOS SwiftUI menu-bar app that tracks AI provider quotas. This feature adds an **opt-in** capability that automatically "primes" (activates) the Codex 5-hour rate-limit window by sending one small `codex exec` request on a user-chosen schedule, so the window's reset cycle aligns with the user's working hours.

Domain fact (verified): the Codex 5h window only starts counting from the *first* request after a reset. One `codex exec "<prompt>"` against the account installed at `~/.codex/auth.json` is enough to start that clock. Each prime is a real (small) request that consumes quota — inherent to the approach and accepted by the user.

The feature is default-off, targets only the current CLI identity, skips priming when the window is already active, and catches up on a missed schedule while the app is awake.

## Requirements

### Requirement 1: Auto-Prime Settings & UI
**Objective:** As a Codex user, I want a toggle and a scheduled time to enable auto-priming, so that I control whether and when the 5h window is activated.

#### Acceptance Criteria
- **R1.1** Where the feature is included, the SettingsStore shall expose an `@AppStorage("codexAutoPrimeEnabled") Bool` defaulting to `false`.
- **R1.2** Where the feature is included, the SettingsStore shall expose an `@AppStorage("codexAutoPrimeMinutes") Int` (minutes since midnight, 0..1439) defaulting to `535` (08:55).
- **R1.3** Where the feature is included, the SettingsStore shall expose an `@AppStorage("codexAutoPrimeLastRun") Double` (epoch seconds; `0` = never) defaulting to `0`.
- **R1.4** When the user opens the Codex provider detail in Settings, the app shall render an auto-prime toggle and an hour+minute time control using the existing `SettingsCard`/`SettingsLabeledRow`/`SettingsRowDivider` components.
- **R1.5** When the user toggles the control or changes the time, the app shall persist the change to the corresponding `@AppStorage` key with no other side effects.
- **R1.6** Where user-facing strings are shown, the app shall resolve every new label/notification string through `L10n` with entries present in BOTH the `vi` and `en` tables.

### Requirement 2: Prime Decision Engine (Pure) & Executor
**Objective:** As a maintainer, I want a pure, unit-testable decision function plus a safe executor, so that prime timing is deterministic and the request is harmless.

#### Acceptance Criteria
- **R2.1** The `CodexQuotaPrimer` type shall expose a pure function `shouldPrime(now:lastRun:scheduledMinutes:windowUsedPct:enabled:) -> Bool` that performs no I/O and reads no ambient `Date()` (time is passed via `now`).
- **R2.2** When `enabled` is `false`, `shouldPrime` shall return `false`.
- **R2.3** When the 5h window is active (`windowUsedPct` is non-nil and `> 0`), `shouldPrime` shall return `false` (skip to save tokens; only prime when idle).
- **R2.4** When `now`'s time-of-day is before `scheduledMinutes`, `shouldPrime` shall return `false`.
- **R2.5** When a prime already occurred today — `lastRun` (epoch seconds) falls on the same calendar day as `now` per `Calendar.current.isDate(_:inSameDayAs:)` — `shouldPrime` shall return `false`.
- **R2.6** When `enabled` is `true` AND `now` is at/after `scheduledMinutes` AND no prime has occurred today AND the window is idle (`windowUsedPct` is `nil` or `0`), `shouldPrime` shall return `true` (this covers both on-time and catch-up-after-miss cases).
- **R2.7** When `prime()` runs, the executor shall spawn `codex exec` off the main thread using the existing `Process` pattern, targeting the current `~/.codex` (no `CODEX_HOME` override) so it primes the installed CLI identity.
- **R2.8** When `prime()` builds its command, it shall use `-s read-only` and `--skip-git-repo-check` with a trivial harmless prompt, and shall NEVER use `--dangerously-bypass-approvals-and-sandbox`.
- **R2.9** If the `codex` binary is not found, `prime()` shall no-op without crashing and without stamping `codexAutoPrimeLastRun`.
- **R2.10** When `prime()` completes its spawn attempt, it shall record `codexAutoPrimeLastRun = now` (epoch seconds) so the same day is not primed again.

### Requirement 3: QuotaService Wiring & Optional Notification
**Objective:** As a user, I want priming to happen automatically during normal app operation, so that no manual action or extra polling loop is needed.

#### Acceptance Criteria
- **R3.1** When `QuotaService.refresh(forceProviderIDs:)` processes the codex path (where codex is due), the app shall call `CodexQuotaPrimer.tick(...)` exactly once per refresh cycle, reusing the existing cadence (no new Timer/polling loop).
- **R3.2** When `tick(...)` runs, it shall read the codex 5h window `usedPct` from the current codex `ProviderStatus.windows` (label `"5 giờ"`) and the current settings, evaluate `shouldPrime(...)`, and invoke `prime()` only when the decision is `true`.
- **R3.3** While the app is running after a missed scheduled time with no prime yet today and an idle window, the next refresh tick shall prime (catch-up), because `tick(...)` runs on every awake refresh.
- **R3.4** Where notification of prime is included, the app shall post a local notification "đã kích hoạt window 5h Codex lúc HH:mm" (localized vi/en) via the existing `QuotaNotifier`/`UserNotifications` infra after a successful prime.
- **R3.5** When priming logs, the app shall NOT log token, credential, or prompt-response contents.

## Non-Functional Requirements

### Requirement 4: Performance & Reliability
**Objective:** As a system owner, I want priming to be cheap, safe, and non-blocking, so that it never degrades the app.

#### Acceptance Criteria
- **R4.1** The prime executor shall run off the main thread and shall not block `QuotaService.refresh(...)`'s UI-affecting path.
- **R4.2** The app shall perform at most one prime per calendar day per the `codexAutoPrimeLastRun` dedup, even if multiple refresh ticks satisfy the schedule.
- **R4.3** If the prime spawn fails or the binary is missing, the app shall continue normal operation with no crash and no user-visible error state.

### Requirement 5: Security & Privacy
**Objective:** As a security stakeholder, I want the prime to be harmless and leak nothing, so that the feature is safe to ship.

#### Acceptance Criteria
- **R5.1** The prime command shall use the read-only sandbox (`-s read-only`) and `--skip-git-repo-check`, and shall NEVER pass `--dangerously-bypass-approvals-and-sandbox` or any `danger-*` sandbox mode.
- **R5.2** The prime prompt shall be trivial and harmless (e.g. "say ok"); its only purpose is to start the 5h clock.
- **R5.3** The feature shall be opt-in (default `false`) and shall never prime while disabled.
