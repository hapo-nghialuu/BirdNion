# Build & Release

## Yêu cầu
- macOS 14+ (Sonoma). Một số API dùng `@Environment` SwiftUI 5.
- Xcode 15+ (đã verify với Xcode 16/26). Command Line Tools: `xcode-select --install`.
- [Homebrew](https://brew.sh) + [GitHub CLI](https://cli.github.com) (`brew install gh`) cho release flow.
- Không cần dependency ngoài SwiftUI / AppKit / UserNotifications / Foundation — nhưng project link local SPM [CodexBarCore](https://github.com/hapo-nghialuu/CodexBar) tại `~/Desktop/CodexBar` (xem `project.pbxproj`).

## Bản đồ build và release

BirdNion hiện có hai lane phân phối độc lập:

- **macOS**: `Scripts/release.sh` chạy verification gate, bump version, build universal `.app`, tạo zip, tạo/cập nhật GitHub Release và cập nhật Homebrew cask.
- **Linux**: `.github/workflows/linux-release.yml` hiện là workflow `workflow_dispatch` thủ công. Workflow không tự bump version và không tự tạo tag; nó nhận một tag release đã tồn tại, checkout ref được dispatch, rồi đính kèm `.deb`, `.rpm` và `.AppImage` vào release đó.

Windows 10/11 x64/ARM64 là **development target**, chưa phải lane phân phối. `linux/src-tauri/tauri.windows.conf.json` mới mô tả NSIS current-user + WebView2 bootstrapper và hiện cố ý để `resources: []`; chưa có sidecar Windows được bundle hoặc workflow Windows nào được xác minh.

Vì vậy, phải phân biệt hai khái niệm:

1. **Tag/source commit**: tag `vX.Y.Z` trỏ tới một commit cụ thể, thường được tạo bởi lane macOS.
2. **Linux build commit**: commit của ref dùng khi dispatch `linux-release.yml` (thường là `main` mới nhất).

Workflow Linux chỉ kiểm tra `inputs.tag` khớp `linux/src-tauri/tauri.conf.json.version`; nó không kiểm tra tag phải trỏ cùng commit với `main`. Khi release lại Linux cho một tag macOS đã tồn tại, cần ghi rõ Linux asset được build từ commit nào.

### Windows build status — chưa phải runbook phát hành

Target dự kiến gồm bốn evidence lanes độc lập: Windows 10 x64, Windows 10 ARM64, Windows 11 x64 và Windows 11 ARM64. Trạng thái hiện tại là `FLASH_UNVERIFIED` vì test suite đã defer và chưa có native Windows compile, runtime hoặc install receipt.

Static implementation đã có:

- platform paths cho `%USERPROFILE%`, `%APPDATA%`, `%LOCALAPPDATA%` và `PATH`/`PATHEXT`;
- atomic private writes bằng same-directory temp + `MoveFileExW`, protected owner/SYSTEM DACL;
- owned child + Windows Job Object, listener PID phải khớp child BirdNion;
- NSIS/current-user/WebView2 config, single-instance callback và tray branch;
- Claude/Gemini/Cursor source-path discovery, Cursor SQLite read-only + browser fallback.

Chưa được phép dùng để build và phát hành public cho tới khi có đủ:

- CLIProxyAPI sidecar source/version/SHA, PE architecture x64/ARM64 và Tauri bundle resource;
- native browser/DPAPI, tray/window/single-instance, process cleanup và provider First Live journeys;
- clean install, same-architecture upgrade, uninstall, SmartScreen/`Unknown publisher` guidance và downloaded-asset verification;
- hai Windows CI và release lanes độc lập, exact tag/commit/version, installer SHA-256 và receipts trên đủ bốn OS/architecture lanes.

Cross-compile hoặc static check trên macOS không thay native evidence. Cho đến khi các gate trên pass, README/release notes/download page không được claim Windows supported hoặc released.

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

### CLIProxyAPI nhúng cho Claude Code

Các custom Claude Code profile dùng BirdNion local proxy sẽ đóng gói core
CLIProxyAPI vào app. Build cần có Go và source CLIProxyAPI ở thư mục cùng cấp
với BirdNion (`~/Desktop/CLIProxyAPI`). Nếu source nằm nơi khác, truyền đường
dẫn tuyệt đối trước khi chạy `xcodebuild`:

```bash
export CLIPROXYAPI_SOURCE=/duong-dan/toi/CLIProxyAPI
xcodebuild build -project BirdNion.xcodeproj -scheme BirdNion \
  -configuration Debug -destination 'platform=macOS'
```

Build phase tạo helper universal cho Apple Silicon và Intel, rồi nhúng tại
`BirdNion.app/Contents/Resources/cliproxyapi`.

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
> Script kiểm tra lại `HapoBaseURL`, `HapoMeURL` và `HapoAuthTemplate` trong
> bundle trước khi đóng gói; release dừng nếu giá trị bị thiếu hoặc biến đổi.

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

Trước khi bump version hoặc publish bất cứ gì, `release.sh` chạy một **verification
gate** (macOS `xcodebuild test`, Linux `npm run build`, Linux `cargo test`) và dừng
lại nếu bất kỳ bước nào fail. Gate này bỏ qua khi chạy với `--skip-build` hoặc
`--dry-run`.

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

## Runbook Linux release thủ công

### 1. Build và test local

Có thể kiểm tra frontend và Rust trên macOS hoặc Linux:

```bash
cd linux
npm ci
npm test
npm run build
cargo test --manifest-path src-tauri/Cargo.toml
```

Đóng gói native Linux phải chạy trên Ubuntu/Linux có đủ WebKitGTK và
AppIndicator dependencies. Cài các dependency tương đương workflow:

```bash
sudo apt-get update
sudo apt-get install -y \
  libwebkit2gtk-4.1-dev build-essential curl wget file \
  libxdo-dev libssl-dev libayatana-appindicator3-dev librsvg2-dev

cd linux
npm ci
npm run tauri build
```

Workflow `linux-build.yml` là lane kiểm tra/đính kèm artifact, không publish
vào GitHub Release. Nó chạy `npm test`, `cargo test`, `npx tsc --noEmit` và tạo đủ ba
bundle trên `ubuntu-22.04`.

### 2. Version và source commit

Trước khi release Linux:

```bash
git status --short --branch
git fetch origin main
git log -1 --oneline origin/main
node -p "require('./linux/src-tauri/tauri.conf.json').version"
```

Các version authority của Linux phải cùng một release version:

- `linux/src-tauri/tauri.conf.json` — workflow dùng file này để so với tag.
- `linux/src-tauri/Cargo.toml` — package Rust.
- `linux/src-tauri/Cargo.lock` — lockfile cần được giữ nhất quán sau khi đổi package version.

Workflow hiện không tự bump các file trên. Nếu `tauri.conf.json` chưa là
`0.10.21`, phải sửa version trong source, test, commit và push trước khi
dispatch `v0.10.21`.

### 3. Build helper CLIProxyAPI cho Linux

Linux app nhúng helper Go `cliproxyapi`. Helper này là **asset build-only**:
workflow tải nó xuống để Tauri bundle có resource `binaries/cliproxyapi`, sau
đó workflow xoá helper và file checksum khỏi GitHub Release khi toàn bộ job
thành công. Người cài Ubuntu không tải helper này; chỉ tải `.deb`, `.rpm` hoặc
`.AppImage` cuối cùng.

Trên macOS để tạo helper Linux x86_64 từ checkout CLIProxyAPI local:

```bash
GOOS=linux GOARCH=amd64 \
CLIPROXYAPI_SOURCE=/duong-dan-tuyet-doi/toi/CLIProxyAPI \
linux/scripts/build-cliproxy.sh

file linux/src-tauri/binaries/cliproxyapi
```

Kết quả phải là ELF Linux `x86-64`, không phải Mach-O macOS. Đổi tên bản
upload và tạo checksum từ đúng thư mục chứa file để checksum có basename
`cliproxyapi-linux-x86_64`; workflow Ubuntu chạy `sha256sum -c` trong thư mục
đó:

```bash
cp linux/src-tauri/binaries/cliproxyapi /tmp/cliproxyapi-linux-x86_64
(cd /tmp && \
  shasum -a 256 cliproxyapi-linux-x86_64 \
    > cliproxyapi-linux-x86_64.sha256)
(cd /tmp && shasum -a 256 -c cliproxyapi-linux-x86_64.sha256)
```

Không commit helper vào Git. `linux/.gitignore` đã coi đây là binary được
build bởi `linux/scripts/build-cliproxy.sh`.

### 4. Đính helper vào release hiện có

Linux workflow cần release/tag đã tồn tại. Upload đúng hai asset tạm thời:

```bash
gh release upload vX.Y.Z \
  /tmp/cliproxyapi-linux-x86_64 \
  /tmp/cliproxyapi-linux-x86_64.sha256 \
  --repo hapo-nghialuu/BirdNion \
  --clobber
```

Kiểm tra trước khi dispatch:

```bash
gh release view vX.Y.Z --repo hapo-nghialuu/BirdNion \
  --json assets --jq '.assets[].name'
```

Danh sách tạm phải có asset macOS (nếu release đã có), helper và helper
checksum; không được còn `.deb`, `.rpm` hoặc `.AppImage` cũ nếu đang release
lại Linux.

### 5. Dispatch Linux release

Dispatch từ `main` mới nhất, truyền tag của release đã tồn tại:

```bash
gh workflow run linux-release.yml \
  --repo hapo-nghialuu/BirdNion \
  --ref main \
  -f tag=vX.Y.Z
```

Lấy run id và theo dõi trực tiếp:

```bash
gh run list --repo hapo-nghialuu/BirdNion \
  --workflow linux-release.yml --limit 3 \
  --json databaseId,status,conclusion,headSha,url

gh run watch RUN_ID \
  --repo hapo-nghialuu/BirdNion \
  --exit-status --interval 10
```

Các gate phải pass theo đúng thứ tự: checkout, version check, system
dependencies, Node/Rust toolchain, `npm ci`, download + checksum helper, Rust
tests, Tauri bundle, upload ba package và cleanup helper. GitHub warning về
Node.js của action không tự làm release fail; vẫn phải ghi nhận warning, không
che nó bằng cách lọc output.

Workflow cần ba GitHub Actions secrets và tự kiểm tra chúng trước khi package:

- `HAPO_BASE_URL`
- `HAPO_ME_URL`
- `HAPO_AUTH_TEMPLATE` — bắt buộc chứa literal `{token}`

Workflow còn kiểm tra các giá trị này đã được bake vào Linux release binary.
Không commit endpoint thật hoặc token vào repository.

### 6. Verify sau khi workflow thành công

```bash
gh run view RUN_ID --repo hapo-nghialuu/BirdNion \
  --json status,conclusion,headSha,url

gh release view vX.Y.Z --repo hapo-nghialuu/BirdNion \
  --json tagName,targetCommitish,assets,isDraft,isPrerelease,url
```

Release cuối phải có đúng các asset cần phát hành:

- `BirdNion-<version>.zip` — macOS, nếu release này có lane macOS.
- `BirdNion_<version>_amd64.deb`.
- `BirdNion-<version>-1.x86_64.rpm`.
- `BirdNion_<version>_amd64.AppImage`.

`cliproxyapi-linux-x86_64` và `.sha256` phải biến mất sau cleanup. Đọc digest
GitHub để lưu SHA256 của ba package; nếu cần kiểm chứng độc lập, download từng
asset rồi chạy `shasum -a 256`/`sha256sum` tại máy nhận.

### 7. Release lại Linux cho cùng một tag

Chỉ xoá package Linux cũ sau khi đã xác định đúng asset id bằng REST API. Không
dùng tag id, không xoá release, không xoá asset macOS:

```bash
gh api repos/hapo-nghialuu/BirdNion/releases/tags/vX.Y.Z \
  --jq '.assets[] | [.name, (.id|tostring)] | @tsv'

gh api --method DELETE \
  repos/hapo-nghialuu/BirdNion/releases/assets/NUMERIC_ASSET_ID
```

`gh release view --json assets` hiển thị GraphQL node id; endpoint REST DELETE
cần numeric asset id lấy từ `gh api` như lệnh trên. Sau khi xoá đúng ba
package Linux, upload helper/checksum, dispatch lại workflow và chỉ coi release
hoàn tất khi ba package mới xuất hiện, helper đã bị cleanup, còn asset macOS
vẫn nguyên vẹn.

Nếu workflow fail trước bước cleanup, helper có thể còn trên release. Khi retry,
kiểm tra và xoá thủ công đúng hai helper asset; đồng thời kiểm tra package nào
đã upload để tránh tạo asset trùng hoặc giữ package không thuộc lần build mới.

### 8. Quy trình macOS chuẩn

Release macOS dùng script thay vì bump thủ công:

```bash
git status --short --branch
gh auth status
source Scripts/dev-env.sh
Scripts/release.sh X.Y.Z
```

Script yêu cầu branch `main`, cây git sạch và `HAPO_BASE_URL` cho release
build. Gate chạy macOS `xcodebuild test`, Linux TypeScript build và Rust test
trước khi đổi version hoặc publish. Sau đó script:

1. bump `BirdNion/Info.plist` và `MARKETING_VERSION` trong `project.pbxproj`;
2. build Release với `ONLY_ACTIVE_ARCH=NO` và `CLIPROXYAPI_UNIVERSAL=1`, nên app/helper có lane Apple Silicon + Intel;
3. kiểm tra bundle version, Hapo build settings, zip và SHA256;
4. commit/push đúng source commit đã build;
5. tạo hoặc upload `vX.Y.Z`, tải lại asset và verify SHA;
6. cập nhật cask trong repo BirdNion và repo `homebrew-tap`.

`--skip-build` chỉ dùng khi đã có build hợp lệ và cố ý bỏ qua verification và
build; `--dry-run` không publish. Sau release, lệnh update đúng là:

```bash
brew update && brew upgrade --cask birdnion
```

Không thay `birdnion` bằng tên project/agent khác.

## Biên bản session Linux `v0.10.20`

Đây là receipt lịch sử để đối chiếu quy trình trên:

- Đã xoá đúng ba Linux asset cũ: `.deb` asset `518180192`, AppImage asset `518180193`, `.rpm` asset `518180194`.
- Giữ nguyên `BirdNion-0.10.20.zip` của macOS, asset id `517775288`.
- Pull/fetch `main` mới nhất và build từ `4e7c2762e39f64731353e58aec7fee59abcc9076`.
- Tag `v0.10.20` vẫn có target commit macOS `9b36cc0c1b74de2b15147caa6409a5aabd5e4138`; đây là lý do phải ghi riêng Linux build commit.
- Workflow [32088016909](https://github.com/hapo-nghialuu/BirdNion/actions/runs/32088016909) thành công trong `8m10s`.
- SHA256 cuối của Linux assets: `.deb` `60e446cd5d234cfafb19fc08fd42cd56c79f4aa7d3fa9e0423b8ce62ed478d9a`; `.rpm` `85a9c523359f35d095071600b87c0cf6466bed5d01e16e53fa1ca0d13cfff9c9`; `.AppImage` `69d2d478658d5b13c4c2e84a1aa84d059bfd12eb2d7eab5da77531ef8c83a786`.
- Helper và checksum helper đã được workflow xoá sau khi upload package; người dùng Linux không cần download chúng.

## Vấn đề cần nhớ

- Linux release hiện là manual-only; push tag không tự build Linux.
- Linux package có thể được build từ `main` mới hơn source commit mà tag đang trỏ tới; luôn ghi `headSha` của workflow.
- Native Linux packaging cần runner Ubuntu/Linux; local macOS chỉ nên build helper hoặc chạy frontend/Rust tests.
- Không dùng checksum được tạo với absolute path; checksum file phải tham chiếu basename đúng với file download.
- Không xoá tag/release để thay package Linux. Xác định numeric asset id, xoá đúng ba package, rồi xác minh lại toàn bộ asset sau workflow.
- macOS hiện ad-hoc signed; Homebrew cask dùng postflight xoá quarantine. Notarization/Developer ID vẫn là việc riêng nếu cần phân phối production không qua postflight.

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
