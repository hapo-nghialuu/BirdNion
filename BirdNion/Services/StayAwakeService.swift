import Foundation
import IOKit.pwr_mgt

/// Opt-in stay-awake setting (ported from CodexBar). `SettingsStore` exposes
/// the same UserDefaults key via `@AppStorage`; the service reads it directly
/// on every tick so toggle changes apply without rebinding.
enum StayAwakeConfig {
    static let enabledKey = "stayAwakeEnabled"
    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// A session file touched within this window counts the agent as live.
    static let activityFreshness: TimeInterval = 10 * 60
    static let pollInterval: TimeInterval = 60
}

/// Session-log roots watched for live-agent evidence. These mirror the
/// directories the cost scanners already read — a session still writing
/// transcript files is an active session, no process scan needed.
enum AgentSessionRoots {
    static func all(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        var roots = [
            home.appendingPathComponent(".claude/projects", isDirectory: true),
            home.appendingPathComponent(".config/claude/projects", isDirectory: true),
            home.appendingPathComponent(".codex/sessions", isDirectory: true),
            home.appendingPathComponent(".kiro_sessions", isDirectory: true),
            home.appendingPathComponent(".kiro/sessions", isDirectory: true),
            home.appendingPathComponent(".pi/agent/sessions", isDirectory: true),
            home.appendingPathComponent(".local/share/devin/cli/transcripts", isDirectory: true),
            home.appendingPathComponent(".grok/sessions", isDirectory: true),
        ]
        roots.append(contentsOf: OMPPaths.allSessionDirectories())
        return roots
    }
}

/// Holds an `IOPMAssertPreventUserIdleSystemSleep` assertion while a local
/// agent session is live (ported from CodexBar's AgentSessionPowerAssertion +
/// the stay-awake side of its agent-session monitor).
///
/// Detection is file-mtime based: every `pollInterval` a bounded walk of the
/// agent session dirs finds the newest transcript; activity within
/// `activityFreshness` means an agent is mid-session and the display/system
/// stays awake. The assertion drops as soon as writes stop or the toggle
/// turns off — it never survives beyond the configured freshness window.
@MainActor
final class StayAwakeService {
    private var timer: Timer?
    private var assertionID: IOPMAssertionID = 0
    private var holdingAssertion = false
    private var scanning = false

    private let rootsProvider: () -> [URL]
    private let enabled: () -> Bool
    private let now: () -> Date
    private let freshness: TimeInterval
    private let fileManager: FileManager

    init(
        rootsProvider: @escaping () -> [URL] = { AgentSessionRoots.all() },
        enabled: @escaping () -> Bool = { StayAwakeConfig.enabled },
        now: @escaping () -> Date = Date.init,
        freshness: TimeInterval = StayAwakeConfig.activityFreshness,
        fileManager: FileManager = .default
    ) {
        self.rootsProvider = rootsProvider
        self.enabled = enabled
        self.now = now
        self.freshness = freshness
        self.fileManager = fileManager
    }

    /// Pure decision (unit-tested): hold only when enabled AND a session file
    /// was touched inside the freshness window.
    static func shouldHoldAssertion(
        latestActivityAt: Date?,
        now: Date,
        enabled: Bool,
        freshness: TimeInterval
    ) -> Bool {
        guard enabled, let latestActivityAt else { return false }
        return now.timeIntervalSince(latestActivityAt) <= freshness
    }

    /// Bounded recursive mtime scan — caps entries per root so a huge
    /// `~/.claude/projects` tree costs a fixed amount of work per poll.
    nonisolated static func latestActivity(
        in roots: [URL],
        fileManager: FileManager = .default,
        maxEntriesPerRoot: Int = 2_000
    ) -> Date? {
        var latest: Date?
        for root in roots {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles])
            else { continue }
            var visited = 0
            for case let url as URL in enumerator {
                visited += 1
                if visited > maxEntriesPerRoot { enumerator.skipDescendants(); break }
                guard let values = try? url.resourceValues(
                    forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                    values.isRegularFile == true,
                    let modified = values.contentModificationDate
                else { continue }
                if latest == nil || modified > latest! { latest = modified }
            }
        }
        return latest
    }

    /// Starts the poll loop. Safe to call once at app start — when the toggle
    /// is off each tick is a cheap flag check and any stale assertion is
    /// released immediately.
    func start() {
        guard timer == nil else { return }
        tick()
        let t = Timer(timeInterval: StayAwakeConfig.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Current hold state — test seam for the acquire/release transitions.
    var isHoldingAssertion: Bool { holdingAssertion }

    func tick() {
        guard enabled() else {
            release()
            return
        }
        guard !scanning else { return }
        scanning = true
        let roots = rootsProvider()
        let fileManager = self.fileManager
        Task.detached(priority: .utility) { [weak self] in
            let latest = Self.latestActivity(in: roots, fileManager: fileManager)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.scanning = false
                self.evaluate(latestActivityAt: latest)
            }
        }
    }

    private func evaluate(latestActivityAt: Date?) {
        if Self.shouldHoldAssertion(
            latestActivityAt: latestActivityAt,
            now: now(),
            enabled: enabled(),
            freshness: freshness
        ) {
            acquire()
        } else {
            release()
        }
    }

    private func acquire() {
        guard !holdingAssertion else { return }
        var assertion: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "BirdNion: local agent session is live" as CFString,
            &assertion)
        if result == kIOReturnSuccess {
            assertionID = assertion
            holdingAssertion = true
        }
    }

    private func release() {
        guard holdingAssertion else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        holdingAssertion = false
    }
}
