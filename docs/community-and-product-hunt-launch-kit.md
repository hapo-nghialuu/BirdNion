# BirdNion Community & Product Hunt Launch Kit

> Trạng thái: **PREPARED — NOT PUBLISHED**
> Cập nhật: 2026-08-28
> Phạm vi: Cursor Community Forum, r/ClaudeCode Weekly Showcase và Product Hunt. Private cohort và Show HN tạm hoãn theo quyết định maintainer.

## Positioning đã khóa

**English**

> Know what is left, when the selected source says it resets, and what needs fixing — on macOS or Linux.

**Tiếng Việt**

> Biết quota còn bao nhiêu, khi nào source báo reset và nguồn nào cần sửa — trên macOS hoặc Linux.

BirdNion là desktop companion miễn phí, mã nguồn mở MIT, giữ quota AI coding, thời điểm reset và local cost được hỗ trợ ngay trên menu bar macOS hoặc system tray Linux.

## Trust disclosure dùng ở mọi kênh

- Không có BirdNion account hoặc BirdNion backend.
- Chỉ đọc nguồn đã được tài liệu hóa khi người dùng bật provider/source tương ứng. Một số source có thể dùng local CLI/OAuth state, browser cookie, API key hoặc gọi provider API.
- Không lưu password và không quét toàn bộ filesystem.
- Bản macOS hiện `ad-hoc signed`; Developer ID/notarization đang pause. README ghi rõ Homebrew/Gatekeeper behavior.
- Linux phát hành cho `x86_64` dưới dạng `.deb`, `.rpm` và `.AppImage`.
- Không quảng bá Windows, auto-update, metric người dùng hoặc capability chưa có evidence.

## Link chuẩn, không tracking

- Landing: <https://birdnion.vercel.app/>
- Source: <https://github.com/hapo-nghialuu/BirdNion>
- Latest release: <https://github.com/hapo-nghialuu/BirdNion/releases/latest>
- Privacy map: <https://github.com/hapo-nghialuu/BirdNion#privacy-note>
- License: <https://github.com/hapo-nghialuu/BirdNion/blob/main/LICENSE>

Không dùng URL shortener, referral link, UTM hoặc query tracking.

## 1. GitHub soft launch

### Repository surface

- Description: `Open-source AI coding quota companion for the macOS menu bar and Linux system tray.`
- Homepage: <https://birdnion.vercel.app/>
- Topics: `macos`, `linux`, `menu-bar`, `system-tray`, `ai-tools`, `quota-tracker`, `swiftui`, `tauri`.
- Latest release phải có macOS `.zip` và Linux `.deb`, `.rpm`, `.AppImage`, kèm digest do GitHub công bố.

### Ready-to-post — English

```text
BirdNion is now available as an open-source desktop companion for AI coding quotas.

It keeps the quota and reset information exposed by Claude, Codex, Gemini, Cursor, Grok, and other supported sources one click away in the macOS menu bar or Linux system tray. Supported Claude, Codex, and Grok session logs can also produce local cost history.

BirdNion is free and MIT-licensed. There is no BirdNion account or backend: you choose each provider source, and the app keeps source, freshness, and error state explicit.

Platforms:
- macOS 14+ via Homebrew or GitHub Releases
- Linux x86_64 via .deb, .rpm, or .AppImage

Landing: https://birdnion.vercel.app/
Source and downloads: https://github.com/hapo-nghialuu/BirdNion

Current limitation: the macOS build is ad-hoc signed rather than Developer ID notarized. The README documents the exact Homebrew and Gatekeeper behavior.

If you try it, which coding-tool quota or reset signal still makes you open another dashboard?
```

### Ready-to-post — Tiếng Việt

