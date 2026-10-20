<div align="center">
  <img src="docs/social.png" alt="BirdNion - AI quota companion for macOS and Linux" />
</div>

# BirdNion - 愿你的 AI 智能体始终不超预算。

> 在 macOS 菜单栏或 Linux 系统托盘中，掌握各个 AI 编程工具的额度与智能体设置。

[English](README.md) · [Tiếng Việt](README.vi.md) · **中文** · [日本語](README.ja.md) · [한국어](README.ko.md) · [Español](README.es.md) · [Deutsch](README.de.md) · [Français](README.fr.md)


[![Latest release](https://img.shields.io/github/v/release/hapo-nghialuu/BirdNion?style=flat-square&color=0a0a0c)](https://github.com/hapo-nghialuu/BirdNion/releases/latest)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-0a0a0c?style=flat-square)](https://github.com/hapo-nghialuu/BirdNion/releases/latest)
[![Linux x86_64](https://img.shields.io/badge/Linux-x86__64-fcc624?style=flat-square&logo=linux&logoColor=111)](https://github.com/hapo-nghialuu/BirdNion/releases/latest)
[![Homebrew](https://img.shields.io/badge/brew-hapo--nghialuu%2Ftap%2Fbirdnion-orange?style=flat-square)](https://github.com/hapo-nghialuu/homebrew-tap)
[![License: MIT](https://img.shields.io/badge/license-MIT-6e5aff?style=flat-square)](LICENSE)

支持 38 个服务商。BirdNion 是一款小巧的 macOS 14+ 菜单栏应用和 Linux 托盘应用，让 AI 编程额度一目了然，显示各额度周期的重置时间，并集中管理各编程智能体的数据读取方式。支持 Codex、Claude、MiniMax、OpenRouter、DeepSeek、z.ai、ElevenLabs、Deepgram、Groq、Grok、xAI、OpenAI、Ollama、GitHub Copilot、Kilo、Command Code、Xiaomi MiMo、Alibaba/Qwen、Cursor、Gemini、Kiro、OpenCode、OpenCode Go、Antigravity、AWS Bedrock、FreeModel、Devin 和 Hapo AI Hub，以及 JavaScript 插件服务商（Aixy、Atlas Cloud、ClinePass、LiteLLM、Muse Code、Nous Portal、Raycast、Sakana AI、Venice、xKiro）。

原生 macOS 应用使用 SwiftUI/AppKit，并在仓库中内置了精简版 `CodexBarCore` 子集。Linux 移植版位于 `linux/`，使用 Tauri v2、Rust 核心和原生 TypeScript 界面。两个平台共用相同的 XDG 服务商配置结构。

## 为什么选择 BirdNion

- **围绕重置时间安排工作。** 按服务商展示 5 小时、每周、每月、点数和预算额度，并提供重置倒计时。
- **查看支出与费用。** 支持 Claude 本地 JSONL 扫描、每周用量洞察、保护隐私的项目排行、Claude Admin API 图表、Codex 点数、OpenRouter 余额、Bedrock 预算，以及各服务商可提供的费用和点数汇总。
- **配置智能体数据源。** 在设置中为每个服务商选择 OAuth、CLI、浏览器 Cookie、API 密钥、AWS 凭据、本地应用文件或服务商应用。
- **切换工具，不丢上下文。** macOS 和 Linux 均支持自定义 Claude/Codex 配置切换、Codex 重置点数/自动预热，以及 Codex、Copilot、Antigravity 和 FreeModel 的多账号流程。
- **桌面信息简洁不打扰。** macOS 可在菜单栏轮播服务商额度百分比；Linux 则直接在托盘图标中轮播服务商标识和百分比。
- **隐私优先。** BirdNion 复用已有会话和明确指定的配置，不存储密码，也不会无范围限制地扫描磁盘。

## 安装

### 系统要求

- macOS 14+（Sonoma）
- 已发布的 `.deb`、`.rpm` 和 `.AppImage` 安装包适用于 Linux x86_64

### GitHub 发行版本

从 [GitHub 发行版本](https://github.com/hapo-nghialuu/BirdNion/releases)下载预编译安装包：

- `BirdNion-<version>.zip` - macOS 通用应用，已使用 Developer ID 签名并通过 Apple 公证。
- `BirdNion_<version>_amd64.deb` - Ubuntu/Debian 安装包。
- `BirdNion-<version>-1.x86_64.rpm` - Fedora/RHEL 安装包。
- `BirdNion_<version>_amd64.AppImage` - Linux 便携版。
- Homebrew cask 使用 SHA256 校验。
- 公证票据已附加到应用中，因此完成常规的“从互联网下载”确认后，Gatekeeper 即可直接放行，即使离线也能打开。

### 在 macOS 上通过 Homebrew 安装

推荐安装命令：

```bash
brew install --cask hapo-nghialuu/tap/birdnion
```

完整限定命令明确指定了 `hapo-nghialuu/tap/birdnion`，因此无需单独执行 `brew tap`。

添加 tap 后，也可使用简短名称安装：

```bash
brew tap hapo-nghialuu/tap
brew trust --cask hapo-nghialuu/tap/birdnion
brew install --cask birdnion
```

也可以信任整个 tap：

```bash
brew trust hapo-nghialuu/tap
brew install --cask birdnion
```

请勿将 `HOMEBREW_NO_REQUIRE_TAP_TRUST=1` 作为常规安装方式。这是用户端的环境覆盖选项，不能放入 `Casks/birdnion.rb` 中，在 Homebrew 加载 cask 前绕过信任检查。

### 更新 macOS 版

```bash
brew update && brew upgrade --cask birdnion
```

先运行 `brew update`（通过 `&&` 串联），确保 tap 拉取最新的 cask；
单独执行 `brew upgrade` 不会刷新第三方 tap，仍会针对旧版本提示
“已安装”。

验证已安装的版本：

```bash
brew list --cask --versions birdnion   # or: brew info --cask birdnion
```

### Linux

从[最新发行版本](https://github.com/hapo-nghialuu/BirdNion/releases/latest)下载一个 Linux 安装包：

```bash
sudo apt install ./BirdNion_<version>_amd64.deb
# or
sudo dnf install ./BirdNion-<version>-1.x86_64.rpm
# or
chmod +x BirdNion_<version>_amd64.AppImage
./BirdNion_<version>_amd64.AppImage
```

### 首次运行

- 从 macOS 菜单栏或 Linux 系统托盘打开 BirdNion。
- 打开“设置 -> 服务商”，启用你使用的服务商。
- 根据服务商要求，安装或登录所需的数据源：CLI、浏览器会话、OAuth/设备授权流程、API 密钥、本地应用文件或云凭据。
- 可选：设置服务商账号标签、菜单栏可见性、刷新间隔、Cookie 来源、区域、AWS 认证模式、Kilo 组织范围、Copilot 企业主机，或该服务商在菜单栏显示的指标。

## 智能体设置与配置

BirdNion 的目标不只是查看额度，还要成为 AI 编程智能体的轻量级设置与配置控制台。

目前已支持：

- 服务商启用开关、排序、账号标签、刷新间隔和菜单栏可见性。
- 为支持 OAuth、CLI、浏览器 Cookie、Admin API 或本地应用状态的服务商提供数据源选择。
- 服务商专属设置：Cookie 模式、手动 Cookie 请求头、MiniMax/z.ai/Alibaba 区域、AWS 密钥/配置/区域、Deepgram 项目 ID、Kilo 组织范围、Copilot 企业主机，以及菜单栏指标选择。
- 发现自行管理认证状态的智能体本地会话，包括 Claude Code、Codex CLI、Gemini CLI、Kiro、Cursor、Antigravity 等工具。
- Claude Code 配置控制台，支持预设/自定义后端、模型档位、全局或项目作用域、JSON 导入，以及安全移除由 BirdNion 管理的环境变量键。
- 自定义 Claude Code 和 Codex 配置切换，展示真实的就绪/过期/代理健康状态，并在检查失败时拒绝激活。
- Codex、GitHub Copilot、Antigravity 和 FreeModel 的多账号发现与切换，包括按浏览器区分的 FreeModel 会话。

后续方向：

- 将配置管理从 Claude Code 扩展到更多编程智能体。
- 展示每个智能体更详细的登录与数据源健康状态。
- 验证本地配置路径和 CLI 可用性。
- 为 Claude Code、Codex CLI、Gemini CLI、Kiro 及未来支持的智能体提供初始设置提示。
- 将 BirdNion 偏好设置保留在自身配置层，不改动各智能体的凭据存储。

## 服务商

- **Codex** - 从 `~/.codex/auth.json` 读取 OAuth API 凭据，支持 API 密钥回退、本地 `codex app-server` 回退、服务状态、版本、点数、重置点数、可选的 OpenAI 网页附加数据，以及托管账号切换。
- **Claude** - 支持 OAuth API、浏览器 Cookie、CLI 或 Admin API；提供 5 小时/每周/Opus/Sonnet 额度周期、Daily Routines、本地费用扫描、网页附加数据（额外用量支出和剩余预付点数），以及管理员 30 天图表。Max 套餐会显示其用量倍数（Max 5x / Max 20x）。
- **MiniMax** - 使用 API 令牌、环境变量令牌或 Cookie 回退，读取编程套餐用量、套餐名称、点数/订阅，以及国际/中国大陆区域信息。
- **OpenRouter** - 使用 API 令牌读取预付点数，以及可选的单密钥支出上限。
- **DeepSeek** - 使用 API 令牌读取美元/人民币余额，区分充值与赠送余额，并提供低余额提醒。
- **z.ai** - 使用 API 令牌和国际/中国大陆区域设置，读取额度上限并计算剩余百分比。
- **ElevenLabs** - 使用 API 密钥读取字符点数、语音槽位、专业语音、套餐和订阅状态。
- **Deepgram** - 使用 API 密钥及可选的项目 ID 读取用量汇总，支持汇总所有项目的模式。
- **Groq** - 使用 API 密钥读取基于 Prometheus 的请求数、Token 数和缓存命中指标。
- **Grok** - 从 `~/.grok/auth.json`（`grok login`）零配置读取；先尝试 CLI `x.ai/billing` RPC，再通过 Chrome Cookie / Bearer 认证访问 grok.com 账单 gRPC-web；提供 SuperGrok 身份与点数周期。“全部”标签页从 `~/.grok/sessions/**/signals.json` 统计本地费用（Token 总数 × 混合模型价格表）。
- **xAI** - 使用管理 API 密钥和团队 ID 访问开发者平台（与面向消费者的 Grok 订阅独立）；展示预付余额和 30 天平台支出。
- **OpenAI** - 使用平台 Admin API（`OPENAI_ADMIN_KEY` / 配置）读取组织今日/7 天/30 天支出；支持可选的项目 ID；用户 API 密钥可回退到旧版授信余额接口。不用于 ChatGPT/Codex 订阅（此类订阅请使用 Codex）。
- **Ollama** - 通过 ollama.com Cookie（自动/手动）读取云端会话/每周用量；可选的 `OLLAMA_API_KEY` 用于验证云端 API 访问权限。
- **GitHub Copilot** - 支持 GitHub 设备授权流程或 PAT 回退、企业主机、完整的账号添加/切换/移除管理、Premium 用量、用户名，以及通过网页 Cookie 读取的预算附加数据。
- **Kilo** - 使用 API 令牌或 CLI 会话，支持 Kilo 组织范围、点数和自动充值详情。
- **Kiro** - 基于 CLI 读取用量、点数/超额数据，并提供 9 种菜单栏显示模式。
- **Command Code** - 使用浏览器 Cookie 或手动 Cookie 读取计费点数和套餐目录。
- **Xiaomi MiMo** - 使用浏览器 Cookie 读取余额、Token 套餐详情和用量。
- **Alibaba/Qwen** - 使用浏览器 Cookie 及国际/中国大陆区域设置，读取编程套餐和 Token 套餐的额度周期。
- **Cursor** - 优先读取 Cursor `state.vscdb`，以浏览器 Cookie 为回退，展示用量汇总、身份和请求用量。
- **Gemini** - 从 `~/.gemini/oauth_creds.json` 读取 Gemini CLI OAuth 凭据，获取 Cloud Code Assist 额度档位。
- **OpenCode** - 使用浏览器 Cookie 读取滚动周期/每周用量和订阅续费信息。
- **OpenCode Go** - 使用浏览器 Cookie 和 Go 工作区页面，读取滚动周期/每周/每月用量及 Zen 余额。
- **Antigravity** - 通过本地进程/CLI 探测和 Google OAuth 账号存储，读取分组额度及与账号匹配的数据。
- **AWS Bedrock** - 使用 AWS 访问密钥或命名配置，支持区域、预算字段，以及 CloudWatch/费用用量数据。
- **FreeModel** - 从 `freemodel.dev` 的浏览器会话读取 5 小时和每周美元预算，支持按浏览器切换账号及托管 Cookie。
- **Devin** - 从 `app.devin.ai/api/<org>/billing/quota/usage` 读取每日和每周额度。自动从 Chrome localStorage 导入浏览器会话令牌和组织，也可手动提供 Bearer 令牌及可选的组织信息（slug 或内部 `org-...` ID）。

欢迎接入更多符合现有 `QuotaProvider` 模型的服务商。

## 吉祥物、图标与截图

macOS 菜单栏默认使用 BirdNion 小鸟图标。启用“在菜单栏显示百分比”后，会轮播活跃服务商的额度百分比，并显示各自的标识。Linux 则直接在托盘图标中轮播服务商标识和百分比。

<div align="center">
  <img src="website/assets/birdnion-readme-bird-quota-384.png" width="196" alt="BirdNion mascot holding a blue and yellow quota bar" />
  <br />
  <strong>BirdNion 额度助手</strong>
</div>

<br />

<div align="center">
  <img src="docs/images/logo.png" width="112" alt="BirdNion app icon" />
  <br />
  <strong>BirdNion 应用图标</strong>
</div>

<br />

<div align="center">
  <img src="docs/images/usage-overview.png" width="426" alt="BirdNion usage and cost overview" />
  <br />
  <strong>用量与费用概览</strong>
</div>

<br />

<div align="center">
  <img src="website/assets/control-surface-redraw.jpg" width="776" alt="Illustrated BirdNion Linux control surface based on the current Settings implementation" />
  <br />
  <strong>设置面板 · 根据当前 Linux 设置界面的实现绘制</strong>
</div>

## 功能

- 可选择在 macOS 菜单栏或 Linux 托盘图标中轮播服务商数值，支持服务商开关和适配各平台的排序控件。
- 按服务商展示用量进度和重置倒计时。
- 引导设置会将可修复的服务商错误定位到具体的设置控件，先保存，再执行真实自检；只有自检成功后，才将服务商标为“已连接”。
- 弹出面板顶部的小巧“操作中心”徽标可打开设置，处理当前的配置/连接问题；问题解决后自动消失，不保存问题历史。
- 渐进式刷新：每个服务商的数据获取完成后立即展示。
- 刷新过程中保留上一次已知数据。
- 服务商数据源可选 OAuth、CLI、网页 Cookie、Admin API、本地应用状态和静态密钥。
- 可为每个服务商单独设置刷新间隔和菜单栏可见性。
- 依赖 Cookie 的服务商可选择“自动”“手动”和“关闭”模式。
- 支持 17 种智能体来源的本地费用图表：Claude、Codex、Grok、Kiro、Oh My Pi、Pi、Devin、OpenCode、Gemini CLI、Copilot CLI、Antigravity、Cursor、Amp、Droid、Kimi、Qwen Code 和 Goose，并持久化保存历史最高累计值。界面会立即加载已保存的柱状图，再通过范围更小的实时扫描刷新最近几天的数据。
- “全部”标签页中的简洁“洞察”摘要可打开“设置 -> 洞察”，查看 7 天对比及 7/30/90 天项目排行。Claude、Codex 和 Grok 根据本地会话元数据生成保护隐私的项目标识；只有无法归属的剩余用量会明确标为 `Unknown`。
- 启用后可查看 Claude Admin API 30 天图表和 Codex 网页仪表盘附加数据。
- Kiro 自定义显示值：剩余点数、百分比、已用/总量，以及超额模式。
- 额度和服务商故障通知，支持配置阈值。
- XDG 配置文件采用严格的访问权限。

## 配置与存储

| 数据 | 位置 |
|---|---|
| 服务商列表、启用标记、API 密钥、区域、预算、项目 ID、基础 URL、账号标签 | `~/.config/birdnion/settings.json` |
| 配置覆盖 | `$BIRDNION_CONFIG` |
| XDG 覆盖 | `$XDG_CONFIG_HOME/birdnion/settings.json` |
| 旧版配置 | `~/.birdnion/settings.json` |
| Codex OAuth | `~/.codex/auth.json`，由 Codex CLI 管理 |
| Claude OAuth | macOS Keychain 条目 `Claude Code-credentials`；Linux `~/.claude/.credentials.json`；均由 Claude Code/CLI 管理 |
| Gemini OAuth | `~/.gemini/oauth_creds.json` |
| Cursor 会话 | macOS：`~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`；Linux：`~/.config/Cursor/User/globalStorage/state.vscdb` |
| Antigravity OAuth 账号 | `~/.config/birdnion/antigravity-oauth.json` |
| Copilot OAuth 账号 | `~/.config/birdnion/copilot-accounts.json` |
| FreeModel 托管账号 | macOS：`~/Library/Application Support/BirdNion/freemodel-accounts.json`；Linux：`~/.config/birdnion/freemodel-accounts.json` |
| 每日费用历史（“全部”标签页） | `~/.config/birdnion/cost-history.json`（与设置文件同目录；按历史最高累计值合并，因此删除智能体会话后仍保留过去的柱状图） |
| 项目费用历史（“洞察”） | `~/.config/birdnion/project-cost-history.json`（独立的可选存储；SHA-256 项目键/撤回 ID、安全的末级目录名、受汇总总量约束的历史最高累计值合并、`0600`） |
| macOS 界面偏好设置 | `UserDefaults`（`showPercentInMenuBar`、可见性、刷新、数据源和显示设置） |
| Linux 界面偏好设置 | Tauri WebView `localStorage`；服务商的 Cookie/可见性/刷新字段仍保存在 `settings.json` 中 |

配置路径优先级：

1. `$BIRDNION_CONFIG`
2. `$XDG_CONFIG_HOME/birdnion/settings.json`
3. `~/.config/birdnion/settings.json`
4. `~/.birdnion/settings.json`

配置文件以原子方式写入，权限设为 `0600`。

## 隐私说明

BirdNion 不会无范围限制地遍历文件系统。只有在相关服务商/数据源启用后，才会读取已说明的位置：服务商配置文件、CLI 认证文件、浏览器 Cookie 存储、本地 IDE 数据库和本地智能体会话日志。服务商令牌保存在访问权限受限的 BirdNion 配置文件中。OAuth、Keychain 和 CLI 会话文件仍由原工具管理。

不存储密码。只有用户选择依赖 Cookie 的数据源时，才会复用浏览器 Cookie。“洞察”从不持久化完整项目路径：Claude 对稳定的会话目录令牌做哈希，Codex 对经过验证的绝对路径 `cwd` 做哈希，Grok 对编码后的会话目录令牌做哈希。验证过的路径仅用于优化经过清理的末级目录名称标签；界面和复制摘要只会获得这一安全标签，或明确归入剩余的 `Unknown` 分组。

## 平台说明

### macOS 权限

- **完全磁盘访问权限** - 核心应用不需要此权限。依赖浏览器 Cookie 的服务商可能需要额外的 macOS 访问权限，具体取决于浏览器和 Cookie 存储方式。
- **Keychain 访问权限** - Claude OAuth 可能读取由 Claude Code/CLI 管理的 `Claude Code-credentials` 条目；导入浏览器 Cookie 也可能触发浏览器 Safe Storage 的钥匙串提示。
- **文件与文件夹提示** - 如果底层 CLI/辅助程序访问受保护的位置，本地服务商探测可能触发 macOS 提示。
- **BirdNion 不会在后台请求的权限** - 不请求屏幕录制或辅助功能权限。

### Linux

- 依赖浏览器 Cookie 的服务商需要受支持的 Chrome/Chromium/Brave/Edge/Firefox 用户配置，并可能依赖桌面密钥环。
- 系统托盘直接在图标中轮播服务商标识和百分比，因为 Linux 桌面没有通用的托盘图标旁文本显示机制。
- Linux 不启用全局快捷键，请使用应用窗口和设置控件。

## 文档

- [docs/build.md](docs/build.md) - 构建、签名与故障排查。
- [docs/system-architecture.md](docs/system-architecture.md) - 系统架构与历史决策记录。
- [docs/development-roadmap.md](docs/development-roadmap.md) - 历史路线图。
- [docs/provider-parity/README.md](docs/provider-parity/README.md) - BirdNion 与 CodexBar 的功能对齐审计。
- [docs/linux-parity-matrix.md](docs/linux-parity-matrix.md) - macOS/Linux 功能对齐情况。
- [linux/README.md](linux/README.md) - Linux 开发、打包与平台说明。

## 开发入门

- 克隆仓库。开发 macOS 版时打开 `BirdNion.xcodeproj`，开发 Tauri 版时进入 `linux/`。
- 启动一次，然后在“设置 -> 服务商”中开启或关闭服务商。
- 安装或登录所需的服务商数据源：CLI、浏览器 Cookie、OAuth/设备授权流程、API 密钥、服务商应用或本地配置文件。
- 可选：设置 OpenAI Cookie 以获取 Codex 仪表盘附加数据，并配置 Claude 的 OAuth/Web/CLI/Admin API 数据源路由。

## 从源码构建

### macOS

需要 macOS 14+，以及支持该项目方案中 Swift 代码的 Xcode。

```bash
xcodebuild test -project BirdNion.xcodeproj -scheme BirdNion \
  -configuration Debug -destination 'platform=macOS'

xcodebuild build -project BirdNion.xcodeproj -scheme BirdNion \
  -configuration Release -destination 'platform=macOS'
```

BirdNion 内置了精简版 `CodexBarCore` 包，位于 `Vendor/CodexBar`，无需在外部检出 `~/Desktop/CodexBar`。

### Linux

开发与测试可在 macOS 或 Linux 上从 `linux/` 目录运行。原生 Linux 安装包必须在安装了 WebKitGTK/AppIndicator 依赖的 Linux 上构建。

```bash
cd linux
npm ci
npm test
npm run build
cargo test --manifest-path src-tauri/Cargo.toml

# On Linux: build .deb, .rpm, and AppImage bundles
npm run tauri build
```

## 致谢

灵感来自 [CodexBar](https://github.com/steipete/CodexBar)，尤其是无需打开仪表盘就能掌握所有 AI 编程额度的理念。BirdNion 独立维护自身的跨平台服务商支持、配置和分发体系。

## 许可证

MIT.
