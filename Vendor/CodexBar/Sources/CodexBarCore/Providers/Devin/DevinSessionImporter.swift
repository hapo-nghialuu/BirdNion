import Foundation
#if os(macOS)
import SweetCookieKit
#endif

#if os(macOS)
enum DevinSessionImporter {
    nonisolated(unsafe) static var importSessionOverrideForTesting:
        ((BrowserDetection, String?, ((String) -> Void)?) -> SessionInfo?)?

    private static let storageOrigin = "https://app.devin.ai"
    private static let externalOrgPrefix = "last-internal-org-for-external-org-v1-"

    struct SessionInfo: Equatable {
        let accessToken: String
        let organization: String?
        let internalOrganizationID: String?
        let sourceLabel: String
    }

    struct LocalStorageCandidate {
        let label: String
        let url: URL
    }

    static func importSession(
        browserDetection: BrowserDetection,
        organizationOverride: String? = nil,
        logger: ((String) -> Void)? = nil) -> SessionInfo?
    {
        if let override = self.importSessionOverrideForTesting {
            return override(browserDetection, organizationOverride, logger)
        }

        let sessions = self.importSessions(
            browserDetection: browserDetection,
            organizationOverride: organizationOverride,
            logger: logger)
        return sessions.first
    }

    static func importSessions(
        browserDetection: BrowserDetection,
        organizationOverride: String? = nil,
        logger: ((String) -> Void)? = nil) -> [SessionInfo]
    {
        if let override = self.importSessionOverrideForTesting {
            return override(browserDetection, organizationOverride, logger).map { [$0] } ?? []
        }

        let log: (String) -> Void = { msg in logger?("[devin-storage] \(msg)") }
        let candidates = self.chromeLocalStorageCandidates(browserDetection: browserDetection)
        if !candidates.isEmpty {
            log("Chrome local storage candidates: \(candidates.count)")
        }

        var sessions: [SessionInfo] = []
        for candidate in candidates {
            let storage = self.readLocalStorage(from: candidate.url, logger: log)
            let found = self.sessions(
                from: storage,
                organizationOverride: organizationOverride,
                sourceLabel: candidate.label)
            guard let session = found.first else {
                continue
            }
            log(
                "Found Devin session in \(candidate.label); " +
                    "organization=\(session.organization != nil), internalOrganizationID=" +
                    "\(session.internalOrganizationID != nil)")
            sessions.append(contentsOf: found)
        }
        sessions = self.rankSessions(self.deduplicateSessions(sessions))

        if sessions.isEmpty {
            log("No Devin session found in browser local storage")
        }
        return sessions
    }

    static func session(
        from storage: [String: String],
        organizationOverride: String? = nil,
        sourceLabel: String) -> SessionInfo?
    {
        self.sessions(
            from: storage,
            organizationOverride: organizationOverride,
            sourceLabel: sourceLabel).first
    }

    /// One session per discovered organization: storage can carry metadata for
    /// several orgs, and auth1 tokens only resolve against their own org —
    /// emitting all candidates lets the fetcher try each until one succeeds.
    static func sessions(
        from storage: [String: String],
        organizationOverride: String? = nil,
        sourceLabel: String) -> [SessionInfo]
    {
        guard let accessToken = self.accessToken(from: storage) else {
            return []
        }
        let organizations = self.organizationCandidates(
            from: storage,
            organizationOverride: organizationOverride)
        if organizations.isEmpty {
            return [SessionInfo(
                accessToken: accessToken,
                organization: nil,
                internalOrganizationID: nil,
                sourceLabel: sourceLabel)]
        }
        return organizations.map { info in
            SessionInfo(
                accessToken: accessToken,
                organization: info.organization,
                internalOrganizationID: info.internalOrganizationID,
                sourceLabel: sourceLabel)
        }
    }

