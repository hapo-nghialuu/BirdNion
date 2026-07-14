# Batch C — HARD providers

Gemini · Kiro · Antigravity · Bedrock
Kết: **1 full / 1 partial / 2 diverge.**

Chung (cosmetics): cả 4 thiếu **brand tint color** (CodexBar có ProviderColor riêng) + thiếu **dashboard/status link** (`dashboardLinks` default→[]).

---

## Gemini 🟡 PARTIAL
- **Auth**: OAuth `~/.gemini/oauth_creds.json` + refresh (oauth2.googleapis.com/token), cùng clientID/secret công khai — MATCH. Cả 2 từ chối API-key/Vertex.
- **Endpoints/flow**: loadCodeAssist (project+tier) → CRM fallback → `retrieveUserQuota` — giống CodexBar. THIẾU **curl-fallback khi URLSession timeout** (CodexBar `GeminiStatusProbe+DataLoader.swift` dùng `/usr/bin/curl`).
- **Parsing/data**: 🔴 grouping DIVERGE — BirdNion group **theo modelId** (N window tên model thô, sort A→Z, `GeminiProvider.swift:321-336`); CodexBar group cố định **3 tier**: Pro=primary, Flash=secondary, Flash-Lite=tertiary, mỗi tier `min(percentLeft)` (`GeminiStatusProbe.swift:43-72`).
- **Plan**: BirdNion map tier→Paid/Free/Legacy (`:231-236`). CodexBar thêm **"Workspace"** khi free-tier + hostedDomain (`hd` claim, `:312-323`). BirdNion THIẾU nhánh Workspace.
- **UI fields**: windows[modelId thô], accountLabel=email (JWT id_token), planName. THIẾU: nhãn chuẩn Pro/Flash/Flash-Lite, plan Workspace.
- **Cosmetics**: displayName "Gemini" ✓, logo ✓ (tint trắng). brand tint CodexBar RGB(171,135,234) — BirdNion không có. dashboard link THIẾU (`gemini.google.com` + Google status).
- **Gaps**: (1) đổi grouping sang 3-tier label cố định (`:321-336`); (2) thêm plan "Workspace" đọc `hd` (`:231-236`); (3) curl fallback timeout; (4) dashboard link.

## Kiro 🟢 FULL (2026-07-14)
- **Auth**: subprocess `kiro`/`kiro-cli whoami` (song song với usage, parse email + **authMethod** "Logged in with …" → `sourceLabel`) + `chat --no-interactive /usage` + `chat --no-interactive /context`, strip ANSI — MATCH.
- **Transport**: pipe-first với **idle cutoff** (4s im lặng sau khi có output) + **PTY fallback** giới hạn deadline (spawn khi pipe im lặng >5s hoặc output không parse được) — port đầy đủ cơ chế race của `KiroStatusProbe` (`KiroProvider.swift runCommand`). Linux: pipe + idle cutoff (PTY fallback không port — cần pty crate, chỉ phục vụ CLI đời rất cũ trước bản Linux).
- **Parsing/data**: credits `█+ X%`, `(X.XX of Y covered)`, bonus, reset, managed-plan (giữ bonus/overage thay vì drop), plan name (displayPlanName title-case), overagesStatus/overageCreditsUsed/estimatedOverageCostUSD/manageURL, **contextUsage** (`/context` breakdown), **version detector** (`kiro-cli --version`).
- **UI fields**: windows[Credits, Bonus Credits, Vượt hạn mức], creditsRemaining ✓, planName ✓, accountLabel=email, version ✓, sourceLabel=authMethod ✓, context % trong info grid (macOS `provider.kiroContext` + Linux `kiroContextPercent`). Menu-bar display mode picker 9 options ✓.
- **Cosmetics**: displayName "Kiro" ✓, logo ✓, brand tint #FF9900 ✓ (`VocabbyTheme.kiro`), dashboard link ✓ (`app.kiro.dev/account/usage` + AWS health).

