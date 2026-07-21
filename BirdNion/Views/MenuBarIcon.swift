import AppKit

/// Builds the frame shown by the menu bar status item. AppDelegate owns the
/// timer fallback; this type only describes each frame and renders the images
/// it needs.
///
/// The default frame is the bird logo. When the user enables menu-bar
/// percentages, provider quota frames rotate in sorted order: **active**
/// providers first (any window with remaining under 100% / used over 0), then
/// alphabetically by `displayName`.
enum MenuBarIconRenderer {
    static let assetName = "MenuBarIcon"

    /// One possible menu-bar frame.
    enum Frame: Equatable {
        /// Just the bird, no text.
        case bird
        /// A provider: `percents` are its windows' `remainingPct` in order;
        /// `id` selects the brand logo drawn to the right of the percentages.
        /// `text`, when non-nil, replaces the joined percents entirely (Kiro's
        /// display-mode picker uses this to show credits / used÷total / overage
        /// instead of percent).
        case provider(id: String, name: String, percents: [Int], text: String?)
    }

    static func percentTitle(for percents: [Int]) -> String {
        percents
            .map { value in "\(max(0, min(100, value)))%" }
            .joined(separator: "  ")
    }

    /// Build the displayed frames. With the global setting off, or with no
    /// active quota windows, the menu bar stays as the bird logo only.
    static func frames(
        from statuses: [ProviderStatus],
        showPercent: Bool = MenuBarPercentDisplay.isEnabled,
        visibility: (String) -> Bool = { MenuBarVisibility.isShown(providerId: $0) }
    ) -> [Frame] {
        guard showPercent else { return [.bird] }
        let frames = providerFrames(from: statuses, visibility: visibility)
        return frames.isEmpty ? [.bird] : frames
    }

    static func providerFrames(
        from statuses: [ProviderStatus],
        visibility: (String) -> Bool = { MenuBarVisibility.isShown(providerId: $0) }
    ) -> [Frame] {
        statuses
            .compactMap { menuBarFrame(from: $0, visibility: visibility) }
            .sorted(by: menuBarFrameSort)
    }

    /// Active frames sort before idle full-quota ones; ties break A→Z by name.
    static func menuBarFrameSort(_ lhs: Frame, _ rhs: Frame) -> Bool {
        let lActive = isActiveMenuBarFrame(lhs)
        let rActive = isActiveMenuBarFrame(rhs)
        if lActive != rActive { return lActive && !rActive }
        return displayName(of: lhs)
            .localizedCaseInsensitiveCompare(displayName(of: rhs)) == .orderedAscending
    }

    /// True when the provider is currently consuming quota (not sitting at
    /// a full unused window set). Bird frames are never "active".
    static func isActiveMenuBarFrame(_ frame: Frame) -> Bool {
        switch frame {
        case .bird:
            return false
        case let .provider(_, _, percents, _):
            // remaining under 100 ⇔ used over 0 for the usual 0…100 clamp.
            return percents.contains { $0 < 100 }
        }
    }

    private static func displayName(of frame: Frame) -> String {
        switch frame {
        case .bird: return ""
        case let .provider(_, name, _, _): return name
        }
    }

    private static func menuBarFrame(
        from status: ProviderStatus,
        visibility: (String) -> Bool
    ) -> Frame? {
        guard visibility(status.id) else { return nil }
        let windows = status.id == "codex"
            ? CodexMenuBarMetric.current.filter(status.windows)
            : MenuBarMetricStore.filter(status.windows, id: status.id)
        guard !windows.isEmpty else { return nil }
        let text = status.id == "kiro"
            ? kiroDisplayText(status: status, mode: KiroMenuBarDisplayMode.current)
            : nil
        if text == "" { return nil }
        let percents = status.id == "freemodel"
            ? freemodelMenuBarPercents(windows)
            : windows.map { $0.remainingPct }
        return .provider(
            id: status.id,
            name: status.displayName,
            percents: percents,
            text: text
        )
    }

    /// FreeModel: the bonus "Số dư" window stays out of the menu bar (it is
    /// not a rate window). Once the 5-hour window is exhausted and bonus
    /// balance remains, the readout collapses to JUST the balance percent —
    /// credits apply automatically at that point, so it's the only number
    /// that matters until the window resets.
    static func freemodelMenuBarPercents(_ windows: [QuotaWindow]) -> [Int] {
        let balance = windows.first { $0.label == "Số dư" }
        if let fiveH = windows.first(where: { $0.label == "5 giờ" }),
           fiveH.remainingPct <= 0,
           let balance, balance.remainingPct > 0 {
            return [balance.remainingPct]
        }
        let percents = windows.filter { $0.label != "Số dư" }.map(\.remainingPct)
        // The menu-bar metric picker isolated the balance window itself →
        // show it as-is instead of an empty title.
        if percents.isEmpty, let balance { return [balance.remainingPct] }
        return percents
    }

