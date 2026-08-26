# Development Roadmap

BirdNion — app theo dõi AI quota/cost, **2 nền tảng chung 1 roadmap**:
- **macOS** (SwiftUI, `BirdNion/`) — bản gốc, đầy đủ tính năng nhất
- **Linux** (Tauri v2 Rust+TS, `linux/`) — dùng chung schema `~/.config/birdnion/settings.json`
- **Windows 10/11 x64/ARM64** — target đang phát triển từ codebase Tauri; chưa phải nền tảng được support hoặc phát hành

**Chính sách nền tảng:** tính năng data-layer/UX mới land trên macOS trước, sync sang Linux trong cùng phase (mục "Linux sync" mỗi phase). Windows phải có evidence độc lập cho bốn lane Windows 10 x64, Windows 10 ARM64, Windows 11 x64 và Windows 11 ARM64; compile hoặc receipt của một lane không thay lane khác.

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
- [x] Codex multi-account (popover view-switching + CLI account switcher) + Claude source picker
- [x] Claude Code backend switcher (profiles ghi `~/.claude/settings.json`)
- [x] Settings parity CodexBar: manual refresh, refresh-on-open, hotkey toàn cục, sound/overlay warning, Disable Keychain, storage footprint, update check + channel
- [x] **Linux port** (Tauri v2, `linux/`): 23/23 providers, tab All + heatmap, cost scanner Rust (lệch <3%), cookie qua rookie, Copilot Device Flow, Claude Admin dashboard, notification libnotify, i18n vi/en, CI build .deb/.rpm/AppImage + 162 cargo tests

### Trạng thái parity 2 nền tảng (2026-07-07)

| Mảng | macOS | Linux |
|---|---|---|
| 23 providers + tab All + heatmap | ✅ | ✅ |
| Cost scanner Claude/Codex | ✅ | ✅ (Rust, lệch <3%) |
| CI tự động | ❌ | ✅ (GitHub Actions) |
| Settings parity (manual refresh, update check, storage) | ✅ v0.8.6 | ✅ (hotkey macOS-only) |
| Per-model breakdown theo ngày (All tab) | ✅ | ✅ |
| Top-models bar theo % tổng + màu chart mới | ✅ | ✅ |
| Reliability (classifier, self-test, failure notify) | ✅ | ✅ |
| Claude Code backend switcher | ✅ | ✅ (quick-apply) |
| Distribution | brew tap | .deb/.rpm/AppImage từ CI |

## 🎯 Phase 7 — Reliability first (NOW, 0–1 tháng, $0)
Ưu tiên số 1: app không được hỏng ngầm. Mọi thứ phía dưới vô nghĩa nếu provider chết lặng lẽ.
- [x] [macOS] Provider self-test: nút "Kiểm tra" per-provider trong Settings (fetch 1 lần, báo pass/fail + lý do) — `specs/provider-reliability`, 2026-07-07
- [x] [macOS] Phân loại lỗi rõ ràng: cookie hết hạn vs API đổi schema vs mạng — hiển thị hướng khắc phục thay vì error thô (`ProviderErrorClassifier`, raw giữ ở tooltip)
- [x] [macOS] Notification khi một provider chuyển từ OK → lỗi liên tục ≥3 lần fetch (1 lần/đợt, re-arm khi hồi, flag riêng default ON)
- [x] [Linux] Sync 3 mục reliability trên (classifier Rust 19 tests + self-test + libnotify episode) — 2026-07-07
- [x] [macOS] Update semi-auto: nút "Cập nhật ngay" chạy `brew upgrade --cask birdnion` qua Terminal — không cần Sparkle/Developer ID
- [x] [Linux] **Sync đợt tính năng v0.8.x**: manual refresh + Refresh-now, refresh-on-open, update check GitHub (semver Rust), storage footprint, màu chart Codex xanh, top-models chia theo tổng; bump version Linux → 0.8.6

**Phase 7 hoàn tất (2026-07-07).** Next: Phase 8.

> CI GitHub Actions cho macOS: **bỏ khỏi Phase 7** (quyết định 2026-07-07). Verify bằng `xcodebuild test` local khi cần.
> macOS ↔ Linux đạt **full feature parity** (2026-07-07) — chỉ còn global hotkey là macOS-only (Linux tray không hỗ trợ).

