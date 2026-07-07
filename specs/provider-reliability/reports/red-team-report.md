# Red Team Report — provider-reliability

**Date:** 2026-07-07
**Mode:** Red Team → Validate (auto-decision: 6 task files ⇒ 4 personas)
**Reviewers:** Security Adversary, Failure Mode Analyst, Assumption Destroyer, Scope & Complexity Critic
**Spec:** specs/provider-reliability/

Reviewer instruction applied: hostile, findings-only, cite exact task/section or verbatim
quote (Evidence Filter §5.5), severity Critical/High/Medium, cap 15.

---

## Findings (post Evidence Filter, sorted by severity)

## Finding 1: "Consecutive cycles" is ambiguous under per-provider interval throttling
- **Severity:** High
- **Location:** task-R3-01 §Steps step 2/3; design.md §2 "Classification episode / notification invariant (R3)"; requirements.md R3.1
- **Flaw:** `QuotaService.refresh()` only fetches providers in the `due` set — a provider with a per-provider refresh override (e.g. 30m) is skipped on most cycles. R3 counts "consecutive refresh cycles" but the design/tasks never define whether a *skipped* (not-fetched) cycle counts, resets, or is ignored. As written, `evaluateFailureEpisode` is only called for fetched providers, so a slow-interval provider needs 3 of *its own* fetches (could be 90 min apart), while the requirement text implies loop cycles.
- **Failure scenario:** A provider set to "refresh every 30m" that breaks fires the notification only after ~90 min, not after 3 loop cycles (~6 min). A reviewer reading R3.1 would expect the faster behavior; the implementer using the step text gets the slower one — silent semantic mismatch.
- **Evidence:** design.md: "Threshold N = 3 consecutive failing cycles"; task-R3-01 step 2 hooks inside `for await (id, status, elapsed) in group` which only iterates `due`. requirements.md R3.1 says "each subsequent failing refresh cycle" without defining skipped cycles.
- **Suggested fix:** Define the counter explicitly as "consecutive failing *fetches* of that provider" (skipped cycles neither increment nor reset). State it in design.md invariant + R3.1 + task-R3-01 so the semantics are unambiguous and test-pinned.
- **Disposition:** Accept
- **Rationale:** Real ambiguity in the artifact that changes observable timing; cheap to pin as "per-fetch, skips are neutral". No scope change.

## Finding 2: Self-test resolves the live provider from `quota.providers`, but a disabled provider may not be there
- **Severity:** High
- **Location:** task-R2-02 §Steps step 3 ("`quota.providers.first { $0.id == id }`"); §Risk Assessment "Live provider instance not found"
- **Flaw:** `ProvidersPane` renders a row for EVERY provider from `BirdNionConfigStore.allProviders()` (enabled + disabled), and the detail pane + self-test button are shown for the selected row regardless of enabled state. But `quota.providers` is the *live enabled* list (`setProviders`/`setEnabled(false)` calls `remove(id:)`). So self-testing a currently-disabled provider resolves `nil` and the button silently no-ops — the task's own guard `guard let p else { return }` leaves the button stuck in `.running` forever (state set to `.running` before the guard returns).
- **Failure scenario:** User selects a disabled provider to check whether their token works before enabling it, clicks Self-test → spinner appears and never resolves (state `.running`, guard returned without resetting), button stays disabled. Looks like a hang.
- **Evidence:** task-R2-02 step 3: "set `selfTestState[id] = .running`; `Task { let p = quota.providers.first { $0.id == id }; guard let p else { return }`" — the `.running` is set before the guard, and the guard path never resets state. ProvidersPane scout: `rows = BirdNionConfigStore.allProviders()` (enabled+disabled); `QuotaService.setEnabled(false)` → `remove(id:)`.
- **Suggested fix:** In task-R2-02, either (a) build a fresh provider instance via the existing factory `ServicesContainer.makeProviders`/`makeProvider` for the row id so self-test works on disabled providers too, OR (b) if not found, set `selfTestState[id] = .fail(.unknown, <"provider disabled — enable to test">)` / a dedicated message and never leave `.running`. Add the "reset state on the not-found path" rule to Completion Criteria + negative-path Evidence.
- **Disposition:** Accept
- **Rationale:** Concrete stuck-spinner UX bug reachable from the described flow; the current guard is a real hole. Prefer option (b) (KISS) — building a throwaway provider is more surface; but leave the choice to the implementer while forbidding the stuck-`.running` state.

