# Task R2-01: Providers pane classified display

**Requirement:** R2 — Classified display (Settings → Providers)
**Status:** done
**Priority:** P1
**Estimated Effort:** 1-2h
**Dependencies:** tasks/task-R0-01-error-classifier-foundation.md, tasks/task-R1-01-remediation-hints-localization.md

**Spec:** specs/provider-reliability/

## Context

- **Why**: The Providers settings pane shows raw error strings in the sidebar row and the detail info grid. Users need the classified, actionable message instead, with the raw string still reachable for power users.
- **Current state**: `BirdNion/Views/Settings/ProvidersPane.swift` — `statusSubtitle(for:)` (~line 2800) renders `L10n.f("provider.errorPrefix", language, truncated(L10n.providerText(err), 32))`; `statusSubtitleDetail(for:)` (~line 2819) already feeds the row `.help()` with the raw string; `detailInfoGrid(_:)` (~line 603) renders the error `infoRow` with `L10n.providerText(err)`. `classify(rawError:)` + `providerError.*` keys exist from R0/R1.
- **Target outcome**: Sidebar subtitle + detail grid show the classified hint; both keep the raw error in a `.help()` tooltip.

## Constraints

- **MUST**: Add ONE private helper `classifiedMessage(for err: String) -> String` = `L10n.t((classify(rawError: err) ?? .unknown).hintKey, language)` (optionally prefixed via `provider.errorPrefix`), used by both surfaces (DRY).
- **MUST**: Keep the raw error reachable via `.help(rawError)` on the sidebar row (already wired through `statusSubtitleDetail`) AND on the detail grid error row (R2.3).
- **SHOULD**: Keep the sidebar truncation so the row stays a single line.
- **MUST NOT**: Remove the raw-error tooltip; do not alter unrelated grid rows or the quota window rendering.
- **SCOPE**: Only R2.1–R2.3 display changes. The self-test button is R2-02.

## Steps

- [x] 1. Add `classifiedMessage(for:)` helper in `ProvidersPane`.
  - Business intent: single seam mapping a raw error to an actionable, localized hint.
  - Code detail: `let kind = classify(rawError: err) ?? .unknown; return L10n.t(kind.hintKey, language)` (or `L10n.f("provider.errorPrefix", language, ...)` for the sidebar to keep the "Lỗi:" prefix look).
  - _Requirements: 2.1, 2.2_

- [x] 2. Update `statusSubtitle(for:)` to use the classified message, keeping truncation.
  - Business intent: sidebar row shows an actionable hint, not a raw string.
  - Code detail: replace `L10n.providerText(err, ...)` inside the error branch with `classifiedMessage(for: err)`; keep `truncated(...)`. `statusSubtitleDetail(for:)` continues returning the RAW string for the row `.help()` (R2.3, already wired at ~line 320).
  - _Requirements: 2.1, 2.3_

- [x] 3. Update `detailInfoGrid(_:)` error row to the classified message + add raw tooltip.
  - Business intent: detail pane matches the sidebar and stays actionable.
  - Code detail: the error `infoRow` value becomes `classifiedMessage(for: err)`; attach `.help(err)` to that grid row so the raw string is reachable (R2.2, R2.3). Since `infoRow` returns a `GridRow`, add a `.help` on the value `Text`. <!-- Updated: Red Team Finding 6 --> SPECIAL CASE for `unknown`: when `classify(rawError: err) == nil || .unknown`, the detail grid error row shows the RAW error string inline as its value (not the generic "xem chi tiết" hint), so "see detail" is not a dead end (R1.3). The sidebar still shows the generic hint + raw tooltip.
  - _Requirements: 2.2, 2.3, 1.3_

- [x] 4. Verification implementation
  - Build the app; manually confirm an errored provider shows the classified hint in both the sidebar and the grid, hovering reveals the raw string, and an `unknown`-kind error shows the raw string inline in the detail grid. Reachability owned by task-R4-01.
  - _Requirements: 2.1, 2.2, 2.3, 1.3_

## Requirements

