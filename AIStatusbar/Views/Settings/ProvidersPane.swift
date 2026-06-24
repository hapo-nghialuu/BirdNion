import SwiftUI

/// Providers tab — CodexBar-style two-pane layout: a sidebar listing every
/// provider (logo + name + status + enable toggle) on the left, and a detail
/// panel for the selected provider on the right.
///
/// Reuses the existing model layer: ProvidersStore (providers.json),
/// QuotaService (live status), KeychainService (tokens), and the bundled brand
/// logos. Codex is zero-config (login status from ~/.codex/auth.json); the
/// other providers take a token.
struct ProvidersPane: View {
    @EnvironmentObject var keychain: KeychainService
    @EnvironmentObject var quota: QuotaService
    @EnvironmentObject var settings: SettingsStore

    @State private var rows: [ProviderConfig] = []
    @State private var selectedID: String?
    @State private var showingClaudeConfig = false
    /// Codex token cost (today / 30d), scanned lazily when Codex is selected.
    @State private var codexCost: CodexCostSummary?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            sidebar
            detail
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            if rows.isEmpty { rows = ProvidersStore.load().providers }
            if selectedID == nil { selectedID = rows.first?.id }
        }
        .task(id: selectedID) {
            // Scan local Codex sessions for token cost only while it's selected.
            guard selectedID == "codex" else { codexCost = nil; return }
            codexCost = await CodexCostScanner.summary()
        }
        .sheet(isPresented: $showingClaudeConfig) {
            ConfigPanel()
                .environmentObject(keychain)
                .environmentObject(quota)
                .frame(width: 440, height: 320)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            ForEach(rows, id: \.id) { row in
                sidebarRow(row)
                if row.id != rows.last?.id {
                    Divider().padding(.leading, 44)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .frame(width: 200, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func sidebarRow(_ row: ProviderConfig) -> some View {
        let isSelected = row.id == selectedID
        return HStack(spacing: 10) {
            ProviderLogoView(id: row.id)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(displayName(for: row))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(statusSubtitle(for: row))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            statusDot(for: row)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : .clear)
                .padding(.horizontal, 6)
        )
        .contentShape(Rectangle())
        .onTapGesture { selectedID = row.id }
    }

    @ViewBuilder
    private func statusDot(for row: ProviderConfig) -> some View {
        let color: Color = {
            if !row.enabled { return .secondary.opacity(0.4) }
            guard let s = status(for: row.id) else { return .secondary.opacity(0.4) }
            return s.error == nil ? .green : .orange
        }()
        Circle().fill(color).frame(width: 7, height: 7)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let id = selectedID, let idx = rows.firstIndex(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    detailHeader(idx)
                    detailInfoGrid(rows[idx])
                    usageSection(rows[idx])
                    settingsSection(idx)
                    if rows[idx].id == "codex" {
                        CodexAccountsCard()
                    }
                    QuotaWarningCard(providerID: rows[idx].id)
                        .id(rows[idx].id)
                    linksSection(rows[idx])
                    if rows[idx].id == "claude" || rows[idx].id == "codex" {
                        claudeConfigButton
                    }
                }
                .frame(maxWidth: 440, alignment: .leading)
                .padding(.vertical, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("Chọn một nhà cung cấp")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detailHeader(_ idx: Int) -> some View {
        let row = rows[idx]
        return HStack(alignment: .center, spacing: 12) {
            ProviderLogoView(id: row.id)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName(for: row))
                    .font(.system(size: 16, weight: .semibold))
                Text(headerSubtitle(for: row))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button {
                Task { await quota.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .controlSize(.small)
            .help("Làm mới")

            Toggle("", isOn: enabledBinding(idx))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private func detailInfoGrid(_ row: ProviderConfig) -> some View {
        let s = status(for: row.id)
        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            infoRow("Trạng thái", row.enabled ? "Đang bật" : "Đang tắt")
            if row.id == "codex" {
                // OAuth-only auth (token read from ~/.codex/auth.json).
                infoRow("Nguồn", "OAuth")
            }
            if let plan = s?.planType, !plan.isEmpty {
                infoRow("Gói", plan.capitalized)
            }
            if let label = s?.accountLabel, !label.isEmpty {
                infoRow("Tài khoản", label)
            }
            if let version = s?.version, !version.isEmpty {
                infoRow("Phiên bản", version)
            }
            if let svc = s?.serviceStatus, !svc.isEmpty {
                serviceStatusRow(svc, level: s?.serviceStatusLevel)
            }
            if let err = s?.error {
                infoRow("Lỗi", err)
            } else {
                infoRow("Cập nhật", updatedSubtitle(for: row.id))
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).gridColumnAlignment(.leading)
            Text(value)
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
    }

    /// Service-status row with a severity dot (green/yellow/orange/red).
    private func serviceStatusRow(_ text: String, level: String?) -> some View {
        GridRow {
            Text("Tình trạng").gridColumnAlignment(.leading)
            HStack(spacing: 6) {
                Circle()
                    .fill(serviceStatusColor(level))
                    .frame(width: 7, height: 7)
                Text(text)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }
        }
    }

    private func serviceStatusColor(_ level: String?) -> Color {
        switch level {
        case "none": return .green
        case "minor": return .yellow
        case "major": return .orange
        case "critical": return .red
        default: return .secondary
        }
    }

    @ViewBuilder
    private func usageSection(_ row: ProviderConfig) -> some View {
        let s = status(for: row.id)
        SettingsCard(header: "Sử dụng") {
            if let s, !s.windows.isEmpty {
                ForEach(Array(s.windows.enumerated()), id: \.element.id) { i, w in
                    quotaWindowRow(w)
                    if i < s.windows.count - 1 { SettingsRowDivider() }
                }
                if let credits = s.creditsRemaining {
                    SettingsRowDivider()
                    creditsRow(credits)
                }
                if row.id == "codex", let cost = codexCost, !cost.isEmpty {
                    SettingsRowDivider()
                    costRows(cost)
                }
            } else {
                Text(row.enabled ? "Chưa có dữ liệu — bấm làm mới." : "Đang tắt — không có dữ liệu.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
        }
    }

    private func quotaWindowRow(_ w: QuotaWindow) -> some View {
        let isWeek = w.label.contains("Tuần")
        let barColor: Color = isWeek ? VocabbyTheme.blue : VocabbyTheme.yellow
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(w.label.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
                Spacer()
                Text("\(w.remainingPct)%")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 8)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(barColor)
                        .frame(width: max(0, geo.size.width * CGFloat(w.remainingPct) / 100), height: 8)
                }
            }
            .frame(height: 8)

            // Pace line: reserve (weekly) on the left, reset countdown on the right.
            let pace = WindowPace(window: w)
            if pace != nil || (w.subtitle?.isEmpty == false) {
                HStack(alignment: .firstTextBaseline) {
                    if isWeek, let r = pace?.reservePct, r > 0 {
                        Text("\(r)% dự phòng")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 6)
                    if let rt = pace?.resetText {
                        Text("Reset sau \(rt)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                if isWeek, let pace {
                    Text(pace.lastsUntilReset ? "Đủ dùng đến khi reset" : "Có thể hết trước khi reset")
                        .font(.system(size: 10))
                        .foregroundStyle(pace.lastsUntilReset ? Color.secondary : Color.orange)
                }
                if let sub = w.subtitle, !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Remaining credit balance line (Codex). Shown only when the provider
    /// reports a credits figure.
    private func creditsRow(_ credits: Double) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("CREDITS")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)
            Spacer()
            Text(creditsText(credits))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func creditsText(_ credits: Double) -> String {
        let amount = credits.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(credits))
            : String(format: "%.2f", credits)
        return credits <= 0 ? "Hết" : "\(amount) còn lại"
    }

    /// Token cost rows (Codex). Dollar amounts are estimates (tokens × price
    /// table), so they're prefixed with "≈"; token counts are exact.
    private func costRows(_ cost: CodexCostSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            costLine("Hôm nay", usd: cost.todayUSD, tokens: cost.todayTokens)
            costLine("30 ngày", usd: cost.last30USD, tokens: cost.last30Tokens)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func costLine(_ label: String, usd: Double, tokens: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)
            Spacer()
            Text("≈$\(String(format: "%.2f", usd)) · \(Self.formatTokens(tokens))")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
        }
    }

    /// Compact token count: 1_234_567 → "1.2M", 12_345 → "12.3K".
    static func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }

    // MARK: - Settings section (token / account label / login status)

    @ViewBuilder
    private func settingsSection(_ idx: Int) -> some View {
        let row = rows[idx]
        SettingsCard(header: "Thiết lập") {
            // Account label (applies to all providers)
            VStack(alignment: .leading, spacing: 4) {
                Text("Nhãn tài khoản")
                    .font(.system(size: 13, weight: .semibold))
                TextField("Tùy chọn — để trống để tự suy ra", text: labelBinding(idx))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            SettingsRowDivider()

            if row.id == "codex" {
                // Zero-config: just show login status.
                VStack(alignment: .leading, spacing: 4) {
                    Text("Đăng nhập")
                        .font(.system(size: 13, weight: .semibold))
                    Text(codexLoginStatus())
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("Đăng nhập bằng lệnh `codex` trong Terminal.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            } else {
                TokenField(
                    providerID: row.id,
                    keychain: keychain,
                    onSaved: { Task { await quota.refresh() } }
                )
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            if row.id == "codex" {
                SettingsRowDivider()
                HStack(spacing: 12) {
                    Text("Menu bar hiển thị")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 8)
                    Picker("", selection: Binding(
                        get: { settings.codexMenuBarMetric },
                        set: {
                            settings.codexMenuBarMetric = $0
                            // Re-fetch so the menu bar rebuilds its frames with
                            // the newly selected window.
                            NotificationCenter.default.post(name: .aistatusbarRefresh, object: nil)
                        }
                    )) {
                        ForEach(CodexMenuBarMetric.allCases) { m in
                            Text(m.displayName).tag(m.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 150)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            if row.id == "minimax" {
                SettingsRowDivider()
                HStack(spacing: 12) {
                    Text("Khu vực API")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 8)
                    Picker("", selection: Binding(
                        get: { settings.minimaxRegion },
                        set: { settings.minimaxRegion = $0; Task { await quota.refresh() } }
                    )) {
                        ForEach(MiniMaxRegion.allCases) { r in
                            Text(r.displayName).tag(r.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 150)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }

    // MARK: - Links / dashboards

    /// External management links for the selected provider. Codex also gets a
    /// status page + changelog; MiniMax's dashboard follows the chosen region.
    @ViewBuilder
    private func linksSection(_ row: ProviderConfig) -> some View {
        let links = dashboardLinks(for: row.id)
        if !links.isEmpty {
            SettingsCard(header: "Liên kết") {
                ForEach(Array(links.enumerated()), id: \.offset) { i, link in
                    Button {
                        NSWorkspace.shared.open(link.url)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: link.icon)
                                .frame(width: 16)
                            Text(link.title)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    if i < links.count - 1 { SettingsRowDivider() }
                }
            }
        }
    }

    private struct DashboardLink { let title: String; let icon: String; let url: URL }

    private func dashboardLinks(for id: String) -> [DashboardLink] {
        func u(_ s: String) -> URL? { URL(string: s) }
        switch id {
        case "codex":
            return [
                u("https://chatgpt.com/codex/settings/usage").map { DashboardLink(title: "Trang sử dụng Codex", icon: "chart.bar", url: $0) },
                u("https://status.openai.com/").map { DashboardLink(title: "Trạng thái OpenAI", icon: "waveform.path.ecg", url: $0) },
                u("https://github.com/openai/codex/releases").map { DashboardLink(title: "Changelog", icon: "doc.text", url: $0) },
            ].compactMap { $0 }
        case "minimax":
            return [DashboardLink(title: "Trang Token Plan", icon: "chart.bar", url: MiniMaxRegion.current.dashboardURL)]
        default:
            return []
        }
    }

    private var claudeConfigButton: some View {
        Button {
            showingClaudeConfig = true
        } label: {
            HStack {
                Image(systemName: "doc.text")
                Text("Cấu hình Claude…")
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 2)
    }

    // MARK: - Bindings & helpers

    private func enabledBinding(_ idx: Int) -> Binding<Bool> {
        Binding(
            get: { rows[idx].enabled },
            set: { rows[idx].enabled = $0; saveAll() }
        )
    }

    private func labelBinding(_ idx: Int) -> Binding<String> {
        Binding(
            get: { rows[idx].accountLabel ?? "" },
            set: {
                rows[idx].accountLabel = $0.isEmpty ? nil : $0
                saveAll()
                NotificationCenter.default.post(name: .aistatusbarRefresh, object: nil)
            }
        )
    }

    private func status(for id: String) -> ProviderStatus? {
        quota.statuses.first { $0.id == id }
    }

    private func displayName(for row: ProviderConfig) -> String {
        switch row.id {
        case "codex": "Codex"
        case "minimax": "MiniMax"
        case "hapo": row.displayName ?? "Hapo Hub"
        case "claude": "Claude"
        default: row.displayName ?? row.id
        }
    }

    private func statusSubtitle(for row: ProviderConfig) -> String {
        if !row.enabled { return "Đã tắt" }
        guard let s = status(for: row.id) else { return "Chưa tải" }
        if s.error != nil { return "Lỗi" }
        if let first = s.windows.first { return "Còn \(first.remainingPct)%" }
        return "Đang tải…"
    }

    /// Header subtitle: prefix the CLI version when known (Codex), e.g.
    /// "codex-cli 0.140.0 • 2 giây trước".
    private func headerSubtitle(for row: ProviderConfig) -> String {
        let updated = updatedSubtitle(for: row.id)
        if let version = status(for: row.id)?.version, !version.isEmpty {
            return "\(version) • \(updated)"
        }
        return updated
    }

    private func updatedSubtitle(for id: String) -> String {
        guard let s = status(for: id) else { return "Chưa tải" }
        let secs = Int(Date().timeIntervalSince(s.lastUpdated))
        if secs < 5 { return "vừa cập nhật" }
        if secs < 60 { return "\(secs) giây trước" }
        if secs < 3600 { return "\(secs / 60) phút trước" }
        return "\(secs / 3600) giờ trước"
    }

    private func codexLoginStatus() -> String {
        guard let creds = try? CodexAuthStore.load() else {
            return "Chưa đăng nhập"
        }
        if let email = CodexAuthStore.emailFromIDToken(creds.idToken) {
            return "Đã đăng nhập: \(email)"
        }
        return "Đã đăng nhập"
    }

    private func saveAll() {
        do {
            let doc = ProvidersDocument(providers: rows)
            try ProvidersStore.save(doc)
            for cfg in doc.providers where !cfg.enabled {
                quota.remove(id: cfg.id)
            }
        } catch {
            // Non-fatal: surfaced indirectly through the live status.
        }
    }
}

// MARK: - Brand logo

/// Real brand logo per provider id, falling back to a SF Symbol when no
/// bundled asset matches. Mirrors `QuotaPanel.providerLogoView`.
struct ProviderLogoView: View {
    let id: String

    var body: some View {
        switch id {
        case "minimax":
            Image("MiniMaxLogo").resizable().interpolation(.high)
        case "hapo":
            Image("HapoLogo").resizable().interpolation(.high)
        case "codex":
            Image("CodexLogo").resizable().interpolation(.high)
                .foregroundStyle(VocabbyTheme.blue)
        default:
            Image(systemName: "circle.dotted")
                .resizable()
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Token field

/// Secure token entry + save button for providers that authenticate with a
/// bearer token (everything except zero-config Codex).
private struct TokenField: View {
    let providerID: String
    let keychain: KeychainService
    let onSaved: () -> Void

    @State private var token = ""
    @State private var banner: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Token")
                .font(.system(size: 13, weight: .semibold))
            HStack(spacing: 8) {
                SecureField("Dán token vào đây", text: $token)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12).monospacedDigit())
                Button("Lưu") {
                    guard !token.isEmpty else { return }
                    do {
                        try keychain.save(account: providerID, secret: token)
                        token = ""
                        banner = "Đã lưu token."
                        onSaved()
                    } catch {
                        banner = "Lỗi Keychain: \(error.localizedDescription)"
                    }
                }
                .controlSize(.small)
                .disabled(token.isEmpty)
            }
            if let banner {
                Text(banner)
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Quota warning card

/// Per-provider quota-warning thresholds. Each window (session/weekly) inherits
/// the global thresholds unless "Customize" is on, mirroring CodexBar's panel.
/// Overrides are persisted via `QuotaWarnConfig` (UserDefaults).
private struct QuotaWarningCard: View {
    let providerID: String

    @State private var sessionCustom = false
    @State private var weeklyCustom = false
    @State private var sessionLevels: [Int] = [50, 20]
    @State private var weeklyLevels: [Int] = [50, 20]

    var body: some View {
        SettingsCard(
            header: "Cảnh báo quota",
            footer: "Dùng ngưỡng chung trừ khi bật tùy chỉnh riêng cho từng cửa sổ."
        ) {
            windowRow(title: "Phiên (5 giờ)", window: "session",
                      custom: $sessionCustom, levels: $sessionLevels)
            SettingsRowDivider()
            windowRow(title: "Tuần", window: "weekly",
                      custom: $weeklyCustom, levels: $weeklyLevels)
        }
        .onAppear(perform: load)
    }

    @ViewBuilder
    private func windowRow(title: String, window: String,
                           custom: Binding<Bool>, levels: Binding<[Int]>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { custom.wrappedValue },
                set: { on in
                    custom.wrappedValue = on
                    QuotaWarnConfig.setOverride(provider: providerID, window: window,
                                                thresholds: on ? levels.wrappedValue : nil)
                }
            )) {
                Text("Tùy chỉnh ngưỡng \(title)")
                    .font(.system(size: 13, weight: .semibold))
            }
            .toggleStyle(.checkbox)

            if custom.wrappedValue {
                HStack(spacing: 16) {
                    levelStepper("Cảnh báo", levels: levels, index: 0, window: window)
                    levelStepper("Nguy hiểm", levels: levels, index: 1, window: window)
                }
            } else {
                let inherited = QuotaWarnConfig.globalThresholds.map { "\($0)%" }.joined(separator: ", ")
                Text("Kế thừa: \(inherited)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func levelStepper(_ label: String, levels: Binding<[Int]>, index: Int, window: String) -> some View {
        Stepper(value: Binding(
            get: { levels.wrappedValue[index] },
            set: { value in
                var arr = levels.wrappedValue
                arr[index] = value
                levels.wrappedValue = arr
                QuotaWarnConfig.setOverride(provider: providerID, window: window, thresholds: arr)
            }
        ), in: 1...100, step: 5) {
            Text("\(label): \(levels.wrappedValue[index])%")
                .font(.system(size: 11).monospacedDigit())
        }
        .fixedSize()
    }

    private func load() {
        sessionCustom = QuotaWarnConfig.hasOverride(provider: providerID, window: "session")
        weeklyCustom = QuotaWarnConfig.hasOverride(provider: providerID, window: "weekly")
        sessionLevels = padded(QuotaWarnConfig.thresholds(provider: providerID, window: "session"))
        weeklyLevels = padded(QuotaWarnConfig.thresholds(provider: providerID, window: "weekly"))
    }

    /// Ensure exactly two levels for the two steppers.
    private func padded(_ values: [Int]) -> [Int] {
        var x = values
        while x.count < 2 { x.append(x.last ?? 20) }
        return Array(x.prefix(2))
    }
}

// MARK: - Codex accounts card

/// Multi-account management for Codex. The system account (~/.codex) is shown
/// read-only; managed accounts live in their own CODEX_HOME and are added via
/// `codex login` in the browser. Selecting one switches which login the
/// provider reads.
private struct CodexAccountsCard: View {
    @State private var accounts: [CodexAccount] = []
    @State private var activeID = "system"
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        SettingsCard(
            header: "Tài khoản",
            footer: "Mỗi tài khoản đăng nhập riêng. “Thêm tài khoản” mở `codex login` trong trình duyệt; tài khoản hệ thống (~/.codex) không bị ghi đè."
        ) {
            ForEach(accounts) { account in
                accountRow(account)
                SettingsRowDivider()
            }
            addRow
        }
        .onAppear(perform: reload)
    }

    private func accountRow(_ account: CodexAccount) -> some View {
        HStack(spacing: 10) {
            Image(systemName: account.id == activeID ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(account.id == activeID ? Color.accentColor : Color.secondary)
                .onTapGesture {
                    CodexAccountStore.setActive(account.id)
                    activeID = account.id
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(account.email ?? (account.isSystem ? "Tài khoản hệ thống" : "Tài khoản"))
                    .font(.system(size: 13, weight: .semibold))
                Text(account.isSystem ? "Hệ thống · ~/.codex" : "Quản lý bởi app")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            Button("Đăng nhập lại") { Task { await reauth(account.id) } }
                .controlSize(.small)
                .disabled(busy)

            if !account.isSystem {
                Button(role: .destructive) {
                    CodexAccountStore.remove(id: account.id)
                    reload()
                } label: {
                    Image(systemName: "trash")
                }
                .controlSize(.small)
                .disabled(busy)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var addRow: some View {
        HStack(spacing: 8) {
            Button { Task { await add() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle")
                    Text("Thêm tài khoản")
                }
            }
            .buttonStyle(.plain)
            .disabled(busy)

            if busy {
                ProgressView().controlSize(.small)
                Text("Đang chờ đăng nhập trong trình duyệt…")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            if let errorText {
                Text(errorText)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func reload() {
        accounts = CodexAccountStore.allAccounts()
        activeID = CodexAccountStore.activeID()
    }

    private func add() async {
        busy = true; errorText = nil
        defer { busy = false }
        do { _ = try await CodexAccountStore.addAccount(); reload() }
        catch { errorText = error.localizedDescription }
    }

    private func reauth(_ id: String) async {
        busy = true; errorText = nil
        defer { busy = false }
        do { try await CodexAccountStore.reauth(id: id); reload() }
        catch { errorText = error.localizedDescription }
    }
}
