import Foundation

@MainActor
final class InstalledAgentCatalog: ObservableObject {
    typealias Detector = @Sendable (InstalledAgentDetectionContext) async -> [InstalledAgentRecord]

    @Published private(set) var records: [InstalledAgentRecord] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshedAt: Date?

    private let context: InstalledAgentDetectionContext
    private let detector: Detector
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration: UInt64 = 0

    init(
        context: InstalledAgentDetectionContext = .current,
        detector: @escaping Detector = { context in
            await Task.detached(priority: .utility) {
                InstalledAgentDetectors.detect(context: context)
            }.value
        }
    ) {
        self.context = context
        self.detector = detector
    }

    func start() {
        refresh()
    }

    func stop() {
        refreshGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
    }

    /// Starts a fresh bounded detection pass. A newer request supersedes the
    /// previous one even when its detached filesystem scan cannot stop
    /// immediately; only the latest generation may publish records.
    @discardableResult
    func refresh() -> Task<Void, Never> {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        refreshTask?.cancel()
        isRefreshing = true
        let context = context
        let detector = detector
        let task = Task { [weak self] in
            let detected = await detector(context)
            guard let self, self.refreshGeneration == generation else { return }
            guard !Task.isCancelled else {
                isRefreshing = false
                refreshTask = nil
                return
            }
            records = detected
            lastRefreshedAt = Date()
            isRefreshing = false
            refreshTask = nil
        }
        refreshTask = task
        return task
    }

    func record(id: InstalledAgentID) -> InstalledAgentRecord? {
        records.first { $0.id == id }
    }
}
