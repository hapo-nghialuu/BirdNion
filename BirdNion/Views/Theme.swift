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
/// Light values are byte-identical to the original fixed-light palette
/// (regression zero); dark values come from the approved remake mockups
/// (plans/settings-remake-plan.md).
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

    // Surfaces
    static let background = dyn(0xF4F5F7, 0x1E1E20)
    static let card       = dyn(0xFEFEFF, 0x2C2C2E)
    static let group      = dyn(0xFAFBFC, 0x37373A)
    static let segment    = dyn(0xEEF0F4, 0x232326)
    static let selectedSurface = dyn(0xE7F1FF, 0x313D52)
    static let hoverSurface = dyn(0xE7EAF0, 0x3A3A3E)

    // Text
    static let primary    = dyn(0x1C1F26, 0xF2F2F5)
    static let secondary  = dyn(0x59616D, 0xA5A5AB)
    static let tertiary   = dyn(0x6B7280, 0x7C7C82)
    static let disabled   = dyn(0x9AA3AD, 0x6B6B70)

    // Accent + semantic states
    static let blue       = dyn(0x0057B8, 0x4C8DFF)   // action
    static let yellow     = dyn(0xA84B00, 0xF7B955)   // warning text
    static let warningFill = dyn(0xB86A00, 0xD99A45)
    static let warningSurface = dyn(0xFFF1D6, 0x4A3A20)
    static let success    = dyn(0x15803D, 0x46C25F)
    static let successSurface = dyn(0xEAF7EF, 0x263D2C)
    static let critical   = dyn(0xD70015, 0xFF6369)
    static let criticalSurface = dyn(0xFFE8EA, 0x4A2A2E)

    // Chrome
    static let track      = dyn(0xE3E6EA, 0x3D3D41)
    static let border     = dyn(0xD7DCE2, 0x3D3D41)
    static let badge      = group

    // Charts — series colors stay constant so the stacked split reads the
    // same in both themes; only near-black series get a dark override below.
    static let chartBar    = fixed(0x469BE9)
    static let chartCodex  = fixed(0x469BE9)
    static let chartClaude = fixed(0xCC7C5E)   // brand orange
    static let chartGrok   = dyn(0x111827, 0xC8CCD6)  // near-black is invisible on dark

    // Per-provider brand tints for the monochrome template logos.
    // Values mirror CodexBar's ProviderBranding.color exactly (see
    // docs/provider-parity). Near-black brands (Grok, CommandCode) flip to a
    // light neutral in dark mode; ElevenLabs keeps following `primary`.
    static let codex      = fixed(0x49A3B0)
    static let minimax    = fixed(0xFE603C)
    static let openRouter = fixed(0x6467F2)
    static let deepSeek   = fixed(0x527DF0)
    static let zai        = fixed(0xE85A6A)
    static let claude     = fixed(0xCC7C5E)
    static let elevenLabs = primary            // CodexBar #EBEBE6 invisible on light → follows text
    static let deepgram   = fixed(0x6467F2)
    static let groq       = fixed(0xF56844)
    static let grok       = dyn(0x111827, 0xC8CCD6)
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
    static let bedrock    = fixed(0xFF9900)    // AWS

    /// Brand tint for a provider id; nil → caller falls back to default styling.
    static func providerTint(_ id: String) -> Color? {
        switch id {
        case "codex": return codex
        case "minimax": return minimax
        case "openrouter": return openRouter
        case "deepseek": return deepSeek
        case "zai": return zai
        case "claude": return claude
        case "elevenlabs": return primary
        case "deepgram": return deepgram
        case "groq": return groq
        case "grok": return grok
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

    /// Heatmap cell fill for the All tab's activity grid.
    /// GitHub-style contribution greens, lightened one step so the popover
    /// heatmap is softer than the full GitHub calendar palette. The empty
    /// cell follows the surface so it does not glare in dark mode.
    static let heatEmpty = dyn(0xEBEDF0, 0x37373A)
    static let heatL1    = fixed(0xC6F0CD)
    static let heatL2    = fixed(0x8CDC9B)
    static let heatL3    = fixed(0x5ABE73)
    static let heatL4    = fixed(0x379B55)

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
