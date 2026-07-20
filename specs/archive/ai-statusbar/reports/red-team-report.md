# Red Team Review — ai-statusbar — 2026-06-23

**Findings:** 45 collected, 30 deduplicated, 15 prioritized for adjudication.
**Severity breakdown:** 4 Critical, 8 High, 3 Medium (after dedup, before BOSS decision)
**Reviewers:** Security Adversary, Failure Mode Analyst, Assumption Destroyer, Scope & Complexity Critic

## Disposition table

| # | Finding | Severity | Disposition | Applied To |
|---|---------|----------|-------------|------------|
| F1 | HapoHubProvider auth header substitution vulnerable to CR/LF injection | High | **Accept** | task-R1-02 (token regex validation) |
| F2 | `providers.json` plaintext controls endpoint + auth scheme (tampering) | High | **Accept** | task-R1-01 (MiniMax endpoint is compile-time constant), design.md §KeychainService |
| F3 | `ANTHROPIC_API_KEY` written plaintext to `settings.json` violates R11.1 | High | **Accept** | task-R2-03 (KEYCHAIN_REF placeholder), requirements R11.1 |
| F4 | `~/Library/Application Support/AIStatusbar/` not created on first launch → crash | High | **Accept** | task-R2-04 (explicit `createDirectory`) |
| F5 | `URLProtocol` stubs cannot intercept `URLSession.shared` → tests hit real network | Critical | **Accept** | task-R1-01 + task-R1-02 (inject `URLSession` via init) |
| F6 | MiniMax `token_plan/remains` requires inference key, not Subscription Key | Critical | **Accept** | task-R1-01 (distinct 401/403 error message), requirements R3.6 |
| F7 | Claude Code does not hot-reload `settings.json` → edits invisible until restart | Critical | **Accept** | task-R2-03 (post-save banner "Khởi động lại Claude Code để áp dụng") |
| F8 | `~/.claude/projects/<id>/.claude/settings.json` does not exist on BOSS machine | High | **Accept (superseded by F14)** | scope_lock drop per-project, R7.* struck |
| F9 | `.bak` rotation overwrites only-slot → bad save unrecoverable | Critical | **Accept** | task-R3-01 (3-deep ring `.bak`/`.bak.1`/`.bak.2` with JSON-parse validation) |
| F10 | Atomic write cross-filesystem `EXDEV` → copy+unlink non-atomic | Critical | **Reject** | BOSS's filesystem is APFS only; mitigation: temp in same directory as target (still documented in design.md) |
| F11 | `providers.json` no atomic write + no lock → races with self/editor | Critical | **Accept** | task-R2-04 (atomic write + `flock` lock) |
| F12 | `QuotaService.refresh()` + 60s timer can overlap → double-fetch | High | **Reject** | Acceptable for v1 personal use; revisit if concurrent UI |
| F13 | `MenuBarIcon` shows neutral during first cycle → no warn on missing token | Medium | **Reject** | Minor UX; first cycle is < 1s |
| F14 | Per-project `~/.claude/projects/` editing is YAGNI | High | **Accept (per BOSS)** | scope_lock + R7.* + R3-01 step 4-5 + R2-03 step 2 removed |
| F15 | Settings provider-mgmt UI is over-engineered for "enter token once" | High | **Reject (per BOSS)** | BOSS chose "Giu Settings day du"; F2 + F11 fixes applied |

## Rejected findings — rationale

- **F10 (`EXDEV`)**: BOSS's Mac is APFS. Temp file in same directory as target is already the design choice; the cross-FS failure mode is theoretical. Documented as risk in design.md.
- **F12 (double-fetch)**: For a personal-use app with 2 providers polled every 60s, occasional double-fetch is harmless. A 5-line `inFlight: Task?` guard can be added later if needed.
- **F13 (neutral icon during first cycle)**: First cycle completes in < 1s; UX impact negligible.
- **F15**: BOSS explicitly chose to keep the full Settings sheet (token entry + enable/disable toggle + persistence). F2 + F11 harden the security/concurrency aspects of that sheet; the UI scope is preserved.

## Verifier

- Pre-validate: `node .claude/scripts/validate-spec-output.cjs specs/ai-statusbar` → PASS
- Pre-ground: `node .claude/scripts/spec-ground.cjs specs/ai-statusbar --root /Users/nghialuutrung/Desktop/statusbar` → GROUNDED
- Post-fix validators: PASS + GROUNDED (re-run after all 13 accepted findings applied)
