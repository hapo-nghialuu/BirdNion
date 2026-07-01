# BirdNion — System Architecture

> Menu-bar app macOS native (Swift + SwiftUI), theo dõi quota AI từ nhiều provider, full parity với CodexBar cho Claude.

## 1. Mục tiêu

App nhỏ chạy trên thanh menu macOS (icon góc phải, popover), theo dõi quota AI của các hệ thống BOSS dùng/vận hành. **BirdNion** = fork/evolution của `ai-statusbar` (MiniMax + Hapo only) thành multi-provider (7 providers) với Claude parity.

## 2. Stack & phạm vi

- **Stack**: Swift + SwiftUI, AppKit (`NSStatusBar` + custom `DropdownPanel`), Xcode 16/26
- **Local SPM**: [CodexBarCore](https://github.com/hapo-nghialuu/CodexBar) tại `~/Desktop/CodexBar` — cung cấp `ClaudeUsageFetcher`, `ClaudeStatusProbe`, `RateWindow`, `ProviderCostSnapshot`
- **Triển khai**: cá nhân / share nội bộ qua [Homebrew tap](https://github.com/hapo-nghialuu/homebrew-tap)
- **Out of scope**: App Store, multi-user, auto-update (Sparkle), translation

## 3. Provider quota

### 3.1 Mô hình dữ liệu

```swift
struct QuotaWindow {
  let label: String     // vd "5 giờ", "Tuần", "Opus"
  let usedPct: Int      // 0-100
  let remainingPct: Int // 0-100
  let resetDate: Date?
  let windowSeconds: Int?
}

struct ProviderStatus {
  let id: String
  let displayName: String
  let windows: [QuotaWindow]
  let lastUpdated: Date
  let error: String?
  // Claude parity
  let cost: ProviderCostSnapshot?       // web-scraped monthly cap
  let webExtras: ClaudeWebExtras?        // account email, loginMethod, ...
}

struct ClaudeWebExtras {
  let accountEmail: String?
  let accountOrganization: String?
  let loginMethod: String?
  let sessionPercentUsed: Double?
  let weeklyPercentUsed: Double?
  let opusPercentUsed: Double?
  let extraRateWindows: [ClaudeExtraRateWindow]
  let sourceLabel: String?
}
```

### 3.2 Providers (7 built-in)

| id | Provider | Auth | Source |
|---|---|---|---|
| `minimax` | MiniMax | Bearer API key (`~/.config/birdnion/settings.json`) | `/v1/token_plan/remains` |
| `codex` | OpenAI Codex | OAuth (read `~/.codex/auth.json`) | `ChatGPT backend API` |
| `hapo` | Hapo AI Hub | API key (`~/.config/birdnion/settings.json`) | `<HAPO_BASE_URL>` |
| `claude` | Anthropic Claude | OAuth (`Claude Code-credentials` Keychain entry owned by Claude Code app) + cookie scrape | `api.anthropic.com/api/oauth/usage` + `claude.ai/api/*` |
| `openrouter` | OpenRouter | Bearer API key | `/auth/key` + `/generation` |
| `deepseek` | DeepSeek | Bearer API key | `/user/balance` |
| `zai` | Z.ai / GLM | Bearer API key | `/api/paas/v4/quota/limit` |

### 3.3 Claude parity (CodexBar feature parity)

- **Source routing**: `ClaudeUsageDataSource` enum — auto / oauth / web / cli / api
  - `oauth`: in-house `fetchOAuth()` against `api.anthropic.com/api/oauth/usage`
  - `web`: `ClaudeWebAPIFetcher` with browser cookie auto-detect (Safari/Chrome via `SweetCookieKit`)
  - `cli`: `ClaudeStatusProbe.fetch()` runs `claude` PTY
  - `api`: Admin API key
- **Source planner**: `ClaudeSourcePlanner.resolve()` walks OAuth → Web → CLI fallback chain
- **5-min timeout** on cost scrape (`withTaskGroup` race) so a missed Keychain prompt doesn't hang
- **Per-provider override interval**: stored in UserDefaults, filters slow providers out of cycles

## 4. Luồng quota

```
QuotaService.refresh()  (mỗi globalInterval ± 10s, default 120s)
  │
  ├─ Filter providers theo per-provider override interval
  │   (nhỏ hơn interval thì skip, vẫn giữ status cũ trong displayStatuses)
  │
  ├─ TaskGroup: fetch song song tất cả providers do
  │   (timeout 5s cho web, timeout 6s cho status probe, timeout 15s cho OAuth)
  │
  ├─ Khi mỗi provider return:
  │   - update `statuses[id]` mới
  │   - publish displayStatuses (giữ order `BirdNionConfigStore` — từ `~/.config/birdnion/settings.json`)
  │   - log slow providers (>2s)
  │
  └─ Sau khi tất cả xong:
      - isRefreshing = false
      - QuotaNotifier.post nếu remaining < threshold
```

`displayStatuses` luôn có 1 entry/provider kể cả khi fetch đang chạy (placeholder nếu chưa có data). Khi refresh bắt đầu, **status cũ vẫn hiển thị** — chỉ từng row swap sang data mới khi fetch return.

## 5. Lưu trữ & bảo mật

| Dữ liệu | Vị trí | Quyền |
|---|---|---|
| Tất cả provider tokens + enabled flags + metadata (MiniMax, Hapo, OpenRouter, DeepSeek, Z.ai, Claude admin key) | `~/.config/birdnion/settings.json` (XDG) hoặc `~/.birdnion/settings.json` (legacy) | 0600 |
| Codex OAuth | `~/.codex/auth.json` | 0600 |
| Claude OAuth | macOS Keychain `service: Claude Code-credentials` (owned by Claude Code app, not BirdNion) | Keychain ACL |
| Claude Cost scrape cookies | Browser cookies (Safari/Chrome) qua `BrowserCookieAccessGate` | read-only |
| UserDefaults settings | `~/Library/Preferences/com.local.birdnion.plist` | standard |
| Per-provider refresh override | `UserDefaults.refreshInterval.<id>` | standard |
| Per-provider menu-bar visibility | `UserDefaults.menuBarVisibility.<id>` | standard |
| Local token scanner cache | in-memory (5 min TTL) | n/a |

> As of the 2026-06-25 storage refactor, there is **no BirdNion-owned
> Keychain entry**. The previous split between
> `~/Library/Application Support/BirdNion/providers.json` and the macOS
> Keychain (services `BirdNion`) was consolidated into the single
> `~/.config/birdnion/settings.json` file. Migration is opt-in: tokens saved
> under the old Keychain service are not auto-migrated; users re-enter
> them via Settings on first launch.

API key trong UI hiển thị dạng masked: `fe_oa_••••4a8`.

## 6. UI

### 6.1 Popover layout
```
┌─ Tabs (logo-only 44×44 chips) ────────────┐
│ [Claude] [Codex] [Hapo] [MiniMax] [..]   │
├──────────────────────────────────────────┤
│ ┌─ Header Card ─────────────────────────┐│
│ │ Logo  Claude     ✓ ON/OFF switch    ││ ← "đang cập nhật" inline
│ │       email · 1 phút trước          ││
│ └──────────────────────────────────────┘│
│ ┌─ Provider Card (window bars) ───────┐│
│ │ 5 GIỜ  ████████░  87%   Resets 4h   ││
│ │ TUẦN  █████████  98%   Resets 6d  ││
│ └──────────────────────────────────────┘│
│ ┌─ Claude 30-day chart (if Claude) ───┐│
│ │ Today: $X · NYM tokens              ││
│ │ 30d cost: $X · NYB tokens           ││
│ │ ████ ▆▅▇▆▄▃▅▆▇▄▅▆▅▇▄▆▅▆▇          ││
│ │ Top model: claude-opus-4-8          ││
│ └──────────────────────────────────────┘│
├──────────────────────────────────────────┤
│ Refresh / Settings… / About / Quit      │ ← tight rows
└──────────────────────────────────────────┘
```

### 6.2 Settings tab (sidebar)
```
┌─ Sidebar (200pt) ──────────┬─ Detail ──────┐
│ 🔍 Search box              │ Provider name  │
│ ┌─ Provider row ──────┐    │ [Settings card]│
│ │ ☐ 🐦 Claude 100%   │ ← │  Account label │
│ │ ☑ ⓘ Codex  99%      │    │  Token paste   │
│ │ ☑ 🛡 Hapo   81%     │    │  Region picker │
│ │ ☑ ⓜ MiniMax 92%    │    │  Source picker │
│ │ ☐ 💚 OpenRouter     │    │  Cookie source │
│ │ ...                  │    │  Refresh rate  │
│ └──────────────────────┘    │  Show on bar   │
│ (drag to reorder)            │               │
└─────────────────────────────┴───────────────┘
```

## 7. Cấu trúc module

```
BirdNion/
  BirdNionApp.swift              # @main, NSApplicationDelegate, services
  AppDelegate.swift                  # status item, click handling, observers
  Views/
    PopoverView.swift                # container
    QuotaPanel.swift                 # tabs + provider card + actions
    MenuBarIcon.swift                # status bar bird/provider-percent renderer
    MenuBarVisibility.swift          # UserDefaults-backed show/hide
    Settings/
      ProvidersPane.swift            # sidebar + detail
      GeneralPane.swift               # language, refresh interval
      DisplayPane.swift
      AdvancedPane.swift
      AboutPane.swift
  Services/
    QuotaService.swift               # polling loop, @Published statuses
    SettingsStore.swift               # @AppStorage + UserDefaults
    ServicesContainer.swift          # DI, providers list, makeProviders()
    BirdNionConfigStore.swift         # single source of truth: ~/.config/birdnion/settings.json (tokens + enabled + metadata)
  Models/
    ProviderStatus.swift              # QuotaWindow, ProviderStatus
  Providers/
    QuotaProvider.swift               # protocol
    MiniMaxProvider.swift
    Codex/
      CodexProvider.swift
      CodexAuth.swift                 # auth.json I/O
      CodexUsageAPI.swift
      CodexStatusProbe.swift
      CodexResetCreditsAPI.swift
      CodexAccountStore.swift         # multi-account
      CodexBarConfigStore.swift        # shared CodexBar config
      TextParsing.swift
    Claude/
      ClaudeProvider.swift            # source routing
      ClaudeCLIVersionDetector.swift
      ClaudeCostScanner.swift         # local token usage from jsonl
    HapoHubProvider.swift
    OpenRouterProvider.swift
    DeepSeekProvider.swift
    ZaiProvider.swift
  Assets.xcassets/
    AppIcon.appiconset/               # macOS app icon (1024 master)
    ProviderLogo.imageset/            # generic 50pt provider logo
    MiniMaxLogo/CodexLogo/HapoLogo/   # per-brand
    ClaudeLogo/DeepSeekLogo/ZaiLogo/  # monochrome templates
    OpenRouterLogo/                   # brand-tinted
Scripts/
  release.sh                          # auto-build + publish
```

## 8. Acceptance criteria (current state)

- [x] App icon xuất hiện ở menu bar (blue bird), click mở popover
- [x] 7 providers configured (4 enabled by default, 3 disabled)
- [x] Per-provider enable/visibility trong Settings
- [x] Tokens lưu file `~/.config/birdnion/settings.json` (0600), không plaintext
- [x] Quota poll 120s + per-provider override (30s — 30m)
- [x] Provider tabs với 1-4 windows, progress bar, reset countdown
- [x] Claude full parity: 4 windows, plan name, extra usage, 30-day chart
- [x] Last-known data preserved while refresh in flight (no empty flash)
- [x] Per-provider loading state (placeholder + inline spinner)
- [x] Drag-drop reorder in Settings sidebar
- [x] Search box + active-first sort
- [x] Menu-bar visibility toggle per provider
- [x] Ad-hoc signed, Gatekeeper auto-strip qua Homebrew cask postflight
- [x] `xcodebuild` build clean, 111 tests pass
- [x] Local token scanner: 30-day chart for Claude usage
- [x] Release pipeline (`Scripts/release.sh`) → tap → brew install

## 9. Decision register

| Quyết định | Lý do |
|---|---|
| Swift + SwiftUI + AppKit (NSPopover-style) | Native, giống CodexBar |
| Ad-hoc signed + cask postflight xattr | Free, $0/yr, user mở thẳng (không cần Developer ID cho test nội bộ) |
| Local CodexBarCore SPM (path-based) | Tận dụng `ClaudeWebAPIFetcher` + `RateWindow` battle-tested |
| Seed pending with old statuses on refresh | User không thấy flash empty khi provider fetch chậm |
| Per-provider refresh interval | Provider chậm/rate-limited poll ít hơn, user tự chỉnh |
| Menu-bar visibility toggle per provider | User loại provider không quan tâm khỏi chuỗi % trên menu bar |
| Cask filename: `BirdNion-${version}.zip` (no v prefix) | GitHub release-asset upload cache trả 404 BlobNotFound với `v${version}.zip` |

## 10. Open questions / future

- **Apple Developer Program** ($99/năm) — cần nếu muốn user cài đặt thẳng không cần postflight xattr
- **Codex multi-account** đã có, còn polish UI
- **Sparkle auto-update** — optional, cần server
- **Mac App Store** — nếu muốn mass distribution, cần review process
- **Claude code API key** flow — hiện support Anthropic key, có thể extend cho setup token từ CLI
- **Local memory** — track Anthropic Max weekly + Sonnet daily qua `~/.claude/projects/`

## File liên quan

- `docs/build.md` — build, deploy local, release flow
- `docs/development-roadmap.md` — phases đã xong + còn lại
- `Scripts/release.sh` — auto release pipeline
- External: [homebrew-tap](https://github.com/hapo-nghialuu/homebrew-tap) — Cask + releases
