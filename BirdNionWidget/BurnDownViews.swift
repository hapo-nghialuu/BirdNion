import SwiftUI

// MARK: - Palette (ported from CodexBar BurnPalette / BirdNion Theme)

enum BurnPalette {
    static let aheadDark = Color(red: 0.306, green: 0.800, blue: 0.506)
    static let aheadLight = Color(red: 0.192, green: 0.620, blue: 0.376)
    static let onpaceDark = Color(red: 0.408, green: 0.668, blue: 0.910)
    static let onpaceLight = Color(red: 0.264, green: 0.474, blue: 0.712)
    static let behindDark = Color(red: 0.922, green: 0.420, blue: 0.227)
    static let behindLight = Color(red: 0.762, green: 0.294, blue: 0.137)

    static let darkBgTop = Color(red: 0.108, green: 0.108, blue: 0.132)
    static let darkBgBottom = Color(red: 0.132, green: 0.132, blue: 0.156)
    static let lightBgTop = Color(white: 0.990)
    static let lightBgBottom = Color(red: 0.940, green: 0.940, blue: 0.960)
}

struct BurnBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        let dark = colorScheme == .dark
        LinearGradient(
            colors: dark
                ? [BurnPalette.darkBgTop, BurnPalette.darkBgBottom]
                : [BurnPalette.lightBgTop, BurnPalette.lightBgBottom],
            startPoint: .top, endPoint: .bottom)
    }
}

/// Provider brand tints — mirror of `VocabbyTheme.providerTint` (keep in
/// sync; widget has no access to app sources).
enum BurnBrandTint {
    static func color(for id: String, dark: Bool) -> Color? {
        func rgb(_ l: Int, _ d: Int) -> Color {
            let h = dark ? d : l
            return Color(
                red: Double((h >> 16) & 0xFF) / 255,
                green: Double((h >> 8) & 0xFF) / 255,
                blue: Double(h & 0xFF) / 255)
        }
        switch id {
        case "codex": return rgb(0x49A3B0, 0x49A3B0)
        case "claude": return rgb(0xCC7C5E, 0xCC7C5E)
        case "devin": return rgb(0x317CFF, 0x49B0FF)
        case "commandcode": return rgb(0x000000, 0xE5E5E5)
        case "antigravity": return rgb(0x60BA7E, 0x60BA7E)
        case "copilot": return rgb(0xA855F7, 0xA855F7)
        case "cursor": return rgb(0x00BFA5, 0x00BFA5)
        case "gemini": return rgb(0xAB87EA, 0xAB87EA)
        case "kiro": return rgb(0x8B47F9, 0x8B47F9)
        case "opencode", "opencodego": return rgb(0x3B82F6, 0x3B82F6)
        case "minimax": return rgb(0xFE603C, 0xFE603C)
        case "openrouter", "deepgram": return rgb(0x6467F2, 0x6467F2)
        case "deepseek": return rgb(0x527DF0, 0x527DF0)
        case "zai": return rgb(0xE85A6A, 0xE85A6A)
        case "groq": return rgb(0xF56844, 0xF56844)
        case "grok": return rgb(0x111827, 0xC8CCD6)
        case "openai": return rgb(0x0F826E, 0x0F826E)
        case "kilo": return rgb(0xF27027, 0xF27027)
        case "freemodel": return rgb(0x22C55E, 0x22C55E)
        case "mimo": return rgb(0xFF6900, 0xFF6900)
        case "alibaba": return rgb(0xFF6A00, 0xFF6A00)
        case "bedrock": return rgb(0xFF9900, 0xFF9900)
        default: return nil
        }
    }
}

// MARK: - Geometry (ported from upstream BurnGeom)

struct BurnGeom {
    enum Status { case ahead, onpace, behind }

    let vNow: Double // % remaining (0..100)
    let tNow: Double // position in window (0..1)
    let idealNow: Double // what you should have left = 100 * (1 - tNow)
    let margin: Double // vNow - idealNow; + = conserving, − = over pace
    let slope: Double // %/unit-t (negative = burning)
    let projT: Double // t where projection ends
    let projV: Double // v where projection ends
    let runsOut: Bool // projection hits 0 inside the window

    var status: Status {
        margin > 4 ? .ahead : margin < -4 ? .behind : .onpace
    }
    var depleted: Bool { vNow <= 0.5 }
    var fresh: Bool { vNow >= 99.5 }

