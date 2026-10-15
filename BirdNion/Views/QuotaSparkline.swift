import SwiftUI

/// Mini sparkline of remaining quota over the last 7 days, drawn from
/// `QuotaUsageHistory` samples. Rendered in the window row's foot — a
/// declining line means quota is burning. Hidden until ≥3 samples exist.
struct QuotaSparkline: View {
    let samples: [QuotaUsageSample]
    /// Fill color — same semantic quota tone as the row's bar.
    let color: Color

    /// Samples within the last 7 days, oldest first.
    private var recent: [QuotaUsageSample] {
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        return samples.filter { $0.at >= cutoff }
    }

    var body: some View {
        let points = recent
        if points.count >= 3 {
            GeometryReader { geo in
                Path { path in
                    for (index, sample) in points.enumerated() {
                        let x = geo.size.width * CGFloat(index) / CGFloat(points.count - 1)
                        let y = geo.size.height * (1 - CGFloat(sample.remainingPct) / 100)
                        index == 0 ? path.move(to: CGPoint(x: x, y: y))
                                   : path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
            }
            .frame(width: 44, height: 10)
            .accessibilityLabel("Quota trend 7 days")
        }
    }
}
