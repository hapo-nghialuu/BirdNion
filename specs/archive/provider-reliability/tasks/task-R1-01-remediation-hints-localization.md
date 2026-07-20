# Task R1-01: Remediation hints localization

**Requirement:** R1 — Actionable remediation hints + localization
**Status:** done
**Priority:** P1
**Estimated Effort:** 1-2h
**Dependencies:** tasks/task-R0-01-error-classifier-foundation.md
**Spec:** specs/provider-reliability/

## Context

- **Why**: Each error kind must show a short title + one-line remediation hint (cookie → "đăng nhập lại trình duyệt", token → "dán lại API key") in the user's language, replacing the raw string.
- **Current state**: `BirdNion/Services/AppLocalizer.swift` holds `enum L10n` with `en` and `vi` dictionaries and `t(key,pref)` / `f(key,pref,args...)` lookups. `ProviderErrorKind` (from R0-01) exposes `titleKey`/`hintKey` = `providerError.<kind>.{title,hint}`.
- **Target outcome**: Every `providerError.*` key and the self-test/notification UI keys resolve in both en and vi, so views/notifications never hard-code a single-language string.

## Constraints

- **MUST**: Add `title` + `hint` keys for all six kinds (including `unknown`) to BOTH `en` and `vi` (R1.2). `unknown` gets a generic actionable message (R1.3).
- **MUST**: Add the self-test UI keys + notification body key consumed by R2-02 / R3-01.
- **SHOULD**: Keep hints imperative, one line, short enough for the truncated sidebar/detail width.
- **MUST NOT**: Introduce a new localization mechanism; reuse the existing en/vi dictionary pattern.
- **SCOPE**: Only string tables. No view or classifier logic here.

## Steps

- [x] 1. Add `providerError.<kind>.title` + `providerError.<kind>.hint` for all six kinds to `en` and `vi`.
  - Business intent: actionable, localized copy per error group.
  - Code detail: vi `providerError.cookieExpiredOrMissing.hint = "Cookie hết hạn — đăng nhập lại trình duyệt"` / en `"Cookie expired — sign in again in your browser"`; token vi `"Token sai — dán lại API key"` / en `"Invalid token — re-paste your API key"`; apiSchemaChanged vi `"Phản hồi lạ — có thể cần cập nhật app"`; networkUnreachableOrTimeout vi `"Mất mạng hoặc quá thời gian — kiểm tra kết nối"`; rateLimited vi `"Bị giới hạn tần suất — đợi rồi thử lại"`; unknown vi `"Lỗi không xác định — xem chi tiết"` (R1.1, R1.3).
  - _Requirements: 1.1, 1.2, 1.3_

- [x] 2. Add self-test + notification keys to `en` and `vi`.
  - Business intent: R2-02 and R3-01 render localized labels/body.
  - Code detail: `provider.selfTest` ("Kiểm tra" / "Self-test"), `provider.selfTest.running` ("Đang kiểm tra…" / "Testing…"), `provider.selfTest.pass` ("Đạt" / "Passed"), `provider.selfTest.fail` ("Lỗi" / "Failed"), `provider.selfTest.disabled` ("Bật provider để kiểm tra" / "Enable the provider to test") <!-- Updated: Red Team Finding 2 -->, and `notification.providerFailing` format string taking title + hint, e.g. `"%@ — %@"`.
  - _Requirements: 1.1, 1.2_

- [x] 3. Verification implementation
  - Iterate `ProviderErrorKind.allCases`, assert `L10n.t(kind.titleKey, "vi") != kind.titleKey` (and `"en"`, and `hintKey`) so no key falls through to the raw-key fallback.
  - _Requirements: 1.1, 1.2, 1.3_

## Requirements

- 1.1 — Short title + one-line remediation hint per non-`unknown` kind.
- 1.2 — Titles/hints render in vi and en via existing `L10n` tables.
- 1.3 — `unknown` gets a generic actionable message; raw error stays reachable (via R2-01).

## Related Files

| Path | Action | Description |
|---|---|---|
| `BirdNion/Services/AppLocalizer.swift` | Modify | Add `providerError.*`, `provider.selfTest*`, `notification.providerFailing` to en+vi |
| `BirdNion/Services/ProviderErrorClassifier.swift` | Read | Source of `titleKey`/`hintKey` naming |
| `BirdNionTests/ProviderErrorClassifierTests.swift` | Modify | Assert every kind's keys resolve in both languages |

## Completion Criteria

- [x] All six kinds have `.title` + `.hint` in both en and vi (R1.1, R1.2).
- [x] `unknown` has a generic actionable message (R1.3).
- [x] Self-test keys (`provider.selfTest*`) and `notification.providerFailing` exist in both languages.
- [x] No `providerError.*` key returns the raw key (fallback) when looked up in either language.

## Evidence

- [x] Automated verification (unit)
  - Command(s): `xcodebuild test -scheme BirdNion -destination 'platform=macOS' -only-testing:BirdNionTests/ProviderErrorClassifierTests`
  - Expected proof: loop over `ProviderErrorKind.allCases` asserting `L10n.t(kind.titleKey, "vi") != kind.titleKey` and same for `"en"`/`hintKey`; exit 0.
- [x] Artifact / runtime verification
  - Inspect: `AppLocalizer.swift` en + vi dictionaries.
  - Expect: 12 `providerError.*` entries per language + self-test/notification keys present.
- [x] Runtime reachability verification
  - Entrypoint/caller: keys consumed by `ProvidersPane` (R2-01/R2-02) and `QuotaService` (R3-01); wired proof in task-R4-01.
  - Expect: key names exactly match `ProviderErrorKind.titleKey`/`hintKey` output.
- [x] Contract / negative-path verification
  - Check: switching app language vi↔en changes the rendered hint.
  - Expect: distinct vi and en strings per key.


### Verification Receipt (2026-07-07)

- `xcodebuild test ... -only-testing:BirdNionTests/ProviderErrorClassifierTests` → **TEST SUCCEEDED** incl. `testAllKindsResolveInBothLanguages` (6 kinds × 2 langs × title+hint, vi≠en negative check) and `testSelfTestAndNotificationKeysResolve` (6 keys × 2 langs).
- Artifact: `AppLocalizer.swift` — 12 `providerError.*` entries per language + 5 `provider.selfTest*` + `notification.providerFailing`, en + vi.

## Risk Assessment

| Risk | Severity | Mitigation |
|---|---|---|
| Key name mismatch with classifier `titleKey`/`hintKey` | Medium | Derive keys from the same `providerError.<rawValue>.*` convention; resolve-test in step 3 |
| Missing one language entry → raw-key leak in UI | Low | Resolve-test iterates all kinds in both languages |

---

> **Parallel marker**: Append `(P)` to the title if this task can run concurrently with another (usually when serving different requirements).
> **Test note**: If a test coverage sub-task can be deferred post-MVP, mark it with `- [ ]*`.
> **Requirement mapping**: Every sub-task MUST end with `_Requirements: X.X_`. No mapping = invalid task file.
> **Evidence rule**: No `## Evidence` section = invalid task file. Existing specs may use `## Task Test Plan & Verification Evidence` or legacy `## Verification & Evidence`; agents must support all three headings.
