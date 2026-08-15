import SwiftUI

// MARK: - Instrument redesign — local helpers (this file only)
//
// `SettingsCard` (SettingsSceneRoot.swift) renders the pre-redesign look: a
// filled, rounded, shadowed box. The Instrument redesign replaces that with
// a plain hairline-top divider + mono eyebrow header (mirrors `.card` /
// `.pp-*` in `linux/src/styles.css`). `SettingsCard` itself is shared UI
// infrastructure outside this file's scope, so `InstrumentSection` is a
// local, call-site-only substitute used only by ProviderDetail's own
// sections — same header/content API, no other view files are touched.
private struct InstrumentSection<Content: View>: View {
    var header: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let header {
                // Mirrors the mockup: the eyebrow label itself carries no
                // rule — only the row content below it does (matching
                // `.pp-field-row { border-top: ... }` on every row, first
                // one included), so the divider sits between header and
                // content rather than above the header.
                Text(header)
                    .plexEyebrow()
                    .padding(.horizontal, 4)
                    .padding(.top, 18)
                    .padding(.bottom, 4)
            }
            VStack(spacing: 0) { content() }
                .hairlineTop()
        }
    }
}

private extension View {
    /// Square, hairline-bordered field — replaces `.textFieldStyle(.roundedBorder)`'s
    /// native rounded chrome with the Instrument look (flat background, square
    /// corners, `VocabbyTheme.border` outline). Visual only — bindings/validation
    /// on the wrapped `TextField`/`SecureField` are untouched.
    func instrumentFieldStyle() -> some View {
        self
            .textFieldStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(VocabbyTheme.background)
            .overlay(
                RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous)
                    .stroke(VocabbyTheme.border, lineWidth: 1)
            )
    }
}

// MARK: - Provider detail shell (P4 module split)

