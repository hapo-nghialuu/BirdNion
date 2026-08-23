import SwiftUI

struct AgentsPane: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var installedAgents: InstalledAgentCatalog
    @EnvironmentObject var agentVisibility: InstalledAgentVisibilityStore

    @Binding var tab: SettingsTab
    @Binding var searchText: String

    enum AgentFilter: String, CaseIterable {
        case all, hasQuota, hasCost, configOnly
    }

    @State private var selectedFilter: AgentFilter = .all
    @State private var selectedAgentID: InstalledAgentID?
    @State private var localSearchText: String = ""
    @State private var historyDocument: CostHistoryStore.Document? = nil

    private var vi: Bool { L10n.languageCode(settings.appLanguage) == "vi" }
    private var query: String {
        let combined = searchText.isEmpty ? localSearchText : searchText
        return combined.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var allRecords: [InstalledAgentRecord] {
        installedAgents.records
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
        if query.isEmpty { return list }
        return list.filter { SettingsSearchIndex.installedAgentMatches($0, query: query) }
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selected: $tab, searchText: $searchText)

            SettingsPage {
                VStack(alignment: .leading, spacing: 0) {
                    // Header Title
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
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
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
                        Text(vi ? "BẬT" : "ENABLE")
                            .frame(width: 40, alignment: .leading)
                        Text("AGENT")
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
                    .overlay(alignment: .top) { VocabbyTheme.primary.frame(height: 1) }
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
                .padding(.vertical, 7)
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
        guard let source = id.costHistorySource else { return nil }
        guard let doc = historyDocument, let days = doc.sources?[source.rawValue], !days.isEmpty else {
            return nil
        }
        let total = days.values.reduce(0.0) { $0 + $1.usd }
        return total > 0 ? total : nil
    }

    private func loadHistory() {
        Task {
            let doc = await Task.detached(priority: .utility) {
                CostHistoryStore.read()
            }.value
            await MainActor.run {
                self.historyDocument = doc
            }
        }
    }

    private func applyPendingSelection() {
        if let requested = UserDefaults.standard.string(forKey: "settings.selectedAgentID"),
           let id = InstalledAgentID(rawValue: requested) {
            selectedAgentID = id
            UserDefaults.standard.removeObject(forKey: "settings.selectedAgentID")
        }
    }
}
