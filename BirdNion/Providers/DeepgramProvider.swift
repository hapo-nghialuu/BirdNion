import Foundation

/// Deepgram (speech) usage provider. API key (header `Authorization: Token …`)
/// → lists projects, then sums the first project's 30-day usage breakdown
/// (requests + audio hours). No hard quota, so surfaced as info windows.
/// Native port of CodexBar's DeepgramUsageFetcher (simplified to one project).
final class DeepgramProvider: QuotaProvider {
    let id = "deepgram"
    let displayName = "Deepgram"

    static let base = URL(string: "https://api.deepgram.com/v1")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    private func override() -> String? { BirdNionConfigStore.accountLabel(provider: id) }

    func fetch() async throws -> ProviderStatus {
        guard let token = BirdNionConfigStore.apiKey(provider: id), !token.isEmpty else {
            return failure("Chưa cấu hình API key Deepgram")
        }
        let accountLabel = override() ?? String(token.prefix(8))

        do {
            // 1. Resolve ALL projects for this key.
            let projects = try await get(Self.base.appendingPathComponent("projects"),
                                         token: token, as: ProjectsResponse.self)
            guard !projects.projects.isEmpty else {
                return failure("Không có project Deepgram cho key này")
            }
            // Optional Project ID filter: when set in Settings, fetch ONLY that
            // project; blank = aggregate every project visible to the key.
            let configPID = BirdNionConfigStore.provider(id: id)?.projectID?
                .trimmingCharacters(in: .whitespaces)
            var targetProjects = projects.projects
            if let pid = configPID, !pid.isEmpty {
                let matched = projects.projects.filter { $0.projectID == pid }
                targetProjects = matched.isEmpty ? [Project(projectID: pid, name: nil)] : matched
            }
            // 2. Aggregate the 30-day usage breakdown across the target project(s).
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "yyyy-MM-dd"
            let now = Date()
            let start = df.string(from: now.addingTimeInterval(-30 * 86_400))
            let end = df.string(from: now)

            var agg = Aggregate()
            var ok = 0
            for project in targetProjects {
                var comp = URLComponents(
                    url: Self.base.appendingPathComponent("projects").appendingPathComponent(project.projectID)
                        .appendingPathComponent("usage").appendingPathComponent("breakdown"),
                    resolvingAgainstBaseURL: false)!
                comp.queryItems = [
                    URLQueryItem(name: "start", value: start),
                    URLQueryItem(name: "end", value: end),
                ]
                // Best-effort per project — one failing project must not drop the rest.
                if let usage = try? await get(comp.url!, token: token, as: UsageResponse.self) {
                    agg.add(usage); ok += 1
                }
            }
            guard ok > 0 else { return failure("Không lấy được usage Deepgram") }
            let label = targetProjects.count > 1
                ? "\(targetProjects.count) projects"
                : "Project: \(targetProjects.first?.name ?? targetProjects.first?.projectID ?? "")"
            return materialize(agg, planName: label, accountLabel: accountLabel)
        } catch let e as ProviderError {
            return failure(e.errorDescription ?? "Deepgram lỗi")
        } catch {
            return failure("Network: \(error.localizedDescription)")
        }
    }

    private func materialize(_ agg: Aggregate, planName: String, accountLabel: String?) -> ProviderStatus {
        var windows: [QuotaWindow] = [
            QuotaWindow(label: "Requests (30d)", usedPct: 0, remainingPct: 100, subtitle: fmt(agg.requests),
                        allowance: QuotaAllowance(
                            used: Double(agg.requests), remaining: nil, limit: nil,
                            unit: .requests)),
        ]
        if agg.hours > 0 {
            let audio = agg.totalHours > 0
                ? String(format: "%.1f giờ · %.1f billable", agg.hours, agg.totalHours)
                : String(format: "%.1f giờ", agg.hours)
            windows.append(QuotaWindow(label: "Audio (30d)", usedPct: 0, remainingPct: 100, subtitle: audio))
        }
        // Collapse the remaining metrics (tokens / TTS / agent hours) into one info row.
        var extra: [String] = []
        let tokens = agg.tokensIn + agg.tokensOut
        if tokens > 0 { extra.append("\(fmt(tokens)) tokens") }
        if agg.ttsCharacters > 0 { extra.append("\(fmt(agg.ttsCharacters)) TTS") }
        if agg.agentHours > 0 { extra.append(String(format: "%.1f agent giờ", agg.agentHours)) }
        if !extra.isEmpty {
            windows.append(QuotaWindow(label: "Chi tiết (30d)", usedPct: 0, remainingPct: 100,
                                       subtitle: extra.joined(separator: " · ")))
        }
        return ProviderStatus(
            id: id, displayName: displayName, windows: windows, lastUpdated: Date(),
            error: nil, accountLabel: accountLabel, planName: planName)
    }

    /// Accumulates breakdown results across every project for the key.
    private struct Aggregate {
        var requests = 0
        var hours = 0.0
        var totalHours = 0.0
        var agentHours = 0.0
        var tokensIn = 0
        var tokensOut = 0
        var ttsCharacters = 0
        mutating func add(_ usage: UsageResponse) {
            for r in usage.results {
                requests += r.requests ?? 0
                hours += r.hours ?? 0
                totalHours += r.totalHours ?? 0
                agentHours += r.agentHours ?? 0
                tokensIn += r.tokensIn ?? 0
                tokensOut += r.tokensOut ?? 0
                ttsCharacters += r.ttsCharacters ?? 0
            }
        }
    }

    private func get<T: Decodable>(_ url: URL, token: String, as: T.Type) async throws -> T {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.http(0) }
        guard (200..<300).contains(http.statusCode) else { throw ProviderError.http(http.statusCode) }
        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            throw ProviderError.parse
        }
        return decoded
    }

    private func fmt(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private func failure(_ message: String) -> ProviderStatus {
        ProviderStatus(id: id, displayName: displayName, windows: [], lastUpdated: Date(), error: message)
    }

    private enum ProviderError: LocalizedError {
        case http(Int), parse
        var errorDescription: String? {
            switch self {
            case let .http(c): c == 401 || c == 403 ? "API key Deepgram không hợp lệ" : "HTTP \(c)"
            case .parse: "Response thiếu trường"
            }
        }
    }

    private struct ProjectsResponse: Decodable { let projects: [Project] }
    private struct Project: Decodable {
        let projectID: String
        let name: String?
        enum CodingKeys: String, CodingKey { case projectID = "project_id"; case name }
    }
    private struct UsageResponse: Decodable { let results: [Result] }
    private struct Result: Decodable {
        let hours: Double?
        let totalHours: Double?
        let agentHours: Double?
        let tokensIn: Int?
        let tokensOut: Int?
        let ttsCharacters: Int?
        let requests: Int?
        enum CodingKeys: String, CodingKey {
            case hours, requests
            case totalHours = "total_hours"
            case agentHours = "agent_hours"
            case tokensIn = "tokens_in"
            case tokensOut = "tokens_out"
            case ttsCharacters = "tts_characters"
        }
    }
}
