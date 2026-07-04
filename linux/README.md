# BirdNion for Linux (Tauri)

Bản port Linux/Ubuntu của BirdNion — tray app theo dõi usage/cost các AI provider.
Stack: Tauri v2 (Rust core + web UI vanilla TS). Dùng chung schema config
`~/.config/birdnion/settings.json` với bản macOS.

## Trạng thái

- [x] Phase 0 — skeleton: tray icon (Show/Quit), window 420pt, đóng window = ẩn xuống tray
- [x] Phase 1 (một phần) — Claude Code CLI cost scanner (`src-tauri/src/claude_scanner.rs`,
      port 1:1 từ `BirdNion/Providers/Claude/ClaudeCostScanner.swift`: dedup, pricing,
      daily 90d + totals 30d + hourly 24h) + UI overview cơ bản
- [ ] Codex cost scanner (parse `~/.codex/sessions` rollout jsonl)
- [ ] Tab All đầy đủ (stacked chart, heatmap, top models, period picker)
- [ ] Providers API-key (10) → CLI/OAuth (5) → cookie-based (8, dùng crate `rookie`)
- [ ] Notifications (libnotify), autostart, i18n vi/en, đóng gói .deb/AppImage

## Dev

```bash
npm install
npm run tauri dev        # chạy app (macOS/Linux đều được)
cd src-tauri && cargo test   # test logic scanner
```

Build Linux thật cần Ubuntu với `libwebkit2gtk-4.1-dev libappindicator3-dev librsvg2-dev`.
