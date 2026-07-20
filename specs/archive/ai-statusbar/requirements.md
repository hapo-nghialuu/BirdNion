# Requirements Document

## Introduction
macOS menu bar app (Swift + SwiftUI, `MenuBarExtra`) running on the user's local machine. Tracks remaining AI quota for two providers (MiniMax Token Plan and Hapo AI Hub), and provides a structured form to read and edit Claude Code configuration files at global (`~/.claude/settings.json`) and per-project (`<project>/.claude/settings.json`) scope. All sensitive material is stored in the macOS Keychain; written settings files are atomic and backed up.

## Requirements

### Requirement 1: Menu bar presence
**Objective:** As a user, I want a discrete icon in the macOS menu bar that opens the app, so that quota and config are one click away without filling the Dock.

#### Acceptance Criteria
- **R1.1** When the user launches the app, the system shall display a single icon in the macOS menu bar (no Dock icon).
- **R1.2** When the user clicks the menu bar icon, the system shall open a popover containing the Quota and Config panels.
- **R1.3** While the app is running, the system shall update the menu bar icon at least once per minute to reflect the lowest remaining quota percentage across providers, or display a warning glyph if any provider reports a status error.
- **R1.4** When the user clicks outside the popover, the system shall close the popover.

### Requirement 2: Quota provider abstraction
**Objective:** As the developer, I want a single protocol for quota providers, so that adding new providers does not change UI or polling code.

#### Acceptance Criteria
- **R2.1** The system shall define a `QuotaProvider` protocol with properties `id`, `displayName`, and an async `fetch() throws -> ProviderStatus`.
- **R2.2** When `QuotaService` is initialized, the system shall instantiate every enabled provider from the persisted provider list.
- **R2.3** When a provider's `fetch()` throws, the system shall record the error on the corresponding `ProviderStatus` and continue running other providers.

### Requirement 3: MiniMax quota adapter
**Objective:** As a user, I want to see remaining MiniMax Token Plan quota (5-hour and weekly windows) in the menu bar, so that I know when to slow or stop usage.

#### Acceptance Criteria
- **R3.1** The system shall call `GET https://api.minimax.io/v1/token_plan/remains` with `Authorization: Bearer <subscriptionKey>`.
- **R3.2** When the response is a 2xx with valid JSON, the system shall produce a `ProviderStatus` containing exactly two `QuotaWindow` items: one labeled "5 giờ" using `model_remains[0].current_interval_remaining_percent`, one labeled "Tuần" using `model_remains[0].current_weekly_remaining_percent`.
- **R3.3** If the response is missing `model_remains` or the first model entry lacks the percent fields, the system shall set `error` on the status and shall not crash.
- **R3.4** If the response is HTTP non-2xx, the system shall record the status code and message text in `error`.
- **R3.5** When no token is stored in Keychain for MiniMax, the system shall report `error: "Chưa cấu hình token"` and shall not make the network call.
- **R3.6** When the MiniMax endpoint returns HTTP 401 or 403, the system shall report `error: "Token bị từ chối — kiểm tra loại key (inference key, không phải Subscription Key)"` so BOSS can distinguish wrong key type from network failure.

### Requirement 4: Hapo Hub quota adapter
**Objective:** As a user, I want quota for the Hapo AI Hub (`<HAPO_HOST>`) shown alongside MiniMax, so that I can track both sources at once.

#### Acceptance Criteria
- **R4.1** The system shall ship a `HapoHubProvider` whose fetch logic is gated by a configuration block (`endpoint`, `authHeaderTemplate`, `jsonPath`).
- **R4.2** If the configuration block is missing, the system shall use a `MockHapoHubProvider` that returns two fixed windows of 80% and 60% so the UI is testable.
- **R4.3** When BOSS supplies the real endpoint + auth + JSON shape, the system shall replace the mock without UI or protocol changes by editing only the provider registry.
- **R4.4** When the real endpoint returns non-2xx, the system shall record status code in `error` like MiniMax.

