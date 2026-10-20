# Task 02 — Parse hex-printed and large `security -w` output

Status: done

## Outcome
When `security -w` prints the credentials blob as hex or the output exceeds the pipe buffer, BirdNion still returns the original bytes and parses the same credentials as for small text output.

## Scope
- In: a pure decode helper applied to the CLI stdout after CR/LF trimming; the live `runSecurityCLI` drains stdout and stderr concurrently before waiting for exit.
- Out: the no-UI SecItem path (returns raw bytes already); changing what Claude Code stores; runner/deadline/retry logic from task 01.

## Coverage
- CP-02

## Ownership
- Modify: `BirdNion/Providers/Claude/OAuth/ClaudeOAuth.swift`
- Modify: `BirdNionTests/ClaudeNativeTests.swift`

## Steps
1. Add `static func decodeSecurityCLIPasswordOutput(_ data: Data) -> Data` implementing AC-05 (non-empty, even length, every byte in `0-9a-fA-F`).
2. Call it on the trimmed stdout in `readKeychainDataViaSecurityCLI` before returning.
3. Add `executable: String = "/usr/bin/security"` as the last parameter of `runSecurityCLI` (the default runner argument of `readKeychainDataViaSecurityCLI` becomes `{ runSecurityCLI($0, timeout: $1) }`); start reading stdout and stderr on background queues (or `readabilityHandler`) before waiting on the termination semaphore; join both reads after exit; on timeout terminate the process and return `nil`.
4. Add tests: plain JSON unchanged; hex of a JSON blob with a trailing `\n` decodes and `ClaudeOAuthCredentials.parse` returns the token; hex of JSON containing non-ASCII decodes; odd-length or non-hex input unchanged; `runSecurityCLI` on `/bin/sh -c 'head -c 200000 /dev/zero | tr "\0" a'`-style output returns all bytes with status 0 well before the timeout.

## Acceptance
- AC-05: `testDecodeSecurityCLIPasswordOutput` passes its four cases.
- AC-06: `testSecurityCLIRunnerDrainsLargeOutput` returns 200000 bytes, status 0, within 10 s.

## Dependencies
- task-01-pin-keychain-account.md

## Verification Plan
- Command: `CLIPROXYAPI_SOURCE="${CLIPROXYAPI_SOURCE:?set to a CLIProxyAPI-private checkout}" xcodebuild test -project BirdNion.xcodeproj -scheme BirdNion -configuration Debug -destination 'platform=macOS' -only-testing:BirdNionTests/ClaudeNativeTests`
- Named probe: `ClaudeNativeTests.testDecodeSecurityCLIPasswordOutput`, `ClaudeNativeTests.testSecurityCLIRunnerDrainsLargeOutput`
- Reachability: source level; same environment as task 01; the large-output probe needs the runner to accept an executable path (default `/usr/bin/security`) so the test can point it at `/bin/sh`.
- Oracle: both named tests reported passed and `** TEST SUCCEEDED **`.
- Counterexample: decoding a plain JSON line, not decoding the hex fixture, or reading stdout only after exit (blocks on 200000 bytes) must fail a named test.
- Artifacts: ephemeral (DerivedData).

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
Shared run with task-01 (probes owned here: testDecodeSecurityCLIPasswordOutput, testSecurityCLIRunnerDrainsLargeOutput — each executed once, passed).
Negative control: disposable worktree mutant reading both pipes only after exit → `testSecurityCLIRunnerDrainsLargeOutput` failed at its assertions after the 30 s timeout (`** TEST FAILED **`, exit 65); worktree removed.
Review: code-auditor PASS (0 Critical/High/Medium); Lows fixed before this run: bounded `drained.wait` (5 s), uppercase-hex test case; Low "10 s threshold flakiness" judged acceptable by reviewer.
