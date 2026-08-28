import SwiftUI

// MARK: - Provider multi-account sections (P4 module split)

extension ProvidersPane {
    // MARK: - Claude accounts (multi-account)

    /// Account switcher: lists stored Claude accounts (web sessionKey / Admin
    /// API key), lets the user pick the active one, delete, or add a new one.
    /// OAuth stays single-account (system Keychain); this governs web/admin.
    @ViewBuilder
    func claudeAccountsSection() -> some View {
        // Instrument redesign: hairline-divided section in place of the old
        // filled/rounded SettingsCard container (mirrors AdvancedPane.swift).
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.languageCode(language) == "vi" ? "Tài khoản Claude" : "Claude accounts")
                .plexEyebrow(color: SettingsTheme.secondary)

            ForEach(Array(claudeAccounts.accounts.enumerated()), id: \.element.id) { idx, acc in
                HStack(spacing: 8) {
                    Image(systemName: idx == claudeAccounts.clampedActiveIndex()
                          ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(idx == claudeAccounts.clampedActiveIndex()
                                         ? SettingsTheme.accent : SettingsTheme.tertiary)
                        .onTapGesture {
                            switch ClaudeTokenAccountStore.setActive(id: acc.id) {
                            case .success(let persisted):
                                claudeAccounts = persisted
                                claudeAccountError = nil
                                providerFetchIdentityDidChange("claude")
                            case .failure(let error):
                                claudeAccountError = error.localizedDescription
                            }
                        }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(acc.displayName)
                            .font(.plexSans(12, weight: .medium))
                            .foregroundStyle(SettingsTheme.primary)
                        Text(acc.kind == .admin ? "Admin API key" : "Web sessionKey")
                            .font(.plexSans(10))
                            .foregroundStyle(SettingsTheme.tertiary)
                    }
                    Spacer()
                    Button {
                        switch ClaudeTokenAccountStore.remove(id: acc.id) {
                        case .success(let persisted):
                            claudeAccounts = persisted
                            claudeAccountError = nil
                            providerFetchIdentityDidChange("claude")
                        case .failure(let error):
                            claudeAccountError = error.localizedDescription
                        }
                    } label: {
                        Image(systemName: "trash").foregroundStyle(SettingsTheme.critical)
                            .instrumentIconTile(bordered: false)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
                if idx < claudeAccounts.accounts.count - 1 { SettingsRowDivider() }
            }

            // Add-account form — shared 28pt Instrument chrome so select /
            // fields / Add sit on one baseline (no native .roundedBorder).
            HStack(alignment: .center, spacing: 6) {
                InstrumentMenuSelect(
                    options: [
                        (ClaudeTokenAccount.Kind.web, "Web"),
                        (ClaudeTokenAccount.Kind.admin, "Admin"),
                    ],
                    selection: $newAccountKind
                )
                .frame(width: InstrumentMetrics.selectWidthCompact)
                TextField(L10n.languageCode(language) == "vi" ? "Nhãn" : "Label", text: $newAccountLabel)
                    .font(.plexSans(11))
                    .instrumentControlFieldStyle()
                    .frame(width: InstrumentMetrics.selectWidthCompact)
                SecureField(newAccountKind == .admin ? "sk-ant-admin..." : "sessionKey sk-ant-...",
                            text: $newAccountToken)
                    .font(.plexSans(11))
                    .instrumentControlFieldStyle()
                Button(L10n.languageCode(language) == "vi" ? "Thêm" : "Add") {
                    let token = newAccountToken.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !token.isEmpty else { return }
                    switch ClaudeTokenAccountStore.add(ClaudeTokenAccount(
                        label: newAccountLabel, token: token, kind: newAccountKind))
                    {
                    case .success(let persisted):
                        claudeAccounts = persisted
                        claudeAccountError = nil
                        newAccountToken = ""; newAccountLabel = ""
                        providerFetchIdentityDidChange("claude")
                    case .failure(let error):
                        claudeAccountError = error.localizedDescription
                    }
                }
                .buttonStyle(.instrumentInline)
                .pointingHandCursor()
                .disabled(newAccountToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let claudeAccountError {
                Text(claudeAccountError)
                    .font(.plexSans(10))
                    .foregroundStyle(SettingsTheme.critical)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Kilo parity (usage source + organizations)

    func kiloUsageSourceName(_ source: KiloUsageSource) -> String {
        let vi = L10n.languageCode(language) == "vi"
        switch source {
        case .auto: return vi ? "Tự động" : "Auto"
        case .api:  return "API"
        case .cli:  return "CLI"
        }
    }

    func kiloSourceSubtitle(for source: String) -> String {
        let vi = L10n.languageCode(language) == "vi"
        switch source {
        case "api": return vi
            ? "Dùng API key (hoặc biến môi trường KILO_API_KEY)."
            : "Use the API key (or KILO_API_KEY env var)."
        case "cli": return vi
            ? "Đọc phiên đăng nhập CLI ~/.local/share/kilo/auth.json."
            : "Read the CLI session at ~/.local/share/kilo/auth.json."
        default: return vi
            ? "API key trước, fallback sang phiên CLI."
            : "API key first, then the CLI session."
        }
    }

    @ViewBuilder
    func kiloUsageSourcePicker() -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text(L10n.t("provider.dataSource", language))
                    .font(.plexSans(13, weight: .semibold))
                    .foregroundStyle(SettingsTheme.primary)
                Spacer(minLength: 8)
                InstrumentMenuSelect(
                    options: KiloUsageSource.allCases.map {
                        ($0.rawValue, kiloUsageSourceName($0))
                    },
                    selection: Binding(
                        get: { settings.kiloUsageDataSource },
                        set: {
                            settings.kiloUsageDataSource = $0
                            providerFetchIdentityDidChange("kilo")
                        }
                    )
                )
                .frame(width: InstrumentMetrics.selectWidth)
            }
            Text(kiloSourceSubtitle(for: settings.kiloUsageDataSource))
                .font(.plexSans(10))
                .foregroundStyle(SettingsTheme.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .hairlineTop()
    }

    /// Known orgs for the scope picker. Always folds in the currently-selected
    /// org (from persisted id+name) so the selection renders before a refresh.
    var kiloScopeOrgs: [KiloOrganization] {
        var orgs = kiloKnownOrgs
        let id = settings.kiloOrgID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !id.isEmpty, !orgs.contains(where: { $0.id == id }) {
            let name = settings.kiloOrgName.isEmpty ? id : settings.kiloOrgName
            orgs.insert(KiloOrganization(id: id, name: name), at: 0)
        }
        return orgs
    }

    @ViewBuilder
    func kiloOrganizationsSection() -> some View {
        let vi = L10n.languageCode(language) == "vi"
        // Instrument redesign: hairline-divided section in place of the old
        // filled/rounded SettingsCard container.
        VStack(alignment: .leading, spacing: 0) {
            Text(vi ? "Tổ chức" : "Organizations")
                .plexEyebrow(color: SettingsTheme.secondary)
                .padding(.bottom, 4)

            // Scope picker: Personal + known orgs.
            HStack(spacing: 12) {
                Text(vi ? "Phạm vi" : "Scope")
                    .font(.plexSans(13, weight: .semibold))
                    .foregroundStyle(SettingsTheme.primary)
                Spacer(minLength: 8)
                InstrumentMenuSelect(
                    options: {
                        var opts: [(String, String)] = [("", vi ? "Cá nhân" : "Personal")]
                        opts.append(contentsOf: kiloScopeOrgs.map { ($0.id, $0.name) })
                        return opts
                    }(),
                    selection: Binding(
                        get: { settings.kiloOrgID },
                        set: { newID in
                            settings.kiloOrgID = newID
                            settings.kiloOrgName = kiloKnownOrgs.first(where: { $0.id == newID })?.name ?? ""
                            providerFetchIdentityDidChange("kilo")
                        }
                    )
                )
                .frame(width: 180)
            }
            .padding(.vertical, 10)
            .hairlineTop()

            VStack(alignment: .leading, spacing: 6) {
                if let err = kiloOrgError {
                    Text(L10n.providerText(err, preference: language))
                        .font(.plexSans(11))
                        .foregroundStyle(SettingsTheme.critical)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    kiloRefreshOrganizations()
                } label: {
                    HStack(spacing: 4) {
                        if kiloOrgRefreshing { ProgressView().controlSize(.small) }
                        Text(vi ? "Tải lại tổ chức" : "Refresh organizations")
                    }
                }
                .buttonStyle(.instrumentInline)
                .pointingHandCursor()
                .disabled(kiloOrgRefreshing)
                Text(vi
                     ? "Lấy danh sách tổ chức của tài khoản; chọn để xem hạn mức theo tổ chức."
                     : "Fetch the account's organizations; pick one to scope quota to it.")
                    .font(.plexSans(10))
                    .foregroundStyle(SettingsTheme.tertiary)
            }
            .padding(.vertical, 10)
            .hairlineTop()
        }
        .padding(.horizontal, 14)
    }

    func kiloRefreshOrganizations() {
        kiloOrgError = nil
        let vi = L10n.languageCode(language) == "vi"
        guard let resolved = KiloProvider.resolveToken(source: KiloUsageSource.current) else {
            kiloOrgError = vi
                ? "Chưa có token Kilo (nhập API key hoặc đăng nhập CLI)."
                : "No Kilo token (enter an API key or sign in via CLI)."
            return
        }
        kiloOrgRefreshing = true
        Task {
            do {
                let orgs = try await KiloOrganization.fetchOrganizations(token: resolved.token)
                await MainActor.run {
                    kiloKnownOrgs = orgs
                    if orgs.isEmpty {
                        kiloOrgError = vi
                            ? "Tài khoản không thuộc tổ chức nào."
                            : "Account has no organizations."
                    }
                    kiloOrgRefreshing = false
                }
            } catch {
                await MainActor.run {
                    kiloOrgError = error.localizedDescription
                    kiloOrgRefreshing = false
                }
            }
        }
    }

    // MARK: - Antigravity settings

    /// Usage source picker for Antigravity — mirrors CodexBar's source picker.
    @ViewBuilder
    func antigravityUsageSourcePicker() -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text(L10n.t("provider.dataSource", language))
                    .font(.plexSans(13, weight: .semibold))
                    .foregroundStyle(SettingsTheme.primary)
                Spacer(minLength: 8)
                InstrumentMenuSelect(
                    options: AntigravityUsageSource.allCases.map {
                        ($0.rawValue, antigravityUsageSourceName($0))
                    },
                    selection: Binding(
                        get: { settings.antigravityUsageSource },
                        set: {
                            settings.antigravityUsageSource = $0
                            providerFetchIdentityDidChange("antigravity")
                        }
                    )
                )
                .frame(width: InstrumentMetrics.selectWidth)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .hairlineTop()
    }

    func antigravityUsageSourceName(_ source: AntigravityUsageSource) -> String {
        switch source {
        case .auto: return L10n.languageCode(language) == "vi" ? "Tự động" : "Auto"
        case .app:  return L10n.languageCode(language) == "vi" ? "Ứng dụng Antigravity" : "Antigravity App"
        case .ide:  return "IDE"
        case .cli:  return "agy CLI"
        case .oauth: return "Google OAuth"
        }
    }

    /// Google OAuth accounts card for Antigravity.
    @ViewBuilder
    func antigravityOAuthAccountsSection() -> some View {
        let vi = L10n.languageCode(language) == "vi"
        // Instrument redesign: hairline-divided section in place of the old
        // filled/rounded SettingsCard container.
        VStack(alignment: .leading, spacing: 0) {
            Text(vi ? "Tài khoản Google" : "Google Accounts")
                .plexEyebrow(color: SettingsTheme.secondary)
                .padding(.bottom, 4)

            // Account list
            if antigravityStore.accounts.isEmpty {
                Text(vi ? "Chưa có tài khoản nào." : "No accounts.")
                    .font(.plexSans(12))
                    .foregroundStyle(SettingsTheme.tertiary)
                    .padding(.vertical, 10)
            } else {
                ForEach(Array(antigravityStore.accounts.enumerated()), id: \.element.label) { idx, acc in
                    let isActive = antigravityStore.activeLabel == acc.label
                        || (antigravityStore.activeLabel == nil && idx == 0)
                    if idx > 0 { SettingsRowDivider() }
                    HStack(spacing: 8) {
                        Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(isActive ? SettingsTheme.accent : SettingsTheme.tertiary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(acc.label)
                                .font(.plexSans(12, weight: .medium))
                                .foregroundStyle(SettingsTheme.primary)
                            if let email = acc.email {
                                Text(email)
                                    .font(.plexSans(10))
                                    .foregroundStyle(SettingsTheme.tertiary)
                            }
                        }
                        Spacer()
                        agySettingsAffordance(for: acc)
                        if !isActive {
                            Button(vi ? "Đặt mặc định" : "Set default") {
                                do {
                                    guard try AntigravityOAuthStore.persistActiveLabel(acc.label) else {
                                        antigravityLoginError = vi
                                            ? "Tài khoản không còn tồn tại."
                                            : "The account no longer exists."
                                        return
                                    }
                                    antigravityStore = AntigravityOAuthStore.load()
                                    antigravityLoginError = nil
                                    providerFetchIdentityDidChange("antigravity")
                                } catch {
                                    antigravityLoginError = error.localizedDescription
                                }
                            }
                            .buttonStyle(.plain)
                            .pointingHandCursor()
                            .font(.plexSans(11))
                            .foregroundStyle(SettingsTheme.accent)
                        }
                        Button {
                            do {
                                antigravityStore = try AntigravityOAuthStore.persistRemovingAccount(acc.label)
                                antigravityLoginError = nil
                                providerFetchIdentityDidChange("antigravity")
                            } catch {
                                antigravityLoginError = error.localizedDescription
                            }
                        } label: {
                            Image(systemName: "trash").foregroundStyle(SettingsTheme.critical)
                            .instrumentIconTile(bordered: false)
                        }
                        .accessibilityLabel(vi ? "Xoá \(acc.label)" : "Remove \(acc.label)")
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                    }
                    .padding(.vertical, 8)
                    if agyLoginTargetLabel == acc.label {
                        agySettingsLoginPanel(for: acc)
                            .padding(.bottom, 8)
                    }
                }
            }

            // Keep the common path obvious; credential import remains available
            // behind progressive disclosure for recovery and headless setups.
            VStack(alignment: .leading, spacing: 8) {
                if let err = antigravityLoginError {
                    Text(L10n.providerText(err, preference: language))
                        .font(.plexSans(11))
                        .foregroundStyle(SettingsTheme.critical)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    antigravityLoginWithGoogle(vi: vi)
                } label: {
                    HStack(spacing: 6) {
                        if antigravityLoginInProgress {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "plus")
                        }
                        Text(vi ? "Thêm tài khoản" : "Add account")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(InstrumentInlineButtonStyle(prominent: true))
                .pointingHandCursor()
                .disabled(antigravityLoginInProgress)
                .accessibilityHint(vi
                    ? "Mở trình duyệt để đăng nhập Google"
                    : "Opens the browser to sign in with Google")

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        antigravityAdvancedSetupExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: antigravityAdvancedSetupExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                        Text(vi ? "Cài đặt nâng cao" : "Advanced setup")
                            .font(.plexSans(11, weight: .medium))
                        Spacer()
                    }
                    .foregroundStyle(SettingsTheme.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .accessibilityValue(antigravityAdvancedSetupExpanded
                    ? (vi ? "Đã mở" : "Expanded")
                    : (vi ? "Đã đóng" : "Collapsed"))

                if antigravityAdvancedSetupExpanded {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .center, spacing: 6) {
                            TextField(vi ? "Nhãn" : "Label", text: $antigravityNewLabel)
                                .font(.plexSans(11))
                                .instrumentControlFieldStyle()
                                .frame(width: 100)
                            SecureField("OAuth credentials JSON", text: $antigravityNewJSON)
                                .font(.plexSans(11))
                                .instrumentControlFieldStyle()
                            Button(vi ? "Nhập" : "Import") {
                                antigravityAddFromJSON()
                            }
                            .buttonStyle(.instrumentInline)
                            .pointingHandCursor()
                            .disabled(antigravityNewJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        Text(vi
                             ? "Dùng khi đăng nhập Google không khả dụng. Dán JSON gồm client_id, client_secret và refresh_token."
                             : "Use when Google sign-in is unavailable. Paste JSON with client_id, client_secret, and refresh_token.")
                            .font(.plexSans(10))
                            .foregroundStyle(SettingsTheme.tertiary)

                        HStack(spacing: 8) {
                            Button(vi ? "Mở file token" : "Open token file") {
                                NSWorkspace.shared.open(AntigravityOAuthStore.fileURL)
                            }
                            .buttonStyle(.instrumentInline)
                            .pointingHandCursor()

                            Button(vi ? "Tải lại" : "Reload") {
                                antigravityReloadTick += 1
                            }
                            .buttonStyle(.instrumentInline)
                            .pointingHandCursor()
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.vertical, 10)
            .hairlineTop()
        }
        .padding(.horizontal, 14)
        .onChange(of: agyLogin.state) { _, newValue in
            // Login agy cô lập xong: reload store + refetch để hàng account
            // chuyển sang "agy đã kết nối" và quota cập nhật ngay.
            guard newValue == .success, let target = agyLoginTargetLabel else { return }
            antigravityStore = AntigravityOAuthStore.load()
            providerFetchIdentityDidChange("antigravity")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if agyLoginTargetLabel == target { agyLoginTargetLabel = nil }
            }
        }
    }

    // MARK: - Isolated agy login (Settings — tương đương popover)

    /// Badge "agy đã kết nối" hoặc nút "Đăng nhập agy" cho từng account, để
    /// seed login cô lập ngay trong Settings.
    @ViewBuilder
    func agySettingsAffordance(for acc: AntigravityOAuthStore.Account) -> some View {
        let vi = L10n.languageCode(language) == "vi"
        if agyLoginTargetLabel == acc.label {
            EmptyView()
        } else if AntigravityIsolatedAgy.hasLogin(forAccountLabel: acc.label) {
            Text(vi ? "agy đã kết nối" : "agy connected")
                .font(.plexMono(9, weight: .semibold))
                .foregroundStyle(SettingsTheme.success)
        } else {
            Button(vi ? "Đăng nhập agy" : "Sign in to agy") {
                startAgyLoginSettings(acc.label)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .font(.plexSans(11, weight: .medium))
            .foregroundStyle(SettingsTheme.accent)
        }
    }

    /// Panel trạng thái đăng nhập agy (mở trình duyệt → thành công/thất bại).
    @ViewBuilder
    func agySettingsLoginPanel(for acc: AntigravityOAuthStore.Account) -> some View {
        let vi = L10n.languageCode(language) == "vi"
        HStack(spacing: 6) {
            switch agyLogin.state {
            case .idle, .launching:
                ProgressView().controlSize(.small)
                Text(L10n.t("antigravity.login.launching", language))
                    .font(.plexSans(11))
                    .foregroundStyle(SettingsTheme.secondary)
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(SettingsTheme.success)
                Text(vi ? "Đã kết nối agy" : "agy connected")
                    .font(.plexSans(11, weight: .medium))
                    .foregroundStyle(SettingsTheme.success)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(SettingsTheme.critical)
                Text(L10n.providerText(message, preference: language))
                    .font(.plexSans(10))
                    .foregroundStyle(SettingsTheme.critical)
                    .fixedSize(horizontal: false, vertical: true)
                Button(vi ? "Thử lại" : "Retry") { startAgyLoginSettings(acc.label) }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .font(.plexSans(11, weight: .medium))
                    .foregroundStyle(SettingsTheme.accent)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(SettingsTheme.selectedSurface)
        )
    }

    func startAgyLoginSettings(_ label: String) {
        agyLoginTargetLabel = label
        agyLogin.start(accountLabel: label)
    }

    func antigravityLoginWithGoogle(vi: Bool) {
        antigravityLoginError = nil
        let store = antigravityStore
        guard let clientID = AntigravityOAuthStore.resolvedClientID(store: store),
              let clientSecret = AntigravityOAuthStore.resolvedClientSecret(store: store) else {
            antigravityLoginError = vi
                ? "Không thể mở đăng nhập Google. Hãy cài Antigravity.app hoặc dùng Cài đặt nâng cao."
                : "Google sign-in is unavailable. Install Antigravity.app or use Advanced setup."
            antigravityAdvancedSetupExpanded = true
            return
        }
        antigravityLoginInProgress = true
        Task {
            do {
                let (refreshToken, email) = try await AntigravityOAuthLogin.login(
                    clientID: clientID, clientSecret: clientSecret)
                antigravityStore = try AntigravityOAuthStore.persistNewLoginAccount(
                    fallbackLabel: vi ? "Tài khoản" : "Account",
                    refreshToken: refreshToken,
                    email: email,
                    makeActive: true)
                providerFetchIdentityDidChange("antigravity")
            } catch {
                antigravityLoginError = error.localizedDescription
            }
            antigravityLoginInProgress = false
        }
    }

    // MARK: - Copilot accounts

    /// GitHub accounts card for Copilot — Device Flow (mirrors antigravityOAuthAccountsSection).
    @ViewBuilder
    func copilotOAuthAccountsSection(idx: Int) -> some View {
        let vi = L10n.languageCode(language) == "vi"
        let enterpriseHost: String = {
            guard rows.indices.contains(idx) else { return "github.com" }
            let raw = rows[idx].baseURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return raw.isEmpty ? "github.com" : raw
        }()

        // Instrument redesign: hairline-divided section in place of the old
        // filled/rounded SettingsCard container.
        VStack(alignment: .leading, spacing: 0) {
            Text(vi ? "Tài khoản GitHub" : "GitHub Accounts")
                .plexEyebrow(color: SettingsTheme.secondary)
                .padding(.bottom, 4)

            // Account list
            if copilotStore.accounts.isEmpty {
                Text(vi ? "Chưa có tài khoản nào." : "No accounts.")
                    .font(.plexSans(12))
                    .foregroundStyle(SettingsTheme.tertiary)
                    .padding(.vertical, 10)
            } else {
                ForEach(Array(copilotStore.accounts.enumerated()), id: \.element.label) { i, acc in
                    let isActive = copilotStore.activeLabel == acc.label
                        || (copilotStore.activeLabel == nil && i == 0)
                    if i > 0 { SettingsRowDivider() }
                    HStack(spacing: 8) {
                        Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(isActive ? SettingsTheme.accent : SettingsTheme.tertiary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(acc.login ?? acc.label)
                                .font(.plexSans(12, weight: .medium))
                                .foregroundStyle(SettingsTheme.primary)
                            if isActive {
                                Text(vi ? "Đang dùng" : "Active")
                                    .font(.plexMono(10, weight: .semibold))
                                    .textCase(.uppercase)
                                    .foregroundStyle(SettingsTheme.accent)
                            }
                        }
                        Spacer()
                        if !isActive {
                            Button(vi ? "Đặt mặc định" : "Set default") {
                                var s = copilotStore
                                CopilotAccountStore.setActive(in: &s, label: acc.label)
                                do {
                                    try CopilotAccountStore.save(s)
                                    copilotStore = s
                                    copilotLoginError = nil
                                    NotificationCenter.default.post(
                                        name: .birdnionRefresh, object: "copilot")
                                } catch {
                                    copilotLoginError = error.localizedDescription
                                }
                            }
                            .buttonStyle(.plain)
                            .pointingHandCursor()
                            .font(.plexSans(11))
                            .foregroundStyle(SettingsTheme.accent)
                        }
                        Button {
                            var s = copilotStore
                            CopilotAccountStore.removeAccount(from: &s, label: acc.label)
                            do {
                                try CopilotAccountStore.save(s)
                                copilotStore = s
                                copilotLoginError = nil
                                NotificationCenter.default.post(
                                    name: .birdnionRefresh, object: "copilot")
                            } catch {
                                copilotLoginError = error.localizedDescription
                            }
                        } label: {
                            Image(systemName: "trash").foregroundStyle(SettingsTheme.critical)
                            .instrumentIconTile(bordered: false)
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                    }
                    .padding(.vertical, 8)
                }
            }

            // Device user code display — shown while waiting for user to enter on GitHub
            if let userCode = copilotDeviceUserCode {
                VStack(alignment: .leading, spacing: 4) {
                    Text(vi
                         ? "Nhập mã XXXX-XXXX sau tại github.com/login/device:"
                         : "Enter code at github.com/login/device:")
                        .font(.plexSans(11))
                        .foregroundStyle(SettingsTheme.secondary)
                    Text(userCode)
                        .font(.plexMono(20, weight: .bold))
                        .foregroundStyle(SettingsTheme.accent)
                        .padding(.vertical, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                .hairlineTop()
            }

            // Error display
            if let err = copilotLoginError {
                Text(L10n.providerText(err, preference: language))
                    .font(.plexSans(11))
                    .foregroundStyle(SettingsTheme.critical)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
                    .hairlineTop()
            }

            // Action buttons
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        copilotLoginError = nil
                        copilotLoginInProgress = true
                        copilotDeviceUserCode = nil
                        copilotLoginTask?.cancel()
                        copilotLoginTask = Task {
                            do {
                                let dc = try await CopilotDeviceFlow.start(host: enterpriseHost)
                                await MainActor.run {
                                    copilotDeviceUserCode = dc.userCode
                                    if let uri = URL(string: dc.verificationURI) {
                                        NSWorkspace.shared.open(uri)
                                    }
                                }
                                let res = try await CopilotDeviceFlow.poll(
                                    host: enterpriseHost,
                                    deviceCode: dc.deviceCode,
                                    interval: dc.interval
                                )
                                await MainActor.run {
                                    let loginLabel = res.login ?? "GitHub"
                                    var s = CopilotAccountStore.load()
                                    CopilotAccountStore.addAccount(
                                        to: &s, label: loginLabel, token: res.token, login: res.login)
                                    CopilotAccountStore.setActive(in: &s, label: loginLabel)
                                    do {
                                        try CopilotAccountStore.save(s)
                                        copilotStore = s
                                        copilotDeviceUserCode = nil
                                        copilotLoginInProgress = false
                                        NotificationCenter.default.post(
                                            name: .birdnionRefresh, object: "copilot")
                                    } catch {
                                        copilotDeviceUserCode = nil
                                        copilotLoginError = error.localizedDescription
                                        copilotLoginInProgress = false
                                    }
                                }
                            } catch is CancellationError {
                                await MainActor.run {
                                    copilotDeviceUserCode = nil
                                    copilotLoginInProgress = false
                                }
                            } catch {
                                await MainActor.run {
                                    copilotDeviceUserCode = nil
                                    copilotLoginError = error.localizedDescription
                                    copilotLoginInProgress = false
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if copilotLoginInProgress {
                                ProgressView().controlSize(.small)
                            }
                            Text(vi ? "Đăng nhập GitHub (Add Account)" : "Login with GitHub (Add Account)")
                        }
                    }
                    .buttonStyle(.instrumentInline)
                    .pointingHandCursor()
                    .disabled(copilotLoginInProgress)
                }
                HStack(spacing: 8) {
                    Button(vi ? "Mở file token" : "Open token file") {
                        NSWorkspace.shared.open(CopilotAccountStore.fileURL)
                    }
                    .buttonStyle(.instrumentInline)
                    .pointingHandCursor()

                    Button(vi ? "Tải lại" : "Reload") {
                        copilotReloadTick += 1
                    }
                    .buttonStyle(.instrumentInline)
                    .pointingHandCursor()
                }
            }
            .padding(.vertical, 10)
            .hairlineTop()
        }
        .padding(.horizontal, 14)
    }

    /// Parse best-effort OAuth credentials JSON and update the store.
    func antigravityAddFromJSON() {
        let vi = L10n.languageCode(language) == "vi"
        let raw = antigravityNewJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            antigravityLoginError = vi
                ? "OAuth credentials JSON không hợp lệ."
                : "Invalid OAuth credentials JSON."
            return
        }

        let clientId = obj["client_id"]
        let clientSecret = obj["client_secret"]
        let refreshToken = obj["refresh_token"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let accountLabel: String?
        if let refreshToken, !refreshToken.isEmpty {
            let trimmedLabel = antigravityNewLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            let importedEmail = obj["email"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            accountLabel = trimmedLabel.isEmpty
                ? (importedEmail?.isEmpty == false ? importedEmail : nil) ?? (vi ? "Tài khoản" : "Account")
                : trimmedLabel
        } else {
            accountLabel = nil
        }
        do {
            if let refreshToken, !refreshToken.isEmpty, let accountLabel {
                antigravityStore = try AntigravityOAuthStore.persistAccount(
                    label: accountLabel,
                    refreshToken: refreshToken,
                    email: obj["email"],
                    clientId: clientId,
                    clientSecret: clientSecret)
            } else {
                antigravityStore = try AntigravityOAuthStore.persistClientCredentials(
                    clientId: clientId,
                    clientSecret: clientSecret)
            }
            antigravityNewLabel = ""
            antigravityNewJSON = ""
            antigravityLoginError = nil
            providerFetchIdentityDidChange("antigravity")
        } catch {
            antigravityLoginError = error.localizedDescription
        }
    }
}