    static func accessToken(from storage: [String: String]) -> String? {
        for (key, value) in storage where self.isAuth1StorageKey(key) {
            guard let json = self.jsonObject(from: value),
                  let token = self.findAuth1Token(in: json)
            else {
                continue
            }
            return token
        }

        for (key, value) in storage where self.isAuth0StorageKey(key) {
            guard let json = self.jsonObject(from: value),
                  let token = self.findAccessToken(in: json)
            else {
                continue
            }
            return token
        }

        for value in storage.values {
            guard let json = self.jsonObject(from: value),
                  let token = self.findAccessToken(in: json)
            else {
                continue
            }
            return token
        }

        return nil
    }

    static func deduplicateSessions(_ sessions: [SessionInfo]) -> [SessionInfo] {
        var order: [String] = []
        var bestByToken: [String: SessionInfo] = [:]
        for session in sessions {
            // Same token may legitimately pair with different org candidates —
            // dedupe by (token, org), not token alone.
            let key = [
                session.accessToken,
                session.organization ?? "",
                session.internalOrganizationID ?? "",
            ].joined(separator: "\u{0}")
            if let existing = bestByToken[key] {
                if self.organizationScore(session) > self.organizationScore(existing) {
                    bestByToken[key] = session
                }
            } else {
                order.append(key)
                bestByToken[key] = session
            }
        }
        return order.compactMap { bestByToken[$0] }
    }

    static func rankSessions(_ sessions: [SessionInfo]) -> [SessionInfo] {
        sessions.enumerated()
            .sorted { lhs, rhs in
                let lhsScore = self.organizationScore(lhs.element)
                let rhsScore = self.organizationScore(rhs.element)
                return lhsScore == rhsScore ? lhs.offset < rhs.offset : lhsScore > rhsScore
            }
            .map(\.element)
    }

    private static func organizationScore(_ session: SessionInfo) -> Int {
        (session.organization == nil ? 0 : 1) + (session.internalOrganizationID == nil ? 0 : 2)
    }

    static func organizationInfo(
        from storage: [String: String],
        organizationOverride: String?) -> (organization: String?, internalOrganizationID: String?)
    {
        self.organizationCandidates(from: storage, organizationOverride: organizationOverride)
            .first ?? (nil, nil)
    }

    /// Ordered (slug, internal-ID) candidates. Storage dictionaries iterate in
    /// nondeterministic order and may hold metadata for several orgs, so scan
    /// sorted keys and emit every discovered candidate — the fetcher retries
    /// with the next session when an org doesn't match the token.
    static func organizationCandidates(
        from storage: [String: String],
        organizationOverride: String?) -> [(organization: String?, internalOrganizationID: String?)]
    {
        let override = DevinUsageFetcher.normalizedOrganization(organizationOverride)
        let overrideSlug = override.flatMap(self.slug(fromNormalizedOrganization:))
        let overrideOrgID = override.flatMap(self.orgID(fromNormalizedOrganization:))
        let sortedEntries = storage.sorted { $0.key < $1.key }

        var pairs: [(organization: String?, internalOrganizationID: String?)] = []
        var seen = Set<String>()
        var internalOrgIDs: [String] = []
        var slugs: [String] = []
        var firstInternalOrgID: String?

        func add(_ organization: String?, _ internalOrganizationID: String?) {
            guard organization != nil || internalOrganizationID != nil else { return }
            guard seen.insert("\(organization ?? "")\u{0}\(internalOrganizationID ?? "")").inserted
            else { return }
            pairs.append((organization, internalOrganizationID))
        }
        func noteIDs(_ internalOrganizationID: String?) {
            guard let internalOrganizationID else { return }
            if firstInternalOrgID == nil { firstInternalOrgID = internalOrganizationID }
            if !internalOrgIDs.contains(internalOrganizationID) { internalOrgIDs.append(internalOrganizationID) }
        }

        for (key, value) in sortedEntries where self.isExternalOrgStorageKey(key) {
            let suffix = self.externalOrgSlug(from: key)
            let orgID = self.cleanedOrgID(value)
            noteIDs(orgID)
            if let override {
                if let overrideOrgID, orgID == overrideOrgID { add(override, orgID) }
                if let overrideSlug, suffix == overrideSlug { add(override, orgID) }
            } else if suffix != "null" {
                add("org/\(suffix)", orgID)
            }
        }

        for (key, value) in sortedEntries {
            let object = self.jsonObject(from: value)
            let internalOrgID = self.cleanedOrgID(self.firstString(
                in: object,
                matching: ["internalOrgId", "internal_org_id", "org_id", "orgId"]))
                ?? self.internalOrgIDFromStorageKey(key)
            let slug = self.cleanedSlug(
                self.slugFromPostAuthKey(key) ??
                    self.firstString(in: object, matching: [
                        "orgName", "org_name", "externalOrgId", "external_org_id",
                    ]))

            if let override {
                if let overrideOrgID, internalOrgID == overrideOrgID { add(override, internalOrgID) }
                if let overrideSlug, slug == overrideSlug { add(override, internalOrgID) }
            } else if let slug, let internalOrgID {
                // Name and ID from the same storage record only — never pair a
                // slug from one org with an ID from another.
                add("org/\(slug)", internalOrgID)
            }
            noteIDs(internalOrgID)
            if let slug, !slugs.contains(slug) { slugs.append(slug) }
        }

        if let override {
            for orgID in internalOrgIDs { add(override, orgID) }
            add(override, overrideOrgID ?? firstInternalOrgID)
        } else {
            // Internal IDs first: auth1 tokens resolve only via the internal
            // organization ID, not the display slug.
            for orgID in internalOrgIDs { add("organizations/\(orgID)", orgID) }
            for slug in slugs { add("org/\(slug)", nil) }
        }
        return pairs
    }

