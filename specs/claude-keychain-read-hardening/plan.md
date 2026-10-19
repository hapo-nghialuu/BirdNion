# Claude Keychain read hardening
Specs-Contract: process-first-ready-v1

## Scope decision (GATE-SCOPE — 2026-10-19)
- Existing: prompted reads spawn `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w` with no account (`BirdNion/Providers/Claude/OAuth/ClaudeOAuth.swift:218`); stdout is read only after the process exits (`ClaudeOAuth.swift:233-237`); lock, 300 s timeout and "cancel" denial cooldown already exist (`ClaudeOAuth.swift:214-215, 233-247, 255-257`); `recordDenied` defaults to `UserDefaults.standard` (`ClaudeOAuth.swift:571-572`); no-UI path is `SecItemCopyMatching` by service only (`ClaudeOAuth.swift:192-202`); `ClaudeProvider.readKeychainData` reuses the CLI helper with no arguments (`BirdNion/Providers/ClaudeProvider.swift:278-281`); output is only stripped of trailing CR/LF (`ClaudeOAuth.swift:249`); tests run inside `BirdNion.app` (`BirdNion.xcodeproj/project.pbxproj:1348`).
- Evidence (2026-10-19, this Mac):
  - Claude Code 2.1.303 binary writes `add-generic-password -U -a "<account>" -s "<service>" -X "<hex(JSON.stringify)>"` and reads `security find-generic-password -a "<account>" -w -s "<service>"`; account = `$USER` || OS username, replaced by `claude-code-user` unless it matches `^[a-zA-Z0-9._-]+$`.
  - Temp-keychain experiment: `-s` is an exact match (a `Claude Code-credentials-<hash>` item is not returned); with two same-service items and no `-a`, `security` returns storage order, not the newest; `-a` selects the right item; not-found exits `44`.
  - `security -w` prints lowercase hex plus `\n` when the stored bytes contain newline, tab, a trailing `\n`, a BOM/leading space with non-ASCII, or any non-ASCII UTF-8.
  - Reviewer replay: a ~40 KB blob printed as ~80 KB hex blocks a wait-then-read reader (pipe full).
  - This Mac: one `Claude Code-credentials` item; its account matches Claude Code's rule.
- Minimum change: read the same item Claude Code reads (pin its account, fall back to the unpinned read only when the pinned one is not found), decode hex `-w` output, and read the pipes without deadlocking.
- Expansion signals: none — 2 files, no new type (tuple typealias only).
- User decision: KEEP — (b) account pin with fallback + (c) hex decode.

## Out of scope
- Switching prompted reads to `SecItemCopyMatching` (Claude Code resets the item ACL on token refresh).
- `CLAUDE_CONFIG_DIR` / `CLAUDE_SECURESTORAGE_CONFIG_DIR` / `OAUTH_FILE_SUFFIX` service names (needs a settings surface).
- Arming the cooldown on a Deny that exits 51 without "cancel" in stderr (unverified; needs a real dialog).
- Linux, Sparkle, CodexBar vendored code.
- Changing the cooldown duration or the non-blocking lock semantics.

## Decisions
| ID | Chosen | Rejected | Why | Load-bearing assumption | Break signal → response |
|---|---|---|---|---|---|
| D-01 | Pin `-a` with Claude Code's own account rule | CodexBar's "newest modified candidate" probe | Matches exactly what Claude Code reads; no extra Security-framework probe | Claude Code keeps `$USER`/username + `claude-code-user` rule | (1) Claude Code changes the rule → pinned read exits 44 → fallback keeps today's behavior; update the rule. (2) A stale item exists under the login account while Claude Code now writes under another `USER` (`sudo -u`, devcontainer, `USER=x claude`) → BirdNion deterministically reads the stale item and never falls back; accepted: today's result is storage-order random |
| D-02 | Retry unpinned only on exit `44` | Retry on any failure or on runner `nil` | Denial/timeout must not spawn a second prompt | `security` keeps exit 44 for not-found | Exit code changes → fallback never fires → pinned-only behavior; adjust code |
| D-03 | Decode only when output is non-empty, even-length, all hex digits | Always try hex first | JSON text starts with `{`, which is not a hex digit | Credentials blob is a JSON object | Blob stops being JSON → parse already fails today |
| D-04 | One 300 s deadline shared by the pinned and unpinned runs | 300 s per run | Keeps the worst-case lock hold at today's 300 s | `security` honors termination at the deadline | Retry has ≤ 0 s left → skip it and return nil |

## Coverage profile
| ID | Outcome | Change kinds | Material surfaces | Ambiguity/action | Risk/evidence | Required proof |
|---|---|---|---|---|---|---|
| CP-01 | Keychain reads target the item Claude Code itself reads, with unchanged behavior when that item is absent, and no second prompt on denial or timeout | fix | CLI `security` arguments; exit/`nil` handling; shared deadline; no-UI SecItem query; cooldown defaults | none | critical (credential read) — experiments above | source: unit tests via injected runner, injected `copyMatching`, isolated `UserDefaults` suite |
| CP-02 | Hex-printed or large `-w` output parses as the same credentials as small text output | fix | CLI output decoding; pipe reading | none | critical (credential read) — hex and pipe-full replays above | source: unit tests (decode helper; live runner with a large-output `/bin/sh` command) |

