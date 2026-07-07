# Task R3-01: Failure transition notification

**Requirement:** R3 — Failure-transition notification
**Status:** done
**Priority:** P1
**Estimated Effort:** 2-3h
**Dependencies:** tasks/task-R0-01-error-classifier-foundation.md, tasks/task-R1-01-remediation-hints-localization.md

**Spec:** specs/provider-reliability/

## Context

- **Why**: A provider can die silently (expired cookie, revoked token) and the user only notices later. When a provider goes OK → failing for 3 consecutive refresh cycles, post one notification naming the provider and the classified reason.
- **Current state**: `BirdNion/Services/QuotaService.swift` `refresh(forceProviderIDs:)` fetches each due provider in a `withTaskGroup`; the `for await (id, status, elapsed) in group` loop sets `status`. A thrown fetch is caught and yields `ProviderStatus(..., error: "\(error)")`. CRITICAL: when a follow-up fetch errors but a prior renderable snapshot exists, the loop KEEPS the old good snapshot (`preserve stale status...`) so the published `statuses[id].error` stays `nil`. Existing `QuotaNotifier.post(id:title:body:)` + `QuotaWarnConfig.enabled` gate the quota-warning notifications; `evaluateWarnings(_:)` uses a fire-once/re-arm `warnState` map — a pattern R3 mirrors with a SEPARATE map.
- **Target outcome**: A per-provider consecutive-failure counter driven off the fetched result posts exactly one notification at 3 failures and re-arms on recovery.

## Constraints

- **MUST**: Drive the counter off the freshly-fetched `status.error != nil` computed BEFORE the stale-preservation branch overwrites `pending[id]` (R3.5) — otherwise ongoing failures are masked.
- **MUST**: Fire exactly once per failure episode; reset + re-arm on a successful fetch (R3.3, R3.4). Use a NEW map `failureEpisode: [String: (consecutive: Int, notified: Bool)]`, separate from `warnState` (R4.3).
- **MUST**: Threshold `N = 3` as a fixed `private static let failureNotifyThreshold = 3`. Gate on `QuotaWarnConfig.enabled` (reuse the master notifications toggle — no new setting).
- **MUST NOT**: Modify `QuotaWarnConfig`, `evaluateWarnings`, `ProviderStatus`, or provider fetch signatures.
- **SCOPE**: Only R3.1–R3.5. No retry/backoff, no per-provider config.

## Steps

- [x] 1. Add the episode state + threshold + enablement flag to `QuotaService`.
  - Business intent: track consecutive failures per provider without touching the quota-warning system.
  - Code detail: `private var failureEpisode: [String: (consecutive: Int, notified: Bool, episodeSeq: Int)] = [:]` and `private static let failureNotifyThreshold = 3`. <!-- Updated: Red Team Finding 7 --> Add `static var failureNotificationsEnabled: Bool { UserDefaults.standard.object(forKey: "providerFailureNotificationsEnabled") as? Bool ?? true }` (default TRUE, dedicated — NOT `QuotaWarnConfig.enabled`).
  - _Requirements: 3.1, 3.2, 3.3_

- [x] 2. Compute `fetchFailed` from the awaited status and call an episode evaluator inside the refresh loop.
  - Business intent: base the decision on the actual fetch result of THIS fetch (R3.5).
  - Code detail: in `for await (id, status, elapsed) in group`, derive `let fetchFailed = (status.error != nil)` from the AWAITED `status` only. <!-- Updated: Red Team Finding 4 --> MUST NOT read `pending[id]`, `statuses`, or `displayStatuses` (they may carry a preserved stale good snapshot). The loop iterates only FETCHED (`due`) providers, so skipped providers never call the evaluator (consecutive = consecutive fetches, Finding 1). Call `evaluateFailureEpisode(id: id, displayName: status.displayName, error: status.error)`.
  - _Requirements: 3.1, 3.5_

- [x] 3. Implement `evaluateFailureEpisode(id:displayName:error:)`.
  - Business intent: fire once at 3, don't spam, reset on recovery, deliver reliably on a 2nd episode.
  - Code detail: `var st = failureEpisode[id] ?? (0, false, 0)`. If `error == nil` → `failureEpisode[id] = (0, false, st.episodeSeq)` (reset + re-arm, keep seq; R3.4). Else `st.consecutive += 1`; if `st.consecutive >= Self.failureNotifyThreshold && !st.notified && Self.failureNotificationsEnabled { st.episodeSeq += 1; let kind = classify(rawError: error) ?? .unknown; QuotaNotifier.post(id: "\(id).failing.\(st.episodeSeq)", title: displayName, body: L10n.f("notification.providerFailing", nil, L10n.t(kind.titleKey), L10n.t(kind.hintKey))); st.notified = true }; failureEpisode[id] = st`. <!-- Updated: Red Team Findings 3 (per-episode id), 7 (dedicated flag) -->
  - _Requirements: 3.2, 3.3, 3.4_

- [x] 4. Verification implementation
  - Extend `BirdNionTests/QuotaServicePollingTests.swift` with a stub that fails N times then recovers; assert the notification fires exactly once at the 3rd failing FETCH, not before, not again on the 4th, and re-arms after a success (a fresh 3-failure run notifies again with a NEW episode id). Use an injectable notifier seam (closure) or assert the observable `failureEpisode` transitions (consecutive/notified/episodeSeq). Include a case proving a preserved stale good snapshot does not stop the counter (R3.5), and a case with `providerFailureNotificationsEnabled = false` producing no notification.
  - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5_

## Requirements

