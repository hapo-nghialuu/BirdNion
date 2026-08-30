import SwiftUI

struct QuotaAgendaPanelItem: Equatable, Identifiable {
    let agentName: String
    let projection: QuotaAgendaProjection

    var id: String { projection.providerID }
}

struct QuotaAgendaPanelRoot: View {
    @EnvironmentObject var settings: SettingsStore

    let items: [QuotaAgendaPanelItem]
    let onSelectProvider: (String) -> Void
    let onClose: () -> Void

    private static let rowLimit = 3
    private var vi: Bool { L10n.languageCode(settings.appLanguage) == "vi" }

    var body: some View {
        VStack(spacing: 0) {
            header
            if items.isEmpty { emptyState } else { agendaRows }
            trustFooter
        }
        .frame(width: 340)
        .background(VocabbyTheme.background)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .stroke(VocabbyTheme.border, lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(VocabbyTheme.blue)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(vi ? "Lịch quota" : "Quota Agenda")
                    .font(.plexSans(14, weight: .semibold))
                    .foregroundStyle(VocabbyTheme.primary)
                Text(vi ? "\(items.count) provider có dữ liệu" : "\(items.count) providers with data")
                    .font(.plexMono(10))
                    .foregroundStyle(VocabbyTheme.tertiary)
            }
            Spacer(minLength: 8)
            Button(action: onClose) {
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
            .help(vi ? "Đóng lịch quota" : "Close Quota Agenda")
            .accessibilityLabel(vi ? "Đóng lịch quota" : "Close Quota Agenda")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { VocabbyTheme.chromeRule.frame(height: 1) }
    }

    private var agendaRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.prefix(Self.rowLimit))) { item in
                Button { onSelectProvider(item.projection.providerID) } label: {
                    agendaRow(item)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel(item))
            }
            let hiddenCount = max(0, items.count - Self.rowLimit)
            if hiddenCount > 0, let next = items.dropFirst(Self.rowLimit).first {
                Button { onSelectProvider(next.projection.providerID) } label: {
                    HStack(spacing: 6) {
                        Text(vi ? "+\(hiddenCount) provider khác" : "+\(hiddenCount) more providers")
                            .font(.plexMono(10, weight: .medium))
                            .foregroundStyle(VocabbyTheme.tertiary)
                            .textCase(.uppercase)
                        Text("›").font(.plexSans(12)).foregroundStyle(VocabbyTheme.tertiary)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func agendaRow(_ item: QuotaAgendaPanelItem) -> some View {
        let agenda = item.projection
        return HStack(alignment: .top, spacing: 8) {
            ProviderLogoMark(id: agenda.providerID)
                .frame(width: 16, height: 16)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(item.agentName)
                        .font(.plexSans(12, weight: .semibold))
                        .foregroundStyle(VocabbyTheme.primary)
                    if item.agentName != agenda.providerName {
                        Text("· \(agenda.providerName)")
                            .font(.plexMono(9))
                            .foregroundStyle(VocabbyTheme.tertiary)
                    }
                }
                .lineLimit(1)
                Text(resetLine(agenda))
                    .font(.plexMono(9, weight: .medium))
                    .foregroundStyle(resetTone(agenda.resetState))
                    .lineLimit(1)
                Text(metadataText(agenda.metadata))
                    .font(.plexMono(9))
                    .foregroundStyle(VocabbyTheme.tertiary)
                    .lineLimit(1)
                    .help(metadataText(agenda.metadata))
            }
            Spacer(minLength: 6)
            remainingView(agenda.remaining)
                .font(.plexMono(12, weight: .semibold))
                .frame(minWidth: 34, alignment: .trailing)
            Text("›")
                .font(.plexSans(12))
                .foregroundStyle(VocabbyTheme.tertiary)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(VocabbyTheme.tertiary)
            Text(vi ? "Chưa có lịch reset rõ ràng" : "No explicit reset schedule yet")
                .font(.plexSans(12, weight: .medium))
                .foregroundStyle(VocabbyTheme.secondary)
            Text(vi ? "Làm mới provider để kiểm tra lại." : "Refresh providers to check again.")
                .font(.plexMono(9))
                .foregroundStyle(VocabbyTheme.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 130)
        .accessibilityElement(children: .combine)
    }

    private var trustFooter: some View {
        HStack {
            Text(vi ? "CHỈ DÙNG MỐC RESET ĐƯỢC XÁC NHẬN" : "EXPLICIT RESET TIMES ONLY")
                .font(.plexMono(9, weight: .medium))
                .foregroundStyle(VocabbyTheme.tertiary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .overlay(alignment: .top) { VocabbyTheme.chromeRule.frame(height: 1) }
    }

    @ViewBuilder
    private func remainingView(_ remaining: QuotaAgendaRemaining) -> some View {
        switch remaining {
        case let .current(percent):
            Text("\(percent)%")
                .foregroundStyle(percentTone(percent))
        case .unavailable:
            Text("—").foregroundStyle(VocabbyTheme.tertiary)
        case let .lastKnown(percent):
            Text("\(percent)%*").foregroundStyle(VocabbyTheme.tertiary)
        }
    }

    private func resetLine(_ agenda: QuotaAgendaProjection) -> String {
        let window = L10n.windowLabel(agenda.windowLabel, preference: settings.appLanguage)
        return "\(window.uppercased()) · \(resetText(agenda.resetState))"
    }

    private func resetText(_ state: QuotaAgendaResetState) -> String {
        switch state {
        case let .scheduled(date): return L10n.resetCountdown(to: date, preference: settings.appLanguage)
        case .awaitingRefresh: return vi ? "Đợi dữ liệu sau reset" : "Awaiting post-reset data"
        case .unknown: return vi ? "Chưa rõ lịch reset" : "Reset schedule unknown"
        case .staleLastKnown: return vi ? "Chưa xác nhận reset kế" : "Next reset unconfirmed"
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
        let relative = L10n.relativeUpdated(from: metadata.observedAt, preference: settings.appLanguage)
        let freshness = metadata.isStale
            ? (vi ? "số cũ \(relative)" : "last known \(relative)")
            : (vi ? "cập nhật \(relative)" : "updated \(relative)")
        return [source, account, freshness].joined(separator: " · ")
    }

    private func accessibilityLabel(_ item: QuotaAgendaPanelItem) -> String {
        let agenda = item.projection
        let remaining: String
        switch agenda.remaining {
        case let .current(percent): remaining = "\(percent)%"
        case .unavailable: remaining = vi ? "chưa có phần trăm hiện tại" : "current percent unavailable"
        case let .lastKnown(percent): remaining = vi ? "số cũ \(percent)%" : "last known \(percent)%"
        }
        return [item.agentName, agenda.providerName, resetLine(agenda), remaining,
                metadataText(agenda.metadata)].joined(separator: ", ")
    }

    private func percentTone(_ percent: Int) -> Color {
        if percent <= 20 { return VocabbyTheme.critical }
        if percent <= 50 { return VocabbyTheme.warningFill }
        return VocabbyTheme.success
    }

    private func resetTone(_ state: QuotaAgendaResetState) -> Color {
        switch state {
        case .scheduled: return VocabbyTheme.blue
        case .awaitingRefresh, .staleLastKnown: return VocabbyTheme.warningFill
        case .unknown: return VocabbyTheme.tertiary
        }
    }
}
