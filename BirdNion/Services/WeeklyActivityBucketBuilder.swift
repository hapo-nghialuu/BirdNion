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

        let calendar = normalized(calendar)
        let today = calendar.startOfDay(for: now)
        let currentWeek = startOfWeek(containing: today, calendar: calendar)
        let firstWeek = calendar.date(
            byAdding: .weekOfYear,
            value: -(weekCount - 1),
            to: currentWeek
        ) ?? currentWeek

        struct DayAccumulator {
            var usd = 0.0
            var tokens = 0
            var hasEvidence = false
        }

        var dailyTotals: [Date: DayAccumulator] = [:]
        for source in sources {
            for (dayKey, day) in document.sources?[source.rawValue] ?? [:] {
                guard let date = CostHistoryStore.parseDayKey(dayKey, calendar: calendar) else { continue }
                let normalizedDate = calendar.startOfDay(for: date)
                let week = startOfWeek(containing: normalizedDate, calendar: calendar)
                guard normalizedDate <= today,
                      week >= firstWeek,
                      week <= currentWeek
                else { continue }
                var value = dailyTotals[normalizedDate] ?? DayAccumulator()
                value.usd += day.usd
                value.tokens += day.tokens
                value.hasEvidence = true
                dailyTotals[normalizedDate] = value
            }
        }

        let weeks = (0..<weekCount).compactMap { offset -> AgentActivityWeek? in
            guard let start = calendar.date(
                byAdding: .weekOfYear,
                value: offset,
                to: firstWeek
            ) else { return nil }
            let days = (0..<7).compactMap { dayOffset -> AgentActivityDay? in
                guard let date = calendar.date(byAdding: .day, value: dayOffset, to: start) else { return nil }
                let value = dailyTotals[date] ?? DayAccumulator()
                return AgentActivityDay(
                    date: date,
                    usd: value.usd,
                    tokens: value.tokens,
                    hasEvidence: value.hasEvidence)
            }
            return AgentActivityWeek(startDate: start, days: days)
        }
        let metrics = streakMetrics(
            days: weeks.flatMap(\.days).filter { $0.date <= today },
            today: today,
            calendar: calendar)
        return AgentActivityWindow(
            weeks: weeks,
            currentStreak: metrics.current,
            longestStreak: metrics.longest)
    }

    private static func startOfWeek(containing date: Date, calendar: Calendar) -> Date {
        if let interval = calendar.dateInterval(of: .weekOfYear, for: date) {
            return calendar.startOfDay(for: interval.start)
        }
        return calendar.startOfDay(for: date)
    }

    private static func normalized(_ source: Calendar) -> Calendar {
        var calendar = source
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    private static func streakMetrics(
        days: [AgentActivityDay],
        today: Date,
        calendar: Calendar
    ) -> (current: Int, longest: Int) {
        let ordered = days.sorted { $0.date < $1.date }
        var longest = 0
        var run = 0
        for day in ordered {
            if day.isActive {
                run += 1
                longest = max(longest, run)
            } else {
                run = 0
            }
        }

        let byDate = Dictionary(uniqueKeysWithValues: ordered.map { ($0.date, $0) })
        let todayEntry = byDate[today]
        var cursor = today
        if todayEntry?.isActive != true {
            cursor = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        }
        var current = 0
        while byDate[cursor]?.isActive == true {
            current += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return (current, longest)
    }
}
