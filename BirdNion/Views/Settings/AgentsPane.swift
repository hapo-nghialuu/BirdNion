import SwiftUI

struct AgentsPane: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var installedAgents: InstalledAgentCatalog
    @EnvironmentObject var agentVisibility: InstalledAgentVisibilityStore
    @EnvironmentObject var quota: QuotaService

    @Binding var tab: SettingsTab
    @Binding var searchText: String

    enum AgentFilter: String, CaseIterable {
        case all, hasQuota, hasCost, configOnly
    }

    @State private var selectedFilter: AgentFilter = .all
    @State private var selectedAgentID: InstalledAgentID?
    @State private var localSearchText: String = ""
    @State private var historyDocument: CostHistoryStore.Document? = nil
    @State private var localSourceLabels: [InstalledAgentID: String] = [:]

    private var vi: Bool { L10n.languageCode(settings.appLanguage) == "vi" }
    private var query: String {
        let combined = searchText.isEmpty ? localSearchText : searchText
        return combined.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var allRecords: [InstalledAgentRecord] {
        installedAgents.records.map {
            $0.projected(
                providerStatuses: quota.displayStatuses,
                availableCostSources: historyCostSources)
        }
    }

    private var historyCostSources: Set<CostHistoryStore.Source> {
        let sources = historyDocument?.sources ?? [:]
        return Set(CostHistoryStore.Source.allCases.filter { source in
            sources[source.rawValue]?.values.contains { $0.usd > 0 || $0.tokens > 0 } == true
        })
    }

    private var quotaCount: Int {
        allRecords.filter { $0.capabilities.contains(.quota) }.count
    }

    private var costCount: Int {
        allRecords.filter { $0.capabilities.contains(.localCost) }.count
    }

    private var configOnlyCount: Int {
        allRecords.filter { !$0.capabilities.contains(.quota) && !$0.capabilities.contains(.localCost) }.count
    }

    private var filteredRecords: [InstalledAgentRecord] {
        let list: [InstalledAgentRecord]
        switch selectedFilter {
        case .all:
            list = allRecords
        case .hasQuota:
            list = allRecords.filter { $0.capabilities.contains(.quota) }
        case .hasCost:
            list = allRecords.filter { $0.capabilities.contains(.localCost) }
        case .configOnly:
            list = allRecords.filter { !$0.capabilities.contains(.quota) && !$0.capabilities.contains(.localCost) }
        }
        let matched = query.isEmpty
            ? list
            : list.filter { SettingsSearchIndex.installedAgentMatches($0, query: query) }
        return sortedByActivity(matched)
    }

    /// Agent đang bật (visible) lên trước, sau đó tới agent có dữ liệu thật,
    /// rồi mới đến phần còn lại — trong mỗi nhóm giữ thứ tự A→Z.
    private func sortedByActivity(_ list: [InstalledAgentRecord]) -> [InstalledAgentRecord] {
        list.sorted { lhs, rhs in
            let lv = agentVisibility.isVisible(lhs.id)
            let rv = agentVisibility.isVisible(rhs.id)
            if lv != rv { return lv }
            let lc = real90dCost(for: lhs.id) ?? 0
            let rc = real90dCost(for: rhs.id) ?? 0
            if (lc > 0) != (rc > 0) { return lc > 0 }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selected: $tab, searchText: $searchText)

            SettingsPage {
                VStack(alignment: .leading, spacing: 0) {
                    // Header Title (kèm icon Action Center bên phải)
                    HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(vi ? "Agent" : "Agents")
                            .font(.plexSans(22, weight: .bold))
                            .foregroundStyle(SettingsTheme.primary)
                            .tracking(-0.5)
                        Text(vi
                             ? "Mỗi agent khai báo có quota, có log chi phí, hay chỉ có cấu hình. BirdNion chỉ hiển thị đúng thứ agent đó cung cấp."
                             : "Each agent reports quota, local cost logs, or config only. BirdNion displays exactly what the agent provides.")
                            .font(.plexSans(13))
                            .foregroundStyle(SettingsTheme.secondary)
                            .lineSpacing(2)
                    }
                    Spacer(minLength: 8)
                    ActionCenterIconButton()
                    }
                    // Ép full-width: VStack .leading tự co theo text nên rule
                    // dưới tiêu đề bị hụt bên phải (2026-08-24).
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 16)
                    .overlay(alignment: .bottom) {
                        VocabbyTheme.primary.frame(height: 1)
                    }

                    // Search & Filter bar
                    HStack(spacing: 8) {
                        HStack(spacing: 7) {
                            Text("⌕")
                                .font(.plexMono(12))
                                .foregroundStyle(VocabbyTheme.tertiary)
                            TextField(vi ? "Tìm agent" : "Search agents", text: $localSearchText)
                                .textFieldStyle(.plain)
                                .font(.plexSans(12))
                        }
                        .padding(.horizontal, 8)
                        .frame(minHeight: InstrumentMetrics.controlHeight)
                        .overlay(
                            RoundedRectangle(cornerRadius: InstrumentShape.controlRadius)
                                .stroke(VocabbyTheme.border, lineWidth: 1)
                        )

                        filterButton(
                            filter: .all,
                            label: vi ? "Tất cả \(allRecords.count)" : "All \(allRecords.count)"
                        )
                        filterButton(
                            filter: .hasQuota,
                            label: vi ? "Có quota \(quotaCount)" : "Quota \(quotaCount)"
                        )
                        filterButton(
                            filter: .hasCost,
                            label: vi ? "Có chi phí \(costCount)" : "Cost \(costCount)"
                        )
                        filterButton(
                            filter: .configOnly,
                            label: vi ? "Chỉ config \(configOnlyCount)" : "Config \(configOnlyCount)"
                        )
                    }
                    .padding(.vertical, 14)

                    // Table Header
                    HStack(spacing: 12) {
                        Text(vi ? "HIỆN" : "SHOW")
                            .frame(width: 40, alignment: .leading)
                        Text(vi ? "AGENT" : "AGENT")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(vi ? "NGUỒN" : "SOURCE")
                            .frame(width: 110, alignment: .leading)
                        Text(vi ? "DỮ LIỆU" : "DATA")
                            .frame(width: 148, alignment: .leading)
                        Text(vi ? "90 NGÀY" : "90 DAYS")
                            .frame(width: 92, alignment: .trailing)
                        Spacer().frame(width: 14)
                    }
                    .font(.plexMono(9, weight: .medium))
                    .foregroundStyle(VocabbyTheme.tertiary)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 8)
                    // Rule chạy hết bề ngang bảng (yêu cầu 2026-08-24).
                    .overlay(alignment: .top) { VocabbyTheme.chromeRule.frame(height: 1) }
                    .overlay(alignment: .bottom) { VocabbyTheme.hairline.frame(height: 1) }

                    // Table Rows
                    if filteredRecords.isEmpty {
                        VStack(spacing: 8) {
                            Text(vi ? "Không tìm thấy agent nào." : "No agents found.")
                                .font(.plexSans(13))
                                .foregroundStyle(SettingsTheme.secondary)
                                .padding(.top, 24)
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        ForEach(filteredRecords) { record in
                            AgentInventoryRow(
                                record: record,
                                isVisible: agentVisibility.isVisible(record.id),
                                isSelected: selectedAgentID == record.id,
                                cost90dUSD: real90dCost(for: record.id),
                                sourceLabel: sourceLabel(for: record),
                                detailSnapshot: detailSnapshot(for: record),
                                language: settings.appLanguage,
                                onSelect: { selectedAgentID = record.id },
                                onVisibilityChange: { agentVisibility.setVisible($0, for: record.id) }
                            )
                        }
                    }

                    // Bottom Bar
                    HStack {
                        Text(vi ? "Còn \(filteredRecords.count) agent — cuộn để xem" : "\(filteredRecords.count) agents total")
                            .font(.plexMono(11))
                            .foregroundStyle(VocabbyTheme.tertiary)
                        Spacer()
                    }
                    .padding(.top, 14)
                }
                .padding(24)
            }
        }
        .background(SettingsTheme.background)
        .onAppear {
            applyPendingSelection()
            loadHistory()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAgentsTab)) { _ in
            applyPendingSelection()
            loadHistory()
        }
    }

    private func filterButton(filter: AgentFilter, label: String) -> some View {
        let active = selectedFilter == filter
        return Button {
            selectedFilter = filter
        } label: {
            Text(label.uppercased())
                .font(.plexMono(10, weight: active ? .semibold : .medium))
                .foregroundStyle(active ? VocabbyTheme.background : VocabbyTheme.secondary)
                .padding(.horizontal, 11)
                .frame(minHeight: InstrumentMetrics.controlHeight)
                .background(
                    RoundedRectangle(cornerRadius: InstrumentShape.controlRadius)
                        .fill(active ? VocabbyTheme.primary : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: InstrumentShape.controlRadius)
                        .stroke(active ? Color.clear : VocabbyTheme.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func real90dCost(for id: InstalledAgentID) -> Double? {
        real90dTotals(for: id)?.usd
    }

    private func real90dTotals(for id: InstalledAgentID) -> (usd: Double, tokens: Int)? {
        guard let source = id.costHistorySource else { return nil }
        guard let doc = historyDocument, let days = doc.sources?[source.rawValue], !days.isEmpty else {
            return nil
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let cutoff = calendar.date(byAdding: .day, value: -89, to: today) ?? today
        let total = days.reduce(into: (usd: 0.0, tokens: 0)) { partial, entry in
            guard let date = CostHistoryStore.parseDayKey(entry.key, calendar: calendar),
                  date >= cutoff,
                  date <= today
            else { return }
            partial.usd += entry.value.usd
            partial.tokens += entry.value.tokens
        }
        return total.usd > 0 || total.tokens > 0 ? total : nil
    }

    private func detailSnapshot(for record: InstalledAgentRecord) -> AgentDetailSnapshot {
        let status = quota.displayStatuses.first { status in
            record.providerIDs.contains(status.id) || status.id == record.id.rawValue
        }
        let totals = real90dTotals(for: record.id)
        let summary = totals.map {
            AgentDetailSnapshot.CostSummary(
                todayUSD: 0,
                todayTokens: 0,
                periodUSD: $0.usd,
                periodTokens: $0.tokens,
                periodDays: 90,
                topModel: nil,
                confidence: .init(included: true, live: false, scannedAt: nil))
        }
        let label = sourceLabel(for: record)
        let unset = vi ? "Chưa đặt" : "Unset"
        return AgentDetailSnapshot(
            record: record,
            providerStatus: status,
            configuredProviders: [],
            costSummary: summary,
            sourceName: label == unset ? "" : label,
            sourceType: status == nil ? "Local evidence" : "Provider status",
            logPath: record.evidence.first { $0.kind == .applicationState }?.token,
            configPath: record.evidence.first { $0.kind == .configuration }?.token,
            subtitle: record.displayName)
    }

    private func loadHistory() {
        Task {
            let loaded = await Task.detached(priority: .utility) {
                let omp = OMPAgentConfigStore.load().modelRoles.defaultRole
                let pi = PiAgentConfigStore.load().defaultProvider
                return (
                    document: CostHistoryStore.read(),
                    labels: [
                        InstalledAgentID.omp: omp,
                        InstalledAgentID.pi: pi,
                    ].filter { !$0.value.isEmpty })
            }.value
            await MainActor.run {
                self.historyDocument = loaded.document
                self.localSourceLabels = loaded.labels
            }
        }
    }

    private func sourceLabel(for record: InstalledAgentRecord) -> String {
        if let local = localSourceLabels[record.id], !local.isEmpty {
            return local
        }
        if let status = quota.displayStatuses.first(where: { status in
            record.providerIDs.contains(status.id) || status.id == record.id.rawValue
        }) {
            if let label = status.sourceLabel, !label.isEmpty { return label }
            return status.displayName
        }
        return vi ? "Chưa đặt" : "Unset"
    }

    private func applyPendingSelection() {
        if let requested = UserDefaults.standard.string(forKey: "settings.selectedAgentID"),
           let id = InstalledAgentID(rawValue: requested) {
            selectedAgentID = id
            UserDefaults.standard.removeObject(forKey: "settings.selectedAgentID")
        }
    }
}
