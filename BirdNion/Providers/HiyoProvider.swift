import Foundation

// MARK: - HiyoKeyStore

/// One Hiyo API key the app can fetch balance for.
struct HiyoKey: Identifiable, Equatable {
    let id: String
    let label: String?
    /// First 8 characters of the key for display (never the full secret in UI lists).
    let preview: String
}

/// Hiyo multi-key state — same shape as `ElevenLabsKeyStore`:
/// managed keys + active id live in Application Support `hiyo-keys.json`
/// (secrets never ride in the shared settings.json list UI). UserDefaults is
/// kept as a mirror for older builds. Legacy single `providers.hiyo.apiKey`
/// is imported once when the store file does not exist yet.
enum HiyoKeyStore {
    static let activeKey = "activeHiyoKey"

    /// Production store location. Tests pass a temp `url:` (and a throwaway
    /// `defaults:` suite) so they never touch the real key store — same
    /// default-parameter injection pattern as `CostHistoryStore`.
    static func metadataURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base
            .appendingPathComponent("BirdNion", isDirectory: true)
            .appendingPathComponent("hiyo-keys.json")
    }

    // MARK: Active selection

    static func activeID(url: URL = metadataURL(),
                         defaults: UserDefaults = .standard) -> String? {
        ensureLegacyImport(url: url, defaults: defaults)
        let stored = loadStored(url: url)
        if let id = stored.activeId, stored.accounts.contains(where: { $0.id == id }) {
            return id
        }
        // Migrate mirror from UserDefaults (older builds wrote only there).
        if let id = defaults.string(forKey: activeKey),
           stored.accounts.contains(where: { $0.id == id }) {
            try? write(Stored(activeId: id, accounts: stored.accounts), url: url)
            return id
        }
        return stored.accounts.first?.id
    }

    static func setActive(_ id: String,
                          url: URL = metadataURL(),
                          defaults: UserDefaults = .standard) {
        var stored = loadStored(url: url)
        guard stored.accounts.contains(where: { $0.id == id }) else { return }
        stored.activeId = id
        try? write(stored, url: url)
        defaults.set(id, forKey: activeKey)
        notifyChanged(refreshQuota: true)
    }

    /// Full API key for the active account — nil when the store is empty.
    static func activeApiKey(url: URL = metadataURL(),
                             defaults: UserDefaults = .standard) -> String? {
        ensureLegacyImport(url: url, defaults: defaults)
        guard let id = activeID(url: url, defaults: defaults) else { return nil }
        return loadStored(url: url).accounts.first(where: { $0.id == id })?.apiKey
    }

    /// Display label for the active key (custom label or key preview).
    static func activeDisplayLabel(url: URL = metadataURL(),
                                   defaults: UserDefaults = .standard) -> String? {
        guard let id = activeID(url: url, defaults: defaults),
              let entry = loadStored(url: url).accounts.first(where: { $0.id == id }) else { return nil }
        if let label = entry.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            return label
        }
        return preview(of: entry.apiKey)
    }

    // MARK: Persistence

    private struct Stored: Codable {
        var activeId: String?
        var accounts: [Entry]
    }

    private struct Entry: Codable {
        var id: String
        var label: String?
        var apiKey: String
    }

    private static func loadStored(url: URL) -> Stored {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            return Stored(activeId: nil, accounts: [])
        }
        return stored
    }

    private static func write(_ stored: Stored, url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(stored)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func preview(of key: String) -> String {
        String(key.prefix(8))
    }

    private static func toKey(_ e: Entry) -> HiyoKey {
        HiyoKey(id: e.id, label: e.label, preview: preview(of: e.apiKey))
    }

    /// Notify Settings + popover to re-list keys; optionally force quota refresh.
    private static func notifyChanged(refreshQuota: Bool) {
        NotificationCenter.default.post(name: .birdnionHiyoKeysChanged, object: nil)
        if refreshQuota {
            NotificationCenter.default.post(name: .birdnionRefresh, object: nil)
        }
    }

    // MARK: Listing / mutation

    static func allKeys(url: URL = metadataURL(),
                        defaults: UserDefaults = .standard) -> [HiyoKey] {
        ensureLegacyImport(url: url, defaults: defaults)
        return loadStored(url: url).accounts.map(toKey)
    }

    /// One-time import of the legacy single `apiKey` from settings.json when
    /// the multi-key store file has never been created. An empty store after
    /// the user deleted every key is left empty (no re-import loop).
    @discardableResult
    static func ensureLegacyImport(url: URL = metadataURL(),
                                   defaults: UserDefaults = .standard) -> Bool {
        if FileManager.default.fileExists(atPath: url.path) { return false }
        guard let legacy = BirdNionConfigStore.apiKey(provider: "hiyo"),
              !legacy.isEmpty else { return false }
        let label = BirdNionConfigStore.accountLabel(provider: "hiyo")
        let entry = Entry(id: UUID().uuidString, label: label, apiKey: legacy)
        try? write(Stored(activeId: entry.id, accounts: [entry]), url: url)
        defaults.set(entry.id, forKey: activeKey)
        return true
    }

    /// Stores a new managed API key. Rejects empty keys. Sets active when this
    /// is the first key. Always notifies UI so popover/Settings update live.
    @discardableResult
    static func add(apiKey: String, label: String?,
                    url: URL = metadataURL(),
                    defaults: UserDefaults = .standard) throws -> HiyoKey {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw NSError(domain: "HiyoKeyStore", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "API key trống"])
        }
        let trimmedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = Entry(
            id: UUID().uuidString,
            label: (trimmedLabel?.isEmpty ?? true) ? nil : trimmedLabel,
            apiKey: key)
        var stored = loadStored(url: url)
        stored.accounts.append(entry)
        let isFirst = stored.accounts.count == 1
        if isFirst || stored.activeId == nil
            || !stored.accounts.contains(where: { $0.id == stored.activeId }) {
            stored.activeId = entry.id
            defaults.set(entry.id, forKey: activeKey)
        }
        try write(stored, url: url)
        // First key / auto-activate → refresh quota; otherwise just re-list UI.
        notifyChanged(refreshQuota: isFirst || stored.activeId == entry.id)
        return toKey(entry)
    }

    /// Removes a managed key; falls active back to the first remaining key.
    static func remove(_ id: String,
                       url: URL = metadataURL(),
                       defaults: UserDefaults = .standard) throws {
        var stored = loadStored(url: url)
        let previousActive = stored.activeId
            ?? defaults.string(forKey: activeKey)
            ?? stored.accounts.first?.id
        stored.accounts = stored.accounts.filter { $0.id != id }
        if previousActive == id {
            stored.activeId = stored.accounts.first?.id
            if let next = stored.activeId {
                defaults.set(next, forKey: activeKey)
            } else {
                defaults.removeObject(forKey: activeKey)
            }
        }
        try write(stored, url: url)
        notifyChanged(refreshQuota: previousActive == id)
    }
}