## 🚀 Phase 8 — AI spend cockpit (IN PROGRESS, 2026-08-15, $0)
Chuyển từ *hiển thị* sang *hành động* trên dữ liệu chi phí:
- [x] [both] Data Confidence Pass: phân biệt live / history-only / unavailable, hiển thị freshness, giữ last-good service status và không đưa nguồn thiếu dữ liệu vào tổng/chart
- [x] [both] Ngân sách **tổng** tháng cho chi phí local Claude + Codex + Grok, kèm linear forecast cuối tháng và trạng thái on-track / forecast-over / already-over
- [x] [both] Adaptive refresh đơn giản: provider lỗi giãn nhịp 1× → 2× → 4× → 8×; manual/forced refresh bypass và reset khi thành công, không thêm timer
- [x] [both] Digest tuần qua notification: rolling 7 ngày so với 7 ngày trước, top source/model, forecast; mặc định OFF và cảnh báo khi có nguồn dùng dữ liệu cũ
- [x] [macOS] Quick switch custom Claude/Codex profile từ popover, kèm source/login health và activation fail-closed nếu profile bị sửa/xóa giữa `await`
- [x] [Linux] Codex account quick switch hiển thị last-good quota + health snapshot thụ động, không thêm polling
- [x] [both] First-provider onboarding Claude/Codex/Grok: phát hiện nguồn an toàn → bật và lưu → self-test thật → quota live; có Retry/Fix trong Settings và popover — 2026-08-15
- [x] [both] Reliability + Error UX hardening (2026-08-16): settings.json fail-closed (từ chối ghi khi file hiện hữu malformed/unreadable) + lossless save (giữ unknown top-level và per-provider keys) trên `BirdNionConfigStore` (macOS) và `config.rs` (Linux)
- [x] [both] Provider fetch dùng hard deadline chung (200s, `ProviderFetchDeadline`/`FETCH_DEADLINE`) bọc ngoài cả refresh loop và self-test, để một provider treo không giữ app/refresh vô hạn
- [x] [both] Sửa last-good policy: chỉ giữ quota cũ khi lỗi transient thật (network/timeout, rate-limit, 5xx thật) — cookie/credential/not-configured/schema khác giờ thay bằng lỗi mới thay vì bị che
- [x] [both] Thêm `notConfigured` tách khỏi token sai trong classifier; popover Retry hiện cho mọi provider lỗi (không chỉ Claude/Codex/Grok), Fix chỉ hiện khi lỗi thật sự sửa được từ Settings (not-configured/credential/cookie)
- [x] [macOS] Chuẩn hóa macOS minimum 14.0 — `Info.plist` (`LSMinimumSystemVersion`) trước đó lệch còn 13.0 so với `MACOSX_DEPLOYMENT_TARGET`/docs
- [x] Release gate: `Scripts/release.sh` chạy macOS build+test, Linux TS build (`npm run build`), và Rust tests trước khi bump version hoặc publish
- [ ] [Linux] Custom Claude/Codex profile quick switch trong popover — deferred/accepted gap cho tới khi UX macOS ổn định
- [x] [both] Budget **per-source** cho Claude/Codex/Grok/Kiro/OMP/Pi — UserDefaults (macOS) / localStorage (Linux), độc lập với budget tổng; Claude/Codex/Grok/Kiro có card trong tab provider, OMP/Pi có Settings + digest; mọi forecast tôn trọng trust-unavailable và digest chỉ cảnh báo forecast-over/already-over
- [x] [both] Usage Insights + Cost by Project — All tab chỉ giữ compact highlight; Settings có tab Insights với Overview và Projects 7/30/90 ngày. Claude/Codex/Grok dùng project key SHA-256 + basename an toàn từ metadata local; chỉ residual không gán được mới vào `Unknown`; history riêng `project-cost-history.json` high-water/0600 — 2026-08-20
- [x] [both] Guided Setup completion + Action Center v1 — lỗi sửa được mở đúng provider/control; save fail không chạy self-test; Live chỉ sau probe thật. Popover chỉ thêm badge gọn, chi tiết nằm trong Settings; chỉ current setup/connection-health, không history/quota/budget/release và không persist raw error — 2026-08-21
- [x] [both] First Live Checkpoint — receipt local per-provider cho Claude/Codex/Grok chỉ được ghi từ save-first explicit probe hiện tại có quota window và sau paint acknowledgment thật (AppKit `draw` / hai `requestAnimationFrame`); failure/cache/background/stale generation không tạo hoặc ghi đè, root storage hỏng được giữ nguyên, payload chuẩn hoá đúng schema và không chứa credential/path/token/raw error. macOS dùng atomic UUID journal + tri-state commit; `indeterminate` không giả Live/Fail — 2026-08-26
- [ ] [both] Export CSV/JSON chi phí theo ngày/model — deferred, ngoài scope đợt 2026-08-15
- [ ] [Windows] Port từ codebase Tauri `linux/` — **đang phát triển, `FLASH_UNVERIFIED`**:
  - [x] Platform seam cho `%USERPROFILE%`/`%APPDATA%`/`%LOCALAPPDATA%`, `PATH`/`PATHEXT`, atomic private writes và owner/SYSTEM DACL
  - [x] Static process ownership dùng owned child + Windows Job Object; listener chỉ được nhận khi PID khớp child BirdNion
  - [x] Static app-shell work: Windows Tauri config cho NSIS/current-user/WebView2, single-instance callback và tray left-click branch
  - [x] Static source discovery cho Claude, Gemini và Cursor qua platform paths; Cursor giữ SQLite read-only + browser fallback
  - [ ] Native Windows compile, runtime và install receipts cho đủ bốn OS/architecture lanes
  - [ ] CLIProxyAPI sidecar source/version/SHA, PE x64/ARM64, bundle resources và Defender receipt
  - [ ] Native browser/DPAPI, tray/single-instance, First Live provider, upgrade/uninstall và unsigned Setup EXE journeys

