# Task R2-02: QuotaPanel

**Requirement:** R5 — Quota display
**Status:** pending
**Priority:** P1
**Estimated Effort:** M
**Dependencies:** tasks/task-R1-03-quota-service.md, tasks/task-R2-01-popover-shell.md
**Spec:** specs/ai-statusbar/

## Context

- **Why**: BOSS needs to read MiniMax + Hapo quota at a glance. The popover must show a row per provider with one `QuotaBar` per window, color-coded by percent remaining, with a relative timestamp.
- **Current state**: `QuotaService.statuses` publishes; `PopoverView` has a Quota tab placeholder.
- **Target outcome**: `AIStatusbar/Views/QuotaPanel.swift`, `AIStatusbar/Views/ProviderRow.swift`, and `AIStatusbar/Views/QuotaBar.swift`. The panel shows all providers from `QuotaService.statuses`. The bar colors: green ≥ 35, amber 15–34, red < 15. Errors render inline; bars hidden for the failing provider.

## Constraints

- **MUST**: `QuotaBar` colors: green `>= 35`, amber `15..34`, red `< 15`.
- **MUST**: Relative timestamp: `"vừa xong"` for < 30s, `"Ns trước"` for < 60s, `"Nm trước"` otherwise.
- **MUST NOT**: Show a bar for a provider with non-nil `error`; show the error message instead.
- **SCOPE**: Three view files. No new tests for views in v1 (verified manually).

## Steps

- [ ] 1. Add `AIStatusbar/Views/QuotaBar.swift` with a `View` that takes a `QuotaWindow` and renders a horizontal progress bar with the right color.
  - Business intent: requirement 5.4.
  - Code detail: `ProgressView(value: Double(window.remainingPct), total: 100).tint(color(for: window.remainingPct))`. Show label and `"\(remainingPct)%"` on the right.
  - _Requirements: 5.3, 5.4_

- [ ] 2. Add `AIStatusbar/Views/ProviderRow.swift` with a `View` that takes a `ProviderStatus` and renders name, relative timestamp, and either one `QuotaBar` per window or the error message.
  - Business intent: requirement 5.3, 5.5.
  - Code detail: `if let err = status.error { Text(err).foregroundStyle(.red) } else { ForEach(status.windows) { QuotaBar(window: $0) } }`.
  - _Requirements: 5.3, 5.5_

- [ ] 3. Add `AIStatusbar/Views/QuotaPanel.swift` with a `View` that observes `QuotaService.statuses` and renders a `ProviderRow` per status.
  - Business intent: requirement 5.1, 5.2.
  - Code detail: `@EnvironmentObject var quota: QuotaService`. `List { ForEach(quota.statuses) { ProviderRow(status: $0) } }`.
  - _Requirements: 5.1, 5.2, 5.3_

- [ ] 4. Wire `QuotaPanel` into `PopoverView` as the "Quota" tab.
  - Business intent: makes the panel reachable.
  - Code detail: `case .quota: QuotaPanel()`.
  - _Requirements: 9.4_

- [ ] 5. Verification.
  - _Requirements: 5.1, 5.2, 5.3, 5.4, 5.5, 9.4_

## Requirements

- 5.1 — `QuotaPanel` reflects the latest `statuses`.
- 5.2 — Updates within 200ms of fetch.
- 5.3 — Each row: name, relative timestamp, one bar per window.
- 5.4 — Bar color: green ≥ 35, amber 15–34, red < 15.
- 5.5 — Provider with `error != nil` shows error inline, no bars.
- 9.4 — Panel is reachable from the popover.

## Related Files

| Path | Action | Description |
|---|---|---|
| `AIStatusbar/Views/QuotaBar.swift` | Create | Single progress bar |
| `AIStatusbar/Views/ProviderRow.swift` | Create | One provider's name + windows or error |
| `AIStatusbar/Views/QuotaPanel.swift` | Create | List of rows |
| `AIStatusbar/Views/PopoverView.swift` | Modify | Render `QuotaPanel()` in quota tab |
| `AIStatusbar.xcodeproj/project.pbxproj` | Modify | Add new sources |

## Completion Criteria

- [ ] `xcodebuild build` exits 0.
- [ ] Popover shows one row per provider with correct bar colors (manual visual check).
- [ ] When a provider has an error, the row shows the error text only.
- [ ] The relative timestamp updates as time passes (manual: open, wait 30s, see "vừa xong" → "30s trước").

## Evidence

- [ ] Automated verification
  - Command(s): `xcodebuild -scheme AIStatusbar -configuration Debug build 2>&1 | tail -10`
  - Expected proof: `** BUILD SUCCEEDED **`, exit 0.
- [ ] Artifact / runtime verification
  - Inspect: built `.app` launched; popover shows `QuotaPanel` content.
  - Expect: at least one provider row visible (mock Hapo).
- [ ] Runtime reachability verification
  - Entrypoint/caller: `PopoverView` case `.quota` returns `QuotaPanel()`.
  - Expect: panel appears when the Quota tab is selected.
- [ ] Contract / negative-path verification
  - Check: with all providers in error state.
  - Expect: each row shows the error string, no progress bars rendered.

## Risk Assessment

| Risk | Severity | Mitigation |
|---|---|---|
| Color thresholds drift from spec | Low | Thresholds (`>= 35`, `15..34`, `< 15`) are constants at top of `QuotaBar.swift` with a comment. |
| Timestamp formatter is locale-dependent | Low | Use `RelativeDateTimeFormatter` with explicit Vietnamese strings. |