    static func decodedStorageValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if let data = trimmed.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(String.self, from: data)
        {
            return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func chromeLocalStorageCandidates(browserDetection: BrowserDetection) -> [LocalStorageCandidate] {
        let installedBrowsers = self.localStorageBrowsers(browserDetection: browserDetection)
        let roots = ChromiumProfileLocator
            .roots(for: installedBrowsers, homeDirectories: BrowserCookieClient.defaultHomeDirectories())
            .map { (url: $0.url, labelPrefix: $0.labelPrefix) }

        var candidates: [LocalStorageCandidate] = []
        for root in roots {
            candidates.append(contentsOf: self.chromeProfileLocalStorageDirs(
                root: root.url,
                labelPrefix: root.labelPrefix))
        }
        return candidates
    }

    static func localStorageBrowsers(browserDetection: BrowserDetection) -> [Browser] {
        let order = ProviderDefaults.metadata[.devin]?.browserCookieOrder ?? [.chrome]
        return order.browsersWithProfileData(using: browserDetection)
    }

    private static func chromeProfileLocalStorageDirs(root: URL, labelPrefix: String) -> [LocalStorageCandidate] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        else { return [] }

        return entries.filter { url in
            guard let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory), isDir else {
                return false
            }
            let name = url.lastPathComponent
            return name == "Default" || name.hasPrefix("Profile ") || name.hasPrefix("user-")
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .compactMap { dir in
            let levelDBURL = dir.appendingPathComponent("Local Storage").appendingPathComponent("leveldb")
            guard FileManager.default.fileExists(atPath: levelDBURL.path) else { return nil }
            return LocalStorageCandidate(label: "\(labelPrefix) \(dir.lastPathComponent)", url: levelDBURL)
        }
    }

    private static func readLocalStorage(from levelDBURL: URL, logger: ((String) -> Void)?) -> [String: String] {
        var storage: [String: String] = [:]
        let entries = SweetCookieKit.ChromiumLocalStorageReader.readEntries(
            for: self.storageOrigin,
            in: levelDBURL,
            logger: logger)
        for entry in entries {
            storage[entry.key] = self.decodedStorageValue(entry.value)
        }

        // readTextEntries scans the whole profile store — it is NOT scoped to
        // our origin. Without a filter, a foreign site's auth0spajs token
        // (e.g. ChatGPT's, living in the same LevelDB) gets mistaken for a
        // Devin session. LevelDB text keys keep the `_<origin>\x00\x01<key>`
        // prefix, so only accept entries belonging to storageOrigin.
        let textEntries = SweetCookieKit.ChromiumLocalStorageReader.readTextEntries(
            in: levelDBURL,
            logger: logger)
        for entry in textEntries where storage[entry.key] == nil {
            if self.isOwnOriginTextKey(entry.key), self.isUsefulStorageKey(entry.key) {
                storage[entry.key] = self.decodedStorageValue(entry.value)
            }
        }

        return storage
    }