## Antigravity 🔴 DIVERGE/MISSING
- **Auth/flow**: BirdNion = **CHỈ local probe** (`ps -ax` tìm language_server/agy → `--csrf_token`+port → `lsof` → POST Connect/JSON, `AntigravityProvider.swift:94-198`). CodexBar có **3 source mode** (descriptor `:42-63`): `app/ide local` + **`agy` CLI warm-session** (spawn process, poll port, auth-prompt detect) + **`oauth` remote** (multi-account Google login, AntigravityRemoteUsageFetcher). → BirdNion thiếu ~2/3 chiến lược.
- **Endpoints**: `RetrieveUserQuotaSummary` → fallback `GetUserStatus` — khớp cơ bản (`forceRefresh:true`).
- **Parsing/data**: parse `clientModelConfigs.quotaInfo.remainingFraction` + quota-summary buckets, filter image/lite/autocomplete, sort Claude>GPT>Gemini (`:332-368`). CodexBar có parser riêng + **account-match guard** (chỉ chấp nhận snapshot đúng email đã chọn, `:383-410`); BirdNion KHÔNG (lấy bất kỳ account local).
- **UI fields**: windows[model humanized], accountLabel (config→email→"Antigravity"), planName (userTier.name). THIẾU: multi-account selector, source label, account guard.
- **Cosmetics**: displayName ✓, logo ✓. brand tint CodexBar RGB(96,186,126) — BirdNion không. CodexBar nhóm 2 cụm "Gemini Models"/"Claude and GPT"; BirdNion per-model. toggleTitle CodexBar ghi "(experimental)".
- **Gaps**: (1) thêm agy CLI warm-session + Google OAuth remote + multi-account; (2) source-mode picker (Auto/OAuth/CLI); (3) account-match guard.

## Bedrock 🔴 DIVERGE/MISSING
- **Auth**: BirdNion = env → `~/.aws/credentials [profile]` → `~/.aws/config` INI tự parse, region env>config>us-east-1 (`BedrockProvider.swift:241-286`). CodexBar = 2 mode `keys`/`profile` qua **`aws configure export-credentials`** (SSO/assume-role/credential_process, `BedrockProfileCredentialProvider.swift:28-53`). → DIVERGE: BirdNion KHÔNG shell ra AWS CLI ⇒ không hỗ trợ SSO/assume-role/session refresh; thiếu auth-mode picker.
- **Endpoints/flow**: 🔴 lệch lớn. BirdNion = **chỉ CloudWatch GetMetricData** (InputTokenCount/OutputTokenCount/Invocations, filter `claude`, 14 ngày, `:385-425`). CodexBar = **Cost Explorer `ce.us-east-1` GetCostAndUsage** (monthly $ UnblendedCost, group SERVICE) làm **nguồn chính** + CloudWatch chỉ bổ sung token (`BedrockUsageStats.swift:120-291`). → BirdNion thiếu toàn bộ chi phí thực + budget %.
- **Parsing/data**: BirdNion chỉ tokens 14d + request count (không $). CodexBar: monthlySpend $, monthlyBudget, budgetUsedPercent → primary window "Monthly budget" + `ProviderCostSnapshot` USD, reset cuối tháng (`:44-89`).
- **UI fields**: BirdNion windows[1: "14 ngày (region)" tokens/req] usedPct=0. THIẾU: `cost` ($ spend/budget), budget %, monthly window. CodexBar `supportsTokenCost=true` render cost card; BirdNion cost=nil.
- **Cosmetics**: displayName "AWS Bedrock" ✓, logo ✓. brand tint CodexBar RGB(255,153,0). **Region UI THIẾU** — CodexBar Settings có auth-mode picker + profile/access-key/secret/**region field** (`BedrockProviderImplementation.swift:29-97`); BirdNion region picker chỉ có cho minimax/zai. Lưu ý `BirdNionConfigStore.Provider.region` đã tồn tại (`:61`) nhưng Bedrock không đọc. dashboard link `console.aws.amazon.com/bedrock` THIẾU.
- **Gaps**: (1) thêm Cost Explorer ($ spend, group SERVICE, phân trang); (2) budget + budgetUsedPercent + `ProviderCostSnapshot` → populate `cost`; (3) auth-mode picker + `aws configure export-credentials` cho SSO; (4) Settings UI profile/keys/region (`Provider.region` đã có); (5) dashboard link.
