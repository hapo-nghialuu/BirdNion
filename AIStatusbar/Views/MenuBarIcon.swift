import AppKit

/// Renders the menu bar icon as a small bird with one sticky numeric badge
/// per enabled provider, drawn in a row across the top of the icon. Each
/// badge shows the lowest `remainingPct` across that provider's quota
/// windows. When no status is available yet, the bird is drawn alone
/// (no badges).
///
/// The bird itself is the `MenuBarIcon` asset in `Assets.xcassets`. Badges
/// are composed at render time via Core Graphics so the digits always
/// stay sharp regardless of bar height.
enum MenuBarIconRenderer {
    static let assetName = "MenuBarIcon"

    /// Draw the menu bar image. `statuses` is the list of provider states;
    /// one badge is drawn per status that has at least one window. Each
    /// badge shows the lowest `remainingPct` of that provider.
    static func image(statuses: [ProviderStatus] = []) -> NSImage {
        // The on-screen point size for menu bar icons is 18x18 on most Macs;
        // render at 2x for crispness on Retina displays.
        let pointSize: CGFloat = 18
        let scale: CGFloat = 2
        let px = Int(pointSize * scale)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: px, pixelsHigh: px,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return fallback() }

        let cs = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = cs
        cs?.cgContext.scaleBy(x: scale, y: scale)

        // 1) Draw the bird (template asset) full-bleed. With per-provider
        //    badges stacked at the top, the bird reads as a single shape
        //    since the badges are small and offset upward.
        let birdRect = NSRect(x: 0, y: 0, width: pointSize, height: pointSize)
        if let bird = NSImage(named: assetName) {
            bird.isTemplate = true
            bird.draw(in: birdRect,
                      from: .zero, operation: .sourceOver, fraction: 1.0)
        } else {
            NSColor.secondaryLabelColor.setFill()
            NSBezierPath(roundedRect: birdRect.insetBy(dx: 2, dy: 2),
                          xRadius: 4, yRadius: 4).fill()
        }

        // 2) Draw one badge per provider with data, in order, sized to fit
        //    across the top of the 18pt slot. The slot is 18pt wide so we
        //    can fit up to 3 badges comfortably; more would clip.
        let perProvider = statuses.compactMap { status -> Int? in
            let pcts = status.windows.map { $0.remainingPct }
            return pcts.min()
        }
        let maxBadges = 3
        let toShow = Array(perProvider.prefix(maxBadges))
        if !toShow.isEmpty {
            drawBadgeRow(percents: toShow, in: pointSize)
        }

        NSGraphicsContext.restoreGraphicsState()

        let img = NSImage(size: NSSize(width: pointSize, height: pointSize))
        img.addRepresentation(rep)
        img.isTemplate = false // The badges are coloured, so the icon isn't a template.
        return img
    }

    /// Fallback when the bitmap allocation fails (extremely unlikely).
    private static func fallback() -> NSImage {
        if let img = NSImage(named: assetName) {
            img.isTemplate = false
            return img
        }
        return NSImage(size: NSSize(width: 22, height: 22))
    }

    // MARK: - Badge row

    /// Draw a row of small red circle badges across the top of the icon,
    /// one per percentage value, left-to-right. Each badge is 7pt across;
    /// with up to 3 badges and a 1pt inset on each side, they fit within
    /// the 18pt menu bar slot without overlapping the bird's silhouette
    /// center.
    private static func drawBadgeRow(percents: [Int], in size: CGFloat) {
        let diameter: CGFloat = 7
        let gap: CGFloat = 1
        let totalWidth = CGFloat(percents.count) * diameter
                         + CGFloat(max(0, percents.count - 1)) * gap
        let startX = (size - totalWidth) / 2
        let y: CGFloat = size - diameter - 1 // hug the top edge

        for (i, pct) in percents.enumerated() {
            let x = startX + CGFloat(i) * (diameter + gap)
            let rect = NSRect(x: x, y: y, width: diameter, height: diameter)
            drawSingleBadge(percent: pct, in: rect)
        }
    }

    /// Filled red circle with a centred white percentage label.
    private static func drawSingleBadge(percent: Int, in rect: NSRect) {
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: rect).fill()

        let text = "\(percent)" as NSString
        // 1–2 digits fit at 5pt; 3 digits shrink to 4pt to stay inside the
        // 7pt circle without overflowing.
        let fontSize: CGFloat = percent >= 100 ? 3.6 : 4.6
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let textSize = text.size(withAttributes: attrs)
        let textRect = NSRect(
            x: rect.midX - textSize.width / 2,
            y: rect.midY - textSize.height / 2,
            width: textSize.width,
            height: textSize.height
        )
        text.draw(in: textRect, withAttributes: attrs)
    }
}
