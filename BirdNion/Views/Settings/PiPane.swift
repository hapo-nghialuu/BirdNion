import SwiftUI

/// Settings pane for Pi Agent (`pi`) configuration.
///
/// Reads and writes directly to `~/.pi/agent/settings.json`.
struct PiPane: View {
    @EnvironmentObject var settings: SettingsStore
    @StateObject private var store = PiAgentConfigStore()

    @State private var defaultProvider: String = "token-plan"
    @State private var defaultModel: String = "MiniMax-M3"
    @State private var defaultThinkingLevel: String = "high"
    @State private var hideThinkingBlock: Bool = true
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    private var vi: Bool { L10n.languageCode(settings.appLanguage) == "vi" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerCard

                SettingsRowDivider()

                modelConfigSection

                SettingsRowDivider()

                thinkingSection

                SettingsRowDivider()

                pathsAndPrivacySection

                Spacer(minLength: 20)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        .onAppear {
            syncFromStore()
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous)
                    .fill(VocabbyTheme.chartPi.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: "terminal")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(VocabbyTheme.chartPi)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Pi Agent (pi)")
                    .font(.plexSans(16, weight: .semibold))
                    .foregroundStyle(VocabbyTheme.primary)
                Text(vi ? "Trợ lý lập trình AI đa nhà cung cấp" : "Multi-provider AI Coding Assistant")
                    .font(.plexSans(12))
                    .foregroundStyle(VocabbyTheme.secondary)
            }

            Spacer()

            Button {
                saveChanges()
            } label: {
                Text(vi ? "Lưu cấu hình" : "Save Config")
            }
            .buttonStyle(.instrumentPrimary)
        }
    }

    // MARK: - Model Config Section

    private var modelConfigSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(vi ? "MÔ HÌNH MẶC ĐỊNH (DEFAULT MODEL)" : "DEFAULT MODEL CONFIGURATION")
                .plexEyebrow(size: 11, color: VocabbyTheme.tertiary)

            VStack(spacing: 10) {
                inputRow(
                    label: vi ? "Nhà cung cấp mặc định (Provider)" : "Default Provider",
                    hint: "e.g. token-plan, openai, anthropic",
                    text: $defaultProvider)

                inputRow(
                    label: vi ? "Model mặc định" : "Default Model",
                    hint: "e.g. MiniMax-M3, claude-3-5-sonnet, gpt-4o",
                    text: $defaultModel)
            }
        }
    }

    private func inputRow(label: String, hint: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.plexSans(12, weight: .medium))
                .foregroundStyle(VocabbyTheme.primary)

            TextField(hint, text: text)
                .font(.plexMono(12))
                .instrumentControlFieldStyle()
        }
    }

    // MARK: - Thinking Section

    private var thinkingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(vi ? "TÙY CHỌN SUY LUẬN (THINKING / REASONING)" : "THINKING & REASONING")
                .plexEyebrow(size: 11, color: VocabbyTheme.tertiary)

            inputRow(
                label: vi ? "Mức độ suy luận (Thinking Level)" : "Default Thinking Level",
                hint: "off | minimal | low | medium | high | xhigh | max",
                text: $defaultThinkingLevel)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(vi ? "Ẩn khối suy luận trong TUI" : "Hide Thinking Blocks in TUI")
                        .font(.plexSans(13, weight: .medium))
                        .foregroundStyle(VocabbyTheme.primary)
                    Text(vi ? "Thu gọn các bước suy luận để giao diện gọn gàng" : "Collapse thinking text in terminal output")
                        .font(.plexSans(11))
                        .foregroundStyle(VocabbyTheme.tertiary)
                }
                Spacer()
                Toggle("", isOn: $hideThinkingBlock)
                    .labelsHidden()
                    .labelsHidden()
                .toggleStyle(.instrumentSwitch)
            }
        }
    }

    // MARK: - Paths & Privacy

    private var pathsAndPrivacySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(vi ? "ĐƯỜNG DẪN & BẢO MẬT CỤC BỘ" : "PATHS & PRIVACY")
                .plexEyebrow(size: 11, color: VocabbyTheme.tertiary)

            VStack(alignment: .leading, spacing: 6) {
                pathRow(label: "Settings file:", value: PiAgentConfigStore.configFile.path)
                pathRow(label: "Sessions directory:", value: PiCostScanner.defaultSessionsDirectory.path)
            }

            if let status = statusMessage {
                Text(status)
                    .font(.plexSans(12))
                    .foregroundStyle(VocabbyTheme.success)
            }

            if let error = errorMessage {
                Text(error)
                    .font(.plexSans(12))
                    .foregroundStyle(VocabbyTheme.critical)
            }
        }
    }

    private func pathRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.plexMono(11, weight: .medium))
                .foregroundStyle(VocabbyTheme.secondary)
            Text(value)
                .font(.plexMono(11))
                .foregroundStyle(VocabbyTheme.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: - Helpers

    private func syncFromStore() {
        defaultProvider = store.config.defaultProvider
        defaultModel = store.config.defaultModel
        defaultThinkingLevel = store.config.defaultThinkingLevel
        hideThinkingBlock = store.config.hideThinkingBlock
    }

    private func saveChanges() {
        store.config.defaultProvider = defaultProvider.trimmingCharacters(in: .whitespacesAndNewlines)
        store.config.defaultModel = defaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
        store.config.defaultThinkingLevel = defaultThinkingLevel.trimmingCharacters(in: .whitespacesAndNewlines)
        store.config.hideThinkingBlock = hideThinkingBlock

        do {
            try store.save()
            statusMessage = vi ? "Đã lưu cấu hình ~/.pi/agent/settings.json thành công" : "Saved configuration to settings.json successfully"
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = nil
        }
    }
}
