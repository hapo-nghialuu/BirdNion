# BirdNion — System Architecture

> AI spend + quota cockpit: menu-bar app macOS native và tray app Linux, cùng theo dõi quota/cost từ nhiều provider.

## 1. Mục tiêu

BirdNion chạy trên thanh menu macOS hoặc system tray Linux, theo dõi quota và chi phí AI từ dữ liệu provider lẫn scanner cục bộ. Dự án phát triển từ `ai-statusbar` thành một cockpit đa provider, ưu tiên độ tin cậy dữ liệu và thao tác cấu hình.

## 2. Stack & phạm vi

- **macOS**: Swift + SwiftUI, AppKit (`NSStatusBar` + custom `DropdownPanel`), Xcode 16/26
- **Linux**: Tauri v2, Rust backend + TypeScript frontend
- **Local SPM**: [CodexBarCore](https://github.com/hapo-nghialuu/CodexBar) tại `~/Desktop/CodexBar` — cung cấp `ClaudeUsageFetcher`, `ClaudeStatusProbe`, `RateWindow`, `ProviderCostSnapshot`
- **Triển khai**: cá nhân / share nội bộ qua [Homebrew tap](https://github.com/hapo-nghialuu/homebrew-tap)
- **Out of scope hiện tại**: App Store, multi-user server và Windows production build

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
  let serviceStatus: String?              // last-good vendor status text
  let serviceStatusLevel: String?         // operational / degraded / outage
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

### 3.4 Codex account switching

Popover Accounts row (`CodexAccountsPopoverSection` trong `QuotaPanel.swift`) cho phép:
- Hover để xem danh sách tài khoản (system + managed `~/Library/Application Support/BirdNion/codex-accounts/<uuid>/`)
- Click để xem quota tài khoản khác (snapshot swap via `.birdnionCodexAccountChanged`)
- "Add account…" chạy `codex login` với `CODEX_HOME` riêng

**CLI account switcher** (`CodexAccountStore.swift`): Switch button copy managed account vào `~/.codex/auth.json` để terminal `codex` dùng, với bảo mật:
- One-time pristine backup tại `~/.codex/auth.json.birdnion-orig` (lần đầu overwrite)
- Promote-before-overwrite: system account tự thêm vào managed nếu chưa tracked
- Atomic writes 0600 qua `CodexAuthStore` (staged file + `fchmod` + `rename`)
- Token-rotation sync-back: mỗi refresh, so sánh mtime CLI vs managed copy, auto-sync nếu CLI mới hơn (idempotent)

Tracked state: UserDefaults key `codexCLISwitchedAccount` lưu managed account id hiện đang ở CLI; `nil` = system account gốc.

### 3.5 Profile quick switch và activation safety

- macOS popover cho phép quick switch custom Claude Code/Codex profile, đồng thời hiển thị trạng thái ready/stale/active và health của local proxy.
- Linux giữ quick switch Codex account hiện có, bổ sung last-good quota + health snapshot thụ động; không tạo polling loop riêng. Custom Claude/Codex profile switcher trong popover Linux vẫn là accepted gap.
- Mỗi activation macOS kiểm tra **exact profile snapshot** trước và sau mọi `await`. Profile bị sửa hoặc xóa trong lúc activation chạy sẽ ném `profileChangedDuringActivation`, không upsert/apply/ghi overlay từ snapshot cũ; proxy reconcile đọc lại store hiện tại.

## 4. Luồng quota

```
QuotaService.refresh()  (globalInterval ± 10s, default 120s)
  │
  ├─ Tính effective interval = base/per-provider override × adaptive multiplier
  │   (1× / 2× / 4× / 8× theo failure streak; capped ở 8×)
  │
  ├─ Filter providers theo effective interval
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

Adaptive refresh dùng chính polling/tick hiện có, không thêm timer hay daemon. Automatic failure tăng multiplier; fetch thành công xóa streak. Manual/forced refresh luôn bypass due-filter, và queued forced retry vẫn giữ semantics user-initiated. State backoff chỉ ở memory và được dọn khi provider bị remove.

### 4.1 Data confidence và last-good state

Mỗi scanner Claude/Codex/Grok trả metadata `included`, `live`, `scannedAt` (`UsageScanConfidence` trên macOS, `UsageReport` trên Linux):

- `live`: scan hiện tại thành công; `history-only`: không live nhưng có lịch sử; `unavailable`: không có cả hai.
- `scannedAt` được lưu cùng cost history để vẫn hiển thị freshness khi chu kỳ hiện tại chỉ dùng lịch sử.
- Tab All chỉ cộng nguồn `included`; badge hiển thị trạng thái + freshness. Heatmap dùng token count, không dùng USD làm activity giả.
- Provider refresh thiếu tạm thời `serviceStatus`/`serviceStatusLevel` sẽ kế thừa last-good pair thay vì làm trống UI.

### 4.2 Monthly budget, forecast và weekly digest

- `MonthlyForecast` cộng chi phí local Claude + Codex + Grok từ đầu tháng đến hiện tại rồi linear-project tới cuối tháng. Budget tổng là local preference; `0`/blank nghĩa là tắt card. Đây không phải billing API.
- **Budget per-provider** (Claude/Codex/Grok riêng biệt, độc lập với budget tổng): cùng công thức `MonthlyForecast.build(source:)` nhưng chỉ cộng daily USD của đúng 1 source. Lưu ở UserDefaults `claudeBudgetUSD`/`codexBudgetUSD`/`grokBudgetUSD` (macOS) và `localStorage` `birdnion.claudeBudgetUSD`/`birdnion.codexBudgetUSD`/`birdnion.grokBudgetUSD` (Linux) — **không** ghi vào provider `settings.json`.
  - Tab provider tương ứng (`ProviderBudgetCard` macOS / `providerBudgetCard` Linux, không phải All tab — All tab chỉ hiển thị budget tổng) hiển thị mỗi provider có budget > 0: MTD/budget, linear projection, remaining hoặc over, status on-track/forecast-over/already-over.
  - Trust rule: provider có `confidence == .unavailable` (không live lẫn không lịch sử) hiện "chưa có dữ liệu chi phí" thay vì tính forecast — không bao giờ hiện on-track (xanh) giả khi thiếu bằng chứng. History-only vẫn tính bình thường.
- Weekly digest mặc định OFF. Cửa sổ hiện tại là hôm nay + 6 ngày trước; cửa sổ so sánh là 7 ngày liền trước đó.
- Digest đi nhờ refresh/tick sẵn có. `lastEvaluatedAt` giới hạn cadence và vẫn được ghi khi suppress/error; `lastSentAt` chỉ ghi sau khi notification thành công.
- Không gửi khi không có live source hoặc tổng USD/token bằng 0. Nếu một phần nguồn không live, notification ghi rõ nguồn dùng cached data.
- Digest chỉ cảnh báo budget khi trạng thái là `forecast-over` hoặc `already-over` (không nhắc khi `on-track`), cho cả budget tổng và từng provider có cấu hình riêng. `forecast-over` dùng số dự phóng cuối tháng (`projectedTotalUSD`); `already-over` dùng số đã chi thực tế tháng này (`monthToDateUSD`).

### 4.3 Usage Insights và cost theo project

- All tab chỉ thêm một compact highlight sau Data Confidence và trước budget; click mở top-level Settings `Insights`, không mở thêm popover/modal chi tiết.
- `Overview` tái sử dụng đúng rolling 7 ngày của Weekly Digest: current/prior, change, top source/model và confidence. Source đã bật nhưng chưa có report được giữ rõ là `unavailable`, không bị loại khỏi coverage. `Projects` có ranking/detail theo 7/30/90 ngày.
- Claude lấy project identity trong cùng lượt quét JSONL: project key luôn là SHA-256 của session-directory token ổn định (`derived`); top-level `cwd` đã verify chỉ nâng display label thành basename an toàn, không đổi key. Store/UI/copy không nhận full path.
- Codex đọc `session_meta.payload.cwd`; Grok dùng token thư mục `sessions/<encoded_cwd>/...` làm identity ổn định và chỉ dùng `summary.json.git_root_dir` để nâng basename hiển thị. Cả hai chỉ persist SHA-256 key + label đã sanitize; phần aggregate thiếu metadata mới được giữ ở residual `Unknown`.
- `project-cost-history.json` là optional/versioned store riêng, high-water và giữ 400 ngày. Day key chỉ nhận canonical `yyyy-MM-dd`; missing/corrupt/write failure không làm hỏng `cost-history.json`, quota, budget hay digest. Projection luôn bị chặn bởi aggregate source/day để project cũ + mới không double-count; Codex conflict rõ ràng phát tombstone có ID SHA-256 và contribution chính xác, áp dụng idempotent để phần đó trở lại `Unknown` mà empty scan bình thường vẫn giữ high-water.

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
| Total monthly budget | macOS `UserDefaults.monthlyBudgetUSD`; Linux local storage `birdnion.monthlyBudgetUSD` | local preference |
| Per-provider budget (Claude/Codex/Grok) | macOS `UserDefaults.claudeBudgetUSD`/`codexBudgetUSD`/`grokBudgetUSD`; Linux local storage `birdnion.claudeBudgetUSD`/`birdnion.codexBudgetUSD`/`birdnion.grokBudgetUSD` — không phải provider `settings.json` | local preference |
| Weekly digest toggle/cadence | macOS `weeklyDigest*`; Linux local storage `birdnion.weeklyDigest*` | local preference, default OFF |
| Project cost history | `~/.config/birdnion/project-cost-history.json` (sibling của settings/cost history) | SHA-256 keys + safe basename, hashed retraction IDs, atomic `0600`, high-water 400 ngày |
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
      InsightsPane.swift               # Overview / Projects 7d, 30d, 90d
      InsightsContentViews.swift       # weekly summary + project detail
      ProvidersPane.swift            # sidebar + detail
      GeneralPane.swift               # language, refresh interval
      DisplayPane.swift
      AdvancedPane.swift
      AboutPane.swift
  Services/
    QuotaService.swift               # polling loop, @Published statuses
    SettingsStore.swift               # @AppStorage + UserDefaults
    ProjectCostHistoryStore.swift     # isolated privacy-safe project history
    ProjectInsightsBuilder.swift      # aggregate + Unknown residual policy
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
- [x] `xcodebuild` build clean; full macOS suite 420 tests pass (2026-08-15)
- [x] Local token scanner: 30-day chart for Claude usage
- [x] Data confidence + freshness + last-good service status trên macOS/Linux
- [x] Total monthly budget + linear forecast trên macOS/Linux
- [x] Per-provider budget (Claude/Codex/Grok) + trust-unavailable no false-green trên macOS/Linux
- [x] Adaptive refresh 1×/2×/4×/8×, manual/forced bypass, không timer mới
- [x] Weekly digest rolling 7 ngày, default OFF, trên macOS/Linux
- [x] Usage Insights + Cost by Project trên macOS/Linux: compact All highlight, Settings Overview/Projects 7/30/90, Claude/Codex/Grok privacy key + residual `Unknown`
- [x] macOS custom profile quick switch fail-closed; Linux Codex account quota/health snapshot
- [x] Release pipeline (`Scripts/release.sh`) → tap → brew install

## 9. Decision register

| Quyết định | Lý do |
|---|---|
| Swift + SwiftUI + AppKit (NSPopover-style) | Native, giống CodexBar |
| Ad-hoc signed + cask postflight xattr | Free, $0/yr, user mở thẳng (không cần Developer ID cho test nội bộ) |
| Local CodexBarCore SPM (path-based) | Tận dụng `ClaudeWebAPIFetcher` + `RateWindow` battle-tested |
| Seed pending with old statuses on refresh | User không thấy flash empty khi provider fetch chậm |
| Per-provider refresh interval | Provider chậm/rate-limited poll ít hơn, user tự chỉnh |
| Adaptive multiplier capped 8× | Giảm request khi provider lỗi mà không tạo scheduler mới hoặc gây starvation vô hạn |
| Total budget là local preference | Forecast minh bạch trên dữ liệu scanner; không giả là provider billing |
| Per-provider budget lưu UserDefaults/localStorage, không ghi vào `settings.json` | Cùng convention "local UI preference" với budget tổng; tách khỏi token/config của provider |
| Weekly digest default OFF | Tránh tự đưa số liệu chi phí ra ngoài popover khi user chưa opt in |
| Project history tách khỏi aggregate history | Corrupt/missing project attribution không được ảnh hưởng quota, budget, digest hoặc `cost-history.json` |
| Codex/Grok project attribution từ local logs | Codex hash validated `cwd`; Grok hash stable encoded session-directory token và chỉ dùng verified `git_root_dir` cho safe basename; aggregate thiếu metadata vẫn là `Unknown` |
| Exact-snapshot activation guard | Delete/edit profile thắng async activation; stale continuation fail closed |
| Menu-bar visibility toggle per provider | User loại provider không quan tâm khỏi chuỗi % trên menu bar |
| Cask filename: `BirdNion-${version}.zip` (no v prefix) | GitHub release-asset upload cache trả 404 BlobNotFound với `v${version}.zip` |

## 10. Open questions / future

- **Apple Developer Program** ($99/năm) — cần nếu muốn user cài đặt thẳng không cần postflight xattr
- **Codex multi-account** đã có, còn polish UI
- **Sparkle auto-update** — optional, cần server
- **Mac App Store** — nếu muốn mass distribution, cần review process
- **Claude code API key** flow — hiện support Anthropic key, có thể extend cho setup token từ CLI
- **Local memory** — track Anthropic Max weekly + Sonnet daily qua `~/.claude/projects/`
- **Phase 8 còn lại** — CSV/JSON export, Linux custom-profile popover và Windows port

## File liên quan

- `docs/build.md` — build, deploy local, release flow
- `docs/development-roadmap.md` — phases đã xong + còn lại
- `Scripts/release.sh` — auto release pipeline
- External: [homebrew-tap](https://github.com/hapo-nghialuu/homebrew-tap) — Cask + releases