```text
BirdNion đã sẵn sàng dưới dạng ứng dụng desktop mã nguồn mở để theo dõi quota AI coding.

Ứng dụng giữ quota và thời điểm reset mà Claude, Codex, Gemini, Cursor, Grok cùng các nguồn được hỗ trợ cung cấp ngay trên menu bar macOS hoặc system tray Linux. Session log Claude, Codex và Grok được hỗ trợ cũng có thể tạo lịch sử chi phí local.

BirdNion miễn phí, giấy phép MIT, không có BirdNion account hoặc backend. Bạn chọn từng provider source; ứng dụng luôn thể hiện rõ source, freshness và error state.

Nền tảng:
- macOS 14+ qua Homebrew hoặc GitHub Releases
- Linux x86_64 qua .deb, .rpm hoặc .AppImage

Landing: https://birdnion.vercel.app/
Source và tải xuống: https://github.com/hapo-nghialuu/BirdNion

Giới hạn hiện tại: bản macOS được ad-hoc signed, chưa có Developer ID/notarization. README ghi rõ cách cài Homebrew và xử lý Gatekeeper.

Nếu dùng thử, quota hoặc reset signal nào vẫn khiến bạn phải mở thêm dashboard?
```

### D0 checklist

- [x] Description, homepage và topics công khai đã đồng bộ.
- [x] Latest release có đủ bốn package macOS/Linux.
- [x] Landing, release và privacy anchor mở được.
- [x] macOS ad-hoc signing được disclose trên landing và README.
- [ ] Maintainer đăng bài soft-launch thủ công và điền URL thật vào bảng publication.

## 2. Cursor Community Forum

Cách GitHub soft launch tối thiểu một nhịp support; không đăng đồng loạt.


### Policy lane