## Finding 3: Notification identifier `"<id>.failing"` collides with UNUserNotificationCenter dedup + never removed on recovery
- **Severity:** Medium
- **Location:** task-R3-01 §Steps step 3 (`QuotaNotifier.post(id: "\(id).failing", ...)`); design.md §4 R3
- **Flaw:** `QuotaNotifier.post` uses the id as the `UNNotificationRequest` identifier. If a new failure episode occurs after recovery, the same identifier `"<id>.failing"` is reused. UNUserNotificationCenter *replaces* a delivered notification with the same identifier silently if it is still in Notification Center — so a second genuine episode may not re-alert the user (no banner) because the OS treats it as an update of the still-present prior notification. The fire-once logic resets in-app, but the OS-level dedup is not addressed.
- **Failure scenario:** Provider fails (notified), recovers, fails again a day later while the first notification still sits in Notification Center → the OS updates the existing entry in place; the user gets no new banner/sound and never notices the second outage.
- **Evidence:** task-R3-01 step 3 uses a static id `"\(id).failing"`; QuotaNotifier scout: `UNNotificationRequest(identifier: id, ...)` — identifier-based. The quota-warning path uses per-threshold ids `"\(status.id).\(windowKey).\(t)"` which are naturally unique per crossing; the failing path is not.
- **Suggested fix:** Make the identifier unique per episode (e.g. append an episode counter or a timestamp: `"\(id).failing.\(episodeSeq)"`), documented in task-R3-01 step 3 + design.md R3. Keep fire-once in-app; uniqueness only affects OS delivery.
- **Disposition:** Accept
- **Rationale:** Real, provider-specific delivery defect grounded in the actual notifier implementation; one-line fix, no scope change.

## Finding 4: R3 hook ordering vs the stale-preservation branch is asserted but not sequenced in the step text
- **Severity:** Medium
- **Location:** task-R3-01 §Steps step 2; design.md §3.3 "Where R3 hooks in"
- **Flaw:** The design says compute `fetchFailed` "BEFORE the stale-preservation branch overwrites `pending[id]`". But `fetchFailed` is derived from `status.error`, and `status` (the freshly awaited value) is never mutated by the preservation branch — only `pending[id]` is. So the "before/after" framing is misleading: reading `status.error` is order-independent. The real risk (masking) is only if someone reads `pending[id].error` instead. The step text should assert "read `status.error` (the awaited result), never `pending[id]`/`statuses`" rather than an ordering that doesn't matter.
- **Failure scenario:** An implementer follows "compute before the branch", places the call correctly, but a later refactor moves it "after" the branch and still reads `status.error` — the ordering rule gives false confidence while the actual invariant (source = awaited `status`, not `pending`/`statuses`) is what protects R3.5.
- **Evidence:** design.md §3.3: "evaluated BEFORE the stale-preservation branch overwrites `pending[id]`"; QuotaService scout: the branch mutates `pending[id]`, not `status`.
- **Suggested fix:** Reword R3.5 wiring in design.md + task-R3-01 to: "derive `fetchFailed` from the awaited `status.error` of this fetch; MUST NOT read `pending[id]`, `statuses`, or `displayStatuses`". Drop the load-bearing "before/after" ordering claim (keep placement as a suggestion, not the invariant).
- **Disposition:** Accept
- **Rationale:** Sharpens the true invariant and removes a misleading proxy rule; directly strengthens the High-severity masking mitigation.

