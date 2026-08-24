import SwiftUI

struct AllAgentsQuotaSection: View {
    @EnvironmentObject var settings: SettingsStore

    let rows: [AgentQuotaRow]
    let totalAgentCount: Int
    let onOpenAgent: (InstalledAgentID) -> Void

    private static let visibleRowLimit = 3
    private var vi: Bool { L10n.languageCode(settings.appLanguage) == "vi" }
    /// Giữ nguyên thứ tự do AllUsageOverview dựng (khớp tab strip provider).
    private var sortedRows: [AgentQuotaRow] { rows }

    var body: some View {
        if !sortedRows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    sectionTitle("Quota")
                    Spacer(minLength: 8)
                    Text(vi
                         ? "\(rows.count)/\(totalAgentCount) agent có quota"
                         : "\(rows.count)/\(totalAgentCount) agents with quota")
                        .font(.plexMono(10))
                        .foregroundStyle(VocabbyTheme.tertiary)
                }
                .padding(.bottom, 8)

                ForEach(Array(sortedRows.prefix(Self.visibleRowLimit))) { row in
                    Button { onOpenAgent(row.record.id) } label: { rowView(row) }
                        .buttonStyle(.plain)
                }

                let hiddenCount = max(0, sortedRows.count - Self.visibleRowLimit)
                if hiddenCount > 0 {
                    Button {
                        if let next = sortedRows.dropFirst(Self.visibleRowLimit).first {
                            onOpenAgent(next.record.id)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(vi ? "+\(hiddenCount) agent còn quota cao" : "+\(hiddenCount) more agents with high quota")
                                .font(.plexMono(10, weight: .medium))
                                .foregroundStyle(VocabbyTheme.tertiary)
                                .textCase(.uppercase)
                            Text("›")
                                .font(.plexSans(12))
                                .foregroundStyle(VocabbyTheme.tertiary)
                        }
                        .padding(.top, 7)
                    }
                    .buttonStyle(.plain)
                }
            }
            .popoverContentInset()
            .padding(.vertical, 14)
            // Chỉ kẻ line đỉnh — line đáy do section kế tiếp tự kẻ, tránh
            // double line với chrome rule của footer.
            .overlay(alignment: .top) { PopoverInsetHairline() }
        }
    }

    private func rowView(_ row: AgentQuotaRow) -> some View {
        let percent = row.remainingPct ?? 0
        let tint = percent < 20 ? VocabbyTheme.critical : VocabbyTheme.success
        return HStack(spacing: 8) {
            ProviderLogoMark(id: row.record.id.rawValue)
                .frame(width: 16, height: 16)
            Text(row.record.displayName)
                .font(.plexSans(13, weight: .medium))
                .foregroundStyle(VocabbyTheme.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(row.windowLabel.uppercased())
                .font(.plexMono(9))
                .foregroundStyle(VocabbyTheme.tertiary)
                .lineLimit(1)
            ZStack(alignment: .leading) {
                Rectangle().fill(VocabbyTheme.track)
                Rectangle().fill(tint).frame(width: 56 * CGFloat(percent) / 100)
            }
            .frame(width: 56, height: 3)
            Text("\(percent)%")
                .font(.plexMono(12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, alignment: .trailing)
            Text("›")
                .font(.plexSans(12))
                .foregroundStyle(VocabbyTheme.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.plexMono(10, weight: .medium))
            .foregroundStyle(VocabbyTheme.tertiary)
    }
}
