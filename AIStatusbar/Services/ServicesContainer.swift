import Foundation
import SwiftUI

/// Owns the 3 app-wide services so AppDelegate (non-SwiftUI) and Views
/// (SwiftUI) can share the same instances.
@MainActor
final class ServicesContainer: ObservableObject {
    let keychain: KeychainService
    let configService: ConfigService
    let quotaService: QuotaService

    init() {
        let ks = KeychainService()
        self.keychain = ks
        self.configService = ConfigService()

        // Build providers from providers.json so each entry uses its real
        // baseURL / authHeaderTemplate. Falls back to the default document
        // (which already points at <HAPO_HOST>) on first launch when
        // no providers.json exists on disk.
        let doc = ProvidersStore.load()
        var providers: [QuotaProvider] = []
        for cfg in doc.providers where cfg.enabled {
            if cfg.id == "minimax" {
                providers.append(MiniMaxProvider(keychain: ks))
            } else if cfg.id == "hapo" {
                let hapoConfig = HapoHubConfig(
                    id: cfg.id,
                    displayName: cfg.displayName ?? "AIHub",
                    baseURL: cfg.baseURL ?? HapoHubConfig.real.baseURL,
                    authHeaderTemplate: HapoHubConfig.real.authHeaderTemplate,
                    jsonPath: HapoHubConfig.real.jsonPath
                )
                providers.append(HapoHubFactory.make(
                    session: .shared,
                    config: hapoConfig,
                    keychain: ks
                ))
            }
        }
        // If providers.json is missing/empty (first launch before any UI save),
        // fall back to the hard-coded defaults so the popover is never blank.
        if providers.isEmpty {
            providers = [
                MiniMaxProvider(keychain: ks),
                HapoHubFactory.make(
                    session: .shared,
                    config: HapoHubConfig.real,
                    keychain: ks
                )
            ]
        }
        self.quotaService = QuotaService(providers: providers, interval: 120)
    }

    func start() {
        quotaService.start()
    }

    func stop() {
        quotaService.stop()
    }
}