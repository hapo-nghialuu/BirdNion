# Task 01 — Read the Keychain item Claude Code itself reads

Status: done

## Outcome
Prompted (CLI) and no-UI (SecItem) Keychain reads select the `Claude Code-credentials` item whose account matches Claude Code's account rule, fall back to today's unpinned read only when that item does not exist, and never produce a second prompt after a denial or timeout.

## Scope
- In: account derivation; `-a` on the `security` CLI read with one unpinned retry on exit 44 inside one shared 300 s deadline; `kSecAttrAccount` on the no-UI query with one service-only retry on `errSecItemNotFound`; injectable runner, `copyMatching`, and `UserDefaults` with production defaults.
- Out: hex decoding and concurrent pipe draining (task 02); `ClaudeProvider.swift` (its zero-argument call keeps compiling through default arguments).

## Coverage
- CP-01

## Ownership
- Modify: `BirdNion/Providers/Claude/OAuth/ClaudeOAuth.swift`
- Modify: `BirdNionTests/ClaudeNativeTests.swift`
- Read: `BirdNion/Providers/ClaudeProvider.swift`

## Steps
1. Add `static func claudeKeychainAccount(environment: [String: String] = ProcessInfo.processInfo.environment, systemUserName: String = NSUserName()) -> String` implementing AC-01 (empty `USER` falls through to `systemUserName`).
2. Add `typealias SecurityCLIRunResult = (status: Int32, stdout: Data, stderr: String)` and a live runner `static func runSecurityCLI(_ arguments: [String], timeout: TimeInterval) -> SecurityCLIRunResult?` returning `nil` on spawn failure or timeout (process terminated).
3. Change the helper to `static func readKeychainDataViaSecurityCLI(account: String = claudeKeychainAccount(), defaults: UserDefaults = .standard, clock: () -> Date = Date.init, runner: ([String], TimeInterval) -> SecurityCLIRunResult? = runSecurityCLI) -> Data?`; keep `securityCLIReadLock.try()` around the whole read; compute one deadline = `clock()` + `securityCLIReadTimeout` (300 s).
4. First run `["find-generic-password", "-s", service, "-a", account, "-w"]` with timeout = deadline − `clock()`; if it returns status 44 and deadline − `clock()` > 0, run once more without `-a` with exactly that remaining time; otherwise (no time left, `nil`, or any other non-zero status) end the read with no retry; apply the existing "cancel" check to the final non-zero result via `recordDenied(defaults: defaults)`.
5. Split the no-UI branch into `static func readKeychainDataWithoutUI(account: String = claudeKeychainAccount(), copyMatching: ([String: Any]) -> (OSStatus, Data?) = liveCopyMatching) -> Data?` and add `static func liveCopyMatching(_ query: [String: Any]) -> (OSStatus, Data?)` wrapping `SecItemCopyMatching`. Build every query (pinned and retry) through `KeychainNoUIQuery.apply` (today `ClaudeOAuth.swift:198`); first query adds `kSecAttrAccount`; only `errSecItemNotFound` repeats it without the account; `readKeychainData(allowPrompt: false)` calls it.
6. Add tests in `ClaudeNativeTests` (no real Keychain, an isolated `UserDefaults(suiteName:)` removed in teardown, a fake clock advanced by the fake runner): account rule; runner fallback (44 → second call without `-a` whose timeout equals 300 s minus the time the fake first call consumed; first call consuming ≥ 300 s then 44 → no second call; status 128 with "cancel" → one call and cooldown armed in the suite only; `nil` → one call; status 0 → one call); no-UI (first query has account; not-found → second query without account; `errSecInteractionNotAllowed` → one query; every recorded query contains `kSecUseAuthenticationContext` and `kSecUseAuthenticationUI`).

## Acceptance
- AC-01: `testClaudeKeychainAccountRule` covers USER set, USER empty → system name, invalid characters → `claude-code-user`.
- AC-02: `testSecurityCLIReadRetriesUnpinnedOnlyOnNotFound` records exactly two invocations, first with `-a <account>`, second without and with timeout = remaining shared deadline, when the first returns 44; one invocation when the first call exhausts the 300 s deadline.
- AC-03: the same test records one invocation for status 128 + "cancel" (cooldown set in the test suite, `UserDefaults.standard` untouched) and one invocation for `nil`.
- AC-04: `testNoUIKeychainReadRetriesWithoutAccountOnlyOnNotFound` records the query sequence for not-found (2) and interaction-not-allowed (1), and every query carries the no-UI keys.

