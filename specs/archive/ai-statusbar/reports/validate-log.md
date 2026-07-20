# Validation Log — Session 1 — 2026-06-23

**Trigger:** `/hapo:specs --validate ai-statusbar` (BOSS request: "chạy validate đầy đủ")
**Questions asked:** 3
**Pre-validate result:** PASS (`validate-spec-output.cjs`) + GROUNDED (`spec-ground.cjs`)

## Questions & Answers

### 1. **[Architecture] R11.1/F3: ANTHROPIC_API_KEY resolution model**
- Options: Placeholder + BOSS resolve | App tự inject env qua launchd | Bỏ field API key khỏi UI
- **Answer:** Placeholder + BOSS resolve
- **Rationale:** Cleanest — settings.json stays plaintext-safe; BOSS owns the env wrapper script. Documented in design.md §ConfigService.

### 2. **[Performance] Polling interval**
- Options: 60s + 5s | 120s + 10s | 300s + 30s
- **Answer:** 120s + 10s jitter
- **Rationale:** Battery friendlier than 60s; quota doesn't change that fast. Updated R5.1, R10.2, R1-03 step 1+3, R3-02 step 3 to 120s/180s.

### 3. **[UX] First-launch experience when no token configured**
- Options: Error rows + Settings button | Banner CTA inline | Auto-open Settings first run
- **Answer:** Error rows + Settings button
- **Rationale:** Simplest implementation; matches existing R3-5 + R2-04 wiring without new state. Quota panel shows two red rows ("Chưa cấu hình token") and the popover's Settings button is reachable.

## Confirmed Decisions

- `env.ANTHROPIC_API_KEY` value flows: form `SecureField` → `KeychainService.save(account: "anthropic", secret: <value>)`. settings.json stores the literal placeholder `"KEYCHAIN_REF:AIStatusbar/anthropic"`. BOSS resolves via his own shell wrapper before launching Claude Code.
- Quota polling cadence: 120s ± 10s jitter; QuotaService default initializer is `interval: TimeInterval = 120`.
- First-launch UX: error rows + Settings button (no special first-run state).

## Action Items

- [x] Update R5.1 to "120s ± 10s jitter" — done
- [x] Update R10.2 to reference 120s loop — done
- [x] Update R1-03 step 1 + step 3 to 120s + 10s — done
- [x] Update R3-02 step 3 to wait 180s (one cycle + jitter) — done
- [x] Update design.md Mermaid sequenceDiagram "every 120s ±10s" — done

## Impact on Tasks

- **R1-03:** default `interval = 120`, jitter `±10` with floor 60s.
- **R3-02:** manual smoke wait extended from 90s to 180s; completion criterion updated.

## Validator

- `node .claude/scripts/validate-spec-output.cjs specs/ai-statusbar` → PASS
- `node .claude/scripts/spec-ground.cjs specs/ai-statusbar --root /Users/nghialuutrung/Desktop/statusbar` → GROUNDED
