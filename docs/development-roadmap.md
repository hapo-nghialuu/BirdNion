# Development Roadmap

BirdNion — app theo dõi AI quota/cost, **2 nền tảng chung 1 roadmap**:
- **macOS** (SwiftUI, `BirdNion/`) — bản gốc, đầy đủ tính năng nhất
- **Linux** (Tauri v2 Rust+TS, `linux/`) — dùng chung schema `~/.config/birdnion/settings.json`

**Chính sách nền tảng:** tính năng data-layer/UX mới land trên macOS trước, sync sang Linux trong cùng phase (mục "Linux sync" mỗi phase). Windows sẽ build từ codebase Tauri khi Phase 8.

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

## ✅ Phase 5 — Distribution (zero-budget path)
- [x] GitHub release pipeline (`Scripts/release.sh`)
- [x] Homebrew tap: `hapo-nghialuu/homebrew-tap`
- [x] Auto-strip quarantine in cask postflight
- [x] Releases published through v0.8.6
- [x] Update check via GitHub Releases API (About pane — no Sparkle needed)

> Phân phối chuẩn hiện tại: **brew tap** (ad-hoc signed + postflight strip).
> Đủ tốt cho người dùng kỹ thuật — đúng tệp người dùng của app.

## ✅ Phase 6 — Provider expansion + All tab (shipped v0.4.0 → v0.8.x)
- [x] 15 provider mới port từ CodexBar (tổng ~23: Groq, Copilot, Kilo, Cursor, Gemini, Kiro, Bedrock, Antigravity, cookie-based…)
- [x] Tab "All": gộp Claude CLI + Codex — chart stacked 24h/7/30/90 ngày, heatmap 90 ngày, top models, per-model breakdown theo ngày
- [x] Codex multi-account + Claude source picker
- [x] Claude Code backend switcher (profiles ghi `~/.claude/settings.json`)
- [x] Settings parity CodexBar: manual refresh, refresh-on-open, hotkey toàn cục, sound/overlay warning, Disable Keychain, storage footprint, update check + channel
- [x] **Linux port** (Tauri v2, `linux/`): 23/23 providers, tab All + heatmap, cost scanner Rust (lệch <3%), cookie qua rookie, Copilot Device Flow, Claude Admin dashboard, notification libnotify, i18n vi/en, CI build .deb/.rpm/AppImage + 162 cargo tests

### Trạng thái parity 2 nền tảng (2026-07-07)

| Mảng | macOS | Linux |
|---|---|---|
| 23 providers + tab All + heatmap | ✅ | ✅ |
| Cost scanner Claude/Codex | ✅ | ✅ (Rust, lệch <3%) |
| CI tự động | ❌ | ✅ (GitHub Actions) |
| Settings parity mới (manual refresh, hotkey, update check, storage) | ✅ v0.8.6 | ❌ chưa sync |
| Per-model breakdown theo ngày (All tab) | ✅ | ❌ chưa sync |
| Top-models bar theo % tổng + màu chart mới | ✅ | ❌ chưa sync |
| Claude Code backend switcher | ✅ | ✅ (quick-apply) |
| Distribution | brew tap | .deb/.rpm/AppImage từ CI |

## 🎯 Phase 7 — Reliability first (NOW, 0–1 tháng, $0)
Ưu tiên số 1: app không được hỏng ngầm. Mọi thứ phía dưới vô nghĩa nếu provider chết lặng lẽ.
- [ ] [both] Provider self-test: nút "Kiểm tra" per-provider trong Settings (fetch 1 lần, báo pass/fail + lý do)
- [ ] [both] Phân loại lỗi rõ ràng: cookie hết hạn vs API đổi schema vs mạng — hiển thị hướng khắc phục thay vì error thô
- [ ] [both] Notification khi một provider chuyển từ OK → lỗi liên tục >N lần (đừng để user tự phát hiện)
- [ ] [macOS] CI GitHub Actions: build + full unit tests mỗi push (Linux đã có — chỉ macOS thiếu)
- [ ] [macOS] Update semi-auto: nút "Cập nhật" chạy `brew upgrade --cask birdnion` — không cần Sparkle/Developer ID
- [ ] [Linux] **Sync đợt tính năng v0.8.x**: Settings parity (manual refresh, update check GitHub, storage footprint), per-model breakdown tab All, top-models % tổng + màu chart mới

