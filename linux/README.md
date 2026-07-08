# BirdNion for Linux (Tauri)

Bản port Linux/Ubuntu của BirdNion — tray app theo dõi usage/cost các AI provider.
Stack: Tauri v2 (Rust core + web UI vanilla TS). Dùng chung schema config
`~/.config/birdnion/settings.json` với bản macOS (copy 1 file config chạy được cả 2 OS).

## Tính năng (parity với macOS)

- [x] Tray icon (Show/Quit, tooltip % quota động), đóng window = ẩn xuống tray
- [x] Tab **All**: tổng cost Claude Code CLI + Codex — period picker 24h/7/30/90 ngày,
      stacked bars theo nguồn, heatmap 90 ngày clickable (peak/avg/streak), top models
- [x] Cost scanner: Claude (`claude_scanner.rs`, port 1:1 semantics) +
      Codex (`codex_scanner.rs`, parse rollout jsonl + bảng giá CodexBar, lệch <3%)
- [x] **23/23 providers**: 10 API-key (openrouter, deepseek, zai, minimax, hapo,
      elevenlabs, deepgram, groq, kiro, bedrock-SigV4) + 5 CLI/OAuth (codex, claude,
      gemini, kilo, antigravity) + 8 cookie-based qua `rookie` (opencode, opencodego,
      commandcode, cursor, mimo, alibaba, freemodel, copilot)
- [x] Tab per-provider: quota windows + reset countdown + chart 30 ngày (Claude/Codex)
- [x] Settings: bật/tắt provider, API key, cookie thủ công, autostart — ghi settings.json (0600)
- [x] Notifications cảnh báo quota ≤20% (libnotify), i18n vi/en
- [x] CI: GitHub Actions build .deb/.rpm/AppImage trên ubuntu-22.04 + cargo test
- [x] Claude Admin API org dashboard (card 30 ngày trên tab Claude khi có admin key)
- [x] Copilot Device Flow login ngay trong Settings (mã + link GitHub + polling)

## Khác biệt đã biết so với macOS

- Cookie: cần trình duyệt Chrome/Chromium/Brave/Edge/Firefox trên Linux (gnome-keyring);
  Safari không tồn tại — có ô "cookie thủ công" trong Settings làm fallback
- Menu-bar percent rotation → tray tooltip (GNOME/KDE không hỗ trợ text cạnh icon tray)

## Dev

```bash
npm install
npm run tauri dev            # chạy app (macOS/Linux)
cd src-tauri && cargo test   # 162 unit tests
```

Build Ubuntu thật: CI `.github/workflows/linux-build.yml` hoặc máy Ubuntu với
`libwebkit2gtk-4.1-dev libayatana-appindicator3-dev librsvg2-dev libxdo-dev`.

## Cài đặt (không cần build)

Tải `.deb`/`.rpm`/`.AppImage` từ [GitHub Releases](https://github.com/hapo-nghialuu/BirdNion/releases)
(CI `linux-release.yml` tự build và đính kèm khi push tag `v*`):

```bash
sudo apt install ./BirdNion_<version>_amd64.deb   # Ubuntu/Debian
# hoặc: sudo dnf install ./BirdNion-<version>-1.x86_64.rpm
# hoặc: chmod +x BirdNion_<version>_amd64.AppImage && ./BirdNion_...AppImage
```

## Kiến trúc

- `src-tauri/src/claude_scanner.rs` / `codex_scanner.rs` — cost scanners (90d daily,
  strict 30d totals, 24h hourly)
- `src-tauri/src/config.rs` — settings.json reader/writer (schema chung macOS)
- `src-tauri/src/providers/` — 23 provider + `browser_cookies.rs` (rookie) +
  registry `mod.rs` fetch concurrent
- `src/` — web UI: `all-tab.ts` (chart/heatmap/models), `provider-tab.ts` (quota),
  `settings-tab.ts`, `i18n.ts` (vi/en), `usage.ts` (combine + format)
