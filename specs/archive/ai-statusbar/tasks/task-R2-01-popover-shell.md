# Task R2-01: Popover shell + App entry wiring

**Requirement:** R1 — Menu bar entry + popover navigation
**Status:** pending
**Priority:** P1
**Estimated Effort:** S
**Dependencies:** tasks/task-R0-01-xcode-scaffold.md
**Spec:** specs/ai-statusbar/

## Context

- **Why**: The `MenuBarExtra` placeholder from R0-01 must grow into a real popover that hosts the Quota and Config panels. The `App` struct becomes the place where the singleton services are constructed and passed down.
- **Current state**: Placeholder popover with a single `Text("AI Statusbar")`. No services wired.
- **Target outcome**: `AIStatusbar/AIStatusbarApp.swift` constructs `KeychainService`, `QuotaService`, and `ConfigService` and injects them via `@StateObject` (services) and `.environmentObject(...)` (views). `MenuBarExtra` hosts a `PopoverView` that has two tabs (Quota / Config) plus a Settings button. The menu bar icon shows the lowest remaining % across providers, or a warning glyph if any provider has an error.

## Constraints

- **MUST**: Popover content width ≤ 360 pt; close on outside click (default `MenuBarExtra` behavior).
- **MUST**: Services are constructed once, in the `App`.
- **MUST NOT**: Re-instantiate services per popover open.
- **SCOPE**: App + PopoverView only. Quota + Config content is R2-02 / R2-03.

## Steps

- [ ] 1. Add `AIStatusbar/Views/PopoverView.swift` with a `TabView` (or segmented picker) for "Quota" and "Config", plus a "Settings" button.
  - Business intent: navigation between the two main panels.
  - Code detail: `@EnvironmentObject var quota: QuotaService`; `@EnvironmentObject var config: ConfigService`. A `@State var tab: Tab = .quota`. Use `Picker(...).pickerStyle(.segmented)` for tabs.
  - _Requirements: 1.2, 1.4_

- [ ] 2. Add `AIStatusbar/Views/MenuBarIcon.swift` with a small `View` that returns `Image(systemName: ...)` based on the lowest `remainingPct` across providers or a warning if any error is present.
  - Business intent: requirement 1.3 (icon reflects state).
  - Code detail: `func iconName(for statuses: [ProviderStatus]) -> String` returning `"chart.bar.xaxis"` when no data, `"exclamationmark.triangle"` on error, otherwise `"chart.bar.fill"`. (No animated numeric overlay in v1.)
  - _Requirements: 1.3_

- [ ] 3. Update `AIStatusbar/AIStatusbarApp.swift` to construct `KeychainService`, `QuotaService`, `ConfigService` as `@StateObject` (services that take init params) or `@StateObject` wrappers; pass via `.environmentObject(...)` to the popover content.
  - Business intent: single source of truth for services.
  - Code detail: `@StateObject private var quotaService: QuotaService = { let ks = KeychainService(); let minimax = MiniMaxProvider(keychain: ks); let hapoConfig = HapoHubConfig(...); let hapo = HapoHubFactory.make(config: hapoConfig, keychain: ks); return QuotaService(providers: [minimax, hapo]) }()`. Call `.task { await quotaService.start() }`.
  - _Requirements: 1.1, 1.2, 2.2, 9.4_

- [ ] 4. Verification.
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 9.2, 9.4_

## Requirements

- 1.1 — Single menu bar icon, no Dock icon.
- 1.2 — Click → popover with Quota + Config panels.
- 1.3 — Icon reflects lowest remaining % or warning.
- 1.4 — Click outside closes popover.
- 2.2 — `QuotaService` instantiates every enabled provider.
- 9.2 — Built `.app` launches and the menu bar icon appears within 2s.
- 9.4 — Every service is wired through `@StateObject` and consumed by the popover.

## Related Files

| Path | Action | Description |
|---|---|---|
| `AIStatusbar/AIStatusbarApp.swift` | Modify | Construct services; use new PopoverView |
| `AIStatusbar/Views/PopoverView.swift` | Create | Tabbed popover content |
| `AIStatusbar/Views/MenuBarIcon.swift` | Create | Icon chooser based on statuses |
| `AIStatusbar.xcodeproj/project.pbxproj` | Modify | Add new sources |

## Completion Criteria

- [ ] `xcodebuild build` exits 0.
- [ ] The popover shows two tabs ("Quota", "Config") and a Settings button.
- [ ] Switching tabs swaps the content (verified manually).
- [ ] No service is constructed twice (no two `@StateObject` for the same service).
- [ ] `MenuBarIcon` produces one of the three expected system images for the three states.

## Evidence

- [ ] Automated verification
  - Command(s): `xcodebuild -scheme AIStatusbar -configuration Debug build 2>&1 | tail -10`
  - Expected proof: `** BUILD SUCCEEDED **`, exit 0.
- [ ] Artifact / runtime verification
  - Inspect: built `AIStatusbar.app` launches and shows the icon.
  - Expect: click the icon → popover with tabs visible.
- [ ] Runtime reachability verification
  - Entrypoint/caller: `AIStatusbarApp` body constructs services and `MenuBarExtra` content; `PopoverView` reads them via `@EnvironmentObject`.
  - Expect: the popover is rendered; tab switching works.
- [ ] Contract / negative-path verification
  - Check: kill the app and relaunch.
  - Expect: state resets cleanly; no stale services.

## Risk Assessment

| Risk | Severity | Mitigation |
|---|---|---|
| Services initialized before Keychain is accessible | Low | Lazy `@StateObject` defer construction to first body access. |
| Popover size too small for content | Low | 360 pt chosen as default; can be tuned later. |