## 🚀 Phase 8 — AI spend cockpit (NEXT, 1–3 tháng, $0)
Chuyển từ *hiển thị* sang *hành động* trên dữ liệu chi phí:
- [ ] [both] Budget per-provider + tổng: đặt ngân sách tháng, cảnh báo pace "sẽ vượt $X trước ngày Y" (macOS mở rộng `WindowPace`; Linux port cùng logic sang Rust)
- [ ] [both] Digest tuần qua notification: tổng chi, top model, streak (dữ liệu scanner có sẵn)
- [ ] [both] Export CSV/JSON chi phí theo ngày/model (đối soát nội bộ)
- [ ] [macOS] Claude Code switcher từ popover (không cần mở Settings) — tính năng khác biệt nhất so với CodexBar; Linux sync sau khi UX chốt
- [ ] [Windows] Port từ codebase Tauri `linux/`: tray Windows, đường dẫn `%APPDATA%`, cookie qua rookie (đã hỗ trợ Windows), CI msi/exe

## 🌐 Phase 9 — Audience expansion (LATER, 3–6 tháng)
Chọn một hướng khi Phase 7–8 xong:
- [ ] **Team/nội bộ Hapo**: dashboard org (Claude Admin API + Kilo orgs đã có), tổng hợp chi phí nhiều máy (cả macOS lẫn Linux ghi chung schema → sync file là đủ), báo cáo
- [ ] **Public/OSS**: landing page, README tiếng Anh đầy đủ, screenshots cả 2 OS, launch HN/Product Hunt (điểm bán: cross-platform, thứ CodexBar không có)

## 💰 Blocked on budget (làm ngay khi có $99/năm Apple Developer)
- [ ] Developer ID + notarization → cài đặt không cần strip quarantine, mở rộng được tệp người dùng không kỹ thuật
- [ ] Sparkle auto-update (yêu cầu app đã ký)
- [ ] Mac App Store (cũng cần giải bài toán sandbox — cookie/Keychain scraping sẽ bị chặn; cân nhắc kỹ)

## 📋 Backlog (nice-to-have)
- [ ] Snapshot / memory quota tracking (Claude Max weekly + Sonnet daily)
- [ ] `ClaudePlan` rewrite to match CodexBar's exact subscription type logic
- [ ] Migrate to `MenuBarExtra` SwiftUI scene (currently using NSPopover-style)
- [x] Vietnamese/English UI localization

## Nguyên tắc cắt scope
- KHÔNG thêm provider mới trừ khi có nhu cầu thật (mỗi provider = gánh bảo trì dài hạn)
- KHÔNG monetization khi chưa có khối người dùng
- Parity với CodexBar coi như XONG — không đuổi theo tiếp
- Linux không được tụt quá 1 phase so với macOS (mục "Linux sync" là bắt buộc trước khi đóng phase)

## Recent milestones

| Date | Milestone |
|---|---|
| 2026-07-07 | v0.8.6 — Settings parity CodexBar (hotkey, update check, storage footprint…) |
| 2026-07-06 | Per-model breakdown tab All + fix drag-reorder + fix token clobber |
| 2026-07-01 | v0.6.x — provider reordering, FreeModel, color system |
| 2026-06-28 | 15 providers ported từ CodexBar (~23 tổng) |
| 2026-06-25 | v0.2.0 release — full Claude parity + Homebrew tap |
| 2026-06-24 | Drag-drop reorder + menu-bar visibility per provider |
| 2026-06-23 | Claude provider parity with CodexBar |