### Requirement 5: Quota polling and display
**Objective:** As a user, I want the quota panel to refresh automatically and show progress bars per window, so that I can read remaining usage at a glance.

#### Acceptance Criteria
- **R5.1** The system shall call every enabled provider's `fetch()` in parallel every 120 seconds (±10s jitter).
- **R5.2** When `fetch()` returns, the system shall update the in-memory cache and publish a new `[ProviderStatus]` to subscribers within 200ms.
- **R5.3** For each provider row, the system shall display its name, last-updated timestamp (relative: "vừa xong" / "Ns trước"), and one `QuotaBar` per window.
- **R5.4** If a window's `remainingPercent` is below 15, the system shall color its `QuotaBar` red; below 35, amber; otherwise green.
- **R5.5** If a provider's status has a non-nil `error`, the system shall render an inline error message and disable that row's bars.

### Requirement 6: Claude Code global config editing
**Objective:** As a user, I want to edit fields in `~/.claude/settings.json` from the menu bar app, so that I can switch model, base URL, and API key without leaving the menu bar.

#### Acceptance Criteria
- **R6.1** The system shall read `~/.claude/settings.json` on Config panel open and render typed form fields for: `env.ANTHROPIC_MODEL`, `env.ANTHROPIC_BASE_URL`, `env.ANTHROPIC_API_KEY` (rendered via `SecureField`, stored in Keychain — see R11.1), `env.ANTHROPIC_DEFAULT_OPUS_MODEL`, `env.ANTHROPIC_DEFAULT_SONNET_MODEL`, `env.ANTHROPIC_DEFAULT_HAIKU_MODEL`, `permissions.defaultMode`, and the keys of `enabledPlugins` (as toggles).
- **R6.2** When the user changes a field and presses Save, the system shall perform an atomic write to `~/.claude/settings.json` (temp file in same directory + rename), and display a banner: "Đã lưu. Khởi động lại Claude Code để áp dụng." (Saved. Restart Claude Code to apply.)
- **R6.3** Before every atomic write, the system shall rotate the ring of backups: rename `.bak.2` → `.bak.3` (delete oldest), `.bak.1` → `.bak.2`, `.bak` → `.bak.1`, then copy current → `.bak`. The active `.bak` MUST be validated as parseable JSON before the rename proceeds; if not parseable, the rotation is aborted and the user is warned.
- **R6.4** If the atomic write fails, the system shall restore from `.bak` and surface the error to the user.
- **R6.5** The system shall display API key fields in masked form (`fe_oa_••••4a8`) and shall not log or print the raw value.
- **R6.6** When the file does not exist, the system shall create it with a minimal valid JSON skeleton matching the current Claude Code schema.
- **R6.7** When the file is present but contains invalid JSON, the system shall refuse to load, surface the parse error, and offer to open the latest `.bak`.

### Requirement 7: ~~Per-project Claude Code config editing~~ (DEFERRED to v2)
> Decision: removed from v1 scope after Red Team review (Finding F14). Per-project editing requires reverse-engineering the slug→cwd mapping in `~/.claude/projects/`, which Claude Code's runtime does not document. v1 is global-only.

### Requirement 8: Provider configuration persistence
**Objective:** As the developer, I want provider enable/disable + display name + base URL persisted to disk, while tokens live in Keychain, so that no plaintext credential is on disk.

#### Acceptance Criteria
- **R8.1** The system shall persist provider config to `~/Library/Application Support/AIStatusbar/providers.json`.
- **R8.2** The system shall store every provider's token in macOS Keychain under service `AIStatusbar` and account = provider id, using `kSecClassGenericPassword`.
- **R8.3** When the user adds a provider in Settings, the system shall prompt for the token once, write it to Keychain, and store only the reference in `providers.json`.
- **R8.4** The system shall never write a token to `providers.json`, logs, or any file under `~/Library/Application Support/AIStatusbar/`.
- **R8.5** When a Keychain read fails (e.g., keychain locked), the system shall surface the error and offer a retry.

