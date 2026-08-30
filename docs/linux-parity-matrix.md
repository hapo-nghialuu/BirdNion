# Linux ↔ macOS parity matrix

Baseline updated 2026-08-26: macOS + Linux after the agent-centric remake — installed-agent catalog, 4-block All tab, side panels, 52-week activity, Kiro as the sixth cost source, First Live Checkpoint và credential/settings race hardening.

Trước đó (2026-08-21): Data Confidence, budget/forecast, profile health, adaptive refresh, weekly digest, per-provider budget, Usage Insights, Guided Setup và Action Center v1.

| Area | macOS | Linux target | Status |
|---|---|---|---|
| Providers roster | 29 ids | 29 ids in registry + Settings ROSTER, gồm cả `xai` | **done** |
| OpenAI Admin/API | OpenAIProvider.swift | `providers/openai.rs` | **done** |
| Ollama cloud | OllamaProvider.swift | `providers/ollama.rs` | **done** |
| Grok quota | GrokProvider.swift | `providers/grok.rs` | **done** |
| Grok cost scanner | GrokCostScanner.swift | `grok_scanner.rs` | **done** — rev 3 chia token theo `events.jsonl` (xem "Quy ngày của Grok") |
| Cost history | CostHistoryStore.swift | `cost_history.rs` (high-water merge) | **done** — model label dùng cùng contract Unicode scalar: non-empty sau trim, tối đa 128 scalar và không control character |
| Usage Insights + project cost | compact All highlight; Settings `Insights` Overview/Projects; `ProjectCostHistoryStore` | compact All highlight; Settings `Insights`; `project_cost_history.rs` + `project_insights.rs` | **done** — Claude/Codex/Grok SHA-256 identity + safe basename; only unattributed residual stays `Unknown` |
| Guided Setup + First Live Checkpoint + Action Center v1 | exact remediation flow; save-first real self-test; AppKit draw acknowledgment; receipt dùng atomic UUID journal + tri-state commit | cùng flow; hai animation frame + native visible/restored/focused; receipt exact-schema/fail-closed | **done** — response id/generation/config-account đều bind đúng attempt; failure/cache/stale completion/root storage hỏng không tạo hoặc ghi đè receipt; commit không xác định hiện cảnh báo trung lập, không giả Live/Fail; không lưu credential/path/token/raw error |
| Data confidence | `UsageScanConfidence` (`included` / `live` / `scannedAt`) + freshness badges | `UsageReport` cùng metadata + freshness badges | **done** |
| Last-good provider status | giữ `serviceStatus`/level khi refresh mới thiếu status | giữ `serviceStatus`/level từ cached status | **done** |
| All-tab local cost aggregate 6 sources | `AllUsageOverview` (Claude/Codex/Grok/Kiro/OMP/Pi) | `usage.ts` + `all-tab.ts` cùng canonical source set | **done** — Kiro nằm trong 24h/30d, top source/model, agent panel, provider chart, digest và budget riêng |
| Total monthly budget + forecast | local `monthlyBudgetUSD`, Claude+Codex+Grok linear forecast | local `birdnion.monthlyBudgetUSD`, cùng scope/logic | **done** |
| Per-source budget (6 nguồn) | `UserDefaults` cho Claude/Codex/Grok/Kiro/OMP/Pi; card trong tab Claude/Codex/Grok/Kiro; OMP/Pi tham gia Settings + digest | `localStorage` cùng 6 key và cùng card/digest scope | **done** — trust-unavailable, không false-green |
| Adaptive refresh | base interval × 1/2/4/8; forced/manual bypass + success reset | cùng multiplier/bypass/reset, dùng tick sẵn có | **done** |
| Weekly digest | rolling 7 ngày, default OFF, partial-data caveat, cảnh báo budget tổng + per-provider chỉ khi forecast-over/already-over | cùng cửa sổ/cadence, default OFF, cùng logic cảnh báo budget | **done** |
| Per-provider cost chart | Claude/Codex/Grok/Kiro cards | `source-chart.ts` + main tab branch cùng 4 nguồn | **done** |
| Quota Agenda MVP | Icon calendar ở footer mở `QuotaAgendaPanelRoot` trong shared `AgentDetailPanelCoordinator`; mở/đóng không đổi tab, chọn dòng đóng panel rồi route provider | `quota-agenda.ts` + `quota-agenda-panel.ts` chạy trong side panel 340px hiện có; main validate provider trước `goTab`, cập nhật theo status/tick/privacy/catalog; All-tab Quota/Configured giữ nguyên | **done** — tối đa 3 dòng + `+N`, percent vẫn là giá trị đã normalize; không thêm poller/backend/storage; native-unit / overage và visual E2E chưa nằm trong receipt MVP |
| Settings structure | multi-tab | section nav: Providers / General / About | **done** |
| Heatmap greens | VocabbyTheme.heat* | `styles.css` soft GitHub greens | **done** |
| Startup fetch | launch-time refresh, per-provider streaming, lazy scans + 5-min cache | first paint before any fetch; per-provider status streaming; scanners `spawn_blocking` + 5-min TTL cache; skeleton + "Đang quét…" hint | **done** |
| Grok brand color | #111827 black | `--grok: #111827` bars/dots/fills | **done** |
| Hotkey global | yes | N/A — Ctrl+, in-window only | **accepted gap** |
| Menu-bar % text | yes | tray tooltip | **accepted gap** |
| Settings provider detail | detailHeader + info grid + usage (pace/credits/cost) + setup + quota-warn card + links | `settings-provider-detail.ts` full port; ProviderStatus mở rộng (plan/version/serviceStatus/sourceLabel/windowSeconds) | **done** |
| Settings Claude Code pane | 2-pane: preset + custom profiles, activation panel + power 76px, scope segmented + folder picker, remove env, token/baseURL, model loader, 1M toggle, paste JSON | `claude-code-pane.ts` + Rust `claudeCodeProfiles` (config flatten giữ key lạ), `claude_code_models` fetcher, profile apply/state commands, tauri-plugin-dialog | **done** |
| Custom Claude/Codex quick switch trong popover | có, kèm ready/stale/active + proxy health; exact-snapshot guard chống activate sau delete/edit | chưa port; Settings quick-apply vẫn có | **accepted gap** |
| Codex account quick switch health | account switcher + quota state | last-good quota/health snapshot thụ động, không polling mới | **done** |
| Codex web extras (Code review %) | WKWebView scrape | không có headless tương đương | **accepted gap** |
| Codex reset-credits row / auto-prime card | CodexResetCreditsAPI + scheduler | chưa port | **gap (todo)** |
| Claude web cost bar + webExtras + multi-account | web cookie enrichment | web source không port enrichment | **accepted gap** |
| Antigravity/Copilot OAuth accounts cards | multi-account store | copilot device-flow có; multi-account chưa | **gap (todo)** |
| Kilo org picker / menu-bar metric pickers | riêng macOS menu bar | tray tooltip không có metric per-provider | **accepted gap** |

