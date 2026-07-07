# Requirements — provider-reliability

**Feature:** macOS-first reliability core (roadmap Phase 7 items 1-3)
**Platform:** macOS only (Linux/Windows sync tracked separately)
**Canonical language:** English

## Overview

BirdNion must never fail silently. Providers currently surface ad-hoc raw error strings
that a user cannot act on, there is no way to test a single provider on demand, and a
provider can die quietly without notice. This feature adds: (1) a pure, unit-testable
error classifier that maps raw errors into actionable groups with remediation hints,
(2) a per-provider self-test button, and (3) a one-shot notification when a provider
transitions from OK to failing for several consecutive refresh cycles.

## Functional Requirements

### R0 — Foundation: pure error classifier

The classifier is the shared seam consumed by R2 and R3.

- **R0.1** The system shall provide a pure function `classify(rawError:)` that maps a
  provider's raw `error` string (and any embedded HTTP status code) to exactly one
  `ProviderErrorKind` value from the fixed set: `cookieExpiredOrMissing`,
  `tokenInvalidOrMissing`, `apiSchemaChanged`, `networkUnreachableOrTimeout`,
  `rateLimited`, `unknown`.
- **R0.2** The classifier shall be a pure function with no I/O, no global state, and no
  dependency on UI or network types, so it is unit-testable in isolation.
- **R0.3** When a raw error contains both a cookie marker and an authentication status
  code (e.g. `"HTTP 401 (cookie)"`), the classifier shall classify it as
  `cookieExpiredOrMissing` (cookie markers take precedence over the generic 401/403 →
  token rule).
- **R0.4** When a raw error carries HTTP `429` or a rate-limit marker, the classifier
  shall return `rateLimited`, evaluated before the 401/403 → token rule.
- **R0.5** When a raw error carries a timeout or network marker (e.g. `"timeout"`,
  `"Network:"`), the classifier shall return `networkUnreachableOrTimeout`, evaluated
  before the schema rule.
- **R0.6** If a raw error matches no known group, the classifier shall return `unknown`.
- **R0.7** When the provided raw error is `nil` or empty, the classifier shall return
  `nil` (no error to classify), and callers shall treat this as "no error".

### R1 — Actionable remediation hints + localization

