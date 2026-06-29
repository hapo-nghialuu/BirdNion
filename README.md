<div align="center">
  <img src="docs/images/logo.png" width="128" alt="BirdNion" />
</div>

# BirdNion - May your AI agents stay in budget.

> Every AI coding quota and agent setting, in your macOS menu bar.

[![Latest release](https://img.shields.io/github/v/release/hapo-nghialuu/BirdNion?style=flat-square&color=0a0a0c)](https://github.com/hapo-nghialuu/BirdNion/releases/latest)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-0a0a0c?style=flat-square)](https://github.com/hapo-nghialuu/BirdNion/releases/latest)
[![Homebrew](https://img.shields.io/badge/brew-hapo--nghialuu%2Ftap%2Fbirdnion-orange?style=flat-square)](https://github.com/hapo-nghialuu/homebrew-tap)
[![License: MIT](https://img.shields.io/badge/license-MIT-6e5aff?style=flat-square)](LICENSE)

23 providers. Tiny macOS 14+ menu-bar app that keeps AI coding limits visible, shows when each window resets, and centralizes the settings that decide how each coding agent is read. Codex, Claude, MiniMax, Hapo AI Hub, OpenRouter, DeepSeek, z.ai, ElevenLabs, Deepgram, Groq, GitHub Copilot, Kilo, Command Code, Xiaomi MiMo, Alibaba/Qwen, Cursor, Gemini, Kiro, OpenCode, OpenCode Go, Antigravity, AWS Bedrock, and FreeModel. No Dock icon, minimal UI, dynamic provider icons.

BirdNion is inspired by [CodexBar](https://github.com/steipete/CodexBar). It reuses a vendored, trimmed `CodexBarCore` subset while staying focused on BirdNion's provider set, Hapo workflows, Homebrew distribution, and future agent-settings control.

## Why

- **Plan around resets.** Per-provider 5-hour, weekly, monthly, credit, and budget windows with reset countdowns.
- **See spend and cost.** Claude local JSONL scans, Claude Admin API charts, Codex credits, OpenRouter balances, Bedrock budgets, and provider-specific cost/credit summaries where available.
- **Configure agent sources.** Pick OAuth, CLI, browser cookies, API keys, AWS credentials, local app files, or provider apps from Settings per provider.
- **Keep the menu bar useful.** Provider icons rotate in the bar; Kiro, Codex, Gemini, Bedrock, and other providers can choose which metric appears.
- **Privacy-first.** BirdNion reuses existing sessions and explicit config. It does not store passwords or crawl your disk.

## Install

### Requirements

- macOS 14+ (Sonoma)

### GitHub Releases

Download pre-built bundles from [GitHub Releases](https://github.com/hapo-nghialuu/BirdNion/releases):

- `BirdNion-<version>.zip` - universal macOS app, ad-hoc signed.
- SHA256 is used by the Homebrew cask.
- The cask postflight removes the Gatekeeper quarantine flag from the staged app. If macOS still blocks the first launch, use Right-click -> Open.

### Homebrew

Recommended Homebrew 6 Tap Trust flow:

```bash
brew install --cask hapo-nghialuu/tap/birdnion
```

The fully-qualified command explicitly selects `hapo-nghialuu/tap/birdnion`, so a separate `brew tap` step is not required.

Short-name flow after tapping:

```bash
brew tap hapo-nghialuu/tap
brew trust --cask hapo-nghialuu/tap/birdnion
brew install --cask birdnion
```

Or trust the whole tap:

```bash
brew trust hapo-nghialuu/tap
brew install --cask birdnion
```

Do not use `HOMEBREW_NO_REQUIRE_TAP_TRUST=1` as the normal install path. It is a user-side environment override and cannot be placed inside `Casks/birdnion.rb` to bypass trust before Homebrew loads the cask.

### Update

```bash
brew update
brew upgrade --cask birdnion
brew info --cask birdnion
```

### First run

- Open BirdNion from the menu bar.
- Open Settings -> Providers and enable what you use.
- Install or sign in to the provider sources you rely on: CLIs, browser sessions, OAuth/device flow, API keys, local app files, or cloud credentials depending on the provider.
- Optional: set provider account labels, menu-bar visibility, refresh intervals, cookie source, region, AWS auth mode, Kilo org scope, Copilot enterprise host, Hapo Base URL, or provider-specific menu-bar metric.

## Agent Settings Config

BirdNion is meant to become a lightweight settings/config console for AI coding agents, not only a quota viewer.

What exists today:

- Provider enablement, order, account labels, refresh intervals, and menu-bar visibility.
- Source selectors for providers that can read from OAuth, CLI, browser cookies, Admin API, or local app state.
- Provider-specific settings for cookie mode, manual cookie headers, MiniMax/z.ai/Alibaba regions, AWS keys/profile/region, Deepgram Project ID, Kilo organization scope, Copilot enterprise host, Hapo Base URL, and menu-bar metric selection.
- Local session discovery for agents that own their auth state: Claude Code, Codex CLI, Gemini CLI, Kiro, Cursor, Antigravity, and similar tools.

Planned direction:

- Manage coding-agent config profiles from Settings, not just quota tokens.
- Surface login/source health for each agent.
- Validate local config paths and CLI availability.
- Provide bootstrap hints for Claude Code, Codex CLI, Gemini CLI, Kiro, and future agents.
- Keep BirdNion preferences in BirdNion's config layer while leaving each agent's credential store untouched.

## Providers

- **Codex** - OAuth API from `~/.codex/auth.json`, API-key fallback, local `codex app-server` fallback, service status, version, credits, reset credits, and optional OpenAI web extras.
- **Claude** - OAuth API, browser cookies, CLI, or Admin API; 5-hour/weekly/Opus/Sonnet windows, local cost scans, web extras, and admin 30-day chart.
- **MiniMax** - API token, environment token, or cookie fallback for coding-plan usage, plan name, points/subscription, and global/CN region.
- **Hapo AI Hub** - Config token plus custom Base URL for weekly budget and best-effort `/v1/me` identity.
- **OpenRouter** - API token for prepaid credits plus optional per-key spending limit.
- **DeepSeek** - API token for USD/CNY balance with paid/granted split and low-balance warning.
- **z.ai** - API token with global/CN region for quota limits and computed remaining percentage.
- **ElevenLabs** - API key for character credits, voice slots, professional voices, plan, and subscription status.
- **Deepgram** - API key with optional Project ID for usage summaries and aggregate-all-project mode.
- **Groq** - API key for Prometheus-backed request, token, and cache-hit metrics.
- **GitHub Copilot** - GitHub Device Flow or PAT fallback, enterprise host, premium usage, username, and budget extras via web cookies.
- **Kilo** - API token or CLI session, Kilo organization scope, credits, and auto top-up details.
- **Kiro** - CLI-based usage, credits/overage data, and 9 menu-bar display modes.
- **Command Code** - Browser or manual cookies for billing credits and plan catalog.
- **Xiaomi MiMo** - Browser cookies for balance, token-plan details, and usage.
- **Alibaba/Qwen** - Browser cookies plus intl/CN region for coding-plan and token-plan windows.
- **Cursor** - Cursor `state.vscdb` first, browser cookies as fallback, usage summary, identity, and request usage.
- **Gemini** - Gemini CLI OAuth credentials from `~/.gemini/oauth_creds.json` for Cloud Code Assist quota tiers.
- **OpenCode** - Browser cookies for rolling/weekly usage and subscription renewal.
- **OpenCode Go** - Browser cookies plus Go workspace page for rolling/weekly/monthly usage and Zen balance.
- **Antigravity** - Local process/CLI probe and Google OAuth account store for quota buckets and account-matched data.
- **AWS Bedrock** - AWS access keys or named profile, region, budget fields, and CloudWatch/Cost usage.
- **FreeModel** - Browser cookie from `freemodel.dev` for 5-hour and weekly dollar budgets.

Open to more providers when they fit the existing `QuotaProvider` model.

## Icon & Screenshot

The menu-bar icon is a tiny rotating quota meter. Provider frames use each provider's logo and the selected usage metric; loading/error states stay visible instead of silently disappearing.

![BirdNion preview](docs/social.png)

## Features

- Multi-provider menu bar with provider toggles and drag-to-reorder Settings.
- Provider-specific usage meters with reset countdowns.
- Progressive refresh: each provider publishes as soon as its fetch completes.
- Last-known data stays visible while refreshes are in flight.
- Provider source selectors for OAuth, CLI, web cookies, Admin API, local app state, and static keys.
- Per-provider refresh intervals and menu-bar visibility.
- Cookie-source picker with Auto, Manual, and Off modes for cookie-backed providers.
- Claude local cost chart from `~/.claude/projects/*.jsonl`.
- Claude Admin API 30-day chart and Codex web dashboard extras where enabled.
- Kiro custom menu-bar values: credits left, percent, used/total, and overage modes.
- Quota warning notifications via UserDefaults-configurable thresholds.
- XDG config file with restrictive permissions.

## Config And Storage

| Data | Location |
|---|---|
| Provider list, enabled flags, API keys, region, budget, project ID, base URL, account label | `~/.config/birdnion/settings.json` |
| Config override | `$BIRDNION_CONFIG` |
| XDG override | `$XDG_CONFIG_HOME/birdnion/settings.json` |
| Legacy config | `~/.birdnion/settings.json` |
| Codex OAuth | `~/.codex/auth.json`, owned by Codex CLI |
| Claude OAuth | macOS Keychain item `Claude Code-credentials`, owned by Claude Code/CLI |
| Gemini OAuth | `~/.gemini/oauth_creds.json` |
| Cursor session | `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` |
| Antigravity OAuth accounts | `~/.config/birdnion/antigravity-oauth.json` |
| Copilot OAuth accounts | `~/.config/birdnion/copilot-accounts.json` |
| Browser/manual cookie source | `UserDefaults` keys `<providerID>CookieSource`, `<providerID>ManualCookie` |
| Menu-bar visibility | `UserDefaults.menuBarVisibility.<id>` |
| Per-provider refresh interval | `UserDefaults.refreshInterval.<id>` |

Config path priority:

1. `$BIRDNION_CONFIG`
2. `$XDG_CONFIG_HOME/birdnion/settings.json`
3. `~/.config/birdnion/settings.json`
4. `~/.birdnion/settings.json`

The config file is written atomically and set to permission `0600`.

## Privacy Note

BirdNion does not crawl your filesystem. It reads a small set of known locations only when the related provider/source is enabled: provider config files, CLI auth files, browser cookie stores, local IDE databases, and Claude JSONL logs. Provider tokens live in the BirdNion config file with restrictive permissions. OAuth, Keychain, and CLI session files remain owned by their original tools.

No passwords are stored. Browser cookies are reused only when the user chooses a cookie-backed source.

## macOS Permissions

- **Full Disk Access** - not required for the core app. Browser-cookie providers may need additional macOS access depending on the browser and cookie store.
- **Keychain access** - Claude OAuth may read the `Claude Code-credentials` item owned by Claude Code/CLI; browser cookie import may also trigger browser Safe Storage keychain prompts.
- **Files & Folders prompts** - local provider probes can trigger macOS prompts if the underlying CLI/helper touches protected locations.
- **What BirdNion does not request in the background** - no Screen Recording or Accessibility permission.

## Docs

- [docs/build.md](docs/build.md) - build, release, signing, troubleshooting.
- [docs/system-architecture.md](docs/system-architecture.md) - system architecture and historical decision log.
- [docs/development-roadmap.md](docs/development-roadmap.md) - historical roadmap.
- [docs/provider-parity/README.md](docs/provider-parity/README.md) - BirdNion vs CodexBar parity audit.

## Getting Started (Dev)

- Clone the repo and open it in Xcode.
- Launch once, then toggle providers in Settings -> Providers.
- Install or sign in to the provider sources you rely on: CLIs, browser cookies, OAuth/device flow, API keys, provider apps, or local config files.
- Optional: set OpenAI cookies for Codex dashboard extras and Claude source routing for OAuth/Web/CLI/Admin API.

## Build From Source

Requires macOS 14+ and Xcode with Swift support for the project scheme.

```bash
xcodebuild test -project BirdNion.xcodeproj -scheme BirdNion \
  -configuration Debug -destination 'platform=macOS'

xcodebuild build -project BirdNion.xcodeproj -scheme BirdNion \
  -configuration Release -destination 'platform=macOS'
```

BirdNion vendors a trimmed `CodexBarCore` package in `Vendor/CodexBar`; no external `~/Desktop/CodexBar` checkout is required.

## Release Flow

```bash
Scripts/release.sh 0.5.3
Scripts/release.sh 0.5.3 --dry-run
```

The release script verifies a clean tree, bumps app versions, builds Release, zips `BirdNion-<version>.zip`, uploads `v<version>` to GitHub Releases, updates `Casks/birdnion.rb`, then updates `hapo-nghialuu/homebrew-tap/Casks/birdnion.rb`.

## Credits

Inspired by [CodexBar](https://github.com/steipete/CodexBar), especially the idea of keeping every AI coding limit visible from the menu bar. BirdNion vendors a trimmed `CodexBarCore` subset and keeps its own focused provider/config surface.

## License

MIT.