- 3.1 — Increment a per-provider consecutive-failure counter each failing FETCH after an OK→fail transition; skipped cycles neither increment nor reset.
- 3.2 — Post exactly one `QuotaNotifier` notification at 3 (dedicated default-on flag), per-episode-unique id, naming provider + classified reason + hint.
- 3.3 — Do not re-notify while still failing in the same episode.
- 3.4 — Reset + re-arm the counter on recovery.
- 3.5 — Base the counter on the awaited fetch result, not the published `statuses`/`pending`/`displayStatuses` snapshots.

## Related Files

| Path | Action | Description |
|---|---|---|
| `BirdNion/Services/QuotaService.swift` | Modify | `failureEpisode` map, `failureNotifyThreshold`, `failureNotificationsEnabled`, loop hook, `evaluateFailureEpisode` |
| `BirdNion/Services/ProviderErrorClassifier.swift` | Read | `classify` for the notification reason |
| `BirdNion/Services/AppLocalizer.swift` | Read | `notification.providerFailing` + `providerError.*` keys |
| `BirdNionTests/QuotaServicePollingTests.swift` | Modify | Episode unit tests (fire-once, re-arm, per-episode id, stale-snapshot safety, flag-off) |

## Completion Criteria

- [x] `failureEpisode` state + `failureNotifyThreshold = 3` + dedicated `failureNotificationsEnabled` (default true) added, separate from `warnState`/`QuotaWarnConfig` (R3.1, R3.2, R4.3).
- [x] Notification posts exactly once at the 3rd consecutive failing fetch with provider name + classified reason and a per-episode-unique id (R3.2). <!-- Updated: Red Team Findings 3, 7 -->
- [x] No re-notification while failing; counter resets + re-arms on a successful fetch; a 2nd episode notifies again with a new id (R3.3, R3.4).
- [x] Counter is driven by the awaited `status.error` (never `pending`/`statuses`/`displayStatuses`), verified to still count when a stale good snapshot is preserved (R3.5); skipped-throttled cycles do not move the counter (R3.1).

## Evidence

- [x] Automated verification (unit)
  - Command(s): `xcodebuild test -scheme BirdNion -destination 'platform=macOS' -only-testing:BirdNionTests/QuotaServicePollingTests`
  - Expected proof: new episode test passes — notify count == 0 after fetches 1-2, == 1 after fetch 3, still == 1 after fetch 4, a subsequent success resets so a new 3-failure run notifies again with a new episode id; a `providerFailureNotificationsEnabled = false` run posts nothing; exit 0.
- [x] Artifact / runtime verification
  - Inspect: `QuotaService.evaluateFailureEpisode` in source + the refresh-loop hook site.
  - Expect: `fetchFailed` read from the awaited `status.error` (not `pending`/`statuses`); `QuotaNotifier.post` called with id `"<id>.failing.<seq>"` and the classified body.
- [x] Runtime reachability verification
  - Entrypoint/caller: `QuotaService.refresh()` loop — the live poll cycle started by `QuotaService.start()`.
  - Expect: `evaluateFailureEpisode` invoked once per FETCHED provider per cycle from the running loop.
- [x] Contract / negative-path verification
  - Check: a provider that keeps timing out while a prior good snapshot is preserved; a provider skipped by its interval throttle; `providerFailureNotificationsEnabled == false`.
  - Expect: counter still increments off the awaited fetch result and fires at 3 (R3.5); skipped cycles leave the counter unchanged (R3.1); when the dedicated flag is off, no notification is posted (R3.2).


### Verification Receipt (2026-07-07)

- `xcodebuild test ... -only-testing:BirdNionTests/QuotaServicePollingTests` → **6/6 passed, TEST SUCCEEDED**:
  - `testFailureEpisodeFiresOnceAtThresholdAndReArms` — notify at 3rd fetch only, silent at 4th, reset+re-arm on recovery, 2nd episode seq=2 (per-episode id)
  - `testFailureEpisodeRespectsDisabledFlag` — flag off ⇒ counter runs, nothing notified
  - `testFailureCounterRunsDespitePreservedStaleSnapshot` — published status keeps good snapshot while counter advances from awaited result (R3.5)
- Artifact: `QuotaService.swift` — `failureEpisode` map (separate from warnState), `failureNotifyThreshold=3`, dedicated `failureNotificationsEnabled` default true, `evaluateFailureEpisode` hooked in `for await` loop reading awaited `status.error`, notification id `"<id>.failing.<seq>"`.

## Risk Assessment

| Risk | Severity | Mitigation |
|---|---|---|
| Stale-snapshot preservation masks the failure | High | Read `fetchFailed` from the awaited `status.error` only, never `pending`/`statuses` (R3.5); dedicated test |
| "Consecutive cycles" ambiguous under interval throttle | High | Count consecutive fetches; skipped cycles neutral (Finding 1); test with a throttled provider |
| 2nd-episode notification suppressed by OS id dedup | Medium | Per-episode-unique id `"<id>.failing.<seq>"` (Finding 3) |
| Failure alerts off by default via coupled toggle | Medium | Dedicated `providerFailureNotificationsEnabled`, default true (Finding 7) |
| Notification spam on a flapping provider | Medium | `notified` flag fires once per episode; reset only on success |
| Test can't observe `QuotaNotifier` | Low | Inject a notifier closure seam or assert `failureEpisode` transitions |

---

> **Parallel marker**: Append `(P)` to the title if this task can run concurrently with another (usually when serving different requirements).
> **Test note**: If a test coverage sub-task can be deferred post-MVP, mark it with `- [ ]*`.
> **Requirement mapping**: Every sub-task MUST end with `_Requirements: X.X_`. No mapping = invalid task file.
> **Evidence rule**: No `## Evidence` section = invalid task file. Existing specs may use `## Task Test Plan & Verification Evidence` or legacy `## Verification & Evidence`; agents must support all three headings.