## Agent-centric remake (2026-08-23 → 2026-08-24)

| Area | macOS | Linux | Status |
|---|---|---|---|
| Installed-agent catalog | `InstalledAgentCatalog` + `InstalledAgentDetectors` (allowlist bounded) | `installed_agents.rs` — cùng allowlist 16 agent, `is_executable` theo mode bit, không quét đệ quy | **done** |
| Settings tab Agent | `AgentsPane` bảng phẳng + filter pill + cost 90d | `settings-agents.ts` cùng filter/predicate/sort; truyền quota-bearing provider IDs vào catalog backend | **done** — badge/filter quota lấy từ status hiện tại, không rơi về false |
| All tab 4 khối | quota / cost-by / configured / budget | `all-agents-sections.ts` cùng 4 khối | **done** |
| Cost by: mode agent/model/token | 3 mode, đổi theo kỳ đang chọn | `costByMode()` lưu ở `birdnion.costByMode`, cùng 3 mode | **done** |
| Cost source thứ 6 (Kiro) | `KiroCostScanner.swift` (3 thế hệ lưu trữ) | `kiro_scanner.rs` — CLI sessions (credit thật × $0.04), SQLite v1/v2, archive JSON; detector nhận current + legacy + custom XDG markers và scanner fallback DB mặc định khi XDG DB thiếu; TS aggregate dùng cùng canonical source set | **done** — provider off vẫn scan khi storage thật được detect; empty semantic arrays không mint live evidence; thiếu turn array, turn rỗng, field sai type/value, numeric vượt bound hoặc alias token chưa hỗ trợ đều incomplete; checked aggregate không overflow/Inf và không cache/live |
| Cost tách khỏi provider toggle | scan theo agent detected, provider chỉ gate quota/tab/menu bar | `enabled_usage_sources()` hợp provider bật ∪ agent detected | **done** |
| Side panel (hover/pin) | `AgentDetailPanelCoordinator` (NSPanel con 340px) | cửa sổ Tauri `panel.html` 340px, frameless, always-on-top, đặt cạnh popover +4px | **done** |
| Kỳ ngân sách tuần/tháng | mặc định tuần, ẩn card khi chưa cấu hình | `BudgetPeriod` trong `usage.ts`, cùng mặc định và cùng điều kiện ẩn | **done** |
| Heatmap hoạt động 52 tuần | Insights pane grid 52 cột | `insights-activity.ts` cùng grid, tô đậm theo token | **done** |
| Footer luân phiên nguồn | `ActionsList` đổi 5s giữa UPDATED ↔ LIVE/LỊCH SỬ | slot cố định 16px cùng cadence | **done** |
| Logo agent ngoài provider | OhMyPi/Pi/Aider/Amp/Auggie/Goose imageset, qwen dùng mark Alibaba | cùng bộ asset trong `public/logos/` | **done** |
| Action Center | sheet mở từ icon header mỗi pane | `settings-window.ts` cùng cách (không nằm trong sidebar) | **done** |
| Hotkey / menu-bar metric | xem bảng trên | — | **accepted gap** |

