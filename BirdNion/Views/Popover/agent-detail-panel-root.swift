import SwiftUI

struct AgentDetailPanelRoot: View {
    @EnvironmentObject var settings: SettingsStore
    let snapshot: AgentDetailSnapshot

    enum Tab: String, CaseIterable {
        case quota, cost, config
    }

    /// Tab mở đầu theo NGUỒN click (quota row → "quota", cost row → "cost",
    /// configured row → "config"); nil = heuristics theo capability.
    var initialTab: String? = nil

    @State private var selectedTab: Tab = .cost
    /// Cửa sổ thời gian của chart chi phí trong panel — mặc định 30 ngày.
    @State private var agentPeriodDays = 30
    /// Ngày được click-pin trên chart — filter list model theo đúng ngày đó.
    @State private var selectedDay: Date?
    /// Cap danh sách model để panel height-auto không vượt màn hình.
    private static let maxModelRows = 8
    private var vi: Bool { L10n.languageCode(settings.appLanguage) == "vi" }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar
            // Height auto theo nội dung (không scroll) — đổi tab thì nhờ
            // coordinator refit lại khung panel theo fitting size mới.
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
            footer
        }
        .frame(width: 340)
        .background(VocabbyTheme.background)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        // Viền xám nhạt cho mọi popover (quy ước 2026-08-24).
        .overlay(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .stroke(VocabbyTheme.border, lineWidth: 1)
        )
        .onAppear {
            // Ưu tiên tab theo nguồn click; fallback heuristics capability.
            switch initialTab {
            case "quota" where snapshot.hasQuota:
                selectedTab = .quota
            case "cost" where snapshot.hasLocalCost || snapshot.costSummary != nil:
                selectedTab = .cost
            case "config":
                selectedTab = .config
            default:
                if snapshot.hasLocalCost || snapshot.costSummary != nil {
                    selectedTab = .cost
                } else if snapshot.hasQuota {
                    selectedTab = .quota
                } else {
                    selectedTab = .config
                }
            }
        }
        .onChange(of: selectedTab) { _ in
            NotificationCenter.default.post(name: .birdnionAgentPanelRefit, object: nil)
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
            // Icon mở Settings → tab Agent (nút Configure dạng icon).
            Button {
                openAgentSettings(id: snapshot.id)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(VocabbyTheme.secondary)
                    .frame(width: 24, height: 24)
                    .overlay(
                        RoundedRectangle(cornerRadius: InstrumentShape.controlRadius)
                            .stroke(VocabbyTheme.border, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(vi ? "Cấu hình trong Settings" : "Configure in Settings")

            // Nút đóng theo ngôn ngữ Instrument (ô vuông viền hairline).
            Button {
                NotificationCenter.default.post(name: .birdnionCloseAgentDetail, object: nil)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(VocabbyTheme.secondary)
                    .frame(width: 24, height: 24)
                    .overlay(
                        RoundedRectangle(cornerRadius: InstrumentShape.controlRadius)
                            .stroke(VocabbyTheme.border, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(vi ? "Đóng" : "Close")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            // Chrome rule top: đậm hơn hairline, full-bleed (quy ước 2026-08-24).
            VocabbyTheme.chromeRule.frame(height: 1)
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
        guard !snapshot.sourceName.isEmpty else { return type }
        return "\(type) · \(vi ? "chạy trên" : "runs on") \(snapshot.sourceName)"
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
        // Căn trái full-width như design gốc (VStack cha mặc định căn giữa).
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            VocabbyTheme.hairline.frame(height: 1).padding(.horizontal, 14)
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
        // Cửa sổ thời gian chọn được (7d/30d/90d) — hero, chart, mốc ngày
        // VÀ danh sách model đều bám theo cùng một window.
        let windowDays = Array(snapshot.recentActivity.suffix(agentPeriodDays))
        let models = windowModels(windowDays)
        // SOURCE + LOCAL LOG thuộc tab Config (yêu cầu 2026-08-24) — tab Cost
        // chỉ còn hero + chart + models. Click một cột chart → models chỉ của
        // ngày đó; click lại cột để bỏ filter.
        let filterDay = selectedDay.flatMap { sel in windowDays.first { $0.date == sel } }
        let shownModels = filterDay.map { windowModels([$0]) } ?? models
        return VStack(alignment: .leading, spacing: 0) {
            costHeroSection(windowDays: windowDays)
            if !shownModels.isEmpty {
                modelsSection(models: shownModels,
                              filterLabel: filterDay.map { dayLabel($0.date) })
            }
        }
    }

    /// Gộp model theo window đang chọn (thay cho snapshot.models cố định 90d).
    private func windowModels(_ days: [AgentDetailSnapshot.ActivityDay]) -> [AgentDetailSnapshot.ModelItem] {
        var totals: [String: (usd: Double, tokens: Int)] = [:]
        for m in days.flatMap(\.models) {
            if snapshot.record.id == .kiro,
               m.name == KiroCostScanner.aggregateModelName { continue }
            var t = totals[m.name] ?? (0, 0)
            t.usd += m.usd
            t.tokens += m.tokens
            totals[m.name] = t
        }
        let sorted = totals.sorted {
            if $0.value.tokens != $1.value.tokens { return $0.value.tokens > $1.value.tokens }
            return $0.value.usd > $1.value.usd
        }
        let totalTokens = max(sorted.reduce(0) { $0 + $1.value.tokens }, 1)
        return sorted.map { name, value in
            AgentDetailSnapshot.ModelItem(
                name: name,
                tokens: value.tokens,
                usd: value.usd,
                percentage: Int((Double(value.tokens) / Double(totalTokens) * 100).rounded()))
        }
    }

    @ViewBuilder
    private func costHeroSection(windowDays: [AgentDetailSnapshot.ActivityDay]) -> some View {
        if let summary = snapshot.costSummary {
            let windowUSD = windowDays.reduce(0) { $0 + $1.usd }
            let windowTokens = windowDays.reduce(0) { $0 + $1.tokens }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                    Text(vi
                         ? "CHI PHÍ \(windowDays.count) NGÀY"
                         : "\(windowDays.count)-DAY COST")
                        .font(.plexMono(10, weight: .medium))
                        .foregroundStyle(VocabbyTheme.tertiary)
                    Text(AllUsageFormat.usd(windowUSD))
                        .font(.plexMono(26, weight: .semibold))
                        .foregroundStyle(VocabbyTheme.primary)
                        .tracking(-0.8)
                    Text(AllUsageFormat.tokens(windowTokens))
                        .font(.plexMono(11))
                        .foregroundStyle(VocabbyTheme.tertiary)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 6) {
                        agentPeriodPicker
                        Text(vi ? "HÔM NAY" : "TODAY")
                            .font(.plexMono(10, weight: .medium))
                            .foregroundStyle(VocabbyTheme.tertiary)
                        Text(AllUsageFormat.usd(summary.todayUSD))
                            .font(.plexMono(14, weight: .semibold))
                            .foregroundStyle(VocabbyTheme.primary)
                    }
                }

                miniAgentChart(days: windowDays)
                    .frame(height: 56)
                    .padding(.top, 4)
                    .overlay(alignment: .bottom) {
                        VocabbyTheme.primary.frame(height: 1)
                    }
                // Mốc thời gian 2 đầu chart.
                if let first = windowDays.first, let last = windowDays.last {
                    HStack {
                        Text(dayLabel(first.date))
                            .font(.plexMono(9))
                            .foregroundStyle(VocabbyTheme.tertiary)
                        Spacer(minLength: 8)
                        Text(dayLabel(last.date))
                            .font(.plexMono(9))
                            .foregroundStyle(VocabbyTheme.tertiary)
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.vertical, 14)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(vi ? "CHI PHÍ CỤC BỘ" : "LOCAL COST")
                    .font(.plexMono(10, weight: .medium))
                    .foregroundStyle(VocabbyTheme.tertiary)
                Text(L10n.t("budget.perProvider.noData", settings.appLanguage))
                    .font(.plexSans(13, weight: .medium))
                    .foregroundStyle(VocabbyTheme.secondary)
            }
            .padding(.vertical, 16)
        }
    }

    private var agentPeriodPicker: some View {
        HStack(spacing: 4) {
            ForEach([7, 30, 90], id: \.self) { days in
                let active = agentPeriodDays == days
                Button {
                    agentPeriodDays = days
                    selectedDay = nil  // đổi window → bỏ filter ngày
                    // Nội dung đổi độ dài → nhờ coordinator refit panel.
                    NotificationCenter.default.post(name: .birdnionAgentPanelRefit, object: nil)
                } label: {
                    Text("\(days)d")
                        .font(.plexMono(9, weight: active ? .semibold : .medium))
                        .foregroundStyle(active ? VocabbyTheme.background : VocabbyTheme.secondary)
                        .frame(width: 30, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous)
                                .fill(active ? VocabbyTheme.primary : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous)
                                .stroke(active ? Color.clear : VocabbyTheme.border, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func dayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: vi ? "vi_VN" : "en_US")
        formatter.dateFormat = "d MMM"
        return formatter.string(from: date)
    }

    private func miniAgentChart(days: [AgentDetailSnapshot.ActivityDay]) -> some View {
        let maxTokens = max(days.map(\.tokens).max() ?? 1, 1)
        let agentColor = agentBrandColor(snapshot.id)

        return HStack(alignment: .bottom, spacing: 1) {
            if days.isEmpty {
                Rectangle().fill(VocabbyTheme.hairline).frame(height: 1)
            } else {
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    let fraction = day.tokens > 0 ? CGFloat(Double(day.tokens) / Double(maxTokens)) : 0
                    let height = max(56 * fraction, day.tokens > 0 ? 3 : 1)
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Rectangle()
                            .fill(day.tokens > 0 ? agentColor : VocabbyTheme.hairline)
                            .frame(height: height)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(selectedDay == day.date
                                ? VocabbyTheme.selectedSurface.opacity(0.7) : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Click cột = filter models theo ngày; click lại để bỏ.
                        selectedDay = (selectedDay == day.date) ? nil : day.date
                        NotificationCenter.default.post(name: .birdnionAgentPanelRefit, object: nil)
                    }
                    .help("\(dayLabel(day.date)): \(AllUsageFormat.tokens(day.tokens)) · \(AllUsageFormat.usd(day.usd))")
                }
            }
        }
    }

    private func modelsSection(models: [AgentDetailSnapshot.ModelItem],
                               filterLabel: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text((vi ? "MODEL TRONG AGENT NÀY" : "MODELS IN THIS AGENT")
                 + (filterLabel.map { " · \($0.uppercased())" } ?? ""))
                .font(.plexMono(10, weight: .medium))
                .foregroundStyle(filterLabel == nil ? VocabbyTheme.tertiary : VocabbyTheme.primary)

            // Cap danh sách để panel height-auto không vượt màn hình.
            ForEach(Array(models.prefix(Self.maxModelRows))) { model in
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
                        .font(.plexMono(10, weight: .semibold))
                        .foregroundStyle(VocabbyTheme.primary)
                        .frame(width: 76, alignment: .trailing)
                }
                .padding(.vertical, 3)
            }
            let rest = models.dropFirst(Self.maxModelRows)
            if !rest.isEmpty {
                HStack(spacing: 8) {
                    Rectangle().fill(VocabbyTheme.track).frame(width: 6, height: 6)
                    Text(vi ? "+\(rest.count) model khác" : "+\(rest.count) more models")
                        .font(.plexSans(10))
                        .foregroundStyle(VocabbyTheme.tertiary)
                    Spacer(minLength: 8)
                    Text("\(AllUsageFormat.tokensShort(rest.reduce(0) { $0 + $1.tokens })) · \(AllUsageFormat.usd(rest.reduce(0) { $0 + $1.usd }))")
                        .font(.plexMono(10))
                        .foregroundStyle(VocabbyTheme.tertiary)
                }
                .padding(.vertical, 3)
            }
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
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

            if snapshot.hasQuota, let bridge = snapshot.providerStatus {
                Text(vi
                     ? "Quota của agent này tính vào quota \(bridge.displayName) — xem ở tab \(bridge.displayName)."
                     : "Quota for this agent counts toward \(bridge.displayName) — view under the \(bridge.displayName) tab.")
                    .font(.plexMono(10))
                    .foregroundStyle(VocabbyTheme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
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
        .frame(maxWidth: .infinity, alignment: .leading)
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
                         ? "BirdNion chỉ phát hiện cấu hình cục bộ; agent này chưa có số liệu chi phí hoặc quota để hiển thị."
                         : "BirdNion only detects local configuration; this agent has no cost or quota evidence to display yet.")
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { VocabbyTheme.hairline.frame(height: 1) }
            }

            if let log = effectiveLogPath {
                localLogSection(log)
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
                            Text(L10n.windowLabel(window.label, preference: settings.appLanguage).uppercased())
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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .overlay(alignment: .top) {
            // Chrome rule foot: đậm hơn hairline, full-bleed.
            VocabbyTheme.chromeRule.frame(height: 1)
        }
    }

    // MARK: - Helpers

    private var effectiveSourceID: String {
        snapshot.providerStatus?.id
            ?? snapshot.record.providerIDs.first
            ?? snapshot.id.rawValue
    }

    private var effectiveSourceName: String {
        if !snapshot.sourceName.isEmpty { return snapshot.sourceName }
        return snapshot.providerStatus?.displayName ?? (vi ? "Chưa đặt" : "Unset")
    }

    private var effectiveSourceType: String {
        snapshot.sourceType.isEmpty ? (vi ? "Bằng chứng cục bộ" : "Local evidence") : snapshot.sourceType
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
        case .claude, .codex, .kiro, .opencode, .grok, .gemini, .cursor, .antigravity, .copilot, .aider, .amp, .auggie, .goose, .qwen, .omp, .pi: return true
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
