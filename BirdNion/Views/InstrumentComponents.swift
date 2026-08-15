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
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                configuration.label
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(configuration.isOn ? VocabbyTheme.blue : Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .strokeBorder(configuration.isOn ? Color.clear : VocabbyTheme.secondary, lineWidth: 1)
                        )
                        .frame(width: 40, height: 20)
                    RoundedRectangle(cornerRadius: 0, style: .continuous)
                        .fill(configuration.isOn ? VocabbyTheme.background : VocabbyTheme.secondary)
                        .frame(width: 14, height: 14)
                        .padding(3)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

extension ToggleStyle where Self == InstrumentToggleStyle {
    static var instrument: InstrumentToggleStyle { InstrumentToggleStyle() }
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
    /// Adds a top hairline divider without the old rounded/filled card
    /// look — the standard way a "section" starts in the redesign.
    func hairlineTop(_ color: Color = VocabbyTheme.hairline) -> some View {
        overlay(color.frame(height: 1), alignment: .top)
    }

    /// Adds the stronger ink rule below pane headers / hero numbers.
    func inkRuleBottom() -> some View {
        overlay(VocabbyTheme.inkRule.frame(height: 1), alignment: .bottom)
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
