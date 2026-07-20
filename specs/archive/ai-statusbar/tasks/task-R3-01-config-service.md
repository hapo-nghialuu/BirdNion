# Task R3-01: ConfigService

**Requirement:** R6 + R7 + R11.5 — Read/write settings.json with atomic write + .bak
**Status:** pending
**Priority:** P1
**Estimated Effort:** L
**Dependencies:** tasks/task-R0-01-xcode-scaffold.md
**Spec:** specs/ai-statusbar/

## Context

- **Why**: The form in R2-03 needs a service that loads, edits, and atomically writes Claude Code `settings.json` (global + per-project) without corrupting the file or losing unknown keys. Claude Code crashes on malformed settings, so safety is non-negotiable.
- **Current state**: No service yet.
- **Target outcome**: `AIStatusbar/Services/ConfigService.swift` with `@MainActor ObservableObject` exposing `activePath`, `projects`, `loadGlobal`, `saveGlobal`, `loadProject`, `saveProject`, and `lastError`. Four unit tests: round-trip preserves unknown keys, save failure restores `.bak`, listProjects returns the expected directory entries, corrupted JSON refuses to load.

## Constraints

- **MUST**: Atomic write: write to `settings.json.tmp`, then `FileManager.replaceItemAt`. On failure, copy `.bak` back over the original path.
- **MUST**: `.bak` rotation: copy current file to `.bak` before every successful write.
- **MUST**: Use `JSONSerialization` (mutable container) for read-modify-write so unknown keys are preserved (R11.5).
- **MUST NOT**: Touch any file under `~/.claude/projects/<id>/<...>.jsonl` or other Claude Code state.
- **SCOPE**: One service file + one test file. `ConfigPanel` consumes it in R2-03.

## Steps

- [ ] 1. Add `AIStatusbar/Services/ConfigService.swift` with the class shell, `activePath: URL?`, `projects: [URL]`, and `lastError: String?`.
  - Business intent: typed surface for views.
  - Code detail: `@MainActor final class ConfigService: ObservableObject { @Published var activePath: URL?; @Published var lastError: String? }`. No `projects` array (per-project editing deferred to v2 — Finding F14).
  - _Requirements: 6.1, 6.7, 7.4_

- [ ] 2. Implement `loadGlobal() -> [String: Any]` that reads `~/.claude/settings.json` (or returns an empty object if missing) and parses with `JSONSerialization`. Resolve symlinks first via `url.resolvingSymlinksInPath()` (Finding Failure-F6: symlink safety).
  - Business intent: provide mutable JSON for the form.
  - Code detail: `let url = URL(fileURLWithPath: NSString(string: "~/claude/settings.json").expandingTildeInPath).resolvingSymlinksInPath(); let data = try Data(contentsOf: url); return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]`.
  - _Requirements: 6.1, 6.6, 11.5_

- [ ] 3. Implement `saveGlobal(_ settings: [String: Any]) throws` with the **3-deep ring .bak rotation** (Finding F9): if `.bak` exists and parses as JSON, rename `.bak` → `.bak.1`; if `.bak.1` exists, rename `.bak.1` → `.bak.2`; if `.bak.2` exists, delete it; then copy current → `.bak`. Then write new content to `settings.json.tmp` *in the same directory* (NOT `NSTemporaryDirectory()`), then `FileManager.replaceItemAt(original, withItemAt: tmp)`. On replace failure, restore from `.bak` and throw.
  - Business intent: requirement 6.2, 6.3, 6.4, 6.7, 12.2.
  - Code detail: `try data.write(to: tmp, options: .atomic); _ = try FileManager.default.replaceItemAt(original, withItemAt: tmp)`. Restore in `catch`. Validate `.bak` parses before each rotation step; if it does not, abort and warn.
  - _Requirements: 6.2, 6.3, 6.4, 6.7, 12.2_

- [ ] 4. ~~Implement listProjects()~~ — DELETED in v1 (Finding F14: per-project deferred to v2; v1 is global-only).
  - _Requirements: none_

- [ ] 5. ~~Implement loadProject / saveProject~~ — DELETED in v1 (Finding F14).
  - _Requirements: none_

- [ ] 6. Add `AIStatusbarTests/ConfigServiceAtomicWriteTests.swift` with 4 cases: round-trip preserves unknown keys (sample config including `hooks`, `mcpServers`, `$schema`), write failure restores `.bak` from current rotation, ring rotation produces `.bak`/`.bak.1`/`.bak.2` after 3+ saves, corrupted `.bak` aborts rotation and warns.
  - Business intent: locks the safety contract.
  - Code detail: use a temp directory created in `setUpWithError`; inject the temp dir via a test-only initializer `init(home: URL)`.
  - _Requirements: 6.2, 6.3, 6.4, 6.7, 7.1, 7.2, 7.3, 11.5, 12.2_

- [ ] 7. Verification.
  - _Requirements: 6.2, 6.3, 6.4, 6.7, 7.1, 7.2, 7.3, 11.5, 12.2_

## Requirements

- 6.1 — Form fields.
- 6.2 — Save → atomic write.
- 6.3 — `.bak` rotation.
- 6.4 — Write failure → restore `.bak` + surface error.
- 6.6 — Missing file → create with minimal valid JSON.
- 6.7 — Invalid JSON → refuse to load, offer `.bak`.
- 11.5 — Preserve all unrelated keys verbatim (semantic equality, key order may differ).
- 12.2 — IO errors surfaced as a banner, not crash.

## Related Files

| Path | Action | Description |
|---|---|---|
| `AIStatusbar/Services/ConfigService.swift` | Create | Service class |
| `AIStatusbarTests/ConfigServiceAtomicWriteTests.swift` | Create | 4 cases |
| `AIStatusbar.xcodeproj/project.pbxproj` | Modify | Add new sources + test file |

## Completion Criteria

- [ ] `xcodebuild test` reports 4/4 in `ConfigServiceAtomicWriteTests` passing.
- [ ] After a save in the test, `settings.json.bak` exists in the temp dir.
- [ ] The unknown-key preservation test asserts that a key not touched by the save round-trips identically.
- [ ] The write-failure test (simulated by making the temp file read-only) asserts that the original file is restored from `.bak`.

## Evidence

- [ ] Automated verification
  - Command(s): `xcodebuild test -scheme AIStatusbar -destination 'platform=macOS' -only-testing:AIStatusbarTests/ConfigServiceAtomicWriteTests 2>&1 | tail -30`
  - Expected proof: 4/4 pass, exit 0.
- [ ] Artifact / runtime verification
  - Inspect: a real `~/.claude/settings.json` before and after a manual save in the running app.
  - Expect: the changed field reflects the new value; the `.bak` is a copy of the previous content.
- [ ] Runtime reachability verification
  - Entrypoint/caller: `ConfigPanel` (R2-03) calls `config.loadGlobal()` and `config.saveGlobal(...)`.
  - Expect: the service is reachable from the popover's Config tab.
- [ ] Contract / negative-path verification
  - Check: chmod a file to `0000` so writes fail; call `saveGlobal`.
  - Expect: `lastError` set, original file restored from `.bak`.

## Risk Assessment

| Risk | Severity | Mitigation |
|---|---|---|
| Atomic rename fails on some FS combinations | Low | macOS APFS supports atomic rename reliably; tests run on the dev's FS. |
| Corrupted JSON blocks all future saves | Low | Service refuses to load, offers `.bak`; the user can restore. |
| `JSONSerialization` mutability preserved incorrectly | Medium | Tests assert unknown keys round-trip; read uses `.mutableContainers`. |
