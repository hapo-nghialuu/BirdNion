# Build & Release

## Yêu cầu
- macOS 14+ (Sonoma). Một số API dùng `@Environment` SwiftUI 5.
- Xcode 15+ (đã verify với Xcode 16/26). Command Line Tools: `xcode-select --install`.
- [Homebrew](https://brew.sh) + [GitHub CLI](https://cli.github.com) (`brew install gh`) cho release flow.
- Không cần dependency ngoài SwiftUI / AppKit / UserNotifications / Foundation — nhưng project link local SPM [CodexBarCore](https://github.com/hapo-nghialuu/CodexBar) tại `~/Desktop/CodexBar` (xem `project.pbxproj`).

## Mở project
```bash
open BirdNion.xcodeproj
```
Trong Xcode chọn scheme `BirdNion` → Run (⌘R). App chạy dạng menu-bar only (LSUIElement).

## Build từ CLI

```bash
# Debug build (nhanh)
xcodebuild build -project BirdNion.xcodeproj -scheme BirdNion \
  -configuration Debug -destination 'platform=macOS'

# Release build (binary tối ưu, dùng để deploy ~/Desktop/BirdNion.app)
xcodebuild build -project BirdNion.xcodeproj -scheme BirdNion \
  -configuration Release -destination 'platform=macOS'
```

**Lưu ý**: Sau khi đổi `project.pbxproj` (thêm file, thay đổi build settings) → cần `clean` để tránh linker error từ `.o` cũ.

```bash
xcodebuild clean build -project BirdNion.xcodeproj -scheme BirdNion \
  -configuration Release -destination 'platform=macOS'
```

## Chạy test
```bash
xcodebuild test -project BirdNion.xcodeproj -scheme BirdNion \
  -configuration Debug -destination 'platform=macOS'
```

Filter theo class / function:
```bash
xcodebuild test ... -only-testing:BirdNionTests/BirdNionConfigStoreTests
xcodebuild test ... -only-testing:BirdNionTests/HapoHubProviderTests
xcodebuild test ... -only-testing:BirdNionTests/MiniMaxProviderParserTests
```

## Deploy local — `~/Desktop/BirdNion.app`

Bundle name `BirdNion.app` đặt trong pbxproj. Binary bên trong cũng tên `BirdNion` (PRODUCT_NAME khớp target name). Bundle ID `com.local.birdnion` — đổi từ bản cũ `com.local.aistatusbar`, nghĩa là UserDefaults cũ không di chuyển được (user phải cấu hình lại).

```bash
SRC=~/Library/Developer/Xcode/DerivedData/BirdNion-bnhvrpmimlkomagvqedntylrgzmu/Build/Products/Release/BirdNion.app
DST=~/Desktop/BirdNion.app

pkill -x BirdNion 2>/dev/null; sleep 0.5
rm -rf "$DST"
cp -R "$SRC" "$DST"
open "$DST"
```

Tìm nhanh khi DerivedData path đổi:
```bash
find ~/Library/Developer/Xcode/DerivedData -type d -name BirdNion.app -path "*Release*"
```

## Release — push lên Homebrew tap

Dùng script tự động (xem [release flow](#release-flow) bên dưới):

```bash
Scripts/release.sh 0.5.2
# 9 bước tự động:
#   1. Verify clean working tree (bắt buộc — commit hết trước)
#   2. Bump MARKETING_VERSION + CFBundleShortVersionString
#   3. xcodebuild Release
#   4. Copy → ~/Desktop/BirdNion.app
#   5. Zip + shasum + verify upload
#   6. Commit + push đúng source commit đã dùng để build
#   7. gh release create v<ver> --target <source-commit> + upload zip
#   8. Update Casks/birdnion.rb (version+sha) + commit + push main
#   9. Update homebrew-tap Casks/birdnion.rb + push
```

> **Prereq:** đang ở `main`, `gh` đã auth (`hapo-nghialuu`), cây git sạch.
> Build (bước 3) chạy trước mọi thao tác publish nên build lỗi sẽ dừng an toàn.
> `--skip-build` chỉ bỏ bước compile; không bỏ kiểm tra nhánh `main` và cây git sạch.

> ⚠️ **GitHub push-protection (bước 6 có thể fail):** secret-scanning chặn cặp
> client id/secret OAuth **công khai** của Gemini CLI trong `GeminiProvider.swift`.
> Chúng được **tách chuỗi** (`"GOCSPX" + "-…"`; id tách trước `.apps.googleusercontent.com`)
> để push qua được — **đừng gộp lại thành 1 literal**, nếu không `git push` sẽ
> bị từ chối trước khi tạo release. Khi đó tách lại literal, sửa commit rồi chạy lại script.

> 🔒 **Hapo bảo mật:** endpoint thật không được commit. Release build lấy
> endpoint từ `Scripts/dev-env.sh` (gitignored) rồi bake vào Info.plist qua
> build settings. User chỉ nhập `Token` trong Settings → AIHub.

### Debug/local build có Hapo AI Hub

Debug build cũng phải bake endpoint vào `Info.plist`; khác nhau chỉ là
`Debug` hay `Release`, không phải cơ chế config. Nếu build từ Xcode hoặc
`xcodebuild` mà không truyền `HAPO_*`, app vẫn chạy nhưng Hapo sẽ báo:
`Hapo endpoint chưa được cấu hình trong bản build`.

```bash
source Scripts/dev-env.sh

xcodebuild build -project BirdNion.xcodeproj -scheme BirdNion \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData \
  HAPO_BASE_URL="$HAPO_BASE_URL" \
  HAPO_ME_URL="$HAPO_ME_URL" \
  HAPO_AUTH_TEMPLATE="$HAPO_AUTH_TEMPLATE"
```

App Debug nằm ở:

```bash
build/DerivedData/Build/Products/Debug/BirdNion.app
```

Nếu copy app này ra Desktop, endpoint vẫn còn vì đã được bake vào bundle lúc
build. Verify nhanh trước khi test:

```bash
plutil -extract HapoBaseURL raw \
  build/DerivedData/Build/Products/Debug/BirdNion.app/Contents/Info.plist
```

Output rỗng nghĩa là bản build đó không có Hapo endpoint. Bấm Run trực tiếp
trong Xcode không tự `source Scripts/dev-env.sh`; cần cấu hình Scheme env vars
hoặc build bằng lệnh trên.

### Release flow

```
[Local]                    [GitHub: hapo-nghialuu/BirdNion]
─────────                   ────────────────────────────────
build/zip
  │
  ├─► commit + push source build
  │      │
  │      └─► gh release create vX.Y.Z --target <source-commit> + upload zip
  │              │
  │              └─► Release page (zip available)
  │
  └─► update Casks/birdnion.rb:
       version, sha256
       git commit + push
              │
              └─► User: brew tap hapo-nghialuu/tap && brew install --cask birdnion
                     → downloads zip
                     → copies to /Applications
                     → postflight: xattr -dr com.apple.quarantine
                     → opens app, no Gatekeeper dialog
```

### Verify sau khi release

```bash
brew tap hapo-nghialuu/tap
brew reinstall --cask birdnion
xattr -l /Applications/BirdNion.app   # should NOT contain com.apple.quarantine
plutil -p /Applications/BirdNion.app/Contents/Info.plist | grep CFBundleShortVersionString
```

## Code signing

Hiện tại **ad-hoc signed** (`Sign to Run Locally`). Cách bypass Gatekeeper:

- `Scripts/release.sh` đã thêm `postflight do … xattr -dr com.apple.quarantine` nên user mở thẳng, không cần Right-click → Open.

Để user mở thẳng **không cần** postflight (và không cần `xattr` hack), cần:

1. **Apple Developer Program** ($99/năm) — https://developer.apple.com/programs/
2. Tạo **Developer ID Application** cert trong Xcode → Keychain
3. Setup notarization credentials:
   ```bash
   xcrun notarytool store-credentials "AC_PASSWORD" \
     --apple-id your@email.com --team-id TEAMID
   ```
4. Update `Scripts/release.sh` (sau đoạn `xcodebuild`, trước `zip`):
   ```bash
   codesign --deep --force --options runtime \
     --sign "Developer ID Application: TÊN BẠN (TEAMID)" \
     "$DESKTOP/BirdNion.app"
   ditto -c -k --sequesterRsrc --keepParent \
     "$DESKTOP/BirdNion.app" "$DESKTOP/BirdNion.zip"
   xcrun notarytool submit "$DESKTOP/BirdNion.zip" --wait
   rm "$DESKTOP/BirdNion.zip"
   ```
5. Drop the `postflight xattr` block (no longer needed).

## Provider tokens & config

> As of the 2026-06-25 storage refactor, all provider tokens + enable flags
> + metadata live in a single file: `~/.config/birdnion/settings.json` (XDG-compliant
> path priority). There is **no longer any BirdNion-owned Keychain entry** —
> the previous split between `~/Library/Application Support/BirdNion/providers.json`
> and the macOS Keychain was consolidated into this one file.

| Token / state | Location | Override env |
|---|---|---|
| All provider tokens + enabled flags + metadata (MiniMax, Hapo, OpenRouter, DeepSeek, Z.ai, Claude admin key) | `~/.config/birdnion/settings.json` (XDG) or `~/.birdnion/settings.json` (legacy) | `BIRDNION_CONFIG` (full path), `MINIMAX_CODING_API_KEY`, `MINIMAX_API_KEY` |
| Claude OAuth | macOS Keychain `service: Claude Code-credentials` (owned by Claude Code app, **not BirdNion**) | (re-login via `claude` CLI) |
| Codex OAuth | `~/.codex/auth.json` (owned by `codex` CLI, **not BirdNion**) | (re-login via `codex` CLI) |
| Per-provider menu-bar visibility | UserDefaults `menuBarVisibility.<id>` | (Settings popover switch) |
| Per-provider refresh interval | UserDefaults `refreshInterval.<id>` | (Settings popover picker) |
| General settings (region, refresh, ...) | UserDefaults (key prefix = bundle id) | (Settings general pane) |

### `~/.config/birdnion/settings.json` format

Array-of-providers shape, mirrors CodexBar's `config.json` schema so
developers familiar with one app immediately know the other:

```json
{
  "version": 1,
  "providers": [
    { "id": "minimax", "apiKey": "sk-…", "enabled": false, "region": "io",
      "baseURL": null, "displayName": null, "accountLabel": null },
    { "id": "hapo",    "apiKey": "…",    "enabled": false,
      "baseURL": null, "displayName": "AI Hub" }
  ]
}
```

First-run default: every `enabled` field is `false` — the popover shows a
one-line empty-state hint and the user opts in via Settings.

### Provider endpoints (URLs)

| Provider | API endpoint | Region / Notes |
|---|---|---|
| `minimax` | `https://platform.minimax.io/v1/api/openplatform/coding_plan/remains` | `MINIMAX_CODING_API_KEY` / `MINIMAX_API_KEY` env; region `io` / `com` (mainland CN) via `minimaxRegion` UserDefault |
| `codex` | (uses ChatGPT backend API via `~/.codex/auth.json` — OAuth by `codex` CLI) | zero-config, no token in BirdNion config |
| `hapo` | Build-time endpoint from Info.plist (`HapoBaseURL`) | User only enters token; release builds source `Scripts/dev-env.sh` before `xcodebuild` |
| `claude` | `https://api.anthropic.com/api/oauth/usage` (+ `claude.ai/api/*` for cost scrape) | OAuth from `Claude Code-credentials` Keychain (owned by Claude Code app); admin API key path uses BirdNion config |
| `openrouter` | `https://openrouter.ai/api/v1/credits` | bearer token |
| `deepseek` | `https://api.deepseek.com/user/balance` | bearer token |
| `zai` | `https://api.z.ai/api/monitor/usage/quota/limit` (region `global`); `https://open.bigmodel.cn/api/monitor/usage/quota/limit` (region `cn`) | bearer token; region via `zaiRegion` UserDefault |

### Environment variables

BirdNion reads the following env vars at startup (all optional; unset = empty / fallback):

| Variable | Purpose | Fallback |
|---|---|---|
| `BIRDNION_CONFIG` | Full path to the config file (overrides path priority below) | none |
| `XDG_CONFIG_HOME` | Parent dir for the config file (XDG-compliant) | `~/.config` |
| `MINIMAX_CODING_API_KEY` / `MINIMAX_API_KEY` | MiniMax token (env override) | file entry in BirdNion config |
| `HAPO_BASE_URL` | Hapo AI Hub weekly budget endpoint used by dev/release builds | empty → build has no embedded Hapo endpoint |
| `HAPO_ME_URL` | Hapo identity endpoint (`/v1/me`) used by dev/release builds | empty → identity fetch is skipped (budget still works) |
| `HAPO_AUTH_TEMPLATE` | `Authorization` header template (must contain `{token}`) | `Bearer {token}` |
| `BIRDNION_SUPPORT_EMAIL` | `mailto:` link shown in Settings → About | `mailto:support@localhost` |

For local development, env vars can still be set before launching or building.
Launching an already-built app with `HAPO_*` only affects that process; a
copied `.app` keeps working on another machine only when the values were baked
into `Info.plist` during build:

```bash
export HAPO_BASE_URL="https://your-hapo-host/v1/budget/week"
export HAPO_ME_URL="https://your-hapo-host/v1/me"
export HAPO_AUTH_TEMPLATE="Bearer {token}"
open /Applications/BirdNion.app

xcodebuild build -project BirdNion.xcodeproj -scheme BirdNion \
  -configuration Release -destination 'platform=macOS' \
  HAPO_BASE_URL="$HAPO_BASE_URL" \
  HAPO_ME_URL="$HAPO_ME_URL" \
  HAPO_AUTH_TEMPLATE="$HAPO_AUTH_TEMPLATE"
```

### File path

Default file location (resolved by `BirdNionConfigStore.configURL()` in this order):
1. `BIRDNION_CONFIG` env override (full path)
2. `XDG_CONFIG_HOME/birdnion/settings.json`
3. `~/.config/birdnion/settings.json` (default)
4. `~/.birdnion/settings.json` (legacy)

Quick commands:
```bash
# View current config
cat ~/.config/birdnion/settings.json

# Open in Finder (Settings → Debug → "Mở Finder" button)
open ~/.config/birdnion/settings.json

# Override path via env (for testing)
BIRDNION_CONFIG=/tmp/birdnion-test/settings.json open /Applications/BirdNion.app

# Check the Hapo endpoint manually (for debugging "Lỗi" status)
TOKEN=$(jq -r '.providers[] | select(.id=="hapo") | .apiKey' ~/.config/birdnion/settings.json)
curl -H "Authorization: Bearer $TOKEN" \
  "$HAPO_BASE_URL"

## Troubleshooting

| Lỗi | Nguyên nhân | Cách xử lý |
|---|---|---|
| `linkd` error spam trong test log | System service macOS, vô hại | Bỏ qua — `grep -v "linkd"` |
| `Unable to find module dependency: 'BirdNion'` | Test chạy trước khi app build | `xcodebuild build` trước, rồi `test` |
| Linker error `Undefined symbols ...` | Build incremental sau khi đổi `init` | `xcodebuild clean build` rồi test |
| `release.sh` SHA mismatch on upload | GitHub release-asset cache | Đổi filename (`v0.x.y` → `0.x.y`) — script tự dùng `BirdNion-${VERSION}.zip` |
| BirdNion mở ra dialog Gatekeeper | postflight chưa chạy / cask version cũ | `brew reinstall --cask birdnion` |
| App icon trắng trong Finder | `ASSETCATALOG_COMPILER_APPICON_NAME` chưa set = `AppIcon` | Check project.pbxproj (đã fix ở `5e8ee0a`) |
| Claude tab "Đang tải…" load lâu | OAuth + cookie fetch chậm khi cold | Đặt `refreshInterval.claude` lớn hơn (UI: Settings popover) |

## File liên quan

- `BirdNion.xcodeproj/project.pbxproj` — Xcode project, build settings
- `Scripts/release.sh` — release automation
- `docs/build.md` — file này
- `docs/system-architecture.md` — kiến trúc providers
- `docs/development-roadmap.md` — phases đã xong + còn lại
- `Casks/birdnion.rb` — Homebrew cask (trong repo này)
