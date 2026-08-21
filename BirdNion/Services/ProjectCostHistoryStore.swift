import Foundation

/// Optional project-level history. It is deliberately isolated from
/// `cost-history.json`, so missing/corrupt project data cannot affect quota,
/// budget, confidence, or digest flows.
enum ProjectCostHistoryStore {
    static let version = 1
    static let retainDays = 400
    private static let maximumUSD = 1_000_000_000.0
    private static let maximumTokens = 1_000_000_000_000
    private static let modelLimit = 5
    private static let ioLock = NSLock()

    struct Model: Codable, Equatable, Sendable {
        var name: String
        var usd: Double
        var tokens: Int
    }

    struct Day: Codable, Equatable, Sendable {
        var usd: Double
        var tokens: Int
        var models: [Model]
    }

    struct Project: Codable, Equatable, Sendable {
        var displayName: String
        var attribution: ProjectAttribution
        var days: [String: Day]
    }

    struct Document: Codable, Equatable, Sendable {
        var version: Int?
        var sources: [String: [String: Project]]?
        var appliedRetractionIDs: [String: [String]]? = nil
    }

    struct Retraction: Equatable, Sendable {
        let id: String
        let projectKey: String
        let daily: [ProjectDailyUsage]
    }

    static func historyURL(configURL: URL = BirdNionConfigStore.configURL()) -> URL {
        configURL.deletingLastPathComponent().appendingPathComponent("project-cost-history.json")
    }

    static func read(url: URL = historyURL()) -> Document {
        guard let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(Document.self, from: data)
        else { return Document(version: version, sources: [:]) }
        return sanitized(document)
    }

