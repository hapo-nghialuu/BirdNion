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

    /// Build the rotation: the bird first, then every provider that currently
    /// has at least one quota window. Providers in an error/loading state
    /// (no windows) are skipped so the bar never shows an empty provider.
    static func frames(from statuses: [ProviderStatus]) -> [Frame] {
        var frames: [Frame] = [.bird]
        for status in statuses where !status.windows.isEmpty {
            frames.append(.provider(
                id: status.id,
                name: status.displayName,
                percents: status.windows.map { $0.remainingPct }
            ))
        }
        return frames
    }

    /// The bird asset, scaled to `pointSize`. Deliberately not a template
    /// image: that flag flattens the bird to a single colour and loses its
    /// blue palette (see git history). The default menu bar slot is ~18pt;
    /// 20pt lets the bird read a touch larger than neighbouring status icons.
    static func iconImage(pointSize: CGFloat = 20) -> NSImage {
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
    private static func scaled(_ image: NSImage?, to pointSize: CGFloat,
                               isTemplate: Bool) -> NSImage? {
        guard let source = image else { return nil }
        let target = NSSize(width: pointSize, height: pointSize)
        let out = NSImage(size: target)
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: NSRect(origin: .zero, size: target),
                    from: NSRect(origin: .zero, size: source.size),
                    operation: .sourceOver,
                    fraction: 1.0)
        out.unlockFocus()
        out.isTemplate = isTemplate
        return out
    }
}
