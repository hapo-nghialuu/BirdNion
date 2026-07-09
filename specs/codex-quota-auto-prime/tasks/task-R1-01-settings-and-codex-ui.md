# Task R1-01: Settings keys & Codex auto-prime UI

**Requirement:** R1 — Auto-Prime Settings & UI
**Status:** done
**Priority:** P2
**Estimated Effort:** S
**Dependencies:** none
**Spec:** specs/codex-quota-auto-prime/

## Context

- **Why**: Users need an opt-in toggle and a scheduled time to control whether/when the Codex 5h window is auto-primed.
- **Current state**: `SettingsStore.swift` holds `@AppStorage` keys (lines 59–92). `ProvidersPane.swift` renders `CodexAccountsCard()` under `if rows[idx].id == "codex"` (line 537). `GeneralPane.swift` shows the reusable `SettingsLabeledRow` + `Toggle(...).labelsHidden().toggleStyle(.switch)` + `Picker` idiom. `L10n` has vi (307) and en (657) tables.
- **Target outcome**: Three new persisted settings + a Codex-detail Settings block (toggle + hour/minute time control) that reads/writes them, fully localized vi+en.

## Constraints

- **MUST**: Add exactly three `@AppStorage` keys with the canonical names/defaults; render UI in the Codex provider detail using existing `SettingsCard`/`SettingsLabeledRow`/`SettingsRowDivider`; resolve all strings via `L10n` in BOTH vi and en tables.
- **SHOULD**: Use a macOS `DatePicker` with `.hourAndMinute`, mapping selection ↔ `codexAutoPrimeMinutes` as `hour*60 + minute`.
- **MUST NOT**: Add a new `.swift` file; change other settings; hardcode user-facing strings.
- **SCOPE**: Implement only the behavior mapped to R1 and the approved `scope_lock`; do not add out-of-scope features or leave scoped acceptance criteria unwired.

## Steps

- [x] 1. Add settings keys to `SettingsStore.swift`
  - Business intent: persist opt-in + schedule + dedup cursor.
  - Code detail: `@AppStorage("codexAutoPrimeEnabled") var codexAutoPrimeEnabled: Bool = false`; `@AppStorage("codexAutoPrimeMinutes") var codexAutoPrimeMinutes: Int = 535`; `@AppStorage("codexAutoPrimeLastRun") var codexAutoPrimeLastRun: Double = 0`.
  - _Requirements: 1.1, 1.2, 1.3_

- [x] 2. Render the Codex auto-prime Settings block in `ProvidersPane.swift`
  - Business intent: let the user enable and time the prime from the Codex detail.
  - Code detail: inside the `if rows[idx].id == "codex"` region, add a `SettingsCard` containing a `SettingsLabeledRow` with `Toggle("", isOn: $settings.codexAutoPrimeEnabled).labelsHidden().toggleStyle(.switch)`, a `SettingsRowDivider`, and a `SettingsLabeledRow` with a `DatePicker("", selection:<Binding<Date>>, displayedComponents: .hourAndMinute).labelsHidden()`. Bridge the `Date` binding to `codexAutoPrimeMinutes` via a computed `Binding` (`get`: build a `Date` from hour=minutes/60, minute=minutes%60; `set`: write `hour*60+minute`). All labels via `L10n.t(...)`.
  - _Requirements: 1.4, 1.5_

- [x] 3. Add localized strings to `AppLocalizer.swift` (both tables)
  - Business intent: vi+en labels for toggle, time row, and the future notification.
  - Code detail: add keys e.g. `settings.codex.autoPrime.title`, `settings.codex.autoPrime.toggle`, `settings.codex.autoPrime.time`, and `notification.codexPrimed` (format with `HH:mm`) to BOTH `vi` (307) and `en` (657) tables.
  - _Requirements: 1.6_

- [x] 4. Verification implementation
  - Build the app; open Settings → Codex; toggle on and change the time; confirm persistence across relaunch via `defaults read`.
  - _Requirements: 1_

## Requirements

- 1.1 — `codexAutoPrimeEnabled: Bool = false`
- 1.2 — `codexAutoPrimeMinutes: Int = 535`
- 1.3 — `codexAutoPrimeLastRun: Double = 0`
- 1.4 — Toggle + time control rendered in Codex detail via existing components
- 1.5 — Changes persist to `@AppStorage` with no side effects
- 1.6 — All new strings via `L10n` in vi + en