    static func write(_ document: Document, url: URL = historyURL()) throws {
        let safe = sanitized(document)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(safe)
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".project-cost-history.\(UUID().uuidString).tmp")
        guard fileManager.createFile(
            atPath: temporaryURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600])
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let handle = try FileHandle(forWritingTo: temporaryURL)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            try fileManager.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: url)
            }
            try fileManager.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // An Insights cache is optional; retaining it with broader
            // permissions is not. Remove the just-written file and let the
            // caller degrade to aggregate/Unknown data.
            try? fileManager.removeItem(at: temporaryURL)
            if fileManager.fileExists(atPath: url.path),
               let permissions = try? fileManager.attributesOfItem(atPath: url.path)[.posixPermissions]
                    as? NSNumber,
               permissions.intValue != 0o600 {
                try? fileManager.removeItem(at: url)
            }
            throw error
        }
    }

    static func preferHigher(_ current: Day, _ incoming: Day) -> Day {
        if incoming.tokens != current.tokens { return incoming.tokens > current.tokens ? incoming : current }
        if incoming.usd != current.usd { return incoming.usd > current.usd ? incoming : current }
        return incoming.models.count >= current.models.count ? incoming : current
    }

    static func merge(
        document: Document,
        source: ProjectUsageSource,
        liveProjects: [ProjectUsageRecord],
        now: Date = Date(),
        calendar: Calendar = .current,
        retainDays: Int = retainDays,
        replacingSource: Bool = false,
        retractions: [Retraction] = []
    ) -> Document {
        var sources = document.sources ?? [:]
        var projects = replacingSource ? [:] : (sources[source.rawValue] ?? [:])
        var applied = document.appliedRetractionIDs ?? [:]
        var appliedForSource = Set(applied[source.rawValue] ?? [])

        for retraction in retractions where !appliedForSource.contains(retraction.id) {
            guard retraction.id.count == 64,
                  retraction.id.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
                  ProjectIdentity.safeKey(retraction.projectKey) == retraction.projectKey
            else { continue }
            if var project = projects[retraction.projectKey] {
                for row in retraction.daily {
                    let dayKey = CostHistoryStore.dayKey(row.date, calendar: calendar)
                    guard var stored = project.days[dayKey] else { continue }
                    stored.usd = max(0, stored.usd - max(0, row.usd))
                    stored.tokens = max(0, stored.tokens - max(0, row.tokens))
                    var removals: [String: (usd: Double, tokens: Int)] = [:]
                    for model in row.models {
                        let name = ProjectIdentity.safeModelName(model.name)
                        var value = removals[name] ?? (0, 0)
                        value.usd += max(0, model.usd)
                        value.tokens += max(0, model.tokens)
                        removals[name] = value
                    }
                    stored.models = stored.models.compactMap { model in
                        let removal = removals[model.name] ?? (0, 0)
                        let updated = Model(
                            name: model.name,
                            usd: max(0, model.usd - removal.usd),
                            tokens: max(0, model.tokens - removal.tokens))
                        return updated.usd > 0 || updated.tokens > 0 ? updated : nil
                    }
                    if stored.usd > 0 || stored.tokens > 0 {
                        project.days[dayKey] = stored
                    } else {
                        project.days.removeValue(forKey: dayKey)
                    }
                }
                if project.days.isEmpty {
                    projects.removeValue(forKey: retraction.projectKey)
                } else {
                    projects[retraction.projectKey] = project
                }
            }
            appliedForSource.insert(retraction.id)
        }
        applied[source.rawValue] = appliedForSource.sorted()

        for live in liveProjects where live.source == source {
            let key = ProjectIdentity.safeKey(live.projectKey)
            let name = ProjectIdentity.safeDisplayName(live.displayName, key: key)
            var stored = projects[key] ?? Project(
                displayName: name, attribution: live.attribution, days: [:])
            stored.displayName = name
            stored.attribution = live.attribution
            for row in live.daily {
                let dayKey = CostHistoryStore.dayKey(row.date, calendar: calendar)
                let incoming = Day(
                    usd: row.usd, tokens: row.tokens,
                    models: row.models.map {
                        Model(
                            name: ProjectIdentity.safeModelName($0.name),
                            usd: $0.usd,
                            tokens: $0.tokens)
                    })
                if !replacingSource, let current = stored.days[dayKey] {
                    stored.days[dayKey] = preferHigher(current, incoming)
                } else if incoming.usd > 0 || incoming.tokens > 0 {
                    stored.days[dayKey] = incoming
                }
            }
            projects[key] = stored
        }

        let today = calendar.startOfDay(for: now)
        let pruneBefore = calendar.date(byAdding: .day, value: -(retainDays - 1), to: today) ?? today
        projects = projects.compactMapValues { project in
            var copy = project
            copy.days = project.days.filter { key, _ in
                strictDate(from: key, calendar: calendar).map { $0 >= pruneBefore } ?? false
            }
            return copy.days.isEmpty ? nil : copy
        }
        sources[source.rawValue] = projects
        return sanitized(
            Document(version: version, sources: sources, appliedRetractionIDs: applied),
            calendar: calendar)
    }

    @discardableResult
    static func apply(
        source: ProjectUsageSource,
        liveProjects: [ProjectUsageRecord],
        now: Date = Date(),
        calendar: Calendar = .current,
        url: URL = historyURL(),
        replacingSource: Bool = false,
        retractions: [Retraction] = []
    ) -> Document {
        ioLock.lock()
        defer { ioLock.unlock() }
        let updated = merge(
            document: read(url: url), source: source, liveProjects: liveProjects,
            now: now, calendar: calendar, replacingSource: replacingSource,
            retractions: retractions)
        try? write(updated, url: url)
        return updated
    }

    private static func sanitized(
        _ document: Document,
        calendar: Calendar = .current
    ) -> Document {
        var safeSources: [String: [String: Project]] = [:]
        for (source, projects) in document.sources ?? [:] {
            guard ProjectUsageSource(rawValue: source) != nil else { continue }
            var safeProjects: [String: Project] = [:]
            for (rawKey, project) in projects {
                let key = ProjectIdentity.safeKey(rawKey)
                var copy = project
                copy.displayName = ProjectIdentity.safeDisplayName(project.displayName, key: key)
                copy.days = Dictionary(uniqueKeysWithValues: copy.days.compactMap { dayKey, day in
                    guard strictDate(from: dayKey, calendar: calendar) != nil else { return nil }
                    var safeDay = day
                    safeDay.usd = safeUSD(day.usd)
                    safeDay.tokens = safeTokens(day.tokens)
                    safeDay.models = safeModels(day.models)
                    return (dayKey, safeDay)
                })
                if let existing = safeProjects[key] {
                    for (day, value) in existing.days {
                        copy.days[day] = copy.days[day].map { preferHigher(value, $0) } ?? value
                    }
                }
                safeProjects[key] = copy
            }
            safeSources[source] = safeProjects
        }
        var safeRetractions: [String: [String]] = [:]
        for (source, ids) in document.appliedRetractionIDs ?? [:]
        where ProjectUsageSource(rawValue: source) != nil {
            safeRetractions[source] = Array(Set(ids.filter {
                $0.count == 64 && $0.allSatisfy { $0.isHexDigit && !$0.isUppercase }
            })).sorted()
        }
        return Document(
            version: version,
            sources: safeSources,
            appliedRetractionIDs: safeRetractions)
    }

    private static func safeUSD(_ value: Double) -> Double {
        value.isFinite && value >= 0 && value <= maximumUSD ? value : 0
    }

    private static func safeTokens(_ value: Int) -> Int {
        value >= 0 && value <= maximumTokens ? value : 0
    }

    private static func safeModels(_ models: [Model]) -> [Model] {
        var merged: [String: (usd: Double, tokens: Double)] = [:]
        for model in models {
            let name = ProjectIdentity.safeModelName(model.name)
            var total = merged[name] ?? (0, 0)
            total.usd = min(maximumUSD, total.usd + safeUSD(model.usd))
            total.tokens = min(
                Double(maximumTokens),
                total.tokens + Double(safeTokens(model.tokens)))
            merged[name] = total
        }
        return Array(merged.map {
            Model(
                name: $0.key,
                usd: $0.value.usd,
                tokens: Int($0.value.tokens))
        }.filter { $0.usd > 0 || $0.tokens > 0 }
            .sorted {
                if $0.usd != $1.usd { return $0.usd > $1.usd }
                if $0.tokens != $1.tokens { return $0.tokens > $1.tokens }
                return $0.name < $1.name
            }
            .prefix(modelLimit))
    }

    private static func strictDate(from key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) }),
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2])
        else { return nil }

        let components = DateComponents(year: year, month: month, day: day)
        guard let parsed = calendar.date(from: components) else { return nil }
        let normalized = calendar.startOfDay(for: parsed)
        return CostHistoryStore.dayKey(normalized, calendar: calendar) == key ? normalized : nil
    }
}