## Acceptance criteria
| ID | EARS criterion | Proof |
|---|---|---|
| AC-01 | The system shall derive the Keychain account as `$USER`, else the OS username, replaced by `claude-code-user` when it does not match `^[a-zA-Z0-9._-]+$`. | task-01 Verification Plan |
| AC-02 | When reading via `/usr/bin/security`, the system shall pass `-a <account>` and, if that run exits 44 with deadline time left, retry once without `-a` within the same 300 s deadline. | task-01 Verification Plan |
| AC-03 | If the pinned run exits non-zero with any status other than 44, or the runner returns `nil` (spawn failure or timeout), the system shall not retry; a "cancel" stderr shall arm the cooldown in the injected `UserDefaults`. | task-01 Verification Plan |
| AC-04 | When the no-UI SecItem query by service + account returns `errSecItemNotFound`, the system shall retry once by service only; on any other non-success status it shall not retry. | task-01 Verification Plan |
| AC-05 | When `-w` output is an even-length all-hex string, the system shall hex-decode it before returning; otherwise it shall return the bytes unchanged. | task-02 Verification Plan |
| AC-06 | The `security` runner shall drain stdout and stderr concurrently so outputs larger than the pipe buffer complete before the deadline. | task-02 Verification Plan |

## Tasks
| # | Task | Priority | Criteria | Primary ownership | Dependencies | Status |
|---|---|---|---|---|---|---|
| 01 | Pin Claude Code's account with not-found fallback | P1 | AC-01, AC-02, AC-03, AC-04 | `BirdNion/Providers/Claude/OAuth/ClaudeOAuth.swift`, `BirdNionTests/ClaudeNativeTests.swift` | - | done |
| 02 | Decode hex output and drain pipes concurrently | P2 | AC-05, AC-06 | `BirdNion/Providers/Claude/OAuth/ClaudeOAuth.swift`, `BirdNionTests/ClaudeNativeTests.swift` | task-01-pin-keychain-account.md | done |

## Review log
- Round 1 (2026-10-19): 2 fresh reviewers (Fact Checker + Flow/Contract; Security + Failure-mode). 9 findings after dedupe — F1 test writes cooldown to real defaults (High), F2 AC-04 unproven (High), F3 pipe deadlock on large output (Medium), F4 `nil` must not retry (Medium), F5 shared deadline (Medium), F6 injection seam signature (Medium), F7 stale-item edge in D-01 (Medium), F8 blocked without cause / receipt comment (Medium), F9 citation off by one (Low). User decision: accept all 9. Sweep: 3 files reread / 9 deltas / stale `ClaudeProvider.swift:277-280`, "300 s per run", "[no automated proof]", receipt comment fixed.
- Closure pass (2026-10-19, fresh reviewer): F1–F4, F6–F9 PASS; F5 repaired in text only. Sweep found C1 (shared deadline had no oracle), C2 (`liveCopyMatching` undefined; retry query could skip `KeychainNoUIQuery.apply`), C3 (stale "0 conflicts"). Repaired in task-01 Steps 3–6, Acceptance AC-02/AC-04, Counterexample: injected `clock`, remaining-time and exhausted-deadline cases, no-UI keys asserted on every query. Paper rounds used: 2 of 2 — further findings need runtime evidence.

| ID | Decision | Original counterexample | Repaired at | Proved at | Replay | Closure |
|---|---|---|---|---|---|---|
| F1 | accept | cooldown written to real app defaults by a test | task-01 Steps 3, 4, 6; AC-03 | ClaudeOAuth.swift:571-572 (`defaults:` param exists); pbxproj:1348 | AC-03 asserts `.standard` untouched | PASS |
| F2 | accept | no-UI retry unproven | task-01 Step 5; AC-04 | named probe `testNoUIKeychainReadRetriesWithoutAccountOnlyOnNotFound` | retry on interaction-not-allowed fails it | PASS |
| F3 | accept | pipe full on >64 KB output | task-02 Step 3; AC-06 | ClaudeOAuth.swift:233-237 (read after exit today) | 200000-byte probe times out under old order | PASS |
| F4 | accept | `nil` treated as 44 | AC-03; D-02; task-01 Step 4 | AC-03 `nil` case | second call fails it | PASS |
| F5 | accept | 300 s per run → ~600 s | D-04; task-01 Steps 3–4, 6; AC-02 | AC-02 remaining-time + exhausted-deadline cases (after C1 repair) | fresh 300 s retry fails AC-02 | PASS |
| F6 | accept | seam breaks zero-arg caller | task-01 Step 3; task-02 Step 3 | ClaudeProvider.swift:280 zero-arg call | all params defaulted | PASS |
| F7 | accept | stale item chosen deterministically | plan D-01 break signal (2) | documented as accepted risk | n/a (documentation) | PASS |
| F8 | accept | blocked without cause | task-01:3, task-02:3 `pending` | one `Status:` per task | — | PASS |
| F9 | accept | citation off by one | plan.md Existing | ClaudeProvider.swift:278-281 | — | PASS |
