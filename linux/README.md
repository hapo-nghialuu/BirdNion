# BirdNion for Linux (Tauri)

Bản port Linux/Ubuntu của BirdNion — tray app theo dõi usage/cost các AI provider.
Stack: Tauri v2 (Rust core + web UI vanilla TS). Dùng chung schema config
`~/.config/birdnion/settings.json` với bản macOS (copy 1 file config chạy được cả 2 OS).

## Tính năng (parity với macOS)

- [x] Tray icon (Show/Quit, tooltip % quota động), đóng window = ẩn xuống tray
- [x] Tab **All**: tổng cost **Claude + Codex + Grok** — period picker 24h/7/30/90 ngày,
      stacked bars 3 nguồn (màu Grok `#111827`), heatmap 90 ngày (soft greens), top models
- [x] Cost scanners: Claude (`claude_scanner.rs`) + Codex (`codex_scanner.rs`) +
      Grok (`grok_scanner.rs` — `~/.grok/sessions/**/signals.json`)
- [x] **Cost history** high-water (`cost_history.rs` → `~/.config/birdnion/cost-history.json`):
      bar ngày không co khi xóa session local (Claude/Codex/Grok)
- [x] **26 providers** (roster + registry): 23 cũ + **Grok**, **OpenAI** (Admin spend), **Ollama**
- [x] Tab per-provider: quota windows + reset countdown + chart 30 ngày
      (Claude/Codex/Grok) + Claude Admin card khi có admin key
- [x] Settings (section nav): Providers / General / About —
      bật/tắt, API key, cookie, project id (OpenAI), autostart, polling, about/update
- [x] Notifications cảnh báo quota ≤20% + failure episodes, i18n vi/en
- [x] CI: GitHub Actions build .deb/.rpm/AppImage + cargo test
- [x] Copilot Device Flow login trong Settings; Codex multi-account

## Providers mới

| Id | Cách auth | Ghi chú |
|---|---|---|
| `grok` | Zero-config `~/.grok/auth.json` | Quota Grok Build + cost từ signals.json |
| `openai` | `OPENAI_ADMIN_KEY` / API key + Project ID tùy chọn | Org Admin costs — **không** phải ChatGPT/Codex |
| `ollama` | Cookie ollama.com và/hoặc API key | Session/Weekly % |

## Khác biệt đã biết so với macOS

- Cookie: cần trình duyệt Chrome/Chromium/Brave/Edge/Firefox trên Linux (gnome-keyring);
  Safari không tồn tại — có ô "cookie thủ công" trong Settings làm fallback
- Menu-bar percent rotation → tray tooltip (GNOME/KDE không hỗ trợ text cạnh icon tray)
- Global hotkey OS-level: không có (Wayland không ổn định) — trong window dùng **Ctrl+,** mở Settings

## Dev

```bash
npm install
npm run tauri dev            # chạy app (macOS/Linux)
cd src-tauri && cargo test   # unit tests (lib)
```

Build Ubuntu thật: CI `.github/workflows/linux-build.yml` hoặc máy Ubuntu với
`libwebkit2gtk-4.1-dev libayatana-appindicator3-dev librsvg2-dev libxdo-dev`.

Ma trận parity chi tiết: [`docs/linux-parity-matrix.md`](../docs/linux-parity-matrix.md).

## Cài đặt (không cần build)

Tải `.deb`/`.rpm`/`.AppImage` từ [GitHub Releases](https://github.com/hapo-nghialuu/BirdNion/releases)
(CI `linux-release.yml` tự build và đính kèm khi push tag `v*`):

```bash
sudo apt install ./BirdNion_<version>_amd64.deb   # Ubuntu/Debian
# hoặc: sudo dnf install ./BirdNion-<version>-1.x86_64.rpm
# hoặc: chmod +x BirdNion_<version>_amd64.AppImage && ./BirdNion_...AppImage
```

## Kiến trúc

- `src-tauri/src/claude_scanner.rs` / `codex_scanner.rs` / `grok_scanner.rs` — cost scanners
- `src-tauri/src/cost_history.rs` — high-water merge shared với macOS schema
- `src-tauri/src/config.rs` — settings.json reader/writer (schema chung macOS)
- `src-tauri/src/providers/` — 26 provider + `browser_cookies.rs` (rookie) + registry
- `src/` — web UI: `all-tab.ts`, `provider-tab.ts`, `source-chart.ts`, `settings-tab.ts`
  (sections), `i18n.ts`, `usage.ts` (combine 3 nguồn)
