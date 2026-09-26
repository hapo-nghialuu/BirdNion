import Foundation

/// Single owner for the seven local cost scanners (Claude, Codex, Grok, Kiro,
/// OMP, Pi, Devin). Centralizes the 300s cache TTL + per-source single-flight
/// so concurrent callers (QuotaPanel, InsightsPane, WeeklyDigest) share one
/// scan instead of triplicating work. The scanners' own internal caches stay
/// as a second layer — this coordinator only dedupes the entry points.
///
/// `MainActor` owns the lane state; the scans themselves run off-main
/// (`Task.detached` + the scanners already do their I/O on `.utility`).
@MainActor
final class UsageReportCoordinator {

    /// Mirrors each scanner's internal `cacheTTL` (300s everywhere). The
    /// scanner constants stay `private`; this is the coordinator-level TTL.
    static let cacheTTL: TimeInterval = 300

    static private(set) var shared = UsageReportCoordinator()

    #if DEBUG
    /// Test seam: swap the process-wide instance — production call sites read
    /// `.shared`, so rewired-path tests inject their stub here.
    static func installForTesting(_ coordinator: UsageReportCoordinator) {
        shared = coordinator
    }
    #endif

    /// One source's cache entry + in-flight scan task. `Report` is the
    /// concrete report type — no type erasure.
    struct SingleFlightCache<Report: Sendable>: Sendable {
        var cached: (report: Report, at: Date)?
        var inFlight: Task<Report?, Never>?
    }

    /// Injectable scan closures — tests substitute counters/gates without
    /// touching the real filesystem scanners. `seeded*` reads the persisted
    /// `CostHistoryStore` snapshot (cheap, uncached — a coordinator cache
    /// would only serve a stale seed longer).
    struct Scans: Sendable {
        var claude: @Sendable () async -> ClaudeUsageReport?
        var codex: @Sendable () async -> CodexUsageReport?
        var grok: @Sendable () async -> GrokUsageReport?
        var kiro: @Sendable () async -> KiroUsageReport?
        var omp: @Sendable () async -> OMPUsageReport?
        var pi: @Sendable () async -> PiUsageReport?
        var devin: @Sendable () async -> DevinCLIUsageReport?
        var seededClaude: @Sendable () async -> ClaudeUsageReport?
        var seededCodex: @Sendable () async -> CodexUsageReport?
        var seededGrok: @Sendable () async -> GrokUsageReport?
        var seededKiro: @Sendable () async -> KiroUsageReport?
        var seededOMP: @Sendable () async -> OMPUsageReport?
        var seededPi: @Sendable () async -> PiUsageReport?
        var seededDevin: @Sendable () async -> DevinCLIUsageReport?
        /// Lighter cost summaries for the Providers settings card — same
        /// TTL + single-flight dedupe as the full reports.
        var claudeSummary: @Sendable () async -> ClaudeCostSummary?
        var codexSummary: @Sendable () async -> CodexCostSummary?
        var now: @Sendable () -> Date

        static let live = Scans(
            claude: { await ClaudeCostScanner.usageReport() },
            codex: { await CodexCostScanner.usageReport() },
            grok: { await GrokCostScanner.usageReport() },
            kiro: { await KiroCostScanner.usageReport() },
            omp: { await OMPCostScanner.loadReport() },
            pi: { await PiCostScanner.loadReport() },
            devin: { await DevinCostScanner.loadReport() },
            seededClaude: { await ClaudeCostScanner.seededReport() },
            seededCodex: { await CodexCostScanner.seededReport() },
            seededGrok: { await GrokCostScanner.seededReport() },
            seededKiro: { await KiroCostScanner.seededReport() },
            seededOMP: { await OMPCostScanner.seededReport() },
            seededPi: { await PiCostScanner.seededReport() },
            seededDevin: { await DevinCostScanner.seededReport() },
            claudeSummary: { await ClaudeCostScanner.summary() },
            codexSummary: { await CodexCostScanner.summary() },
            now: { Date() })
    }

    private let scans: Scans

