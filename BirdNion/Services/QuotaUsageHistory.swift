import Foundation

/// Rolling history of remaining-quota samples per provider+window — powers
/// the runway forecast ("hết sau ~X ngày") for windows that carry no reset
/// schedule, and the per-window sparkline.
///
/// One `QuotaUsageSample` per (provider, windowLabel) every `minSampleInterval`
/// on each `QuotaService.statuses` publish, persisted to
/// `~/.config/birdnion/quota-history.json` (atomic, debounced). Fail soft: a
/// write error only leaves a stale file.
struct QuotaUsageSample: Codable, Equatable, Sendable {
    let at: Date
    let remainingPct: Int
}

enum QuotaUsageHistory {
    /// Minimum gap between persisted samples for the same window — quota
    /// publishes can land minutes apart and the burn rate needs days, not
    /// minutes, of signal.
    static let minSampleInterval: TimeInterval = 30 * 60
    /// Samples older than this are dropped on every append.
    static let retention: TimeInterval = 30 * 86400
    /// Burn rate needs at least this much span between first/last sample.
    static let minBurnSpan: TimeInterval = 6 * 3600

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/birdnion/quota-history.json")
    }

    static func key(provider: String, window: String) -> String {
        "\(provider)|\(QuotaWarnConfig.windowKey(window))"
    }

    // MARK: - Recording (publish seam)

    /// Called from `QuotaService.statuses.didSet`. In-memory update is
    /// immediate; the file write is debounced so a burst of lane merges
    /// produces one disk write.
    static func record(_ statuses: [ProviderStatus], now: Date = Date()) {
        var touched = false
        var samples = loadAll()
        for status in statuses where status.error == nil {
            for window in status.windows where !window.isSupplementary && !window.isInactive {
                let key = key(provider: status.id, window: window.label)
                var list = samples[key] ?? []
                if let last = list.last, now.timeIntervalSince(last.at) < minSampleInterval {
                    continue
                }
                list.append(QuotaUsageSample(at: now, remainingPct: window.remainingPct))
                let cutoff = now.addingTimeInterval(-retention)
                samples[key] = list.filter { $0.at >= cutoff }
                touched = true
            }
        }
        guard touched else { return }
        allSamples = samples
        scheduleWrite(samples)
    }

    // MARK: - Queries

    /// Samples for one window, oldest first.
    static func samples(provider: String, window: String) -> [QuotaUsageSample] {
        allSamples[key(provider: provider, window: window)] ?? []
    }

    /// Days until the window hits 0% at the observed burn rate — linear
    /// slope over the first→last sample in the recent window. nil when the
    /// burn is zero/negative or the history has too little span.
    static func runwayDays(
        provider: String, window: String, now: Date = Date()
    ) -> Double? {
        runwayDays(samples: samples(provider: provider, window: window), now: now)
    }

    /// Pure calculation — unit-testable. Uses the oldest sample within the
    /// last 7 days against the newest; requires ≥ minBurnSpan of coverage.
    static func runwayDays(
        samples: [QuotaUsageSample], now: Date = Date()
    ) -> Double? {
        let recent = samples.filter { now.timeIntervalSince($0.at) <= 7 * 86400 }
        guard let first = recent.first, let last = recent.last,
              last.at.timeIntervalSince(first.at) >= minBurnSpan
        else { return nil }
        let burned = Double(first.remainingPct - last.remainingPct)
        guard burned > 0 else { return nil }
        let days = last.at.timeIntervalSince(first.at) / 86400
        guard days > 0 else { return nil }
        return Double(last.remainingPct) / (burned / days)
    }

    // MARK: - Storage

    /// Loaded once, kept warm; `record` mutates it before scheduling a write.
    private static var allSamples: [String: [QuotaUsageSample]] = {
        (try? JSONDecoder().decode(
            [String: [QuotaUsageSample]].self,
            from: Data(contentsOf: fileURL))) ?? [:]
    }()

    private static func loadAll() -> [String: [QuotaUsageSample]] { allSamples }

    private static var writeTask: Task<Void, Never>?

    private static func scheduleWrite(_ samples: [String: [QuotaUsageSample]]) {
        writeTask?.cancel()
        let url = fileURL
        writeTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(samples) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// Test hook: replace the in-memory store without touching disk.
    static func seed(_ samples: [String: [QuotaUsageSample]]) {
        allSamples = samples
    }
}