- **R1.1** The system shall provide, for each non-`unknown` `ProviderErrorKind`, a short
  human-readable title and a one-line remediation hint (e.g. `cookieExpiredOrMissing` →
  "Cookie hết hạn — đăng nhập lại trình duyệt"; `tokenInvalidOrMissing` → "Token sai —
  dán lại API key").
- **R1.2** Where the app language is Vietnamese or English, the system shall render every
  classified title and remediation hint in that language via the existing `L10n` en+vi
  tables (no hard-coded single-language string in a view).
- **R1.3** For the `unknown` kind, the system shall present a generic actionable message
  (e.g. "Lỗi không xác định — xem chi tiết") in the sidebar while keeping the raw error
  reachable; for the `unknown` kind, the detail info grid shall show the raw error string
  inline so the "see detail" hint is not a dead end.
  <!-- Updated: Validation Session 1 — Red Team Finding 6 -->

### R2 — Classified display + self-test button (Settings → Providers)

- **R2.1** While a provider has a non-empty `error`, the ProvidersPane sidebar row
  subtitle shall show the classified message (title/hint) instead of the raw error
  string.
- **R2.2** While a provider has a non-empty `error`, the ProvidersPane detail info grid
  "Error" row shall show the classified message instead of the raw error string.
- **R2.3** The system shall keep the raw error string reachable from both the sidebar row
  and the detail grid via a tooltip/`help` overlay, so power users can still read it.
- **R2.4** Where a provider is selected in the Providers detail pane, the system shall
  present a "Self-test" (Kiểm tra) button.
- **R2.5** When the user activates the self-test button, the system shall run exactly one
  fetch for that provider using the existing provider fetch path (`QuotaProvider.fetch()`)
  and shall not create a new network layer.
- **R2.6** When a self-test fetch succeeds (no error, renderable result), the system shall
  show an inline pass state for that provider.
- **R2.7** If a self-test fetch fails, the system shall show an inline fail state with the
  classified reason + remediation hint (not the raw string), while keeping the raw error
  reachable.
- **R2.8** While a self-test fetch is in flight, the system shall show an in-progress
  state and shall disable re-triggering the same provider's self-test until it completes.
- **R2.9** If the selected provider has no live fetchable instance (e.g. it is disabled and
  not in the active provider list), the self-test shall not enter or remain in the
  in-progress state; it shall instead show a fail/hint state directing the user to enable
  the provider first. <!-- Updated: Validation Session 1 — Red Team Finding 2 -->

### R3 — Failure-transition notification

- **R3.1** While a provider transitions from a previously OK state to a failing fetch
  result, the system shall increment a per-provider consecutive-failure counter on each
  subsequent failing *fetch* of that provider. Refresh cycles on which the provider is
  skipped by its per-provider interval throttle (not fetched) shall neither increment nor
  reset the counter. <!-- Updated: Validation Session 1 — Red Team Finding 1 -->
- **R3.2** When a provider's consecutive-failure counter reaches 3, and provider-failure
  notifications are enabled (dedicated `providerFailureNotificationsEnabled` flag, default
  enabled — NOT the quota-warning master toggle), the system shall post exactly one
  notification via the existing `QuotaNotifier`, using a per-episode-unique identifier,
  naming the provider and including the classified reason + remediation hint.
  <!-- Updated: Validation Session 1 — Red Team Findings 3, 7 -->
- **R3.3** While a provider stays failing after the notification has fired, the system
  shall not post additional notifications for the same failure episode (fire once per
  episode).
- **R3.4** When a provider's fetch succeeds again (recovery), the system shall reset that
  provider's consecutive-failure counter and re-arm it so a future new failure episode can
  notify again.
- **R3.5** The system shall base the failure counter on the awaited fetch result of each
  fetch, not on the published `statuses`/`displayStatuses`/`pending` snapshots, so that
  stale-snapshot preservation in `QuotaService.refresh()` does not hide an ongoing failure.
  <!-- Updated: Validation Session 1 — Red Team Finding 4 -->

## Non-Functional Requirements

- **R4.1 (Reliability)** The self-test and classification paths shall never crash the app:
  a throwing provider fetch shall be caught and surfaced as a fail state, consistent with
  the existing `QuotaService` catch behavior.
- **R4.2 (Performance)** Classification shall be O(n) over the raw error length (simple
  ordered substring/code checks) and add no measurable overhead to the refresh loop
  (called at most once per provider per cycle).
- **R4.3 (Maintainability / Scope)** The change shall not modify the existing
  quota-warning threshold system (`QuotaWarnConfig`), the `ProviderStatus` error invariant,
  provider `fetch()` signatures, or introduce any third-party dependency.
- **R4.4 (Reachability)** Every new user-facing surface (sidebar subtitle, detail grid,
  self-test button, notification) shall be wired to the real runtime entrypoints
  (`ProvidersPane`, `QuotaService.refresh()`) and reachable in the running app — no orphan
  code.
- **R4.5 (Test coverage)** The classifier (R0) and the failure-episode logic (R3) shall
  have unit tests in `BirdNionTests/` following the existing XCTest patterns; the full
  suite shall build and pass.

## Requirements Traceability (summary)

| Req | Covered by task |
|---|---|
| R0.1–R0.7 | task-R0-01 |
| R1.1–R1.3 | task-R1-01 (R1.3 detail-raw display in task-R2-01) |
| R2.1–R2.3 | task-R2-01 |
| R2.4–R2.9 | task-R2-02 |
| R3.1–R3.5 | task-R3-01 |
| R4.1–R4.5 | task-R4-01 (+ enforced across R0–R3 tasks) |

## Unresolved Questions

- None. `N = 3` consecutive failing *fetches* is fixed per approved scope; not made
  user-configurable (YAGNI). Provider-failure notifications use a dedicated default-enabled
  flag (`providerFailureNotificationsEnabled`), decided during Validation Session 1.
