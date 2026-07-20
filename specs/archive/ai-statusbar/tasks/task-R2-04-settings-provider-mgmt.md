# Task R2-04: Settings — provider management

**Requirement:** R8 — Provider enable/disable + token entry
**Status:** pending
**Priority:** P2
**Estimated Effort:** M
**Dependencies:** tasks/task-R1-03-quota-service.md, tasks/task-R0-02-keychain-service.md, tasks/task-R2-01-popover-shell.md
**Spec:** specs/ai-statusbar/

## Context

- **Why**: BOSS needs to enter / change / remove the MiniMax Subscription Key and (later) the Hapo Hub token. Tokens must go to Keychain, not `providers.json`.
- **Current state**: `KeychainService` exists; `QuotaService` instantiates a fixed provider list from `AIStatusbarApp`. There is no UI to add or remove providers.
- **Target outcome**: A Settings sheet accessible from `PopoverView` with a list of providers, each showing display name, "Token đã cấu hình" / "Chưa cấu hình", and a "Cập nhật token" / "Xoá token" button. Saving writes the token to Keychain and reloads `QuotaService`. Providers also toggle on/off in `providers.json`.

## Constraints

- **MUST**: Token input uses `SecureField`; never logged or written to `providers.json`.
- **MUST**: Toggling a provider off removes it from the polling list immediately.
- **MUST NOT**: `providers.json` contains a key called `token` or `secret` (grep clean in saved file).
- **SCOPE**: One Settings view + a small `ProvidersStore` JSON file helper.

## Steps

- [ ] 1. Add `AIStatusbar/Services/ProvidersStore.swift` with `struct ProvidersStore` that loads / saves `~/Library/Application Support/AIStatusbar/providers.json` with **atomic write** (temp file in same directory + `FileManager.replaceItemAt` — never `NSTemporaryDirectory()`, to avoid cross-FS `EXDEV`). On `load()`: if the file is missing or malformed, return the default list (MiniMax enabled, Hapo enabled with `baseURL = "TODO_BOSS"`). On every `save()`, the directory is created first with `FileManager.createDirectory(at: dir, withIntermediateDirectories: true)` (Finding F4: first-launch crash). On save, a flock-style lock file at `providers.json.lock` is acquired; if another instance holds it, `save` throws `LockError.held` (Finding F11).
  - Business intent: persists non-secret provider config, tolerates corruption, races with editors and second instances.
  - Code detail: `Codable` shape: `{ "version": 1, "providers": [{ "id": "minimax", "enabled": true }, { "id": "hapo", "enabled": true, "baseURL": "TODO_BOSS" }] }`. Use `FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first`; ensure `AIStatusbar/` exists.
  - _Requirements: 8.1, 12.3, 12.5_

- [ ] 2. Add `AIStatusbar/Views/SettingsView.swift` with a list of providers and per-row actions.
  - Business intent: requirement 8.3, 8.4.
  - Code detail: `@State var rows: [ProviderRowState] = [...]`. Each row has a `Toggle` for enabled, a `SecureField` bound to a `@State var token: String`, and a "Lưu token" button.
  - _Requirements: 8.3, 8.4_

- [ ] 3. On "Lưu token", call `KeychainService.save(account: provider.id, secret: token)` and clear the `@State var token`.
  - Business intent: requirement 8.2.
  - Code detail: do not log the value; do not store it in `ProvidersStore`.
  - _Requirements: 8.2, 11.1, 11.2_

- [ ] 4. On toggle change, call `ProvidersStore.save(...)` and notify `QuotaService` to add/remove the provider.
  - Business intent: requirement 8.3, 2.2.
  - Code detail: `extension QuotaService { func setEnabled(_ enabled: Bool, for id: String) { ... } }`. When disabled, the provider is removed from the polling loop and from `statuses`.
  - _Requirements: 2.2, 8.3_

- [ ] 5. Wire `SettingsView` into `PopoverView` via a "Settings" button that opens a `sheet`.
  - Business intent: makes the panel reachable.
  - Code detail: `.sheet(isPresented: $showSettings) { SettingsView() }`.
  - _Requirements: 9.4_

- [ ] 6. Verification.
  - _Requirements: 2.2, 8.1, 8.2, 8.3, 8.4, 8.5, 9.4, 11.1, 11.2_

## Requirements

- 2.2 — QuotaService instantiates enabled providers.
- 8.1 — Persist provider config to `~/Library/Application Support/AIStatusbar/providers.json`.
- 12.3 — Missing or malformed `providers.json` starts with the default list and logs the parse error in Debug; `providers.json` writes are atomic.
- 12.5 — Two app instances MUST NOT edit `providers.json` concurrently; second instance refuses to start.
- 8.2 — Tokens in Keychain under service `AIStatusbar`.
- 8.3 — Settings UI prompts for token once and stores in Keychain.
- 8.4 — `providers.json` never contains token or secret.
- 8.5 — Keychain errors surfaced with retry.
- 9.4 — Settings reachable from popover.
- 11.1 — No token written outside Keychain.
- 11.2 — No token logged.

## Related Files

| Path | Action | Description |
|---|---|---|
| `AIStatusbar/Services/ProvidersStore.swift` | Create | JSON load/save |
| `AIStatusbar/Services/QuotaService.swift` | Modify | Add `setEnabled(_:for:)` |
| `AIStatusbar/Views/SettingsView.swift` | Create | Provider list + token entry |
| `AIStatusbar/Views/PopoverView.swift` | Modify | Settings sheet |
| `AIStatusbar.xcodeproj/project.pbxproj` | Modify | Add new sources |

## Completion Criteria

- [ ] `xcodebuild build` exits 0.
- [ ] Settings sheet opens from the popover and lists at least 2 providers.
- [ ] Saving a token writes to Keychain (verified by reading back via `KeychainService.read` in a test).
- [ ] `providers.json` exists at the expected path and contains NO key matching `token` or `secret`.
- [ ] Toggling a provider off removes its row from the Quota panel within one polling cycle.

## Evidence

- [ ] Automated verification
  - Command(s): `xcodebuild -scheme AIStatusbar -configuration Debug build 2>&1 | tail -10`
  - Expected proof: `** BUILD SUCCEEDED **`, exit 0.
- [ ] Artifact / runtime verification
  - Inspect: `~/Library/Application Support/AIStatusbar/providers.json` after toggling.
  - Expect: file exists, no `token` / `secret` keys (grep).
- [ ] Runtime reachability verification
  - Entrypoint/caller: `PopoverView` "Settings" button.
  - Expect: sheet appears; toggling a provider updates the Quota panel.
- [ ] Contract / negative-path verification
  - Check: write a malformed `providers.json` (e.g. just `{}`) and relaunch.
  - Expect: app starts with default provider list (MiniMax enabled, Hapo mock), debug log records the parse error.

## Risk Assessment

| Risk | Severity | Mitigation |
|---|---|---|
| `providers.json` accidentally contains a token | Medium | Code review + grep test in CI script (manual grep before commit). |
| Application Support directory not created | Low | `ProvidersStore` calls `try FileManager.createDirectory(at: ...)` before first write. |
