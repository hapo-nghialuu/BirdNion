import SwiftUI

/// One-line glance summary at the top of the popover: the worst quota
/// window across all providers (highest used %) plus today's total
/// estimated local spend. Renders nothing when neither is known.
struct GlanceLine: View {
    let statuses: [ProviderStatus]
    let todayUSD: Double
    let language: String

    /// Provider+window with the highest usedPct — the "worst" quota state.
    /// Inactive (not-applicable) windows never win.
    private var worst: (name: String, label: String, usedPct: Int)? {
        statuses
            .flatMap { status in status.windows.map { (status.displayName, $0) } }
            .filter { !$0.1.isInactive }
            .max { $0.1.usedPct < $1.1.usedPct }
            .map { (name: $0.0, label: $0.1.label, usedPct: $0.1.usedPct) }
    }

    var body: some View {
        if worst != nil || todayUSD > 0 {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let worst {
                    Text(L10n.f(
                        "glance.worst", language,
                        worst.name, worst.label,
                        worst.usedPct))
                        .foregroundStyle(
                            worst.usedPct >= 80 ? VocabbyTheme.warningFill : VocabbyTheme.secondary)
                }
                Spacer(minLength: 4)
                if todayUSD > 0 {
                    Text(L10n.f(
                        "glance.today", language,
                        String(format: "$%.2f", todayUSD)))
                        .foregroundStyle(VocabbyTheme.tertiary)
                }
            }
            .font(.plexMono(10))
            .lineLimit(1)
            .truncationMode(.tail)
            .textCase(.uppercase)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .overlay(alignment: .bottom) {
                VocabbyTheme.hairline
                    .frame(height: 1)
            }
        }
    }
}
