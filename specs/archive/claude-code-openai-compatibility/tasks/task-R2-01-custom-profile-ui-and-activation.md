# Task R2-01: Custom profile mode UI and activation wiring

**Requirement:** R2, R3, R4
**Status:** done
**Priority:** P2
**Estimated Effort:** M
**Dependencies:** `tasks/task-R1-01-profile-contract-and-proxy-client.md`
**Spec:** specs/claude-code-openai-compatibility/

## Context

- **Why**: Users need distinct fields for upstream versus proxy credentials and an activation flow that cannot leave Claude Code pointed at an unconfigured proxy.
- **Current state**: Form is direct Anthropic only; `powerTapProfile` writes settings immediately.
- **Target outcome**: User selects a mode, sees only relevant fields, and OpenAI activation registers the proxy first.

## Constraints

- **MUST**: Preserve current direct Anthropic form behavior; localize vi/en; await proxy registration before writer apply.
- **SHOULD**: Reuse `SettingsCard`, existing input/secret visibility patterns, semantic colors, focus labels, and fixed row layout.
- **MUST NOT**: Add explanation-heavy UI, hide required inputs behind an ambiguous action, or delete remote proxy config.
- **SCOPE**: Implement only UI and activation mapped to R2/R3/R4.

## Steps

- [x] 1. Add protocol selector and mode-specific fields to `ClaudeCodeCustomProfileForm`.
  - _Requirements: 2.1, 2.2, 2.3, 2.4_
- [x] 2. Add vi/en localization keys for labels and concise error/setup states.
  - _Requirements: 2.5_
- [x] 3. Update custom profile activation to await `CLIProxyAPIClient` for OpenAI mode before `ClaudeCodeConfigWriter.apply`; surface errors without local write.
  - _Requirements: 3.1, 3.4, 3.5, 4.3_
- [x] 4. Build and inspect reachability from `ClaudeCodePane` to form/client/writer.
  - _Requirements: 2, 3_

## Related Files

| Path | Action | Description |
|---|---|---|
| `BirdNion/Views/Settings/ClaudeCodeCustomProfileForm.swift` | Modify | Protocol selector and relevant fields. |
| `BirdNion/Views/Settings/ClaudeCodeCustomProfileConnectionFields.swift` | Create | Isolated protocol-specific connection inputs. |
| `BirdNion/Views/Settings/ClaudeCodePane.swift` | Modify | Ordered proxy registration then local apply. |
| `BirdNion/Services/AppLocalizer.swift` | Modify | vi/en labels. |
| `BirdNionTests/ClaudeCodeTests.swift` | Modify | Add any integration-level proof required by wiring. |

## Completion Criteria

- [x] Form makes OpenAI upstream, proxy API key, and management key unambiguous.
- [x] Direct profiles do not invoke proxy client; OpenAI profiles only write settings after registration success.
- [x] All newly introduced visible strings have vi/en entries.
- [x] New client is reachable from the real power-button activation flow.

## Evidence

- [x] Automated verification
  - Command: `source Scripts/dev-env.sh >/dev/null && xcodebuild -quiet test -project BirdNion.xcodeproj -scheme BirdNion -destination 'platform=macOS' -derivedDataPath build/CLIProxyFullVerificationDerivedData`
  - Proof: xcresult reports `265` passed, `0` failed.
- [x] Artifact / runtime verification
  - Inspect: `ClaudeCodeCustomProfileConnectionFields` renders the segmented mode selector and only the relevant direct/proxy fields; `ClaudeCodePane.powerTapProfile` only calls the client in OpenAI mode.
- [x] Runtime reachability verification
  - Entrypoint/caller: Settings -> Claude Code -> Custom profile -> power button; form binds `workingProfile` and activation consumes the selected profile.
- [x] Contract / negative-path verification
  - Check: failed registration is caught as `CLIProxyAPIClient.ClientError`, mapped to `errorMessage`, and the subsequent local writer call is skipped.

## Risk Assessment

| Risk | Severity | Mitigation |
|---|---|---|
| User confuses upstream key with proxy key | Medium | Separate labelled sections and hide irrelevant direct token controls. |
| Partial activation on network failure | High | `await` proxy registration before applying writer. |
