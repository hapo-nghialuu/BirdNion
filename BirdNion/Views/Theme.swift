import AppKit
import SwiftUI

// MARK: - Appearance preference

/// User-selectable appearance for the whole app (Settings window + popover).
/// `auto` follows macOS; the raw values persist in UserDefaults.
enum AppAppearance: String, CaseIterable, Identifiable {
    case light, dark, auto

    var id: String { rawValue }

    /// NSAppearance to force app-wide, or nil to follow the system.
    var nsAppearance: NSAppearance? {
        switch self {
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        case .auto: return nil
        }
    }

    func title(language: String? = nil) -> String {
        switch self {
        case .light: return L10n.t("settings.appearance.light", language)
        case .dark: return L10n.t("settings.appearance.dark", language)
        case .auto: return L10n.t("settings.appearance.auto", language)
        }
    }
}

// MARK: - Theme

/// App-wide palette. Every semantic token is a dynamic NSColor that resolves
/// per the effective appearance, so views keep using `VocabbyTheme.x` exactly
/// as before and adapt to light/dark without plumbing a color scheme through.
///
/// Values are the "Instrument" redesign palette — paper/ink, hairline
/// dividers instead of filled cards, one accent color — ported 1:1 from the
/// Linux/Tauri implementation (`linux/src/styles.css`, tokens `--bg` …
/// `--heat-4`) so the macOS app and the Linux app read as the same product.
/// Provider brand marks (`claude`, `codex`, `grok`, `providerTint(_:)`, …)
/// are untouched — only surfaces, text, semantic states, and chart/heatmap
/// colors move to the new palette.
enum VocabbyTheme {
    /// Dynamic color: `light` under aqua, `dark` under darkAqua.
    private static func dyn(_ light: Int, _ dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }

    /// Fixed color regardless of appearance (brand marks, chart series).
    private static func fixed(_ hex: Int) -> Color { Color(nsColor: NSColor(hex: hex)) }

    // Brand marks stay constant in both themes.
    static let brandNavy  = fixed(0x1F2433)
    static let brandBlue  = fixed(0x469BE9)

    // Surfaces — paper (light) / ink (dark). `card` == `background`: the
    // redesign has no filled card surface, sections are separated by
    // hairline dividers instead (see `hairline` / `inkRule` below).
    static let background = dyn(0xFBFAF7, 0x17170F)  // --bg
    static let card       = dyn(0xFBFAF7, 0x17170F)  // --surface
    static let group      = dyn(0xF3F1EA, 0x1E1E16)  // --surface2 / --sidebar
    static let segment    = dyn(0xF3F1EA, 0x1E1E16)  // --segment
    static let selectedSurface = dyn(0xE9E6DC, 0x262620)  // --selected-surface
    static let hoverSurface = dyn(0xEDEAE0, 0x262620)     // --hover-surface

    // Text
    static let primary    = dyn(0x16150F, 0xF2F0E8)  // --text
    static let secondary  = dyn(0x4B4941, 0xC9C6BC)  // --text2
    static let tertiary   = dyn(0x6B6862, 0xA3A096)  // --text3
    static let disabled   = dyn(0xB0ADA3, 0x4A4A40)  // --disabled

    // Accent + semantic states
    static let blue       = dyn(0x1F4FD8, 0x7EA2FF)  // --accent (action)
    static let yellow     = dyn(0x8F5F12, 0xE0A93F)  // --warning (text)
    static let warningFill = dyn(0x8F5F12, 0xE0A93F) // --warning-fill
    static let warningSurface = dyn(0xF5EEDD, 0x2A2418) // --warning-surface
    static let success    = dyn(0x1F7A4C, 0x58C089)  // --success
    static let successSurface = dyn(0xECF1EC, 0x1E2A20) // --success-surface
    static let critical   = dyn(0xB4402F, 0xE5716A)  // --critical
    static let criticalSurface = dyn(0xF7E7E3, 0x2C1D1B) // --critical-surface

    // Chrome
    static let track      = dyn(0xE2DFD6, 0x2A2A22)  // --track
    static let border     = dyn(0xDCD8CD, 0x33332B)  // --border
    static let badge      = group

    // Hairline section dividers — replace the old rounded `card` fill.
    // `hairline` is the quiet divider between stacked sections; `inkRule` is
    // the stronger rule under headers/hero numbers (== `primary`, kept as
    // its own token for call-site clarity, matching `--hairline` /
    // `--ink-rule` in the CSS).
    static let hairline   = dyn(0xE2DFD6, 0x2A2A22)  // --hairline
    static let inkRule    = dyn(0x16150F, 0xF2F0E8)  // --ink-rule

    // Charts — series colors now track the CSS `--claude` / `--codex` /
    // `--grok` chart tokens (distinct from the `claude` / `codex` / `grok`
    // brand-mark tints below, which stay untouched).
    static let chartBar    = dyn(0x3C7FB5, 0x62A5DE)  // --chart-bar / --codex
    static let chartCodex  = dyn(0x3C7FB5, 0x62A5DE)  // --codex
    static let chartClaude = dyn(0xB5643F, 0xD98A63)  // --claude
    static let chartGrok   = dyn(0x4A4A4A, 0xC8CCD6)  // --grok

