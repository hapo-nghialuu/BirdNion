import AppKit

/// Builds the frames the menu bar status item rotates through. AppDelegate
/// owns the timer; this type only describes each frame and renders the
/// images it needs.
///
/// The rotation is: the bird logo alone first, then one frame per provider
/// that has quota data. A provider frame shows that provider's quota numbers
/// (no unit) with the provider's brand logo drawn to their right.
enum MenuBarIconRenderer {
    static let assetName = "MenuBarIcon"

    /// One step in the menu bar rotation.
    enum Frame: Equatable {
        /// Just the bird, no text.
        case bird
        /// A provider: `percents` are its windows' `remainingPct` in order
        /// (shown without a "%" unit); `id` selects the brand logo drawn to
        /// the right of the numbers.
        case provider(id: String, name: String, percents: [Int])
    }

    /// Build the rotation: the bird first, then one frame per provider.
    /// Providers with no quota windows (OAuth still loading, or in an
    /// error state) are still included so the brand logo shows up — a
    /// loading Claude chip on the menu bar is more useful than silently
    /// dropping the provider until it recovers. Windowed providers show
    /// their numbers; windowless ones show just the logo.
    static func frames(from statuses: [ProviderStatus]) -> [Frame] {
        var frames: [Frame] = [.bird]
        for status in statuses {
            // Codex lets the user pick which window drives the bar; other
            // providers always show all their windows.
            let windows = status.id == "codex"
                ? CodexMenuBarMetric.current.filter(status.windows)
                : status.windows
            frames.append(.provider(
                id: status.id,
                name: status.displayName,
                percents: windows.map { $0.remainingPct }
            ))
        }
        return frames
    }

    /// The bird asset, scaled to `pointSize`. Deliberately not a template
    /// image: that flag flattens the bird to a single colour and loses its
    /// blue palette (see git history). The default menu bar slot is ~18pt;
    /// 24pt ≈ the full NSStatusBar thickness — effectively the hard ceiling,
    /// since macOS clips anything taller than the bar.
    static func iconImage(pointSize: CGFloat = 24) -> NSImage {
        scaled(NSImage(named: assetName), to: pointSize, isTemplate: false)
            ?? NSImage(size: NSSize(width: pointSize, height: pointSize))
    }

    /// Brand logo for a provider id, scaled for the menu bar. Falls back to a
    /// neutral SF Symbol (rendered as a template so it follows the menu bar
    /// appearance) for providers without a bundled asset, e.g. Codex.
    static func providerLogo(for id: String, pointSize: CGFloat = 18) -> NSImage {
        switch id {
        case "minimax":
            return scaled(NSImage(named: "MiniMaxLogo"), to: pointSize, isTemplate: false)
                ?? fallbackLogo(pointSize)
        case "hapo":
            return scaled(NSImage(named: "HapoLogo"), to: pointSize, isTemplate: false)
                ?? fallbackLogo(pointSize)
        case "claude":
            // Anthropic's sun/star logo (claude.svg) is monochrome white in
            // its template-rendering-intent, so a tint keeps it readable on
            // both light and dark menu bar backgrounds.
            return scaled(NSImage(named: "ClaudeLogo"), to: pointSize,
                          isTemplate: false, tint: .white)
                ?? fallbackLogo(pointSize)
        case "codex":
            // Codex ships as a monochrome SVG silhouette; tint it white so it
            // reads on the menu bar (it's shown blue in the popover instead).
            return scaled(NSImage(named: "CodexLogo"), to: pointSize,
                          isTemplate: false, tint: .white)
                ?? fallbackLogo(pointSize)
        default:
            return fallbackLogo(pointSize)
        }
    }

    /// Neutral, theme-aware logo for providers without a brand asset.
    private static func fallbackLogo(_ pointSize: CGFloat) -> NSImage {
        let symbol = NSImage(systemSymbolName: "bolt.horizontal.circle.fill",
                             accessibilityDescription: nil)
        return scaled(symbol, to: pointSize, isTemplate: true)
            ?? NSImage(size: NSSize(width: pointSize, height: pointSize))
    }

    /// Redraw `image` into a square `pointSize` bitmap with high-quality
    /// interpolation so it stays crisp at small menu bar sizes. `isTemplate`
    /// controls tinting: false keeps the source colours (brand logos), true
    /// lets AppKit tint the alpha mask to match the menu bar (SF Symbols).
    /// When `tint` is set, the source is recoloured to that colour over its
    /// alpha (a flat silhouette), used for the monochrome Codex logo.
    private static func scaled(_ image: NSImage?, to pointSize: CGFloat,
                               isTemplate: Bool, tint: NSColor? = nil) -> NSImage? {
        guard let source = image else { return nil }
        let target = NSSize(width: pointSize, height: pointSize)
        let rect = NSRect(origin: .zero, size: target)
        let out = NSImage(size: target)
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: rect,
                    from: NSRect(origin: .zero, size: source.size),
                    operation: .sourceOver,
                    fraction: 1.0)
        if let tint = tint {
            tint.set()
            rect.fill(using: .sourceAtop)
        }
        out.unlockFocus()
        out.isTemplate = isTemplate
        return out
    }
}