    init(usedPercent: Double, windowMinutes: Int?, resetsAt: TimeInterval?, now: Date = Date()) {
        let remaining = max(0, min(100, 100 - usedPercent))
        self.vNow = remaining

        let t: Double
        if let resetsAt, let windowMinutes, windowMinutes > 0 {
            let reset = Date(timeIntervalSince1970: resetsAt)
            let minutesUntilReset = max(0, reset.timeIntervalSince(now) / 60)
            let elapsed = Double(windowMinutes) - minutesUntilReset
            t = max(0.001, min(0.999, elapsed / Double(windowMinutes)))
        } else {
            t = max(0.001, min(0.999, usedPercent / 100.0))
        }
        self.tNow = t
        self.idealNow = 100.0 * (1.0 - t)
        self.margin = remaining - self.idealNow

        let slope = t > 0.001 ? (remaining - 100.0) / t : -remaining
        self.slope = slope

        if slope < -0.01 {
            let tOut = t + remaining / -slope
            if tOut <= 1.0 {
                self.projT = tOut
                self.projV = 0
                self.runsOut = true
            } else {
                self.projT = 1.0
                self.projV = max(0, remaining + slope * (1.0 - t))
                self.runsOut = false
            }
        } else {
            self.projT = 1.0
            self.projV = remaining
            self.runsOut = false
        }
    }
}

// MARK: - Theme

struct BurnTheme {
    let brand: Color
    let statusColor: Color
    let text: Color
    let sub: Color
    let hair: Color
    let chartGrid: Color
    let chartIdeal: Color
    let chartProj: Color
    let chartLine: Color
    let chartNowRing: Color
    let chartNowDot: Color
    let danger: Color

    init(geom: BurnGeom, providerID: String, dark: Bool, monochrome: Bool) {
        let status: Color
        switch geom.status {
        case .ahead: status = dark ? BurnPalette.aheadDark : BurnPalette.aheadLight
        case .onpace: status = dark ? BurnPalette.onpaceDark : BurnPalette.onpaceLight
        case .behind: status = dark ? BurnPalette.behindDark : BurnPalette.behindLight
        }
        self.brand = monochrome ? .primary
            : (BurnBrandTint.color(for: providerID, dark: dark) ?? status)
        self.statusColor = monochrome ? .primary : status
        self.danger = dark ? BurnPalette.behindDark : BurnPalette.behindLight
        self.text = .primary
        self.sub = .secondary
        self.hair = Color.primary.opacity(0.10)
        self.chartGrid = Color.primary.opacity(0.14)
        self.chartIdeal = Color.primary.opacity(0.30)
        self.chartProj = status.opacity(0.85)
        self.chartLine = status
        self.chartNowRing = dark ? BurnPalette.darkBgBottom : BurnPalette.lightBgBottom
        self.chartNowDot = status
    }
}

// MARK: - Chart canvas (ported from upstream BurnChartCanvas)

struct BurnChartCanvas: View {
    let geom: BurnGeom
    let theme: BurnTheme
    var periods: Int? = nil
    var dark = false

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let padT: CGFloat = periods == nil ? 8 : 5
            let padB: CGFloat = 2
            let padL: CGFloat = 1
            let padR: CGFloat = 1

            func X(_ t: Double) -> CGFloat { padL + CGFloat(t) * (w - padL - padR) }
            func Y(_ v: Double) -> CGFloat { padT + CGFloat(1 - v / 100) * (h - padT - padB) }

            let tNow = geom.tNow
            let vNow = geom.vNow

            if let periods {
                let barColor = dark ? Color.white : Color.black
                let plotH = h - padT - padB
                let refH = 0.46 * plotH
                let idealPerPeriod = 100.0 / Double(periods)
                let burnRate = tNow > 0.001 ? (100.0 - vNow) / tNow : 0.0
                let slotW = (w - padL - padR) / CGFloat(periods)

                for i in 0..<periods {
                    let slotStart = Double(i) / Double(periods)
                    let slotEnd = Double(i + 1) / Double(periods)
                    let slotX = padL + CGFloat(slotStart) * (w - padL - padR)

                    if slotEnd <= tNow {
                        let consumed = burnRate * (slotEnd - slotStart)
                        let ratio = consumed / idealPerPeriod
                        let totalBarH = CGFloat(ratio) * refH
                        let baseH = min(totalBarH, refH)
                        if baseH > 0 {
                            context.fill(Path(CGRect(
                                x: slotX, y: h - padB - baseH,
                                width: slotW - 1, height: baseH)),
                                with: .color(barColor.opacity(0.17)))
                        }
                        if totalBarH > refH {
                            context.fill(Path(CGRect(
                                x: slotX, y: h - padB - totalBarH,
                                width: slotW - 1, height: totalBarH - refH)),
                                with: .color(barColor.opacity(0.34)))
                        }
                    } else if slotStart < tNow {
                        let partialFrac = (tNow - slotStart) / (slotEnd - slotStart)
                        let consumed = burnRate * (tNow - slotStart)
                        let ratio = consumed / idealPerPeriod
                        let totalBarH = CGFloat(ratio) * refH
                        let baseH = min(totalBarH, refH)
                        let barW = CGFloat(partialFrac) * (slotW - 1)
                        if baseH > 0 {
                            context.fill(Path(CGRect(
                                x: slotX, y: h - padB - baseH,
                                width: barW, height: baseH)),
                                with: .color(barColor.opacity(0.13)))
                        }
                        if totalBarH > refH {
                            context.fill(Path(CGRect(
                                x: slotX, y: h - padB - totalBarH,
                                width: barW, height: totalBarH - refH)),
                                with: .color(barColor.opacity(0.26)))
                        }
                    } else {
                        context.fill(Path(CGRect(
                            x: slotX, y: h - padB - refH,
                            width: slotW - 1, height: refH)),
                            with: .color(barColor.opacity(0.045)))
                    }
                }
            }

