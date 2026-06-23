import Foundation
import Combine

/// Polls every enabled provider in parallel on a 120s ± 10s loop.
/// Throwing providers are caught and recorded on the status (no crash).
@MainActor
final class QuotaService: ObservableObject {
    @Published private(set) var statuses: [ProviderStatus] = []
    @Published private(set) var isRefreshing: Bool = false

    private(set) var providers: [QuotaProvider] = []
    private let interval: TimeInterval
    private var loopTask: Task<Void, Never>?

    init(providers: [QuotaProvider] = [], interval: TimeInterval = 120) {
        self.providers = providers
        self.interval = interval
    }

    func add(_ p: QuotaProvider) {
        providers.append(p)
    }

    func remove(id: String) {
        providers.removeAll { $0.id == id }
        statuses.removeAll { $0.id == id }
    }

    func setEnabled(_ enabled: Bool, for id: String) {
        if enabled {
            // already present? no-op
        } else {
            remove(id: id)
        }
    }

    func start() {
        guard loopTask == nil else { return }
        // Manual refresh hook from footer button (.aistatusbarRefresh)
        NotificationCenter.default.addObserver(
            forName: .aistatusbarRefresh, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.refresh() }
        }
        loopTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            while !Task.isCancelled {
                let jitter = Double.random(in: -10...10)
                let delay = max(60.0, self.interval + jitter)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled { break }
                await self.refresh()
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        let snapshot = providers
        let newStatuses: [ProviderStatus] = await withTaskGroup(of: ProviderStatus.self) { group in
            for p in snapshot {
                group.addTask {
                    do {
                        return try await p.fetch()
                    } catch {
                        return ProviderStatus(id: p.id, displayName: p.displayName,
                                              windows: [], lastUpdated: Date(),
                                              error: "\(error)")
                    }
                }
            }
            var results: [ProviderStatus] = []
            for await s in group { results.append(s) }
            return results
        }
        // Merge: preserve order of current providers; replace by id
        var byId = Dictionary(uniqueKeysWithValues: newStatuses.map { ($0.id, $0) })
        statuses = providers.compactMap { byId.removeValue(forKey: $0.id) }
    }
}
