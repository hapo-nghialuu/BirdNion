# Task R0-02: KeychainService

**Requirement:** Foundation — secure storage for provider tokens
**Status:** pending
**Priority:** P0
**Estimated Effort:** S
**Dependencies:** none
**Spec:** specs/ai-statusbar/

## Context

- **Why**: Provider tokens (MiniMax Subscription Key, Hapo Hub token) must NOT live in plaintext on disk. macOS Keychain is the canonical store; the rest of the app calls into a small `KeychainService` to keep the Security framework in one place.
- **Current state**: Greenfield. The Xcode project from R0-01 exists; no source code yet.
- **Target outcome**: A struct `KeychainService` with `save(account:secret:)`, `read(account:)` (throws `KeychainError.itemNotFound` when absent), and `delete(account:)` — all backed by `kSecClassGenericPassword` under service `AIStatusbar`. Two unit tests prove round-trip and missing-item behaviour.

## Constraints

- **MUST**: Use `kSecClassGenericPassword` items with `kSecAttrService = "AIStatusbar"` and `kSecAttrAccount = <provider id>`.
- **MUST**: Return `String` from `read(account:)` and throw `KeychainError.itemNotFound` when `errSecItemNotFound` is returned by the Security framework.
- **MUST NOT**: Log or `print` the secret value, even in debug builds.
- **MUST NOT**: Sync tokens to iCloud (`kSecAttrSynchronizable` must not be set).
- **SCOPE**: Service file + tests only. No provider, no UI.

## Steps

- [ ] 1. Add `AIStatusbar/Services/KeychainService.swift` with `enum KeychainError: Error { case unhandled(OSStatus); case itemNotFound }` and a struct with the three methods.
  - Business intent: isolates the Security framework so other layers don't import Security directly.
  - Code detail: `SecItemAdd` with `kSecValueData = secretData`, query built from a `CFMutableDictionary`. `read` uses `SecItemCopyMatching` with `kSecReturnData = true`.
  - _Requirements: 8.2, 8.3, 11.1, 12.4_

- [ ] 2. Add `AIStatusbarTests/KeychainServiceTests.swift` with two cases: round-trip a fake token, read a missing account throws `itemNotFound`.
  - Business intent: proves the security boundary works.
  - Code detail: use a unique account string per test (e.g. `"test-(UUID())`) and `defer { try? KeychainService().delete(account: a) }`.
  - _Requirements: 8.2, 8.5, 12.4_

- [ ] 3. Wire the test target into the Xcode project and add it as a dependency of the app target.
  - Business intent: enables `xcodebuild test`.
  - Code detail: target `AIStatusbarTests`, product type `com.apple.product-type.bundle.unit-test`, host application = `AIStatusbar`.
  - _Requirements: 9.1_

- [ ] 4. Verification.
  - _Requirements: 8.2, 8.5, 11.1_

## Requirements

- 8.2 — Store tokens in macOS Keychain under service `AIStatusbar`, account = provider id, class `kSecClassGenericPassword`.
- 8.3 — Settings UI prompts for token and stores in Keychain.
- 8.5 — Surface Keychain errors and offer retry.
- 11.1 — Never write tokens to any file outside the macOS Keychain.
- 12.4 — `errSecItemNotFound` treated as "no token configured".

## Related Files

| Path | Action | Description |
|---|---|---|
| `AIStatusbar/Services/KeychainService.swift` | Create | `KeychainService` + `KeychainError` |
| `AIStatusbarTests/KeychainServiceTests.swift` | Create | Round-trip + missing-item tests |
| `AIStatusbar.xcodeproj/project.pbxproj` | Modify | Add test target + dependency |

## Completion Criteria

- [ ] `KeychainService().save(account: "minimax", secret: "fake")` returns with no throw.
- [ ] `KeychainService().read(account: "minimax")` returns `"fake"`.
- [ ] `KeychainService().read(account: "does-not-exist")` throws `KeychainError.itemNotFound`.
- [ ] `KeychainService().delete(account: "minimax")` removes the item; subsequent `read` throws.
- [ ] `xcodebuild test -scheme AIStatusbar` runs the new tests and reports 2/2 passing.
- [ ] No `print` or `os_log` call references the secret parameter (grep clean).

## Evidence

- [ ] Automated verification
  - Command(s): `xcodebuild test -scheme AIStatusbar -destination 'platform=macOS' 2>&1 | tail -30`
  - Expected proof: `Test Suite 'All tests' passed`, 2/2 in `KeychainServiceTests`, exit 0.
- [ ] Artifact / runtime verification
  - Inspect: macOS Keychain Access app, search for items with service `AIStatusbar` after a test run.
  - Expect: at most one item (the one the test wrote); value not visible in the listing (generic password protected).
- [ ] Runtime reachability verification
  - Entrypoint/caller: `AIStatusbarTests` invokes `KeychainService` directly.
  - Expect: the service is reachable from the test target, proving the test target is wired.
- [ ] Contract / negative-path verification
  - Check: read an account that was never saved.
  - Expect: throws `KeychainError.itemNotFound`, not a fatal crash or silent nil.

## Risk Assessment

| Risk | Severity | Mitigation |
|---|---|---|
| User keychain locked during build/test | Low | Test explicitly handles `errSecAuthFailed` via `unhandled(OSStatus)`; tests use unique per-run accounts. |
| Test bleeds keychain entries across runs | Low | `defer` cleanup in every test; namespaced account `"test-\(UUID())`. |
| Future sandboxing breaks Keychain access | Low | Personal-use app is not sandboxed; if sandbox added later, add keychain-access-groups entitlement. |