// MARK: - HiyoProvider

/// Hiyo prepaid-balance provider. API key (Bearer) → usage endpoint reports
/// wallet balance in USD (or other unit). Display mirrors DeepSeek: one
/// "Số dư" window with a dollar subtitle and `creditsRemaining`.
///
/// Key resolution order:
/// 1. `HIYO_API_KEY` env (dev/CI override)
/// 2. Active multi-key store entry (`HiyoKeyStore`)
/// 3. Legacy single `providers.hiyo.apiKey` in settings.json
final class HiyoProvider: QuotaProvider {
    let id = "hiyo"
    let displayName = "Hiyo"

    static let endpoint = URL(string: "https://codex.hiyo.top/v1/usage")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    private func override() -> String? { BirdNionConfigStore.accountLabel(provider: id) }

    func fetch() async throws -> ProviderStatus {
        let envToken = ProcessInfo.processInfo.environment["HIYO_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let storeToken = HiyoKeyStore.activeApiKey()
        let legacyToken = BirdNionConfigStore.apiKey(provider: id)
        let token = (envToken?.isEmpty == false ? envToken : nil)
            ?? storeToken
            ?? legacyToken
        guard let token, !token.isEmpty else {
            return failure("Chưa cấu hình API key Hiyo")
        }
        // Prefer the active key's label so switching keys updates the shown
        // identity; the static Settings "Account label" field is fallback only.
        let accountLabel = HiyoKeyStore.activeDisplayLabel()
            ?? override()
            ?? String(token.prefix(8))

        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        // Same URL for every key — never reuse a cached body from another key.
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            return failure("Network: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else { return failure("Response không phải HTTP") }
        switch http.statusCode {
        case 200..<300: return parse(data, accountLabel: accountLabel)
        case 401, 403: return failure("API key Hiyo không hợp lệ")
        default: return failure("HTTP \(http.statusCode)")
        }
    }

    func parse(_ data: Data, accountLabel: String?) -> ProviderStatus {
        guard let r = try? JSONDecoder().decode(UsageResponse.self, from: data) else {
            return failure("Response thiếu trường")
        }
        if r.isValid == false {
            return failure("API key Hiyo không hợp lệ")
        }
        // Prefer `balance`; fall back to `remaining` when balance is absent.
        let balance = r.balance ?? r.remaining ?? 0
        let unit = r.unit ?? "USD"
        let symbol = unit.uppercased() == "USD" ? "$" : "\(unit) "
        let lowBalance = balance <= 0
        let subtitle: String
        if lowBalance {
            subtitle = "Hết số dư — cần nạp thêm"
        } else {
            subtitle = "\(symbol)\(String(format: "%.2f", balance))"
        }
        // Balance-only provider: single full-width window carries the figure
        // as a subtitle (same pattern as DeepSeek). usedPct=100 flags empty.
        let window = QuotaWindow(
            label: "Số dư",
            usedPct: lowBalance ? 100 : 0,
            remainingPct: lowBalance ? 0 : 100,
            subtitle: subtitle)
        return ProviderStatus(
            id: id,
            displayName: displayName,
            windows: [window],
            lastUpdated: Date(),
            error: nil,
            accountLabel: accountLabel,
            creditsRemaining: balance,
            planName: r.planName)
    }

    // Internal — exposed for unit testing without a live network call.
    func _parseForTesting(_ data: Data, accountLabel: String?) -> ProviderStatus {
        parse(data, accountLabel: accountLabel)
    }

    private func failure(_ message: String) -> ProviderStatus {
        ProviderStatus(id: id, displayName: displayName, windows: [], lastUpdated: Date(), error: message)
    }

    private struct UsageResponse: Decodable {
        let balance: Double?
        let remaining: Double?
        let unit: String?
        let isValid: Bool?
        let mode: String?
        let planName: String?
        let usage: UsageBucket?

        struct UsageBucket: Decodable {
            let total: UsageTotals?
            let today: UsageTotals?
        }

        struct UsageTotals: Decodable {
            let cost: Double?
            let totalTokens: Int?
            let requests: Int?

            enum CodingKeys: String, CodingKey {
                case cost
                case totalTokens = "total_tokens"
                case requests
            }
        }
    }
}