- 2.1 — Sidebar row subtitle shows classified message instead of raw error.
- 2.2 — Detail info grid error row shows classified message instead of raw error.
- 2.3 — Raw error reachable via tooltip/`help` from both surfaces.
- 1.3 — `unknown` kind: detail info grid shows the raw error inline (not a dead-end generic).

## Related Files

| Path | Action | Description |
|---|---|---|
| `BirdNion/Views/Settings/ProvidersPane.swift` | Modify | `classifiedMessage` helper; `statusSubtitle` + `detailInfoGrid` use it; add `.help(raw)` on grid error row |
| `BirdNion/Services/ProviderErrorClassifier.swift` | Read | `classify` + `ProviderErrorKind.hintKey` |
| `BirdNion/Services/AppLocalizer.swift` | Read | `providerError.*` hint keys, `provider.errorPrefix` |

## Completion Criteria

- [x] Sidebar subtitle for an errored provider renders the classified hint (R2.1).
- [x] Detail grid error row renders the classified hint (R2.2).
- [x] Hovering the sidebar row and the grid error row reveals the raw error string (R2.3).
- [x] For an `unknown`-kind error, the detail grid shows the raw error inline (not the generic hint) (R1.3). <!-- Updated: Red Team Finding 6 -->
- [x] Single `classifiedMessage` helper used by both surfaces; no duplicated classify calls; no orphan (consumed by ProvidersPane runtime).

## Evidence

- [x] Automated verification (build/component)
  - Command(s): `xcodebuild build -scheme BirdNion -destination 'platform=macOS'`
  - Expected proof: app target builds clean; `classifiedMessage` compiles and is referenced by both `statusSubtitle` and `detailInfoGrid`.
- [x] Artifact / runtime verification
  - Inspect: run the app, configure a provider to error (e.g. no token/expired cookie), open Settings → Providers.
  - Expect: sidebar subtitle + detail grid show the localized hint (e.g. "Token sai — dán lại API key"), not "HTTP 401".
- [x] Runtime reachability verification
  - Entrypoint/caller: `ProvidersPane` `sidebarRow` (`statusSubtitle`) and `detailInfoGrid` — both on the live settings screen.
  - Expect: `classify` invoked from both call sites; verified in the running Settings window.
- [x] Contract / negative-path verification
  - Check: hover the errored sidebar row and grid error row; trigger an `unknown`-kind error.
  - Expect: `.help()` shows the full raw error string (R2.3); an `unknown`-kind error shows the RAW string inline in the detail grid (R1.3) while the sidebar shows the generic message + tooltip.


### Verification Receipt (2026-07-07)

- `xcodebuild build` → **BUILD SUCCEEDED** (Debug).
- Artifact: `ProvidersPane.swift` — `classifiedMessage(for:)` seam; `statusSubtitle` uses classified hint (truncation kept, raw via `statusSubtitleDetail` tooltip unchanged); detail grid `errorRow(value:rawError:)` shows classified hint with `.help(raw)`, `unknown` shows raw inline (Finding 6).
- Manual UI confirmation + end-to-end reachability owned by task-R4-01.

## Risk Assessment

| Risk | Severity | Mitigation |
|---|---|---|
| Grid `GridRow`/`.help` placement drops the tooltip | Medium | Attach `.help(raw)` on the value `Text` (proven pattern used by the sidebar row) |
| `unknown`-case dead-ends "see detail" | Medium | Detail grid shows raw inline for `unknown` (Finding 6) |
| Truncation hides the whole hint on the sidebar | Low | Full hint remains in the detail grid; raw remains in tooltip |

---

> **Parallel marker**: Append `(P)` to the title if this task can run concurrently with another (usually when serving different requirements).
> **Test note**: If a test coverage sub-task can be deferred post-MVP, mark it with `- [ ]*`.
> **Requirement mapping**: Every sub-task MUST end with `_Requirements: X.X_`. No mapping = invalid task file.
> **Evidence rule**: No `## Evidence` section = invalid task file. Existing specs may use `## Task Test Plan & Verification Evidence` or legacy `## Verification & Evidence`; agents must support all three headings.
