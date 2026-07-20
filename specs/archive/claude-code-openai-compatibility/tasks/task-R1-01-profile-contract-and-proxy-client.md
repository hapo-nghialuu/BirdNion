# Task R1-01: Profile contract, CLIProxyAPI client, and Claude config writer

**Requirement:** R1, R3, R4, R5
**Status:** done
**Priority:** P2
**Estimated Effort:** M
**Dependencies:** none
**Spec:** specs/claude-code-openai-compatibility/

## Context

- **Why**: Claude Code expects Anthropic protocol; CLIProxyAPI must own the OpenAI conversion.
- **Current state**: Custom profiles store only a direct Anthropic endpoint/token, and writer always emits those values.
- **Target outcome**: An OpenAI profile can register its upstream with a running CLIProxyAPI and produce correct proxy-facing Claude Code env.

## Constraints

- **MUST**: Preserve decoding of old profile JSON; use `GET` then `PUT` only against CLIProxyAPI management API; preserve non-owned entries.
- **SHOULD**: Keep networking in a focused service with `URLSession` injection for XCTest.
- **MUST NOT**: Bundle/start CLIProxyAPI, use its private Go SDK, log secrets, or write management/upstream keys to Claude Code settings.
- **SCOPE**: Implement only R1, R3, R4, R5 contracts.

## Steps

- [x] 1. Extend `ClaudeCodeProfile` with backward-compatible optional mode-specific fields and stable BirdNion proxy entry/prefix derivation.
  - _Requirements: 1.1, 1.2, 1.3, 1.4_
- [x] 2. Add a typed `CLIProxyAPIClient` that GETs, merges, and PUTs `openai-compatibility` entries using management-key authorization.
  - _Requirements: 3.1, 3.2, 4.2_
- [x] 3. Update `ClaudeCodeConfigWriter` so OpenAI profiles emit proxy URL/proxy API key/prefixed models; retain direct profile behavior.
  - _Requirements: 3.3, 3.5, 4.1_
- [x] 4. Add XCTest coverage for backward compatibility, client request/payload/error paths, and writer outputs.
  - _Requirements: 5.1, 5.2_

## Related Files

| Path | Action | Description |
|---|---|---|
| `BirdNion/Services/BirdNionConfigStore.swift` | Modify | Mode-specific profile persistence. |
| `BirdNion/Services/CLIProxyAPIClient.swift` | Create | Management API client. |
| `BirdNion/Services/ClaudeCodeConfigWriter.swift` | Modify | Proxy-aware env spec. |
| `BirdNion.xcodeproj/project.pbxproj` | Modify | Compile new service. |
| `BirdNionTests/ClaudeCodeTests.swift` | Modify | Deterministic XCTest coverage. |

## Completion Criteria

- [x] Old JSON profiles decode and behave as direct Anthropic profiles.
- [x] Client preserves unrelated entries and submits a namespaced OpenAI entry with expected headers.
- [x] OpenAI env contains only proxy credentials; direct env behavior remains unchanged.
- [x] New client is compiled and test-reachable through the app target.

## Evidence

- [x] Automated verification
  - Command: `source Scripts/dev-env.sh >/dev/null && xcodebuild -quiet test -project BirdNion.xcodeproj -scheme BirdNion -destination 'platform=macOS' -derivedDataPath build/CLIProxyFullVerificationDerivedData`
  - Proof: xcresult reports `265` passed, `0` failed.
- [x] Artifact / runtime verification
  - Inspect: `CLIProxyAPIClient.swift` is in BirdNion Sources; its tests verify `GET` then `PUT` against `/v0/management/openai-compatibility` with Bearer authorization.
- [x] Runtime reachability verification
  - Entrypoint/caller: `ClaudeCodePane.powerTapProfile` awaits `CLIProxyAPIClient.configure` before it calls `ClaudeCodeConfigWriter.apply` for OpenAI mode.
- [x] Contract / negative-path verification
  - Check: `testCLIProxyAPIClientSurfacesHTTPFailure` covers HTTP error propagation; activation control flow cannot call the writer after a thrown registration error.

## Risk Assessment

| Risk | Severity | Mitigation |
|---|---|---|
| Full-list PUT overwrites other entries | High | GET then replace only stable BirdNion-owned name and preserve all other decoded entries. |
| Secret writes to Claude settings | High | Writer tests assert only proxy API key appears. |