            // Now hairline + baseline
            do {
                var p = Path()
                p.move(to: CGPoint(x: X(tNow), y: Y(100)))
                p.addLine(to: CGPoint(x: X(tNow), y: Y(0)))
                context.stroke(p, with: .color(theme.chartGrid), lineWidth: 1)
            }
            do {
                var p = Path()
                p.move(to: CGPoint(x: X(0), y: Y(0)))
                p.addLine(to: CGPoint(x: X(1), y: Y(0)))
                context.stroke(p, with: .color(theme.chartGrid), lineWidth: 1)
            }

            // Area fill
            if periods == nil {
                var p = Path()
                p.move(to: CGPoint(x: X(0), y: Y(100)))
                p.addLine(to: CGPoint(x: X(tNow), y: Y(vNow)))
                p.addLine(to: CGPoint(x: X(tNow), y: Y(0)))
                p.addLine(to: CGPoint(x: X(0), y: Y(0)))
                p.closeSubpath()
                let gradient = Gradient(stops: [
                    .init(color: theme.chartLine.opacity(0.30), location: 0),
                    .init(color: theme.chartLine.opacity(0), location: 0.92),
                ])
                context.fill(p, with: .linearGradient(
                    gradient, startPoint: CGPoint(x: 0, y: padT), endPoint: CGPoint(x: 0, y: h)))
            }

            // Ideal line (dashed)
            do {
                var p = Path()
                p.move(to: CGPoint(x: X(0), y: Y(100)))
                p.addLine(to: CGPoint(x: X(1), y: Y(0)))
                context.stroke(p, with: .color(theme.chartIdeal),
                               style: StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [2.5, 3]))
            }

            // Projection (dotted)
            if geom.slope < -0.01 {
                var p = Path()
                p.move(to: CGPoint(x: X(tNow), y: Y(vNow)))
                p.addLine(to: CGPoint(x: X(geom.projT), y: Y(geom.projV)))
                context.stroke(p, with: .color(theme.chartProj.opacity(0.95)),
                               style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [0.5, 3.5]))
            }

            // Actual line (hero)
            do {
                var p = Path()
                p.move(to: CGPoint(x: X(0), y: Y(100)))
                p.addLine(to: CGPoint(x: X(tNow), y: Y(vNow)))
                context.stroke(p, with: .color(theme.chartLine),
                               style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
            }

            // Now dot
            let dotCenter = CGPoint(x: X(tNow), y: Y(vNow))
            context.fill(Path(ellipseIn: CGRect(
                x: dotCenter.x - 5.4, y: dotCenter.y - 5.4, width: 10.8, height: 10.8)),
                with: .color(theme.chartNowRing))
            context.fill(Path(ellipseIn: CGRect(
                x: dotCenter.x - 3.4, y: dotCenter.y - 3.4, width: 6.8, height: 6.8)),
                with: .color(theme.chartNowDot))
        }
    }
}

// MARK: - Tile

struct BurnTileView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.widgetRenderingMode) private var renderingMode

    let tile: BurnTile

    var body: some View {
        let dark = colorScheme == .dark
        let w = tile.window
        let geom = BurnGeom(
            usedPercent: Double(w.usedPercent),
            windowMinutes: w.windowMinutes,
            resetsAt: w.resetsAt)
        let theme = BurnTheme(
            geom: geom, providerID: tile.providerID, dark: dark,
            monochrome: renderingMode != .fullColor)

        let paceWord: String = geom.depleted ? "đã hết" : geom.fresh ? "đầy"
            : geom.status == .ahead ? "chậm hơn nhịp"
            : geom.status == .behind ? "nhanh hơn nhịp" : "đúng nhịp"
        let arrow: String = geom.depleted ? "■" : geom.fresh ? "◆"
            : geom.status == .ahead ? "▲" : geom.status == .behind ? "▼" : "●"

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle()
                    .fill(theme.brand)
                    .frame(width: 6, height: 6)
                Text(tile.providerName)
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Text(w.label)
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(theme.sub)
                    .lineLimit(1)
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(Int(geom.vNow.rounded()))")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("% left")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.sub)
                Spacer()
                Text(arrow)
                    .font(.system(size: 7))
                    .foregroundStyle(theme.statusColor)
                Text(paceWord)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.statusColor)
                    .lineLimit(1)
            }

            BurnChartCanvas(geom: geom, theme: theme, dark: dark)
                .frame(height: 36)

            if let reset = w.resetsAt {
                let resetDate = Date(timeIntervalSince1970: reset)
                HStack {
                    Text("reset \(resetDate, style: .relative)")
                        .font(.system(size: 8.5))
                        .foregroundStyle(theme.sub)
                    Spacer()
                    if geom.runsOut {
                        Text("hết sớm hơn reset")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(theme.danger)
                    }
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(dark ? 0.06 : 0.04)))
    }
}