    private var claudeLane = SingleFlightCache<ClaudeUsageReport>()
    private var codexLane = SingleFlightCache<CodexUsageReport>()
    private var grokLane = SingleFlightCache<GrokUsageReport>()
    private var kiroLane = SingleFlightCache<KiroUsageReport>()
    private var ompLane = SingleFlightCache<OMPUsageReport>()
    private var piLane = SingleFlightCache<PiUsageReport>()
    private var devinLane = SingleFlightCache<DevinCLIUsageReport>()
    private var claudeSummaryLane = SingleFlightCache<ClaudeCostSummary>()
    private var codexSummaryLane = SingleFlightCache<CodexCostSummary>()

    nonisolated init(scans: Scans = .live) {
        self.scans = scans
    }

    // MARK: - Typed report API

    func claudeReport() async -> ClaudeUsageReport? {
        await report(\.claudeLane, scan: scans.claude)
    }

    func codexReport() async -> CodexUsageReport? {
        await report(\.codexLane, scan: scans.codex)
    }

    func grokReport() async -> GrokUsageReport? {
        await report(\.grokLane, scan: scans.grok)
    }

    func kiroReport() async -> KiroUsageReport? {
        await report(\.kiroLane, scan: scans.kiro)
    }

    func ompReport() async -> OMPUsageReport? {
        await report(\.ompLane, scan: scans.omp)
    }

    func piReport() async -> PiUsageReport? {
        await report(\.piLane, scan: scans.pi)
    }

    func devinReport() async -> DevinCLIUsageReport? {
        await report(\.devinLane, scan: scans.devin)
    }

    func claudeSummary() async -> ClaudeCostSummary? {
        await report(\.claudeSummaryLane, scan: scans.claudeSummary)
    }

    func codexSummary() async -> CodexCostSummary? {
        await report(\.codexSummaryLane, scan: scans.codexSummary)
    }

    // MARK: - Persisted seeds (uncached pass-through)

    func seededClaudeReport() async -> ClaudeUsageReport? { await scans.seededClaude() }
    func seededCodexReport() async -> CodexUsageReport? { await scans.seededCodex() }
    func seededGrokReport() async -> GrokUsageReport? { await scans.seededGrok() }
    func seededKiroReport() async -> KiroUsageReport? { await scans.seededKiro() }
    func seededOMPReport() async -> OMPUsageReport? { await scans.seededOMP() }
    func seededPiReport() async -> PiUsageReport? { await scans.seededPi() }
    func seededDevinReport() async -> DevinCLIUsageReport? { await scans.seededDevin() }

    /// Drops every lane's cached entry (in-flight scans finish untouched).
    /// Keeps scanner-level invalidation (`CodexCostScanner.invalidateCaches()`
    /// after extra-home changes, counting-revision bumps) effective — without
    /// this, a warm coordinator cache would serve stale reports for up to TTL.
    func invalidateAll() {
        claudeLane.cached = nil
        codexLane.cached = nil
        grokLane.cached = nil
        kiroLane.cached = nil
        ompLane.cached = nil
        piLane.cached = nil
        devinLane.cached = nil
        claudeSummaryLane.cached = nil
        codexSummaryLane.cached = nil
    }

    // MARK: - Single-flight core

    /// TTL → in-flight share → detached scan → cache write on success. A nil
    /// (failed/empty) scan is never cached, so the next caller retries.
    private func report<Report: Sendable>(
        _ lane: ReferenceWritableKeyPath<UsageReportCoordinator, SingleFlightCache<Report>>,
        scan: @escaping @Sendable () async -> Report?
    ) async -> Report? {
        if let cached = self[keyPath: lane].cached,
           scans.now().timeIntervalSince(cached.at) < Self.cacheTTL {
            return cached.report
        }
        if let inFlight = self[keyPath: lane].inFlight {
            return await inFlight.value
        }
        let task = Task.detached { await scan() }
        self[keyPath: lane].inFlight = task
        let result = await task.value
        self[keyPath: lane].inFlight = nil
        if let result {
            self[keyPath: lane].cached = (result, scans.now())
        }
        return result
    }
}
