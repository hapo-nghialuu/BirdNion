import SwiftUI

/// Popover content — single window that hosts three sections:
/// Quota (default), Providers (token entry), Claude Config (settings.json).
///
/// Sections swap inline via the `section` state. The Settings button in the
/// footer's footer-menu posts the `.openSettings` notification; PopoverView
/// observes it and switches to `.providers`. The header gets a back button
/// when the user is not on the Quota section so they can return.
///
/// Cmd+, routes through `AppDelegate.openSettings(_:)` which ensures the
/// popover is open before reposting the notification (otherwise the listener
/// would miss it on a cold press).
struct PopoverView: View {
    @EnvironmentObject var quota: QuotaService
    @EnvironmentObject var config: ConfigService
    @EnvironmentObject var keychain: KeychainService
    @State private var section: Section = .quota

    enum Section: Hashable {
        case quota, config
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Inline top bar — only shown when not on Quota (Quota has its
            // own HeaderCard with the logo + status pill).
            if section != .quota {
                inlineBar
            }
            Group {
                switch section {
                case .quota:  QuotaOverview()
                case .config: ConfigPanel()
                }
            }
        }
        // Width is fixed; height is left unconstrained so the hosting
        // controller reports its fitting height and the popover shrinks to
        // hug the content. The fixed 480 height used to leave dead space
        // below the cards (a Spacer absorbed it into a visible gap).
        .frame(width: 420)
        .background(VocabbyTheme.background)
    }

    /// Single place that swaps the popover section. We intentionally switch
    /// WITHOUT animation: animating the height while the panel auto-resizes to
    /// its content (the hosting controller's preferredContentSize) drove
    /// NSHostingView's autoresizing constraints into an NSISEngine recursion
    /// that crashed the whole app (reproduced: animated = crash, instant = ok).
    private func switchTo(_ s: Section) {
        section = s
    }

    private var inlineBar: some View {
        HStack(spacing: 6) {
            Button {
                switchTo(.quota)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Quota")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(VocabbyTheme.blue)
            }
            .buttonStyle(.plain)
            Spacer()
            Text(sectionTitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(VocabbyTheme.primary)
            Spacer()
            // Right-side spacer to keep the title visually centered relative
            // to the left back button's width.
            Color.clear.frame(width: 50, height: 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(VocabbyTheme.badge)
    }

    private var sectionTitle: String {
        switch section {
        case .quota:  return "Quota"
        case .config: return "Claude Config"
        }
    }
}

extension Notification.Name {
    static let openSettings = Notification.Name("com.local.birdnion.openSettings")
}