## Finding 5: HTTP-code extraction can misfire on codes embedded in tokens/URLs/counts
- **Severity:** Medium
- **Location:** task-R0-01 §Steps step 2 ("Extract HTTP codes by scanning for 3-digit 4xx/5xx tokens"); design.md §4 R0/R1 "HTTP code extraction"
- **Flaw:** Raw errors include arbitrary text — account ids, URLs, token counts, timestamps. A bare "scan for a 3-digit 4xx/5xx token" can match `403` inside `"...id=140399"` or `"5000 tokens"` (→ `500`), classifying a benign schema/network message as token/schema wrongly. The scout confirms strings like `"codex-cli 0.140.0"`, `"5000 tokens"`, `"account_id"` flow through the same `error` channel in some providers.
- **Failure scenario:** A provider returns `"Response thiếu trường (id 5031)"` → naive 3-digit scan sees `503` → classified `apiSchemaChanged` (coincidentally right) OR `"timeout sau 429ms"` → sees `429` → classified `rateLimited` instead of network/timeout, giving a wrong remediation hint ("wait and retry" vs "check connection").
- **Evidence:** task-R0-01 step 2: "Extract HTTP codes by scanning for 3-digit 4xx/5xx tokens"; scout raw strings `"Claude: timeout sau \(Int(Self.fetchTimeout))s"`, numeric-bearing messages. The precedence already puts network before rate, but `"timeout sau 429ms"` would still hit the naive scan if scan runs before the network marker check — depends on implementation order.
- **Suggested fix:** In task-R0-01, require HTTP-code matching to be anchored to an HTTP context (e.g. match `"http 401"`, `"http\(space)4xx"`, `"(401)"`, `"status 401"`, or `"401"` only when adjacent to non-digits and not preceded by a decimal), OR simply rely on the ordered marker checks first (cookie/rate-marker/timeout-marker/`http NNN`) and treat bare digits conservatively. Add a negative test: `"timeout sau 429ms"` → `networkUnreachableOrTimeout`, `"5000 tokens used"` → not `apiSchemaChanged` from the `500`.
- **Disposition:** Accept
- **Rationale:** Concrete misclassification path grounded in real raw strings; fix is a tightened matching rule + two negative tests. No scope change.

## Finding 6: `unknown` still shows a truncated generic hint in the sidebar — raw error becomes unreachable there for the one case users most need it
- **Severity:** Medium
- **Location:** task-R2-01 §Steps step 2; requirements.md R1.3, R2.3
- **Flaw:** For `.unknown`, the sidebar shows "Lỗi không xác định — xem chi tiết" and the raw string is only in the `.help()` tooltip. On macOS, tooltips require a hover and are easy to miss; for the *unknown* case (the one where the classifier gave up) the user is told "see detail" but the sidebar itself hides the only diagnostic. R2.3 keeps raw "reachable" via tooltip, which technically satisfies the requirement, but the UX for `.unknown` specifically routes the user to "detail" — the detail grid must then actually show something more than the same generic hint.
- **Failure scenario:** Unknown error → sidebar + detail grid both show "Lỗi không xác định — xem chi tiết", tooltip shows raw. User reads "xem chi tiết", looks at the detail grid, sees the identical generic line, and has nowhere obvious to "see detail" — a dead-end loop.
- **Evidence:** requirements.md R1.3 "generic actionable message (e.g. 'Lỗi không xác định — xem chi tiết')"; task-R2-01 step 3 grid also uses `classifiedMessage(for: err)` (generic for unknown) + `.help(err)`.
- **Suggested fix:** For `.unknown`, the DETAIL grid should render the raw error inline (not just tooltip), since "xem chi tiết" points there. Add to task-R2-01: when `kind == .unknown`, the detail grid error row shows the raw string as the value (tooltip optional); the sidebar keeps the generic + tooltip. Update R1.3/R2.3 note accordingly.
- **Disposition:** Accept
- **Rationale:** Closes a real dead-end for the unknown case; small, in-scope refinement that makes R2.3's "reachable" genuinely useful.

