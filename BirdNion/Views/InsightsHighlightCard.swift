import SwiftUI

/// Compact All-tab bridge into the full Settings insights workspace.
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
            VStack(spacing: 5) {
                HStack(spacing: 8) {
                    Text("Insights").plexEyebrow(size: 9, color: VocabbyTheme.blue)
                    Spacer(minLength: 8)
                    Text(currentValue)
                        .font(.plexMono(12, weight: .semibold))
                    Text(changeValue)
                        .font(.plexMono(10, weight: .medium))
                        .foregroundStyle(changeColor)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(VocabbyTheme.tertiary)
                }
                .lineLimit(1)

                HStack(spacing: 6) {
                    Text(summaryLine)
                        .font(.plexSans(10))
                        .foregroundStyle(VocabbyTheme.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(confidenceLine)
                        .font(.plexMono(9, weight: .medium))
                        .foregroundStyle(VocabbyTheme.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
            .popoverContentInset()
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .popoverHairlineTop()
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
        return change > 0 ? VocabbyTheme.yellow : VocabbyTheme.success
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

    static func confidenceLabel(_ confidence: ProjectInsightsConfidence) -> String {
        let total = confidence.live.count
            + confidence.historyOnly.count
            + confidence.unavailable.count
        guard total > 0 else { return "—" }
        return "LIVE \(confidence.live.count)/\(total)"
    }
}
