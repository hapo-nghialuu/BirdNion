# Linux ↔ macOS parity matrix

Baseline: macOS BirdNion after Grok / OpenAI / Ollama / cost-history (2026-07-11).

| Area | macOS | Linux target | Status |
|---|---|---|---|
| Providers roster | 26 ids | 26 ids in registry + settings ROSTER | **done** |
| OpenAI Admin/API | OpenAIProvider.swift | `providers/openai.rs` | **done** |
| Ollama cloud | OllamaProvider.swift | `providers/ollama.rs` | **done** |
| Grok quota | GrokProvider.swift | `providers/grok.rs` | **done** |
| Grok cost scanner | GrokCostScanner.swift | `grok_scanner.rs` | **done** |
| Cost history | CostHistoryStore.swift | `cost_history.rs` (high-water merge) | **done** |
| All tab 3 sources | AllUsageOverview | `usage.ts` + `all-tab.ts` (Claude/Codex/Grok) | **done** |
| Per-provider cost chart | Claude/Codex/Grok cards | `source-chart.ts` + main tab branch | **done** |
| Settings structure | multi-tab | section nav: Providers / General / About | **done** |
| Heatmap greens | VocabbyTheme.heat* | `styles.css` soft GitHub greens | **done** |
| Startup fetch | launch-time refresh, per-provider streaming, lazy scans + 5-min cache | first paint before any fetch; per-provider status streaming; scanners `spawn_blocking` + 5-min TTL cache; skeleton + "Đang quét…" hint | **done** |
| Grok brand color | #111827 black | `--grok: #111827` bars/dots/fills | **done** |
| Hotkey global | yes | N/A — Ctrl+, in-window only | **accepted gap** |
| Menu-bar % text | yes | tray tooltip | **accepted gap** |
| Settings provider detail | detailHeader + info grid + usage (pace/credits/cost) + setup + quota-warn card + links | `settings-provider-detail.ts` full port; ProviderStatus mở rộng (plan/version/serviceStatus/sourceLabel/windowSeconds) | **done** |
| Settings Claude Code pane | 2-pane: preset + custom profiles, activation panel + power 76px, scope segmented + folder picker, remove env, token/baseURL, model loader, 1M toggle, paste JSON | `claude-code-pane.ts` + Rust `claudeCodeProfiles` (config flatten giữ key lạ), `claude_code_models` fetcher, profile apply/state commands, tauri-plugin-dialog | **done** |
| Codex web extras (Code review %) | WKWebView scrape | không có headless tương đương | **accepted gap** |
| Codex reset-credits row / auto-prime card | CodexResetCreditsAPI + scheduler | chưa port | **gap (todo)** |
| Claude web cost bar + webExtras + multi-account | web cookie enrichment | web source không port enrichment | **accepted gap** |
| Antigravity/Copilot OAuth accounts cards | multi-account store | copilot device-flow có; multi-account chưa | **gap (todo)** |
| Kilo org picker / menu-bar metric pickers | riêng macOS menu bar | tray tooltip không có metric per-provider | **accepted gap** |

## Provider ids (canonical order)

claude, codex, minimax, hapo, openrouter, deepseek, zai, elevenlabs, deepgram, groq, **grok**, **openai**, **ollama**, copilot, kilo, commandcode, freemodel, mimo, alibaba, cursor, gemini, kiro, opencode, opencodego, antigravity, bedrock

## Auth notes (new providers)

| Id | Auth | Notes |
|---|---|---|
| grok | `~/.grok/auth.json` (zero-config) | `grok login` / grok.com session |
| openai | Admin API key + optional Project ID | **Not** ChatGPT/Codex OAuth — org spend |
| ollama | Cookie (ollama.com) and/or API key | Session + weekly % from settings page |

## Cost history

Path: `~/.config/birdnion/cost-history.json` (shared schema with macOS).

Never-shrink merge for `claude` / `codex` / `grok` so deleted local sessions keep past daily bars.