    // Per-provider brand tints for the monochrome template logos.
    // Values mirror CodexBar's ProviderBranding.color exactly (see
    // docs/provider-parity). Near-black brands (Grok, CommandCode) flip to a
    // light neutral in dark mode; ElevenLabs keeps following `primary`.
    static let codex      = fixed(0x49A3B0)
    static let minimax    = fixed(0xFE603C)
    static let openRouter = fixed(0x6467F2)
    static let tryAPI     = fixed(0x5B6CFF)
    static let deepSeek   = fixed(0x527DF0)
    static let zai        = fixed(0xE85A6A)
    static let claude     = fixed(0xCC7C5E)
    static let elevenLabs = primary            // CodexBar #EBEBE6 invisible on light → follows text
    static let deepgram   = fixed(0x6467F2)
    static let groq       = fixed(0xF56844)
    static let grok       = dyn(0x111827, 0xC8CCD6)
    static let xai        = dyn(0x8E8E93, 0xF5F5F7)
    static let openAI     = fixed(0x0F826E)    // OpenAI API teal, distinct from Codex chat
    static let ollama     = fixed(0x888888)
    static let copilot    = fixed(0xA855F7)
    static let kilo       = fixed(0xF27027)
    static let commandCode = dyn(0x000000, 0xE5E5E5)
    static let freemodel  = fixed(0x22C55E)
    static let mimo       = fixed(0xFF6900)
    static let alibaba    = fixed(0xFF6A00)
    static let cursor     = fixed(0x00BFA5)
    static let gemini     = fixed(0xAB87EA)
    static let kiro       = fixed(0x8B47F9)    // Kiro violet, icon gradient mid
    static let openCode   = fixed(0x3B82F6)
    static let antigravity = fixed(0x60BA7E)
    static let googleBlue = fixed(0x4285F4)
    static let googleRed = fixed(0xEA4335)
    static let googleYellow = fixed(0xFBBC05)
    static let googleGreen = fixed(0x34A853)
    static let bedrock    = fixed(0xFF9900)    // AWS
    static let hiyo       = fixed(0x00A8E8)

    /// Brand tint for a provider id; nil → caller falls back to default styling.
    static func providerTint(_ id: String) -> Color? {
        switch id {
        case "codex": return codex
        case "minimax": return minimax
        case "openrouter": return openRouter
        case "tryapi": return tryAPI
        case "deepseek": return deepSeek
        case "zai": return zai
        case "claude": return claude
        case "elevenlabs": return primary
        case "deepgram": return deepgram
        case "groq": return groq
        case "grok": return grok
        case "xai": return xai
        case "openai": return openAI
        case "ollama": return ollama
        case "copilot": return copilot
        case "kilo": return kilo
        case "commandcode": return commandCode
        case "freemodel": return freemodel
        case "mimo": return mimo
        case "alibaba": return alibaba
        case "cursor": return cursor
        case "gemini": return gemini
        case "kiro": return kiro
        case "opencode", "opencodego": return openCode
        case "antigravity": return antigravity
        case "bedrock": return bedrock
        case "hiyo": return hiyo
        default: return nil
        }
    }

    static func quotaColor(remaining: Int) -> Color {
        if remaining <= 20 { return critical }
        if remaining <= 50 { return yellow }
        return success
    }

    static func quotaFillColor(remaining: Int) -> Color {
        if remaining <= 20 { return critical }
        if remaining <= 50 { return warningFill }
        return success
    }

    static func usedFillColor(usedPercent: Int) -> Color {
        if usedPercent >= 90 { return critical }
        if usedPercent >= 70 { return warningFill }
        return success
    }

    /// Daily-bar fill shared by the per-provider chart cards. `tint` colors
    /// normal active days (at 72%), `currentTint` marks today's bar — the
    /// defaults keep the original blue scheme; the Claude card passes its
    /// brand orange.
    static func activityChartBarColor(isCurrent: Bool, hasActivity: Bool,
                                      tint: Color = chartBar,
                                      currentTint: Color = blue) -> Color {
        if !hasActivity { return selectedSurface.opacity(0.76) }
        return isCurrent ? currentTint : tint.opacity(0.72)
    }

    /// Heatmap cell fill for the All tab's activity grid — Instrument
    /// redesign uses the accent-blue scale (`--heat-0`…`--heat-4`) instead
    /// of the old GitHub-style contribution greens, so activity intensity
    /// reads as "more accent", consistent with the rest of the palette.
    static let heatEmpty = dyn(0xEFEDE6, 0x23231C)  // --heat-0
    static let heatL1    = dyn(0xD5DDF3, 0x2F3A5C)  // --heat-1
    static let heatL2    = dyn(0xA9BCE8, 0x41528C)  // --heat-2
    static let heatL3    = dyn(0x6E8DDB, 0x5A72C4)  // --heat-3
    static let heatL4    = dyn(0x1F4FD8, 0x7EA2FF)  // --heat-4

    static func heatColor(fraction: Double) -> Color {
        guard fraction > 0 else { return heatEmpty }
        if fraction <= 0.25 { return heatL1 }
        if fraction <= 0.5 { return heatL2 }
        if fraction <= 0.75 { return heatL3 }
        return heatL4
    }
}

private extension NSColor {
    /// 0xRRGGBB → sRGB color.
    convenience init(hex: Int) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

// MARK: - Fonts

/// Font family names for the Instrument redesign — bundled via
/// `BirdNion/Resources/Fonts/*.ttf` and registered at launch by
/// `AppFonts.registerBundledFonts()`. Mirrors `--font-sans` / `--font-mono`
/// in `linux/src/styles.css`.
enum VocabbyFont {
    static let sans = "IBM Plex Sans"
    static let mono = "IBM Plex Mono"
}

extension Font {
    /// Body/label/UI text — replaces `.system(size:weight:)` call sites the
    /// redesign touches. Falls back to the system font automatically if the
    /// bundled font failed to register (`Font.custom` degrades gracefully).
    static func plexSans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(VocabbyFont.sans, size: size).weight(weight)
    }

    /// Numerals, percentages, money, timestamps, uppercase mono labels —
    /// replaces `.system(size:weight:).monospacedDigit()` call sites.
    static func plexMono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(VocabbyFont.mono, size: size).weight(weight)
    }
}
