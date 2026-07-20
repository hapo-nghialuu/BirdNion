# Validation Log — Session 1 — 2026-07-07

**Trigger:** `/hapo:specs provider-reliability --validate` (auto-decision: 6 task files ⇒
Red Team → Validate). Red Team ran first and produced 8 accepted findings; this session
confirms the resulting spec is internally consistent and records the one user-owned
behavior decision surfaced by the review.

**Questions asked:** 1 (behavior decision) + reconciliation audit. The coordinator relayed
the run without a live user; user-owned decisions were resolved with an explicit recommended
default and documented here for user override.

## Questions & Answers

1. **[Scope / Assumptions]** Failure-transition notifications (R3) — enablement default?
   - Options:
     - A. Reuse the existing quota-warning master toggle `QuotaWarnConfig.enabled` (default OFF)
     - B. Dedicated `providerFailureNotificationsEnabled` flag, default ON (Recommended)
     - C. Always on, no toggle
   - **Answer:** B (Recommended) — applied as the canonical decision.
   - **Rationale:** The Phase-7 goal is "don't let providers die silently". Option A would
     leave the headline reliability feature inert for the default user (the quota-warning
     toggle defaults false and is a separate feature). Option C removes user control. B is a
     single bool (YAGNI-compliant) that makes the feature work out of the box while staying
     controllable. This was Red Team Finding 7.

## Confirmed Decisions

- **Failure-notification enablement:** dedicated `providerFailureNotificationsEnabled`
  UserDefaults flag, default true, gating only the R3 failure alert. Recorded in
  design.md §2 + §4 R3, requirements.md R3.2, task-R3-01.
- **Counter semantics:** "consecutive failing *fetches*" (skipped-throttled cycles are
  neutral) — Red Team Finding 1.
- **R3.5 source rule:** decision derived from the awaited `status.error` only, never
  `pending`/`statuses`/`displayStatuses` — Red Team Finding 4.
- **Notification id:** per-episode-unique `"<id>.failing.<episodeSeq>"` — Red Team Finding 3.
- **Unknown-kind detail:** detail grid shows raw error inline for `unknown` — Red Team Finding 6.
- **Self-test on disabled provider:** never enters/remains `.running`; shows
  "enable to test" — Red Team Finding 2 (added R2.9).
- **HTTP-code matching:** only in HTTP context; digits-in-text not misread — Red Team Finding 5.
- **Markers:** illustrative/non-exhaustive; ambiguous single-word markers excluded — Finding 8.

## Action Items

- [x] Propagate all 8 accepted findings into requirements.md / design.md / tasks/*.md.
- [x] Add R2.9 (self-test disabled-provider path) + map it to task-R2-02.
- [x] Add `provider.selfTest.disabled` localization key to R1-01 + design.
- [x] Update traceability tables (requirements.md summary, design.md matrix).
- [x] Re-run both validators after fixes.

## Impact on Tasks

- **task-R0-01:** HTTP-code context matching + digit-in-text negative tests (Finding 5).
- **task-R1-01:** `provider.selfTest.disabled` key added (Finding 2).
- **task-R2-01:** unknown-kind detail shows raw inline; now also maps R1.3 (Finding 6).
- **task-R2-02:** disabled-provider safe path; new R2.9 mapped (Finding 2).
- **task-R3-01:** per-fetch counter, awaited-status source, per-episode id, dedicated
  default-on flag (Findings 1, 3, 4, 7).
- **task-R4-01:** unchanged scope; still the reachability + full-suite gate.

## Rejected (from Red Team)

- **Finding 9** (self-test bypasses source settings): Reject — using the real fetch path and
  honoring current settings is the approved design (R2.5); source-aware messaging is scope
  creep (YAGNI).
- **Finding 10** (self-test Task not cancelled on switch): Reject — per-id keying + `.running`
  guard already prevent corruption; Task cancellation is gold-plating for a manual one-shot probe.

## Reconciliation Audit

- Re-read spec.json, requirements.md, design.md, all 6 task files: every accepted finding is
  reflected in an implementation-facing section (not only Risk Assessment).
- No provider drift; no delete/privacy policy mixing (N/A).
- Task naming convention intact; no forbidden artifacts.
- Deterministic validators re-run — see spec-maker final report / spec.json.