## Finding 7: Master toggle `QuotaWarnConfig.enabled` defaults OFF — failure alerts silently disabled out of the box
- **Severity:** Medium
- **Location:** task-R3-01 §Steps step 3 ("Gate on `QuotaWarnConfig.enabled`"); design.md §4 R3
- **Flaw:** The scout shows `QuotaWarnConfig.enabled` defaults to `false` (`UserDefaults...object(forKey:) as? Bool ?? false`). Gating the failure-transition notification on this flag (reusing the quota-threshold master toggle) means the entire Phase-7 "don't let providers die silently" feature is OFF by default and coupled to a *different* feature's toggle. A user who never enabled quota-warning notifications gets zero failure alerts — defeating the roadmap goal.
- **Failure scenario:** Fresh install, user never turns on quota warnings (default off) → provider dies → no notification ever. The headline reliability feature is inert for the default user.
- **Evidence:** QuotaService scout: `static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false }`; task-R3-01 step 3 gates on `QuotaWarnConfig.enabled`.
- **Suggested fix:** Decide the gate explicitly in design.md §2 as a canonical decision: EITHER (a) gate failure alerts on their own default-ON flag (small new UserDefaults key, e.g. `providerFailureNotificationsEnabled` default true) — respects YAGNI as a single bool, not a new settings system; OR (b) keep coupling to `QuotaWarnConfig.enabled` and explicitly document that failure alerts require the master notifications toggle. Record the chosen policy in design.md + R3.2 + task-R3-01 so it isn't an accidental default. Recommend (a) so the reliability feature works out of the box.
- **Disposition:** Accept
- **Rationale:** Grounded in the real default; directly undermines the feature's purpose. Fix is a one-line policy decision + one bool if option (a). This is a user-facing behavior decision — surfaced to the Validation interview as the primary question.

## Finding 8: Over-specified marker lists risk drift and false confidence
- **Severity:** Medium
- **Location:** design.md §4 R0/R1 (marker sets); task-R0-01 §Steps step 2
- **Flaw:** The design enumerates concrete marker substrings (`"__host-auth"`, `"sessionkey"`, `"đăng nhập"`, etc.). Some are risky: `"đăng nhập"` (sign in) appears in token-config hints AND cookie hints; `"connection"` is broad; `"expired"` is put under token but also applies to cookies. Baking an over-precise list into the spec invites either drift from the code or misclassification, and `"đăng nhập"` under the token bucket contradicts the cookie-first intent for cookie-auth providers whose messages say "đăng nhập ... trình duyệt".
- **Failure scenario:** Cookie-provider message `"Không tìm thấy cookie đăng nhập Command Code"` contains BOTH `"cookie"` (cookie bucket, checked first — correct) and `"đăng nhập"` (listed under token). Fine here due to precedence, but `"Access token hết hạn — đăng nhập lại"` (a token message with "đăng nhập") is correctly token. The ambiguity of `"đăng nhập"` as a marker is a latent misclassifier if precedence ever changes.
- **Evidence:** design.md §4: token markers include `"đăng nhập"`; cookie markers include `"cookie"`, `"cần auth"`. Scout raw: `"Không tìm thấy cookie đăng nhập Command Code"`, `"Access token hết hạn (401)"`.
- **Suggested fix:** In design.md, mark the marker lists as *illustrative, non-exhaustive* (they already say "illustrative" for one set — make it explicit for all) and remove genuinely ambiguous single-word markers like `"đăng nhập"`/`"connection"` from the authoritative list, relying on the more specific tokens (`"token"`, `"api key"`, `"401"`, `"cookie"`). Keep the classifier centralized so additions are one-line. Pin the ambiguous cases with tests instead of markers.
- **Disposition:** Accept (partial)
- **Rationale:** Reduces latent misclassification and drift; keep it light — just annotate "illustrative/non-exhaustive" and drop the two ambiguous markers. Not a redesign.

## Finding 9: Self-test bypasses per-provider "cookie source: Off" / prompt-mode policies
- **Severity:** Medium
- **Location:** task-R2-02 §Steps step 3 (`provider.fetch()`)
- **Flaw:** Some providers honor user settings read at fetch time (e.g. Claude `claudeOAuthKeychainPromptMode = .never`, cookie source `= off`). Self-test calls the same `provider.fetch()`, so it inherits those policies — which is correct — but the task never states that self-test result reflects *current settings*, so a user who set "cookie off" and self-tests will see a fail and may think the provider is broken rather than intentionally disabled by their own setting.
- **Failure scenario:** User sets Claude cookie source = Off, self-tests → fail (no cookie) → classified `cookieExpiredOrMissing` → hint "đăng nhập lại trình duyệt" → user re-logs in browser pointlessly because the real cause is their own "Off" setting.
- **Evidence:** ProvidersPane scout: cookie source pickers (`claudeCookieSource`, `<id>CookieSource`), `claudeOAuthKeychainPromptMode`; task-R2-02 step 3 calls `provider.fetch()` which reads these at fetch time.
- **Suggested fix:** Add a Constraint/note to task-R2-02: self-test reflects current provider settings (by design, since it uses the real fetch path); optionally the fail message may hint "check this provider's source settings". Minimal: document the behavior so it's intentional, not a surprise. No code beyond wording.
- **Disposition:** Reject
- **Rationale:** Using the real fetch path (and thus honoring current settings) is the explicitly approved design and the whole point of R2.5 ("no new network layer"). Adding source-aware messaging is scope creep (YAGNI). The behavior is correct; documenting every possible user-misconfiguration is out of scope. Noting for the record only.

