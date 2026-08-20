import SwiftUI

// MARK: - Instrument redesign — shared shape & type primitives
//
// Small, reusable building blocks so every view file applies the "Instrument"
// language (paper/ink, hairline dividers instead of filled rounded cards,
// square controls, mono numerals) the same way instead of reinventing it per
// file. Mirrors the CSS "Instrument redesign v1" override block in
// `linux/src/styles.css` — see that file's comments for the 1:1 rule mapping.
//
// These are pure view/style helpers: no business logic, no state. Existing
// `@State`/`@Binding`/`@EnvironmentObject` wiring in call sites is untouched.

/// Square switch (40×20, 3pt corner) replacing the default rounded
/// `Toggle(.switch)` knob — mirrors `.sw-switch` / `.mb-vis-switch` in the
/// CSS. Track is outlined (not filled) when off, solid accent when on; knob
/// is a small square, not a circle.
struct InstrumentToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        // Explicit assignment (not `toggle()`) so Bindings projected from
        // `@AppStorage` on a class-based store always hit the setter.
        Button {
            configuration.isOn = !configuration.isOn
        } label: {
            HStack(spacing: 8) {
                configuration.label
                InstrumentSwitchTrack(isOn: configuration.isOn)
            }
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .accessibilityAddTraits(.isButton)
    }
}

/// Switch chrome only (40×20) for trailing controls in labeled rows. Use with
/// `.labelsHidden()` so title/help stay outside the toggle and alignment does
/// not shift with label length (Codex Spark / Claude Fable / OpenAI web).
struct InstrumentSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn = !configuration.isOn
        } label: {
            InstrumentSwitchTrack(isOn: configuration.isOn)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .accessibilityAddTraits(.isButton)
    }
}

private struct InstrumentSwitchTrack: View {
    let isOn: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(isOn ? VocabbyTheme.blue : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(
                            isOn ? Color.clear : VocabbyTheme.secondary,
                            lineWidth: 1.5)
                )
                .frame(width: 40, height: 20)
            RoundedRectangle(cornerRadius: 0, style: .continuous)
                .fill(isOn ? VocabbyTheme.background : VocabbyTheme.primary)
                .frame(width: 14, height: 14)
                .padding(3)
        }
        .frame(width: 40, height: 20)
        .contentShape(Rectangle())
    }
}

extension ToggleStyle where Self == InstrumentToggleStyle {
    static var instrument: InstrumentToggleStyle { InstrumentToggleStyle() }
}

extension ToggleStyle where Self == InstrumentSwitchStyle {
    static var instrumentSwitch: InstrumentSwitchStyle { InstrumentSwitchStyle() }
}

/// A single hairline rule — the section separator that replaces filled,
/// rounded `.card` backgrounds throughout the redesign (`.card`, `.sw-row`,
/// `border-top: 1px solid var(--hairline)` in the CSS). Use as an overlay
/// (`.overlay(HairlineRule(), alignment: .top)`) or standalone between
/// stacked sections.
struct HairlineRule: View {
    var color: Color = VocabbyTheme.hairline
    var body: some View {
        color.frame(height: 1)
    }
}

/// The stronger rule under hero numbers / pane headers (`--ink-rule` in the
/// CSS) — same shape as `HairlineRule`, darker/lighter-per-theme color.
struct InkRule: View {
    var body: some View {
        VocabbyTheme.inkRule.frame(height: 1)
    }
}

extension View {
    /// Adds a top hairline divider. `inset` indents the rule from the view
    /// edges (popover body sections use content inset; header/tabs stay 0).
    func hairlineTop(_ color: Color = VocabbyTheme.hairline, inset: CGFloat = 0) -> some View {
        overlay(alignment: .top) {
            color.frame(height: 1)
                .padding(.horizontal, inset)
        }
    }

    /// Adds the stronger ink rule below pane headers / hero numbers.
    func inkRuleBottom(inset: CGFloat = 0) -> some View {
        overlay(alignment: .bottom) {
            VocabbyTheme.inkRule.frame(height: 1)
                .padding(.horizontal, inset)
        }
    }

