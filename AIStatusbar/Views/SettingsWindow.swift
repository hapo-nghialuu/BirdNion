import SwiftUI

/// Settings window: separate macOS Scene (R2-01 refactor). Two sections —
/// Providers (token entry, enable/disable) and Claude Code Config (settings.json).
/// Opens via Cmd+, from the popover or via the gear menu.
struct SettingsWindow: View {
    @EnvironmentObject var keychain: KeychainService
    @EnvironmentObject var config: ConfigService
    @EnvironmentObject var quota: QuotaService
    @State private var section: Section = .providers

    enum Section: Hashable, CaseIterable { case providers, config }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image("OriginalImage")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("BirdNion")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Quota + Claude Config")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $section) {
                    Text("Providers").tag(Section.providers)
                    Text("Claude Config").tag(Section.config)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 200)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            Group {
                switch section {
                case .providers: ProvidersSection()
                case .config: ConfigPanel()
                }
            }
            .frame(width: 420, height: 260)
        }
        .frame(width: 420, height: 300)
    }
}

/// Per-provider rows: toggle + secure token field + save button.
struct ProvidersSection: View {
    @EnvironmentObject var keychain: KeychainService
    @EnvironmentObject var quota: QuotaService
    @State private var rows: [ProviderConfig] = []
    @State private var pendingTokens: [String: String] = [:]
    @State private var savedBanner: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let b = savedBanner {
                Text(b)
                    .font(.system(size: 10))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                    if idx > 0 { Divider() }
                    rowView(row)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)
                }
            }
            Spacer(minLength: 0)
        }
        .task { rows = ProvidersStore.load().providers }
    }

    @ViewBuilder
    private func rowView(_ row: ProviderConfig) -> some View {
        HStack(spacing: 8) {
            Text(row.id)
                .font(.system(size: 11, weight: .medium))
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
            .controlSize(.mini)
            .labelsHidden()
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
