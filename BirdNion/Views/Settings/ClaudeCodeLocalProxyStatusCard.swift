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
        VStack(alignment: .leading, spacing: 6) {
            Text(header ?? L10n.t("ccx.step.proxy", lang)).plexEyebrow()
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: presentation.icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(presentation.color)
                        .frame(width: 34, height: 34)
                        .overlay(
                            RoundedRectangle(cornerRadius: InstrumentShape.plateRadius, style: .continuous)
                                .stroke(presentation.color, lineWidth: 1)
                        )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(presentation.title)
                            .font(.plexSans(13, weight: .semibold))
                            .foregroundStyle(VocabbyTheme.primary)
                        Text(presentation.detail)
                            .font(.plexSans(11))
                            .foregroundStyle(VocabbyTheme.secondary)
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
                    .buttonBorderShape(.roundedRectangle(radius: InstrumentShape.controlRadius))
                    .controlSize(.small)
                    .disabled(busy || runtimeState == .starting)
                    .pointingHandCursor(enabled: !busy && runtimeState != .starting)
                    .help(L10n.t("ccx.proxy.refresh", lang))
                    .accessibilityLabel(L10n.t("ccx.proxy.refresh", lang))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .hairlineTop()

                HStack(spacing: 12) {
                    Text(L10n.t("ccx.proxy.localEndpoint", lang))
                        .font(.plexSans(12, weight: .semibold))
                        .foregroundStyle(VocabbyTheme.primary)
                        .frame(width: 112, alignment: .leading)
                    Text(endpoint)
                        .font(.plexMono(12))
                        .foregroundStyle(VocabbyTheme.secondary)
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
                    .buttonBorderShape(.roundedRectangle(radius: InstrumentShape.controlRadius))
                    .controlSize(.small)
                    .pointingHandCursor()
                    .help(L10n.t("ccx.proxy.copyEndpoint", lang))
                    .accessibilityLabel(L10n.t("ccx.proxy.copyEndpoint", lang))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .hairlineTop()

                if let feedback {
                    Label(feedback, systemImage: feedbackIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.plexSans(11, weight: .medium))
                        .foregroundStyle(feedbackIsError ? VocabbyTheme.critical : VocabbyTheme.success)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .hairlineTop()
                }
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
                    .font(.plexMono(11, weight: .semibold))
                    .textCase(.uppercase)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: InstrumentShape.controlRadius))
            .controlSize(.small)
            .tint(VocabbyTheme.critical)
            .disabled(busy)
            .pointingHandCursor(enabled: !busy)
        case .start, .update, .retry:
            Button(action: onStart) {
                Label(actionLabel, systemImage: actionIcon)
                    .font(.plexMono(11, weight: .semibold))
                    .textCase(.uppercase)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: InstrumentShape.controlRadius))
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
                VocabbyTheme.warningFill,
                L10n.t("ccx.proxy.status.needsConfig", lang),
                L10n.t("ccx.proxy.detail.needsConfig", lang)
            )
        }
        switch runtimeState {
        case .checking:
            return (
                "magnifyingglass",
                VocabbyTheme.secondary,
                L10n.t("ccx.proxy.status.checking", lang),
                L10n.t("ccx.proxy.detail.checking", lang)
            )
        case .starting:
            return (
                "arrow.triangle.2.circlepath",
                VocabbyTheme.blue,
                L10n.t("ccx.proxy.status.starting", lang),
                L10n.t("ccx.proxy.detail.starting", lang)
            )
        case .running where configurationCurrent:
            return (
                "checkmark.circle.fill",
                VocabbyTheme.success,
                L10n.t("ccx.proxy.status.running", lang),
                runningDetail ?? L10n.t("ccx.proxy.detail.running", lang)
            )
        case .running:
            return (
                "arrow.triangle.2.circlepath.circle.fill",
                VocabbyTheme.warningFill,
                L10n.t("ccx.proxy.status.needsUpdate", lang),
                L10n.t("ccx.proxy.detail.needsUpdate", lang)
            )
        case .stopped:
            return (
                "stop.circle",
                VocabbyTheme.secondary,
                L10n.t("ccx.proxy.status.stopped", lang),
                stoppedDetail ?? L10n.t("ccx.proxy.detail.stopped", lang)
            )
        case .failed:
            return (
                "exclamationmark.triangle.fill",
                VocabbyTheme.critical,
                L10n.t("ccx.proxy.status.failed", lang),
                L10n.t("ccx.proxy.detail.failed", lang)
            )
        }
    }
}
