import SwiftUI
import AppKit

/// Large circular power button (VeePN-style) used to toggle a provider as the
/// active Claude Code backend. Presentational only: the parent supplies the
/// state, the status subtitle, colors, and the tap handler, so the same button
/// works in the (light) popover and the Settings tab.
struct ClaudeCodePowerButton: View {
    enum PowerState { case on, off, stale, needsSetup }

    let state: PowerState
    let subtitle: String
    var diameter: CGFloat = 116
    var busy: Bool = false
    var subtitleColor: Color = .primary
    var showsSubtitle: Bool = true
    let action: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Button(action: action) {
                ZStack {
                    Circle()
                        .fill(gradient)
                        .frame(width: diameter, height: diameter)
                        .shadow(color: Self.glow.opacity(state == .on ? 0.55 : 0),
                                radius: state == .on ? 26 : 0)
                        .overlay(
                            Circle().strokeBorder(
                                Color.white.opacity(state == .on ? 0.28 : 0.10), lineWidth: 1)
                        )

                    if busy {
                        ProgressView().controlSize(.large).tint(.white)
                    } else {
                        Image(systemName: "power")
                            .font(.system(size: diameter * 0.34, weight: .bold))
                            .foregroundStyle(state == .on || state == .stale ? .white : Color.white.opacity(0.72))
                    }

                    // Badge dot for states that need the user's attention.
                    if (state == .needsSetup || state == .stale) && !busy {
                        Circle()
                            .fill(VocabbyTheme.warningFill)
                            .frame(width: 16, height: 16)
                            .offset(x: diameter * 0.34, y: -diameter * 0.34)
                    }
                }
                .scaleEffect(busy ? 0.97 : 1)
                .contentShape(Circle())
                .animation(.easeInOut(duration: 0.2), value: busy)
                .animation(.easeInOut(duration: 0.25), value: state)
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .pointingHandCursor(enabled: !busy)

            if showsSubtitle {
                Text(subtitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(subtitleColor)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private static let glow = VocabbyTheme.brandBlue

    private var gradient: LinearGradient {
        switch state {
        case .on:
            return LinearGradient(
                colors: [VocabbyTheme.brandBlue, VocabbyTheme.blue],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        case .off:
            return LinearGradient(
                colors: [Color(red: 0.34, green: 0.38, blue: 0.46),
                         Color(red: 0.20, green: 0.23, blue: 0.30)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        case .stale:
            // Amber: active but the written values are out of date.
            return LinearGradient(
                colors: [VocabbyTheme.warningFill, VocabbyTheme.yellow],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        case .needsSetup:
            return LinearGradient(
                colors: [Color(red: 0.28, green: 0.30, blue: 0.37),
                         VocabbyTheme.brandNavy],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

private struct PointingHandCursorModifier: ViewModifier {
    let enabled: Bool
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content.onHover { inside in
            if inside, enabled, !isHovering {
                isHovering = true
                NSCursor.pointingHand.push()
            } else if !inside, isHovering {
                isHovering = false
                NSCursor.pop()
            }
            if !enabled, isHovering {
                isHovering = false
                NSCursor.pop()
            }
        }
        .onDisappear {
            if isHovering {
                isHovering = false
                NSCursor.pop()
            }
        }
    }
}

extension View {
    func pointingHandCursor(enabled: Bool = true) -> some View {
        modifier(PointingHandCursorModifier(enabled: enabled))
    }
}
