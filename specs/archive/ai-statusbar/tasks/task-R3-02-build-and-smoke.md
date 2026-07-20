# Task R3-02: Build + smoke verification

**Requirement:** R9 — End-to-end build + runtime reachability
**Status:** pending
**Priority:** P0
**Estimated Effort:** S
**Dependencies:** tasks/task-R0-01-xcode-scaffold.md, tasks/task-R1-03-quota-service.md, tasks/task-R2-02-quota-panel.md, tasks/task-R2-03-config-panel.md, tasks/task-R2-04-settings-provider-mgmt.md, tasks/task-R3-01-config-service.md
**Spec:** specs/ai-statusbar/

## Context

- **Why**: With every other task done, the only thing left is to prove the entire app builds, the tests pass, and the launched `.app` actually reaches every provider + view at runtime. Without this, "done" is just a guess.
- **Current state**: All prior tasks are `completed`. The repo has an Xcode project, services, providers, views, and tests.
- **Target outcome**: `xcodebuild -scheme AIStatusbar -configuration Debug build` and `xcodebuild test -scheme AIStatusbar` both exit 0. Launching the built `.app` shows the menu bar icon, the popover has both tabs, the Quota panel renders rows, the Config panel loads `~/.claude/settings.json`. A final verification receipt is written to `specs/ai-statusbar/reports/r3-02-smoke.md`.

## Constraints

- **MUST**: Build exit 0.
- **MUST**: All tests pass (count from `xcodebuild test` log).
- **MUST**: Every `QuotaProvider` instance is `fetch()`ed at least once during a 90-second manual run (verified via debug log).
- **MUST**: Every Config form field is wired (no orphan fields). Verified by the test suite for the service, manual for the form binding.
- **SCOPE**: Verification only. No new source files.

## Steps

- [ ] 1. Run a clean build and capture the log.
  - Business intent: proves R9.1.
  - Code detail: `xcodebuild -scheme AIStatusbar -configuration Debug clean build 2>&1 | tee /tmp/build.log`. Expect `** BUILD SUCCEEDED **` and exit 0.
  - _Requirements: 9.1_

- [ ] 2. Run the full test suite and capture the per-class pass counts.
  - Business intent: proves the contracts tested in earlier tasks still hold together.
  - Code detail: `xcodebuild test -scheme AIStatusbar -destination 'platform=macOS' 2>&1 | tee /tmp/test.log`. Expect `Test Suite 'All tests' passed` and per-class counts: `KeychainServiceTests 2/2`, `ProviderStatusTests 3/3`, `MiniMaxProviderParserTests 4/4`, `HapoHubProviderTests 3/3`, `QuotaServicePollingTests 1/1`, `ConfigServiceAtomicWriteTests 4/4`.
  - _Requirements: 9.1, 9.4_

- [ ] 3. Launch the built `.app` and observe for 90 seconds.
  - Business intent: proves R1.1, R1.2, R1.3, R5.1, R5.2, R9.2, R9.3, R9.4, R10.1, R10.3.
  - Code detail: `open ~/Library/Developer/Xcode/DerivedData/AIStatusbar-*/Build/Products/Debug/AIStatusbar.app`. Watch the menu bar icon appear. Click → popover opens ≤ 200ms. Quota panel shows ≥ 1 row. Wait 180s (one 120s cycle + jitter), confirm at least one new `fetch()` happened (debug log line "QuotaService: poll cycle" or equivalent). Resident memory `ps -o rss -p <pid>` ≤ 50 MB.
  - _Requirements: 1.1, 1.2, 1.3, 5.1, 5.2, 9.2, 9.3, 9.4, 10.1, 10.3_

