import SwiftUI
import WidgetKit

/// One (provider, window) pair shown as a burn-down tile.
struct BurnTile: Identifiable {
    let id: String
    let providerName: String
    let providerID: String
    let window: WidgetWindowSnapshot
}

struct BurnDownEntry: TimelineEntry {
    let date: Date
    let tiles: [BurnTile]
    let snapshotAge: TimeInterval?
    let empty: Bool
}

struct BurnDownProvider: TimelineProvider {
    func placeholder(in context: Context) -> BurnDownEntry {
        BurnDownEntry(date: Date(), tiles: [], snapshotAge: nil, empty: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (BurnDownEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BurnDownEntry>) -> Void) {
        let e = entry()
        let next = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [e], policy: .after(next)))
    }

    /// Burn-down needs windows with both a window length and a reset time —
    /// same compatibility gate as upstream `BurnDownState.isCompatible`.
    private func entry(now: Date = Date()) -> BurnDownEntry {
        guard let snapshot = WidgetSnapshotLoader.load() else {
            return BurnDownEntry(date: now, tiles: [], snapshotAge: nil, empty: true)
        }
        var tiles: [BurnTile] = []
        for provider in snapshot.providers {
            for window in provider.windows where Self.isCompatible(window) {
                tiles.append(BurnTile(
                    id: "\(provider.id).\(window.label)",
                    providerName: provider.name,
                    providerID: provider.id,
                    window: window))
            }
        }
        // Most-spent first so the critical quota always leads.
        tiles.sort { ($0.window.usedPercent) > ($1.window.usedPercent) }
        let cap = 4
        return BurnDownEntry(
            date: now,
            tiles: Array(tiles.prefix(cap)),
            snapshotAge: now.timeIntervalSince1970 - snapshot.generatedAt,
            empty: tiles.isEmpty)
    }

    static func isCompatible(_ w: WidgetWindowSnapshot) -> Bool {
        guard let minutes = w.windowMinutes, minutes > 0,
              let reset = w.resetsAt, reset.isFinite, reset > 0
        else { return false }
        return true
    }
}

struct BurnDownWidgetView: View {
    let entry: BurnDownEntry

    var body: some View {
        Group {
            if entry.empty {
                emptyState
            } else {
                grid
            }
        }
        .containerBackground(for: .widget) {
            BurnBackground()
        }
    }

    private var grid: some View {
        let tiles = entry.tiles
        let columns = tiles.count > 1 ? 2 : 1
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("BirdNion")
                    .font(.system(size: 13, weight: .bold))
                Text("· burn-down")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columns), spacing: 10) {
                ForEach(tiles) { tile in
                    BurnTileView(tile: tile)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("BirdNion")
                .font(.system(size: 13, weight: .bold))
            Text("Mở BirdNion để đồng bộ quota.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

@main
struct BirdNionWidgetBundle: WidgetBundle {
    var body: some Widget {
        BurnDownWidget()
    }
}

struct BurnDownWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "BirdNionBurnDown",
            provider: BurnDownProvider()) { entry in
            BurnDownWidgetView(entry: entry)
        }
        .configurationDisplayName("Burn Down")
        .description("Đường cháy quota theo thời gian cho các provider đang bật.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}
