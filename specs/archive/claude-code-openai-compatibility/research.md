# Nghiên cứu: Claude Code OpenAI Compatibility

## Bằng chứng mã nguồn

- `BirdNion/Views/Settings/ClaudeCodeCustomProfileForm.swift` hiện chỉ thu thập endpoint/token Anthropic-compatible.
- `BirdNion/Services/ClaudeCodeConfigWriter.swift` chỉ ghi `ANTHROPIC_BASE_URL` cùng token và model keys vào Claude Code settings.
- `CLIProxyAPI/internal/translator/openai/claude/init.go` đăng ký `Claude -> OpenAI` request converter và `OpenAI -> Claude` response converter.
- `CLIProxyAPI/internal/api/server.go` phục vụ Claude endpoint tại `POST /v1/messages` và bảo vệ nó bằng proxy API key.
- Cùng server có protected management endpoint `GET|PUT /v0/management/openai-compatibility`; yêu cầu management key.
- Management entry cần `name`, `base-url`, `api-key-entries`, và `models`; `prefix` namespace alias để nhiều profile không đụng model routing.

## Kết luận kiến trúc

Swift không thể gọi trực tiếp Go internal converter. BirdNion sẽ cấu hình CLIProxyAPI đang chạy, sau đó Claude Code gọi proxy qua Anthropic API. CLIProxyAPI mới là process thực thi chuyển đổi protocol.

## Rủi ro

- `PUT /openai-compatibility` thay toàn bộ danh sách, nên client phải GET trước và chỉ thay entry có prefix do BirdNion sở hữu.
- Nếu management API lỗi, không được ghi local Claude settings vì profile sẽ trỏ đến proxy chưa có upstream.
- Secret upstream và management key phải chỉ nằm trong BirdNion config 0600; Claude settings chỉ nhận proxy API key.

## Evidence Summary

- Contract converter được xác nhận trực tiếp tại `CLIProxyAPI/internal/translator/openai/claude/init.go`.
- Route proxy và management được xác nhận tại `CLIProxyAPI/internal/api/server.go`.
- Schema management entry được xác nhận tại `CLIProxyAPI/internal/config/config.go` và `internal/api/handlers/management/config_lists.go`.
- Điểm mount/form/writer BirdNion được xác nhận tại `ClaudeCodePane.swift`, `ClaudeCodeCustomProfileForm.swift`, `BirdNionConfigStore.swift`, và `ClaudeCodeConfigWriter.swift`.
