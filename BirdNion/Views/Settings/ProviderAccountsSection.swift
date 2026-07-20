import SwiftUI

// MARK: - Provider multi-account sections (P4 module split)

extension ProvidersPane {
    // MARK: - Claude accounts (multi-account)

    /// Account switcher: lists stored Claude accounts (web sessionKey / Admin
    /// API key), lets the user pick the active one, delete, or add a new one.
    /// OAuth stays single-account (system Keychain); this governs web/admin.
    @ViewBuilder
    func claudeAccountsSection() -> some View {
        SettingsRowDivider()
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.languageCode(language) == "vi" ? "Tài khoản Claude" : "Claude accounts")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SettingsTheme.primary)

            ForEach(Array(claudeAccounts.accounts.enumerated()), id: \.element.id) { idx, acc in
                HStack(spacing: 8) {
                    Image(systemName: idx == claudeAccounts.clampedActiveIndex()
                          ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(idx == claudeAccounts.clampedActiveIndex()
                                         ? SettingsTheme.accent : SettingsTheme.tertiary)
                        .onTapGesture {
                            claudeAccounts = ClaudeTokenAccountStore.setActive(id: acc.id)
                            Task { await quota.refresh() }
                        }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(acc.displayName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(SettingsTheme.primary)
                        Text(acc.kind == .admin ? "Admin API key" : "Web sessionKey")
                            .font(.system(size: 10))
                            .foregroundStyle(SettingsTheme.tertiary)
                    }
                    Spacer()
                    Button {
                        claudeAccounts = ClaudeTokenAccountStore.remove(id: acc.id)
                        Task { await quota.refresh() }
                    } label: {
                        Image(systemName: "trash").foregroundStyle(SettingsTheme.tertiary)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
            }

            // Add-account form.
            HStack(spacing: 6) {
                Picker("", selection: $newAccountKind) {
                    Text("Web").tag(ClaudeTokenAccount.Kind.web)
                    Text("Admin").tag(ClaudeTokenAccount.Kind.admin)
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 90)
                TextField(L10n.languageCode(language) == "vi" ? "Nhãn" : "Label", text: $newAccountLabel)
                    .textFieldStyle(.roundedBorder).font(.system(size: 11)).frame(width: 90)
                SecureField(newAccountKind == .admin ? "sk-ant-admin..." : "sessionKey sk-ant-...",
                            text: $newAccountToken)
                    .textFieldStyle(.roundedBorder).font(.system(size: 11))
                Button(L10n.languageCode(language) == "vi" ? "Thêm" : "Add") {
                    let token = newAccountToken.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !token.isEmpty else { return }
                    claudeAccounts = ClaudeTokenAccountStore.add(ClaudeTokenAccount(
                        label: newAccountLabel, token: token, kind: newAccountKind))
                    newAccountToken = ""; newAccountLabel = ""
                    Task { await quota.refresh() }
                }
                .disabled(newAccountToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
        SettingsRowDivider()
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text(L10n.t("provider.dataSource", language))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SettingsTheme.primary)
                Spacer(minLength: 8)
                Picker("", selection: Binding(
                    get: { settings.kiloUsageDataSource },
                    set: { settings.kiloUsageDataSource = $0; Task { await quota.refresh() } }
                )) {
                    ForEach(KiloUsageSource.allCases) { src in
                        Text(kiloUsageSourceName(src)).tag(src.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 170)
            }
            Text(kiloSourceSubtitle(for: settings.kiloUsageDataSource))
                .font(.system(size: 10))
                .foregroundStyle(SettingsTheme.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
        SettingsCard(header: vi ? "Tổ chức" : "Organizations") {
            // Scope picker: Personal + known orgs.
            HStack(spacing: 12) {
                Text(vi ? "Phạm vi" : "Scope")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SettingsTheme.primary)
                Spacer(minLength: 8)
                Picker("", selection: Binding(
                    get: { settings.kiloOrgID },
                    set: { newID in
                        settings.kiloOrgID = newID
                        settings.kiloOrgName = kiloKnownOrgs.first(where: { $0.id == newID })?.name ?? ""
                        Task { await quota.refresh() }
                    }
                )) {
                    Text(vi ? "Cá nhân" : "Personal").tag("")
                    ForEach(kiloScopeOrgs) { org in
                        Text(org.name).tag(org.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 180)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            SettingsRowDivider()

            VStack(alignment: .leading, spacing: 6) {
                if let err = kiloOrgError {
                    Text(L10n.providerText(err, preference: language))
                        .font(.system(size: 11))
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
                .disabled(kiloOrgRefreshing)
                Text(vi
                     ? "Lấy danh sách tổ chức của tài khoản; chọn để xem hạn mức theo tổ chức."
                     : "Fetch the account's organizations; pick one to scope quota to it.")
                    .font(.system(size: 10))
                    .foregroundStyle(SettingsTheme.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
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
        SettingsRowDivider()
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text(L10n.t("provider.dataSource", language))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SettingsTheme.primary)
                Spacer(minLength: 8)
                Picker("", selection: Binding(
                    get: { settings.antigravityUsageSource },
                    set: { settings.antigravityUsageSource = $0; Task { await quota.refresh() } }
                )) {
                    ForEach(AntigravityUsageSource.allCases) { src in
                        Text(antigravityUsageSourceName(src)).tag(src.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 180)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
        SettingsCard(header: vi ? "Tài khoản Google" : "Google Accounts") {
            // Account list
            if antigravityStore.accounts.isEmpty {
                Text(vi ? "Chưa có tài khoản nào." : "No accounts.")
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsTheme.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            } else {
                ForEach(Array(antigravityStore.accounts.enumerated()), id: \.element.label) { idx, acc in
                    let isActive = antigravityStore.activeLabel == acc.label
                        || (antigravityStore.activeLabel == nil && idx == 0)
                    HStack(spacing: 8) {
                        Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(isActive ? SettingsTheme.accent : SettingsTheme.tertiary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(acc.label)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(SettingsTheme.primary)
                            if let email = acc.email {
                                Text(email)
                                    .font(.system(size: 10))
                                    .foregroundStyle(SettingsTheme.tertiary)
                            }
                        }
                        Spacer()
                        if !isActive {
                            Button(vi ? "Đặt mặc định" : "Set default") {
                                var s = antigravityStore
                                AntigravityOAuthStore.setActive(in: &s, label: acc.label)
                                try? AntigravityOAuthStore.save(s)
                                antigravityStore = s
                                Task { await quota.refresh() }
                            }
                            .buttonStyle(.plain)
                            .pointingHandCursor()
                            .font(.system(size: 11))
                            .foregroundStyle(SettingsTheme.accent)
                        }
                        Button {
                            var s = antigravityStore
                            AntigravityOAuthStore.removeAccount(from: &s, label: acc.label)
                            try? AntigravityOAuthStore.save(s)
                            antigravityStore = s
                            Task { await quota.refresh() }
                        } label: {
                            Image(systemName: "trash").foregroundStyle(SettingsTheme.tertiary)
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    if idx < antigravityStore.accounts.count - 1 { SettingsRowDivider() }
                }
            }

            SettingsRowDivider()

            // Add account via JSON paste
            VStack(alignment: .leading, spacing: 6) {
                Text(vi ? "Thêm tài khoản" : "Add account")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SettingsTheme.primary)
                HStack(spacing: 6) {
                    TextField(vi ? "Nhãn" : "Label", text: $antigravityNewLabel)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .frame(width: 100)
                    SecureField(vi ? "OAuth credentials JSON" : "OAuth credentials JSON", text: $antigravityNewJSON)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                    Button(vi ? "Thêm" : "Add") {
                        antigravityAddFromJSON()
                    }
                    .disabled(antigravityNewJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text(vi
                     ? "Dán JSON: {\"client_id\":\"…\",\"client_secret\":\"…\",\"refresh_token\":\"…\"}"
                     : "Paste JSON: {\"client_id\":\"…\",\"client_secret\":\"…\",\"refresh_token\":\"…\"}")
                    .font(.system(size: 10))
                    .foregroundStyle(SettingsTheme.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            SettingsRowDivider()

            // Login with Google + utility buttons
            VStack(alignment: .leading, spacing: 8) {
                if let err = antigravityLoginError {
                    Text(L10n.providerText(err, preference: language))
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsTheme.critical)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button {
                        antigravityLoginError = nil
                        let s = antigravityStore
                        guard let clientID = AntigravityOAuthStore.resolvedClientID(store: s),
                              let clientSecret = AntigravityOAuthStore.resolvedClientSecret(store: s) else {
                            antigravityLoginError = vi
                                ? "Cần đặt ANTIGRAVITY_OAUTH_CLIENT_ID/SECRET hoặc dán credentials JSON trước."
                                : "Set ANTIGRAVITY_OAUTH_CLIENT_ID/SECRET or paste credentials JSON first."
                            return
                        }
                        antigravityLoginInProgress = true
                        Task {
                            do {
                                let (refreshToken, email) = try await AntigravityOAuthLogin.login(
                                    clientID: clientID, clientSecret: clientSecret)
                                var store = AntigravityOAuthStore.load()
                                let label = email ?? (vi ? "Tài khoản" : "Account")
                                AntigravityOAuthStore.addAccount(to: &store, label: label,
                                                                  refreshToken: refreshToken, email: email)
                                try? AntigravityOAuthStore.save(store)
                                antigravityStore = store
                                await quota.refresh()
                            } catch {
                                antigravityLoginError = error.localizedDescription
                            }
                            antigravityLoginInProgress = false
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if antigravityLoginInProgress {
                                ProgressView().controlSize(.small)
                            }
                            Text(vi ? "Đăng nhập Google" : "Login with Google")
                        }
                    }
                    .disabled(antigravityLoginInProgress)

                    Button(vi ? "Mở file token" : "Open token file") {
                        NSWorkspace.shared.open(AntigravityOAuthStore.fileURL)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsTheme.accent)

                    Button(vi ? "Tải lại" : "Reload") {
                        antigravityReloadTick += 1
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsTheme.accent)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
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

        SettingsCard(header: vi ? "Tài khoản GitHub" : "GitHub Accounts") {
            // Account list
            if copilotStore.accounts.isEmpty {
                Text(vi ? "Chưa có tài khoản nào." : "No accounts.")
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsTheme.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            } else {
                ForEach(Array(copilotStore.accounts.enumerated()), id: \.element.label) { i, acc in
                    let isActive = copilotStore.activeLabel == acc.label
                        || (copilotStore.activeLabel == nil && i == 0)
                    HStack(spacing: 8) {
                        Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(isActive ? SettingsTheme.accent : SettingsTheme.tertiary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(acc.login ?? acc.label)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(SettingsTheme.primary)
                            if isActive {
                                Text(vi ? "Đang dùng" : "Active")
                                    .font(.system(size: 10))
                                    .foregroundStyle(SettingsTheme.accent)
                            }
                        }
                        Spacer()
                        if !isActive {
                            Button(vi ? "Đặt mặc định" : "Set default") {
                                var s = copilotStore
                                CopilotAccountStore.setActive(in: &s, label: acc.label)
                                try? CopilotAccountStore.save(s)
                                copilotStore = s
                                NotificationCenter.default.post(name: .birdnionRefresh, object: nil)
                            }
                            .buttonStyle(.plain)
                            .pointingHandCursor()
                            .font(.system(size: 11))
                            .foregroundStyle(SettingsTheme.accent)
                        }
                        Button {
                            var s = copilotStore
                            CopilotAccountStore.removeAccount(from: &s, label: acc.label)
                            try? CopilotAccountStore.save(s)
                            copilotStore = s
                            NotificationCenter.default.post(name: .birdnionRefresh, object: nil)
                        } label: {
                            Image(systemName: "trash").foregroundStyle(SettingsTheme.tertiary)
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    if i < copilotStore.accounts.count - 1 { SettingsRowDivider() }
                }
            }

            SettingsRowDivider()

            // Device user code display — shown while waiting for user to enter on GitHub
            if let userCode = copilotDeviceUserCode {
                VStack(alignment: .leading, spacing: 4) {
                    Text(vi
                         ? "Nhập mã XXXX-XXXX sau tại github.com/login/device:"
                         : "Enter code at github.com/login/device:")
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsTheme.secondary)
                    Text(userCode)
                        .font(.system(size: 20, weight: .bold).monospacedDigit())
                        .foregroundStyle(SettingsTheme.accent)
                        .padding(.vertical, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                SettingsRowDivider()
            }

            // Error display
            if let err = copilotLoginError {
                Text(L10n.providerText(err, preference: language))
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsTheme.critical)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                SettingsRowDivider()
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
                                    try? CopilotAccountStore.save(s)
                                    copilotStore = s
                                    copilotDeviceUserCode = nil
                                    copilotLoginInProgress = false
                                    NotificationCenter.default.post(name: .birdnionRefresh, object: nil)
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
                    .disabled(copilotLoginInProgress)
                }
                HStack(spacing: 8) {
                    Button(vi ? "Mở file token" : "Open token file") {
                        NSWorkspace.shared.open(CopilotAccountStore.fileURL)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsTheme.accent)

                    Button(vi ? "Tải lại" : "Reload") {
                        copilotReloadTick += 1
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsTheme.accent)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    /// Parse best-effort OAuth credentials JSON and update the store.
    func antigravityAddFromJSON() {
        let raw = antigravityNewJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }

        var s = antigravityStore
        // Update client credentials if present
        if let cid = obj["client_id"], !cid.isEmpty { s.clientId = cid }
        if let cs = obj["client_secret"], !cs.isEmpty { s.clientSecret = cs }
        // Add account if refresh_token present
        if let rt = obj["refresh_token"], !rt.isEmpty {
            let trimmedLabel = antigravityNewLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = trimmedLabel.isEmpty
                ? (obj["email"] ?? (L10n.languageCode(language) == "vi" ? "Tài khoản" : "Account"))
                : trimmedLabel
            AntigravityOAuthStore.addAccount(to: &s, label: label, refreshToken: rt, email: obj["email"])
        }
        try? AntigravityOAuthStore.save(s)
        antigravityStore = s
        antigravityNewLabel = ""
        antigravityNewJSON = ""
        Task { await quota.refresh() }
    }
}
