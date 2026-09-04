import AppKit
import SwiftUI

/// Builds the frame shown by the menu bar status item. AppDelegate owns the
/// timer fallback; this type only describes each frame and renders the images
/// it needs.
///
/// The default frame is the BirdNion logo. When the user enables menu-bar
/// percentages, provider quota frames rotate in sorted order: **active**
/// providers first (any window with remaining under 100% / used over 0), then
/// alphabetically by `displayName`.
@MainActor
enum MenuBarIconRenderer {
    static let assetName = "MenuBarIcon"

    /// One possible menu-bar frame.
    enum Frame: Equatable {
        /// Just the BirdNion logo, no text.
        case bird
        /// A provider: `percents` are its windows' `remainingPct` in order;
        /// `id` selects the brand logo drawn to the right of the percentages.
        /// `text`, when non-nil, replaces the joined percents entirely (Kiro's
        /// display-mode picker uses this to show credits / used÷total / overage
        /// instead of percent).
        case provider(id: String, name: String, percents: [Int], text: String?)
    }

    enum PercentTitleLayout {
        case inline
        case stacked

        var separator: String {
            switch self {
            case .inline: return "  "
            case .stacked: return "\n"
            }
        }
    }

    static func percentTitle(
        for percents: [Int],
        layout: PercentTitleLayout = .inline
    ) -> String {
        percents
            .map { value in "\(max(0, min(100, value)))%" }
            .joined(separator: layout.separator)
    }

    static let stackedTitleFontSize: CGFloat = 9
    static let stackedProviderLogoGap: CGFloat = 1
    static let stackedProviderImageHeight: CGFloat = 24
    static let providerLogoBasePointSize: CGFloat = 18
    static let freemodelLogoScale: CGFloat = 1.1
    /// Claude's mark is denser at menu-bar sizes — +15% over the base logo.
    static let claudeLogoScale: CGFloat = 1.15