    /// Popover body section rule — inset 16pt so only header + tabs rules
    /// stay edge-to-edge (design: body hairlines leave a small side gap).
    func popoverHairlineTop(_ color: Color = VocabbyTheme.hairline) -> some View {
        hairlineTop(color, inset: InstrumentPopoverMetrics.contentInset)
    }

    /// Popover chart ink rule under bars — same inset as body hairlines.
    func popoverInkRuleBottom() -> some View {
        inkRuleBottom(inset: InstrumentPopoverMetrics.contentInset)
    }

    /// Horizontal content inset for popover text/controls (16pt).
    /// Pair with `popoverHairlineTop` / `popoverInkRuleBottom` for rules.
    func popoverContentInset() -> some View {
        padding(.horizontal, InstrumentPopoverMetrics.contentInset)
    }

    /// Uppercase mono eyebrow label style (`.summary-label`, `.sw-section-header`,
    /// `SUMMARY LABEL` class of text in the CSS): 9-11pt IBM Plex Mono,
    /// medium weight, wide tracking, tertiary/secondary color, upper-cased.
    func plexEyebrow(size: CGFloat = 10, color: Color = VocabbyTheme.tertiary, tracking: CGFloat = 0.8) -> some View {
        self
            .font(.plexMono(size, weight: .medium))
            .tracking(tracking)
            .foregroundColor(color)
            .textCase(.uppercase)
    }
}

/// Square, hairline-bordered control corner radius used throughout the
/// redesign (buttons, chips, inputs, icon tiles) — replaces the old ~7-8pt
/// rounded-card radius with a tighter 4pt square language.
enum InstrumentShape {
    static let controlRadius: CGFloat = 4
    static let plateRadius: CGFloat = 4
}

/// Outlined square button (mono uppercase) — Settings / About actions.
/// Mirrors Linux `.sw-pill-btn`: transparent fill, 1px border, hover fill.
struct InstrumentButtonStyle: ButtonStyle {
    var textColor: Color = VocabbyTheme.secondary
    var borderColor: Color = VocabbyTheme.border

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.plexMono(10, weight: .medium))
            .tracking(0.4)
            .textCase(.uppercase)
            .foregroundStyle(textColor)
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous)
                    .fill(configuration.isPressed ? VocabbyTheme.hoverSurface : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == InstrumentButtonStyle {
    /// Primary action: ink border + ink text.
    static var instrumentPrimary: InstrumentButtonStyle {
        InstrumentButtonStyle(textColor: VocabbyTheme.primary, borderColor: VocabbyTheme.primary)
    }
    /// Secondary outline: muted border + secondary text.
    static var instrumentOutline: InstrumentButtonStyle {
        InstrumentButtonStyle(textColor: VocabbyTheme.secondary, borderColor: VocabbyTheme.border)
    }
    /// Accent label, muted border.
    static var instrumentAccent: InstrumentButtonStyle {
        InstrumentButtonStyle(textColor: VocabbyTheme.blue, borderColor: VocabbyTheme.border)
    }
    /// Destructive outline (quit).
    static var instrumentCritical: InstrumentButtonStyle {
        InstrumentButtonStyle(textColor: VocabbyTheme.critical, borderColor: VocabbyTheme.critical)
    }
}

// MARK: - Segmented control

/// Square mono segmented control (Linux `.ccp-seg`) — replaces system
/// `Picker(.segmented)` blue pills in Settings.
struct InstrumentSegmentedControl<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                if index > 0 {
                    VocabbyTheme.primary.frame(width: 1)
                }
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(.plexMono(11, weight: .medium))
                        .tracking(0.35)
                        .textCase(.uppercase)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(selection == option.value
                                         ? VocabbyTheme.background
                                         : VocabbyTheme.primary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .frame(minWidth: 108, maxWidth: .infinity)
                        .background(selection == option.value
                                    ? VocabbyTheme.primary
                                    : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .overlay(
            RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous)
                .strokeBorder(VocabbyTheme.primary, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous))
    }
}

