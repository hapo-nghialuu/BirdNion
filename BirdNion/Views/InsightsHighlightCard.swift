import SwiftUI

/// Compact All-tab bridge into Settings Insights — same section language as
/// `BudgetForecastCard` (eyebrow + hero + foot), click opens the full pane.
struct InsightsHighlightCard: View {
    @EnvironmentObject private var settings: SettingsStore
    let combined: CombinedUsageReport
    let enabledSources: Set<ProjectUsageSource>
    @State private var insights: ProjectInsightsReport?

    private var vi: Bool { L10n.languageCode(settings.appLanguage) == "vi" }
    private var reloadKey: String {
        let historyURL = ProjectCostHistoryStore.historyURL()
        let attributes = try? FileManager.default.attributesOfItem(atPath: historyURL.path)
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        return Self.reloadKey(
            combined: combined, enabledSources: enabledSources,
            historyStamp: "\(modified):\(size)")
    }

    static func reloadKey(
        combined: CombinedUsageReport,
        enabledSources: Set<ProjectUsageSource>,
        historyStamp: String
    ) -> String {
        var dayParts: [String] = []
        for day in combined.daily {
            dayParts.append(String(day.date.timeIntervalSince1970))
            dayParts.append(String(day.claudeUSD))
            dayParts.append(String(day.claudeTokens))
            dayParts.append(String(day.codexUSD))
            dayParts.append(String(day.codexTokens))
            dayParts.append(String(day.grokUSD))
            dayParts.append(String(day.grokTokens))
            for model in day.models {
                dayParts.append(model.source)
                dayParts.append(model.name)
                dayParts.append(String(model.usd))
                dayParts.append(String(model.tokens))
            }
        }
        let confidence = [
            confidenceKey(combined.claudeConfidence),
            confidenceKey(combined.codexConfidence),
            confidenceKey(combined.grokConfidence),
        ].joined(separator: "|")
        let sources = enabledSources.map(\.rawValue).sorted().joined(separator: ",")
        return "\(dayParts.joined(separator: ":"))#\(confidence)#\(sources)#\(historyStamp)"
    }

    private static func confidenceKey(_ value: CostHistoryStore.UsageScanConfidence?) -> String {
        guard let value else { return "nil" }
        return "\(value.included):\(value.live):\(value.scannedAt?.timeIntervalSince1970 ?? 0)"
    }

    var body: some View {
        Button { openInsightsSettings() } label: {
            // Match BudgetForecastCard: title+meta · hero+delta · foot line.
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(vi ? "Phân tích" : "Insights")
                        .plexEyebrow(size: 9, color: VocabbyTheme.secondary, tracking: 0.3)
                    Spacer(minLength: 8)
                    HStack(spacing: 6) {
                        Text(confidenceLine)
                            .plexEyebrow(size: 9, color: VocabbyTheme.tertiary, tracking: 0.4)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(VocabbyTheme.tertiary)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(currentValue)
                        .font(.plexMono(24, weight: .bold))
                        .foregroundStyle(VocabbyTheme.primary)
                        .monospacedDigit()
                    Spacer(minLength: 8)
                    Text(changeValue)
                        .font(.plexMono(12, weight: .semibold))
                        .foregroundStyle(changeColor)
                        .monospacedDigit()
                }
                Text(summaryLine)
                    .font(.plexMono(10, weight: .medium))
                    .foregroundStyle(VocabbyTheme.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.3)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .popoverContentInset()
            .padding(.vertical, 16)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .popoverHairlineTop(VocabbyTheme.inkRule)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(vi ? "Mở Phân tích trong Cài đặt" : "Open Insights in Settings")
        .task(id: reloadKey) {
            let snapshot = combined
            let sources = enabledSources
            let next = await Task.detached(priority: .utility) {
                ProjectInsightsBuilder.build(
                    combined: snapshot, history: ProjectCostHistoryStore.read(),
                    enabledSources: sources)
            }.value
            guard !Task.isCancelled else { return }
            insights = next
        }
    }

    private var currentValue: String {
        AllUsageFormat.usd(insights?.overview.currentUSD ?? 0)
    }

    private var changeValue: String {
        guard let change = insights?.overview.changePercent else { return "—" }
        return String(format: "%@%.0f%%", change >= 0 ? "+" : "", change)
    }

    private var changeColor: Color {
        guard let change = insights?.overview.changePercent else { return VocabbyTheme.tertiary }
        if change > 0 { return VocabbyTheme.yellow }
        if change < 0 { return VocabbyTheme.success }
        return VocabbyTheme.tertiary
    }

    private var summaryLine: String {
        guard let top = insights?.ranking(days: 7).first else {
            return vi ? "Chưa có tín hiệu dự án trong 7 ngày" : "No project signal in the last 7 days"
        }
        let prefix = vi ? "Đứng đầu: " : "Top: "
        return prefix + top.displayName
    }

    private var confidenceLine: String {
        guard let confidence = insights?.overview.confidence else { return "—" }
        return Self.confidenceLabel(confidence)
    }

    private var accessibilityText: String {
        "\(currentValue), \(changeValue), \(summaryLine), \(confidenceLine)"
    }

    static func confidenceLabel(_ confidence: ProjectInsightsConfidence) -> String {
        let total = confidence.live.count
            + confidence.historyOnly.count
            + confidence.unavailable.count
        guard total > 0 else { return "—" }
        return "LIVE \(confidence.live.count)/\(total)"
    }
}