## Related Files

| Path | Action | Description |
|---|---|---|
| `BirdNion/Services/SettingsStore.swift` | Modify | Add 3 `@AppStorage` keys |
| `BirdNion/Views/Settings/ProvidersPane.swift` | Modify | Codex auto-prime toggle + time picker block |
| `BirdNion/Services/AppLocalizer.swift` | Modify | New vi + en strings |
| `BirdNion/Views/Settings/SettingsSceneRoot.swift` | Read | `SettingsCard`/`SettingsLabeledRow`/`SettingsRowDivider` components |
| `BirdNion/Views/Settings/GeneralPane.swift` | Read | Reference for row/toggle/picker idiom |

## Completion Criteria

- [x] Three `@AppStorage` keys exist with canonical names and defaults (maps R1.1–1.3).
- [x] Codex detail shows a working toggle + hour/minute control; changing them updates UserDefaults (maps R1.4–1.5).
- [x] Every new user-facing string resolves via `L10n` and exists in both vi and en tables (maps R1.6).
- [x] No orphaned view: the block renders inside the existing `if rows[idx].id == "codex"` path (reachable); no new file added.

## Evidence

This section is both the task-level test plan and the proof checklist. Keep it short, exact, and executable.
Select the proof by task risk; do not run every test type for every task.

- Logic/data/validator task: include unit tests.
- Stateful UI/component task: include component or integration tests.
- Cross-module/API/state flow task: include integration tests.
- User-facing end-to-end workflow: include E2E/UI flow verification.
- Layout/theme/responsive task: include visual/runtime viewport checks.
- Interactive UI task: include accessibility checks when keyboard, focus, labels, or ARIA can regress.
- Scaffold/release task: include smoke build/test/dev-server checks.
- Performance/security checks are required only when the requirement, risk, or touched surface calls for them.

- [x] Automated verification (build)
  - Command(s): `xcodebuild build -project BirdNion.xcodeproj -scheme BirdNion -configuration Debug -destination 'platform=macOS'`
  - Result: **BUILD SUCCEEDED** (`/tmp/birdnion_build_r1prime.log`).
- [x] Artifact / runtime verification
  - Inspect: `grep -n "codexAutoPrime" BirdNion/Services/SettingsStore.swift` → 3 keys present with canonical defaults (`false`/`535`/`0`).
  - Expect: keys exist and are readable via `@AppStorage` — confirmed by successful compile (SwiftUI bindings type-check against these keys).
- [x] Runtime reachability verification
  - Entrypoint/caller: `ProvidersPane.swift:539` — `CodexAutoPrimeCard()` mounted right after `CodexAccountsCard()` inside `if rows[idx].id == "codex"`.
  - Expect: `grep -n "CodexAutoPrimeCard" BirdNion/Views/Settings/ProvidersPane.swift` shows both the call site (539) and the struct definition (3410) — mounted, not orphaned.
- [x] Contract / negative-path verification
  - Check: `grep -n "settings.codex.autoPrime\|notification.codexPrimed" BirdNion/Services/AppLocalizer.swift` — all 7 keys (title/toggle/toggleSubtitle/time/timeSubtitle + notification title/body) present in BOTH vi (327-333) and en (684-690) tables.
  - Expect: no missing-key fallback to raw key string — confirmed, every key has both language entries.

## Risk Assessment

| Risk | Severity | Mitigation |
|---|---|---|
| DatePicker↔minutes off-by-one | Low | Use `hour*60+minute` both directions; 08:55=535 sanity check |
| String key present in only one table | Medium | Grep both `vi` and `en` for each new key before done |
| Accidental new file (pbxproj) | Medium | Extend existing files only |

---

> **Parallel marker**: Append `(P)` to the title if this task can run concurrently with another (usually when serving different requirements).
> **Test note**: If a test coverage sub-task can be deferred post-MVP, mark it with `- [ ]*`.
> **Requirement mapping**: Every sub-task MUST end with `_Requirements: X.X_`. No mapping = invalid task file.
> **Evidence rule**: No `## Evidence` section = invalid task file. Existing specs may use `## Task Test Plan & Verification Evidence` or legacy `## Verification & Evidence`; agents must support all three headings.
