import XCTest
@testable import BirdNion

final class QuotaAgendaProjectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testChoosesNearestExplicitFutureResetInsteadOfLowestPercent() {
        let status = makeStatus(windows: [
            QuotaWindow(
                label: "Bonus", usedPct: 99, remainingPct: 1,
                resetDate: now.addingTimeInterval(60), isSupplementary: true),
            QuotaWindow(
                label: "Inactive", usedPct: 99, remainingPct: 1,
                resetDate: now.addingTimeInterval(120), isInactive: true),
            QuotaWindow(
                label: "Gia hạn", usedPct: 0, remainingPct: 100,
                resetDate: now.addingTimeInterval(180)),
            QuotaWindow(label: "Lowest", usedPct: 96, remainingPct: 4),
            QuotaWindow(
                label: "Later", usedPct: 90, remainingPct: 10,
                resetDate: now.addingTimeInterval(7_200)),
            QuotaWindow(
                label: "Next", usedPct: 20, remainingPct: 80,
                resetDate: now.addingTimeInterval(3_600)),
        ])

        let row = project([status]).first

        XCTAssertEqual(row?.windowLabel, "Next")
        XCTAssertEqual(row?.remaining, .current(80))
        XCTAssertEqual(row?.resetState, .scheduled(now.addingTimeInterval(3_600)))
    }

    func testSortsScheduledAscendingThenAwaitingUnknownAndStale() {
        let soon = makeStatus(
            id: "soon", windows: [window("Soon", reset: now.addingTimeInterval(60))])
        let late = makeStatus(
            id: "late", windows: [window("Late", reset: now.addingTimeInterval(600))])
        let pastReset = now.addingTimeInterval(-60)
        let awaiting = makeStatus(
            id: "awaiting",
            windows: [window("Await", reset: pastReset)],
            observedAt: pastReset.addingTimeInterval(-60))
        let unknown = makeStatus(
            id: "unknown",
            windows: [QuotaWindow(
                label: "Unknown", usedPct: 30, remainingPct: 70,
                windowSeconds: 3_600)])
        let stale = makeStatus(
            id: "stale", windows: [window("Stale", reset: now.addingTimeInterval(30))])

        let rows = project(
            [unknown, stale, late, awaiting, soon],
            staleProviderIDs: ["stale"])

        XCTAssertEqual(rows.map(\.providerID), ["soon", "late", "awaiting", "unknown", "stale"])
    }

    func testPastResetObservedBeforeResetInvalidatesCurrentPercent() {
        let reset = now.addingTimeInterval(-60)
        let status = makeStatus(
            windows: [window("5h", remaining: 64, reset: reset)],
            observedAt: reset.addingTimeInterval(-1))

        let row = project([status]).first

        XCTAssertEqual(row?.resetState, .awaitingRefresh)
        XCTAssertEqual(row?.remaining, .unavailable)
    }

    func testPastResetObservedAfterResetKeepsObservedPercentButNotNextResetClaim() {
        let reset = now.addingTimeInterval(-60)
        let status = makeStatus(
            windows: [window("5h", remaining: 64, reset: reset)],
            observedAt: reset.addingTimeInterval(1))

        let row = project([status]).first

        XCTAssertEqual(row?.resetState, .unknown)
        XCTAssertEqual(row?.remaining, .current(64))
    }

    func testMissingResetDoesNotInferScheduleFromWindowSeconds() {
        let status = makeStatus(windows: [
            QuotaWindow(
                label: "Week", usedPct: 42, remainingPct: 58,
                windowSeconds: 604_800),
        ])

        let row = project([status]).first

        XCTAssertEqual(row?.resetState, .unknown)
        XCTAssertEqual(row?.remaining, .current(58))
    }

    func testStaleUsesLastKnownPercentAndSuppressesNextReset() {
        let status = makeStatus(
            id: "stale",
            windows: [window("5h", remaining: 39, reset: now.addingTimeInterval(60))])

        let row = project([status], staleProviderIDs: ["stale"]).first

        XCTAssertEqual(row?.resetState, .staleLastKnown)
        XCTAssertEqual(row?.remaining, .lastKnown(39))
        XCTAssertTrue(row?.metadata.isStale == true)
    }

    func testOmitsAmbiguousProviderPlaceholders() {
        let kiro = makeStatus(
            id: "kiro",
            windows: [QuotaWindow(label: "Credits", usedPct: 0, remainingPct: 100)])
        let cursor = makeStatus(
            id: "cursor",
            windows: [
                QuotaWindow(
                    label: "Plan", usedPct: 0, remainingPct: 100,
                    subtitle: "$0.00"),
                QuotaWindow(
                    label: "On-demand", usedPct: 0, remainingPct: 100,
                    subtitle: "$5.00 / $0.00"),
            ])
        let claudeAdmin = makeStatus(
            id: "claude",
            windows: [QuotaWindow(
                label: "Chi phí 30 ngày", usedPct: 0, remainingPct: 100,
                subtitle: "$42.00")])

        XCTAssertTrue(project([kiro, cursor, claudeAdmin]).isEmpty)
    }

    func testKeepsCursorZeroUsageWhenSourceProvidesDenominator() {
        let cursor = makeStatus(
            id: "cursor",
            windows: [QuotaWindow(
                label: "Plan", usedPct: 0, remainingPct: 100,
                subtitle: "$0.00 / $20.00")])

        XCTAssertEqual(project([cursor]).first?.remaining, .current(100))
    }

    func testMetadataBuilderNeverCarriesPersonalLabelWhenPrivacyIsEnabled() {
        let status = makeStatus(
            accountLabel: "person@example.com",
            sourceLabel: "OAuth")

        let hidden = QuotaAgendaProjection.metadata(
            for: status, hidePersonalInfo: true, stale: false)
        let visible = QuotaAgendaProjection.metadata(
            for: status, hidePersonalInfo: false, stale: false)

        XCTAssertEqual(hidden.account, .hidden)
        XCTAssertEqual(hidden.sourceLabel, "OAuth")
        XCTAssertEqual(visible.account, .named("person@example.com"))
    }

    private func project(
        _ statuses: [ProviderStatus],
        staleProviderIDs: Set<String> = []
    ) -> [QuotaAgendaProjection] {
        QuotaAgendaProjection.build(
            statuses: statuses,
            staleProviderIDs: staleProviderIDs,
            hidePersonalInfo: false,
            now: now)
    }

    private func makeStatus(
        id: String = "provider",
        windows: [QuotaWindow] = [QuotaWindow(
            label: "5h", usedPct: 20, remainingPct: 80)],
        observedAt: Date? = nil,
        accountLabel: String? = nil,
        sourceLabel: String? = nil
    ) -> ProviderStatus {
        ProviderStatus(
            id: id,
            displayName: id.capitalized,
            windows: windows,
            lastUpdated: observedAt ?? now,
            accountLabel: accountLabel,
            sourceLabel: sourceLabel)
    }

    private func window(
        _ label: String,
        remaining: Int = 50,
        reset: Date
    ) -> QuotaWindow {
        QuotaWindow(
            label: label,
            usedPct: 100 - remaining,
            remainingPct: remaining,
            resetDate: reset)
    }
}