### Requirement 9: Build, run, and reachability
**Objective:** As the user, I want `xcodebuild` to produce a runnable `.app` and want every piece of the app reachable at runtime, so that nothing is dead code.

#### Acceptance Criteria
- **R9.1** The system shall build cleanly via `xcodebuild -scheme AIStatusbar -configuration Debug build` with exit code 0.
- **R9.2** When the built `.app` is launched, the system shall display the menu bar icon within 2 seconds.
- **R9.3** At runtime, every `QuotaProvider` instance shall be invoked at least once per minute (verified by a debug log line in Debug builds).
- **R9.4** At runtime, every Config panel form field shall be wired to a settings.json path (no orphan fields).

## Non-Functional Requirements

### Requirement 10: Performance & resource footprint
**Objective:** As a user, I want the app to be invisible until I click it, so that it does not steal CPU, RAM, or battery.

#### Acceptance Criteria
- **R10.1** While idle (no popover open), the system shall use no more than 50 MB of resident memory.
- **R10.2** The 120-second polling loop shall perform at most 2 HTTP requests per cycle (one per provider).
- **R10.3** The popover shall open within 200ms of clicking the menu bar icon.

### Requirement 11: Security & privacy
**Objective:** As the user, I want credentials and config writes to follow macOS best practice, so that a leak or crash does not expose secrets or break Claude Code.

#### Acceptance Criteria
- **R11.1** The system shall not write any token, API key, or credential to any file outside the macOS Keychain. When the form field `env.ANTHROPIC_API_KEY` is saved, the raw value is written to Keychain under `service=AIStatusbar, account=anthropic`; the JSON file stores the placeholder string `KEYCHAIN_REF:AIStatusbar/anthropic`. Claude Code's shell environment expansion is responsible for resolving the placeholder before launch (out of scope to implement).
- **R11.2** The system shall not log or print any token, API key, or credential, including in debug builds. `URLRequest.description` MUST be overridden to redact the `Authorization` header.
- **R11.3** The system shall not make outbound network calls except to the configured provider endpoint(s). The MiniMax endpoint (`https://api.minimax.io/v1/token_plan/remains`) is a compile-time constant in `MiniMaxProvider`; `providers.json` may override it only for user-added providers.
- **R11.4** The system shall use `URLSession` with default TLS validation; it shall not disable certificate checks. Tests inject a custom `URLSession` via an initializer parameter so `URLProtocol` stubs can intercept.
- **R11.5** When writing to `~/.claude/settings.json`, the system shall preserve all unrelated keys verbatim (semantic equality; key order may differ because `JSONSerialization` does not preserve source order — documented in design.md).

### Requirement 12: Reliability & error handling
**Objective:** As a user, I want network and parse failures to be visible but never crash the app, so that I can keep using the parts that still work.

#### Acceptance Criteria
- **R12.1** If a provider's `fetch()` throws or returns invalid data, the system shall record the error on the status and continue without crashing.
- **R12.2** If a config file cannot be read or written, the system shall surface a non-blocking error banner and keep the app running.
- **R12.3** If `providers.json` is missing or malformed, the system shall start with the default provider list (MiniMax enabled, Hapo in mock mode) and log the parse error in debug builds. `providers.json` writes MUST be atomic (temp file in same directory + rename) to prevent races with external editors or with two app instances.
- **R12.5** Two app instances MUST NOT run concurrently editing `providers.json`. The app SHALL create a lock file at `~/Library/Application Support/AIStatusbar/providers.json.lock` via `flock(2)`; a second instance detects the lock and refuses to start.
- **R12.4** If a Keychain read returns `errSecItemNotFound`, the system shall treat it as "no token configured" and surface the configuration prompt rather than an error.
