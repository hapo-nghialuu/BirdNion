import Foundation

/// Per-provider opt-in for showing in the macOS menu bar percent rotation. Backed
/// by UserDefaults so the choice survives an app restart without growing
/// the providers.json schema (which already carries provider enabled +
/// accountLabel). Default is "shown" so every provider in providers.json can
/// be included in the menu-bar percent sequence until the user hides one.
///
/// Toggle fires `Notification.Name.menuBarVisibilityChanged` so the
/// AppDelegate can rebuild its frame list on the main thread without
/// having to poll.
enum MenuBarVisibility {
    static func isShown(providerId: String) -> Bool {
        // Default true when the key has never been written — saves a migration
        // step and matches the prior behavior (all enabled providers were
        // visible on the menu bar).
        UserDefaults.standard.object(forKey: key(providerId)) as? Bool ?? true
    }

    static func setShown(providerId: String, to shown: Bool) {
        UserDefaults.standard.set(shown, forKey: key(providerId))
        NotificationCenter.default.post(name: .menuBarVisibilityChanged, object: providerId)
    }

    static func toggle(providerId: String) {
        setShown(providerId: providerId, to: !isShown(providerId: providerId))
    }

    private static func key(_ providerId: String) -> String {
        "menuBarVisibility.\(providerId)"
    }
}

extension Notification.Name {
    /// Posted by `MenuBarVisibility` whenever a provider's show/hide state
    /// changes. `object` is the provider id. AppDelegate listens to this to
    /// rebuild the menu-bar frame.
    static let menuBarVisibilityChanged = Notification.Name("com.local.birdnion.menuBarVisibilityChanged")
}
