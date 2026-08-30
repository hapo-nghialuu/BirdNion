import SwiftUI

struct AllAgentsQuotaSection: View {
    @EnvironmentObject var settings: SettingsStore

    let rows: [AgentQuotaRow]
    let onOpenProvider: (String) -> Void

    private static let visibleRowLimit = 3
    private var vi: Bool { L10n.languageCode(settings.appLanguage) == "vi" }

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    sectionTitle(vi ? "Lịch quota" : "Quota agenda")
                    Spacer(minLength: 8)
                    Text(vi ? "\(rows.count) provider" : "\(rows.count) providers")
                        .font(.plexMono(10))
                        .foregroundStyle(VocabbyTheme.tertiary)
                }
                .padding(.bottom, 7)

                ForEach(Array(rows.prefix(Self.visibleRowLimit))) { row in
                    Button { onOpenProvider(row.projection.providerID) } label: {
                        rowView(row)
                    }
                    .buttonStyle(.plain)
                }

                let hiddenCount = max(0, rows.count - Self.visibleRowLimit)
                if hiddenCount > 0 {
                    Button {
                        if let next = rows.dropFirst(Self.visibleRowLimit).first {
                            onOpenProvider(next.projection.providerID)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(vi
                                 ? "+\(hiddenCount) provider khác"
                                 : "+\(hiddenCount) more providers")
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
            .padding(.vertical, 13)
            .overlay(alignment: .top) { PopoverInsetHairline() }
        }
    }

    private func rowView(_ row: AgentQuotaRow) -> some View {
        let agenda = row.projection
        return HStack(alignment: .top, spacing: 8) {
            ProviderLogoMark(id: agenda.providerID)
                .frame(width: 16, height: 16)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(row.record.displayName)
                        .font(.plexSans(12, weight: .semibold))
                        .foregroundStyle(VocabbyTheme.primary)
                    if agenda.providerName != row.record.displayName {
                        Text("· \(agenda.providerName)")
                            .font(.plexMono(9))
                            .foregroundStyle(VocabbyTheme.tertiary)
                    }
                }
                .lineLimit(1)

                HStack(spacing: 5) {
                    Text(L10n.windowLabel(
                        agenda.windowLabel,
                        preference: settings.appLanguage).uppercased())
                        .font(.plexMono(9, weight: .medium))
                        .foregroundStyle(VocabbyTheme.secondary)
                    Text("·")
                        .font(.plexMono(9))
                        .foregroundStyle(VocabbyTheme.tertiary)
                    Text(resetText(agenda.resetState))
                        .font(.plexMono(9, weight: .medium))
                        .foregroundStyle(resetTone(agenda.resetState))
                        .lineLimit(1)
                }

                Text(metadataText(agenda.metadata))
                    .font(.plexMono(8))
                    .foregroundStyle(VocabbyTheme.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }

            Spacer(minLength: 6)
            remainingView(agenda.remaining)
            Text("›")
                .font(.plexSans(12))
                .foregroundStyle(VocabbyTheme.tertiary)
                .padding(.top, 5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(row))
    }

    @ViewBuilder
    private func remainingView(_ remaining: QuotaAgendaRemaining) -> some View {
        switch remaining {
        case let .current(percent):
            Text("\(percent)%")
                .font(.plexMono(13, weight: .semibold))
                .foregroundStyle(VocabbyTheme.quotaColor(remaining: percent))
                .frame(minWidth: 34, alignment: .trailing)
        case .unavailable:
            Text("—")
                .font(.plexMono(13, weight: .semibold))
                .foregroundStyle(VocabbyTheme.tertiary)
                .frame(minWidth: 34, alignment: .trailing)
        case let .lastKnown(percent):
            VStack(alignment: .trailing, spacing: 0) {
                Text("\(percent)%")
                    .font(.plexMono(12, weight: .semibold))
                    .foregroundStyle(VocabbyTheme.warningFill)
                Text(vi ? "SỐ CŨ" : "LAST")
                    .font(.plexMono(7, weight: .medium))
                    .foregroundStyle(VocabbyTheme.tertiary)
            }
            .frame(minWidth: 34, alignment: .trailing)
        }
    }

    private func resetText(_ state: QuotaAgendaResetState) -> String {
        switch state {
        case let .scheduled(date):
            L10n.resetCountdown(to: date, preference: settings.appLanguage)
        case .awaitingRefresh:
            vi ? "Đợi dữ liệu sau reset" : "Awaiting post-reset data"
        case .unknown:
            vi ? "Chưa rõ lịch reset" : "Reset schedule unknown"
        case .staleLastKnown:
            vi ? "Chưa xác nhận reset kế" : "Next reset unconfirmed"
        }
    }

    private func resetTone(_ state: QuotaAgendaResetState) -> Color {
        switch state {
        case .scheduled: VocabbyTheme.blue
        case .awaitingRefresh, .staleLastKnown: VocabbyTheme.warningFill
        case .unknown: VocabbyTheme.tertiary
        }
    }

    private func metadataText(_ metadata: QuotaAgendaMetadata) -> String {
        let source = metadata.sourceLabel.map {
            L10n.providerText($0, preference: settings.appLanguage)
        } ?? (vi ? "Nguồn ?" : "Source ?")
        let account: String
        switch metadata.account {
        case let .named(label): account = label
        case .hidden: account = vi ? "Tài khoản ẩn" : "Account hidden"
        case .unknown: account = vi ? "Tài khoản ?" : "Account ?"
        }
        let relative = L10n.relativeUpdated(
            from: metadata.observedAt,
            preference: settings.appLanguage)
        let freshness = metadata.isStale
            ? (vi ? "số cũ \(relative)" : "last known \(relative)")
            : (vi ? "cập nhật \(relative)" : "updated \(relative)")
        return [source, account, freshness].joined(separator: " · ")
    }

    private func accessibilityLabel(_ row: AgentQuotaRow) -> String {
        let agenda = row.projection
        let remaining: String
        switch agenda.remaining {
        case let .current(percent): remaining = "\(percent)%"
        case .unavailable: remaining = vi ? "chưa có phần trăm hiện tại" : "current percent unavailable"
        case let .lastKnown(percent):
            remaining = vi ? "số cũ \(percent)%" : "last known \(percent)%"
        }
        return [
            agenda.providerName,
            row.record.displayName,
            L10n.windowLabel(agenda.windowLabel, preference: settings.appLanguage),
            remaining,
            resetText(agenda.resetState),
            metadataText(agenda.metadata),
        ].joined(separator: ", ")
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.plexMono(10, weight: .medium))
            .foregroundStyle(VocabbyTheme.tertiary)
    }
}
