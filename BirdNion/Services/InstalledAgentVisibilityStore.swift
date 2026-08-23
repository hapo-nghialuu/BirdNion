import Foundation

extension Notification.Name {
    static let installedAgentVisibilityChanged = Notification.Name(
        "birdnion.installedAgentVisibilityChanged")
}

@MainActor
final class InstalledAgentVisibilityStore: ObservableObject {
    static let shared = InstalledAgentVisibilityStore()

    @Published private(set) var hiddenIDs: Set<InstalledAgentID>
    @Published private(set) var pinnedIDs: [InstalledAgentID]

    private enum Key {
        static let hidden = "birdnion.agentVisibility.v1.hiddenIDs"
        static let pinned = "birdnion.agentVisibility.v1.pinnedIDs"
        static let migration = "birdnion.agentVisibility.v1.migrationCompleted"
        static let selectedTab = "popover.selectedTab"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hiddenIDs = Self.readSet(defaults.stringArray(forKey: Key.hidden))
        pinnedIDs = Self.readOrdered(defaults.stringArray(forKey: Key.pinned))
        migrateLegacySelectionIfNeeded()
    }

    func isVisible(_ id: InstalledAgentID) -> Bool { !hiddenIDs.contains(id) }
    func isPinned(_ id: InstalledAgentID) -> Bool { pinnedIDs.contains(id) }

    func setVisible(_ visible: Bool, for id: InstalledAgentID) {
        if visible { hiddenIDs.remove(id) } else { hiddenIDs.insert(id) }
        defaults.set(hiddenIDs.map(\.rawValue).sorted(), forKey: Key.hidden)
        publishChange()
    }

    func setPinned(_ pinned: Bool, for id: InstalledAgentID) {
        pinnedIDs.removeAll { $0 == id }
        if pinned { pinnedIDs.append(id) }
        defaults.set(pinnedIDs.map(\.rawValue), forKey: Key.pinned)
        publishChange()
    }

    func visibleRecords(from records: [InstalledAgentRecord]) -> [InstalledAgentRecord] {
        let visible = records.filter { isVisible($0.id) }
        let order = Dictionary(uniqueKeysWithValues: pinnedIDs.enumerated().map { ($1, $0) })
        return visible.sorted { lhs, rhs in
            let left = order[lhs.id] ?? Int.max
            let right = order[rhs.id] ?? Int.max
            if left != right { return left < right }
            let leftCatalogOrder = InstalledAgentID.allCases.firstIndex(of: lhs.id) ?? 0
            let rightCatalogOrder = InstalledAgentID.allCases.firstIndex(of: rhs.id) ?? 0
            return leftCatalogOrder < rightCatalogOrder
        }
    }

    private func migrateLegacySelectionIfNeeded() {
        guard !defaults.bool(forKey: Key.migration) else { return }
        if defaults.string(forKey: Key.selectedTab) == "agents" {
            defaults.set("all", forKey: Key.selectedTab)
        }
        defaults.set(true, forKey: Key.migration)
    }

    private func publishChange() {
        NotificationCenter.default.post(name: .installedAgentVisibilityChanged, object: nil)
    }

    private static func readSet(_ values: [String]?) -> Set<InstalledAgentID> {
        Set((values ?? []).compactMap(InstalledAgentID.init(rawValue:)))
    }

    private static func readOrdered(_ values: [String]?) -> [InstalledAgentID] {
        var seen = Set<InstalledAgentID>()
        return (values ?? []).compactMap(InstalledAgentID.init(rawValue:)).filter { seen.insert($0).inserted }
    }
}