    static func isOwnOriginTextKey(_ key: String) -> Bool {
        key.hasPrefix("_\(self.storageOrigin)\u{0}\u{1}")
    }

    private static func jsonObject(from raw: String) -> Any? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func findAuth1Token(in object: Any) -> String? {
        guard let dictionary = object as? [String: Any],
              let token = dictionary["token"] as? String
        else {
            return nil
        }
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.hasPrefix("auth1_") && value.count > 20 ? value : nil
    }

    private static func findAccessToken(in object: Any) -> String? {
        if let dictionary = object as? [String: Any] {
            for key in ["access_token", "accessToken"] {
                if let value = dictionary[key] as? String,
                   self.looksLikeToken(value)
                {
                    return value
                }
            }
            for value in dictionary.values {
                if let found = self.findAccessToken(in: value) {
                    return found
                }
            }
        }

        if let array = object as? [Any] {
            for value in array {
                if let found = self.findAccessToken(in: value) {
                    return found
                }
            }
        }

        return nil
    }

    private static func looksLikeToken(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.count > 20 && (value.hasPrefix("eyJ") || value.contains("."))
    }

    private static func isAuth1StorageKey(_ key: String) -> Bool {
        key.hasSuffix("auth1_session")
    }

    private static func isAuth0StorageKey(_ key: String) -> Bool {
        key.contains("auth0spajs@@::")
    }

    private static func isExternalOrgStorageKey(_ key: String) -> Bool {
        key.contains(self.externalOrgPrefix)
    }

    private static func isUsefulStorageKey(_ key: String) -> Bool {
        self.isAuth1StorageKey(key) ||
            self.isAuth0StorageKey(key) ||
            self.isExternalOrgStorageKey(key) ||
            key.contains("post-auth-v") ||
            key.contains("member-info-v") ||
            key.contains("feature-flags-cache:org-") ||
            key.contains("feature-flags-cache:org_")
    }

    private static func externalOrgSlug(from key: String) -> String {
        guard let range = key.range(of: self.externalOrgPrefix) else { return key }
        return String(key[range.upperBound...])
    }

    private static func cleanedOrgID(_ raw: String) -> String? {
        let value = self.decodedStorageValue(raw)
        guard DevinUsageFetcher.isInternalOrganizationID(value) else { return nil }
        return value
    }

    private static func cleanedOrgID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        return self.cleanedOrgID(raw)
    }

    private static func cleanedSlug(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = self.decodedStorageValue(raw)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != "null", !DevinUsageFetcher.isInternalOrganizationID(value) else {
            return nil
        }
        if value.hasPrefix("org/") {
            return String(value.dropFirst(4))
        }
        return value
    }

    private static func slugFromPostAuthKey(_ key: String) -> String? {
        guard let range = key.range(of: "-org_name-") else { return nil }
        return String(key[range.upperBound...])
    }

    private static func internalOrgIDFromStorageKey(_ key: String) -> String? {
        guard let range = key.range(of: #"org[-_][A-Za-z0-9]{8,}"#, options: .regularExpression) else {
            return nil
        }
        return self.cleanedOrgID(String(key[range]))
    }

    private static func firstString(in object: Any?, matching keys: Set<String>) -> String? {
        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary {
                if keys.contains(key), let string = value as? String, !string.isEmpty {
                    return string
                }
                if let found = self.firstString(in: value, matching: keys) {
                    return found
                }
            }
        }

        if let array = object as? [Any] {
            for value in array {
                if let found = self.firstString(in: value, matching: keys) {
                    return found
                }
            }
        }

        return nil
    }

    private static func slug(fromNormalizedOrganization organization: String) -> String? {
        guard organization.hasPrefix("org/") else { return nil }
        return String(organization.dropFirst(4))
    }

    private static func orgID(fromNormalizedOrganization organization: String) -> String? {
        guard organization.hasPrefix("organizations/") else { return nil }
        return String(organization.dropFirst("organizations/".count))
    }
}
#endif