    static func attributedStackedTitle(_ title: String, font: NSFont) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .right
        return NSAttributedString(
            string: title,
            attributes: [
                .font: font,
                .paragraphStyle: paragraphStyle,
                .foregroundColor: NSColor.controlTextColor,
            ])
    }

    static func stackedPercentLines(for percents: [Int]) -> [String] {
        Array(percents.prefix(2)).map { value in
            "\(max(0, min(100, value)))%"
        }
    }

    /// Render the exact-two-value provider frame as one template image. This
    /// avoids AppKit's relaunch-dependent multiline title positioning while
    /// keeping the native status-button cell for all other frames.
    static func stackedProviderImage(for id: String, percents: [Int]) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(
            ofSize: stackedTitleFontSize, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.controlTextColor,
        ]
        let lines = stackedPercentLines(for: percents)
        let lineWidths = lines.map { ($0 as NSString).size(withAttributes: attributes).width }
        let textWidth = ceil(max(1, lineWidths.max() ?? 1))
        let logoSize = providerLogoPointSize(for: id)
        let targetSize = NSSize(
            width: textWidth + stackedProviderLogoGap + logoSize,
            height: stackedProviderImageHeight)
        let image = NSImage(size: targetSize)

        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        let lineHeight = ceil(font.ascender - font.descender)
        let bottomY: CGFloat = 1
        for (index, line) in lines.enumerated() {
            let width = lineWidths[index]
            let y = index == 0
                ? targetSize.height - lineHeight - 1
                : bottomY
            (line as NSString).draw(
                at: NSPoint(x: textWidth - width, y: y),
                withAttributes: attributes)
        }

        let logo = providerLogo(for: id, pointSize: logoSize)
        logo.draw(
            in: NSRect(
                x: textWidth + stackedProviderLogoGap,
                y: (targetSize.height - logoSize) / 2,
                width: logoSize,
                height: logoSize),
            from: NSRect(origin: .zero, size: logo.size),
            operation: .sourceOver,
            fraction: 1)
        image.unlockFocus()
        image.isTemplate = true
        return image
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
        let codexMetric = status.id == "codex" ? CodexMenuBarMetric.current : nil
        let windows: [QuotaWindow]
        if let codexMetric {
            windows = codexMetric.filter(status.windows)
        } else if status.id == "antigravity" {
            windows = status.windows
        } else {
            windows = MenuBarMetricStore.filter(status.windows, id: status.id)
        }
        guard !windows.isEmpty else { return nil }

        let text = status.id == "kiro"
            ? kiroDisplayText(status: status, mode: KiroMenuBarDisplayMode.current)
            : nil
        if text == "" { return nil }

        // Use the new generic resolver for all providers except Kiro (which has its own mode)
        // and providers with special logic (Codex, Antigravity, FreeModel).
        if status.id == "kiro" || status.id == "freemodel" || status.id == "antigravity" {
            // Keep existing special handling
        } else {
            let settings = ServicesContainer.shared?.settings ?? SettingsStore()
            let pref = status.id == "codex"
                ? MenuBarMetricPreference.automatic
                : settings.metricPreference(for: status.id)
            let caps = settings.providerCapabilities(for: status.id)
            let hasMonthlyPlan = caps.hasMonthlyPlan

            if pref == .average {
                let avg = windows.map(\.remainingPct).reduce(0, +) / max(1, windows.count)
                return .provider(id: status.id, name: status.displayName, percents: [avg], text: L10n.f("menuBar.avg", nil, "\(avg)"))
            }

            let canonicalAutomaticWindows: [QuotaWindow]
            if pref != .automatic {
                canonicalAutomaticWindows = []
            } else if status.id == "claude" {
                canonicalAutomaticWindows = claudeAutomaticWindows(windows)
            } else if status.id == "codex", codexMetric == .automatic {
                canonicalAutomaticWindows = codexAutomaticWindows(windows)
            } else {
                canonicalAutomaticWindows = []
            }
            let selectedWindows: [QuotaWindow]?
            if !canonicalAutomaticWindows.isEmpty {
                selectedWindows = canonicalAutomaticWindows
            } else {
                selectedWindows = MenuBarMetricResolver.resolve(
                    windows: windows,
                    preference: pref,
                    supportsAverage: caps.supportsAverage,
                    supportsPrimaryAndSecondary: caps.hasPrimary && caps.hasSecondary,
                    supportsTertiary: caps.hasTertiary,
                    supportsExtraUsage: caps.hasExtraUsage,
                    hasMonthlyPlan: hasMonthlyPlan
                )
            }

            if let selectedWindows {
                let percents = selectedWindows.map(\.remainingPct)
                guard !percents.isEmpty else { return nil }
                return .provider(id: status.id, name: status.displayName, percents: percents, text: nil)
            }
            return nil
        }

        let percents: [Int]
        if status.id == "freemodel" {
            percents = freemodelMenuBarPercents(windows)
        } else if status.id == "antigravity" {
            percents = antigravityMenuBarPercents(
                windows,
                metric: AntigravityMenuBarMetric.current)
        } else {
            percents = windows.map { $0.remainingPct }
        }
        guard !percents.isEmpty else { return nil }
        return .provider(
            id: status.id,
            name: status.displayName,
            percents: percents,
            text: text
        )
    }

    /// Automatic preserves Antigravity's original single representative.
    /// Explicit groups keep a stable 5-hour → weekly stacked order.
    static func antigravityMenuBarPercents(
        _ windows: [QuotaWindow],
        metric: AntigravityMenuBarMetric = .current
    ) -> [Int] {
        let available = windows.filter { !$0.isSupplementary }
        let gemini = antigravityGroup(
            prefix: "Gemini",
            aggregateLabel: "Gemini",
            windows: available
        )
        let claudeGPT = antigravityGroup(
            prefix: "Claude/GPT",
            aggregateLabel: "Claude/GPT",
            windows: available
        )
        switch metric {
        case .automatic:
            return antigravityAutomaticPercent(available)
        case .gemini:
            guard !gemini.isEmpty else {
                return antigravityAutomaticPercent(available)
            }
            return gemini.map { max(0, min(100, $0.remainingPct)) }
        case .claudeGPT:
            guard !claudeGPT.isEmpty else {
                return antigravityAutomaticPercent(available)
            }
            return claudeGPT.map { max(0, min(100, $0.remainingPct)) }
        }
    }

    /// FreeModel: the bonus "Số dư" window stays out of the menu bar (it is
    /// not a rate window). Once the 5-hour window is exhausted and bonus
    /// balance remains, the readout collapses to JUST the balance percent —
    /// credits apply automatically at that point, so it's the only number
    /// that matters until the window resets.
    static func freemodelMenuBarPercents(_ windows: [QuotaWindow]) -> [Int] {
        let balance = windows.first { $0.label == "Số dư" }
        if let fiveH = windows.first(where: { $0.label == "5 giờ" }),
           !fiveH.isInactive,
           fiveH.remainingPct <= 0,
           let balance, balance.remainingPct > 0 {
            return [balance.remainingPct]
        }
        let percents = windows
            .filter { $0.label != "Số dư" && !$0.isInactive }
            .map(\.remainingPct)
        // The menu-bar metric picker isolated the balance window itself →
        // show it as-is instead of an empty title.
        if percents.isEmpty, let balance { return [balance.remainingPct] }
        return percents
    }

    /// Claude's default menu-bar readout mirrors FreeModel: show the two
    /// canonical recurring budgets, in a stable 5-hour → weekly order. Opus
    /// and extra-usage windows remain available to explicit metric choices.
    static func claudeAutomaticWindows(_ windows: [QuotaWindow]) -> [QuotaWindow] {
        ["5 giờ", "Tuần"].compactMap { label in
            windows.first { $0.label == label }
        }
    }

    private static func antigravityGroup(
        prefix: String,
        aggregateLabel: String,
        windows: [QuotaWindow]
    ) -> [QuotaWindow] {
        let canonical = ["\(prefix) 5-hour", "\(prefix) weekly"].compactMap { label in
            windows.first { $0.label == label }
        }
        if !canonical.isEmpty { return canonical }
        return windows.first { $0.label == aggregateLabel }.map { [$0] } ?? []
    }

    private static func antigravityAutomaticPercent(_ windows: [QuotaWindow]) -> [Int] {
        let semantic = windows.filter { window in
            [
                "Gemini 5-hour",
                "Gemini weekly",
                "Claude/GPT 5-hour",
                "Claude/GPT weekly",
                "Gemini",
                "Claude/GPT",
            ].contains(window.label)
        }
        func pool(_ label: String) -> String? {
            if label.hasPrefix("Gemini") { return "gemini" }
            if label.hasPrefix("Claude/GPT") { return "claudeGPT" }
            return nil
        }
        let gemini = semantic.filter { pool($0.label) == "gemini" }
        let claudeGPT = semantic.filter { pool($0.label) == "claudeGPT" }
        // OAuth model buckets use labels such as Pro/Flash rather than the
        // grouped Gemini/Claude labels. Keep a conservative single readout
        // instead of hiding Antigravity when no semantic group is available.
        let candidates = gemini.isEmpty ? (claudeGPT.isEmpty ? windows : claudeGPT) : gemini
        let selected = candidates.max { lhs, rhs in
            if lhs.usedPct != rhs.usedPct { return lhs.usedPct < rhs.usedPct }
            func intervalRank(_ label: String) -> Int {
                label.hasSuffix("5-hour") ? 0 : label.hasSuffix("weekly") ? 1 : 2
            }
            let lhsRank = intervalRank(lhs.label)
            let rhsRank = intervalRank(rhs.label)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.remainingPct > rhs.remainingPct
        }
        return selected.map { [max(0, min(100, $0.remainingPct))] } ?? []
    }

    /// Codex mirrors Claude's stacked recurring-budget readout only when both
    /// canonical windows exist. Weekly-only Pro accounts and partial data keep
    /// the existing single representative selected by the generic resolver.
    static func codexAutomaticWindows(_ windows: [QuotaWindow]) -> [QuotaWindow] {
        let canonical = ["5 giờ", "Tuần"].compactMap { label in
            windows.first { $0.label == label }
        }
        return canonical.count == 2 ? canonical : []
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

    /// The BirdNion mark, scaled to `pointSize` while preserving its built-in
    /// progress gradient. Template rendering would flatten every opaque pixel
    /// to one color and make the progress bar look completely filled.
    /// Default menu-bar mark size (compact in the status item).
    static func iconImage(pointSize: CGFloat = 18) -> NSImage {
        scaled(NSImage(named: assetName), to: pointSize, isTemplate: false)
            ?? NSImage(size: NSSize(width: pointSize, height: pointSize))
    }

    /// Brand logo for a provider id, scaled as a monochrome template so AppKit
    /// applies the correct menu-bar foreground color in every appearance.
    static func providerLogoPointSize(
        for id: String,
        base: CGFloat = 18
    ) -> CGFloat {
        switch id {
        case "claude": return base * claudeLogoScale
        case "freemodel": return base * freemodelLogoScale
        default: return base
        }
    }

    static func providerLogo(
        for id: String,
        pointSize: CGFloat = 18
    ) -> NSImage {
        let effectivePointSize = providerLogoPointSize(for: id, base: pointSize)
        let providerAsset: String
        switch id {
        case "minimax": providerAsset = "MiniMaxLogo"
        case "hapo": providerAsset = "HapoLogo"
        case "claude": providerAsset = "ClaudeLogo"
        case "codex", "openai": providerAsset = "CodexLogo"
        case "openrouter": providerAsset = "OpenRouterLogo"
        case "tryapi": providerAsset = "TryAPILogo"
        case "deepseek": providerAsset = "DeepSeekLogo"
        case "zai": providerAsset = "ZaiLogo"
        case "elevenlabs": providerAsset = "ElevenLabsLogo"
        case "deepgram": providerAsset = "DeepgramLogo"
        case "groq": providerAsset = "GroqLogo"
        case "grok": providerAsset = "GrokLogo"
        case "xai": providerAsset = "XAILogo"
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
            return fallbackLogo(effectivePointSize)
        }
        return scaled(NSImage(named: providerAsset), to: effectivePointSize, isTemplate: true)
            ?? fallbackLogo(effectivePointSize)
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

// MARK: - Generic per-provider menu-bar metric (CodexBar parity)

/// Per-provider selection of which window drives the menu bar percent.
/// Mirrors CodexBar's `MenuBarMetricPreference` (8 cases). Persisted in
/// SettingsStore under `menuBarMetricPreferences[providerId]`.
enum MenuBarMetricPreference: String, CaseIterable, Identifiable {
    case automatic
    case primary
    case secondary
    case primaryAndSecondary
    case tertiary
    case extraUsage
    case average
    case monthlyPlan

    var id: String { rawValue }
    var label: String { L10n.t("metric_pref_\(rawValue)") }
}

/// Pure resolver: given a provider's windows, the user's preference, and
/// capability flags, return the windows that should drive the menu bar
/// (or nil for `.average` which is rendered as text by the caller).
enum MenuBarMetricResolver {
    static func resolve(
        windows: [QuotaWindow],
        preference: MenuBarMetricPreference,
        supportsAverage: Bool,
        supportsPrimaryAndSecondary: Bool,
        supportsTertiary: Bool,
        supportsExtraUsage: Bool,
        hasMonthlyPlan: Bool
    ) -> [QuotaWindow]? {
        // Fallback to automatic if the selected preference isn't supported.
        let effectivePref: MenuBarMetricPreference
        switch preference {
        case .average where !supportsAverage:
            effectivePref = .automatic
        case .primaryAndSecondary where !supportsPrimaryAndSecondary:
            effectivePref = .automatic
        case .tertiary where !supportsTertiary:
            effectivePref = .automatic
        case .extraUsage where !supportsExtraUsage:
            effectivePref = .automatic
        case .monthlyPlan where !hasMonthlyPlan:
            effectivePref = .automatic
        default:
            effectivePref = preference
        }

        switch effectivePref {
        case .automatic:
            return automaticWindow(windows).map { [$0] }
        case .primary:
            return windows.first.map { [$0] }
        case .secondary:
            return windows.dropFirst().first.map { [$0] }
        case .primaryAndSecondary:
            let selected = Array(windows.prefix(2))
            return selected.isEmpty ? nil : selected
        case .tertiary:
            return windows.dropFirst(2).first.map { [$0] }
        case .extraUsage:
            return windows.first { $0.label.localizedCaseInsensitiveContains("extra") }
                .map { [$0] }
        case .average:
            // Average is rendered as text by the caller; return nil sentinel.
            return nil
        case .monthlyPlan:
            return windows.first { w in
                w.label.localizedCaseInsensitiveContains("monthly") || w.label.localizedCaseInsensitiveContains("plan")
            }.map { [$0] }
        }
    }

    /// CodexBar parity: prefer exhausted window, then highest usage.
    private static func automaticWindow(_ windows: [QuotaWindow]) -> QuotaWindow? {
        windows.max { lhs, rhs in
            if lhs.remainingPct != rhs.remainingPct { return lhs.remainingPct > rhs.remainingPct }
            return lhs.usedPct < rhs.usedPct
        }
    }
}

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
