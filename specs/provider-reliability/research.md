# Research — provider-reliability

**Feature:** macOS-first reliability core (roadmap Phase 7 items 1-3)
**Execution tier:** Standard · **Discovery mode:** light
**Date:** 2026-07-07

## Evidence Summary

- **Codebase scout result:** DONE — the three surfaces already exist and are the exact
  extension points. No new subsystem is needed.
- **External research result:** SKIPPED (justified). This is an internal, macOS-only
  reliability feature over existing code. No third-party API, no library/version choice,
  no security/auth/privacy/payment rule, and the user did not ask for "best/latest/optimal".
  Per SKILL.md Step 5, external research is not mandatory here.
- **Selected decision:** Add a *pure* Swift error classifier (`ProviderErrorKind` +
  `classify(rawError:)`) as a single testable seam, then plumb its output into (a) the
  ProvidersPane sidebar subtitle + detail grid, (b) a new per-provider self-test button,
  and (c) a failure-episode counter inside `QuotaService.refresh()` that fires one
  `QuotaNotifier` notification after >=3 consecutive failing cycles.
- **Rejected alternatives:** (1) Structured error types on every provider (would touch
  ~23 fetchers, violates KISS/surgical scope, no new dep needed). (2) A new
  `ReliabilityService` (over-engineering; the loop already exists in `QuotaService`).
  (3) Retry/backoff on failure (out of scope — only classification + notification asked).
- **Remaining gaps:** None blocking. The raw error strings are ad-hoc and bilingual, so
  classification must match on stable substrings + HTTP codes, ordered specific-first.
- **Downstream task/test implications:** classifier is unit-testable in isolation;
  notification episode logic is unit-testable via `QuotaService` (existing
  `QuotaServicePollingTests` pattern). UI wiring is verified by build + component-level
  reasoning (SwiftUI, no snapshot harness in repo).

## Codebase Scout Findings

### Refresh loop + notification host — `BirdNion/Services/QuotaService.swift`
- `@MainActor final class QuotaService: ObservableObject` polls every provider in
  parallel on a 120s ± 10s loop via `refresh(forceProviderIDs:)`.
- On a throwing fetch, the catch builds `ProviderStatus(..., error: "\(error)")`
  (line ~253). Errors reach the status as a raw string in `status.error`.
- **Stale-preservation caveat (CRITICAL for R3):** when a follow-up fetch errors but a
  previous *renderable* snapshot exists, the code KEEPS the old good snapshot
  (`preserve stale status ...`, line ~265) so `statuses[id].error` stays `nil`. So the
  failure-episode counter must observe the *fetch result*, not the post-preservation
  `statuses` array — otherwise a provider that keeps timing out would never be counted as
  failing because its published status still shows old good data.
- Existing warning system: `evaluateWarnings(_:)` + `QuotaWarnConfig` with a
  `warnState: [String: [String: (last, fired)]]` "fire once per crossing, re-arm on
  recovery" pattern. R3's episode logic mirrors this pattern (fire-once, reset-on-recover)
  but is a SEPARATE, additive state map — the quota-threshold system is out of scope.
- `QuotaNotifier.post(id:title:body:)` — thin `UNUserNotificationCenter` wrapper,
  requests auth lazily, honors `QuotaWarnConfig.soundEnabled` + on-screen overlay. Reuse
  as-is for the failure notification.

### Provider contract — `BirdNion/Providers/QuotaProvider.swift`
- `protocol QuotaProvider { var id; var displayName; func fetch() async throws -> ProviderStatus }`.
- Self-test = call the SAME `provider.fetch()` once. No new network layer.

### Status model — `BirdNion/Models/ProviderStatus.swift`
- `ProviderStatus.error: String?`. Invariant: `error != nil` ⇒ `windows.isEmpty`.
  Classification is derived on read; the model is unchanged.

### UI surfaces — `BirdNion/Views/Settings/ProvidersPane.swift`
- Sidebar subtitle: `statusSubtitle(for:)` (line ~2800) currently does
  `L10n.f("provider.errorPrefix", language, truncated(L10n.providerText(err), 32))`.
  This is where the classified message replaces the raw string.
