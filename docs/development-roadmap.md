# Development Roadmap

BirdNion (fork/evolution của ai-statusbar) — macOS menu-bar app tracking AI quota.

## ✅ Phase 0 — Bootstrap
- [x] Scout codebase + research CodexBar / MiniMax quota
- [x] Design kiến trúc, 4-point review
- [x] `specs/ai-statusbar/` (spec.json + design.md + tasks/)
- [x] Xcode project setup (macOS app, SwiftUI, NSStatusBar + DropdownPanel)

## ✅ Phase 1 — Quota providers
- [x] `QuotaProvider` protocol + `ProviderStatus` / `QuotaWindow` model
- [x] `MiniMaxProvider` (`/v1/token_plan/remains`)
- [x] `HapoHubProvider` (real endpoint `<HAPO_BASE_URL>`)
- [x] `CodexProvider` (OAuth via `~/.codex/auth.json` + `CodexUsageAPI`)
- [x] `OpenRouterProvider`, `DeepSeekProvider`, `ZaiProvider`
- [x] `ClaudeProvider` (OAuth via Claude Code Keychain + cookie scrape)
- [x] `QuotaService` poll 120s ± 10s + per-provider override
- [x] Progressive publishing — each tab fills in as its fetch returns
- [x] Last-known data preserved while refresh is in flight (no flash to empty)

## ✅ Phase 2 — UI quota
- [x] `MenuBarExtra` shell (NSPopover-style DropdownPanel) + popover
- [x] `QuotaPanel` (CodexBar-style two-tab layout: tabs + provider content)
- [x] `ProviderRow` + `QuotaBar` (progress % with reset countdown)
- [x] Icon menu bar shows bird by default, or rotates through active provider percents when enabled
- [x] `ProvidersPane` settings: per-provider token entry, live animated sidebar reorder via drag-drop
- [x] Search box + active-first sort in settings sidebar
- [x] Per-provider refresh interval picker (Mặc định chung / 30s / 1m / 2m / 5m / 10m / 30m)

## ✅ Phase 3 — Claude Code + Claude provider parity
- [x] `ConfigService` reads/writes `~/.claude/settings.json` with .bak backup
- [x] `ConfigPanel` form global (env, permissions, plugins)
- [x] Mask API key in UI
- [x] **Claude full parity with CodexBar** (`8c0b716 → cbd51f0`):
  - [x] `ClaudeWebExtras` model + `ProviderStatus.webExtras` field
  - [x] Source routing (auto / oauth / web / cli / api) via `ClaudeUsageFetcher`
  - [x] 4 quota windows (5h / Tuần / Opus / Sonnet) + extra_usage credits
  - [x] Plan name (Max / Pro / Team) from Keychain JSON
  - [x] 30-day token cost chart (today / last30 / per-day bars / top model)
  - [x] 4 Settings pickers (Usage source / Cookie / Keychain prompt mode / Admin API)
  - [x] Per-provider menu-bar visibility toggle (UserDefaults-backed)
  - [x] CodexBar parity: full local token scanner + web/CLI fallback
- [x] Local token scanner: `ClaudeCostScanner` (parses `~/.claude/projects/*.jsonl`)

## ✅ Phase 4 — Verify & polish
- [x] `xcodebuild` build clean (Debug + Release)
- [x] 111 unit tests passing
- [x] Per-provider loading state (placeholder + spinner)
- [x] Ad-hoc signed, Gatekeeper auto-strip via Homebrew cask postflight
- [x] Edge cases handled: OAuth 401, no cookies, missing CLI, slow providers
- [x] App icon visible in Finder / Dock

## 🔄 Phase 5 — Distribution (in progress)
- [x] GitHub release pipeline (`Scripts/release.sh`)
- [x] Homebrew tap: `hapo-nghialuu/homebrew-tap`
- [x] Auto-strip quarantine in cask postflight
- [x] v0.1.0, v0.1.1, v0.2.0 published
- [ ] Apple Developer ID + notarization (requires $99/year) — for production-grade install
- [ ] Auto-update via Sparkle (optional, complex)
- [ ] Mac App Store submission (if going public)

## 📋 Backlog (nice-to-have, not required)
- [ ] Sparkle-based auto-update
- [ ] Snapshot / memory quota tracking (Claude Max weekly + Sonnet daily)
- [ ] Daily/weekly notification: "X% of your Claude quota used"
- [ ] Multiple workspace switcher (Codex multi-account already done)
- [ ] `ClaudePlan` rewrite to match CodexBar's exact subscription type logic
- [ ] Migrate to `MenuBarExtra` SwiftUI scene (currently using NSPopover-style)
- [x] Vietnamese/English UI localization

## Recent milestones

| Date | Milestone |
|---|---|
| 2026-06-25 | v0.2.0 release — full Claude parity + Homebrew tap |
| 2026-06-25 | App icon visible in Finder / Dock |
| 2026-06-25 | Gatekeeper auto-strip via cask postflight |
| 2026-06-25 | Claude 30-day cost chart in popover |
| 2026-06-25 | Per-provider refresh interval override |
| 2026-06-24 | Drag-drop reorder in settings sidebar |
| 2026-06-24 | Menu-bar visibility toggle per provider |
| 2026-06-23 | Claude provider parity with CodexBar |
