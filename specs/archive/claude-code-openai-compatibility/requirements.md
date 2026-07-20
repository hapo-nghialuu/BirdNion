# Yêu cầu: Claude Code OpenAI Compatibility

## Introduction

Người dùng cần dùng một OpenAI-compatible upstream với Claude Code từ màn hình Custom config. Claude Code vẫn nói Anthropic protocol; CLIProxyAPI đang chạy sẽ đảm nhiệm chuyển đổi Anthropic <-> OpenAI.

## Requirements

### Requirement 1: Hồ sơ tương thích và cấu hình proxy

**Objective:** Là người dùng BirdNion, tôi muốn một custom profile phân biệt rõ Anthropic Compatible và OpenAI Compatible, để dữ liệu cấu hình phù hợp được lưu an toàn.

#### Acceptance Criteria
- **R1.1** When BirdNion đọc profile cũ không có protocol mode, the system shall xử lý nó như Anthropic Compatible mà không làm mất dữ liệu.
- **R1.2** When người dùng chọn OpenAI Compatible, the system shall lưu OpenAI upstream URL/key và CLIProxyAPI URL/proxy API key/management key riêng với endpoint/token Anthropic trực tiếp.
- **R1.3** The system shall dùng một provider prefix ổn định, riêng cho mỗi profile OpenAI, để model alias không va chạm profile khác.
- **R1.4** The system shall coi OpenAI profile là chưa sẵn sàng nếu thiếu upstream URL/key, proxy URL/proxy API key/management key, hoặc không có model mapping nào.

### Requirement 2: Giao diện custom profile

**Objective:** Là người dùng BirdNion, tôi muốn chọn protocol trong form và chỉ thấy các trường có ý nghĩa, để không nhầm token của upstream với key của proxy.

#### Acceptance Criteria
- **R2.1** When custom profile được mở, the system shall hiển thị control chọn Anthropic Compatible hoặc OpenAI Compatible.
- **R2.2** When Anthropic Compatible được chọn, the system shall giữ nguyên form Base URL, Token và Token env key hiện tại.
- **R2.3** When OpenAI Compatible được chọn, the system shall hiển thị các field OpenAI upstream và CLIProxyAPI riêng, đồng thời không hiển thị token env key Anthropic.
- **R2.4** The system shall giữ form model hiện có; ở OpenAI mode các model này là upstream model names được map 1:1 thành aliases cho Claude Code.
- **R2.5** The system shall có label vi/en cho toàn bộ string mới.

### Requirement 3: Đăng ký proxy và áp dụng Claude Code

**Objective:** Là người dùng BirdNion, tôi muốn một lần bật profile OpenAI sẽ cấu hình proxy và Claude Code theo đúng thứ tự, để request thực tế được chuyển đổi được.

#### Acceptance Criteria
- **R3.1** When người dùng bật/stale OpenAI profile, the system shall GET danh sách `openai-compatibility`, cập nhật hoặc thêm đúng entry BirdNion-owned rồi PUT danh sách về `v0/management/openai-compatibility` bằng management key.
- **R3.2** The system shall cấu hình entry OpenAI bằng upstream URL/key và các model mappings, với `prefix` riêng của profile.
- **R3.3** When proxy registration thành công, the system shall ghi Claude Code `ANTHROPIC_BASE_URL` là proxy URL, token là proxy API key, và model defaults có prefix riêng.
- **R3.4** If proxy registration trả lỗi mạng, HTTP hoặc body không hợp lệ, then the system shall hiển thị lỗi và không ghi/đổi Claude Code settings.
- **R3.5** When Anthropic profile được bật, the system shall giữ nguyên writer behavior hiện tại và không gọi CLIProxyAPI.

### Requirement 4: Bảo mật và ownership

**Objective:** Là người dùng, tôi muốn secret và remote config được xử lý có ownership rõ ràng, để BirdNion không làm lộ hoặc xóa cấu hình ngoài phạm vi.

#### Acceptance Criteria
- **R4.1** The system shall không ghi OpenAI upstream key hoặc management key vào Claude Code settings.
- **R4.2** The system shall không log secret trong lỗi hoặc request diagnostics.
- **R4.3** When custom profile bị xóa hoặc chuyển về Anthropic mode, the system shall không xóa entry trên CLIProxyAPI tự động.

## Non-Functional Requirements

### Requirement 5: Khả năng kiểm thử và phản hồi lỗi

**Objective:** Là maintainer, tôi muốn contract HTTP và writer có kiểm thử xác định, để thay đổi CLIProxyAPI không âm thầm làm hỏng setup.

#### Acceptance Criteria
- **R5.1** The system shall có XCTest chứng minh request management API dùng đúng URL, Authorization, payload và preserve entry không thuộc BirdNion.
- **R5.2** The system shall có XCTest chứng minh OpenAI profile ghi đúng proxy env/model prefix và direct Anthropic profile không đổi behavior.