> Test suite đã được defer trong các lát cắt hiện tại. Chưa có Windows release workflow/artifact được xác minh và không được public claim Windows support từ các checkbox static ở trên.

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
| 2026-08-26 | Đóng parity macOS/Linux cho Kiro aggregate/storage, xAI roster, provider status invalidation, settings revision/dirfd, Codex account filesystem identity và First Live atomic journal/tri-state; Linux account remove chỉ unlink đúng `auth.json` qua bound dirfd, không recurse/rename/UUID unlink. Gate: macOS full `726` tests (`725` pass, `1` live skip), First Live `19/19`, Release universal `x86_64 arm64`; Linux Rust `578/578`, Node `65/65`, production build `60` modules; review độc lập `PASS 9.9/10`, 0 fail. |
| 2026-08-25 | macOS/Linux parity increment: Kiro tham gia canonical 6-source aggregate trên Linux (24h/30d, day/agent panel, provider chart, digest, budget); semantic scan receipt từ chối turn sai type/value, numeric vượt bound/overflow và alias chưa hỗ trợ; detector/scanner nhận current/legacy/XDG storage với default-DB fallback khi provider off; Settings Agents truyền quota IDs đúng contract; budget riêng 6 nguồn đồng bộ hai nền tảng; First Live receipt chỉ sau visible paint và storage fail-closed, state đã settle bị reset khi switch/disable. Gate: macOS full `578` tests (`577` pass, `1` live skip), focused `55/55`; Linux Node `14/14`, production build `59` modules, Rust `477/477`; 0 fail |
| 2026-08-23 | Agent-Centric UI Remake v2 (macOS), implementation verified: detector quét agent tools thật (`InstalledAgentDetectors`), popover All 4 khối capability-driven + ngân sách tuần/tháng (`BudgetForecast`), child panel 340px, Settings Agent và activity 52 tuần. Full Debug `566` tests (`565` pass, `1` live skip), Release universal `x86_64 arm64`, runtime 13s và independent review `PASS 9.6/10`; interactive visual receipt còn `UNPROVEN` do macOS Accessibility denial nên plan vẫn `in_progress` |
| 2026-08-21 | Windows Tauri port bắt đầu các lát cắt I1–I5: platform paths, atomic/DACL, owned process + Job Object, shell static và Claude/Gemini/Cursor discovery. Toàn bộ native matrix Windows 10/11 × x64/ARM64 vẫn `FLASH_UNVERIFIED`; chưa support/release công khai |
| 2026-08-21 | Guided Setup completion + Action Center v1 trên macOS/Linux: exact remediation target, save-first real self-test, current-issue header badge + Settings pane, không issue history/raw-error persistence |
| 2026-08-20 | Usage Insights + Cost by Project (macOS + Linux): compact All highlight mở Settings Insights, weekly Overview, project ranking/detail 7/30/90 ngày, privacy-safe attribution cho Claude/Codex/Grok và residual `Unknown` |
| 2026-08-16 | Budget per-source khởi đầu với Claude/Codex/Grok, mở rộng đủ Claude/Codex/Grok/Kiro/OMP/Pi trên macOS + Linux ngày 2026-08-25; UserDefaults/localStorage riêng biệt với budget tổng, trust-unavailable, weekly digest chỉ cảnh báo forecast-over/already-over |
| 2026-08-16 | Reliability + Error UX hardening: config fail-closed/lossless (macOS + Linux), provider fetch hard deadline, sửa last-good chỉ giữ lỗi transient thật, thêm `notConfigured` + Retry/Fix đúng ngữ cảnh, macOS minimum 14.0, release verification gate trong `Scripts/release.sh` |
| 2026-08-15 | Phase 8 in progress: thêm first-provider onboarding Claude/Codex/Grok trên macOS/Linux; Data Confidence, total monthly budget + forecast, profile quick switch/health, adaptive refresh và weekly digest đã có; CSV/JSON, per-provider budget và Windows vẫn deferred |
| 2026-07-31 | 4 tính năng CodexBar: menu-bar metric resolver, bounded Codex cost scan (120 ngày, resumable), xAI Platform provider, Claude prepaid credits + Max multiplier |
| 2026-07-07 | v0.8.6 — Settings parity CodexBar (hotkey, update check, storage footprint…) |
| 2026-07-06 | Per-model breakdown tab All + fix drag-reorder + fix token clobber |
| 2026-07-01 | v0.6.x — provider reordering, FreeModel, color system |
| 2026-06-28 | 15 providers ported từ CodexBar (~23 tổng) |
| 2026-06-25 | v0.2.0 release — full Claude parity + Homebrew tap |
| 2026-06-24 | Drag-drop reorder + menu-bar visibility per provider |
| 2026-06-23 | Claude provider parity with CodexBar |