extension ProvidersPane {
    func onboardingDetection(for id: String) -> OnboardingDetection {
        let env = ProcessInfo.processInfo.environment
        let fm = FileManager.default
        switch id {
        case "claude":
            let home = env["HOME"] ?? NSHomeDirectory()
            let file = URL(fileURLWithPath: home)
                .appendingPathComponent(ClaudeOAuthStore.credentialsRelativePath)
            let hasFile = fm.fileExists(atPath: file.path)
            let hasCLI = ClaudeCLIResolver.isAvailable(environment: env)
            return Self.onboardingDetection(
                hasPrimary: hasFile, primaryLabel: "Claude Code",
                hasSecondary: hasCLI, secondaryLabel: "Claude CLI",
                fallbackLabel: "Claude Code / CLI")
        case "codex":
            let hasFile = fm.fileExists(atPath: CodexAuthStore.authFileURL(env: env).path)
            let hasCLI = CodexAccountStore.codexBinary() != nil
            return Self.onboardingDetection(
                hasPrimary: hasFile, primaryLabel: "Codex login",
                hasSecondary: hasCLI, secondaryLabel: "Codex CLI",
                fallbackLabel: "Codex login / CLI")
        case "grok":
            let configuredHome = env["GROK_HOME"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let root = if let configuredHome, !configuredHome.isEmpty {
                URL(fileURLWithPath: configuredHome, isDirectory: true)
            } else {
                fm.homeDirectoryForCurrentUser.appendingPathComponent(".grok", isDirectory: true)
            }
            let authURL = root.appendingPathComponent("auth.json")
            let sessionsURL = root.appendingPathComponent("sessions", isDirectory: true)
            let hasAuth = fm.fileExists(atPath: authURL.path)
            let hasSessions = fm.fileExists(atPath: sessionsURL.path)
            return Self.onboardingDetection(
                hasPrimary: hasAuth, primaryLabel: "Grok login",
                hasSecondary: hasSessions, secondaryLabel: "Grok sessions",
                fallbackLabel: "Grok login / sessions")
        default:
            return OnboardingDetection(isReady: false, source: "")
        }
    }

    func onboardingPhase(for row: BirdNionConfigStore.Provider) -> OnboardingPhase {
        let current = status(for: row.id)
        return Self.onboardingPhase(
            testState: selfTestState[row.id] ?? .idle,
            statusHasError: current?.error != nil,
            statusHasQuota: !(current?.windows.isEmpty ?? true),
            detectionReady: onboardingDetection(for: row.id).isReady)
    }

    func connectAndTest(_ idx: Int) {
        let id = rows[idx].id
        if rows[idx].enabled != true {
            rows[idx].enabled = true
            saveAll()
            // NotificationCenter delivers this synchronously; AppDelegate
            // rebuilds QuotaService before runSelfTest resolves the provider.
            NotificationCenter.default.post(
                name: .birdnionProvidersChanged,
                object: "onboardingSelfTest")
        }
        runSelfTest(id: id)
    }

    private func onboardingCopy(_ vi: String, _ en: String) -> String {
        L10n.languageCode(language) == "vi" ? vi : en
    }

    @ViewBuilder
    func onboardingSection(_ idx: Int) -> some View {
        let row = rows[idx]
        if Self.onboardingProviderIDs.contains(row.id) {
            let detection = onboardingDetection(for: row.id)
            let phase = onboardingPhase(for: row)
            InstrumentSection(header: onboardingCopy("KẾT NỐI PROVIDER", "CONNECT PROVIDER")) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(phase == .live ? SettingsTheme.success : phase == .failed ? SettingsTheme.critical : SettingsTheme.warning)
                            .frame(width: 8, height: 8)
                        Text({
                            switch phase {
                            case .needsSource: onboardingCopy("Chưa phát hiện nguồn đăng nhập", "No sign-in source detected")
                            case .readyToTest: onboardingCopy("Đã phát hiện \(detection.source)", "Detected \(detection.source)")
                            case .testing: onboardingCopy("Đang kiểm tra kết nối thật…", "Testing the real connection…")
                            case .live: onboardingCopy("Quota đang live", "Quota is live")
                            case .failed: onboardingCopy("Kết nối cần được sửa", "Connection needs attention")
                            }
                        }())
                        .font(.plexSans(12, weight: .semibold))
                        Spacer()
                    }

                    Text(onboardingCopy(
                        "BirdNion chỉ đánh dấu Live sau khi provider trả quota thật. Không sao chép hoặc hiển thị token.",
                        "BirdNion marks Live only after the provider returns real quota. Tokens are never copied or displayed."))
                        .font(.plexSans(11))
                        .foregroundStyle(SettingsTheme.secondary)

                    HStack(spacing: 8) {
                        Button(phase == .failed ? onboardingCopy("Thử lại", "Retry") : onboardingCopy("Kết nối & kiểm tra", "Connect & test")) {
                            connectAndTest(idx)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(phase == .testing)

                        if phase == .needsSource || phase == .failed {
                            Button(onboardingCopy("Sửa thiết lập", "Fix setup")) {
                                selectedID = row.id
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                .padding(12)
            }
        }
    }

    /// One fetch through the provider's real path (R2.5) — never
    /// QuotaService.refresh(). A disabled provider has no live instance in
    /// `quota.providers`; fail fast instead of entering `.running` (R2.9).
    func runSelfTest(id: String) {
        guard let provider = quota.providers.first(where: { $0.id == id }) else {
            selfTestState[id] = .fail(kind: .unknown, raw: L10n.t("provider.selfTest.disabled", language))
            return
        }
        guard selfTestState[id] != .running else { return }
        selfTestState[id] = .running
        Task {
            do {
                let status = try await provider.fetch()
                quota.applySelfTestStatus(status)
                if let err = status.error, !err.isEmpty {
                    selfTestState[id] = .fail(kind: classify(rawError: err) ?? .unknown, raw: err)
                } else if status.windows.isEmpty {
                    let raw = onboardingCopy(
                        "Provider không trả dữ liệu quota.",
                        "Provider returned no quota data.")
                    selfTestState[id] = .fail(kind: .unknown, raw: raw)
                } else {
                    selfTestState[id] = .pass
                }
            } catch {
                let raw = "\(error)"
                selfTestState[id] = .fail(kind: classify(rawError: raw) ?? .unknown, raw: raw)
            }
        }
    }

    /// Inline label next to the self-test button; nothing when idle.
    @ViewBuilder
    func selfTestResult(for id: String) -> some View {
        switch selfTestState[id] ?? .idle {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text(L10n.t("provider.selfTest.running", language))
                    .font(.plexSans(10))
                    .foregroundStyle(SettingsTheme.secondary)
            }
        case .pass:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(SettingsTheme.success)
                Text(L10n.t("provider.selfTest.pass", language))
                    .font(.plexSans(10))
                    .foregroundStyle(SettingsTheme.success)
            }
        case .fail(let kind, let raw):
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(SettingsTheme.critical)
                Text("\(L10n.t("provider.selfTest.fail", language)) — \(L10n.t(kind.hintKey, language))")
                    .font(.plexSans(10))
                    .foregroundStyle(SettingsTheme.critical)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .help(raw)
        }
    }

    // makeProvider was moved to `ServicesContainer.makeProviders(keychain:)`
// so the same factory powers init() and the live rebuild path triggered
// by .birdnionProvidersChanged.

    @ViewBuilder
    func statusDot(for row: BirdNionConfigStore.Provider) -> some View {
        let color: Color = {
            if row.enabled != true { return SettingsTheme.disabled.opacity(0.55) }
            guard let s = status(for: row.id) else { return SettingsTheme.disabled.opacity(0.55) }
            return s.error == nil ? SettingsTheme.success : SettingsTheme.warningFill
        }()
        Circle().fill(color).frame(width: 7, height: 7)
    }

    // MARK: - Detail

    @ViewBuilder
    var detail: some View {
        if let id = selectedID, let idx = rows.firstIndex(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    detailHeader(idx)
                    onboardingSection(idx)
                    detailInfoGrid(rows[idx])
                    usageSection(rows[idx])
                    if rows[idx].id == "xai" {
                        xaiCostSection(status(for: rows[idx].id))
                    }
                    settingsSection(idx)
                    menuBarDisplaySection(for: rows[idx].id)
                    if rows[idx].id == "codex" {
                        CodexAccountsCard()
                        CodexAutoPrimeCard()
                    }
                    if rows[idx].id == "elevenlabs" {
                        ElevenLabsKeysCard()
                    }
                    if rows[idx].id == "hiyo" {
                        HiyoKeysCard()
                    }
                    if rows[idx].id == "antigravity" {
                        antigravityOAuthAccountsSection()
                    }
                    if rows[idx].id == "copilot" {
                        copilotOAuthAccountsSection(idx: idx)
                    }
                    QuotaWarningCard(providerID: rows[idx].id)
                        .id(rows[idx].id)
                    linksSection(rows[idx])
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            // Fill the window height so the ScrollView scrolls tall provider
            // details (e.g. Codex) instead of overflowing past the bottom edge.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            InstrumentSection {
                Text(L10n.t("provider.choose", language))
                    .font(.plexSans(13))
                    .foregroundStyle(SettingsTheme.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
                    .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    func detailHeader(_ idx: Int) -> some View {
        let row = rows[idx]
        return VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 12) {
                ProviderLogoView(id: row.id, tint: row.enabled == true ? SettingsTheme.accent : SettingsTheme.disabled)
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName(for: row))
                        .font(.plexSans(16, weight: .semibold))
                        .foregroundStyle(SettingsTheme.primary)
                    Text(headerSubtitle(for: row))
                        .font(.plexSans(11))
                        .foregroundStyle(SettingsTheme.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                // One-shot probe through the provider's real fetch path;
                // result renders inline below the header row.
                Button(L10n.t("provider.selfTest", language)) {
                    runSelfTest(id: row.id)
                }
                .controlSize(.small)
                .disabled(selfTestState[row.id] == .running)
                .pointingHandCursor(enabled: selfTestState[row.id] != .running)
                Button {
                    // Manual reload: re-read `settings.json` to pick up any
                    // changes another pane (or external editor) made, then
                    // rebuild the provider list and trigger a refresh.
                    // Previously this only called `quota.refresh()` which
                    // didn't re-read the file — so saving a token in TokenField
                    // and refreshing from the detail header could show stale
                    // data because the in-memory provider list still pointed at
                    // the pre-save providers.json state.
                    rows = BirdNionConfigStore.allProviders()
                    NotificationCenter.default.post(name: .birdnionProvidersChanged, object: nil)
                } label: {
                    // Swap the reload glyph for a spinner while a refresh is in
                    // flight so clicking gives immediate visual feedback (the
                    // header subtitle also flips to "Đang cập nhật").
                    ZStack {
                        if quota.isRefreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
                .controlSize(.small)
                .disabled(quota.isRefreshing)
                .pointingHandCursor(enabled: !quota.isRefreshing)
                .help(L10n.t("provider.reloadHelp", language))

                Toggle("", isOn: enabledBinding(idx))
                    .labelsHidden()
                    .toggleStyle(.instrument)
                    .controlSize(.small)
                }
                if selfTestState[row.id] != nil, selfTestState[row.id] != .idle {
                    selfTestResult(for: row.id)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .inkRuleBottom()
    }

    func detailInfoGrid(_ row: BirdNionConfigStore.Provider) -> some View {
        let s = status(for: row.id)
        return InstrumentSection(header: L10n.t("settings.section.info", language)) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                infoRow(
                    L10n.t("provider.status", language),
                    row.enabled == true ? L10n.t("popover.ready", language) : L10n.t("provider.disabled", language)
                )
                if row.id == "codex" {
                    // Which source actually produced the data (OAuth / CLI).
                    infoRow(L10n.t("provider.source", language),
                            L10n.providerText(s?.sourceLabel ?? "OAuth", preference: language))
                } else if row.id == "claude" {
                    // OAuth token comes from the Claude Code Keychain item.
                    infoRow(L10n.t("provider.source", language), "OAuth")
                } else if row.id == "kiro", let auth = s?.sourceLabel, !auth.isEmpty {
                    // Auth method from `kiro-cli whoami` ("Logged in with …") —
                    // CodexBar's "Auth:" menu note.
                    infoRow(L10n.t("provider.source", language),
                            L10n.providerText(auth, preference: language))
                }
                if row.id == "kiro", let ctx = s?.kiroMenu?.contextPercentUsed {
                    // Context-window usage from `kiro-cli /context` (best-effort).
                    infoRow(L10n.t("provider.kiroContext", language),
                            String(format: "%.0f%%", ctx))
                }
                if let plan = s?.planType, !plan.isEmpty {
                    infoRow(L10n.t("provider.plan", language),
                            L10n.providerText(plan.capitalized, preference: language))
                }
                if let name = s?.planName, !name.isEmpty {
                    // Plan display name (MiniMax `current_subscribe_title`) — distinct
                    // from `planType` which carries a code (`plus` / `pro`).
                    infoRow(L10n.t("provider.planName", language),
                            L10n.providerText(name, preference: language))
                }
                if let label = s?.accountLabel, !label.isEmpty {
                    infoRow(L10n.t("provider.account", language), label)
                }
                if let version = s?.version, !version.isEmpty {
                    infoRow(L10n.t("provider.version", language), version)
                }
                if let svc = s?.serviceStatus, !svc.isEmpty {
                    serviceStatusRow(svc, level: s?.serviceStatusLevel)
                }
                if row.id == "codex", let n = s?.resetCreditsAvailable {
                    infoRow(L10n.t("provider.resetCredits", language), "\(n)")
                }
                if row.id == "codex", let web = s?.codexWeb {
                    if let cr = web.codeReviewRemainingPercent {
                        infoRow(L10n.t("provider.codeReview", language), L10n.f("provider.remaining", language, cr))
                    }
                    if let n = web.creditsHistoryCount {
                        infoRow(L10n.t("provider.creditsHistory", language), "\(n)")
                    }
                    if let url = web.creditsPurchaseURL, let u = URL(string: url) {
                        GridRow {
                            Text(L10n.t("provider.buyCredits", language)).gridColumnAlignment(.leading)
                            Link(L10n.t("provider.openPage", language), destination: u)
                                .font(.plexSans(12))
                        }
                    }
                }
                if let err = s?.error {
                    // Classified remediation hint instead of the raw string;
                    // raw stays on hover. For `unknown` the hint would be a
                    // dead-end ("see details" with no details anywhere), so
                    // show the raw error inline instead (R1.3).
                    let kind = classify(rawError: err) ?? .unknown
                    errorRow(
                        value: kind == .unknown
                            ? L10n.providerText(err, preference: language)
                            : classifiedMessage(for: err),
                        rawError: err)
                } else {
                    infoRow(L10n.t("provider.updated", language), updatedSubtitle(for: row.id))
                }
                // On-disk data size (Settings → Advanced toggle). Only for
                // providers with known local dirs; scan runs off-main via
                // ProviderStorageScanner with a 5-minute cache.
                if settings.providerStorageFootprintsEnabled,
                   !ProviderStoragePaths.candidatePaths(for: row.id).isEmpty {
                    infoRow(L10n.t("provider.storage", language), storageText(for: row.id))
                }
            }
            .font(.plexSans(12))
            .foregroundStyle(SettingsTheme.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    func infoRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).gridColumnAlignment(.leading)
            Text(value)
                .foregroundStyle(SettingsTheme.primary)
                .lineLimit(2)
        }
    }

    /// Error info row: classified message as the value, raw error string on
    /// hover so the detail is always reachable (R2.3).
    func errorRow(value: String, rawError: String) -> some View {
        GridRow {
            Text(L10n.t("provider.error", language)).gridColumnAlignment(.leading)
            Text(value)
                .foregroundStyle(SettingsTheme.primary)
                .lineLimit(2)
                .help(L10n.providerText(rawError, preference: language))
        }
    }

    /// Value for the storage info row: scanned size, "no local data" when the
    /// dirs don't exist, or an ellipsis while the first scan runs.
    func storageText(for id: String) -> String {
        guard let footprint = storageScanner.footprints[id] else { return "…" }
        guard !footprint.existingPaths.isEmpty else {
            return L10n.t("provider.storage.none", language)
        }
        return ProviderStorageScanner.formatBytes(footprint.totalBytes)
    }

    /// Service-status row with a severity dot (green/yellow/orange/red).
    func serviceStatusRow(_ text: String, level: String?) -> some View {
        GridRow {
            Text(L10n.t("provider.serviceStatus", language)).gridColumnAlignment(.leading)
            HStack(spacing: 6) {
                Circle()
                    .fill(serviceStatusColor(level))
                    .frame(width: 7, height: 7)
                Text(L10n.providerText(text, preference: language))
                    .foregroundStyle(SettingsTheme.primary)
                    .lineLimit(2)
            }
        }
    }

    func serviceStatusColor(_ level: String?) -> Color {
        switch level {
        case "none": return SettingsTheme.success
        case "minor": return SettingsTheme.warningFill
        case "major": return SettingsTheme.warningFill
        case "critical": return SettingsTheme.critical
        default: return SettingsTheme.disabled
        }
    }

    // MARK: - Settings section (token / account label / login status)

    @ViewBuilder
    func settingsSection(_ idx: Int) -> some View {
        let row = rows[idx]
        InstrumentSection(header: L10n.t("settings.section.setup", language)) {
            // Account label (applies to all providers)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("provider.accountLabel", language))
                    .font(.plexSans(13, weight: .semibold))
                    .foregroundStyle(SettingsTheme.primary)
                TextField(L10n.t("provider.accountLabelPlaceholder", language), text: labelBinding(idx))
                    .instrumentFieldStyle()
                    .font(.plexSans(12))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            HairlineRule()

            if row.id == "codex" {
                // Zero-config: just show login status.
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.t("provider.signIn", language))
                        .font(.plexSans(13, weight: .semibold))
                        .foregroundStyle(SettingsTheme.primary)
                    Text(codexLoginStatus())
                        .font(.plexSans(12))
                        .foregroundStyle(SettingsTheme.secondary)
                    Text(L10n.t("provider.codexSignInHint", language))
                        .font(.plexSans(11))
                        .foregroundStyle(SettingsTheme.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            } else if row.id == "claude" {
                // Claude doesn't take a pasted API token — it uses OAuth
                // from the Keychain, browser cookies (Web), the `claude`
                // CLI (PTY), or an Anthropic Admin API key. The 4 pickers
                // below (Usage source / Cookie source / Manual cookie field
                // / Keychain prompt mode) live in `settingsSection` siblings;
                // here we just skip the generic TokenField.
                EmptyView()
            } else if row.id == "antigravity" {
                // Antigravity uses Google OAuth / CLI / running process.
                // No generic API token — controls rendered below via
                // antigravityUsageSourcePicker() / antigravityOAuthAccountsSection().
                EmptyView()
            } else if row.id == "gemini" {
                // Gemini uses Google OAuth from the Gemini CLI creds file,
                // not a pasted API token — show sign-in status instead.
                geminiSignInSection()
            } else if row.id == "grok" {
                // Grok uses grok login (~/.grok/auth.json) + optional browser
                // session on grok.com — no pasted API token.
                grokSignInSection()
            } else if row.id == "kiro" {
                // Kiro uses the Kiro CLI (no API token) — show a sign-in hint.
                kiroSignInSection()
            } else if row.id == "bedrock" {
                // Bedrock uses AWS credentials (auth-mode picker + keys/profile/
                // region), not a generic API token.
                bedrockAuthSection(idx)
            } else if Self.cookieProviderIDs.contains(row.id) {
                // Cookie-auth providers don't take a pasted API token — they read
                // the browser session cookie. Show a Cookie-source picker (Auto /
                // Manual / Off) + an optional manual Cookie-header field, mirroring
                // CodexBar (no token box).
                cookieProviderControls(row.id)
            } else if row.id == "elevenlabs" || row.id == "hiyo" {
                // Multi-key store (ElevenLabsKeyStore / HiyoKeyStore) — managed
                // in the card below settingsSection; skip the single TokenField.
                EmptyView()
            } else {
                TokenField(
                    providerID: row.id,
                    onSaved: {
                        // TokenField writes apiKey straight to disk, bypassing
                        // `rows`. Reload so the next saveAll() (enable toggle,
                        // drag reorder, label edit — all write the whole rows
                        // array) doesn't clobber the just-saved token with the
                        // stale in-memory entry.
                        rows = BirdNionConfigStore.allProviders()
                        Task { await quota.refresh() }
                    }
                )
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            if row.id == "xai" {
                HairlineRule()
                xaiTeamIDSection(idx)
            }

            if row.id == "codex" {
                HairlineRule()
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 12) {
                        Text(L10n.t("provider.dataSource", language))
                            .font(.plexSans(13, weight: .semibold))
                            .foregroundStyle(SettingsTheme.primary)
                        Spacer(minLength: 8)
                        Picker("", selection: Binding(
                            get: { settings.codexUsageSource },
                            set: { settings.codexUsageSource = $0; Task { await quota.refresh() } }
                        )) {
                            ForEach(CodexUsageSource.allCases) { src in
                                Text(codexUsageSourceName(src)).tag(src.rawValue)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 150)
                    }
                    Text(codexSourceSubtitle(for: settings.codexUsageSource))
                        .font(.plexSans(10))
                        .foregroundStyle(SettingsTheme.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            if row.id == "codex" {
                codexWebExtrasControls()
            }

            if row.id == "minimax" {
                HairlineRule()
                HStack(spacing: 12) {
                    Text(L10n.t("provider.apiRegion", language))
                        .font(.plexSans(13, weight: .semibold))
                        .foregroundStyle(SettingsTheme.primary)
                    Spacer(minLength: 8)
                    Picker("", selection: Binding(
                        get: { settings.minimaxRegion },
                        set: { settings.minimaxRegion = $0; Task { await quota.refresh() } }
                    )) {
                        ForEach(MiniMaxRegion.allCases) { r in
                            Text(miniMaxRegionName(r)).tag(r.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 150)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            if row.id == "zai" {
                HairlineRule()
                HStack(spacing: 12) {
                    Text(L10n.t("provider.apiRegion", language))
                        .font(.plexSans(13, weight: .semibold))
                        .foregroundStyle(SettingsTheme.primary)
                    Spacer(minLength: 8)
                    Picker("", selection: Binding(
                        get: { settings.zaiRegion },
                        set: { settings.zaiRegion = $0; Task { await quota.refresh() } }
                    )) {
                        ForEach(ZaiRegion.allCases) { r in
                            Text(zaiRegionName(r)).tag(r.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 170)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            if row.id == "alibaba" {
                HairlineRule()
                HStack(spacing: 12) {
                    Text(L10n.t("provider.apiRegion", language))
                        .font(.plexSans(13, weight: .semibold))
                        .foregroundStyle(SettingsTheme.primary)
                    Spacer(minLength: 8)
                    Picker("", selection: Binding(
                        get: { settings.alibabaRegion },
                        set: { settings.alibabaRegion = $0; Task { await quota.refresh() } }
                    )) {
                        ForEach(AlibabaRegion.allCases) { r in
                            Text(alibabaRegionName(r)).tag(r.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 170)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            if row.id == "bedrock" {
                HairlineRule()
                HStack(spacing: 12) {
                    Text(L10n.languageCode(language) == "vi" ? "Ngân sách tháng (USD)" : "Monthly budget (USD)")
                        .font(.plexSans(13, weight: .semibold))
                        .foregroundStyle(SettingsTheme.primary)
                    Spacer(minLength: 8)
                    TextField("∞", text: Binding(
                        get: {
                            guard let b = rows[idx].budget else { return "" }
                            return String(b)
                        },
                        set: { raw in
                            rows[idx].budget = Double(raw.trimmingCharacters(in: .whitespaces))
                            saveAll()
                            NotificationCenter.default.post(name: .birdnionRefresh, object: nil)
                        }
                    ))
                    .multilineTextAlignment(.trailing)
                    .instrumentFieldStyle()
                    .frame(width: 90)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            if row.id == "deepgram" {
                HairlineRule()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Project ID")
                        .font(.plexSans(13, weight: .semibold))
                        .foregroundStyle(SettingsTheme.primary)
                    Text(L10n.languageCode(language) == "vi"
                         ? "Tùy chọn. Để trống = lấy & gộp tất cả project của API key."
                         : "Optional. Leave blank to discover and aggregate all projects.")
                        .font(.plexSans(11))
                        .foregroundStyle(SettingsTheme.secondary)
                    TextField("xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx", text: Binding(
                        get: { rows[idx].projectID ?? "" },
                        set: { raw in
                            let v = raw.trimmingCharacters(in: .whitespaces)
                            rows[idx].projectID = v.isEmpty ? nil : v
                            saveAll()
                            NotificationCenter.default.post(name: .birdnionRefresh, object: nil)
                        }
                    ))
                    .instrumentFieldStyle()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            if row.id == "openai" {
                HairlineRule()
                VStack(alignment: .leading, spacing: 4) {
                    let vi = L10n.languageCode(language) == "vi"
                    Text(vi ? "OpenAI Project ID" : "OpenAI Project ID")
                        .font(.plexSans(13, weight: .semibold))
                        .foregroundStyle(SettingsTheme.primary)
                    Text(vi
                         ? "Tùy chọn (proj_…). Dùng Admin API key (OPENAI_ADMIN_KEY). Không phải ChatGPT/Codex quota — đó là provider Codex."
                         : "Optional (proj_…). Prefer an Admin API key (OPENAI_ADMIN_KEY). Not ChatGPT/Codex quota — use the Codex provider for that.")
                        .font(.plexSans(11))
                        .foregroundStyle(SettingsTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField("proj_…", text: Binding(
                        get: { rows[idx].projectID ?? "" },
                        set: { raw in
                            let v = raw.trimmingCharacters(in: .whitespaces)
                            rows[idx].projectID = v.isEmpty ? nil : v
                            saveAll()
                            NotificationCenter.default.post(name: .birdnionRefresh, object: nil)
                        }
                    ))
                    .instrumentFieldStyle()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            if row.id == "copilot" {
                HairlineRule()
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.languageCode(language) == "vi" ? "GitHub Enterprise Host" : "GitHub Enterprise Host")
                        .font(.plexSans(13, weight: .semibold))
                        .foregroundStyle(SettingsTheme.primary)
                    Text(L10n.languageCode(language) == "vi"
                         ? "Tùy chọn. Nhập GitHub Enterprise host (vd octocorp.ghe.com). Để trống = github.com."
                         : "Optional. Enter GitHub Enterprise host (e.g. octocorp.ghe.com). Leave blank = github.com.")
                        .font(.plexSans(11))
                        .foregroundStyle(SettingsTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField("github.com", text: Binding(
                        get: { rows[idx].baseURL ?? "" },
                        set: { raw in
                            let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                            rows[idx].baseURL = v.isEmpty ? nil : v
                            saveAll()
                            NotificationCenter.default.post(name: .birdnionRefresh, object: nil)
                        }
                    ))
                    .instrumentFieldStyle()
                    .font(.plexSans(12))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            if row.id == "claude" {
                claudeUsageSourcePicker()
                claudeCookieSourcePicker()
                if settings.claudeCookieSource == "manual" {
                    HairlineRule()
                    claudeManualCookieField()
                }
                claudeOAuthKeychainPromptPicker()
                claudeAccountsSection()
            }

            if row.id == "antigravity" {
                antigravityUsageSourcePicker()
            }

            if row.id == "kilo" {
                kiloUsageSourcePicker()
                kiloOrganizationsSection()
            }

            // Per-provider refresh interval — applies to every provider.
            // Stored in UserDefaults under "refreshInterval.<id>" and read
            // by QuotaService.effectiveInterval(for:) at the start of each
            // refresh cycle. 0 = use the global QuotaService interval.
            providerRefreshIntervalPicker(for: row)
        }
    }

    /// Universal "refresh every" picker. Options cover the same range as the
    /// global QuotaService interval plus a "Use global (X)" row that shows
    /// the inherited cadence so the user can tell what they're falling
    /// back to. Mirrors CodexBar's per-provider override pattern.
    @ViewBuilder
    func providerRefreshIntervalPicker(for row: BirdNionConfigStore.Provider) -> some View {
        HairlineRule()
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("provider.refreshEvery", language))
                    .font(.plexSans(13, weight: .semibold))
                    .foregroundStyle(SettingsTheme.primary)
                Text(L10n.f("provider.defaultGlobal", language, globalIntervalLabel))
                    .font(.plexSans(10))
                    .foregroundStyle(SettingsTheme.tertiary)
            }
            Spacer(minLength: 8)
            Picker("", selection: Binding(
                get: { Self.providerRefreshSeconds(row.id) },
                set: { newValue in
                    Self.setProviderRefreshSeconds(row.id, newValue)
                    NotificationCenter.default.post(name: .birdnionProvidersChanged, object: nil)
                }
            )) {
                ForEach(Self.providerRefreshOptions, id: \.self) { seconds in
                    Text(providerRefreshLabel(seconds)).tag(seconds)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 150)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    func providerRefreshLabel(_ seconds: Double) -> String {
        switch seconds {
        case 0: return L10n.t("refresh.default", language)
        case 30: return L10n.t("refresh.30s", language)
        case 60: return L10n.t("refresh.1m", language)
        case 120: return L10n.t("refresh.2m", language)
        case 300: return L10n.t("refresh.5m", language)
        case 600: return L10n.t("refresh.10m", language)
        case 1800: return L10n.t("refresh.30m", language)
        default: return L10n.duration(seconds, preference: language)
        }
    }

    static func providerRefreshSeconds(_ id: String) -> Double {
        UserDefaults.standard.double(forKey: "refreshInterval.\(id)")
    }

    static func setProviderRefreshSeconds(_ id: String, _ seconds: Double) {
        UserDefaults.standard.set(seconds, forKey: "refreshInterval.\(id)")
    }

    /// Human-readable label for the global interval — used in the picker
    /// subtitle so the user knows what "Mặc định chung" falls back to.
    var globalIntervalLabel: String {
        let secs = settings.refreshIntervalSeconds
        return L10n.duration(secs, preference: language)
    }

    func codexUsageSourceName(_ source: CodexUsageSource) -> String {
        switch source {
        case .auto: return L10n.t("source.auto", language)
        case .oauth: return L10n.t("source.oauth", language)
        case .cli: return L10n.t("source.cli", language)
        }
    }

    func codexMenuBarMetricName(_ metric: CodexMenuBarMetric) -> String {
        switch metric {
        case .automatic: return L10n.t("metric.automatic", language)
        case .session: return L10n.t("metric.session", language)
        case .weekly: return L10n.t("metric.weekly", language)
        }
    }

    func miniMaxRegionName(_ region: MiniMaxRegion) -> String {
        switch region {
        case .io: return "Global (platform.minimax.io)"
        case .com: return L10n.t("region.china", language)
        }
    }

    func zaiRegionName(_ region: ZaiRegion) -> String {
        switch region {
        case .global: return "Global (api.z.ai)"
        case .cn: return "BigModel CN (open.bigmodel.cn)"
        }
    }

    func alibabaRegionName(_ region: AlibabaRegion) -> String {
        switch region {
        case .international: return "International (Singapore)"
        case .chinaMainland: return "China Mainland (Beijing)"
        }
    }

    func claudeUsageSourceName(_ source: ClaudeUsageDataSource) -> String {
        switch source {
        case .auto: return L10n.t("source.auto", language)
        case .api: return "API (Admin key)"
        case .oauth: return "OAuth API"
        case .web: return "Web API (cookies)"
        case .cli: return "CLI (PTY)"
        }
    }

    // Native cookie-source enum drives both the Claude and Codex cookie pickers
    // (identical auto/manual/off cases). Bindings persist the rawValue string,
    // which CodexWebDashboard still maps onto its own CodexBarCore enum — so the
    // Settings UI needs no CodexBarCore import.
    func cookieSourceName(_ source: ClaudeCookieSource) -> String {
        switch source {
        case .auto: return "Auto"
        case .manual: return L10n.languageCode(language) == "vi" ? "Thủ công" : "Manual"
        case .off: return L10n.languageCode(language) == "vi" ? "Tắt" : "Off"
        }
    }

    // MARK: - Cookie-auth providers

    /// Cookie-source picker (Auto / Manual / Off) + manual Cookie-header field.
    /// Persists to UserDefaults `<id>CookieSource` / `<id>ManualCookie`, which
    /// `ProviderCookieReader.resolvedCookieHeader` reads. Mirrors CodexBar's
    /// cookie providers (no token box).
    @ViewBuilder
    func cookieProviderControls(_ id: String) -> some View {
        let sourceKey = "\(id)CookieSource"
        let manualKey = "\(id)ManualCookie"
        let vi = L10n.languageCode(language) == "vi"
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(vi ? "Nguồn cookie" : "Cookie source")
                    .font(.plexSans(13, weight: .semibold))
                    .foregroundStyle(SettingsTheme.primary)
                Spacer(minLength: 8)
                Picker("", selection: Binding(
                    get: { UserDefaults.standard.string(forKey: sourceKey) ?? "auto" },
                    set: { UserDefaults.standard.set($0, forKey: sourceKey); Task { await quota.refresh() } }
                )) {
                    ForEach(ClaudeCookieSource.allCases) { s in
                        Text(cookieSourceName(s)).tag(s.rawValue)
                    }
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 120)
            }
            Text(vi
                 ? "Auto: tự đọc cookie từ trình duyệt (Brave/Chrome/Safari…). Manual: dán Cookie header bên dưới."
                 : "Auto imports browser cookies. Manual uses the pasted Cookie header below.")
                .font(.plexSans(10))
                .foregroundStyle(SettingsTheme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Cookie: name=value; name2=value2 …", text: Binding(
                get: { UserDefaults.standard.string(forKey: manualKey) ?? "" },
                set: { UserDefaults.standard.set($0, forKey: manualKey) }
            ))
            .instrumentFieldStyle()
            .font(.plexSans(11))
            Text(vi
                 ? "Chỉ dùng khi chọn Manual. Lấy ở DevTools → Network → request → header Cookie."
                 : "Used only when source = Manual. Copy from DevTools → Network → Cookie header.")
                .font(.plexSans(10))
                .foregroundStyle(SettingsTheme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Claude parity pickers

    /// Usage source picker — mirrors CodexBar's `ClaudeUsageDataSource`.
    /// `.auto` walks OAuth → Web → CLI; `.oauth` pins to OAuth (default);
    /// `.web` uses cookies only; `.cli` spawns `claude` PTY; `.api` requires
    /// an Anthropic Admin API key (handled by the field below when picked).
    @ViewBuilder
    func claudeUsageSourcePicker() -> some View {
        HairlineRule()
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text(L10n.t("provider.dataSource", language))
                    .font(.plexSans(13, weight: .semibold))
                    .foregroundStyle(SettingsTheme.primary)
                Spacer(minLength: 8)
                Picker("", selection: Binding(
                    get: { settings.claudeUsageDataSource },
                    // Forced: bypasses the per-provider throttle (Claude may
                    // poll every 30m) and marks the fetch user-initiated so
                    // rate-limit/Keychain gates don't suppress it.
                    set: { settings.claudeUsageDataSource = $0
                           Task { await quota.refresh(forceProviderIDs: ["claude"]) } }
                )) {
                    ForEach(ClaudeUsageDataSource.allCases) { src in
                        Text(claudeUsageSourceName(src)).tag(src.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 170)
            }
            Text(sourceSubtitle(for: settings.claudeUsageDataSource))
                .font(.plexSans(10))
                .foregroundStyle(SettingsTheme.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    func sourceSubtitle(for source: String) -> String {
        switch source {
        case "auto": return L10n.t("source.claude.auto.subtitle", language)
        case "oauth": return L10n.t("source.claude.oauth.subtitle", language)
        case "web": return L10n.t("source.claude.web.subtitle", language)
        case "cli": return L10n.t("source.claude.cli.subtitle", language)
        case "api": return L10n.t("source.claude.api.subtitle", language)
        default: return ""
        }
    }

    func codexSourceSubtitle(for source: String) -> String {
        switch source {
        case "auto": return L10n.t("source.codex.auto.subtitle", language)
        case "oauth": return L10n.t("source.codex.oauth.subtitle", language)
        case "cli": return L10n.t("source.codex.cli.subtitle", language)
        default: return ""
        }
    }

    /// OpenAI web extras toggle + cookie source (auto/manual) for Codex.
    @ViewBuilder
    func codexWebExtrasControls() -> some View {
        HairlineRule()
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { settings.codexOpenAIWebEnabled },
                set: { settings.codexOpenAIWebEnabled = $0; Task { await quota.refresh() } }
            )) {
                Text(L10n.t("provider.openAIWebExtras", language))
                    .font(.plexSans(13, weight: .semibold))
                    .foregroundStyle(SettingsTheme.primary)
            }
            .toggleStyle(.instrument)
            Text(L10n.t("provider.openAIWebExtrasHelp", language))
                .font(.plexSans(10))
                .foregroundStyle(SettingsTheme.tertiary)

            if settings.codexOpenAIWebEnabled {
                HStack(spacing: 12) {
                    Text(L10n.t("provider.cookie", language))
                        .font(.plexSans(12))
                        .foregroundStyle(SettingsTheme.primary)
                    Spacer(minLength: 8)
                    Picker("", selection: Binding(
                        get: { settings.codexCookieSource },
                        set: { settings.codexCookieSource = $0; Task { await quota.refresh() } }
                    )) {
                        ForEach(ClaudeCookieSource.allCases) { src in
                            Text(cookieSourceName(src)).tag(src.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 110)
                }
                if settings.codexCookieSource == "manual" {
                    TextField(L10n.t("provider.cookiePlaceholder", language), text: Binding(
                        get: { settings.codexManualCookieHeader },
                        set: { settings.codexManualCookieHeader = $0 }
                    ))
                    .instrumentFieldStyle()
                    .font(.plexSans(11))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Cookie source picker — mirrors CodexBar's `ProviderCookieSource`.
    @ViewBuilder
    func claudeCookieSourcePicker() -> some View {
        HairlineRule()
        HStack(spacing: 12) {
            Text(L10n.t("provider.cookieClaude", language))
                .font(.plexSans(13, weight: .semibold))
                .foregroundStyle(SettingsTheme.primary)
            Spacer(minLength: 8)
            Picker("", selection: Binding(
                get: { settings.claudeCookieSource },
                set: { settings.claudeCookieSource = $0
                       Task { await quota.refresh(forceProviderIDs: ["claude"]) } }
            )) {
                ForEach(ClaudeCookieSource.allCases) { src in
                    Text(cookieSourceName(src)).tag(src.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 110)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Manual Cookie: header field (only visible when source == .manual).
    /// User pastes the value copied from DevTools → Network → claude.ai
    /// request headers. Stored plaintext (only the user sees it).
    @ViewBuilder
    func claudeManualCookieField() -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.t("provider.manualCookie", language))
                .font(.plexSans(12, weight: .semibold))
                .foregroundStyle(SettingsTheme.primary)
            SecureField("sessionKey=...; cf_clearance=...", text: Binding(
                get: { settings.claudeManualCookieHeader },
                set: { settings.claudeManualCookieHeader = $0 }
            ))
            .instrumentFieldStyle()
            .font(.plexSans(11))
            Text(L10n.t("provider.manualCookieHelp", language))
                .font(.plexSans(10))
                .foregroundStyle(SettingsTheme.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Keychain prompt policy picker — mirrors CodexBar's
    /// `ClaudeOAuthKeychainPromptMode`. `.never` skips OAuth entirely (use
    /// Web/CLI); `.onlyOnUserAction` prompts only on manual refresh;
    /// `.always` prompts on every background fetch.
    @ViewBuilder
    func claudeOAuthKeychainPromptPicker() -> some View {
        HairlineRule()
        HStack(spacing: 12) {
            Text(L10n.t("provider.keychainOAuth", language))
                .font(.plexSans(13, weight: .semibold))
                .foregroundStyle(SettingsTheme.primary)
            Spacer(minLength: 8)
            Picker("", selection: Binding(
                get: { settings.claudeOAuthKeychainPromptMode },
                set: { settings.claudeOAuthKeychainPromptMode = $0
                       Task { await quota.refresh(forceProviderIDs: ["claude"]) } }
            )) {
                Text(L10n.t("prompt.never", language)).tag(ClaudeOAuthKeychainPromptMode.never.rawValue)
                Text(L10n.t("prompt.onlyOnUserAction", language)).tag(ClaudeOAuthKeychainPromptMode.onlyOnUserAction.rawValue)
                Text(L10n.t("prompt.always", language)).tag(ClaudeOAuthKeychainPromptMode.always.rawValue)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 130)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Menu-bar display (mockup: HIỂN THỊ MENU BAR)

    /// Dedicated card for menu-bar metric pickers. Same controls as before —
    /// only re-homed out of the setup card so the section header matches mockup.
    @ViewBuilder
    func menuBarDisplaySection(for id: String) -> some View {
        let hasCodex = id == "codex"
        let hasGeneric = id == "gemini" || id == "kiro" || id == "bedrock"
        let hasKiroValue = id == "kiro"
        if hasCodex || hasGeneric || hasKiroValue {
            InstrumentSection(header: L10n.t("settings.section.menuBarDisplay", language)) {
                if hasCodex {
                    HStack(spacing: 12) {
                        Text(L10n.t("provider.menuBarMetric", language))
                            .font(.plexSans(13, weight: .semibold))
                            .foregroundStyle(SettingsTheme.primary)
                        Spacer(minLength: 8)
                        Picker("", selection: Binding(
                            get: { settings.codexMenuBarMetric },
                            set: {
                                settings.codexMenuBarMetric = $0
                                // Re-fetch so the menu bar rebuilds its frames with
                                // the newly selected window.
                                NotificationCenter.default.post(name: .birdnionRefresh, object: nil)
                            }
                        )) {
                            ForEach(CodexMenuBarMetric.allCases) { m in
                                Text(codexMenuBarMetricName(m)).tag(m.rawValue)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 150)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                if hasGeneric {
                    if hasCodex { HairlineRule() }
                    menuBarMetricPicker(for: id)
                }
                if hasKiroValue {
                    if hasCodex || hasGeneric { HairlineRule() }
                    kiroMenuBarValuePicker()
                }
            }
        }
    }

    /// Per-provider "Menu bar metric" picker (CodexBar parity): Automatic (all
    /// windows) or one named window. Options come from the current status's
    /// windows, so labels match what the menu bar shows.
    @ViewBuilder
    func menuBarMetricPicker(for id: String) -> some View {
        let vi = L10n.languageCode(language) == "vi"
        let windows = status(for: id)?.windows ?? []
        let settings = settings
        let caps = settings.providerCapabilities(for: id)
        let pref = settings.metricPreference(for: id)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text(L10n.t("provider.menuBarMetric", language))
                    .font(.plexSans(13, weight: .semibold))
                    .foregroundStyle(SettingsTheme.primary)
                Spacer(minLength: 8)
                Picker("", selection: Binding(
                    get: { _ = menuBarMetricTick; return pref },
                    set: {
                        settings.setMetricPreference($0, for: id)
                        menuBarMetricTick += 1
                    }
                )) {
                    Text(vi ? "Tự động" : "Automatic").tag(MenuBarMetricPreference.automatic)
                    if caps.hasPrimary { Text(vi ? "Chính" : "Primary").tag(MenuBarMetricPreference.primary) }
                    if caps.hasSecondary { Text(vi ? "Phụ" : "Secondary").tag(MenuBarMetricPreference.secondary) }
                    if caps.hasPrimary && caps.hasSecondary { Text(vi ? "Chính + Phụ" : "Primary + Secondary").tag(MenuBarMetricPreference.primaryAndSecondary) }
                    if caps.hasTertiary { Text(vi ? "Thứ ba" : "Tertiary").tag(MenuBarMetricPreference.tertiary) }
                    if caps.hasExtraUsage { Text(vi ? "Sử dụng thêm" : "Extra Usage").tag(MenuBarMetricPreference.extraUsage) }
                    if caps.supportsAverage { Text(vi ? "Trung bình" : "Average").tag(MenuBarMetricPreference.average) }
                    if caps.hasMonthlyPlan { Text(vi ? "Gói tháng" : "Monthly Plan").tag(MenuBarMetricPreference.monthlyPlan) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 170)
            }
            Text(vi ? "Chọn window nào lái % trên menu bar."
                    : "Choose which window drives the menu bar percent.")
                .font(.plexSans(10))
                .foregroundStyle(SettingsTheme.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    func kiroMenuBarValueName(_ m: KiroMenuBarDisplayMode) -> String {
        let vi = L10n.languageCode(language) == "vi"
        switch m {
        case .automatic: return vi ? "Tự động" : "Automatic"
        case .hidden: return vi ? "Ẩn" : "Hidden"
        case .creditsLeft: return vi ? "Credits còn lại" : "Credits left"
        case .percentLeft: return vi ? "Phần trăm còn lại" : "Percent left"
        case .creditsAndPercent: return vi ? "Credits + %" : "Credits + percent"
        case .usedAndTotal: return vi ? "Đã dùng / tổng" : "Used / total"
        case .overageCreditsWhenExhausted: return vi ? "Overage credits (khi hết)" : "Overage credits at zero"
        case .overageCostWhenExhausted: return vi ? "Overage $ (khi hết)" : "Overage cost at zero"
        case .overageCreditsAndCostWhenExhausted: return vi ? "Overage credits + $ (khi hết)" : "Overage credits + cost at zero"
        }
    }

    @ViewBuilder
    func kiroMenuBarValuePicker() -> some View {
        let vi = L10n.languageCode(language) == "vi"
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text(vi ? "Giá trị menu bar Kiro" : "Kiro menu bar value")
                    .font(.plexSans(13, weight: .semibold))
                    .foregroundStyle(SettingsTheme.primary)
                Spacer(minLength: 8)
                Picker("", selection: Binding(
                    get: { settings.kiroMenuBarDisplayMode },
                    set: {
                        settings.kiroMenuBarDisplayMode = $0
                        NotificationCenter.default.post(name: .birdnionRefresh, object: nil)
                    }
                )) {
                    ForEach(KiroMenuBarDisplayMode.allCases) { m in
                        Text(kiroMenuBarValueName(m)).tag(m.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 200)
            }
            Text(vi ? "Hiện credits, phần trăm, hoặc cả hai cạnh icon menu bar."
                    : "Show or hide Kiro credits, percent, or both next to the menu bar icon.")
                .font(.plexSans(10))
                .foregroundStyle(SettingsTheme.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Gemini / Kiro sign-in (zero-config) + Bedrock AWS auth

    func geminiLoginStatus() -> String {
        let vi = L10n.languageCode(language) == "vi"
        if let email = GeminiProvider.signedInEmail() {
            return vi ? "Đã đăng nhập: \(email)" : "Signed in: \(email)"
        }
        if GeminiProvider.isSignedIn() {
            return vi ? "Đã đăng nhập" : "Signed in"
        }
        return vi ? "Chưa đăng nhập" : "Not signed in"
    }

    @ViewBuilder
    func geminiSignInSection() -> some View {
        let vi = L10n.languageCode(language) == "vi"
        VStack(alignment: .leading, spacing: 4) {
            Text(vi ? "Đăng nhập" : "Sign in")
                .font(.plexSans(13, weight: .semibold))
                .foregroundStyle(SettingsTheme.primary)
            Text(geminiLoginStatus())
                .font(.plexSans(12))
                .foregroundStyle(SettingsTheme.secondary)
            Text(vi
                 ? "Gemini dùng đăng nhập Google qua Gemini CLI (~/.gemini/oauth_creds.json). Chạy `gemini` rồi đăng nhập."
                 : "Gemini uses Google sign-in via the Gemini CLI (~/.gemini/oauth_creds.json). Run `gemini` and log in.")
                .font(.plexSans(11))
                .foregroundStyle(SettingsTheme.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    func kiroSignInSection() -> some View {
        let vi = L10n.languageCode(language) == "vi"
        VStack(alignment: .leading, spacing: 4) {
            Text(vi ? "Đăng nhập" : "Sign in")
                .font(.plexSans(13, weight: .semibold))
                .foregroundStyle(SettingsTheme.primary)
            Text(vi
                 ? "Kiro dùng Kiro CLI (không cần API token). Đăng nhập bằng `kiro-cli login`; usage lấy qua CLI."
                 : "Kiro uses the Kiro CLI (no API token). Sign in with `kiro-cli login`; usage is read via the CLI.")
                .font(.plexSans(11))
                .foregroundStyle(SettingsTheme.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    func grokLoginStatus() -> String {
        let vi = L10n.languageCode(language) == "vi"
        if let email = GrokProvider.signedInEmail() {
            return vi ? "Đã đăng nhập: \(email)" : "Signed in: \(email)"
        }
        if GrokProvider.isSignedIn() {
            return vi ? "Đã đăng nhập (CLI/auth)" : "Signed in (CLI/auth)"
        }
        return vi ? "Chưa đăng nhập" : "Not signed in"
    }

    @ViewBuilder
    func grokSignInSection() -> some View {
        let vi = L10n.languageCode(language) == "vi"
        VStack(alignment: .leading, spacing: 4) {
            Text(vi ? "Đăng nhập" : "Sign in")
                .font(.plexSans(13, weight: .semibold))
                .foregroundStyle(SettingsTheme.primary)
            Text(grokLoginStatus())
                .font(.plexSans(12))
                .foregroundStyle(SettingsTheme.secondary)
            Text(vi
                 ? "Grok đọc `~/.grok/auth.json` (chạy `grok login`) và fallback billing grok.com qua cookie Chrome. Không cần dán API token."
                 : "Grok reads `~/.grok/auth.json` (`grok login`) and falls back to grok.com billing via Chrome cookies. No API token paste.")
                .font(.plexSans(11))
                .foregroundStyle(SettingsTheme.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// One labeled AWS credential field bound to a config keyPath via `rows[idx]`.
    @ViewBuilder
    func bedrockField(
        _ idx: Int, title: String, placeholder: String,
        keyPath: WritableKeyPath<BirdNionConfigStore.Provider, String?>, secure: Bool) -> some View {
        let binding = Binding<String>(
            get: { rows[idx][keyPath: keyPath] ?? "" },
            set: { raw in
                let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                rows[idx][keyPath: keyPath] = v.isEmpty ? nil : v
                saveAll()
                NotificationCenter.default.post(name: .birdnionRefresh, object: nil)
            })
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.plexSans(12, weight: .medium))
                .foregroundStyle(SettingsTheme.primary)
            if secure {
                SecureField(placeholder, text: binding)
                    .instrumentFieldStyle().font(.plexSans(12))
            } else {
                TextField(placeholder, text: binding)
                    .instrumentFieldStyle().font(.plexSans(12))
            }
        }
    }

    @ViewBuilder
    func xaiTeamIDSection(_ idx: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.t("xai.teamId.title", language))
                .font(.plexSans(13, weight: .semibold))
                .foregroundStyle(SettingsTheme.primary)
            Text(L10n.t("xai.teamId.hint", language))
                .font(.plexSans(11))
                .foregroundStyle(SettingsTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("team_…", text: Binding(
                get: { rows[idx].region ?? "" },
                set: { raw in
                    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    rows[idx].region = value.isEmpty ? nil : value
                    saveAll()
                    NotificationCenter.default.post(name: .birdnionRefresh, object: nil)
                }
            ))
            .instrumentFieldStyle()
            .font(.plexMono(12))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    func xaiCostSection(_ status: ProviderStatus?) -> some View {
        if let cost = status?.cost {
            InstrumentSection(header: L10n.t("settings.section.cost", language)) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L10n.languageCode(language) == "vi" ? "Chi tiêu" : "Spend")
                        .font(.plexMono(11, weight: .semibold))
                        .foregroundStyle(SettingsTheme.secondary)
                        .tracking(0.5)
                        .textCase(.uppercase)
                    Spacer(minLength: 8)
                    Text(UsageFormatter.usdString(cost.used))
                        .font(.plexMono(12, weight: .semibold))
                        .foregroundStyle(SettingsTheme.primary)
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                HStack {
                    Text(L10n.providerText(cost.period ?? "Last 30 days", preference: language))
                    Spacer()
                }
                .font(.plexSans(10))
                .foregroundStyle(SettingsTheme.tertiary)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
        }
    }

    @ViewBuilder
    func bedrockAuthSection(_ idx: Int) -> some View {
        let vi = L10n.languageCode(language) == "vi"
        let mode = rows[idx].awsAuthMode ?? "keys"
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(vi ? "Xác thực" : "Authentication")
                    .font(.plexSans(13, weight: .semibold))
                    .foregroundStyle(SettingsTheme.primary)
                Spacer(minLength: 8)
                Picker("", selection: Binding(
                    get: { rows[idx].awsAuthMode ?? "keys" },
                    set: {
                        rows[idx].awsAuthMode = $0
                        saveAll()
                        NotificationCenter.default.post(name: .birdnionRefresh, object: nil)
                    }
                )) {
                    Text(vi ? "Khóa truy cập" : "Access keys").tag("keys")
                    Text("AWS profile").tag("profile")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 150)
            }
            if mode == "profile" {
                bedrockField(idx, title: vi ? "Tên profile" : "Profile name",
                             placeholder: "default", keyPath: \.awsProfile, secure: false)
                Text(vi
                     ? "Profile trong ~/.aws/config (dùng khóa tĩnh; SSO/assume-role chưa hỗ trợ)."
                     : "Named profile from ~/.aws/config (static keys; SSO/assume-role not yet supported).")
                    .font(.plexSans(10))
                    .foregroundStyle(SettingsTheme.tertiary)
            } else {
                bedrockField(idx, title: "Access key ID",
                             placeholder: "AKIA…", keyPath: \.apiKey, secure: true)
                bedrockField(idx, title: vi ? "Secret access key" : "Secret access key",
                             placeholder: "", keyPath: \.secretKey, secure: true)
            }
            bedrockField(idx, title: "Region", placeholder: "us-east-1",
                         keyPath: \.region, secure: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Links / dashboards

    /// External management links for the selected provider. Codex also gets a
    /// status page + changelog; MiniMax's dashboard follows the chosen region.
    @ViewBuilder
    func linksSection(_ row: BirdNionConfigStore.Provider) -> some View {
        let links = dashboardLinks(for: row.id)
        if !links.isEmpty {
            InstrumentSection(header: L10n.t("settings.section.links", language)) {
                ForEach(Array(links.enumerated()), id: \.offset) { i, link in
                    Button {
                        NSWorkspace.shared.open(link.url)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: link.icon)
                                .frame(width: 16)
                            Text(link.title)
                                .textCase(.uppercase)
                                .tracking(0.4)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.plexMono(10, weight: .semibold))
                        }
                        .font(.plexMono(11, weight: .medium))
                        .foregroundStyle(SettingsTheme.accent)
                        .contentShape(Rectangle())
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    if i < links.count - 1 { HairlineRule() }
                }
            }
        }
    }

    struct DashboardLink { let title: String; let icon: String; let url: URL }

    func dashboardLinks(for id: String) -> [DashboardLink] {
        func u(_ s: String) -> URL? { URL(string: s) }
        // Generic link builders so each provider stays a one-liner. URLs mirror
        // CodexBar's descriptors exactly (see docs/provider-parity).
        func dash(_ s: String) -> DashboardLink? {
            u(s).map { DashboardLink(title: L10n.t("provider.link.dashboard", language), icon: "chart.bar", url: $0) }
        }
        func stat(_ s: String) -> DashboardLink? {
            u(s).map { DashboardLink(title: L10n.t("provider.link.status", language), icon: "waveform.path.ecg", url: $0) }
        }
        func usage(_ s: String) -> DashboardLink? {
            u(s).map { DashboardLink(title: L10n.t("provider.link.usage", language), icon: "chart.bar", url: $0) }
        }
        func sub(_ s: String) -> DashboardLink? {
            u(s).map { DashboardLink(title: L10n.t("provider.link.subscription", language), icon: "creditcard", url: $0) }
        }
        func billing(_ s: String) -> DashboardLink? {
            u(s).map { DashboardLink(title: L10n.t("provider.link.billing", language), icon: "creditcard", url: $0) }
        }
        func changelog(_ s: String) -> DashboardLink? {
            u(s).map { DashboardLink(title: L10n.t("provider.link.changelog", language), icon: "doc.text", url: $0) }
        }
        let googleStatus = "https://www.google.com/appsstatus/dashboard/products/npdyhgECDJ6tB66MxXyo/history"
        let awsStatus = "https://health.aws.amazon.com/health/status"

        switch id {
        case "codex":
            return [
                u("https://chatgpt.com/codex/settings/usage").map { DashboardLink(title: L10n.t("provider.link.codexUsage", language), icon: "chart.bar", url: $0) },
                stat("https://status.openai.com/"),
                changelog("https://github.com/openai/codex/releases"),
            ].compactMap { $0 }
        case "claude":
            return [
                billing("https://console.anthropic.com/settings/billing"),
                usage("https://claude.ai/settings/usage"),
                stat("https://status.claude.com/"),
            ].compactMap { $0 }
        case "minimax":
            return [DashboardLink(title: L10n.t("provider.link.minimaxPlan", language), icon: "chart.bar", url: MiniMaxRegion.current.dashboardURL)]
        case "openrouter":
            return [
                u("https://openrouter.ai/settings/credits").map { DashboardLink(title: L10n.t("provider.link.openRouterCredits", language), icon: "chart.bar", url: $0) },
                u("https://openrouter.ai/keys").map { DashboardLink(title: L10n.t("provider.link.apiKeys", language), icon: "key", url: $0) },
                stat("https://status.openrouter.ai"),
            ].compactMap { $0 }
        case "tryapi":
            return [
                dash("https://tryapi.tryai.chat/dashboard"),
                u("https://tryapi.tryai.chat/keys").map { DashboardLink(title: L10n.t("provider.link.apiKeys", language), icon: "key", url: $0) },
            ].compactMap { $0 }
        case "deepseek":
            return [
                u("https://platform.deepseek.com/usage").map { DashboardLink(title: L10n.t("provider.link.deepSeekBalance", language), icon: "chart.bar", url: $0) },
                stat("https://status.deepseek.com"),
            ].compactMap { $0 }
        case "zai":
            return [DashboardLink(title: L10n.t("provider.link.codingPlan", language), icon: "chart.bar",
                                  url: URL(string: "https://z.ai/manage-apikey/coding-plan/personal/my-plan")!)]
        case "elevenlabs":
            return [usage("https://elevenlabs.io/app/developers/usage"),
                    sub("https://elevenlabs.io/app/subscription"),
                    stat("https://status.elevenlabs.io")].compactMap { $0 }
        case "deepgram":
            return [dash("https://console.deepgram.com/project/"), stat("https://status.deepgram.com")].compactMap { $0 }
        case "groq":
            return [dash("https://console.groq.com/dashboard/metrics"), stat("https://status.groq.com")].compactMap { $0 }
        case "grok":
            return [usage("https://grok.com/?_s=usage"),
                    changelog("https://x.ai/news"),
                    stat("https://status.x.ai")].compactMap { $0 }
        case "xai":
            return [dash("https://console.x.ai"), stat("https://status.x.ai")].compactMap { $0 }
        case "openai":
            return [usage("https://platform.openai.com/usage"),
                    dash("https://platform.openai.com/settings/organization/admin-keys"),
                    stat("https://status.openai.com")].compactMap { $0 }
        case "ollama":
            return [dash("https://ollama.com/settings"),
                    usage("https://ollama.com/settings/keys")].compactMap { $0 }
        case "copilot":
            return [dash("https://github.com/settings/copilot"), stat("https://www.githubstatus.com/")].compactMap { $0 }
        case "kilo":
            return [dash("https://app.kilo.ai/usage")].compactMap { $0 }
        case "commandcode":
            return [dash("https://commandcode.ai/studio")].compactMap { $0 }
        case "freemodel":
            return [usage("https://freemodel.dev/dashboard/usage")].compactMap { $0 }
        case "mimo":
            return [dash("https://platform.xiaomimimo.com/#/console/balance")].compactMap { $0 }
        case "opencode", "opencodego":
            return [dash("https://opencode.ai")].compactMap { $0 }
        case "cursor":
            return [dash("https://cursor.com/dashboard?tab=usage"), stat("https://status.cursor.com")].compactMap { $0 }
        case "gemini":
            return [dash("https://gemini.google.com"),
                    stat(googleStatus),
                    changelog("https://github.com/google-gemini/gemini-cli/releases")].compactMap { $0 }
        case "kiro":
            return [dash("https://app.kiro.dev/account/usage"), stat(awsStatus)].compactMap { $0 }
        case "antigravity":
            return [stat(googleStatus)].compactMap { $0 }
        case "bedrock":
            return [dash("https://console.aws.amazon.com/bedrock"), stat(awsStatus)].compactMap { $0 }
        default:
            return []
        }
    }
}
