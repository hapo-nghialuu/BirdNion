# Build & Run

## Yêu cầu
- macOS 14+ (Sonoma). Một số API dùng `@Environment` của SwiftUI 5.
- Xcode 15+ (đã verify với Xcode 16). Command Line Tools: `xcode-select --install`.
- Không cần dependency ngoài — SwiftUI, AppKit, UserNotifications, Foundation đều có sẵn.

## Mở project
```bash
open AIStatusbar.xcodeproj
```
Trong Xcode chọn scheme `AIStatusbar` → Run (⌘R). App chạy dạng menu-bar, không có dock icon.

## Build từ CLI
```bash
# Debug build (nhanh, không tối ưu)
xcodebuild build -project AIStatusbar.xcodeproj -scheme AIStatusbar \
  -configuration Debug -destination 'platform=macOS'

# Release build (binary tối ưu, dùng để deploy ~/Desktop/BirdNion.app)
xcodebuild clean build -project AIStatusbar.xcodeproj -scheme AIStatusbar \
  -configuration Release -destination 'platform=macOS'
```
**Lưu ý:** luôn `clean build` trước Release sau khi đổi `project.pbxproj` (thêm file mới). Build incremental có thể fail linker vì `.o` cũ còn trỏ vào `init` cũ.

## Chạy test
```bash
# Phải build app trước, nếu không test sẽ fail với
# "Unable to find module dependency: 'AIStatusbar'"
xcodebuild build -project AIStatusbar.xcodeproj -scheme AIStatusbar \
  -configuration Debug -destination 'platform=macOS'

xcodebuild test -project AIStatusbar.xcodeproj -scheme AIStatusbar \
  -configuration Debug -destination 'platform=macOS'
```

### Chạy riêng một suite
```bash
xcodebuild test ... -only-testing:AIStatusbarTests/CodexBarConfigStoreTests
```

## Deploy lên ~/Desktop/BirdNion.app

`PRODUCT_NAME` trong project là `AIStatusbar` (để giữ UserDefaults + Keychain service name ổn định). Binary tên `AIStatusbar` bên trong bundle tên `BirdNion.app`:

```bash
SRC=~/Library/Developer/Xcode/DerivedData/AIStatusbar-bnhvrpmimlkomagvqedntylrgzmu/Build/Products/Release/AIStatusbar.app
DST=~/Desktop/BirdNion.app

pkill -x AIStatusbar 2>/dev/null; sleep 0.5
rm -rf "$DST"
cp -R "$SRC" "$DST"
open "$DST"
```
DerivedData path thay đổi theo Xcode config. Tìm nhanh:
```bash
find ~/Library/Developer/Xcode/DerivedData -type d -name AIStatusbar.app -path "*Release*"
```

## Cấu hình runtime

- **Provider tokens (MiniMax, Hapo)**: lưu trong `~/.config/codexbar/config.json` (XDG) hoặc `~/.codexbar/config.json` (legacy). Có thể ghi đè bằng env `MINIMAX_CODING_API_KEY` / `MINIMAX_API_KEY`. File tạo tự động ở lần Lưu token đầu tiên, quyền 0o600.
- **Claude Code API key** (`ANTHROPIC_API_KEY`): lưu trong macOS Keychain `service: AIStatusbar, account: anthropic`. Form `ConfigPanel` chỉ là shortcut để ghi key vào `~/.claude.json`.
- **Codex login**: OAuth, file `~/.codex/auth.json`. App đọc trực tiếp.
- **UserDefaults**: dùng cho setting UI (region, ngưỡng quota warning, menu bar metric, …). Bundle id làm key prefix.

## Troubleshooting

| Lỗi | Nguyên nhân | Cách xử lý |
|---|---|---|
| `linkd` error spam trong test log | System service macOS, vô hại | Bỏ qua — lọc bằng `grep -v "linkd"` |
| `Unable to find module dependency: 'AIStatusbar'` | Test chạy trước khi app build | Build app trước rồi mới test |
| Linker error `Undefined symbols ... QuotaWindow.init` | Build incremental sau khi đổi `init` của struct | `xcodebuild clean build` rồi test |
| `HapoHubProviderTests` crash runner | Đã fix ở commit `889496a` | Kéo `git pull` |
| Settings window crash khi mở | Đã fix ở commit gốc (dùng SwiftUI `Settings` scene, không manual NSWindow) | Xem [[system-architecture]] |
| `SourceKit` báo "Cannot find type" trong file lẻ | LSP phân tích file thiếu module context | Bỏ qua — `xcodebuild` mới là ground truth |
