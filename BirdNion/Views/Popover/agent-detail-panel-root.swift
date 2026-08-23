import SwiftUI

struct AgentDetailPanelRoot: View {
    @EnvironmentObject var settings: SettingsStore
    let snapshot: AgentDetailSnapshot

    enum Tab: String, CaseIterable {
        case quota, cost, config
    }

    @State private var selectedTab: Tab = .cost
    private var vi: Bool { L10n.languageCode(settings.appLanguage) == "vi" }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    switch selectedTab {
                    case .quota:
                        quotaTabContent
                    case .cost:
                        costTabContent
                    case .config:
                        configTabContent
                    }
                }
                .padding(.horizontal, 14)
            }
            footer
        }
        .frame(width: 340)
        .frame(minHeight: 460, maxHeight: 600)
        .background(VocabbyTheme.background)
        .overlay(
            Rectangle()
                .stroke(VocabbyTheme.primary, lineWidth: 1)
        )
        .onAppear {
            if snapshot.hasLocalCost || snapshot.costSummary != nil {
                selectedTab = .cost
            } else if snapshot.hasQuota {
                selectedTab = .quota
            } else {
                selectedTab = .config
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            monogramOrLogo
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.displayName)
                    .font(.plexSans(14, weight: .semibold))
                    .foregroundStyle(VocabbyTheme.primary)
                    .lineLimit(1)
                Text(effectiveSubtitle.uppercased())
                    .font(.plexMono(10))
                    .foregroundStyle(VocabbyTheme.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                NotificationCenter.default.post(name: .birdnionCloseAgentDetail, object: nil)
            } label: {
                Text("×")
                    .font(.plexMono(16, weight: .regular))
                    .foregroundStyle(VocabbyTheme.tertiary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(vi ? "Đóng" : "Close")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            VocabbyTheme.primary.frame(height: 1)
        }
    }

    @ViewBuilder
    private var monogramOrLogo: some View {
        if hasBrandLogo(snapshot.id) {
            ProviderLogoMark(id: snapshot.id.rawValue)
        } else {
            Text(monogram(for: snapshot.id))
                .font(.plexMono(9, weight: .semibold))
                .foregroundStyle(VocabbyTheme.secondary)
                .frame(width: 16, height: 16)
                .overlay {
                    Rectangle().stroke(VocabbyTheme.border, lineWidth: 1)
                }
        }
    }

    private var effectiveSubtitle: String {
        if !snapshot.subtitle.isEmpty { return snapshot.subtitle }
        let type = snapshot.id == .kiro || snapshot.id == .cursor ? "IDE" : (snapshot.hasLocalCost ? "CLI" : "Config")
        let src = snapshot.sourceName.isEmpty ? "Claude" : snapshot.sourceName
        return "\(type) · \(vi ? "chạy trên" : "runs on") \(src)"
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 6) {
            tabButton(
                tab: .quota,
                label: snapshot.hasQuota ? "Quota" : (vi ? "Quota — không" : "Quota — none"),
                isEnabled: snapshot.hasQuota
            )
            tabButton(
                tab: .cost,
                label: (snapshot.hasLocalCost || snapshot.costSummary != nil) ? (vi ? "Chi phí" : "Cost") : (vi ? "Chi phí — không" : "Cost — none"),
                isEnabled: snapshot.hasLocalCost || snapshot.costSummary != nil
            )
            tabButton(
                tab: .config,
                label: "Config",
                isEnabled: true
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            VocabbyTheme.hairline.frame(height: 1)
        }
    }

    private func tabButton(tab: Tab, label: String, isEnabled: Bool) -> some View {
        Button {
            if isEnabled { selectedTab = tab }
        } label: {
            Text(label.uppercased())
                .font(.plexMono(9, weight: selectedTab == tab ? .semibold : .medium))
                .foregroundStyle(
                    !isEnabled
                        ? VocabbyTheme.track
                        : (selectedTab == tab ? VocabbyTheme.primary : VocabbyTheme.secondary)
                )
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .overlay(
                    Rectangle()
                        .stroke(
                            !isEnabled
                                ? VocabbyTheme.border
                                : (selectedTab == tab ? VocabbyTheme.primary : VocabbyTheme.border),
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    // MARK: - Cost Tab Content

    private var costTabContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            costHeroSection
            if !snapshot.models.isEmpty {
                modelsSection
            }
            sourceSection
            if let log = effectiveLogPath {
                localLogSection(log)
            }
        }
    }

    private var costHeroSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(vi ? "CHI PHÍ 90 NGÀY" : "90-DAY COST")
                        .font(.plexMono(10, weight: .medium))
                        .foregroundStyle(VocabbyTheme.tertiary)
                    Text(AllUsageFormat.usd(snapshot.costSummary?.last30USD ?? 0))
                        .font(.plexMono(26, weight: .semibold))
                        .foregroundStyle(VocabbyTheme.primary)
                        .tracking(-0.8)
                    Text(AllUsageFormat.tokens(snapshot.costSummary?.last30Tokens ?? 0))
                        .font(.plexMono(11))
                        .foregroundStyle(VocabbyTheme.tertiary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(vi ? "HÔM NAY" : "TODAY")
                        .font(.plexMono(10, weight: .medium))
                        .foregroundStyle(VocabbyTheme.tertiary)
                    Text(AllUsageFormat.usd(snapshot.costSummary?.todayUSD ?? 0))
                        .font(.plexMono(14, weight: .semibold))
                        .foregroundStyle(VocabbyTheme.primary)
                }
            }

            miniAgentChart
                .frame(height: 44)
                .padding(.top, 4)
                .overlay(alignment: .bottom) {
                    VocabbyTheme.primary.frame(height: 1)
                }
        }
        .padding(.vertical, 14)
    }

    private var miniAgentChart: some View {
        let days = snapshot.recentActivity
        let maxTokens = max(days.map(\.tokens).max() ?? 1, 1)
        let agentColor = agentBrandColor(snapshot.id)

        return HStack(alignment: .bottom, spacing: 1) {
            if days.isEmpty {
                Rectangle().fill(VocabbyTheme.hairline).frame(height: 1)
            } else {
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    let fraction = day.tokens > 0 ? CGFloat(Double(day.tokens) / Double(maxTokens)) : 0
                    let height = max(44 * fraction, day.tokens > 0 ? 3 : 1)
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Rectangle()
                            .fill(day.tokens > 0 ? agentColor : VocabbyTheme.hairline)
                            .frame(height: height)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(vi ? "MODEL TRONG AGENT NÀY" : "MODELS IN THIS AGENT")
                .font(.plexMono(10, weight: .medium))
                .foregroundStyle(VocabbyTheme.tertiary)

            ForEach(snapshot.models) { model in
                HStack(spacing: 8) {
                    Rectangle()
                        .fill(agentBrandColor(snapshot.id))
                        .frame(width: 6, height: 6)
                    Text(model.name)
                        .font(.plexSans(12))
                        .foregroundStyle(VocabbyTheme.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    ZStack(alignment: .leading) {
                        Rectangle().fill(VocabbyTheme.hairline)
                        Rectangle().fill(agentBrandColor(snapshot.id)).frame(width: 48 * CGFloat(model.percentage) / 100)
                    }
                    .frame(width: 48, height: 3)
                    Text("\(AllUsageFormat.tokensShort(model.tokens)) · \(AllUsageFormat.usd(model.usd))")
                        .font(.plexMono(10))
                        .foregroundStyle(VocabbyTheme.tertiary)
                        .frame(width: 76, alignment: .trailing)
                }
                .padding(.vertical, 3)
            }
        }
        .padding(.vertical, 14)
        .overlay(alignment: .top) { VocabbyTheme.hairline.frame(height: 1) }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(vi ? "NGUỒN" : "SOURCE")
                .font(.plexMono(10, weight: .medium))
                .foregroundStyle(VocabbyTheme.tertiary)

            HStack(spacing: 8) {
                ProviderLogoMark(id: effectiveSourceID)
                    .frame(width: 16, height: 16)
                Text(effectiveSourceName)
                    .font(.plexSans(13, weight: .medium))
                    .foregroundStyle(VocabbyTheme.primary)
                Spacer(minLength: 8)
                Text(effectiveSourceType.uppercased())
                    .font(.plexMono(10))
                    .foregroundStyle(VocabbyTheme.tertiary)
            }
            .padding(.vertical, 4)

            Text(vi
                 ? "Quota của agent này tính vào quota \(effectiveSourceName) — xem ở tab \(effectiveSourceName)."
                 : "Quota for this agent counts toward \(effectiveSourceName) — view under the \(effectiveSourceName) tab.")
                .font(.plexMono(10))
                .foregroundStyle(VocabbyTheme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .padding(.vertical, 14)
        .overlay(alignment: .top) { VocabbyTheme.hairline.frame(height: 1) }
    }

    private func localLogSection(_ path: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(vi ? "LOG CỤC BỘ" : "LOCAL LOG")
                .font(.plexMono(10, weight: .medium))
                .foregroundStyle(VocabbyTheme.tertiary)
            Text(path)
                .font(.plexMono(11))
                .foregroundStyle(VocabbyTheme.secondary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 14)
        .overlay(alignment: .top) { VocabbyTheme.hairline.frame(height: 1) }
    }

    // MARK: - Config Tab Content

    private var configTabContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !snapshot.hasLocalCost && snapshot.costSummary == nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text(vi ? "Agent này không ghi log cục bộ." : "This agent does not write local logs.")
                        .font(.plexSans(15, weight: .semibold))
                        .foregroundStyle(VocabbyTheme.primary)
                    Text(vi
                         ? "BirdNion đọc được cấu hình và kiểm tra kết nối, nhưng không có số liệu chi phí hay quota để hiển thị. Chi phí thực tế nằm ở tài khoản nguồn bên dưới."
                         : "BirdNion detects configuration and tests connection health, but has no local cost logs or quota to display. Actual usage resides on the upstream account.")
                        .font(.plexSans(12))
                        .foregroundStyle(VocabbyTheme.secondary)
                        .lineSpacing(2)
                }
                .padding(.vertical, 16)
            }

            sourceSection

            if let config = effectiveConfigPath {
                VStack(alignment: .leading, spacing: 6) {
                    Text(vi ? "CẤU HÌNH" : "CONFIGURATION")
                        .font(.plexMono(10, weight: .medium))
                        .foregroundStyle(VocabbyTheme.tertiary)
                    Text(config)
                        .font(.plexMono(11))
                        .foregroundStyle(VocabbyTheme.secondary)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 14)
                .overlay(alignment: .top) { VocabbyTheme.hairline.frame(height: 1) }
            }
        }
    }

    // MARK: - Quota Tab Content

    private var quotaTabContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let status = snapshot.providerStatus, !status.windows.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(vi ? "QUOTA HIỆN TẠI" : "CURRENT QUOTA")
                        .font(.plexMono(10, weight: .medium))
                        .foregroundStyle(VocabbyTheme.tertiary)
                    ForEach(status.windows) { window in
                        HStack {
                            Text(window.label.uppercased())
                                .font(.plexMono(11))
                                .foregroundStyle(VocabbyTheme.secondary)
                            Spacer()
                            ZStack(alignment: .leading) {
                                Rectangle().fill(VocabbyTheme.hairline)
                                Rectangle()
                                    .fill(window.remainingPct < 20 ? VocabbyTheme.critical : VocabbyTheme.success)
                                    .frame(width: 56 * CGFloat(window.remainingPct) / 100)
                            }
                            .frame(width: 56, height: 3)
                            Text("\(window.remainingPct)%")
                                .font(.plexMono(12, weight: .semibold))
                                .foregroundStyle(window.remainingPct < 20 ? VocabbyTheme.critical : VocabbyTheme.success)
                                .frame(width: 38, alignment: .trailing)
                        }
                        .padding(.vertical, 4)
                    }
                }
            } else {
                Text(vi ? "Không có quota trực tiếp." : "No direct quota surface.")
                    .font(.plexSans(12))
                    .foregroundStyle(VocabbyTheme.secondary)
            }
            sourceSection
        }
        .padding(.vertical, 14)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text((snapshot.hasLocalCost || snapshot.costSummary != nil
                  ? (vi ? "Quét gần đây" : "Recently scanned")
                  : (vi ? "Chỉ có config" : "Config only")).uppercased())
                .font(.plexMono(10, weight: .medium))
                .foregroundStyle(VocabbyTheme.tertiary)
            Spacer()
            Button {
                NotificationCenter.default.post(name: .openAgentsTab, object: nil)
                NotificationCenter.default.post(name: .openSettings, object: nil)
            } label: {
                Text(vi ? "CẤU HÌNH" : "CONFIGURE")
                    .font(.plexMono(10, weight: .medium))
                    .foregroundStyle(VocabbyTheme.primary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .overlay(
                        Rectangle().stroke(VocabbyTheme.primary, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .overlay(alignment: .top) {
            VocabbyTheme.primary.frame(height: 1)
        }
    }

    // MARK: - Helpers

    private var effectiveSourceID: String {
        switch snapshot.id {
        case .claude, .aider: return "claude"
        case .codex: return "codex"
        case .grok: return "grok"
        case .kiro: return "kiro"
        case .opencode, .pi: return "openrouter"
        default: return snapshot.record.providerIDs.first ?? "openrouter"
        }
    }

    private var effectiveSourceName: String {
        switch snapshot.id {
        case .claude, .aider: return "Claude"
        case .codex: return "Codex"
        case .grok: return "Grok"
        case .kiro: return "Kiro"
        case .opencode, .pi: return "OpenRouter"
        default: return snapshot.sourceName.isEmpty ? "Claude" : snapshot.sourceName
        }
    }

    private var effectiveSourceType: String {
        switch snapshot.id {
        case .claude, .aider: return "OAuth · Max 20x"
        case .codex: return "OAuth"
        case .grok: return "Zero-config"
        case .kiro: return "OAuth"
        case .opencode, .pi: return "API key"
        default: return "API key"
        }
    }

    private var effectiveLogPath: String? {
        if let p = snapshot.logPath { return p }
        return snapshot.evidence.first(where: { $0.kind == .applicationState })?.token
    }

    private var effectiveConfigPath: String? {
        if let p = snapshot.configPath { return p }
        return snapshot.evidence.first(where: { $0.kind == .configuration })?.token
    }

    private func agentBrandColor(_ id: InstalledAgentID) -> Color {
        switch id {
        case .claude: return VocabbyTheme.chartClaude
        case .codex: return VocabbyTheme.chartCodex
        case .grok: return VocabbyTheme.chartGrok
        case .kiro: return VocabbyTheme.chartKiro
        case .omp: return VocabbyTheme.chartOMP
        case .pi: return VocabbyTheme.chartPi
        default: return VocabbyTheme.primary
        }
    }

    private func hasBrandLogo(_ id: InstalledAgentID) -> Bool {
        switch id {
        case .claude, .codex, .kiro, .opencode, .grok, .gemini, .cursor: return true
        default: return false
        }
    }

    private func monogram(for id: InstalledAgentID) -> String {
        switch id {
        case .aider: return "A"
        case .pi: return "P"
        case .omp: return "OM"
        case .cursor: return "C"
        case .gemini: return "G"
        case .antigravity: return "AG"
        case .copilot: return "CP"
        case .auggie: return "AU"
        case .amp: return "AM"
        case .qwen: return "Q"
        case .goose: return "GS"
        default: return String(id.displayName.prefix(1)).uppercased()
        }
    }
}
