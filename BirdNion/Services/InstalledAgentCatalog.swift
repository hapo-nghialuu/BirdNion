import Foundation

@MainActor
final class InstalledAgentCatalog: ObservableObject {
    @Published private(set) var records: [InstalledAgentRecord] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshedAt: Date?

    private let context: InstalledAgentDetectionContext
    private var refreshTask: Task<Void, Never>?

    init(context: InstalledAgentDetectionContext = .current) {
        self.context = context
    }

    func start() {
        refresh()
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
    }

    func refresh() {
        guard refreshTask == nil else { return }
        isRefreshing = true
        let context = context
        refreshTask = Task { [weak self] in
            let detected = await Task.detached(priority: .utility) {
                InstalledAgentDetectors.detect(context: context)
            }.value
            guard !Task.isCancelled, let self else { return }
            records = detected
            lastRefreshedAt = Date()
            isRefreshing = false
            refreshTask = nil
        }
    }

    func record(id: InstalledAgentID) -> InstalledAgentRecord? {
        records.first { $0.id == id }
    }
}
