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

    @State private var rows: [ProviderConfig] = []
    @State private var selectedID: String?
    @State private var showingClaudeConfig = false

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
        .frame(width: 240, alignment: .top)
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
                Text(updatedSubtitle(for: row.id))
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
            if let label = s?.accountLabel, !label.isEmpty {
                infoRow("Tài khoản", label)
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

    @ViewBuilder
    private func usageSection(_ row: ProviderConfig) -> some View {
        let s = status(for: row.id)
        SettingsCard(header: "Sử dụng") {
            if let s, !s.windows.isEmpty {
                ForEach(Array(s.windows.enumerated()), id: \.element.id) { i, w in
                    quotaWindowRow(w)
                    if i < s.windows.count - 1 { SettingsRowDivider() }
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
            if let sub = w.subtitle, !sub.isEmpty {
                Text(sub)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
