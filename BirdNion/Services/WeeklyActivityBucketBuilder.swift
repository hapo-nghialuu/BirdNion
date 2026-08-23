import Foundation

enum WeeklyActivityBucketBuilder {
    static func buildSnapshot(
        document: CostHistoryStore.Document,
        agentIDs: [InstalledAgentID],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> AgentActivitySnapshot {
        let pairs = agentIDs.compactMap { id in
            id.costHistorySource.map { (id, $0) }
        }
        let byAgent = Dictionary(uniqueKeysWithValues: pairs.map { id, source in
            (id, build(document: document, sources: [source], now: now, calendar: calendar))
        })
        return AgentActivitySnapshot(
            overall: build(
                document: document,
                sources: Set(pairs.map(\.1)),
                now: now,
                calendar: calendar
            ),
            byAgent: byAgent
        )
    }

    static func build(
        document: CostHistoryStore.Document,
        sources: Set<CostHistoryStore.Source>,
        now: Date = Date(),
        calendar: Calendar = .current,
        weekCount: Int = 52
    ) -> AgentActivityWindow {
        guard weekCount > 0 else { return AgentActivityWindow(weeks: []) }

        let currentWeek = startOfWeek(containing: now, calendar: calendar)
        let firstWeek = calendar.date(
            byAdding: .weekOfYear,
            value: -(weekCount - 1),
            to: currentWeek
        ) ?? currentWeek

        struct Accumulator {
            var usd = 0.0
            var tokens = 0
            var activeDays = Set<Date>()
            var hasEvidence = false
        }

        var totals: [Date: Accumulator] = [:]
        for source in sources {
            for (dayKey, day) in document.sources?[source.rawValue] ?? [:] {
                guard let date = CostHistoryStore.parseDayKey(dayKey, calendar: calendar) else { continue }
                let week = startOfWeek(containing: date, calendar: calendar)
                guard week >= firstWeek, week <= currentWeek else { continue }
                var value = totals[week] ?? Accumulator()
                value.usd += day.usd
                value.tokens += day.tokens
                value.hasEvidence = true
                if day.usd > 0 || day.tokens > 0 {
                    value.activeDays.insert(calendar.startOfDay(for: date))
                }
                totals[week] = value
            }
        }

        let weeks = (0..<weekCount).compactMap { offset -> AgentActivityWeek? in
            guard let start = calendar.date(
                byAdding: .weekOfYear,
                value: offset,
                to: firstWeek
            ) else { return nil }
            let value = totals[start] ?? Accumulator()
            return AgentActivityWeek(
                startDate: start,
                usd: value.usd,
                tokens: value.tokens,
                activeDays: value.activeDays.count,
                hasEvidence: value.hasEvidence
            )
        }
        return AgentActivityWindow(weeks: weeks)
    }

    private static func startOfWeek(containing date: Date, calendar: Calendar) -> Date {
        var cal = calendar
        cal.firstWeekday = 2 // Monday
        if let interval = cal.dateInterval(of: .weekOfYear, for: date) {
            return cal.startOfDay(for: interval.start)
        }
        return cal.startOfDay(for: date)
    }
}
