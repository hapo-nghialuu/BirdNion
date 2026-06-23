import SwiftUI

/// Providers tab: per-provider rows (toggle + Account label + Token) plus a
/// footer button that opens the Claude Config sheet.
///
/// Codex is zero-config — its row hides the token field and shows the login
/// status read from `~/.codex/auth.json` instead.
struct ProvidersPane: View {
    @EnvironmentObject var keychain: KeychainService
    @EnvironmentObject var quota: QuotaService
    @State private var rows: [ProviderConfig] = []
    @State private var pendingTokens: [String: String] = [:]
    @State private var savedBanner: String? = nil
    @State private var showingClaudeConfig = false

    var body: some View {
        SettingsPage {
            SettingsCard(
                header: "Nhà cung cấp",
                footer: "Codex tự động đăng nhập từ `codex login` trong Terminal — không cần nhập token."
            ) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                    rowView(row)
                    if idx < rows.count - 1 { SettingsRowDivider() }
                }
            }

            SettingsCard(
                header: "Claude Code",
                footer: "Sửa trực tiếp ~/.claude/settings.json (model, base URL, API key)."
            ) {
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
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }

            if let b = savedBanner {
                Text(b)
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 4)
            }
        }
        .task { rows = ProvidersStore.load().providers }
        .sheet(isPresented: $showingClaudeConfig) {
            ConfigPanel()
                .environmentObject(keychain)
                .environmentObject(quota)
                .frame(width: 440, height: 320)
        }
    }

    @ViewBuilder
    private func rowView(_ row: ProviderConfig) -> some View {
        HStack(spacing: 8) {
            Text(displayName(for: row))
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 80, alignment: .leading)
            Toggle("", isOn: Binding(
                get: { row.enabled },
                set: { newVal in
                    if let i = rows.firstIndex(where: { $0.id == row.id }) {
                        rows[i].enabled = newVal
                        saveAll()
                    }
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)

            TextField("Account", text: labelBinding(for: row.id))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11).monospacedDigit())
                .help("Tùy chọn: hiển thị trên tab chip. Để trống = auto-derive.")

            if row.id == "codex" {
                Text(codexLoginStatus())
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                SecureField("Token", text: binding(for: row.id))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11).monospacedDigit())
                Button("Lưu") {
                    let v = pendingTokens[row.id] ?? ""
                    if !v.isEmpty {
                        do {
                            try keychain.save(account: row.id, secret: v)
                            pendingTokens[row.id] = ""
                            savedBanner = "Đã lưu token cho \(row.id)"
                        } catch {
                            savedBanner = "Keychain error: \(error)"
                        }
                    }
                }
                .controlSize(.small)
                .disabled((pendingTokens[row.id] ?? "").isEmpty)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func displayName(for row: ProviderConfig) -> String {
        switch row.id {
        case "codex": "Codex"
        case "minimax": "MiniMax"
        case "hapo": row.displayName ?? "Hapo Hub"
        default: row.displayName ?? row.id
        }
    }

    /// Reads ~/.codex/auth.json to show whether Codex is logged in. Cheap
    /// enough at the low render rate of the settings panel.
    private func codexLoginStatus() -> String {
        guard let creds = try? CodexAuthStore.load() else {
            return "Chưa đăng nhập — chạy `codex`"
        }
        if let email = CodexAuthStore.emailFromIDToken(creds.idToken) {
            return "Đã đăng nhập: \(email)"
        }
        return "Đã đăng nhập"
    }

    private func labelBinding(for id: String) -> Binding<String> {
        Binding(
            get: { rows.first(where: { $0.id == id })?.accountLabel ?? "" },
            set: { newVal in
                if let i = rows.firstIndex(where: { $0.id == id }) {
                    rows[i].accountLabel = newVal.isEmpty ? nil : newVal
                    saveAll()
                    NotificationCenter.default.post(name: .aistatusbarRefresh, object: nil)
                }
            }
        )
    }

    private func binding(for id: String) -> Binding<String> {
        Binding(
            get: { pendingTokens[id] ?? "" },
            set: { pendingTokens[id] = $0 }
        )
    }

    private func saveAll() {
        do {
            let doc = ProvidersDocument(providers: rows)
            try ProvidersStore.save(doc)
            for cfg in doc.providers where !cfg.enabled {
                quota.remove(id: cfg.id)
            }
        } catch {
            savedBanner = "Save error: \(error)"
        }
    }
}