- Tooltip already exists: `statusSubtitleDetail(for:)` (line ~2819) feeds the row
  `.help(...)` — keep the RAW error here.
- Detail grid: `detailInfoGrid(_:)` (line ~550) renders
  `infoRow(L10n.t("provider.error"), L10n.providerText(err))` at line ~603 — replace value
  with classified message; add `.help(rawError)` for the raw fallback.
- Detail header already has a per-provider reload button (line ~512) — the self-test
  button goes near it (or in the info grid), scoped to a single provider via
  `provider.fetch()`.
- `status(for:)` (line ~2767) returns the live `ProviderStatus` for a provider id.

### Localization — `BirdNion/Services/AppLocalizer.swift`
- `enum L10n` with `en` / `vi` dictionaries; `t(key, pref)` + `f(key, pref, args...)`.
  All new UI strings need both tables. `providerText(_:)` does substring replacement of
  provider copy across languages (not a keyed lookup) — the classifier's OUTPUT should be
  a localization KEY per kind, not a raw string, so we use `L10n.t`/`L10n.f` directly.

### Tests — `BirdNionTests/`
- XCTest. `QuotaServicePollingTests.swift` uses stub providers (`StubProvider`,
  `ThrowingProvider`, `GoodThenErrorProvider`, `CountingProvider`) and `@MainActor` async
  tests — the exact harness R0 + R3 unit tests plug into.
- `ProviderStatusTests.swift` exists for model-level assertions.

### Build system — `BirdNion.xcodeproj/project.pbxproj`
- No synced groups: new `.swift` files require manual `pbxproj` edits (PBXBuildFile +
  PBXFileReference + Sources build phase, for BOTH the app target and, for a testable
  type, the test target). Memory note `pbxproj-no-synced-groups` confirms this.
- **Decision:** put `ProviderErrorKind` + `classify` in a NEW file
  `BirdNion/Services/ProviderErrorClassifier.swift` (a pure classifier is a clear logical
  boundary and must be `@testable import`-reachable), and add its unit test file. The R0
  task carries the exact pbxproj steps. Everything else (UI + notification) edits EXISTING
  files, so no further pbxproj churn.

## Raw Error String Universe (input to the classifier)

Sampled via grep across `BirdNion/Providers/**/*.swift`. The classifier matches
substrings + HTTP status codes, ordered specific-first. Representative inputs per kind:

| Kind | Representative raw substrings / codes |
|---|---|
| `cookieExpiredOrMissing` | "Không tìm thấy cookie", "cần auth", "session cookie", "(cookie)", "Chưa cấu hình token và không tìm thấy cookie" |
| `tokenInvalidOrMissing` | "Chưa cấu hình token", "token không hợp lệ", "Access token hết hạn (401)", "token expired", "expired_token", "GitHub token không hợp lệ", HTTP 401/403 |
| `rateLimited` | HTTP 429, "rate limit", "quá nhiều yêu cầu" |
| `networkUnreachableOrTimeout` | "Network:", "Network (cookie):", "timeout", "timeout sau 12s", "codex /status timeout", "Kiro CLI timeout" |
| `apiSchemaChanged` | "Response ... không hợp lệ", "Response JSON không hợp lệ", "Response thiếu trường", "Không có model nào", "Định dạng ... không nhận ra", "Phản hồi không hợp lệ", HTTP 5xx |
| `unknown` | anything unmatched (fallback) |

Ordering rule that matters: a message like `"HTTP 401 (cookie)"` contains BOTH a cookie
marker and 401. Product intent = "cookie expired → re-login the browser" beats "token
wrong", so cookie markers are checked before the generic 401→token rule. `429` is checked
before 401/403. Timeout/network markers are checked before schema (a network error can
carry a garbled body). This ordering is fixed in design as a canonical invariant.

## Unresolved Questions

- None blocking. `N = 3` consecutive failing cycles is fixed per the approved scope
  ("liên tục >N lần", user-approved N=3). Not made user-configurable (YAGNI; the quota
  threshold system is the configurable one and is out of scope).
