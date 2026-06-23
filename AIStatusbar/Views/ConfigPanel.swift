import SwiftUI

/// Compact config form: 11pt labels, 22pt row height, no labels-on-the-side bloat.
struct ConfigPanel: View {
    @EnvironmentObject var config: ConfigService
    @EnvironmentObject var keychain: KeychainService
    @State private var settings: [String: Any] = [:]
    @State private var pendingApiKey: String = ""
    @State private var apiKeyHasValue: Bool = false
    @State private var loadError: String? = nil
    @State private var savedBanner: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(config.activePath.path)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(config.activePath.path)
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 2)

            if let err = loadError ?? config.lastError {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 10)
            }
            if let banner = savedBanner {
                Text(banner)
                    .font(.system(size: 10))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 10)
            }

            VStack(alignment: .leading, spacing: 3) {
                Group {
                    envStringField("ANTHROPIC_MODEL")
                    envStringField("ANTHROPIC_BASE_URL")
                    envStringField("ANTHROPIC_DEFAULT_OPUS_MODEL")
                    envStringField("ANTHROPIC_DEFAULT_SONNET_MODEL")
                    envStringField("ANTHROPIC_DEFAULT_HAIKU_MODEL")
                }
                Divider().padding(.vertical, 3)
                apiKeyField
                Divider().padding(.vertical, 3)
                permissionsPicker
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)

            HStack {
                Spacer()
                Button("Lưu", action: save)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 10)
            .padding(.top, 2)
            .padding(.bottom, 6)
        }
        .task { load() }
    }

    @ViewBuilder
    private func envStringField(_ key: String) -> some View {
        let current = ((settings["env"] as? [String: Any]) ?? [:])[key] as? String ?? ""
        let binding = Binding<String>(
            get: { current },
            set: { newVal in
                var env = (settings["env"] as? [String: Any]) ?? [:]
                env[key] = newVal
                settings["env"] = env
            }
        )
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
                .lineLimit(1)
            TextField("", text: binding)
                .textFieldStyle(.plain)
                .font(.system(size: 11).monospacedDigit())
        }
    }

    @ViewBuilder
    private var apiKeyField: some View {
        HStack(spacing: 4) {
            Text("ANTHROPIC_API_KEY")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
                .lineLimit(1)
            if apiKeyHasValue && pendingApiKey.isEmpty {
                Text("fe_oa_••••••••")
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(.secondary)
            } else {
                SecureField("Nhập", text: $pendingApiKey)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
            }
        }
    }

    @ViewBuilder
    private var permissionsPicker: some View {
        let modes = ["default", "acceptEdits", "dontAsk", "plan"]
        let current = (settings["permissions"] as? [String: Any])?["defaultMode"] as? String ?? "default"
        HStack(spacing: 4) {
            Text("permissions")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
                .lineLimit(1)
            Picker("", selection: Binding<String>(
                get: { current },
                set: { newVal in
                    var p = (settings["permissions"] as? [String: Any]) ?? [:]
                    p["defaultMode"] = newVal
                    settings["permissions"] = p
                }
            )) {
                ForEach(modes, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
        }
    }

    private func load() {
        do {
            settings = try config.loadGlobal()
            let placeholder = (settings["env"] as? [String: Any])?["ANTHROPIC_API_KEY"] as? String
            apiKeyHasValue = placeholder == AIStatusbarConfig.AnthropicKeyPlaceholder
        } catch let e as ConfigError {
            loadError = e.message
        } catch {
            loadError = "\(error)"
        }
    }

    private func save() {
        do {
            if !pendingApiKey.isEmpty {
                if pendingApiKey.count > 256 {
                    config.lastError = "API key quá dài (max 256)"
                    return
                }
                try keychain.save(account: "anthropic", secret: pendingApiKey)
            }
            var env = (settings["env"] as? [String: Any]) ?? [:]
            env["ANTHROPIC_API_KEY"] = AIStatusbarConfig.AnthropicKeyPlaceholder
            settings["env"] = env
            try config.saveGlobal(settings)
            savedBanner = "Đã lưu. Khởi động lại Claude Code để áp dụng."
            pendingApiKey = ""
            apiKeyHasValue = true
        } catch let e as ConfigError {
            config.lastError = e.message
        } catch {
            config.lastError = "\(error)"
        }
    }
}

enum AIStatusbarConfig {
    static let AnthropicKeyPlaceholder = "KEYCHAIN_REF:BirdNion/anthropic"
}