- [ ] 4. Open the Config tab; change one field; save; verify the JSON file and `.bak` update.
  - Business intent: proves R6.2, R6.3, R6.4, R7.1, R7.2, R7.3, R7.4, R11.5.
  - Code detail: change `env.ANTHROPIC_MODEL` from `claude-opus-4-8` to `claude-sonnet-4-6`, click Lưu, `cat ~/.claude/settings.json | jq .env.ANTHROPIC_MODEL` returns `"claude-sonnet-4-6"`, `ls -la ~/.claude/settings.json.bak` shows recent mtime, `diff` shows only the changed field.
  - _Requirements: 6.2, 6.3, 6.4, 7.1, 7.2, 7.3, 7.4, 11.5_

- [ ] 5. Open Settings; add a fake MiniMax token; verify Keychain holds it and `providers.json` does not.
  - Business intent: proves R8.1, R8.2, R8.3, R8.4, R11.1, R11.2.
  - Code detail: `security find-generic-password -s AIStatusbar -a minimax -w` returns the token; `cat ~/Library/Application\ Support/AIStatusbar/providers.json` does not contain `token` or `secret`.
  - _Requirements: 8.1, 8.2, 8.3, 8.4, 11.1, 11.2_

- [ ] 6. Write the verification receipt to `specs/ai-statusbar/reports/r3-02-smoke.md` with: build command + exit, test command + counts, manual observations, screenshots if any.
  - Business intent: durable proof for the Definition of Done.
  - Code detail: the report file lives under `specs/ai-statusbar/reports/`.
  - _Requirements: 9.1, 9.2, 9.3, 9.4_

- [ ] 7. Final verification.
  - _Requirements: 9.1, 9.2, 9.3, 9.4_

## Requirements

- 9.1 — Build exit 0.
- 9.2 — `.app` launches, icon appears within 2s.
- 9.3 — Every provider fetched at least once per minute.
- 9.4 — No orphan modules; every field is wired.
- Plus all acceptance criteria from R1, R5, R6, R7, R8, R10, R11 verified end-to-end.

## Related Files

| Path | Action | Description |
|---|---|---|
| `specs/ai-statusbar/reports/r3-02-smoke.md` | Create | Verification receipt |

## Completion Criteria

- [ ] Build log shows `** BUILD SUCCEEDED **` and exit 0.
- [ ] Test log shows 17/17 tests passing across 6 test classes.
- [ ] Manual run shows menu bar icon, popover opens ≤ 200ms, Quota panel renders, Config panel loads `~/.claude/settings.json`, at least one poll cycle completed in 180s, resident memory ≤ 50 MB.
- [ ] Save in Config panel changes the file and rotates `.bak`.
- [ ] Token save lands in Keychain, not `providers.json`.
- [ ] `specs/ai-statusbar/reports/r3-02-smoke.md` exists and contains the receipts.

## Evidence

- [ ] Automated verification
  - Command(s): `xcodebuild -scheme AIStatusbar -configuration Debug build 2>&1 | tail -10; xcodebuild test -scheme AIStatusbar -destination 'platform=macOS' 2>&1 | tail -20`
  - Expected proof: build exit 0, test counts as above.
- [ ] Artifact / runtime verification
  - Inspect: `specs/ai-statusbar/reports/r3-02-smoke.md` (Read tool after writing).
  - Expect: contains build log tail, test log tail, manual observations.
- [ ] Runtime reachability verification
  - Entrypoint/caller: `open` of the built `.app`.
  - Expect: menu bar icon, popover, both panels, polling log line.
- [ ] Contract / negative-path verification
  - Check: all negative-path tests in earlier tasks pass (token missing, non-2xx, write failure).
  - Expect: no failures.

## Risk Assessment

| Risk | Severity | Mitigation |
|---|---|---|
| macOS does not allow unsigned app to run | Low | ad-hoc signing; `spctl --assess` not required for local launch. |
| Some endpoint change at runtime | Medium | Provider tests use URLProtocol stub; the real network is exercised once during the manual run. |
| Receipt file contains a token by accident | High | The receipt only contains command output tails; never paste a token in any log. |
