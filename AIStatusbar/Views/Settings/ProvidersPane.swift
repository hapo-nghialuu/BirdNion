import SwiftUI
import CodexBarCore

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
    /// Claude token cost (today / 30d), scanned lazily when Claude is
    /// selected — mirrors CodexCostScanner but reads Claude Code's local
    /// session jsonl files (see ClaudeCostScanner.swift).
    @State private var claudeCost: ClaudeCostSummary?

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
            // Scan local sessions for token cost only while the provider is
            // selected. Mirrors CodexCostScanner's behavior — cached 5 min
            // so the panel doesn't re-walk the project tree on every refresh.
            switch selectedID {
            case "codex":
                claudeCost = nil
                codexCost = await CodexCostScanner.summary()
            case "claude":
                codexCost = nil
                claudeCost = await ClaudeCostScanner.summary()
            default:
                codexCost = nil
                claudeCost = nil
            }
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
            } else if row.id == "claude" {
                // OAuth token comes from the Claude Code Keychain item.
                infoRow("Nguồn", "OAuth")
            }
            if let plan = s?.planType, !plan.isEmpty {
                infoRow("Gói", plan.capitalized)
            }
            if let name = s?.planName, !name.isEmpty {
                // Plan display name (MiniMax `current_subscribe_title`) — distinct
                // from `planType` which carries a code (`plus` / `pro`).
                infoRow("Tên gói", name)
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
            if row.id == "codex", let n = s?.resetCreditsAvailable {
                infoRow("Reset khả dụng", "\(n) lần")
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
            } else if s == nil || s?.windows.isEmpty == true {
                // Empty placeholder only when there's truly no data — cost /
                // extras below can still render so the panel stays useful
                // even when OAuth fails.
                Text(row.enabled ? "Chưa có dữ liệu — bấm làm mới." : "Đang tắt — không có dữ liệu.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
            // Provider-specific extras render regardless of OAuth window
            // presence — cost + account info stay useful even when the
            // primary fetch fails. Codex ships a local token scanner; Claude
            // ships both a local token scanner and web extras.
            if row.id == "codex", let cost = codexCost, !cost.isEmpty {
                SettingsRowDivider()
                costRows(cost)
            }
            if row.id == "claude", let cost = s?.cost {
                SettingsRowDivider()
                webCostRow(cost)
            }
            if row.id == "claude", let cost = claudeCost, !cost.isEmpty {
                SettingsRowDivider()
                costRows(cost)
            }
            if row.id == "claude", let extras = s?.webExtras {
                SettingsRowDivider()
                webExtrasRows(extras)
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

    /// Token cost rows (Codex + Claude). Dollar amounts are estimates (tokens ×
    /// price table), so they're prefixed with "≈"; token counts are exact.
    /// Both `CodexCostSummary` and `ClaudeCostSummary` carry the same 4
    /// fields, so we forward to a single renderer.
    private func costRows(_ cost: CodexCostSummary) -> some View {
        costRowsImpl(todayUSD: cost.todayUSD, todayTokens: cost.todayTokens,
                     last30USD: cost.last30USD, last30Tokens: cost.last30Tokens)
    }
    private func costRows(_ cost: ClaudeCostSummary) -> some View {
        costRowsImpl(todayUSD: cost.todayUSD, todayTokens: cost.todayTokens,
                     last30USD: cost.last30USD, last30Tokens: cost.last30Tokens)
    }
    private func costRowsImpl(todayUSD: Double, todayTokens: Int,
                              last30USD: Double, last30Tokens: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            costLine("Hôm nay", usd: todayUSD, tokens: todayTokens)
            costLine("30 ngày", usd: last30USD, tokens: last30Tokens)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Claude cost row, CodexBar parity. Renders a progress bar (used% of
    /// monthly limit), the dollar amount on the right, a "X% used" line, and
    /// an optional "Resets in Nd" countdown sourced from `cost.resetsAt`.
    /// Matches CodexBar's `ProviderCostSection` layout: title + percent +
    /// spend line + reset countdown.
    private func webCostRow(_ cost: ProviderCostSnapshot) -> some View {
        let usedPct = cost.limit > 0
            ? Int(min(100, max(0, (cost.used / cost.limit * 100).rounded())))
            : 0
        let remaining = max(0, cost.limit - cost.used)
        let barColor: Color = usedPct >= 90 ? .red
            : (usedPct >= 70 ? .orange : VocabbyTheme.blue)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("CHI PHÍ")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
                Spacer()
                Text("\(UsageFormatter.usdString(cost.used)) / \(UsageFormatter.usdString(cost.limit))")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 8)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(barColor)
                        .frame(width: max(0, geo.size.width * CGFloat(usedPct) / 100), height: 8)
                }
            }
            .frame(height: 8)
            HStack(alignment: .firstTextBaseline) {
                Text("\(usedPct)% đã dùng · còn \(UsageFormatter.usdString(remaining))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                if let reset = cost.resetsAt {
                    Text("Reset sau \(Self.resetCountdown(to: reset))")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                } else if let period = cost.period {
                    Text(period)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Compact countdown to a future date. Mirrors `WindowPace.format` but
    /// skips the "< 1m" branch so a sub-minute reset still reads "0m".
    /// "1d 4h", "4h 12m", "12m", "<1m".
    static func resetCountdown(to date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(date.timeIntervalSince(now)))
        let days = s / 86400, hours = (s % 86400) / 3600, minutes = (s % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "<1m"
    }

    /// Claude web/CLI account identity rows. Surfaces email, organization,
    /// and login method when `webExtras` carries them — replaces CodexBar's
    /// `ProviderDetailInfoGrid` "Account" + "Auth" rows so the user can
    /// confirm which Claude.ai account the cookie/CLI session belongs to
    /// when OAuth is offline.
    @ViewBuilder
    private func webExtrasRows(_ extras: ClaudeWebExtras) -> some View {
        if let email = extras.accountEmail, !email.isEmpty {
            webInfoRow(label: "EMAIL", value: email)
        }
        if let org = extras.accountOrganization, !org.isEmpty {
            webInfoRow(label: "TỔ CHỨC", value: org)
        }
        if let method = extras.loginMethod, !method.isEmpty {
            webInfoRow(label: "LOGIN", value: method)
        }
        if let source = extras.sourceLabel, !source.isEmpty {
            webInfoRow(label: "NGUỒN", value: source.uppercased())
        }
    }

    private func webInfoRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
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
            } else if row.id == "claude" {
                // Claude doesn't take a pasted API token — it uses OAuth
                // from the Keychain, browser cookies (Web), the `claude`
                // CLI (PTY), or an Anthropic Admin API key. The 4 pickers
                // below (Usage source / Cookie source / Manual cookie field
                // / Keychain prompt mode) live in `settingsSection` siblings;
                // here we just skip the generic TokenField.
                EmptyView()
            } else {
                TokenField(
                    providerID: row.id,
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

            if row.id == "zai" {
                SettingsRowDivider()
                HStack(spacing: 12) {
                    Text("Khu vực API")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 8)
                    Picker("", selection: Binding(
                        get: { settings.zaiRegion },
                        set: { settings.zaiRegion = $0; Task { await quota.refresh() } }
                    )) {
                        ForEach(ZaiRegion.allCases) { r in
                            Text(r.displayName).tag(r.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 170)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            if row.id == "claude" {
                claudeUsageSourcePicker()
                claudeCookieSourcePicker()
                if settings.claudeCookieSource == "manual" {
                    SettingsRowDivider()
                    claudeManualCookieField()
                }
                claudeOAuthKeychainPromptPicker()
            }
        }
    }

    // MARK: - Claude parity pickers

    /// Usage source picker — mirrors CodexBar's `ClaudeUsageDataSource`.
    /// `.auto` walks OAuth → Web → CLI; `.oauth` pins to OAuth (default);
    /// `.web` uses cookies only; `.cli` spawns `claude` PTY; `.api` requires
    /// an Anthropic Admin API key (handled by the field below when picked).
    @ViewBuilder
    private func claudeUsageSourcePicker() -> some View {
        SettingsRowDivider()
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text("Nguồn dữ liệu")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                Picker("", selection: Binding(
                    get: { settings.claudeUsageDataSource },
                    set: { settings.claudeUsageDataSource = $0; Task { await quota.refresh() } }
                )) {
                    ForEach(ClaudeUsageDataSource.allCases) { src in
                        Text(src.displayName).tag(src.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 170)
            }
            Text(sourceSubtitle(for: settings.claudeUsageDataSource))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func sourceSubtitle(for source: String) -> String {
        switch source {
        case "auto": return "Thử OAuth → Web → CLI, lấy cái đầu tiên thành công."
        case "oauth": return "Dùng OAuth token trong Keychain của Claude Code (mặc định)."
        case "web": return "Scrape claude.ai qua cookie Safari/Chrome."
        case "cli": return "Chạy `claude` CLI trong PTY (cần CLI cài đặt)."
        case "api": return "Anthropic Admin API (cần nhập key bên dưới)."
        default: return ""
        }
    }

    /// Cookie source picker — mirrors CodexBar's `ProviderCookieSource`.
    @ViewBuilder
    private func claudeCookieSourcePicker() -> some View {
        SettingsRowDivider()
        HStack(spacing: 12) {
            Text("Cookie Claude")
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 8)
            Picker("", selection: Binding(
                get: { settings.claudeCookieSource },
                set: { settings.claudeCookieSource = $0; Task { await quota.refresh() } }
            )) {
                ForEach(ProviderCookieSource.allCases) { src in
                    Text(src.displayName).tag(src.rawValue)
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
    private func claudeManualCookieField() -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Cookie header thủ công")
                .font(.system(size: 12, weight: .semibold))
            SecureField("sessionKey=...; cf_clearance=...", text: Binding(
                get: { settings.claudeManualCookieHeader },
                set: { settings.claudeManualCookieHeader = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11))
            Text("Mở claude.ai trong trình duyệt đã đăng nhập → DevTools → Network → sao chép toàn bộ header `Cookie:`.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Keychain prompt policy picker — mirrors CodexBar's
    /// `ClaudeOAuthKeychainPromptMode`. `.never` skips OAuth entirely (use
    /// Web/CLI); `.onlyOnUserAction` prompts only on manual refresh;
    /// `.always` prompts on every background fetch.
    @ViewBuilder
    private func claudeOAuthKeychainPromptPicker() -> some View {
        SettingsRowDivider()
        HStack(spacing: 12) {
            Text("Keychain OAuth")
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 8)
            Picker("", selection: Binding(
                get: { settings.claudeOAuthKeychainPromptMode },
                set: { settings.claudeOAuthKeychainPromptMode = $0; Task { await quota.refresh() } }
            )) {
                Text("Không bao giờ").tag(ClaudeOAuthKeychainPromptMode.never.rawValue)
                Text("Chỉ khi bấm").tag(ClaudeOAuthKeychainPromptMode.onlyOnUserAction.rawValue)
                Text("Luôn hỏi").tag(ClaudeOAuthKeychainPromptMode.always.rawValue)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 130)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
        case "openrouter":
            return [
                u("https://openrouter.ai/settings/credits").map { DashboardLink(title: "Tín dụng OpenRouter", icon: "chart.bar", url: $0) },
                u("https://openrouter.ai/keys").map { DashboardLink(title: "API keys", icon: "key", url: $0) },
            ].compactMap { $0 }
        case "deepseek":
            return [DashboardLink(title: "Số dư DeepSeek", icon: "chart.bar",
                                  url: URL(string: "https://platform.deepseek.com/usage")!)]
        case "zai":
            return [DashboardLink(title: "Coding Plan", icon: "chart.bar",
                                  url: URL(string: "https://z.ai/manage-apikey/coding-plan/personal/my-plan")!)]
        case "claude":
            return [DashboardLink(title: "Trạng thái Anthropic", icon: "waveform.path.ecg",
                                  url: URL(string: "https://status.anthropic.com/")!)]
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
        case "openrouter": "OpenRouter"
        case "deepseek": "DeepSeek"
        case "zai": "Z.ai / GLM"
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
        case "openrouter":
            Image("OpenRouterLogo").resizable().interpolation(.high)
                .foregroundStyle(VocabbyTheme.openRouter)
        case "deepseek":
            Image("DeepSeekLogo").resizable().interpolation(.high)
                .foregroundStyle(VocabbyTheme.deepSeek)
        case "zai":
            Image("ZaiLogo").resizable().interpolation(.high)
                .foregroundStyle(VocabbyTheme.zai)
        case "claude":
            Image("ClaudeLogo").resizable().interpolation(.high)
                .foregroundStyle(VocabbyTheme.claude)
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
                        // Save to the shared CodexBar config file (interops with
                        // CodexBar), same as where the providers read it from.
                        try CodexBarConfigStore.setAPIKey(token, provider: providerID)
                        token = ""
                        banner = "Đã lưu vào config CodexBar."
                        onSaved()
                    } catch {
                        banner = "Lỗi lưu: \(error.localizedDescription)"
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