    // MARK: - Kiro menu-bar display mode

    /// Computes the Kiro menu-bar title for the selected display mode, mirroring
    /// CodexBar's `kiroDisplayText`. Returns nil for `.automatic`/data-less
    /// cases so the caller falls back to the numeric percents; "" for `.hidden`
    /// so nothing is drawn; otherwise the formatted credits/overage text.
    static func kiroDisplayText(status: ProviderStatus, mode: KiroMenuBarDisplayMode) -> String? {
        if mode == .hidden { return "" }
        guard let u = status.kiroMenu else { return nil }
        let pct = u.primaryRemainingPct
        let percentText = pct.map { "\($0)%" }
        let creditsLeft = u.creditsRemaining.map(creditNumber)
        let hasTotal = (u.creditsTotal ?? 0) > 0

        switch mode {
        case .automatic, .creditsLeft:
            return hasTotal ? creditsLeft : nil   // nil → fall back to percents
        case .hidden:
            return ""
        case .percentLeft:
            return percentText
        case .creditsAndPercent:
            guard hasTotal, let c = creditsLeft else { return nil }
            guard let p = percentText else { return c }
            return "\(c) · \(p)"
        case .usedAndTotal:
            guard hasTotal, let used = u.creditsUsed, let total = u.creditsTotal else { return nil }
            return "\(creditNumber(used)) / \(creditNumber(total))"
        case .overageCreditsWhenExhausted:
            return overageText(u, format: .credits) ?? creditsLeft
        case .overageCostWhenExhausted:
            return overageText(u, format: .cost) ?? creditsLeft
        case .overageCreditsAndCostWhenExhausted:
            return overageText(u, format: .creditsAndCost) ?? creditsLeft
        }
    }

    private enum KiroOverageFormat { case credits, cost, creditsAndCost }

