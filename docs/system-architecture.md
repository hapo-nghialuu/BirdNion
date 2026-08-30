# BirdNion — System Architecture

> AI spend + quota cockpit: menu-bar app macOS native và tray app Linux; Windows Tauri đang phát triển nhưng chưa được support hoặc phát hành.

## 1. Mục tiêu

BirdNion chạy trên thanh menu macOS hoặc system tray Linux, theo dõi quota và chi phí AI từ dữ liệu provider lẫn scanner cục bộ. Dự án phát triển từ `ai-statusbar` thành một cockpit đa provider, ưu tiên độ tin cậy dữ liệu và thao tác cấu hình. Windows 10/11 x64/ARM64 là target đang phát triển từ codebase Tauri, chưa phải capability public.

## 2. Stack & phạm vi

- **macOS**: Swift + SwiftUI, AppKit (`NSStatusBar` + custom `DropdownPanel`), Xcode 16/26
- **Linux**: Tauri v2, Rust backend + TypeScript frontend
- **Windows (development target)**: Tauri v2 dùng lại Rust backend + TypeScript frontend trong `linux/`; target NSIS x64/ARM64 chưa có native compile, runtime hoặc install receipt
- **Local SPM**: [CodexBarCore](https://github.com/hapo-nghialuu/CodexBar) tại `~/Desktop/CodexBar` — cung cấp `ClaudeUsageFetcher`, `ClaudeStatusProbe`, `RateWindow`, `ProviderCostSnapshot`
- **Triển khai**: cá nhân / share nội bộ qua [Homebrew tap](https://github.com/hapo-nghialuu/homebrew-tap)
- **Out of scope hiện tại**: App Store, multi-user server và public Windows support/release trước khi đủ evidence gates

### 2.1 Windows platform seam — trạng thái tạm thời

Code hiện có là implementation tĩnh, không phải bằng chứng Windows native:

- `platform/paths.rs` centralize `%USERPROFILE%`, `%APPDATA%`, `%LOCALAPPDATA%`, provider homes và overrides; `platform/executable.rs` resolve `PATH`/`PATHEXT`, gồm `.exe`, `.cmd` và `.bat`.
- `platform/atomic_file.rs` ghi temp cùng thư mục, flush/sync rồi replace bằng `MoveFileExW(REPLACE_EXISTING | WRITE_THROUGH)`. Temp file và config/auth directories dùng protected DACL chỉ cho owner và `SYSTEM`; ACL thực tế vẫn cần inspect trên Windows.
- `platform/process.rs` giữ exact child handle; Windows gắn child vào Job Object `KILL_ON_JOB_CLOSE` và dùng TCP owner table để chỉ chấp nhận listener có PID khớp child. Không fallback kill process theo tên/PID/port, nhưng spawn-to-job race và native lifecycle vẫn chưa được chứng minh.
- `tauri.windows.conf.json` tách Windows identity, NSIS current-user, WebView2 bootstrapper và icon. Single-instance callback cùng tray left-click branch đã wiring tĩnh; tray/window/DPI/autostart/notification runtime chưa verify.
- Claude dùng ordered config roots, Gemini dùng `GEMINI_CLI_HOME`/`%USERPROFILE%`, Cursor dùng `%APPDATA%/.../state.vscdb` với SQLite read-only, bounded timeout và browser fallback. Browser/DPAPI, locked DB, multi-profile và real credential journeys vẫn chưa verify.
- CLIProxyAPI sidecar có owned-process seam và resource/dev executable resolution, nhưng source/version/SHA, PE architecture x64/ARM64, bundle resources và Defender receipt chưa được khóa.

Evidence bắt buộc tách bốn lane độc lập: Windows 10 x64, Windows 10 ARM64, Windows 11 x64 và Windows 11 ARM64. Test suite hiện được defer; trạng thái tổng thể là `FLASH_UNVERIFIED`. Không suy ra Windows support từ macOS-host `cargo check`, isolated Windows type-check hoặc static review.

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
- Auth transaction bind root/home bằng directory descriptor và identity `dev+ino`; symlink, real-directory replacement và route đổi giữa validation/write đều fail-closed
- Atomic writes 0600 qua `CodexAuthStore`; exact bytes + app revision chặn reauth/remove ghi đè, source credential phải parse hợp lệ trước mọi copy
- Token refresh giữ binding account đã capture: switch A→B giữa request chỉ có thể commit rotated token vào A, rồi generation guard loại UI/snapshot cũ
- `codex login` chạy trong managed dir đã bind bằng child-process cwd descriptor; managed metadata/path lỗi không bao giờ fallback sang system credential
- Linux carry identity root/home từ validation sang descriptor bind cho select/promote/remove và persist `dev+ino` cho account mới; thay managed root trước hoặc sau metadata commit đều fail-closed. Entry legacy thiếu identity không được route; remove chỉ bỏ metadata, còn entry identity-bearing chỉ unlink đúng `auth.json` qua bound home descriptor sau commit, không recurse, rename hoặc unlink tên UUID

Tracked state: UserDefaults key `codexCLISwitchedAccount` lưu managed account id hiện đang ở CLI; `nil` = system account gốc.

#### Antigravity multi-account

- macOS và Linux cùng quản lý nhiều Google OAuth account, chọn account mặc định trong Settings và quick-switch trong popover; quick-switch ẩn khi chỉ có tối đa một account.
- Store chỉ đổi `activeLabel` khi switch, ghi atomic với quyền `0600`; IPC Linux chỉ trả `label`, `email` và `activeLabel`, không serialize refresh token hay OAuth client secret.
- Account OAuth đang chọn là identity ưu tiên. Ở chế độ `auto`, local process/CLI trả account mismatch sẽ không chặn OAuth fallback; kết quả mismatch chỉ được dùng nếu không có OAuth result.
- Mỗi mutation Linux phát event trước và sau durable IPC: pulse đầu vô hiệu hóa result của account cũ, pulse sau xếp refresh account mới. macOS đổi selection đồng bộ rồi invalidate/refetch provider ngay.

### 3.5 Profile quick switch và activation safety

- macOS popover cho phép quick switch custom Claude Code/Codex profile, đồng thời hiển thị trạng thái ready/stale/active và health của local proxy.
- Linux giữ quick switch Codex account hiện có, bổ sung last-good quota + health snapshot thụ động; không tạo polling loop riêng. Custom Claude/Codex profile switcher trong popover Linux vẫn là accepted gap.
- Mỗi activation macOS kiểm tra **exact profile snapshot** trước và sau mọi `await`. Profile bị sửa hoặc xóa trong lúc activation chạy sẽ ném `profileChangedDuringActivation`, không upsert/apply/ghi overlay từ snapshot cũ; proxy reconcile đọc lại store hiện tại.

### 3.6 Agent Catalog, Popover Capability Blocks và 52-week Activity Ledger (2026-08-23)

- **Installed Agent Catalog**: Quét có giới hạn (bounded allowlist) bằng `InstalledAgentDetectors` kiểm tra file thực thi thật (`isExecutableFile`) và config/session marker paths trên máy; lưu preferences visibility/pinning trong namespace `birdnion.agentVisibility.v1.*`.
- Visibility/pinning chỉ điều khiển trình bày roster. Ẩn agent không tắt scanner, không sửa provider/config, không làm mất capability evidence và không loại cost khỏi aggregate.
- **Popover All 4 Khối**:
  1. *Tổng chi phí*: 6 nguồn cost (`claude`, `codex`, `grok`, `kiro`, `omp`, `pi`), period chips `[24h, 7d, 30d, 90d, 120d]`, dòng stats mở nhanh panel Hoạt động.
  2. *Quota*: lọc provider có quota window thực tế, cắt 3 dòng + dòng gộp "+N".
  3. *Chi phí theo*: toggle Agent / Model, thanh phân bố màu liên tục.
  4. *Đã cấu hình*: danh sách agent chỉ có config (ẩn khi rỗng).
  5. *Ngân sách*: hỗ trợ cài đặt kỳ linh hoạt Tuần / Tháng (`BudgetPeriod` trong `SettingsStore`), tính toán dự phóng qua `BudgetForecast`.
- **Agent Detail Child Panel**: NSPanel 340px độc lập neo bên phải popover chính, hiển thị 3 tab `Quota`, `Chi phí`, `Config` lấy đường dẫn và model từ dữ liệu quét thật.
- Quota row dùng window chính đang active qua `ProviderStatusSummary.lowestWindow`; supplementary/inactive window không được thay quota chính. Detail chỉ hiện số cost khi có evidence thực, và chỉ nói quota/upstream/health khi snapshot có bridge/status tương ứng. Request mở child panel có generation guard để intent cũ không ghi đè click mới.
- OMP/Pi stream JSONL theo chunk 64 KiB với read cursor tuyến tính và file cap 64 MiB; chỉ compact prefix đã consume. Malformed complete line, missing root, enumeration/read error, cancellation hoặc entry-limit truncation đều làm scan incomplete. Partial result không được merge vào high-water history hoặc cache/stamp như live; malformed unterminated tail đang được writer append mới được bỏ qua. Dedup chỉ claim key sau khi record có timestamp/usage hợp lệ, nên duplicate rỗng không chặn record usage hợp lệ phía sau. Trên Linux, Kiro detector và scanner cùng nhận current CLI, legacy archive/SQLite và custom `XDG_DATA_HOME`, có fallback về DB mặc định khi custom DB không tồn tại; provider tắt không làm ẩn log thật. Scanner trả typed completion theo từng source: container/turn array rỗng **không** đủ làm live evidence; thiếu turn array, turn rỗng hoặc identity field sai type/value là semantic failure. Numeric integral như `1.0` được parser và validator hai nền tảng xử lý giống nhau; token/context tối đa 10B, percentage tối đa 100, metering/credit tối đa 1B mỗi turn và mọi aggregate dùng checked arithmetic. Alias token plural/cache chưa có parser contract bị fail-closed thay vì tạo live zero-usage. Partial source không được stamp live/cache.
- `CostHistoryStore.applyWithReceipt` chỉ công bố merged window/freshness sau durable atomic write. Mutation read chỉ tạo document mới khi file thật sự chưa tồn tại; file hiện hữu unreadable/malformed làm receipt fail-closed và không bị ghi đè. Persist failure trả lại persisted window cũ; Claude/Codex/Grok/Kiro/OMP/Pi không phát `live` hoặc advance pricing/counting revision từ state chỉ tồn tại trong memory. Shared schema dùng snake_case `scanned_at`/`counting_revision`/`top_models`, timestamp mili-giây nguyên và day key Gregorian `yyyy-MM-dd` theo múi giờ local; model label non-empty sau trim nhưng giới hạn/control được kiểm trên original Unicode scalars (tối đa 128) ở cả hai nền tảng. Cả hai bản migrate alias camelCase và timestamp macOS cũ có phần lẻ. Reader bị chặn 8 MiB, 32 model/ngày, source/version/future-day/future-scan và đường dẫn symlink/FIFO. Claude cũng không publish/cache hourly live khi daily history chưa persist.
- **52-week Activity Ledger**: Tổng hợp daily token evidence thật từ 400 ngày trong `CostHistoryStore` thành đúng 52 tuần; future/out-of-window evidence bị loại, zero-day có evidence khác missing-day, streak/current/longest tính theo ngày liên tiếp.

#### 3.6.1 Bản Linux (Tauri) — cùng mô hình (2026-08-24)

Bản Linux port nguyên mô hình trên sang Tauri v2 + TypeScript:

- Catalog: `installed_agents.rs` giữ đúng allowlist bounded và kiểm tra mode bit thực thi; visibility lưu ở `localStorage` key `birdnion.agentVisibility`, vẫn chỉ ảnh hưởng hiển thị.
- Sáu nguồn cost giống macOS sau khi thêm `kiro_scanner.rs` (CLI sessions với credit tính phí thật, SQLite v1/v2, archive JSON).
- Kiro giữ bucket tổng hợp `Other` trong daily chart để bảo toàn USD/token, nhưng loại nó khỏi top-model và digest ranking; winner thật được lưu riêng trong `top_models`.
- Cost tách khỏi provider toggle: `enabled_usage_sources()` là hợp của provider đang bật và agent phát hiện được, nên CLI tắt provider vẫn báo chi phí.
- Panel phụ không nằm trong popover 420px mà là cửa sổ Tauri riêng (`panel.html`, 340px, frameless, always-on-top) neo cạnh popover — tương đương NSPanel con bên macOS, giữ nguyên vòng đời hover-transient / click-pin.
- Kiểm chứng chạy ở workflow `linux-build.yml` trên Ubuntu (`cargo test` + `tsc` + bundle). Crate từng không compile do call site chưa theo kịp `target_config_path()`/`target_path()` infallible — đã sửa 2026-08-24; gate local 2026-08-26 xanh `578/578` Rust, `65/65` Node và production build `60` modules.

#### 3.6.2 Quota Agenda MVP (2026-08-30)

- All tab có Quota Agenda theo contract trust-first, dùng `remainingPct` đã normalize từ provider; native-unit / overage chưa nằm trong MVP này.
- Mỗi provider có tối đa một dòng và toàn Agenda chỉ hiện 3 dòng; `+N` mở provider ẩn kế tiếp, còn click một dòng đi thẳng tới provider tab tương ứng.
- Selector ưu tiên window có `resetDate` tương lai gần nhất; nếu không có reset tương lai thì mới rơi về window primary còn lại có `remainingPct` thấp nhất.
- State hiện tại chỉ có `scheduled`, `awaitingRefresh`, `unknown`, và `staleLastKnown`. `scheduled` dùng reset countdown, `awaitingRefresh` che phần trăm hiện tại, `staleLastKnown` giữ last-known và `unknown` giữ số hiện tại nhưng không khẳng định lịch reset.
- Metadata hiển thị source, account và freshness theo kiểu privacy-safe; `hidePersonalInfo` chỉ ẩn account label, không đổi source/freshness.
- macOS dùng `QuotaAgendaProjection.build(...)` và `AllAgentsQuotaSection`; Linux dùng `quota-agenda.ts` + `quota-agenda-section.ts`. `main.ts` refresh đồng thời hai slot ổn định Agenda/Đã cấu hình khi provider hoặc `birdnion-hide-personal-info-changed` đổi, nên agent không bị trùng/mất mà chart cũng không bị rerender.

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

Mỗi scanner Claude/Codex/Grok/Kiro/OMP/Pi trả metadata `included`, `live`, `scannedAt` (`UsageScanConfidence` trên macOS, `UsageReport` trên Linux):

- `live`: scan hiện tại thành công; `history-only`: không live nhưng có lịch sử; `unavailable`: không có cả hai.
- `scannedAt` được lưu cùng cost history dưới key chung `scanned_at` dạng epoch-millisecond integer để vẫn hiển thị freshness khi chu kỳ hiện tại chỉ dùng lịch sử.
- Tab All chỉ cộng nguồn `included`; badge hiển thị trạng thái + freshness. Heatmap dùng token count, không dùng USD làm activity giả.
- Provider refresh thiếu tạm thời `serviceStatus`/`serviceStatusLevel` sẽ kế thừa last-good pair thay vì làm trống UI.

### 4.2 Budget tuần/tháng, forecast và weekly digest

- Budget tổng trong All dùng cùng kỳ `week`/`month`, cộng sáu nguồn local Claude/Codex/Grok/Kiro/OMP/Pi có confidence `included`, rồi linear-project tới cuối kỳ. Không có nguồn included thì hiện “chưa có dữ liệu chi phí”, không tạo trạng thái on-track giả. Budget là local preference; `0`/blank nghĩa là tắt card. Đây không phải billing API.
- **Budget per-source** (sáu nguồn, độc lập với budget tổng): cùng công thức forecast nhưng chỉ cộng daily USD của đúng 1 source. Lưu bằng sáu key `<source>BudgetUSD` trong UserDefaults (macOS) hoặc `birdnion.<source>BudgetUSD` trong localStorage (Linux) — **không** ghi vào provider `settings.json`.
  - Tab Claude/Codex/Grok/Kiro có `ProviderBudgetCard`/`providerBudgetCard`; OMP/Pi không có provider tab nên chỉ có Settings + weekly digest. Card chỉ hiện khi budget > 0: period-to-date, projection, remaining/over và status.
  - Trust rule: provider có `confidence == .unavailable` (không live lẫn không lịch sử) hiện "chưa có dữ liệu chi phí" thay vì tính forecast — không bao giờ hiện on-track (xanh) giả khi thiếu bằng chứng. History-only vẫn tính bình thường.
- Kỳ tuần được pin ISO Monday–Sunday trên hai nền tảng; số ngày đã trôi được tính bằng calendar-day local, không chia giây nên không lệch tại DST.
- Weekly digest mặc định OFF. Cửa sổ hiện tại là hôm nay + 6 ngày trước; cửa sổ so sánh là 7 ngày liền trước đó.
- Digest đi nhờ refresh/tick sẵn có. `lastEvaluatedAt` giới hạn cadence và vẫn được ghi khi suppress/error; `lastSentAt` chỉ ghi sau khi notification thành công.
- Không gửi khi không có live source hoặc tổng USD/token bằng 0. Nếu một phần nguồn không live, notification ghi rõ nguồn dùng cached data.
- Digest macOS dùng cùng kỳ week/month và sáu nguồn local; chỉ cảnh báo budget khi trạng thái là `forecast-over` hoặc `already-over` (không nhắc khi `on-track`), cho cả budget tổng và từng provider có cấu hình riêng. `forecast-over` dùng số dự phóng cuối kỳ; `already-over` dùng số đã chi thực tế trong kỳ.

### 4.3 Usage Insights và cost theo project

- All tab chỉ thêm một compact highlight sau Data Confidence và trước budget; click mở top-level Settings `Insights`, không mở thêm popover/modal chi tiết.
- `Overview` tái sử dụng đúng rolling 7 ngày của Weekly Digest: current/prior, change, top source/model và confidence. Source đã bật nhưng chưa có report được giữ rõ là `unavailable`, không bị loại khỏi coverage. `Projects` có ranking/detail theo 7/30/90 ngày.
- Claude lấy project identity trong cùng lượt quét JSONL: project key luôn là SHA-256 của session-directory token ổn định (`derived`); top-level `cwd` đã verify chỉ nâng display label thành basename an toàn, không đổi key. Store/UI/copy không nhận full path.
- Codex đọc `session_meta.payload.cwd`; Grok dùng token thư mục `sessions/<encoded_cwd>/...` làm identity ổn định và chỉ dùng `summary.json.git_root_dir` để nâng basename hiển thị. Cả hai chỉ persist SHA-256 key + label đã sanitize; phần aggregate thiếu metadata mới được giữ ở residual `Unknown`.
- `project-cost-history.json` là optional/versioned store riêng, high-water và giữ 400 ngày. Day key chỉ nhận canonical `yyyy-MM-dd`; missing/corrupt/write failure không làm hỏng `cost-history.json`, quota, budget hay digest. Projection luôn bị chặn bởi aggregate source/day để project cũ + mới không double-count; Codex conflict rõ ràng phát tombstone có ID SHA-256 và contribution chính xác, áp dụng idempotent để phần đó trở lại `Unknown` mà empty scan bình thường vẫn giữ high-water.

### 4.4 Guided Setup và Action Center

- Classifier chỉ map ba nhóm user-fixable sang target ổn định `setupSource`, `credential`, `cookieSource`; network/rate-limit/schema/unknown chỉ có Retry.
- Guided Setup luôn lưu cấu hình trước. Save fail rollback UI và dừng probe; save thành công mới chạy fetch user-initiated thật. Trạng thái Live cần response không lỗi và có quota window.
- macOS giữ registry task/generation per provider để không cho self-test chồng nhau hoặc completion cũ ghi đè. Error status chỉ ở memory; disk cache chỉ nhận renderable non-error snapshots.
- First Live Checkpoint chỉ áp dụng Claude/Codex/Grok trong Guided Setup. Mỗi lần save-first tạo `attemptId` và mốc thời gian riêng; chỉ explicit probe hiện tại, đúng generation/provider đang chọn, response `id` khớp request, provider còn bật, không lỗi và có quota window mới ghi receipt per-provider. Thay đổi config/account invalidate generation; Codex mutation phát event trước và sau durable commit, listener phải sẵn sàng trước khi pane interactive và được dispose khi pane rời DOM. `liveRenderedAtMs` chỉ được chốt sau AppKit view `draw` trên macOS hoặc hai `requestAnimationFrame` với Live node còn connected **và** cửa sổ Tauri native visible, không minimized, có focus. Failure, cache, background refresh, header self-test hoặc stale completion không tạo/ghi đè receipt trước; store từ chối attempt cũ hơn, bỏ riêng entry hỏng nhưng giữ nguyên toàn bộ blob nếu root corrupt/unreadable. macOS persist bằng atomic UUID journal trên một bound dirfd + `flock`; kết quả là `committed`/`rejected`/`indeterminate`, và trạng thái cuối chỉ hiện cảnh báo trung lập thay vì giả Live hoặc Fail. Load/save chuẩn hoá đúng 9 field allowlist; receipt không nhận token, credential, path hoặc raw error.
- Action Center v1 chỉ project Claude/Codex/Grok đang bật từ cùng detection + current status + stale-warning memory của Guided Setup. Một provider có tối đa một issue; thứ tự `needsSource` → lỗi sửa được → lỗi transient cần Retry, tối đa ba issue.
- Popover chỉ hiện badge count gọn; tab All không thêm card. Chi tiết và CTA nằm trong Settings `Action Center`. Issue tự biến mất khi status thành công/stale được xóa.
- Không có issue database/history, polling loop riêng, raw-error persistence, quota/budget/release item. Trên Linux, main WebView giữ projection và fetch owner; Settings nhận snapshot sanitized qua Tauri event, còn Retry quay về existing per-provider in-flight guard thay vì tạo pipeline mới.

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
| Kỳ budget tổng macOS | `UserDefaults.birdnion.budgetPeriod` (`week`/`month`) | local preference, mặc định `month` |
| Agent visibility/pinning | `UserDefaults.birdnion.agentVisibility.v1.*` | local presentation preference; không mutate provider/config |
| Per-source budget (Claude/Codex/Grok/Kiro/OMP/Pi) | macOS `UserDefaults.<source>BudgetUSD`; Linux local storage `birdnion.<source>BudgetUSD` — không phải provider `settings.json` | local preference |
| Weekly digest toggle/cadence | macOS `weeklyDigest*`; Linux local storage `birdnion.weeklyDigest*` | local preference, default OFF |
| First Live Checkpoint | macOS `Application Support/BirdNion/first-live-checkpoints-v1.json` (migrate key UserDefaults cũ); Linux `localStorage` key `birdnion.firstLiveCheckpoints.v1` | receipt local per-provider; exact-schema normalization, corrupt-root fail-closed, privacy allowlist |

Shared `settings.json` dùng revision monotonic + exact-byte CAS, fixed recovery claim, reader/writer lock và directory-descriptor binding. Lỗi đọc authoritative không được giả thành document revision 0; parent route đổi làm transaction fail-closed. App chỉ đặt `0700` khi tự tạo leaf support directory, không thay mode của parent override đã tồn tại; settings/lock file vẫn `0600`.
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
- [x] `xcodebuild` Release universal clean; full macOS suite `726` tests (`725` pass, `1` live skip, `0` fail) (2026-08-26)
- [x] Local token scanner: 30-day chart for Claude usage
- [x] Data confidence + freshness + last-good service status trên macOS/Linux
- [x] Total monthly budget + linear forecast trên macOS/Linux
- [x] Per-source budget (Claude/Codex/Grok/Kiro/OMP/Pi) + trust-unavailable no false-green trên macOS/Linux
- [x] Adaptive refresh 1×/2×/4×/8×, manual/forced bypass, không timer mới
- [x] Weekly digest rolling 7 ngày, default OFF, trên macOS/Linux
- [x] Usage Insights + Cost by Project trên macOS/Linux: compact All highlight, Settings Overview/Projects 7/30/90, Claude/Codex/Grok privacy key + residual `Unknown`
- [x] First Live Checkpoint trên macOS/Linux: receipt per-provider chỉ từ explicit current probe sau visible paint, exact-schema/corrupt-root fail-closed và không persist secret/raw error
- [x] macOS custom profile quick switch fail-closed; Linux Codex account quota/health snapshot
- [x] Release pipeline (`Scripts/release.sh`) → tap → brew install
- [ ] Windows 10/11 x64/ARM64 native compile, runtime, install, First Live và release integrity; hiện `FLASH_UNVERIFIED`, không public support claim

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
| First Live receipt chỉ từ current explicit probe | Phân biệt setup vừa được chứng minh với cache/last-good/background; giữ receipt cũ khi lần thử mới thất bại |
| Menu-bar visibility toggle per provider | User loại provider không quan tâm khỏi chuỗi % trên menu bar |
| Cask filename: `BirdNion-${version}.zip` (no v prefix) | GitHub release-asset upload cache trả 404 BlobNotFound với `v${version}.zip` |
| Windows evidence tách 4 OS/architecture lanes | Cross-compile, static review hoặc một lane không chứng minh ba lane còn lại; chỉ public claim sau native runtime/install/release receipts |

## 10. Open questions / future

- **Apple Developer Program** ($99/năm) — cần nếu muốn user cài đặt thẳng không cần postflight xattr
- **Codex multi-account** đã có, còn polish UI
- **Sparkle auto-update** — optional, cần server
- **Mac App Store** — nếu muốn mass distribution, cần review process
- **Claude code API key** flow — hiện support Anthropic key, có thể extend cho setup token từ CLI
- **Local memory** — track Anthropic Max weekly + Sonnet daily qua `~/.claude/projects/`
- **Phase 8 còn lại** — CSV/JSON export, Linux custom-profile popover và hoàn tất native evidence/release gates cho Windows port
- **Windows blockers** — native matrix, browser/DPAPI, sidecar artifact/SHA/PE/bundle, installer/upgrade/uninstall và First Live journeys chưa có receipt

## File liên quan

- `docs/build.md` — build, deploy local, release flow
- `docs/development-roadmap.md` — phases đã xong + còn lại
- `Scripts/release.sh` — auto release pipeline
- External: [homebrew-tap](https://github.com/hapo-nghialuu/homebrew-tap) — Cask + releases