- Đăng tại [Showcase → Built for Cursor](https://forum.cursor.com/c/showcase/9).
- Recheck [Cursor Community Guidelines](https://forum.cursor.com/guidelines) ngay trước khi publish.
- Dùng một standalone topic, disclosure maintainer ngay đầu; không link-drop vào thread khác.
- Xác nhận account đã có đóng góp hữu ích trước khi self-promote; nếu chưa có thì chưa đăng.

### Title

```text
BirdNion — open-source Cursor quota tracking in the macOS menu bar and Linux tray
```

### Ready-to-post — English

```text
I’m the maintainer of BirdNion, a free and MIT-licensed desktop companion for AI coding quotas.

I built it because checking a dashboard — or discovering a limit only after a coding session stops — was too disruptive. BirdNion keeps Cursor usage one click away in the macOS menu bar or Linux system tray. Cursor billing-cycle reset timing is currently surfaced on macOS; the Linux view does not yet expose that cycle date.

For Cursor, BirdNion reads Cursor’s local state.vscdb first and can use an enabled browser-session source as a fallback. It can show the usage summary, account identity, and request usage exposed by those sources. It does not store passwords or scan the filesystem without bounds.

BirdNion also brings Claude, Codex, Gemini, Grok, and other documented provider sources into the same desktop surface, but Cursor is the focus of this post.

Current platforms:
- macOS 14+ via Homebrew or GitHub Releases
- Linux x86_64 via .deb, .rpm, or .AppImage

Source and install: https://github.com/hapo-nghialuu/BirdNion
Privacy map: https://github.com/hapo-nghialuu/BirdNion#privacy-note

One current limitation worth stating up front: the macOS release is ad-hoc signed, not Developer ID notarized. The exact install and Gatekeeper behavior is documented in the README.

If you use Cursor, I’d value one very specific kind of feedback: which usage or reset signal is missing or differs from what you see in Cursor’s dashboard?
```

### Bản companion — Tiếng Việt

```text
Tôi là maintainer của BirdNion, ứng dụng desktop miễn phí và mã nguồn mở MIT để theo dõi quota AI coding.

BirdNion đặt usage của Cursor ngay trên menu bar macOS hoặc system tray Linux. Billing-cycle reset của Cursor hiện được surface trên macOS; Linux chưa hiển thị cycle date này. Ứng dụng ưu tiên state.vscdb cục bộ và có thể dùng browser session làm fallback khi người dùng bật nguồn đó. BirdNion không lưu password và không quét filesystem không giới hạn.

Nền tảng hiện tại là macOS 14+ và Linux x86_64. Bản macOS đang ad-hoc signed, chưa có Developer ID/notarization; README ghi rõ cách cài và Gatekeeper behavior.

Source/cài đặt: https://github.com/hapo-nghialuu/BirdNion
Privacy map: https://github.com/hapo-nghialuu/BirdNion#privacy-note

Nếu bạn dùng Cursor: usage/reset signal nào đang thiếu hoặc lệch so với Cursor dashboard?
```

**Media:** `website/assets/product-hunt-gallery-01-overview.png` hoặc `product-hunt-gallery-02-data-trust.png`. Không dùng browser/mock render như native capture.

## 3. r/ClaudeCode Weekly Showcase

### Policy lane

- Đăng một top-level comment trong pinned/current `Weekly Showcase Thread` của [r/ClaudeCode](https://www.reddit.com/r/ClaudeCode/).
- Không tạo standalone self-promo post; không referral, affiliate, spam hoặc xin upvote.
- Weekly thread quay vòng, nên phải xác nhận đúng thread hiện hành ngay trước lúc đăng.

### Ready-to-post — English

```text
I maintain BirdNion, a free, MIT-licensed macOS menu-bar and Linux tray app for AI coding quotas.

What it does: BirdNion keeps Claude’s 5-hour, weekly, Opus, and Sonnet windows visible alongside reset timing and supported local cost insights. You choose the Claude source — OAuth, browser session, CLI, or Admin API — and the UI keeps source and error state explicit instead of pretending every reading has the same confidence.

How it works: the macOS app is native SwiftUI/AppKit; the Linux app uses Tauri with a Rust core. Both use documented provider/source paths and share provider configuration. There is no BirdNion account or backend. Some enabled sources can contact their provider, and the privacy map says exactly what may be read.

The broader use case is seeing Claude beside Codex, Cursor, Gemini, Grok, and other coding-tool quotas without opening several dashboards.

The biggest implementation lesson so far: “quota” is not one universal API. Freshness, reset semantics, account identity, and recovery paths have to remain explicit per source or the desktop number becomes misleading.

Source/install: https://github.com/hapo-nghialuu/BirdNion
Privacy map: https://github.com/hapo-nghialuu/BirdNion#privacy-note

Current limitation: the macOS release is ad-hoc signed rather than Developer ID notarized; Linux x86_64 packages are available as .deb, .rpm, and .AppImage.

I’d especially like to hear which Claude quota window or reset signal you still have to open another page to verify.
```

### Bản companion — Tiếng Việt

```text
Tôi duy trì BirdNion, ứng dụng miễn phí, mã nguồn mở MIT chạy ở menu bar macOS và system tray Linux để theo dõi quota AI coding.

BirdNion giữ các cửa sổ 5-hour, weekly, Opus và Sonnet của Claude dễ nhìn, kèm thời điểm reset và local cost insight được hỗ trợ. Người dùng chọn OAuth, browser session, CLI hoặc Admin API; UI luôn nói rõ source/error state.

Bản macOS dùng SwiftUI/AppKit native; bản Linux dùng Tauri với Rust core. BirdNion không có account/backend riêng. Privacy map ghi rõ dữ liệu nào có thể được đọc. Bản macOS hiện ad-hoc signed, chưa có Developer ID/notarization.

Source/cài đặt: https://github.com/hapo-nghialuu/BirdNion
Privacy map: https://github.com/hapo-nghialuu/BirdNion#privacy-note

Cửa sổ quota hoặc reset signal nào của Claude vẫn buộc bạn mở trang khác để kiểm tra?
```

Đăng sau Cursor tối thiểu 72 giờ để đủ khả năng support; không lặp lại tuần sau nếu không có update đáng kể.

## 4. Product Hunt

### Listing fields — English primary

**Name**

```text
BirdNion
```

**Tagline — 47/60 characters**

```text
AI coding quotas in your menu bar or Linux tray
```

**Description — 163/260 characters**

```text
BirdNion keeps AI coding quotas, reset windows, and supported local cost one click away on macOS or Linux. Free, MIT-licensed, with no BirdNion account or backend.
```

**Launch tags**

Ưu tiên `AI Coding Agents` và `Vibe Coding Tools`. Product Hunt cho chọn tối đa ba tag; chỉ chọn tag thực sự xuất hiện trong submission UI.

### Maker first comment

```text
Hi Product Hunt — I’m BirdNion’s maintainer.

I built it after too many coding sessions were interrupted by a quota I could have planned around if the reset window had been visible. I wanted a quiet desktop instrument, not another dashboard or account to maintain.

The difficult part was not drawing a percentage. Different tools expose quota through different local files, CLI/OAuth sessions, browser sources, or APIs. BirdNion keeps that source, freshness, and failure state visible so a number is not presented with more confidence than its evidence supports.

Today BirdNion runs in the macOS menu bar and Linux system tray. It is free, MIT-licensed, and has no BirdNion backend or account. The README documents every supported data path and the current signing limitation: macOS is ad-hoc signed, not yet Developer ID notarized.

I’m here for concrete feedback, especially:
1. Which coding-tool quota still surprises you?
2. Which reset or recovery detail would make the desktop view trustworthy enough to rely on?

Thanks for taking a look — I’ll answer technical and privacy questions directly.
```

### Bản companion — Tiếng Việt

```text
Quota AI coding ngay trên menu bar hoặc Linux tray

BirdNion đặt quota AI coding, thời điểm reset và local cost được hỗ trợ ngay trên macOS hoặc Linux. Miễn phí, mã nguồn mở MIT, không cần BirdNion account/backend.

Tôi làm BirdNion sau nhiều lần phiên code bị ngắt bởi một quota lẽ ra có thể dự đoán nếu thời điểm reset luôn hiện trước mắt. Mỗi coding tool cung cấp quota qua local file, CLI/OAuth session, browser source hoặc API khác nhau, nên BirdNion luôn giữ source, freshness và failure state dễ thấy. Bản macOS hiện ad-hoc signed, chưa có Developer ID/notarization.
```

### Media contract

| Thứ tự | File | Kích thước | Alt text |
|---|---|---:|---|
| Thumbnail | `website/assets/product-hunt-thumbnail.png` | 240×240 | BirdNion quota mascot trên nền giấy ấm. |
| Gallery 1 | `website/assets/product-hunt-gallery-01-overview.png` | 1270×760 | BirdNion overview for quota and resets on macOS and Linux. |
| Gallery 2 | `website/assets/product-hunt-gallery-02-data-trust.png` | 1270×760 | Explanatory data-trust card listing enabled sources and explicit freshness/error state. |
| Gallery 3 | `website/assets/product-hunt-gallery-03-platform-install.png` | 1270×760 | Platform/install card for macOS 14+ and Linux x86_64, including the macOS signing limitation. |

Ba gallery trên là explanatory marketing cards, không phải native product screenshots. Không dùng `control-surface-redraw.jpg` hoặc browser/mock render làm capability proof.

### Pre-publish checklist

- [ ] Product Hunt account đủ điều kiện tạo launch; account mới có thể phải chờ theo policy hiện hành.
- [x] Tagline `47/60`, description `163/260`, tối đa ba launch tag.
- [x] Thumbnail 240×240; ba gallery image 1270×760; mọi file dưới 3 MB.
- [x] Maintainer chấp nhận dùng explanatory cards thay native captures trong iteration này; asset/copy không gọi các card là product capture.
- [x] Landing, release, install commands và privacy anchor mở được.
- [x] macOS ad-hoc signing được disclose.
- [x] Không tracked/short link, fake urgency, testimonial, metric hoặc coordinated upvote.
- [ ] Maintainer có thời gian trực launch window.
- [ ] Cursor account đã có đóng góp hữu ích trước self-promotion; không dùng account mới chỉ để drop link.
- [ ] Đọc lại [Before launch](https://www.producthunt.com/launch/before-launch) và [Preparing for launch](https://www.producthunt.com/launch/preparing-for-launch) trong ngày publish.

### Readiness receipt — 2026-09-21

- Cursor guideline công khai xác nhận Showcase chấp nhận sản phẩm làm với/cho Cursor, nhưng yêu cầu contribute first, disclosure minh bạch, liên quan đúng topic, không link-drop/spam và không dùng bài hoàn toàn do AI tạo. Draft hiện tại vẫn cần maintainer viết lại bằng giọng cá nhân trước khi đăng.
- `r/ClaudeCode` đang dùng recurring `Weekly Showcase Thread`; candidate thread tìm thấy ngày 2026-09-21 là <https://www.reddit.com/r/ClaudeCode/comments/1w9pn3e/weekly_showcase_thread_what_are_you_building_with/>. Thread quay vòng nên URL phải được maintainer xác nhận lại trong ngày đăng.
- Product Hunt pages trả Cloudflare `403` cho automated reader/browser trong lần kiểm tra này. Contract tagline/description/assets hiện pass theo launch kit, nhưng account eligibility, tags có trong submission UI và policy cuối vẫn là manual same-day gate.
- Asset proof: thumbnail PNG `240×240`, `40,856` bytes; ba gallery PNG `1270×760`, lần lượt `158,555`, `49,023`, `51,847` bytes.

## Publication sequence và evidence

1. GitHub soft launch.
2. Cursor Community Forum sau khi đã xử lý phản hồi GitHub ban đầu.
3. Sau Cursor tối thiểu 72 giờ: r/ClaudeCode Weekly Showcase.
4. Hấp thụ objection/fix copy từ các kênh trên.
5. Product Hunt chỉ publish sau manual account/policy/link/media preflight.

| Kênh | URL bài thật | Trạng thái |
|---|---|---|
| GitHub soft launch | Chưa có | READY — AWAITING MANUAL POST |
| Cursor Community | Chưa có | NOT PUBLISHED |
| r/ClaudeCode | Chưa có | NOT PUBLISHED |
| Product Hunt | Chưa có | NOT PUBLISHED |

### Deferred maintainer inputs — 2026-09-21

Maintainer đã yêu cầu ghi nhận và tiếp tục phần chuẩn bị, chưa publish thủ công. Các đầu vào sẽ được cung cấp sau:

- Phiên đăng nhập hoặc URL bài GitHub soft-launch sau khi maintainer đăng.
- Cursor Community account đủ điều kiện và URL topic sau khi đăng.
- URL `r/ClaudeCode` Weekly Showcase thread hiện hành và URL comment sau khi đăng.
- Product Hunt maker account/browser session, launch window và URL draft/live.
- Người trực support trong từng launch window.

Cho tới khi có các đầu vào trên, không đổi trạng thái kênh thành `PUBLISHED` và không tự suy diễn URL.


### Support log tối thiểu

| Thời gian | Kênh | Platform | Provider đầu tiên | Blocker/câu hỏi nguyên văn | Owner | Kết quả |
|---|---|---|---|---|---|---|
| — | — | — | — | — | — | — |

Tổng hợp acquisition theo referrer/traffic và download theo asset ở mức aggregate. Không nối thành user-level funnel, không suy diễn download thành activation và không dùng stars/upvotes làm bằng chứng sử dụng.

Chỉ ghi một bài là hoàn thành khi có URL thật.

## Unresolved questions

- Maintainer đã chấp nhận dùng explanatory marketing cards hiện có thay cho native captures trong iteration này; các card vẫn phải được ghi rõ không phải product capture.
- Authenticated account/browser session, launch window, support owner và URL bài thật được hoãn để maintainer cung cấp sau.
- Policy có thể đổi; cả hai community lane và Product Hunt requirements phải được recheck ngay trước khi đăng.
