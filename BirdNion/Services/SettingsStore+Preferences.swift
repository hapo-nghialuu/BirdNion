import Foundation

extension SettingsStore {
    /// Snapshot the allowlisted UI preferences + provider enable/order for
    /// export. Secrets, account identity and local paths are not part of the
    /// document by construction (see `PreferencesDocument` allowlist).
    func exportPreferences() throws -> PreferencesDocument {
        try PreferencesDocument(defaults: UserDefaults.standard)
    }

    /// Apply a portable-preferences document through the same write paths the
    /// UI uses, so observers see ordinary changes. Unknown or non-portable
    /// keys were already rejected by `PreferencesDocument.init(data:)`.
    func importPreferences(
        _ document: PreferencesDocument,
        defaults: UserDefaults = .standard
    ) throws {
        try document.validate()
        for (key, value) in document.preferences {
            switch value {
            case let .bool(v): defaults.set(v, forKey: key)
            case let .integer(v): defaults.set(v, forKey: key)
            case let .double(v): defaults.set(v, forKey: key)
            case let .string(v): defaults.set(v, forKey: key)
            case .array, .object, .null: break // validate() rejects these
            }
        }
        if let providers = document.providers {
            try Self.applyProviderPreferences(providers)
        }
        applyAppearance()
        applyLanguage()
        NotificationCenter.default.post(name: .menuBarVisibilityChanged, object: nil)
        NotificationCenter.default.post(name: .birdnionRefresh, object: nil)
    }

    /// Reorder + set enable flags in `settings.json` to match the document,
    /// preserving every other provider field (apiKey, secrets, metadata).
    /// Providers missing from the document keep their relative order at the
    /// end — import never invents or deletes provider entries.
    static func applyProviderPreferences(
        _ wanted: [PreferencesDocument.ProviderPreference],
        url: URL = BirdNionConfigStore.configURL()
    ) throws {
        var current = BirdNionConfigStore.allProviders(url: url)
        var ordered: [BirdNionConfigStore.Provider] = []
        for pref in wanted {
            guard let index = current.firstIndex(where: { $0.id == pref.id }) else { continue }
            var provider = current.remove(at: index)
            provider.enabled = pref.enabled
            ordered.append(provider)
        }
        ordered.append(contentsOf: current)
        _ = try BirdNionConfigStore.saveProviders(ordered, url: url)
    }

    /// Apply a document queued by a CLI `config import` while the app was not
    /// running, then clear the pending blob. Called once at startup.
    func consumePendingPreferencesImport() {
        let defaults = UserDefaults.standard
        defaults.synchronize()
        guard let data = defaults.data(forKey: PreferencesDocument.pendingImportKey) else { return }
        do {
            try importPreferences(PreferencesDocument(data: data))
            if defaults.data(forKey: PreferencesDocument.pendingImportKey) == data {
                defaults.removeObject(forKey: PreferencesDocument.pendingImportKey)
                defaults.synchronize()
            }
        } catch {
            // Keep the blob so the next launch retries after the user fixes it.
            print("Could not import portable preferences: \(error)")
        }
    }
}