## Dependencies
- none

## Verification Plan
- Command: `CLIPROXYAPI_SOURCE="${CLIPROXYAPI_SOURCE:?set to a CLIProxyAPI-private checkout}" xcodebuild test -project BirdNion.xcodeproj -scheme BirdNion -configuration Debug -destination 'platform=macOS' -only-testing:BirdNionTests/ClaudeNativeTests`
- Named probe: `ClaudeNativeTests.testClaudeKeychainAccountRule`, `ClaudeNativeTests.testSecurityCLIReadRetriesUnpinnedOnlyOnNotFound`, `ClaudeNativeTests.testNoUIKeychainReadRetriesWithoutAccountOnlyOnNotFound`
- Reachability: source level; runs from the repo root with a CLIProxyAPI checkout (build phase requirement, `BirdNion.xcodeproj/project.pbxproj:706`); no real Keychain access; `ClaudeProvider.swift:280` compiles unchanged.
- Oracle: the three named tests reported passed and `** TEST SUCCEEDED **`.
- Counterexample: retrying after "cancel" or `nil`, omitting `-a` on the first call, giving the retry a fresh 300 s or retrying after the deadline, retrying the no-UI query on `errSecInteractionNotAllowed`, building a no-UI query without `KeychainNoUIQuery.apply`, or writing the cooldown to `UserDefaults.standard` must fail a named test.
- Artifacts: ephemeral (DerivedData; the test `UserDefaults` suite is removed in teardown).

## Failure Protocol
On a failed Step or Verification Plan run: stop; do not widen scope, change the Command, or weaken a test; record observed versus expected; repair only the cited cause; after three failed rounds, stop and ask the user.

## Receipt

Verification: PASS
Command: CLIPROXYAPI_SOURCE="${CLIPROXYAPI_SOURCE:?set to a CLIProxyAPI-private checkout}" xcodebuild test -project BirdNion.xcodeproj -scheme BirdNion -configuration Debug -destination 'platform=macOS' -only-testing:BirdNionTests/ClaudeNativeTests
Exit: 0
Base: 7c2ba958314ecb3d14258379284119fcea23b848
Head: a45e36ea24892e9ceb0e39bc980fac84ec224636cb3b3165bd6a617529c52557
```text
$ export CLIPROXYAPI_SOURCE=<session scratchpad>/CLIProxyAPI
$ xcodebuild test -project BirdNion.xcodeproj -scheme BirdNion -configuration Debug -destination 'platform=macOS' -only-testing:BirdNionTests/ClaudeNativeTests
Test Case '-[BirdNionTests.ClaudeNativeTests testClaudeKeychainAccountRule]' passed (0.001 seconds).
Test Case '-[BirdNionTests.ClaudeNativeTests testDecodeSecurityCLIPasswordOutput]' passed (0.001 seconds).
Test Case '-[BirdNionTests.ClaudeNativeTests testNoUIKeychainReadRetriesWithoutAccountOnlyOnNotFound]' passed (0.008 seconds).
Test Case '-[BirdNionTests.ClaudeNativeTests testSecurityCLIReadRetriesUnpinnedOnlyOnNotFound]' passed (0.001 seconds).
Test Case '-[BirdNionTests.ClaudeNativeTests testSecurityCLIRunnerDrainsLargeOutput]' passed (0.015 seconds).
	 Executed 44 tests, with 0 failures (0 unexpected) in 0.095 (0.105) seconds
** TEST SUCCEEDED **
exit=0
```
Shared run with task-02 (probes owned here: testClaudeKeychainAccountRule, testSecurityCLIReadRetriesUnpinnedOnlyOnNotFound, testNoUIKeychainReadRetriesWithoutAccountOnlyOnNotFound — each executed once, passed); rebound after task-02 changed ClaudeOAuth.swift.
Negative control: disposable worktree mutant changing the retry guard to `result.status != 0` → `testSecurityCLIReadRetriesUnpinnedOnlyOnNotFound` failed (`** TEST FAILED **`, exit 65); worktree removed.
Review: code-auditor PASS (0 Critical/High/Medium); Low "fake crashes on extra call" fixed; Low "AGENTS.md/CLAUDE.md modified outside ownership" — excluded from this task.