// MARK: - Compact power control

/// Premium compact start/stop for Settings activation rows.
/// Layered disc (ambient glow → shell → body gradient → specular → icon)
/// so the control reads as a real physical button rather than a flat circle.
struct InstrumentPowerControl: View {
    enum State { case on, off, stale, needsSetup }

    let state: State
    var busy: Bool = false
    /// Outer diameter of the control (shell).
    var size: CGFloat = 56
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                // Soft ground shadow / ambient halo
                Circle()
                    .fill(glow)
                    .frame(width: size + 12, height: size + 12)
                    .blur(radius: state == .on ? 9 : 5)

                // Outer shell ring
                Circle()
                    .fill(shellGradient)
                    .frame(width: size, height: size)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5)
                    )

                // Inner body (recessed face)
                Circle()
                    .fill(bodyGradient)
                    .frame(width: size - 5, height: size - 5)
                    .overlay(
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(sheenTop),
                                        Color.white.opacity(0.0),
                                    ],
                                    startPoint: .top,
                                    endPoint: UnitPoint(x: 0.5, y: 0.55)
                                )
                            )
                    )
                    .overlay(
                        Circle()
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(rimTop),
                                        Color.black.opacity(rimBottom),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: Color.black.opacity(0.22), radius: 1.5, y: 1)

                if busy {
                    ProgressView()
                        .controlSize(.regular)
                        .tint(.white)
                } else {
                    Image(systemName: "power")
                        .font(.system(size: size * 0.34, weight: .bold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(iconOpacity),
                                    Color.white.opacity(iconOpacity * 0.82),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .shadow(color: Color.black.opacity(0.28), radius: 0.5, y: 0.5)
                }

                if (state == .needsSetup || state == .stale) && !busy {
                    Circle()
                        .fill(badgeColor)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.white.opacity(0.95), lineWidth: 1.5)
                        )
                        .frame(width: 12, height: 12)
                        .shadow(color: badgeColor.opacity(0.55), radius: 3)
                        .offset(x: size * 0.30, y: -size * 0.30)
                }
            }
            .frame(width: size + 12, height: size + 12)
            .scaleEffect(busy ? 0.96 : 1)
            .contentShape(Circle())
        }
        .buttonStyle(InstrumentPowerPressStyle())
        .disabled(busy || state == .needsSetup)
        .pointingHandCursor(enabled: !busy && state != .needsSetup)
        .accessibilityLabel(accessibilityLabel)
        .animation(.easeInOut(duration: 0.22), value: state)
        .animation(.easeInOut(duration: 0.18), value: busy)
    }

    // MARK: Materials

    private var shellGradient: LinearGradient {
        switch state {
        case .on:
            return LinearGradient(
                colors: [
                    Color(nsColor: NSColor(srgbRed: 0.35, green: 0.55, blue: 0.95, alpha: 1)),
                    Color(nsColor: NSColor(srgbRed: 0.12, green: 0.28, blue: 0.72, alpha: 1)),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        case .off:
            return LinearGradient(
                colors: [
                    Color(nsColor: NSColor(srgbRed: 0.42, green: 0.45, blue: 0.50, alpha: 1)),
                    Color(nsColor: NSColor(srgbRed: 0.14, green: 0.16, blue: 0.20, alpha: 1)),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        case .stale:
            return LinearGradient(
                colors: [
                    Color(nsColor: NSColor(srgbRed: 0.95, green: 0.72, blue: 0.28, alpha: 1)),
                    Color(nsColor: NSColor(srgbRed: 0.62, green: 0.40, blue: 0.05, alpha: 1)),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        case .needsSetup:
            return LinearGradient(
                colors: [
                    Color(nsColor: NSColor(srgbRed: 0.52, green: 0.54, blue: 0.58, alpha: 1)),
                    Color(nsColor: NSColor(srgbRed: 0.22, green: 0.24, blue: 0.28, alpha: 1)),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private var bodyGradient: LinearGradient {
        switch state {
        case .on:
            return LinearGradient(
                colors: [
                    Color(nsColor: NSColor(srgbRed: 0.45, green: 0.68, blue: 1.0, alpha: 1)),
                    VocabbyTheme.brandBlue,
                    VocabbyTheme.blue,
                    Color(nsColor: NSColor(srgbRed: 0.10, green: 0.22, blue: 0.62, alpha: 1)),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        case .off:
            return LinearGradient(
                colors: [
                    Color(nsColor: NSColor(srgbRed: 0.58, green: 0.61, blue: 0.66, alpha: 1)),
                    Color(nsColor: NSColor(srgbRed: 0.36, green: 0.39, blue: 0.44, alpha: 1)),
                    Color(nsColor: NSColor(srgbRed: 0.20, green: 0.22, blue: 0.27, alpha: 1)),
                    Color(nsColor: NSColor(srgbRed: 0.12, green: 0.13, blue: 0.16, alpha: 1)),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        case .stale:
            return LinearGradient(
                colors: [
                    Color(nsColor: NSColor(srgbRed: 1.0, green: 0.82, blue: 0.40, alpha: 1)),
                    VocabbyTheme.warningFill,
                    VocabbyTheme.yellow,
                    Color(nsColor: NSColor(srgbRed: 0.55, green: 0.34, blue: 0.04, alpha: 1)),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        case .needsSetup:
            return LinearGradient(
                colors: [
                    Color(nsColor: NSColor(srgbRed: 0.62, green: 0.64, blue: 0.68, alpha: 1)),
                    Color(nsColor: NSColor(srgbRed: 0.40, green: 0.42, blue: 0.46, alpha: 1)),
                    Color(nsColor: NSColor(srgbRed: 0.24, green: 0.26, blue: 0.30, alpha: 1)),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private var glow: Color {
        switch state {
        case .on: return VocabbyTheme.blue.opacity(0.42)
        case .stale: return VocabbyTheme.warningFill.opacity(0.32)
        case .off: return Color.black.opacity(0.14)
        case .needsSetup: return Color.black.opacity(0.10)
        }
    }

    private var sheenTop: Double {
        switch state {
        case .on: return 0.38
        case .stale: return 0.32
        case .off: return 0.28
        case .needsSetup: return 0.18
        }
    }

    private var rimTop: Double {
        switch state {
        case .on: return 0.45
        case .stale: return 0.35
        case .off: return 0.30
        case .needsSetup: return 0.18
        }
    }

    private var rimBottom: Double {
        switch state {
        case .on: return 0.22
        case .stale: return 0.20
        case .off: return 0.28
        case .needsSetup: return 0.20
        }
    }

    private var iconOpacity: Double {
        switch state {
        case .on, .stale: return 1
        case .off: return 0.94
        case .needsSetup: return 0.70
        }
    }

    private var badgeColor: Color {
        switch state {
        case .needsSetup: return VocabbyTheme.blue
        case .stale: return Color(nsColor: NSColor(srgbRed: 0.98, green: 0.76, blue: 0.20, alpha: 1))
        case .on, .off: return VocabbyTheme.secondary
        }
    }

    private var accessibilityLabel: String {
        switch state {
        case .on: return "Stop"
        case .off: return "Start"
        case .stale: return "Update"
        case .needsSetup: return "Needs setup"
        }
    }
}

/// Slight press scale for the power disc.
private struct InstrumentPowerPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

/// Popover shell metrics.
/// Only the header ink-rule and tabs hairline are edge-to-edge; body rules
/// use `contentInset` so they stop short of the left/right edges.
enum InstrumentPopoverMetrics {
    static let contentInset: CGFloat = 16
}

/// Inset 1pt rule for popover body (not header/tabs).
struct PopoverInsetHairline: View {
    var color: Color = VocabbyTheme.hairline
    var body: some View {
        color
            .frame(height: 1)
            .padding(.horizontal, InstrumentPopoverMetrics.contentInset)
    }
}
