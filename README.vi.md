<div align="center">
  <img src="docs/social.png" alt="BirdNion - AI quota companion for macOS and Linux" />
</div>

# BirdNion - Để các tác nhân AI của bạn luôn trong ngân sách.

> Mọi hạn mức lập trình AI và cài đặt tác nhân, ngay trên thanh menu macOS hoặc khay hệ thống Linux.

[English](README.md) · **Tiếng Việt** · [中文](README.zh.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Español](README.es.md) · [Deutsch](README.de.md) · [Français](README.fr.md)


[![Latest release](https://img.shields.io/github/v/release/hapo-nghialuu/BirdNion?style=flat-square&color=0a0a0c)](https://github.com/hapo-nghialuu/BirdNion/releases/latest)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-0a0a0c?style=flat-square)](https://github.com/hapo-nghialuu/BirdNion/releases/latest)
[![Linux x86_64](https://img.shields.io/badge/Linux-x86__64-fcc624?style=flat-square&logo=linux&logoColor=111)](https://github.com/hapo-nghialuu/BirdNion/releases/latest)
[![Homebrew](https://img.shields.io/badge/brew-hapo--nghialuu%2Ftap%2Fbirdnion-orange?style=flat-square)](https://github.com/hapo-nghialuu/homebrew-tap)
[![License: MIT](https://img.shields.io/badge/license-MIT-6e5aff?style=flat-square)](LICENSE)

38 nhà cung cấp. BirdNion là ứng dụng nhỏ gọn chạy trên thanh menu macOS 14+ và khay hệ thống Linux, giúp bạn luôn nắm được các giới hạn lập trình AI, biết khi nào từng kỳ hạn mức được đặt lại và quản lý tập trung cách đọc dữ liệu của từng tác nhân lập trình. Codex, Claude, MiniMax, OpenRouter, DeepSeek, z.ai, ElevenLabs, Deepgram, Groq, Grok, xAI, OpenAI, Ollama, GitHub Copilot, Kilo, Command Code, Xiaomi MiMo, Alibaba/Qwen, Cursor, Gemini, Kiro, OpenCode, OpenCode Go, Antigravity, AWS Bedrock, FreeModel, Devin và Hapo AI Hub — cùng các nhà cung cấp qua plugin JavaScript (Aixy, Atlas Cloud, ClinePass, LiteLLM, Muse Code, Nous Portal, Raycast, Sakana AI, Venice, xKiro).

Ứng dụng macOS gốc sử dụng SwiftUI/AppKit và một tập con `CodexBarCore` đã được tinh gọn, tích hợp sẵn vào dự án. Bản chuyển sang Linux nằm trong `linux/`, sử dụng Tauri v2 với lõi Rust và giao diện TypeScript thuần. Cả hai nền tảng dùng chung lược đồ cấu hình nhà cung cấp theo XDG.

## Vì sao chọn BirdNion

- **Chủ động theo thời điểm đặt lại hạn mức.** Theo dõi các kỳ hạn mức 5 giờ, hằng tuần, hằng tháng, tín dụng và ngân sách của từng nhà cung cấp, kèm đếm ngược đến lần đặt lại.
- **Nắm rõ chi tiêu và chi phí.** Quét JSONL cục bộ của Claude, phân tích mức sử dụng hằng tuần, xếp hạng dự án bảo vệ quyền riêng tư, biểu đồ Claude Admin API, tín dụng Codex, số dư OpenRouter, ngân sách Bedrock và tổng hợp chi phí/tín dụng theo từng nhà cung cấp khi có dữ liệu.
- **Cấu hình nguồn dữ liệu cho tác nhân.** Chọn OAuth, CLI, cookie trình duyệt, khóa API, thông tin xác thực AWS, tệp ứng dụng cục bộ hoặc ứng dụng của nhà cung cấp trong phần Cài đặt của từng nhà cung cấp.
- **Chuyển đổi mà không mất ngữ cảnh.** Cả macOS và Linux đều hỗ trợ chuyển đổi hồ sơ Claude/Codex tùy chỉnh, đặt lại tín dụng/tự động khởi tạo sẵn cho Codex và quy trình đa tài khoản cho Codex, Copilot, Antigravity và FreeModel.
- **Giữ giao diện hệ thống gọn gàng.** macOS có thể luân phiên hiển thị phần trăm hạn mức của các nhà cung cấp trên thanh menu; Linux luân phiên hiển thị logo và phần trăm trực tiếp trong biểu tượng khay hệ thống.
- **Ưu tiên quyền riêng tư.** BirdNion tái sử dụng các phiên hiện có và cấu hình được chỉ định rõ ràng. Ứng dụng không lưu mật khẩu hay quét ổ đĩa không giới hạn.

## Cài đặt

### Yêu cầu

- macOS 14+ (Sonoma)
- Linux x86_64 cho các gói `.deb`, `.rpm` và `.AppImage` được phát hành

### Bản phát hành trên GitHub

Tải các gói dựng sẵn từ [Bản phát hành trên GitHub](https://github.com/hapo-nghialuu/BirdNion/releases):

- `BirdNion-<version>.zip` - ứng dụng macOS universal, được ký bằng Developer ID và được Apple công chứng.
- `BirdNion_<version>_amd64.deb` - gói Ubuntu/Debian.
- `BirdNion-<version>-1.x86_64.rpm` - gói Fedora/RHEL.
- `BirdNion_<version>_amd64.AppImage` - gói Linux chạy độc lập, không cần cài đặt.
- Homebrew cask sử dụng SHA256.
- Chứng nhận công chứng được đính kèm trực tiếp vào ứng dụng, nên Gatekeeper có thể mở ứng dụng ngay cả khi ngoại tuyến sau bước xác nhận tiêu chuẩn “được tải xuống từ Internet”.

### macOS qua Homebrew

Lệnh cài đặt được khuyến nghị:

```bash
brew install --cask hapo-nghialuu/tap/birdnion
```

Lệnh dùng tên đầy đủ chọn rõ `hapo-nghialuu/tap/birdnion`, nên không cần bước `brew tap` riêng.

Quy trình dùng tên ngắn sau khi thêm tap:

```bash
brew tap hapo-nghialuu/tap
brew trust --cask hapo-nghialuu/tap/birdnion
brew install --cask birdnion
```

Hoặc tin cậy toàn bộ tap:

```bash
brew trust hapo-nghialuu/tap
brew install --cask birdnion
```

Không dùng `HOMEBREW_NO_REQUIRE_TAP_TRUST=1` làm cách cài đặt thông thường. Đây là biến môi trường ghi đè ở phía người dùng, không thể đặt trong `Casks/birdnion.rb` để bỏ qua bước xác nhận tin cậy trước khi Homebrew nạp cask.

### Cập nhật trên macOS

```bash
brew update && brew upgrade --cask birdnion
```

Chạy `brew update` trước (nối bằng `&&`) để tap tải về cask mới nhất —
chỉ chạy `brew upgrade` sẽ không làm mới tap bên thứ ba và sẽ báo
“đã cài đặt” dựa trên phiên bản cũ.

Kiểm tra phiên bản đã cài:

```bash
brew list --cask --versions birdnion   # or: brew info --cask birdnion
```

### Linux

Tải một trong các gói Linux từ [bản phát hành mới nhất](https://github.com/hapo-nghialuu/BirdNion/releases/latest):

```bash
sudo apt install ./BirdNion_<version>_amd64.deb
# or
sudo dnf install ./BirdNion-<version>-1.x86_64.rpm
# or
chmod +x BirdNion_<version>_amd64.AppImage
./BirdNion_<version>_amd64.AppImage
```

### Lần chạy đầu tiên

- Mở BirdNion từ thanh menu macOS hoặc khay hệ thống Linux.
- Mở Cài đặt -> Nhà cung cấp và bật những nhà cung cấp bạn sử dụng.
- Cài đặt hoặc đăng nhập vào các nguồn dữ liệu bạn cần: CLI, phiên trình duyệt, OAuth/quy trình xác thực thiết bị, khóa API, tệp ứng dụng cục bộ hoặc thông tin xác thực đám mây, tùy nhà cung cấp.
- Tùy chọn: đặt nhãn tài khoản nhà cung cấp, khả năng hiển thị trên thanh menu, chu kỳ làm mới, nguồn cookie, khu vực, chế độ xác thực AWS, phạm vi tổ chức Kilo, máy chủ doanh nghiệp Copilot hoặc chỉ số riêng của nhà cung cấp trên thanh menu.

## Cấu hình cài đặt tác nhân

BirdNion hướng tới việc trở thành bảng điều khiển cài đặt/cấu hình gọn nhẹ cho các tác nhân lập trình AI, chứ không chỉ là công cụ xem hạn mức.

Những gì hiện đã có:

- Bật/tắt nhà cung cấp, sắp xếp thứ tự, đặt nhãn tài khoản, chu kỳ làm mới và khả năng hiển thị trên thanh menu.
- Bộ chọn nguồn cho các nhà cung cấp có thể đọc từ OAuth, CLI, cookie trình duyệt, Admin API hoặc trạng thái ứng dụng cục bộ.
- Cài đặt riêng theo nhà cung cấp cho chế độ cookie, tiêu đề cookie nhập thủ công, khu vực MiniMax/z.ai/Alibaba, khóa/hồ sơ/khu vực AWS, ID dự án Deepgram, phạm vi tổ chức Kilo, máy chủ doanh nghiệp Copilot và lựa chọn chỉ số trên thanh menu.
- Tự tìm các phiên cục bộ của những tác nhân tự quản lý trạng thái xác thực: Claude Code, Codex CLI, Gemini CLI, Kiro, Cursor, Antigravity và các công cụ tương tự.
- Bảng điều khiển cấu hình Claude Code cho các backend có sẵn/tùy chỉnh, các cấp mô hình, phạm vi toàn cục hoặc theo dự án, nhập JSON và xóa an toàn các khóa biến môi trường do BirdNion quản lý.
- Chuyển đổi hồ sơ Claude Code và Codex tùy chỉnh với kiểm tra thực tế trạng thái sẵn sàng/lỗi thời/tình trạng proxy, đồng thời chặn kích hoạt nếu không xác nhận được tính an toàn.
- Tìm và chuyển đổi nhiều tài khoản cho Codex, GitHub Copilot, Antigravity và FreeModel, bao gồm các phiên FreeModel theo từng trình duyệt.

Định hướng dự kiến:

- Mở rộng quản lý hồ sơ từ Claude Code sang nhiều tác nhân lập trình khác.
- Hiển thị chi tiết hơn tình trạng đăng nhập/nguồn dữ liệu của từng tác nhân.
- Kiểm tra tính hợp lệ của đường dẫn cấu hình cục bộ và khả năng sử dụng CLI.
- Cung cấp hướng dẫn thiết lập ban đầu cho Claude Code, Codex CLI, Gemini CLI, Kiro và các tác nhân trong tương lai.
- Giữ các tùy chọn của BirdNion trong lớp cấu hình riêng, không can thiệp vào kho thông tin xác thực của từng tác nhân.

## Nhà cung cấp

- **Codex** - OAuth API từ `~/.codex/auth.json`, dự phòng bằng khóa API, dự phòng bằng `codex app-server` cục bộ, trạng thái dịch vụ, phiên bản, tín dụng, đặt lại tín dụng, các thông tin bổ sung tùy chọn từ trang web OpenAI và chuyển đổi tài khoản có quản lý.
- **Claude** - OAuth API, cookie trình duyệt, CLI hoặc Admin API; các kỳ hạn mức 5 giờ/hằng tuần/Opus/Sonnet, Daily Routines, quét chi phí cục bộ, thông tin bổ sung từ trang web (chi tiêu cho phần sử dụng vượt hạn mức cùng tín dụng trả trước còn lại) và biểu đồ quản trị 30 ngày. Các gói Max hiển thị hệ số sử dụng tương ứng (Max 5x / Max 20x).
- **MiniMax** - Token API, token từ môi trường hoặc dự phòng bằng cookie để lấy mức sử dụng gói lập trình, tên gói, điểm/thuê bao và khu vực toàn cầu/Trung Quốc.
- **OpenRouter** - Token API để lấy tín dụng trả trước, kèm giới hạn chi tiêu tùy chọn cho từng khóa.
- **DeepSeek** - Token API để lấy số dư USD/CNY, tách riêng phần đã nạp/được tặng và cảnh báo số dư thấp.
- **z.ai** - Token API với khu vực toàn cầu/Trung Quốc để lấy giới hạn hạn mức và tính phần trăm còn lại.
- **ElevenLabs** - Khóa API để lấy hạn mức ký tự, số lượng giọng nói, giọng nói chuyên nghiệp, gói dịch vụ và trạng thái thuê bao.
- **Deepgram** - Khóa API với ID dự án tùy chọn để tổng hợp mức sử dụng, có chế độ tổng hợp tất cả dự án.
- **Groq** - Khóa API để lấy các chỉ số yêu cầu, token và lượt trúng bộ nhớ đệm dựa trên Prometheus.
- **Grok** - Không cần cấu hình, đọc từ `~/.grok/auth.json` (`grok login`); gọi RPC `x.ai/billing` qua CLI, sau đó dùng gRPC-web thanh toán của grok.com qua cookie Chrome / token Bearer xác thực; thông tin tài khoản SuperGrok và các kỳ hạn mức tín dụng. Chi phí cục bộ trong thẻ Tất cả lấy từ `~/.grok/sessions/**/signals.json` (tổng token × bảng giá tổng hợp theo mô hình).
- **xAI** - Khóa API quản lý cùng ID nhóm cho nền tảng dành cho nhà phát triển (tách biệt với thuê bao Grok dành cho người dùng cá nhân); số dư trả trước và chi tiêu trên nền tảng trong 30 ngày.
- **OpenAI** - Admin API của nền tảng (`OPENAI_ADMIN_KEY` / cấu hình) để lấy chi tiêu của tổ chức trong hôm nay/7 ngày/30 ngày; ID dự án tùy chọn; dự phòng bằng cơ chế cấp tín dụng cũ cho khóa API người dùng. Không phải thuê bao ChatGPT/Codex (hãy dùng nhà cung cấp Codex cho loại thuê bao đó).
- **Ollama** - Mức sử dụng phiên đám mây/hằng tuần qua cookie ollama.com (Tự động/Thủ công); `OLLAMA_API_KEY` tùy chọn để xác minh quyền truy cập Cloud API.
- **GitHub Copilot** - Quy trình xác thực thiết bị GitHub hoặc dự phòng bằng PAT, máy chủ doanh nghiệp, quản lý đầy đủ việc thêm/chuyển/xóa tài khoản, mức sử dụng cao cấp, tên người dùng và thông tin ngân sách bổ sung qua cookie web.
- **Kilo** - Token API hoặc phiên CLI, phạm vi tổ chức Kilo, tín dụng và chi tiết tự động nạp thêm.
- **Kiro** - Mức sử dụng qua CLI, dữ liệu tín dụng/vượt hạn mức và 9 chế độ hiển thị trên thanh menu.
- **Command Code** - Cookie trình duyệt hoặc cookie nhập thủ công để lấy tín dụng thanh toán và danh mục gói dịch vụ.
- **Xiaomi MiMo** - Cookie trình duyệt để lấy số dư, chi tiết gói token và mức sử dụng.
- **Alibaba/Qwen** - Cookie trình duyệt cùng khu vực quốc tế/Trung Quốc để lấy các kỳ hạn mức của gói lập trình và gói token.
- **Cursor** - Ưu tiên `state.vscdb` của Cursor, dự phòng bằng cookie trình duyệt, cung cấp tổng hợp mức sử dụng, thông tin tài khoản và mức sử dụng yêu cầu.
- **Gemini** - Thông tin xác thực OAuth của Gemini CLI từ `~/.gemini/oauth_creds.json` để lấy các cấp hạn mức Cloud Code Assist.
- **OpenCode** - Cookie trình duyệt để lấy mức sử dụng theo kỳ trượt/hằng tuần và thời điểm gia hạn thuê bao.
- **OpenCode Go** - Cookie trình duyệt cùng trang không gian làm việc Go để lấy mức sử dụng theo kỳ trượt/hằng tuần/hằng tháng và số dư Zen.
- **Antigravity** - Dò tiến trình/CLI cục bộ và kho tài khoản Google OAuth để lấy các nhóm hạn mức cùng dữ liệu khớp với tài khoản.
- **AWS Bedrock** - Khóa truy cập AWS hoặc hồ sơ có tên, khu vực, các trường ngân sách và mức sử dụng từ CloudWatch/Cost.
- **FreeModel** - Phiên trình duyệt từ `freemodel.dev` để lấy ngân sách bằng đô la theo kỳ 5 giờ và hằng tuần, hỗ trợ chuyển đổi tài khoản theo từng trình duyệt và cookie do ứng dụng quản lý.
- **Devin** - Hạn mức hằng ngày và hằng tuần từ `app.devin.ai/api/<org>/billing/quota/usage`. Tự nhập token phiên trình duyệt và tổ chức từ localStorage của Chrome, hoặc nhận token Bearer nhập thủ công cùng Tổ chức tùy chọn (slug hoặc ID nội bộ dạng `org-...`).

Sẵn sàng hỗ trợ thêm nhà cung cấp khi phù hợp với mô hình `QuotaProvider` hiện có.

## Linh vật, biểu tượng và ảnh chụp màn hình

Biểu tượng thanh menu macOS mặc định là chú chim BirdNion. Khi bật “Hiển thị phần trăm trên thanh menu”, thanh menu luân phiên hiển thị phần trăm hạn mức của các nhà cung cấp đang hoạt động cùng logo tương ứng. Linux hiển thị luân phiên logo nhà cung cấp và phần trăm trực tiếp trong biểu tượng khay hệ thống.

<div align="center">
  <img src="website/assets/birdnion-readme-bird-quota-384.png" width="196" alt="BirdNion mascot holding a blue and yellow quota bar" />
  <br />
  <strong>BirdNion — người bạn đồng hành theo dõi hạn mức</strong>
</div>

<br />

<div align="center">
  <img src="docs/images/logo.png" width="112" alt="BirdNion app icon" />
  <br />
  <strong>Biểu tượng ứng dụng BirdNion</strong>
</div>

<br />

<div align="center">
  <img src="docs/images/usage-overview.png" width="426" alt="BirdNion usage and cost overview" />
  <br />
  <strong>Tổng quan mức sử dụng và chi phí</strong>
</div>

<br />

<div align="center">
  <img src="website/assets/control-surface-redraw.jpg" width="776" alt="Illustrated BirdNion Linux control surface based on the current Settings implementation" />
  <br />
  <strong>Bảng điều khiển · minh họa dựa trên phần Cài đặt hiện tại của bản Linux</strong>
</div>

## Tính năng

- Tùy chọn luân phiên hiển thị các giá trị của nhà cung cấp trên thanh menu macOS hoặc biểu tượng khay hệ thống Linux, kèm công tắc bật/tắt nhà cung cấp và điều khiển sắp xếp phù hợp với từng nền tảng.
- Thanh đo mức sử dụng riêng cho từng nhà cung cấp, kèm đếm ngược đến lần đặt lại hạn mức.
- Hướng dẫn thiết lập đưa người dùng từ lỗi nhà cung cấp có thể khắc phục đến đúng điều khiển trong Cài đặt, lưu trước, rồi chỉ đánh dấu nhà cung cấp đang hoạt động sau khi bước tự kiểm tra thực tế thành công.
- Huy hiệu Trung tâm hành động nhỏ gọn ở đầu bảng bật lên mở Cài đặt để xử lý các vấn đề thiết lập/kết nối hiện tại; mục đã xử lý tự biến mất, không lưu lịch sử sự cố.
- Làm mới từng phần: dữ liệu của mỗi nhà cung cấp được cập nhật ngay khi truy xuất xong.
- Dữ liệu gần nhất vẫn hiển thị trong khi đang làm mới.
- Bộ chọn nguồn dữ liệu nhà cung cấp cho OAuth, CLI, cookie web, Admin API, trạng thái ứng dụng cục bộ và khóa tĩnh.
- Chu kỳ làm mới và khả năng hiển thị trên thanh menu riêng cho từng nhà cung cấp.
- Bộ chọn nguồn cookie với các chế độ Tự động, Thủ công và Tắt cho nhà cung cấp dùng cookie.
- Biểu đồ chi phí cục bộ từ 17 nguồn tác nhân — Claude, Codex, Grok, Kiro, Oh My Pi, Pi, Devin, OpenCode, Gemini CLI, Copilot CLI, Antigravity, Cursor, Amp, Droid, Kimi, Qwen Code và Goose — với lịch sử lưu bền vững theo giá trị cao nhất từng ghi nhận. Các cột đã lưu xuất hiện ngay trên giao diện, trong khi lượt quét dữ liệu hiện tại với phạm vi hẹp hơn cập nhật những ngày gần đây.
- Điểm nhấn Phân tích nhỏ gọn trong thẻ Tất cả mở Cài đặt -> Phân tích để so sánh 7 ngày và xếp hạng dự án trong 7/30/90 ngày. Claude, Codex và Grok tạo định danh dự án bảo vệ quyền riêng tư từ siêu dữ liệu phiên cục bộ; chỉ phần sử dụng còn lại không thể quy về dự án nào mới được ghi rõ là `Unknown`.
- Biểu đồ Claude Admin API 30 ngày và thông tin bổ sung từ bảng điều khiển web Codex khi được bật.
- Các giá trị hiển thị tùy chỉnh của Kiro: tín dụng còn lại, phần trăm, đã dùng/tổng cộng và các chế độ vượt hạn mức.
- Thông báo hạn mức và lỗi nhà cung cấp với ngưỡng có thể cấu hình.
- Tệp cấu hình XDG với quyền truy cập hạn chế.

## Cấu hình và lưu trữ

| Dữ liệu | Vị trí |
|---|---|
| Danh sách nhà cung cấp, cờ bật/tắt, khóa API, khu vực, ngân sách, ID dự án, URL cơ sở, nhãn tài khoản | `~/.config/birdnion/settings.json` |
| Ghi đè đường dẫn cấu hình | `$BIRDNION_CONFIG` |
| Ghi đè theo XDG | `$XDG_CONFIG_HOME/birdnion/settings.json` |
| Cấu hình cũ | `~/.birdnion/settings.json` |
| OAuth của Codex | `~/.codex/auth.json`, do Codex CLI quản lý |
| OAuth của Claude | Mục `Claude Code-credentials` trong Keychain trên macOS; `~/.claude/.credentials.json` trên Linux; cả hai đều do Claude Code/CLI quản lý |
| OAuth của Gemini | `~/.gemini/oauth_creds.json` |
| Phiên Cursor | macOS: `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`; Linux: `~/.config/Cursor/User/globalStorage/state.vscdb` |
| Tài khoản OAuth của Antigravity | `~/.config/birdnion/antigravity-oauth.json` |
| Tài khoản OAuth của Copilot | `~/.config/birdnion/copilot-accounts.json` |
| Tài khoản FreeModel do ứng dụng quản lý | macOS: `~/Library/Application Support/BirdNion/freemodel-accounts.json`; Linux: `~/.config/birdnion/freemodel-accounts.json` |
| Lịch sử chi phí hằng ngày (thẻ Tất cả) | `~/.config/birdnion/cost-history.json` (cùng thư mục với tệp cài đặt; hợp nhất theo giá trị cao nhất từng ghi nhận để vẫn giữ các cột dữ liệu cũ khi phiên tác nhân đã bị xóa) |
| Lịch sử chi phí dự án (Phân tích) | `~/.config/birdnion/project-cost-history.json` (kho lưu riêng, tùy chọn; khóa dự án/ID thu hồi dùng SHA-256, tên cuối đường dẫn an toàn, hợp nhất theo giá trị cao nhất từng ghi nhận nhưng không vượt tổng chi phí, `0600`) |
| Tùy chọn giao diện macOS | `UserDefaults` (`showPercentInMenuBar`, cài đặt hiển thị, làm mới, nguồn dữ liệu và cách trình bày) |
| Tùy chọn giao diện Linux | `localStorage` của Tauri WebView; các trường cookie/hiển thị/làm mới của nhà cung cấp vẫn nằm trong `settings.json` |

Thứ tự ưu tiên đường dẫn cấu hình:

1. `$BIRDNION_CONFIG`
2. `$XDG_CONFIG_HOME/birdnion/settings.json`
3. `~/.config/birdnion/settings.json`
4. `~/.birdnion/settings.json`

Tệp cấu hình được ghi theo cơ chế nguyên tử và đặt quyền truy cập `0600`.

## Lưu ý về quyền riêng tư

BirdNion không quét hệ thống tệp một cách không giới hạn. Ứng dụng chỉ đọc các vị trí đã được ghi trong tài liệu khi nhà cung cấp/nguồn dữ liệu liên quan được bật: tệp cấu hình nhà cung cấp, tệp xác thực CLI, kho cookie trình duyệt, cơ sở dữ liệu IDE cục bộ và nhật ký phiên tác nhân cục bộ. Token nhà cung cấp nằm trong tệp cấu hình BirdNion với quyền truy cập hạn chế. Các tệp phiên OAuth, Keychain và CLI vẫn do công cụ gốc quản lý.

Không lưu mật khẩu. Cookie trình duyệt chỉ được tái sử dụng khi người dùng chọn nguồn dữ liệu dùng cookie. Phần Phân tích không bao giờ lưu đường dẫn đầy đủ của dự án: Claude băm token ổn định của thư mục phiên, Codex băm `cwd` tuyệt đối đã được xác thực, còn Grok băm token đã mã hóa của thư mục phiên. Đường dẫn đã xác minh chỉ có thể dùng để cải thiện nhãn tên cuối đường dẫn đã được làm sạch; giao diện và bản tóm tắt để sao chép chỉ nhận nhãn an toàn đó hoặc một nhóm `Unknown` riêng cho phần còn lại.

## Lưu ý theo nền tảng

### Quyền trên macOS

- **Truy cập toàn bộ ổ đĩa** - không bắt buộc với chức năng cốt lõi của ứng dụng. Các nhà cung cấp dùng cookie trình duyệt có thể cần thêm quyền truy cập trên macOS, tùy trình duyệt và kho cookie.
- **Truy cập Keychain** - OAuth của Claude có thể đọc mục `Claude Code-credentials` do Claude Code/CLI quản lý; việc nhập cookie trình duyệt cũng có thể làm xuất hiện hộp thoại xin quyền truy cập mục Safe Storage của trình duyệt trong Keychain.
- **Hộp thoại xin quyền Tệp & Thư mục** - việc dò nguồn dữ liệu nhà cung cấp cục bộ có thể khiến macOS hỏi quyền nếu CLI/công cụ hỗ trợ bên dưới truy cập các vị trí được bảo vệ.
- **Những quyền BirdNion không yêu cầu ngầm** - không yêu cầu quyền Ghi màn hình hay Trợ năng.

### Linux

- Nhà cung cấp dùng cookie trình duyệt cần hồ sơ Chrome/Chromium/Brave/Edge/Firefox được hỗ trợ và có thể phụ thuộc vào kho khóa của môi trường desktop.
- Khay hệ thống luân phiên hiển thị logo nhà cung cấp và phần trăm trực tiếp trong biểu tượng vì các môi trường desktop Linux không có cách thống nhất để hiển thị văn bản bên cạnh biểu tượng khay.
- Phím tắt toàn cục không được bật trên Linux; hãy dùng cửa sổ ứng dụng và các điều khiển trong Cài đặt.

## Tài liệu

- [docs/build.md](docs/build.md) - dựng ứng dụng, ký và khắc phục sự cố.
- [docs/system-architecture.md](docs/system-architecture.md) - kiến trúc hệ thống và nhật ký các quyết định trước đây.
- [docs/development-roadmap.md](docs/development-roadmap.md) - lộ trình phát triển trước đây.
- [docs/provider-parity/README.md](docs/provider-parity/README.md) - đánh giá mức độ tương đương giữa BirdNion và CodexBar.
- [docs/linux-parity-matrix.md](docs/linux-parity-matrix.md) - mức độ tương đương tính năng giữa macOS/Linux.
- [linux/README.md](linux/README.md) - phát triển, đóng gói và lưu ý nền tảng cho Linux.

## Bắt đầu (dành cho nhà phát triển)

- Sao chép kho mã. Mở `BirdNion.xcodeproj` để phát triển cho macOS hoặc làm việc trong `linux/` để phát triển với Tauri.
- Khởi chạy một lần, rồi bật/tắt nhà cung cấp trong Cài đặt -> Nhà cung cấp.
- Cài đặt hoặc đăng nhập vào các nguồn dữ liệu bạn cần: CLI, cookie trình duyệt, OAuth/quy trình xác thực thiết bị, khóa API, ứng dụng của nhà cung cấp hoặc tệp cấu hình cục bộ.
- Tùy chọn: thiết lập cookie OpenAI để lấy thông tin bổ sung từ bảng điều khiển Codex và định tuyến nguồn dữ liệu Claude cho OAuth/Web/CLI/Admin API.

## Dựng từ mã nguồn

### macOS

Yêu cầu macOS 14+ và Xcode có hỗ trợ Swift cho scheme của dự án.

```bash
xcodebuild test -project BirdNion.xcodeproj -scheme BirdNion \
  -configuration Debug -destination 'platform=macOS'

xcodebuild build -project BirdNion.xcodeproj -scheme BirdNion \
  -configuration Release -destination 'platform=macOS'
```

BirdNion tích hợp sẵn gói `CodexBarCore` đã tinh gọn trong `Vendor/CodexBar`; không cần bản sao kho mã `~/Desktop/CodexBar` bên ngoài.

### Linux

Có thể phát triển và chạy kiểm thử từ `linux/` trên macOS hoặc Linux. Các gói Linux gốc phải được dựng trên Linux với các thư viện phụ thuộc WebKitGTK/AppIndicator đã cài đặt.

```bash
cd linux
npm ci
npm test
npm run build
cargo test --manifest-path src-tauri/Cargo.toml

# On Linux: build .deb, .rpm, and AppImage bundles
npm run tauri build
```

## Ghi nhận đóng góp

Lấy cảm hứng từ [CodexBar](https://github.com/steipete/CodexBar), đặc biệt là ý tưởng luôn hiển thị mọi giới hạn lập trình AI mà không cần mở bảng điều khiển. BirdNion duy trì hệ thống nhà cung cấp, cấu hình và phân phối đa nền tảng riêng.

## Giấy phép

MIT.
