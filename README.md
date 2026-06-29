<div align="center">
  <img src="docs/images/logo.png" width="128" alt="BirdNion" />
</div>

# BirdNion 🪶 — every AI quota, in your menu bar.

> Tiny macOS menu-bar app that keeps your AI subscription usage visible. MiniMax, Codex, Claude, Hapo AI Hub, OpenRouter, DeepSeek, z.ai.

[![Latest release](https://img.shields.io/github/v/release/hapo-nghialuu/BirdNion?style=flat-square&color=0a0a0c)](https://github.com/hapo-nghialuu/BirdNion/releases/latest)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-0a0a0c?style=flat-square)](https://github.com/hapo-nghialuu/BirdNion/releases/latest)
[![Homebrew](https://img.shields.io/badge/brew-hapo--nghialuu%2Ftap%2Fbirdnion-orange?style=flat-square)](https://github.com/hapo-nghialuu/homebrew-tap)
[![License: MIT](https://img.shields.io/badge/license-MIT-6e5aff?style=flat-square)](LICENSE)

A focused fork / extension of [CodexBar](https://github.com/steipete/CodexBar)'s "track every AI coding limit" idea, scoped to the **7 providers** (MiniMax, Codex, Claude, Hapo AI Hub, OpenRouter, DeepSeek, z.ai). One status item per provider, popover with usage bars + reset countdowns, local token scanner for Claude, full Claude parity. No Dock icon.

## What you get

> 🪶 **One bird to watch every AI quota — and set up your AI coding tools in a single click.**

- 👀 **Watch** — menu-bar icon rotates through your providers, popover shows per-window usage bars (session / weekly / monthly) with reset countdowns. Never start a long task without knowing when the clock resets.
- 🔌 **One-time setup** — drop a token in Settings → Providers and BirdNion auto-detects CLI sessions for Codex (`~/.codex/auth.json`) and Claude (Keychain `Claude Code-credentials`). No copy-pasting the same OAuth URL 5 times.
- 🧮 **Count the cost** — Claude token usage parsed from `~/.claude/projects/*.jsonl` (today + 30-day) so you know *exactly* what you spent, not just what the API says.
- 🛡 **Secure** — file-based config, no Keychain, no background disk scan, no third-party telemetry. Tokens live in `~/.config/birdnion/settings.json` with `chmod 600`.
- 🪶 **No noise** — no Dock icon, no notifications unless you cross a threshold, no waiting on a slow provider (each tab fills in independently).

## Why

- **Plan around resets.** Per-provider session / weekly / monthly windows with countdowns to the next reset.
- **Cost scans.** Claude token usage parsed from `~/.claude/projects/*.jsonl` (today + 30-day) — exact tokens, approximate USD.
- **Live status.** Status pages (Anthropic, OpenAI, etc.) surfaced as inline pill + icon overlay.
- **Privacy-first.** File-based config (`~/.config/birdnion/settings.json`), no Keychain, no background disk scan, no third-party telemetry.

## Install

### Requirements
- macOS 14+ (Sonoma)
- Apple Silicon or Intel
- ~100 MB disk for the bundle + CodexBarCore SPM checkouts in DerivedData

### Homebrew (recommended)
```bash
brew tap hapo-nghialuu/tap
brew install --cask birdnion
```

The cask's `postflight` step auto-strips the Gatekeeper quarantine flag (BirdNion is ad-hoc signed for free distribution — no Apple Developer account required). If macOS still blocks the first launch, Right-click → Open → Open.

### Update
```bash
brew update && brew upgrade --cask birdnion
```
`brew update` refreshes the tap so the new version is visible, then `upgrade` installs it. Check the installed version with:
```bash
brew info --cask birdnion
```

### GitHub Releases
Pre-built `.app` bundles are published at
[hapo-nghialuu/BirdNion/releases](https://github.com/hapo-nghialuu/BirdNion/releases). Each release includes:
- `BirdNion-<version>.zip` — ad-hoc-signed universal binary
- SHA256 next to the asset for verification
- Release notes (changelog-style)

### Build from source
```bash
git clone https://github.com/hapo-nghialuu/BirdNion.git
cd BirdNion
open BirdNion.xcodeproj   # or: xcodebuild ...
```
First build pulls the local [CodexBarCore](https://github.com/hapo-nghialuu/CodexBar) SPM at `~/Desktop/CodexBar` — see [docs/build.md](docs/build.md) for the full setup.

## First run

1. Open the menu-bar icon (bird / provider logo). If no providers are enabled, the popover shows an empty-state with a CTA → Settings.
2. **Settings → Providers** lists every provider with a checkbox. Toggle on what you use.
3. For each enabled provider, paste the relevant token in the detail pane (right side):
   - **API-key providers** (MiniMax, OpenRouter, DeepSeek, z.ai, Hapo): paste in the Token field.
   - **Codex**: zero-config — BirdNion reads `~/.codex/auth.json` (set up by `codex` CLI).
   - **Claude**: zero-config — BirdNion reads the OAuth token from the `Claude Code-credentials` Keychain item (set up by `claude` CLI).
4. Quota starts polling immediately on the next refresh cycle (default 120 s, configurable per-provider).

## Providers

| id | Service | Auth | Source |
|---|---|---|---|
| `minimax` | MiniMax Coding Plan | bearer token (Settings pane) | `GET /v1/token_plan/remains` |
| `codex` | OpenAI Codex | OAuth (read `~/.codex/auth.json`) | `GET backend-api/usage` |
| `hapo` | Hapo AI Hub | bearer token | `GET <HAPO_BASE_URL>/v1/budget/week` (+ `/v1/me` for identity) |
| `claude` | Anthropic Claude | OAuth (read `Claude Code-credentials` from Keychain) + browser cookies for cost | `GET /api/oauth/usage` + `claude.ai/api/*` (cost + email + org) |
| `openrouter` | OpenRouter | bearer token | `GET /auth/key` + `/generation` |
| `deepseek` | DeepSeek | bearer token | `GET /user/balance` |
| `zai` | z.ai / GLM Coding Plan | bearer token | `GET /api/paas/v4/quota/limit` (global) or `open.bigmodel.cn/.../quota/limit` (cn) |

### Claude full parity

The Claude panel matches CodexBar's Claude surface, including:
- **4 windows**: 5-hour, weekly, Opus-only weekly, Sonnet-only weekly (each with reset countdown).
- **Extra usage**: monthly `costProvider()` snapshot from the claude.ai billing API.
- **Account identity**: `accountEmail` + `accountOrganization` + `loginMethod` from `claude.ai/api/account`.
- **Source routing**: `auto / oauth / web / cli / api` (OAuth API / Web cookies / `claude` CLI / Admin API) — CodexBar-style planner falls back across sources on failure.
- **Local cost scan**: `ClaudeCostScanner` parses `~/.claude/projects/*.jsonl` to compute today + 30-day token cost (per-day bars + top-model line).

## Features

- **Multi-provider menu bar** — one menu-bar item per provider, rotating frames. Per-provider show/hide toggle (Settings popover).
- **Quota windows** with reset countdowns, color-coded progress bars, per-window labels.
- **Per-provider refresh interval** — default 120 s, overridable per provider (30 s / 1 m / 2 m / 5 m / 10 m / 30 m) in Settings popover.
- **Progressive rendering** — each tab fills in as its fetch returns; the slowest provider never blocks the others.
- **Last-known data preserved** while a refresh is in flight — no flash to empty placeholders.
- **Per-provider loading state** — placeholder row + inline spinner; once data lands, the row swaps in.
- **Settings sidebar** with search, active-first sort, drag-to-reorder, per-provider checkbox.
- **Quota warnings** — notifications when a window's remaining % drops below a threshold (UserDefaults-configurable, default 50 % + 20 %).
- **Menu-bar rotation** cycles bird → enabled providers → bird, refreshes every 3 s per frame.
- **Claude 30-day cost chart** — `~/.claude/projects/*.jsonl` scanned once (5 min cache) and rendered as per-day USD bars + top-model line.
- **Ad-hoc signed** with `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` so the Finder / Dock icon shows the blue bird. No code signing required for distribution.

## Storage

| Data | Location | Format |
|---|---|---|
| API tokens + provider enable flags + per-provider metadata | `~/.config/birdnion/settings.json` (XDG; legacy `~/.birdnion/settings.json`) | single JSON file, `chmod 600` |
| Codex OAuth | `~/.codex/auth.json` | owned by `codex` CLI, BirdNion reads only |
| Claude OAuth | macOS Keychain `service: Claude Code-credentials` | owned by Claude Code app, BirdNion reads only |
| Per-provider menu-bar visibility | `UserDefaults.menuBarVisibility.<id>` | standard |
| Per-provider refresh interval | `UserDefaults.refreshInterval.<id>` | standard |
| General settings (refresh, language, ...) | `UserDefaults` (key prefix = bundle id) | standard |
| App icon | baked into `Assets.car` at build time | — |

Path priority for the config file (mirrors CodexBar):
1. `$BIRDNION_CONFIG` (full path override)
2. `$XDG_CONFIG_HOME/birdnion/settings.json`
3. `~/.config/birdnion/settings.json`
4. `~/.birdnion/settings.json` (legacy)

API keys in the Settings UI render masked: `fe_oa_••••4a8`.

## Privacy note

- No background disk scan. BirdNion reads a small, fixed set of locations only when the related feature is enabled (`~/.claude/projects/` for Claude cost, `~/.codex/auth.json` for Codex, browser cookie stores only when the user enables web-mode Claude).
- No Keychain reads for app config (we're file-based).
- No outbound telemetry. No analytics SDKs. No third-party network calls except the provider APIs themselves.
- All provider API tokens live in `~/.config/birdnion/settings.json` with `chmod 600`.

## macOS permissions

- **Full Disk Access** — *not* required. We use a fixed allowlist of well-known paths and browser cookie stores, not a full filesystem scan.
- **Keychain access** — Claude OAuth reads the `Claude Code-credentials` item that the Claude CLI already created. macOS may prompt the first time; click **Always Allow** to suppress future prompts. If "Always Allow" doesn't stick (e.g., after a Claude Code update), open the item in **Keychain Access.app** → **Access Control** → add `BirdNion.app` to the always-allow list.
- **Browser cookie prompts** — Claude web mode reads Safari / Chrome / Brave cookie stores via `SweetCookieKit`. First-time decrypt may trigger a Chrome / Brave Safe Storage keychain prompt; allow once.
- **Automation / Accessibility / Screen Recording** — *not* requested.

## Docs

- [docs/build.md](docs/build.md) — full build / deploy / release flow, env-var reference, troubleshooting, signing notes
- [docs/system-architecture.md](docs/system-architecture.md) — provider data model, refresh loop, storage layout, UI structure, decision register
- [docs/development-roadmap.md](docs/development-roadmap.md) — phase history, current status, backlog

## Development

Requires macOS 14+ and Xcode 16+.

```bash
# Build + run the test suite
xcodebuild test -project BirdNion.xcodeproj -scheme BirdNion \
  -configuration Debug -destination 'platform=macOS'

# Build a Release .app (lands in build/DerivedData/...)
xcodebuild build -project BirdNion.xcodeproj -scheme BirdNion \
  -configuration Release -destination 'platform=macOS'

# Cut a release end-to-end (build + zip + upload + cask bump)
Scripts/release.sh 0.3.0

# Same, but only print what would happen
Scripts/release.sh 0.3.0 --dry-run
```

The release script: bumps `CFBundleShortVersionString` + `MARKETING_VERSION`, builds Release, packages `BirdNion-<version>.zip`, uploads to the GitHub release, updates the cask's SHA, and pushes the tap. Filename uses `BirdNion-<version>.zip` (no `v` prefix) to work around a GitHub release-asset cache that returns `BlobNotFound` on re-upload of `v<version>.zip` names.

## Architecture (TL;DR)

- **`BirdNion/Services/QuotaService.swift`** — `@MainActor` polling loop, `@Published statuses` + `displayStatuses`, progressive publishing, per-provider throttle, last-known data preservation.
- **`BirdNion/Services/BirdNionConfigStore.swift`** — single source of truth for tokens / enable flags / metadata. Path resolution (`BIRDNION_CONFIG` → XDG → legacy), `chmod 600` on save, Codable round-trip.
- **`BirdNion/Providers/QuotaProvider.swift`** — minimal protocol (`id`, `displayName`, `fetch()`). No `Foundation` import so the contract is testable in isolation.
- **`BirdNion/Providers/ClaudeProvider.swift`** — source-routing dispatcher (auto / oauth / web / cli / api), 12 s cap on the whole `fetch()` so a hung Anthropic endpoint can't block other providers' refreshes.
- **`BirdNion/Providers/Claude/ClaudeCostScanner.swift`** — local jsonl scanner, 30-day buckets + top-model vote count.
- **`BirdNion/Views/QuotaPanel.swift`** — popover: tabs, header card (with inline "updating" indicator), provider card (windows), Claude 30-day chart, actions list.
- **`BirdNion/Views/Settings/ProvidersPane.swift`** — sidebar (search + active-first sort + drag-to-reorder + checkbox) + detail pane (token / source pickers / refresh interval / menu-bar visibility).
- **`BirdNion/AppDelegate.swift`** + **`DropdownPanel`** — borderless NSPanel for the popover (no NSPopover triangle), NSStatusItem with a per-provider rotating frame.

See [docs/system-architecture.md](docs/system-architecture.md) for the full data flow + decision register.

## Why a fork / why this exists

[CodexBar](https://github.com/steipete/CodexBar) tracks 53+ providers and is the obvious upstream. BirdNion exists as a focused build for a small fixed set of 7 providers, with:
- A file-based config (no Keychain prompts) — different from CodexBar's Keychain + `~/Library/Application Support` split.
- Claude deep-parity on its own (CodexBar's Claude surface is wider but shipped behind more flags).
- A `Scripts/release.sh` end-to-end pipeline instead of manual steps.
- Distribution via a personal Homebrew tap without an Apple Developer account.

Reused from CodexBar (via the local `CodexBarCore` SPM):
- `ClaudeWebAPIFetcher` + browser cookie auto-detect (Safari / Chrome / Brave via `SweetCookieKit`).
- `ClaudeStatusProbe` (PTY-based `claude` CLI fallback).
- `RateWindow`, `ProviderCostSnapshot`, `ClaudeUsageFetcher` data types.

## Related

- [CodexBar](https://github.com/steipete/CodexBar) — the upstream this fork draws on. 53+ providers, App Store version, macOS-native, MIT.
- [ccusage](https://github.com/ryoppippi/ccusage) — Claude Code cost-usage CLI (MIT). BirdNion's local `ClaudeCostScanner` reads the same `~/.claude/projects/*.jsonl` files.

## License

MIT.
