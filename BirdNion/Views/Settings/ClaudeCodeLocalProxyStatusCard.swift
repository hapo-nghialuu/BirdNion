import AppKit
import SwiftUI

/// Presents the embedded helper as an explicit setup step, separate from the
/// upstream credentials and the Claude Code settings file that consumes it.
struct ClaudeCodeLocalProxyStatusCard: View {
    let runtimeState: LocalProxyRuntimeState
    let hasUpstreamConfiguration: Bool
    let configurationCurrent: Bool
    let endpoint: String
    let lang: String
    let busy: Bool
    let feedback: String?
    let feedbackIsError: Bool
    let onStart: () -> Void
    let onStop: () -> Void
    let onRefresh: () -> Void
    var header: String? = nil
    var runningDetail: String? = nil
    var stoppedDetail: String? = nil

    private enum Action {
        case start
        case update
        case retry
        case stop
        case waiting
    }

    var body: some View {
        SettingsCard(header: header ?? L10n.t("ccx.step.proxy", lang)) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: presentation.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(presentation.color)
                    .frame(width: 34, height: 34)
                    .background(presentation.color.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(presentation.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SettingsTheme.primary)
                    Text(presentation.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                actionControl

                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(busy || runtimeState == .starting)
                .pointingHandCursor(enabled: !busy && runtimeState != .starting)
                .help(L10n.t("ccx.proxy.refresh", lang))
                .accessibilityLabel(L10n.t("ccx.proxy.refresh", lang))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            SettingsRowDivider()

            HStack(spacing: 12) {
                Text(L10n.t("ccx.proxy.localEndpoint", lang))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SettingsTheme.primary)
                    .frame(width: 112, alignment: .leading)
                Text(endpoint)
                    .font(.system(size: 12).monospaced())
                    .foregroundStyle(SettingsTheme.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(endpoint, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .pointingHandCursor()
                .help(L10n.t("ccx.proxy.copyEndpoint", lang))
                .accessibilityLabel(L10n.t("ccx.proxy.copyEndpoint", lang))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)

            if let feedback {
                SettingsRowDivider()
                Label(feedback, systemImage: feedbackIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(feedbackIsError ? SettingsTheme.critical : SettingsTheme.success)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
            }
        }
    }

    @ViewBuilder
    private var actionControl: some View {
        switch action {
        case .waiting:
            ProgressView()
                .controlSize(.small)
                .frame(width: 102, height: 28)
        case .stop:
            Button(action: onStop) {
                Label(L10n.t("ccx.proxy.stop", lang), systemImage: "stop.fill")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(SettingsTheme.critical)
            .disabled(busy)
            .pointingHandCursor(enabled: !busy)
        case .start, .update, .retry:
            Button(action: onStart) {
                Label(actionLabel, systemImage: actionIcon)
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(busy || !hasUpstreamConfiguration)
            .pointingHandCursor(enabled: !busy && hasUpstreamConfiguration)
        }
    }

    private var action: Action {
        guard hasUpstreamConfiguration else { return .start }
        switch runtimeState {
        case .running:
            return configurationCurrent ? .stop : .update
        case .failed:
            return .retry
        case .checking, .starting:
            return .waiting
        case .stopped:
            return .start
        }
    }

    private var actionLabel: String {
        switch action {
        case .start: return L10n.t("ccx.proxy.start", lang)
        case .update: return L10n.t("ccx.proxy.update", lang)
        case .retry: return L10n.t("ccx.proxy.retry", lang)
        case .stop, .waiting: return ""
        }
    }

    private var actionIcon: String {
        switch action {
        case .start: return "play.fill"
        case .update: return "arrow.triangle.2.circlepath"
        case .retry: return "arrow.clockwise"
        case .stop, .waiting: return ""
        }
    }

    private var presentation: (icon: String, color: Color, title: String, detail: String) {
        guard hasUpstreamConfiguration else {
            return (
                "slider.horizontal.3",
                SettingsTheme.warning,
                L10n.t("ccx.proxy.status.needsConfig", lang),
                L10n.t("ccx.proxy.detail.needsConfig", lang)
            )
        }
        switch runtimeState {
        case .checking:
            return (
                "magnifyingglass",
                SettingsTheme.secondary,
                L10n.t("ccx.proxy.status.checking", lang),
                L10n.t("ccx.proxy.detail.checking", lang)
            )
        case .starting:
            return (
                "arrow.triangle.2.circlepath",
                SettingsTheme.accent,
                L10n.t("ccx.proxy.status.starting", lang),
                L10n.t("ccx.proxy.detail.starting", lang)
            )
        case .running where configurationCurrent:
            return (
                "checkmark.circle.fill",
                SettingsTheme.success,
                L10n.t("ccx.proxy.status.running", lang),
                runningDetail ?? L10n.t("ccx.proxy.detail.running", lang)
            )
        case .running:
            return (
                "arrow.triangle.2.circlepath.circle.fill",
                SettingsTheme.warning,
                L10n.t("ccx.proxy.status.needsUpdate", lang),
                L10n.t("ccx.proxy.detail.needsUpdate", lang)
            )
        case .stopped:
            return (
                "stop.circle",
                SettingsTheme.secondary,
                L10n.t("ccx.proxy.status.stopped", lang),
                stoppedDetail ?? L10n.t("ccx.proxy.detail.stopped", lang)
            )
        case .failed:
            return (
                "exclamationmark.triangle.fill",
                SettingsTheme.critical,
                L10n.t("ccx.proxy.status.failed", lang),
                L10n.t("ccx.proxy.detail.failed", lang)
            )
        }
    }
}
