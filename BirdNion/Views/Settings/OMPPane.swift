import SwiftUI

/// Settings pane for Oh My Pi (`omp`) coding agent configuration.
///
/// Reads and writes directly to `~/.omp/agent/config.yml` (and profile configs).
struct OMPPane: View {
    @EnvironmentObject var settings: SettingsStore
    @StateObject private var store = OMPAgentConfigStore()

    @State private var planModel: String = ""
    @State private var slowModel: String = ""
    @State private var smolModel: String = ""
    @State private var defaultModel: String = ""
    @State private var prewalkEnabled: Bool = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    private var vi: Bool { L10n.languageCode(settings.appLanguage) == "vi" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerCard

                SettingsRowDivider()

                modelRolesSection

                SettingsRowDivider()

                automationSection

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
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(VocabbyTheme.chartOMP.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: "cpu")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(VocabbyTheme.chartOMP)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Oh My Pi (omp)")
                    .font(.plexSans(16, weight: .semibold))
                    .foregroundStyle(VocabbyTheme.primary)
                Text(vi ? "Hạ tầng điều phối đa Agent (Multi-Agent Harness)" : "Multi-Agent Coding Harness Platform")
                    .font(.plexSans(12))
                    .foregroundStyle(VocabbyTheme.secondary)
            }

            Spacer()

            Button {
                saveChanges()
            } label: {
                Text(vi ? "Lưu cấu hình" : "Save Config")
                    .font(.plexSans(12, weight: .medium))
                    .foregroundStyle(VocabbyTheme.background)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(VocabbyTheme.primary)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Model Roles Section

    private var modelRolesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(vi ? "CẤU HÌNH PHÂN VAI MODEL (MODEL ROLES)" : "MODEL ROLE ROUTING")
                .plexEyebrow(size: 11, color: VocabbyTheme.tertiary)

            VStack(spacing: 10) {
                roleInputRow(
                    label: vi ? "Plan Model (Lập kế hoạch)" : "Plan Model",
                    hint: "e.g. claude-opus-4-6, gpt-5.2",
                    text: $planModel)

                roleInputRow(
                    label: vi ? "Slow Model (Suy luận chuyên sâu)" : "Slow / Reasoning Model",
                    hint: "e.g. gpt-5.6-sol:max, gemini-3.7-flash",
                    text: $slowModel)

                roleInputRow(
                    label: vi ? "Smol Model (Thực thi tác vụ nhẹ)" : "Smol / Fast Model",
                    hint: "e.g. ox-alpha, gpt-5.2-mini",
                    text: $smolModel)

                roleInputRow(
                    label: vi ? "Default Model (Mặc định)" : "Default Model",
                    hint: "e.g. gemini-3.7-flash:high",
                    text: $defaultModel)
            }
        }
    }

    private func roleInputRow(label: String, hint: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.plexSans(12, weight: .medium))
                .foregroundStyle(VocabbyTheme.primary)

            TextField(hint, text: text)
                .textFieldStyle(.plain)
                .font(.plexMono(12))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(VocabbyTheme.card)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(VocabbyTheme.border, lineWidth: 1)
                        )
                )
        }
    }

    // MARK: - Automation Section

    private var automationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(vi ? "TỰ ĐỘNG HÓA (AUTOMATION)" : "AUTOMATION")
                .plexEyebrow(size: 11, color: VocabbyTheme.tertiary)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(vi ? "Chế độ Prewalk" : "Prewalk Mode")
                        .font(.plexSans(13, weight: .medium))
                        .foregroundStyle(VocabbyTheme.primary)
                    Text(vi ? "Tự động chuyển sang Smol model sau khi duyệt Plan" : "Auto-switch from Plan model to Smol model once plan is approved")
                        .font(.plexSans(11))
                        .foregroundStyle(VocabbyTheme.tertiary)
                }
                Spacer()
                Toggle("", isOn: $prewalkEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
    }

    // MARK: - Paths & Privacy

    private var pathsAndPrivacySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(vi ? "ĐƯỜNG DẪN & BẢO MẬT CỤC BỘ" : "PATHS & PRIVACY")
                .plexEyebrow(size: 11, color: VocabbyTheme.tertiary)

            VStack(alignment: .leading, spacing: 6) {
                pathRow(label: "Config file:", value: OMPPaths.configFile().path)
                pathRow(label: "Sessions directory:", value: OMPPaths.defaultSessionsDirectory.path)
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
        planModel = store.config.modelRoles.plan
        slowModel = store.config.modelRoles.slow
        smolModel = store.config.modelRoles.smol
        defaultModel = store.config.modelRoles.defaultRole
        prewalkEnabled = store.config.prewalkEnabled
    }

    private func saveChanges() {
        store.config.modelRoles.plan = planModel.trimmingCharacters(in: .whitespacesAndNewlines)
        store.config.modelRoles.slow = slowModel.trimmingCharacters(in: .whitespacesAndNewlines)
        store.config.modelRoles.smol = smolModel.trimmingCharacters(in: .whitespacesAndNewlines)
        store.config.modelRoles.defaultRole = defaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
        store.config.prewalkEnabled = prewalkEnabled

        do {
            try store.save()
            statusMessage = vi ? "Đã lưu cấu hình ~/.omp/agent/config.yml thành công" : "Saved configuration to config.yml successfully"
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = nil
        }
    }
}