    /// Overage text shown only once the plan credits are exhausted. nil when
    /// there is no overage (so the caller falls back to the credits number).
    private static func overageText(_ u: KiroMenuUsage, format: KiroOverageFormat) -> String? {
        let credits = u.overageCreditsUsed
        let cost = u.overageCostUSD
        guard (credits ?? 0) > 0 || (cost ?? 0) > 0 else { return nil }
        switch format {
        case .credits:
            return credits.map { "+\(creditNumber($0))" }
        case .cost:
            return cost.map { String(format: "+$%.2f", $0) }
        case .creditsAndCost:
            let c = credits.map { "+\(creditNumber($0))" }
            let d = cost.map { String(format: "$%.2f", $0) }
            return [c, d].compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// Compact credit number: whole numbers without decimals, else one decimal.
    private static func creditNumber(_ value: Double) -> String {
        if value >= 1000 { return String(format: "%.0f", value) }
        if value == value.rounded() { return String(format: "%.0f", value) }
        return String(format: "%.1f", value)
    }

    /// The bird asset, scaled to `pointSize`. Deliberately not a template
    /// image: that flag flattens the bird to a single colour and loses its
    /// blue palette (see git history). The default menu bar slot is ~18pt;
    /// 24pt ≈ the full NSStatusBar thickness — effectively the hard ceiling,
    /// since macOS clips anything taller than the bar.
    static func iconImage(pointSize: CGFloat = 24) -> NSImage {
        scaled(NSImage(named: assetName), to: pointSize, isTemplate: false)
            ?? NSImage(size: NSSize(width: pointSize, height: pointSize))
    }

    /// Brand logo for a provider id, scaled as a monochrome template so AppKit
    /// applies the correct menu-bar foreground color in every appearance.
    static func providerLogo(for id: String, pointSize: CGFloat = 18) -> NSImage {
        let providerAsset: String
        switch id {
        case "minimax": providerAsset = "MiniMaxLogo"
        case "hapo": providerAsset = "HapoLogo"
        case "claude": providerAsset = "ClaudeLogo"
        case "codex", "openai": providerAsset = "CodexLogo"
        case "openrouter": providerAsset = "OpenRouterLogo"
        case "deepseek": providerAsset = "DeepSeekLogo"
        case "zai": providerAsset = "ZaiLogo"
        case "elevenlabs": providerAsset = "ElevenLabsLogo"
        case "deepgram": providerAsset = "DeepgramLogo"
        case "groq": providerAsset = "GroqLogo"
        case "grok": providerAsset = "GrokLogo"
        case "ollama": providerAsset = "OllamaLogo"
        case "copilot": providerAsset = "CopilotLogo"
        case "kilo": providerAsset = "KiloLogo"
        case "commandcode": providerAsset = "CommandCodeLogo"
        case "freemodel": providerAsset = "FreemodelLogo"
        case "mimo": providerAsset = "MiMoLogo"
        case "alibaba": providerAsset = "AlibabaLogo"
        case "cursor": providerAsset = "CursorLogo"
        case "gemini": providerAsset = "GeminiLogo"
        case "kiro": providerAsset = "KiroLogo"
        case "opencode": providerAsset = "OpenCodeLogo"
        case "opencodego": providerAsset = "OpenCodeGoLogo"
        case "antigravity": providerAsset = "AntigravityLogo"
        case "bedrock": providerAsset = "BedrockLogo"
        case "hiyo": providerAsset = "HiyoLogo"
        default:
            return fallbackLogo(pointSize)
        }
        return scaled(NSImage(named: providerAsset), to: pointSize, isTemplate: true)
            ?? fallbackLogo(pointSize)
    }

    /// Neutral, theme-aware logo for providers without a brand asset.
    private static func fallbackLogo(_ pointSize: CGFloat) -> NSImage {
        let symbol = NSImage(systemSymbolName: "bolt.horizontal.circle.fill",
                             accessibilityDescription: nil)
        return scaled(symbol, to: pointSize, isTemplate: true)
            ?? NSImage(size: NSSize(width: pointSize, height: pointSize))
    }

    /// Redraw `image` into a square `pointSize` bitmap with high-quality
    /// interpolation so it stays crisp at small menu bar sizes. `isTemplate`
    /// lets AppKit tint the alpha mask to match the current menu-bar appearance.
    private static func scaled(_ image: NSImage?, to pointSize: CGFloat,
                               isTemplate: Bool) -> NSImage? {
        guard let source = image else { return nil }
        let target = NSSize(width: pointSize, height: pointSize)
        let rect = NSRect(origin: .zero, size: target)
        let out = NSImage(size: target)
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: rect,
                    from: NSRect(origin: .zero, size: source.size),
                    operation: .sourceOver,
                    fraction: 1.0)
        out.unlockFocus()
        out.isTemplate = isTemplate
        return out
    }
}

// MARK: - Kiro menu-bar display mode (mirrors CodexBar's KiroMenuBarDisplayMode)

/// How Kiro's quota is shown next to the menu-bar icon. Persisted in
/// UserDefaults under `defaultsKey`; `MenuBarIconRenderer.kiroDisplayText`
/// turns the selected mode + the provider's `kiroMenu` data into the title.
enum KiroMenuBarDisplayMode: String, CaseIterable, Identifiable {
    case automatic
    case hidden
    case creditsLeft
    case percentLeft
    case creditsAndPercent
    case usedAndTotal
    case overageCreditsWhenExhausted
    case overageCostWhenExhausted
    case overageCreditsAndCostWhenExhausted

    static let defaultsKey = "kiroMenuBarDisplayMode"

    var id: String { rawValue }

    static var current: KiroMenuBarDisplayMode {
        KiroMenuBarDisplayMode(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .automatic
    }
}

// MARK: - Generic per-provider menu-bar metric

/// Per-provider selection of which window drives the menu bar, persisted under
/// `menuBarMetric.<id>`. "" (the default) means Automatic — show every window.
/// Otherwise it stores a window label to isolate. Mirrors CodexBar's universal
/// "Menu bar metric" picker; BirdNion exposes it for gemini/kiro/bedrock.
enum MenuBarMetricStore {
    static func key(_ id: String) -> String { "menuBarMetric.\(id)" }

    static func metric(_ id: String) -> String {
        UserDefaults.standard.string(forKey: key(id)) ?? ""
    }

    static func setMetric(_ id: String, _ value: String) {
        if value.isEmpty {
            UserDefaults.standard.removeObject(forKey: key(id))
        } else {
            UserDefaults.standard.set(value, forKey: key(id))
        }
    }

    /// Isolates the window whose label matches the stored metric. Falls back to
    /// all windows when Automatic or the saved label no longer exists.
    static func filter(_ windows: [QuotaWindow], id: String) -> [QuotaWindow] {
        let m = metric(id)
        guard !m.isEmpty else { return windows }
        let matched = windows.filter { $0.label == m }
        return matched.isEmpty ? windows : matched
    }
}
