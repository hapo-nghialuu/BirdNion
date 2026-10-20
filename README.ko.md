<div align="center">
  <img src="docs/social.png" alt="BirdNion - AI quota companion for macOS and Linux" />
</div>

# BirdNion - AI 에이전트가 예산 안에서 일할 수 있도록.

> 모든 AI 코딩 사용 한도와 에이전트 설정을 macOS 메뉴 막대나 Linux 시스템 트레이에서 확인하세요.

[English](README.md) · [Tiếng Việt](README.vi.md) · [中文](README.zh.md) · [日本語](README.ja.md) · **한국어** · [Español](README.es.md) · [Deutsch](README.de.md) · [Français](README.fr.md)


[![Latest release](https://img.shields.io/github/v/release/hapo-nghialuu/BirdNion?style=flat-square&color=0a0a0c)](https://github.com/hapo-nghialuu/BirdNion/releases/latest)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-0a0a0c?style=flat-square)](https://github.com/hapo-nghialuu/BirdNion/releases/latest)
[![Linux x86_64](https://img.shields.io/badge/Linux-x86__64-fcc624?style=flat-square&logo=linux&logoColor=111)](https://github.com/hapo-nghialuu/BirdNion/releases/latest)
[![Homebrew](https://img.shields.io/badge/brew-hapo--nghialuu%2Ftap%2Fbirdnion-orange?style=flat-square)](https://github.com/hapo-nghialuu/homebrew-tap)
[![License: MIT](https://img.shields.io/badge/license-MIT-6e5aff?style=flat-square)](LICENSE)

38개 제공업체를 지원합니다. BirdNion은 AI 코딩 사용 한도를 한눈에 보여 주고, 각 한도의 초기화 시점과 코딩 에이전트별 데이터 소스 설정을 한곳에서 관리하는 작은 macOS 14+ 메뉴 막대 앱이자 Linux 트레이 앱입니다. Codex, Claude, MiniMax, OpenRouter, DeepSeek, z.ai, ElevenLabs, Deepgram, Groq, Grok, xAI, OpenAI, Ollama, GitHub Copilot, Kilo, Command Code, Xiaomi MiMo, Alibaba/Qwen, Cursor, Gemini, Kiro, OpenCode, OpenCode Go, Antigravity, AWS Bedrock, FreeModel, Devin, Hapo AI Hub와 JavaScript 플러그인 제공업체(Aixy, Atlas Cloud, ClinePass, LiteLLM, Muse Code, Nous Portal, Raycast, Sakana AI, Venice, xKiro)를 지원합니다.

macOS 네이티브 앱은 SwiftUI/AppKit과 필요한 부분만 추려 프로젝트에 포함한 `CodexBarCore`를 사용합니다. Linux 포트는 `linux/`에 있으며, Rust 코어와 바닐라 TypeScript UI를 갖춘 Tauri v2를 사용합니다. 두 플랫폼은 같은 XDG 제공업체 설정 스키마를 공유합니다.

## 왜 필요한가요?

- **초기화 일정에 맞춰 계획하세요.** 제공업체별 5시간·주간·월간 한도, 크레딧, 예산과 초기화까지 남은 시간을 확인할 수 있습니다.
- **지출과 비용을 확인하세요.** Claude 로컬 JSONL 스캔, 주간 사용량 인사이트, 개인정보를 보호하는 프로젝트 순위, Claude Admin API 차트, Codex 크레딧, OpenRouter 잔액, Bedrock 예산과 지원되는 제공업체별 비용·크레딧 요약을 제공합니다.
- **에이전트 소스를 설정하세요.** 설정에서 제공업체별로 OAuth, CLI, 브라우저 쿠키, API 키, AWS 자격 증명, 로컬 앱 파일, 제공업체 앱을 선택하세요.
- **맥락을 유지하며 전환하세요.** macOS와 Linux 모두 사용자 지정 Claude/Codex 프로필 전환, Codex 초기화 크레딧/자동 프라이밍, Codex·Copilot·Antigravity·FreeModel의 다중 계정 기능을 제공합니다.
- **데스크톱을 깔끔하게 유지하세요.** macOS는 메뉴 막대에서 제공업체별 잔여 한도 백분율을 순환 표시할 수 있습니다. Linux는 트레이 아이콘에 제공업체 로고와 백분율을 직접 순환 표시합니다.
- **개인정보 보호가 우선입니다.** BirdNion은 기존 세션과 명시적으로 지정한 설정을 재사용합니다. 비밀번호를 저장하거나 디스크를 무제한으로 스캔하지 않습니다.

## 설치

### 요구 사항

- macOS 14+ (Sonoma)
- 배포되는 `.deb`, `.rpm`, `.AppImage` 번들을 실행할 Linux x86_64

### GitHub 릴리스

[GitHub 릴리스](https://github.com/hapo-nghialuu/BirdNion/releases)에서 미리 빌드된 번들을 다운로드하세요.

- `BirdNion-<version>.zip` - Developer ID로 서명하고 Apple 공증을 받은 macOS 유니버설 앱입니다.
- `BirdNion_<version>_amd64.deb` - Ubuntu/Debian 패키지입니다.
- `BirdNion-<version>-1.x86_64.rpm` - Fedora/RHEL 패키지입니다.
- `BirdNion_<version>_amd64.AppImage` - 휴대용 Linux 번들입니다.
- Homebrew cask는 SHA256을 사용합니다.
- 공증 티켓이 앱에 첨부되어 있으므로, 일반적인 “인터넷에서 다운로드한 앱” 확인 후에는 오프라인에서도 Gatekeeper가 바로 앱을 엽니다.

### Homebrew로 macOS에 설치

권장 설치 명령어:

```bash
brew install --cask hapo-nghialuu/tap/birdnion
```

전체 경로를 지정한 명령어는 `hapo-nghialuu/tap/birdnion`을 명시적으로 선택하므로, 별도의 `brew tap` 단계가 필요 없습니다.

tap을 추가한 뒤 짧은 이름으로 설치하려면:

```bash
brew tap hapo-nghialuu/tap
brew trust --cask hapo-nghialuu/tap/birdnion
brew install --cask birdnion
```

또는 tap 전체를 신뢰할 수 있습니다.

```bash
brew trust hapo-nghialuu/tap
brew install --cask birdnion
```

일반적인 설치 방법으로 `HOMEBREW_NO_REQUIRE_TAP_TRUST=1`을 사용하지 마세요. 이는 사용자 측 환경 변수 재정의이며, Homebrew가 cask를 읽기 전에 신뢰 확인을 우회하도록 `Casks/birdnion.rb` 안에 넣을 수는 없습니다.

### macOS 업데이트

```bash
brew update && brew upgrade --cask birdnion
```

먼저 `brew update`를 실행하고 `&&`로 연결해야 tap에서 최신 cask를 가져옵니다.
`brew upgrade`만 실행하면 타사 tap을 새로 고치지 않아,
오래된 버전을 기준으로 “이미 설치됨”이라고 표시됩니다.

설치된 버전 확인:

```bash
brew list --cask --versions birdnion   # or: brew info --cask birdnion
```

### Linux

[최신 릴리스](https://github.com/hapo-nghialuu/BirdNion/releases/latest)에서 Linux용 파일을 하나 다운로드하세요.

```bash
sudo apt install ./BirdNion_<version>_amd64.deb
# or
sudo dnf install ./BirdNion-<version>-1.x86_64.rpm
# or
chmod +x BirdNion_<version>_amd64.AppImage
./BirdNion_<version>_amd64.AppImage
```

### 첫 실행

- macOS 메뉴 막대나 Linux 시스템 트레이에서 BirdNion을 엽니다.
- 설정 -> 제공업체를 열고 사용하는 제공업체를 활성화하세요.
- 사용하는 제공업체 소스를 설치하거나 로그인하세요. 제공업체에 따라 CLI, 브라우저 세션, OAuth/기기 인증 흐름, API 키, 로컬 앱 파일, 클라우드 자격 증명을 사용할 수 있습니다.
- 선택 사항: 제공업체 계정 이름, 메뉴 막대 표시 여부, 새로 고침 주기, 쿠키 소스, 지역, AWS 인증 모드, Kilo 조직 범위, Copilot 엔터프라이즈 호스트, 제공업체별 메뉴 막대 지표를 설정하세요.

## 에이전트 설정 관리

BirdNion은 단순한 사용 한도 뷰어를 넘어, AI 코딩 에이전트를 위한 가벼운 설정 콘솔을 지향합니다.

현재 제공하는 기능:

- 제공업체 활성화 여부, 순서, 계정 이름, 새로 고침 주기, 메뉴 막대 표시 여부.
- OAuth, CLI, 브라우저 쿠키, Admin API, 로컬 앱 상태를 읽을 수 있는 제공업체의 소스 선택.
- 쿠키 모드, 수동 쿠키 헤더, MiniMax/z.ai/Alibaba 지역, AWS 키/프로필/지역, Deepgram 프로젝트 ID, Kilo 조직 범위, Copilot 엔터프라이즈 호스트, 메뉴 막대 지표 선택 등 제공업체별 설정.
- Claude Code, Codex CLI, Gemini CLI, Kiro, Cursor, Antigravity처럼 인증 상태를 직접 관리하는 에이전트의 로컬 세션 탐색.
- 사전 설정/사용자 지정 백엔드, 모델 등급, 전역 또는 프로젝트 범위, JSON 가져오기, BirdNion이 관리하는 환경 변수 키의 안전한 제거를 지원하는 Claude Code 설정 콘솔.
- 실제 준비 상태·오래된 상태·프록시 상태를 확인하고, 검증에 실패하면 활성화를 차단하는 사용자 지정 Claude Code 및 Codex 프로필 전환.
- 브라우저별 FreeModel 세션을 포함한 Codex, GitHub Copilot, Antigravity, FreeModel의 다중 계정 탐색 및 전환.

앞으로의 방향:

- Claude Code를 넘어 더 많은 코딩 에이전트로 프로필 관리를 확장합니다.
- 각 에이전트의 로그인 및 소스 상태를 더 자세히 보여 줍니다.
- 로컬 설정 경로와 CLI 사용 가능 여부를 검증합니다.
- Claude Code, Codex CLI, Gemini CLI, Kiro와 앞으로 지원할 에이전트의 초기 설정 안내를 제공합니다.
- 에이전트별 자격 증명 저장소는 건드리지 않고, BirdNion 환경설정은 BirdNion 설정 계층에서 관리합니다.

## 제공업체

- **Codex** - `~/.codex/auth.json`의 OAuth API, API 키 대체 경로, 로컬 `codex app-server` 대체 경로, 서비스 상태, 버전, 크레딧, 초기화 크레딧, 선택적 OpenAI 웹 부가 정보, 관리형 계정 전환을 지원합니다.
- **Claude** - OAuth API, 브라우저 쿠키, CLI 또는 Admin API를 사용합니다. 5시간/주간/Opus/Sonnet 한도, 일일 루틴, 로컬 비용 스캔, 웹 부가 정보(추가 사용 지출 및 남은 선불 크레딧), 관리자용 30일 차트를 제공합니다. Max 요금제는 사용량 배수(Max 5x / Max 20x)를 표시합니다.
- **MiniMax** - API 토큰, 환경 변수 토큰 또는 쿠키 대체 경로로 코딩 요금제 사용량, 요금제 이름, 포인트/구독, 글로벌/중국 지역을 지원합니다.
- **OpenRouter** - API 토큰으로 선불 크레딧과 선택적 키별 지출 한도를 확인합니다.
- **DeepSeek** - API 토큰으로 USD/CNY 잔액을 확인하며, 유료/지급 잔액 구분과 잔액 부족 경고를 제공합니다.
- **z.ai** - 글로벌/중국 지역을 지정한 API 토큰으로 사용 한도와 계산된 잔여 백분율을 확인합니다.
- **ElevenLabs** - API 키로 문자 크레딧, 음성 슬롯, 전문 음성, 요금제, 구독 상태를 확인합니다.
- **Deepgram** - API 키와 선택적 프로젝트 ID로 사용량 요약과 전체 프로젝트 합산 모드를 제공합니다.
- **Groq** - API 키로 Prometheus 기반 요청, 토큰, 캐시 적중 지표를 확인합니다.
- **Grok** - `~/.grok/auth.json`(`grok login`)을 통해 별도 설정 없이 연결합니다. 먼저 CLI `x.ai/billing` RPC를 사용하고, 이어서 Chrome 쿠키/인증 Bearer 토큰으로 grok.com 결제 gRPC-web에 접근합니다. SuperGrok 계정 정보와 크레딧 한도를 제공합니다. 전체 탭에서는 `~/.grok/sessions/**/signals.json`을 기반으로 로컬 비용을 표시합니다(총 토큰 수 × 혼합 모델 가격표).
- **xAI** - 개발자 플랫폼용 관리 API 키와 팀 ID를 사용합니다(Grok 소비자용 구독과 별개). 선불 잔액과 30일 플랫폼 지출을 제공합니다.
- **OpenAI** - 플랫폼 Admin API(`OPENAI_ADMIN_KEY` / 설정)로 조직의 오늘/7일/30일 지출을 확인하며, 프로젝트 ID는 선택 사항입니다. 사용자 API 키에는 기존 크레딧 지급 정보 조회를 대체 경로로 사용합니다. ChatGPT/Codex 구독용은 아닙니다(구독은 Codex를 사용하세요).
- **Ollama** - ollama.com 쿠키(자동/수동)로 클라우드 세션/주간 사용량을 확인합니다. 선택적 `OLLAMA_API_KEY`로 클라우드 API 접근을 검증합니다.
- **GitHub Copilot** - GitHub 기기 인증 흐름 또는 PAT 대체 경로, 엔터프라이즈 호스트, 계정 추가/전환/삭제 관리를 지원하며, 웹 쿠키로 프리미엄 사용량, 사용자 이름, 예산 부가 정보를 제공합니다.
- **Kilo** - API 토큰 또는 CLI 세션, Kilo 조직 범위, 크레딧, 자동 충전 세부 정보를 지원합니다.
- **Kiro** - CLI 기반 사용량, 크레딧/초과 사용 데이터, 9가지 메뉴 막대 표시 모드를 제공합니다.
- **Command Code** - 브라우저 쿠키 또는 수동 쿠키로 결제 크레딧과 요금제 목록을 확인합니다.
- **Xiaomi MiMo** - 브라우저 쿠키로 잔액, 토큰 요금제 세부 정보, 사용량을 확인합니다.
- **Alibaba/Qwen** - 브라우저 쿠키와 해외/중국 지역 설정으로 코딩 요금제 및 토큰 요금제의 한도 기간을 확인합니다.
- **Cursor** - Cursor `state.vscdb`를 우선 사용하고 브라우저 쿠키를 대체 경로로 사용합니다. 사용량 요약, 계정 정보, 요청 사용량을 제공합니다.
- **Gemini** - `~/.gemini/oauth_creds.json`의 Gemini CLI OAuth 자격 증명으로 Cloud Code Assist 등급별 사용 한도를 확인합니다.
- **OpenCode** - 브라우저 쿠키로 최근 일정 기간/주간 사용량과 구독 갱신을 확인합니다.
- **OpenCode Go** - 브라우저 쿠키와 Go 워크스페이스 페이지로 최근 일정 기간/주간/월간 사용량과 Zen 잔액을 확인합니다.
- **Antigravity** - 로컬 프로세스/CLI 탐색과 Google OAuth 계정 저장소를 사용해 한도 구간과 계정에 맞는 데이터를 제공합니다.
- **AWS Bedrock** - AWS 액세스 키 또는 이름이 지정된 프로필, 지역, 예산 필드, CloudWatch/Cost 사용량을 지원합니다.
- **FreeModel** - `freemodel.dev`의 브라우저 세션으로 5시간 및 주간 달러 예산을 확인하며, 브라우저별 계정 전환과 관리형 쿠키를 지원합니다.
- **Devin** - `app.devin.ai/api/<org>/billing/quota/usage`에서 일일 및 주간 한도를 확인합니다. Chrome localStorage에서 브라우저 세션 토큰과 조직을 자동으로 가져오거나, 수동 Bearer 토큰과 선택적 조직 정보(slug 또는 내부 `org-...` ID)를 입력할 수 있습니다.

기존 `QuotaProvider` 모델에 맞는 제공업체라면 추가 지원도 환영합니다.

## 마스코트, 아이콘 및 스크린샷

macOS 메뉴 막대의 기본 아이콘은 BirdNion 새입니다. “메뉴 막대에 백분율 표시”를 켜면 활성 제공업체의 로고와 잔여 한도 백분율이 순환 표시됩니다. Linux는 트레이 아이콘 자체에 제공업체 로고와 백분율을 직접 순환 표시합니다.

<div align="center">
  <img src="website/assets/birdnion-readme-bird-quota-384.png" width="196" alt="BirdNion mascot holding a blue and yellow quota bar" />
  <br />
  <strong>BirdNion 사용 한도 도우미</strong>
</div>

<br />

<div align="center">
  <img src="docs/images/logo.png" width="112" alt="BirdNion app icon" />
  <br />
  <strong>BirdNion 앱 아이콘</strong>
</div>

<br />

<div align="center">
  <img src="docs/images/usage-overview.png" width="426" alt="BirdNion usage and cost overview" />
  <br />
  <strong>사용량 및 비용 개요</strong>
</div>

<br />

<div align="center">
  <img src="website/assets/control-surface-redraw.jpg" width="776" alt="Illustrated BirdNion Linux control surface based on the current Settings implementation" />
  <br />
  <strong>제어 화면 · 현재 Linux 설정 구현을 바탕으로 한 일러스트</strong>
</div>

## 기능

- macOS 메뉴 막대 또는 Linux 트레이 아이콘에서 제공업체별 값을 선택적으로 순환 표시하며, 제공업체 표시 토글과 플랫폼에 맞는 순서 변경 기능을 제공합니다.
- 제공업체별 사용량 미터와 초기화까지 남은 시간을 표시합니다.
- 설정 안내는 해결 가능한 제공업체 오류를 정확한 설정 항목으로 연결합니다. 먼저 저장한 뒤 실제 자체 테스트에 성공한 경우에만 제공업체를 연결됨으로 표시합니다.
- 팝오버 헤더의 작은 알림 센터 배지는 현재 설정/연결 문제를 해결할 수 있는 설정 화면을 엽니다. 해결된 항목은 자동으로 사라지며, 문제 이력은 별도로 저장하지 않습니다.
- 점진적 새로 고침: 각 제공업체의 조회가 끝나는 즉시 결과를 표시합니다.
- 새로 고침 중에도 마지막으로 확인한 데이터를 계속 보여 줍니다.
- OAuth, CLI, 웹 쿠키, Admin API, 로컬 앱 상태, 고정 키를 제공업체 소스로 선택할 수 있습니다.
- 제공업체별 새로 고침 주기와 메뉴 막대 표시 여부를 설정할 수 있습니다.
- 쿠키를 사용하는 제공업체에는 자동, 수동, 끄기 모드를 갖춘 쿠키 소스 선택 기능을 제공합니다.
- Claude, Codex, Grok, Kiro, Oh My Pi, Pi, Devin, OpenCode, Gemini CLI, Copilot CLI, Antigravity, Cursor, Amp, Droid, Kimi, Qwen Code, Goose 등 17개 에이전트 소스의 로컬 비용 차트와 최대 누적값 유지 이력을 제공합니다. 저장된 막대 데이터를 즉시 UI에 표시하고, 더 좁은 범위의 실시간 스캔으로 최근 며칠을 갱신합니다.
- 전체 탭의 작은 인사이트 요약에서 설정 -> 인사이트를 열어 7일 비교와 7/30/90일 프로젝트 순위를 확인할 수 있습니다. Claude, Codex, Grok은 로컬 세션 메타데이터에서 개인정보를 보호하는 프로젝트 식별자를 만들며, 프로젝트에 귀속할 수 없는 잔여 사용량만 명시적으로 `Unknown`으로 남깁니다.
- 활성화된 경우 Claude Admin API 30일 차트와 Codex 웹 대시보드 부가 정보를 제공합니다.
- Kiro 사용자 지정 표시 값: 남은 크레딧, 백분율, 사용량/전체 한도, 초과 사용 모드.
- 임계값을 설정할 수 있는 사용 한도 및 제공업체 연결 실패 알림을 제공합니다.
- 접근 권한이 제한된 XDG 설정 파일을 사용합니다.

## 설정 및 저장 위치

| 데이터 | 위치 |
|---|---|
| 제공업체 목록, 활성화 여부, API 키, 지역, 예산, 프로젝트 ID, 기본 URL, 계정 이름 | `~/.config/birdnion/settings.json` |
| 설정 경로 재정의 | `$BIRDNION_CONFIG` |
| XDG 경로 재정의 | `$XDG_CONFIG_HOME/birdnion/settings.json` |
| 기존 설정 | `~/.birdnion/settings.json` |
| Codex OAuth | `~/.codex/auth.json`, Codex CLI가 관리 |
| Claude OAuth | macOS Keychain 항목 `Claude Code-credentials`; Linux `~/.claude/.credentials.json`; 둘 다 Claude Code/CLI가 관리 |
| Gemini OAuth | `~/.gemini/oauth_creds.json` |
| Cursor 세션 | macOS: `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`; Linux: `~/.config/Cursor/User/globalStorage/state.vscdb` |
| Antigravity OAuth 계정 | `~/.config/birdnion/antigravity-oauth.json` |
| Copilot OAuth 계정 | `~/.config/birdnion/copilot-accounts.json` |
| FreeModel 관리형 계정 | macOS: `~/Library/Application Support/BirdNion/freemodel-accounts.json`; Linux: `~/.config/birdnion/freemodel-accounts.json` |
| 일별 비용 이력(전체 탭) | `~/.config/birdnion/cost-history.json` (설정 파일과 같은 디렉터리; 최대 누적값 유지 병합으로 에이전트 세션이 삭제되어도 과거 막대 데이터를 보존) |
| 프로젝트 비용 이력(인사이트) | `~/.config/birdnion/project-cost-history.json` (별도의 선택적 저장소; SHA-256 프로젝트 키/철회 ID, 안전한 기본 이름, 합계 상한 내 최대 누적값 유지 병합, `0600`) |
| macOS UI 환경설정 | `UserDefaults` (`showPercentInMenuBar`, 표시 여부, 새로 고침, 소스, 표시 설정) |
| Linux UI 환경설정 | Tauri WebView `localStorage`; 제공업체의 쿠키/표시 여부/새로 고침 필드는 `settings.json`에 유지 |

설정 경로 우선순위:

1. `$BIRDNION_CONFIG`
2. `$XDG_CONFIG_HOME/birdnion/settings.json`
3. `~/.config/birdnion/settings.json`
4. `~/.birdnion/settings.json`

설정 파일은 원자적으로 기록되며 권한은 `0600`으로 설정됩니다.

## 개인정보 보호 안내

BirdNion은 파일 시스템을 무제한으로 탐색하지 않습니다. 관련 제공업체/소스가 활성화된 경우에만 문서에 명시된 위치를 읽습니다. 대상은 제공업체 설정 파일, CLI 인증 파일, 브라우저 쿠키 저장소, 로컬 IDE 데이터베이스, 로컬 에이전트 세션 로그입니다. 제공업체 토큰은 접근 권한이 제한된 BirdNion 설정 파일에 저장됩니다. OAuth, Keychain, CLI 세션 파일은 원래 도구가 계속 관리합니다.

비밀번호는 저장하지 않습니다. 브라우저 쿠키는 사용자가 쿠키 기반 소스를 선택한 경우에만 재사용합니다. 인사이트는 프로젝트 전체 경로를 영구 저장하지 않습니다. Claude는 안정적인 세션 디렉터리 토큰을, Codex는 검증된 절대 경로 `cwd`를, Grok은 인코딩된 세션 디렉터리 토큰을 해시 처리합니다. 검증된 경로는 안전하게 정제된 기본 이름 레이블을 개선하는 데만 사용할 수 있습니다. UI와 복사 요약에는 이 안전한 레이블 또는 명시적인 잔여 `Unknown` 항목만 전달됩니다.

## 플랫폼별 안내

### macOS 권한

- **전체 디스크 접근 권한** - 앱의 핵심 기능에는 필요하지 않습니다. 브라우저 쿠키를 사용하는 제공업체는 브라우저와 쿠키 저장소에 따라 추가 macOS 접근 권한이 필요할 수 있습니다.
- **Keychain 접근** - Claude OAuth는 Claude Code/CLI가 관리하는 `Claude Code-credentials` 항목을 읽을 수 있습니다. 브라우저 쿠키를 가져올 때 브라우저 Safe Storage Keychain 접근 요청이 나타날 수도 있습니다.
- **파일 및 폴더 권한 요청** - 로컬 제공업체를 탐색할 때 내부 CLI/도우미가 보호된 위치에 접근하면 macOS 권한 요청이 나타날 수 있습니다.
- **BirdNion이 백그라운드에서 요청하지 않는 권한** - 화면 기록이나 손쉬운 사용 권한은 요청하지 않습니다.

### Linux

- 브라우저 쿠키를 사용하는 제공업체에는 지원되는 Chrome/Chromium/Brave/Edge/Firefox 프로필이 필요하며, 데스크톱 키링에 의존할 수 있습니다.
- Linux 데스크톱에는 트레이 아이콘 옆 텍스트를 공통으로 표시할 방법이 없으므로, 시스템 트레이는 아이콘 자체에 제공업체 로고와 백분율을 순환 표시합니다.
- Linux에서는 전역 단축키가 활성화되어 있지 않습니다. 앱 창과 설정 컨트롤을 사용하세요.

## 문서

- [docs/build.md](docs/build.md) - 빌드, 서명, 문제 해결.
- [docs/system-architecture.md](docs/system-architecture.md) - 시스템 아키텍처 및 과거 의사결정 기록.
- [docs/development-roadmap.md](docs/development-roadmap.md) - 과거 로드맵.
- [docs/provider-parity/README.md](docs/provider-parity/README.md) - BirdNion과 CodexBar의 기능 동등성 점검.
- [docs/linux-parity-matrix.md](docs/linux-parity-matrix.md) - macOS/Linux 기능 동등성.
- [linux/README.md](linux/README.md) - Linux 개발, 패키징, 플랫폼별 안내.

## 시작하기(개발)

- 저장소를 복제하세요. macOS에서는 `BirdNion.xcodeproj`를 열고, Tauri 개발은 `linux/`에서 진행하세요.
- 한 번 실행한 뒤 설정 -> 제공업체에서 필요한 제공업체를 켜세요.
- 사용하는 제공업체 소스를 설치하거나 로그인하세요. CLI, 브라우저 쿠키, OAuth/기기 인증 흐름, API 키, 제공업체 앱, 로컬 설정 파일을 사용할 수 있습니다.
- 선택 사항: Codex 대시보드 부가 정보를 위한 OpenAI 쿠키와 Claude의 OAuth/Web/CLI/Admin API 소스 라우팅을 설정하세요.

## 소스에서 빌드

### macOS

macOS 14+와 프로젝트 스킴에 필요한 Swift 지원을 갖춘 Xcode가 필요합니다.

```bash
xcodebuild test -project BirdNion.xcodeproj -scheme BirdNion \
  -configuration Debug -destination 'platform=macOS'

xcodebuild build -project BirdNion.xcodeproj -scheme BirdNion \
  -configuration Release -destination 'platform=macOS'
```

BirdNion은 필요한 부분만 추린 `CodexBarCore` 패키지를 `Vendor/CodexBar`에 포함합니다. 별도의 `~/Desktop/CodexBar` 저장소 복제본은 필요하지 않습니다.

### Linux

macOS 또는 Linux의 `linux/`에서 개발과 테스트를 실행할 수 있습니다. Linux 네이티브 번들은 WebKitGTK/AppIndicator 의존성이 설치된 Linux에서 빌드해야 합니다.

```bash
cd linux
npm ci
npm test
npm run build
cargo test --manifest-path src-tauri/Cargo.toml

# On Linux: build .deb, .rpm, and AppImage bundles
npm run tauri build
```

## 감사의 말

[CodexBar](https://github.com/steipete/CodexBar), 특히 대시보드를 열지 않고도 모든 AI 코딩 사용 한도를 볼 수 있다는 아이디어에서 영감을 받았습니다. BirdNion은 크로스 플랫폼 제공업체 지원, 설정, 배포 체계를 독자적으로 유지합니다.

## 라이선스

MIT.