## Provider ids (canonical order)

claude, codex, minimax, hapo, openrouter, tryapi, deepseek, zai, elevenlabs, hiyo, deepgram, groq, **grok**, **xai**, **openai**, **ollama**, copilot, kilo, commandcode, freemodel, mimo, alibaba, cursor, gemini, kiro, opencode, opencodego, antigravity, bedrock

## Auth notes (new providers)

| Id | Auth | Notes |
|---|---|---|
| grok | `~/.grok/auth.json` (zero-config) | `grok login` / grok.com session |
| xai | xAI Management API key + Team ID | Team-scoped balance/usage; khác Grok consumer quota |
| openai | Admin API key + optional Project ID | **Not** ChatGPT/Codex OAuth — org spend |
| ollama | Cookie (ollama.com) and/or API key | Session + weekly % from settings page |

## Cost history

Path: `~/.config/birdnion/cost-history.json` (shared schema with macOS).

Never-shrink merge for `claude` / `codex` / `grok` so deleted local sessions keep past daily bars.

Sáu nguồn chi phí cục bộ: `claude`, `codex`, `grok`, `omp`, `pi`, `kiro`.

Schema chung ghi `scanned_at`, `counting_revision`, `top_models` bằng snake_case; timestamp là epoch-millisecond integer và key ngày luôn Gregorian `yyyy-MM-dd` theo timezone local, không phụ thuộc user calendar. Reader hai bên migrate camelCase/timestamp macOS cũ có phần lẻ, chặn file >8 MiB, source/version/cardinality/future timestamp/day sai, symlink và FIFO. Kiro `Other` chỉ là bucket bảo toàn tổng cho chart, không tham gia top-model/digest ranking.

### Quy ngày của Grok (rev 3, 2026-08-25)

Grok chỉ ghi token ở mức **session** — `signals.json` có tổng cả đời, `chat_history.jsonl` không mang usage — nên không thể đo chính xác từng ngày tiêu bao nhiêu.

Rev 2 (cả hai bản) dồn TRỌN tổng cả đời vào **ngày hoạt động cuối**. Sai hai kiểu:

1. Chỉ cần MỞ session là `last_active_at` nhảy sang hôm nay, kéo theo cả chục ngày tích luỹ đổ vào một ngày không hề chạy lượt nào.
2. Khi ngày-hoạt-động-cuối trôi dần, merge không-bao-giờ-giảm giữ lại bản sao ở từng ngày cũ → một session bị đếm nhiều lần. Đo trên máy thật: **6,810,391 token thành 34,346,238, phồng 5.04×**.

Rev 3 chia tổng theo **dòng thời gian của chính session**: `events.jsonl` có `first_token` kèm `ts` cho mỗi lượt model trả lời, dùng số lượt mỗi ngày (theo giờ máy) làm trọng số, largest-remainder để tổng sau khi chia bằng đúng tổng cả đời. Ngày không có lượt nhận đúng 0. Không có `events.jsonl` thì lùi về ngày hoạt động cuối.

Đây là **phân bổ có bằng chứng, không phải số đo**: trọng số là số lượt trả lời, không phải token thật của từng lượt.

Đổi ngữ nghĩa đếm buộc dựng lại lịch sử một lần (Linux `cost_history::apply_and_report_at_counting_revision` + `Document.counting_revision`; macOS `countingRevision` + `replacingSource`), nếu không giá trị high-water cũ sẽ sống mãi.

Các nguồn khác không dính lỗi này: `claude`, `codex`, `omp` đều quy ngày theo timestamp của từng dòng log.

## Verification

`cargo check` từng báo 9 lỗi ở `lib.rs`/`codex_config.rs` và điều đó dễ bị hiểu nhầm là "crate Linux-only nên không build trên macOS". Thực tế crate KHÔNG compile ở đâu cả kể từ khi `target_config_path()`/`target_path()` chuyển sang infallible mà call site không đổi theo. Đã sửa 2026-08-24. Gate local mới nhất 2026-08-26: Rust `578/578`, Node `65/65`, Linux production build `60` modules; tất cả 0 fail.

Kiểm chứng đầy đủ chạy ở `.github/workflows/linux-build.yml` (Ubuntu 22.04, `cargo test` + `tsc --noEmit` + `npm run tauri build`), trigger bằng `workflow_dispatch`. Workflow này cũng từng hỏng từ 2026-07-21 vì `tauri.conf.json` khai báo resource `binaries/cliproxyapi` trong khi thư mục đó bị gitignore và helper build từ repo Go riêng — job nay tạo file stub để verify compile/test/bundle; bản phát hành vẫn đi qua `linux-release.yml` với helper thật kèm checksum.
