# Task R2-03: ConfigPanel

**Requirement:** R6 + R7 — Edit Claude Code global + per-project settings
**Status:** pending
**Priority:** P1
**Estimated Effort:** L
**Dependencies:** tasks/task-R3-01-config-service.md, tasks/task-R2-01-popover-shell.md
**Spec:** specs/ai-statusbar/

## Context

- **Why**: BOSS wants to switch Claude Code model, base URL, and API key from the menu bar without opening a terminal. The panel covers both the global `~/.claude/settings.json` and any per-project `.claude/settings.json` detected under `~/.claude/projects/`.
- **Current state**: `ConfigService` (R3-01) and `PopoverView` (R2-01) exist. No form view yet.
- **Target outcome**: `AIStatusbar/Views/ConfigPanel.swift` with a project picker (dropdown) and a typed form for the fields listed in requirement 6.1. The absolute file path being edited is shown at the top. API key fields are `SecureField` and rendered masked. Save button calls `ConfigService.saveGlobal` or `saveProject`.

## Constraints

- **MUST**: Form fields exactly as enumerated in R6.1; `SecureField` for `ANTHROPIC_API_KEY`; segmented picker for `permissions.defaultMode`.
- **MUST**: Top of the panel shows the absolute file path being edited (R7.4).
- **MUST NOT**: Log or print the raw API key; display as `"fe_oa_••••<last4>"` when re-loaded.
- **SCOPE**: One view file. `ConfigService` is the source of truth for IO.

## Steps

- [ ] 1. Add `AIStatusbar/Views/ConfigPanel.swift` with `@EnvironmentObject var config: ConfigService` and `@State var settings: ClaudeSettings`. Global-only in v1 (per-project editing deferred — Finding F14).
  - Business intent: hosts the form.
  - Code detail: Show `Text(config.activePath)` (always `~/.claude/settings.json`) at the top of the panel.
  - _Requirements: 6.1, 6.7, 7.4_

- [ ] 2. ~~Project picker~~ — DELETED in v1 (Finding F14).
  - _Requirements: none_

- [ ] 3. Render the form: `TextField` for `env.ANTHROPIC_MODEL`, `env.ANTHROPIC_BASE_URL`, the three per-model defaults, `permissions.defaultMode` (segmented), and per-key `enabledPlugins` toggles. For `env.ANTHROPIC_API_KEY`, render a `SecureField`; on field change, store the raw value in a `@State var pendingApiKey: String` and DO NOT write the raw value to `settings.env.ANTHROPIC_API_KEY` in the form state.
  - Business intent: requirement 6.1; API key stays out of JSON.
  - Code detail: bind fields to `@State` properties on the view; `pendingApiKey` is held separately and sent to `KeychainService.save(account: "anthropic", secret: pendingApiKey)` on Save (Finding F3 / R11.1). The form's `settings.env.ANTHROPIC_API_KEY` is fixed at the literal placeholder `"KEYCHAIN_REF:AIStatusbar/anthropic"`.
  - _Requirements: 6.1, 6.5, 11.1_

- [ ] 4. Implement Save: validate API key length (reject if > 256 chars; allow empty to mean "leave Keychain untouched"); call `KeychainService.save("anthropic", pendingApiKey)` if `pendingApiKey` is non-empty; call `config.saveGlobal(settings)`; on success show banner **"Đã lưu. Khởi động lại Claude Code để áp dụng."** (Finding F7: Claude Code does not hot-reload). On error, show `config.lastError`.
  - Business intent: requirement 6.2, 6.3, 6.4, 11.1.
  - Code detail: `Button("Lưu") { do { try config.saveGlobal(settings); keychain.save(...) } catch { error = \.some(error) }`. The restart banner persists for 5 seconds or until the user closes the popover.
  - _Requirements: 6.2, 6.3, 6.4, 6.5, 11.1, 12.2_

- [ ] 5. Wire `ConfigPanel` into `PopoverView` as the "Config" tab.
  - Business intent: makes the panel reachable.
  - Code detail: `case .config: ConfigPanel()`.
  - _Requirements: 9.4_

- [ ] 6. Verification.
  - _Requirements: 6.1, 6.2, 6.3, 6.4, 6.5, 7.1, 7.2, 7.3, 7.4, 9.4_

## Requirements

- 6.1 — Form fields enumerated.
- 6.2 — Save → atomic write.
- 6.3 — `.bak` rotation on every save.
- 6.4 — Write failure → restore from `.bak` + show error.
- 6.5 — API key masked; never logged.
- 7.1 — Project dropdown lists `~/.claude/projects/*`.
- 7.2 — Per-project file loaded into the same form.
- 7.3 — Per-project save uses atomic + `.bak`.
- 7.4 — Absolute file path displayed at top.
- 9.4 — Panel reachable from the popover.

## Related Files

| Path | Action | Description |
|---|---|---|
| `AIStatusbar/Views/ConfigPanel.swift` | Create | Form view |
| `AIStatusbar/Views/PopoverView.swift` | Modify | Render `ConfigPanel()` in config tab |
| `AIStatusbar.xcodeproj/project.pbxproj` | Modify | Add new source |

## Completion Criteria

- [ ] `xcodebuild build` exits 0.
- [ ] Global tab shows all R6.1 fields.
- [ ] Per-project dropdown lists at least the existing `~/.claude/projects/*` entries.
- [ ] Saving a value updates the JSON file (verified by `cat ~/.claude/settings.json` after save).
- [ ] `.bak` file is created/rotated on save (verified by `ls -la ~/.claude/`).
- [ ] API key field shows masked text after re-open (verified by reading saved JSON and re-launching the panel).

## Evidence

- [ ] Automated verification
  - Command(s): `xcodebuild -scheme AIStatusbar -configuration Debug build 2>&1 | tail -10`
  - Expected proof: `** BUILD SUCCEEDED **`, exit 0.
- [ ] Artifact / runtime verification
  - Inspect: `~/.claude/settings.json` after a save with one field changed.
  - Expect: that field reflects the new value; other fields unchanged.
- [ ] Runtime reachability verification
  - Entrypoint/caller: `PopoverView` case `.config` returns `ConfigPanel()`.
  - Expect: panel appears when the Config tab is selected.
- [ ] Contract / negative-path verification
  - Check: write a deliberately invalid JSON to `~/.claude/settings.json`, then open the panel.
  - Expect: panel shows an error banner offering to load the `.bak`.

## Risk Assessment

| Risk | Severity | Mitigation |
|---|---|---|
| Form loses unsaved changes on tab switch | Medium | `@State` persists per-panel; warn before discarding if dirty. |
| User accidentally overwrites project config | Medium | Show absolute path at top; confirm dialog for per-project save. |
| Save corrupts `settings.json` mid-write | Low | `ConfigService` uses atomic write + `.bak`. |
