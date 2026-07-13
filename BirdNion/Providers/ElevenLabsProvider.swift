import Foundation

// MARK: - ElevenLabsKeyStore

/// One ElevenLabs API key the app can fetch quota for.
struct ElevenLabsKey: Identifiable, Equatable {
    let id: String
    let label: String?
    /// First 8 characters of the key for display (never the full secret in UI lists).
    let preview: String
}

/// ElevenLabs multi-key state — same shape as `FreemodelAccountStore`:
/// managed keys + active id live in Application Support `elevenlabs-keys.json`
/// (secrets never ride in the shared settings.json list UI). UserDefaults is
/// kept as a mirror for older builds. Legacy single `providers.elevenlabs.apiKey`
/// is imported once when the store file does not exist yet.
enum ElevenLabsKeyStore {
    static let activeKey = "activeElevenLabsKey"

    /// Production store location. Tests pass a temp `url:` (and a throwaway
    /// `defaults:` suite) so they never touch the real key store — same
    /// default-parameter injection pattern as `CostHistoryStore`.
    static func metadataURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base
            .appendingPathComponent("BirdNion", isDirectory: true)
            .appendingPathComponent("elevenlabs-keys.json")
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

    private static func toKey(_ e: Entry) -> ElevenLabsKey {
        ElevenLabsKey(id: e.id, label: e.label, preview: preview(of: e.apiKey))
    }

    /// Notify Settings + popover to re-list keys; optionally force quota refresh.
    private static func notifyChanged(refreshQuota: Bool) {
        NotificationCenter.default.post(name: .birdnionElevenLabsKeysChanged, object: nil)
        if refreshQuota {
            NotificationCenter.default.post(name: .birdnionRefresh, object: nil)
        }
    }

    // MARK: Listing / mutation

    static func allKeys(url: URL = metadataURL(),
                        defaults: UserDefaults = .standard) -> [ElevenLabsKey] {
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
        guard let legacy = BirdNionConfigStore.apiKey(provider: "elevenlabs"),
              !legacy.isEmpty else { return false }
        let label = BirdNionConfigStore.accountLabel(provider: "elevenlabs")
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
                    defaults: UserDefaults = .standard) throws -> ElevenLabsKey {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw NSError(domain: "ElevenLabsKeyStore", code: 1,
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

// MARK: - ElevenLabsProvider

/// ElevenLabs (TTS) usage provider. API key (header `xi-api-key`) → the
/// subscription endpoint reports character credits used/limit + voice slots.
/// Native port of CodexBar's ElevenLabsUsageFetcher.
///
/// Key resolution order:
/// 1. `ELEVENLABS_API_KEY` env (dev/CI override)
/// 2. Active multi-key store entry (`ElevenLabsKeyStore`)
/// 3. Legacy single `providers.elevenlabs.apiKey` in settings.json
final class ElevenLabsProvider: QuotaProvider {
    let id = "elevenlabs"
    let displayName = "ElevenLabs"

    static let endpoint = URL(string: "https://api.elevenlabs.io/v1/user/subscription")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    private func override() -> String? { BirdNionConfigStore.accountLabel(provider: id) }

    func fetch() async throws -> ProviderStatus {
        let envToken = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let storeToken = ElevenLabsKeyStore.activeApiKey()
        let legacyToken = BirdNionConfigStore.apiKey(provider: id)
        let token = (envToken?.isEmpty == false ? envToken : nil)
            ?? storeToken
            ?? legacyToken
        guard let token, !token.isEmpty else {
            return failure("Chưa cấu hình API key ElevenLabs")
        }
        // Prefer the active key's label so switching keys updates the shown
        // identity; the static Settings "Account label" field is fallback only.
        let accountLabel = ElevenLabsKeyStore.activeDisplayLabel()
            ?? override()
            ?? String(token.prefix(8))

        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "GET"
        req.setValue(token, forHTTPHeaderField: "xi-api-key")
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
        case 401, 403: return failure("API key ElevenLabs không hợp lệ")
        default: return failure("HTTP \(http.statusCode)")
        }
    }

    func parse(_ data: Data, accountLabel: String?) -> ProviderStatus {
        guard let r = try? JSONDecoder().decode(Subscription.self, from: data) else {
            return failure("Response thiếu trường")
        }
        var windows: [QuotaWindow] = []
        let used = max(0, min(100, r.characterLimit > 0
                              ? Int((Double(r.characterCount) / Double(r.characterLimit) * 100).rounded()) : 0))
        windows.append(QuotaWindow(
            label: "Credits",
            usedPct: used,
            remainingPct: 100 - used,
            subtitle: "\(fmt(r.characterCount)) / \(fmt(r.characterLimit))",
            resetDate: r.nextCharacterCountResetUnix.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            windowSeconds: 30 * 24 * 3600))
        if let u = r.voiceSlotsUsed, let lim = r.voiceLimit, lim > 0 {
            let p = max(0, min(100, Int((Double(u) / Double(lim) * 100).rounded())))
            windows.append(QuotaWindow(label: "Voice slots", usedPct: p, remainingPct: 100 - p,
                                       subtitle: "\(u) / \(lim)"))
        }
        if let u = r.professionalVoiceSlotsUsed, let lim = r.professionalVoiceLimit, lim > 0 {
            let p = max(0, min(100, Int((Double(u) / Double(lim) * 100).rounded())))
            windows.append(QuotaWindow(label: "Professional voices", usedPct: p, remainingPct: 100 - p,
                                       subtitle: "\(u) / \(lim)"))
        }
        let plan = displayTier(tier: r.tier, status: r.status)
        return ProviderStatus(
            id: id, displayName: displayName, windows: windows, lastUpdated: Date(),
            error: nil, accountLabel: accountLabel, planName: plan)
    }

    // Internal — exposed for unit testing without importing CodexBarCore.
    func _parseForTesting(_ data: Data, accountLabel: String?) -> ProviderStatus {
        parse(data, accountLabel: accountLabel)
    }

    /// Mirrors CodexBar's ElevenLabsUsageSnapshot.displayTier logic.
    /// Returns "Tier · status" when status != "active", otherwise just the tier name.
    private func displayTier(tier: String?, status: String?) -> String? {
        guard let tier = tier?.trimmingCharacters(in: .whitespacesAndNewlines), !tier.isEmpty else {
            return status
        }
        let statusSuffix: String
        if let s = status, !s.isEmpty, s.lowercased() != "active" {
            statusSuffix = " · \(s)"
        } else {
            statusSuffix = ""
        }
        return "\(tier.replacingOccurrences(of: "_", with: " ").capitalized)\(statusSuffix)"
    }

    private func fmt(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private func failure(_ message: String) -> ProviderStatus {
        ProviderStatus(id: id, displayName: displayName, windows: [], lastUpdated: Date(), error: message)
    }

    private struct Subscription: Decodable {
        let tier: String?
        let status: String?
        let characterCount: Int
        let characterLimit: Int
        let voiceSlotsUsed: Int?
        let voiceLimit: Int?
        let professionalVoiceSlotsUsed: Int?
        let professionalVoiceLimit: Int?
        let nextCharacterCountResetUnix: Int?
        enum CodingKeys: String, CodingKey {
            case tier
            case status
            case characterCount = "character_count"
            case characterLimit = "character_limit"
            case voiceSlotsUsed = "voice_slots_used"
            case voiceLimit = "voice_limit"
            case professionalVoiceSlotsUsed = "professional_voice_slots_used"
            case professionalVoiceLimit = "professional_voice_limit"
            case nextCharacterCountResetUnix = "next_character_count_reset_unix"
        }
    }
}