## Finding 10: No guard that self-test `Task` is cancelled / ignored when the provider selection changes mid-fetch
- **Severity:** Medium
- **Location:** task-R2-02 §Steps step 3 ("Reset to `.idle` when `selectedID` changes")
- **Flaw:** The task says reset `selfTestState[id]` on `selectedID` change, but the in-flight `Task` for the previous provider still completes and writes `selfTestState[oldId] = .pass/.fail`. Since state is keyed by id, that's mostly fine — but if the user switches away and back quickly, they may see a stale result from a prior run, or two concurrent self-tests race on the same id (double-click is guarded by `.running`, but switch-away-and-back is not).
- **Failure scenario:** User self-tests provider A (slow, 12s Claude timeout), switches to B and back to A within the window; A's button shows `.idle` (reset) but the original Task then lands `.fail`, and if the user clicked again the two tasks both write — last-writer-wins, possibly showing the older result.
- **Evidence:** task-R2-02 step 3: keyed `selfTestState`, reset on `selectedID` change, guard only on `.running` for the *current* view; no task handle/cancellation.
- **Suggested fix:** Minor: task-R2-02 note that the button is disabled while `.running` for that id, and the reset-on-switch keeps the map keyed per id so a late write only affects that id's state (acceptable). Optionally hold the `Task` handle to cancel on switch. Keep it light — document that last-writer-wins per id is acceptable.
- **Disposition:** Reject
- **Rationale:** Low-impact edge; per-id keying already prevents cross-provider corruption, and `.running` guards double-fire. Adding Task cancellation is gold-plating for a manual, single-shot probe (YAGNI). Documented as acceptable in the existing Risk Assessment ("Stale result shown after switching providers" is already listed with the reset mitigation).

---

## Red Team Review — 2026-07-07

**Findings:** 10 surfaced (10 survived Evidence Filter; 0 auto-rejected) → **8 accepted, 2 rejected**
**Severity breakdown:** 0 Critical, 2 High, 8 Medium

| # | Finding | Severity | Disposition | Applied To |
|---|---------|----------|-------------|------------|
| 1 | "Consecutive cycles" ambiguous under interval throttle | High | Accept | design.md §2, requirements.md R3.1, task-R3-01 |
| 2 | Self-test on disabled provider → stuck `.running` | High | Accept | task-R2-02 (Steps, Completion, Evidence, Risk) |
| 3 | Notification identifier dedup on 2nd episode | Medium | Accept | design.md §4 R3, task-R3-01 |
| 4 | R3.5 invariant should target awaited `status`, not ordering | Medium | Accept | design.md §3.3/§2, task-R3-01 |
| 5 | HTTP-code scan misfires on digits in text | Medium | Accept | task-R0-01 (Steps, Evidence), design.md §4 |
| 6 | `.unknown` sidebar dead-ends "see detail" | Medium | Accept | task-R2-01 (Steps, Completion), requirements.md R1.3 |
| 7 | Failure alerts OFF by default (coupled toggle) | Medium | Accept | design.md §2, requirements.md R3.2, task-R3-01 |
| 8 | Over-specified/ambiguous markers | Medium | Accept(partial) | design.md §4 |
| 9 | Self-test bypasses source settings | Medium | Reject | — (correct by design, YAGNI) |
| 10 | Self-test Task not cancelled on switch | Medium | Reject | — (already mitigated, YAGNI) |

**Provider-drift check:** none — Claude/Anthropic appears only as one legitimately-tracked provider; no scope switch, no stale `Haiku`/`Claude API` strings.
