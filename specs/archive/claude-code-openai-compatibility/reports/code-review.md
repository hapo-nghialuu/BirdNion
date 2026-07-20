# Code Review: Claude Code OpenAI Compatibility

**Date:** 2026-07-17
**Scope:** macOS custom Claude Code profiles and the CLIProxyAPI management bridge.

## Findings

No critical or high-severity finding.

- CLIProxyAPI contract matches source: management API accepts Bearer key, GET returns `openai-compatibility`, and PUT accepts the merged array.
- The stable `birdnion-<profile-id>` prefix is valid for CLIProxyAPI model routing: the proxy exposes `prefix/alias` and strips the prefix for the selected credential.
- Writer emits only proxy URL and proxy API key into Claude settings. OpenAI upstream and management keys remain in BirdNion's owner-only config file.
- Proxy registration is awaited before local Claude settings are written. A client failure skips the writer.
- Legacy direct Anthropic profiles remain the default when the new optional mode is absent.

## Verification

- `xcodebuild` full macOS XCTest: 265 passed, 0 failed.
- Targeted CLIProxyAPI contract tests: 2 passed, 0 failed.
- `git diff --check`: passed for feature files.
- Spec validator: passed.

## Residual Risk

CLIProxyAPI exposes a whole-list PUT rather than an atomic per-entry create/update endpoint. BirdNion preserves all entries returned by its GET and replaces only its owned name, but an external management client writing during that small interval can still win the last write.

## Docs Impact

Minor. Feature design, implementation, evidence, and review are recorded under this spec. No unrelated project documentation was edited.

## Unresolved Questions

None.
