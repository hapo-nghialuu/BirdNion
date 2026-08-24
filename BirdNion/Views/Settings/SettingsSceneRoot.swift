import AppKit
import SwiftUI

/// Semantic Settings palette (aliases onto VocabbyTheme light/dark tokens).
enum SettingsTheme {
    static let background = VocabbyTheme.background
    static let toolbar = VocabbyTheme.segment
    static let card = VocabbyTheme.card
    static let control = VocabbyTheme.group
    static let selectedSurface = VocabbyTheme.selectedSurface
    static let hoverSurface = VocabbyTheme.hoverSurface
    static let border = VocabbyTheme.border
    static let track = VocabbyTheme.track
    static let primary = VocabbyTheme.primary
    static let secondary = VocabbyTheme.secondary
    static let tertiary = VocabbyTheme.tertiary
    static let accent = VocabbyTheme.blue
    static let success = VocabbyTheme.success
    static let successSurface = VocabbyTheme.successSurface
    static let warning = VocabbyTheme.yellow
    static let warningFill = VocabbyTheme.warningFill
    static let warningSurface = VocabbyTheme.warningSurface
    static let critical = VocabbyTheme.critical
    static let criticalSurface = VocabbyTheme.criticalSurface
    static let disabled = VocabbyTheme.disabled
    static let hairline = VocabbyTheme.hairline
    static let inkRule = VocabbyTheme.inkRule

    static func quotaColor(remaining: Int) -> Color {
        VocabbyTheme.quotaColor(remaining: remaining)
    }

    static func quotaFillColor(remaining: Int) -> Color {
        VocabbyTheme.quotaFillColor(remaining: remaining)
    }

    static func usedFillColor(usedPercent: Int) -> Color {
        VocabbyTheme.usedFillColor(usedPercent: usedPercent)
    }
}

/// Root view rendered inside AppDelegate's settings NSWindow. Hosts the vertical
/// sidebar on the left + a scrollable content pane on the right (remake P2).
struct SettingsSceneRoot: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var config: ConfigService
    @EnvironmentObject var quota: QuotaService

    @State private var selected = SettingsTab.restored(
        UserDefaults.standard.string(forKey: "birdnion.settingsSection"))
    /// One Settings-wide search (nav + contextual roster). Owned here so
    /// Providers/AI Coding don't mount a second search field.
    @State private var sidebarSearch = ""
    /// Action Center mở dạng sheet (không còn là mục sidebar).
    @State private var showActionCenter = false

    /// One constant window size for all tabs — wide enough for the providers
    /// sidebar + detail, still fine for the single-column tabs. This MUST stay
    /// constant: the `Settings` scene has no `.windowResizability(.contentSize)`,
    /// because a window that re-fits its content on every re-render (e.g. each
    /// QuotaService publish) drives NSHostingView's autoresizing constraints
    /// into an NSISEngine recursion that crashes the whole app.
    private let contentWidth: CGFloat = 920
    private let contentHeight: CGFloat = 620

    var body: some View {
        Group {
            switch selected {
            // Providers / AI Coding render the whole row themselves: their
            // roster list lives inside the sidebar column (below the nav),
            // so the pane owns both the embedded list state and the detail.
            case .providers: ProvidersPane(tab: $selected, searchText: $sidebarSearch)
            case .agents: AgentsPane(tab: $selected, searchText: $sidebarSearch)
            case .aiCoding: AICodingPane(tab: $selected, searchText: $sidebarSearch)
            case .insights: navAndContent { InsightsPane() }
            case .general: navAndContent { GeneralPane() }
            case .advanced: navAndContent { AdvancedPane() }
            case .about: navAndContent { AboutPane() }
            // Action Center không có pane riêng nữa (sheet) — fallback General.
            case .actionCenter: navAndContent { GeneralPane() }
            }
        }
        .frame(width: contentWidth, height: contentHeight)
        // Opaque backing so AppKit always has something to clear to.
        .background(SettingsTheme.background)
        .overlay(SettingsWindowAppearanceView().frame(width: 0, height: 0))
        .tint(SettingsTheme.accent)
        .onReceive(NotificationCenter.default.publisher(for: .openClaudeCodeTab)) { _ in
            selected = .aiCoding
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAgentsTab)) { _ in
            selected = .agents
        }
        .onReceive(NotificationCenter.default.publisher(for: .openProvidersTab)) { _ in
            selected = .providers
        }
        .onReceive(NotificationCenter.default.publisher(for: .openInsightsTab)) { _ in
            selected = .insights
        }
        .onReceive(NotificationCenter.default.publisher(for: .openActionCenterTab)) { _ in
            // Action Center giờ là sheet, không phải mục sidebar.
            showActionCenter = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .openGeneralTab)) { _ in
            selected = .general
        }
        .onReceive(NotificationCenter.default.publisher(for: .openProviderSetup)) { _ in
            UserDefaults.standard.set("providers", forKey: "birdnion.settingsSection")
            selected = .providers
        }
        .onChange(of: selected) { _, value in
            UserDefaults.standard.set(value.rawValue, forKey: "birdnion.settingsSection")
        }
        .sheet(isPresented: $showActionCenter) {
            ActionCenterSheet(isPresented: $showActionCenter)
                .environmentObject(quota)
                .environmentObject(settings)
        }
    }

    /// Standard row for single-column tabs: nav-only sidebar + content pane.
    private func navAndContent<Pane: View>(@ViewBuilder _ pane: () -> Pane) -> some View {
        HStack(spacing: 0) {
            SettingsSidebar(selected: $selected, searchText: $sidebarSearch)
            pane()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

extension Notification.Name {
    /// Kept for existing quick-apply callers; the route now opens AI Coding.
    static let openClaudeCodeTab = Notification.Name("birdnion.openClaudeCodeTab")
    static let openAgentsTab = Notification.Name("birdnion.openAgentsTab")
    static let openProviderSetup = Notification.Name("birdnion.openProviderSetup")
    static let openInsightsTab = Notification.Name("birdnion.openInsightsTab")
    static let openActionCenterTab = Notification.Name("birdnion.openActionCenterTab")
    static let openGeneralTab = Notification.Name("birdnion.openGeneralTab")
}

struct ProviderSettingsRoute: Equatable, Sendable {
    let providerID: String
    let target: ProviderRemediationTarget?
}

@MainActor
func openInsightsSettings(segment: InsightsSegment = .overview) {
    UserDefaults.standard.set(SettingsTab.insights.rawValue, forKey: "birdnion.settingsSection")
    UserDefaults.standard.set(segment.rawValue, forKey: InsightsSegment.defaultsKey)
    NotificationCenter.default.post(name: .openInsightsTab, object: nil)
    NotificationCenter.default.post(name: .openSettings, object: nil)
}

@MainActor
func openAgentSettings(id: InstalledAgentID) {
    UserDefaults.standard.set(SettingsTab.agents.rawValue, forKey: "birdnion.settingsSection")
    UserDefaults.standard.set(id.rawValue, forKey: "settings.selectedAgentID")
    NotificationCenter.default.post(name: .openAgentsTab, object: nil)
    NotificationCenter.default.post(name: .openSettings, object: nil)
}

@MainActor
func openActionCenterSettings() {
    UserDefaults.standard.set(SettingsTab.actionCenter.rawValue, forKey: "birdnion.settingsSection")
    NotificationCenter.default.post(name: .openActionCenterTab, object: nil)
    NotificationCenter.default.post(name: .openSettings, object: nil)
}

@MainActor
func openProviderSettings(_ id: String, target: ProviderRemediationTarget? = nil) {
    UserDefaults.standard.set("providers", forKey: "birdnion.settingsSection")
    UserDefaults.standard.set(id, forKey: "birdnion.selectedProvider")
    if let target {
        UserDefaults.standard.set(target.rawValue, forKey: "birdnion.providerRemediationTarget")
    } else {
        UserDefaults.standard.removeObject(forKey: "birdnion.providerRemediationTarget")
    }
    NotificationCenter.default.post(
        name: .openProviderSetup,
        object: ProviderSettingsRoute(providerID: id, target: target))
    NotificationCenter.default.post(name: .openSettings, object: nil)
}

@MainActor
func openAICodingSettings(providerID: String? = nil, profileID: String? = nil) {
    UserDefaults.standard.set(SettingsTab.aiCoding.rawValue, forKey: "birdnion.settingsSection")
    if let providerID, !providerID.isEmpty {
        UserDefaults.standard.set(providerID, forKey: "birdnion.selectedAICodingProvider")
        UserDefaults.standard.removeObject(forKey: "birdnion.selectedAICodingProfile")
    } else if let profileID, !profileID.isEmpty {
        UserDefaults.standard.set(profileID, forKey: "birdnion.selectedAICodingProfile")
        UserDefaults.standard.removeObject(forKey: "birdnion.selectedAICodingProvider")
    }
    NotificationCenter.default.post(name: .openClaudeCodeTab, object: nil)
    NotificationCenter.default.post(name: .openSettings, object: nil)
}

/// Shared Settings sidebar search matching (provider aliases + page keywords).
enum SettingsSearchIndex {
    static func installedAgentMatches(_ record: InstalledAgentRecord, query: String) -> Bool {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return true }
        let hay = "\(record.displayName) \(record.id.rawValue) \(record.providerIDs.joined(separator: " "))".lowercased()
        return hay.contains(q)
    }

    static func providerTitle(id: String, fallback: String?) -> String {
        switch id {
        case "codex": return "Codex"
        case "minimax": return "MiniMax"
        case "hapo": return fallback ?? "Hapo Hub"
        case "claude": return "Claude"
        case "openrouter": return "OpenRouter"
        case "tryapi": return "TryAPI"
        case "deepseek": return "DeepSeek"
        case "zai": return "z.ai"
        case "elevenlabs": return "ElevenLabs"
        case "deepgram": return "Deepgram"
        case "groq": return "Groq"
        case "grok": return "Grok"
        case "xai": return "xAI"
        case "openai": return "OpenAI"
        case "ollama": return "Ollama"
        case "copilot": return "Copilot"
        case "kilo": return "Kilo"
        case "commandcode": return "Command Code"
        case "mimo": return "Xiaomi MiMo"
        case "alibaba": return "Alibaba / Qwen"
        case "cursor": return "Cursor"
        case "gemini": return "Gemini"
        case "kiro": return "Kiro"
        case "opencode": return "OpenCode"
        case "opencodego": return "OpenCode Go"
        case "antigravity": return "Antigravity"
        case "bedrock": return "AWS Bedrock"
        case "freemodel": return "FreeModel"
        case "hiyo": return "Hiyo"
        default: return fallback ?? id
        }
    }

    static func providerAliases(id: String) -> [String] {
        switch id {
        case "claude": return ["claude", "anthropic", "fable", "sessionkey", "oauth", "keychain"]
        case "codex": return ["codex", "openai", "chatgpt", "spark", "chatgpt"]
        case "grok", "xai": return ["grok", "xai", "x.ai"]
        case "gemini": return ["gemini", "google"]
        case "copilot": return ["copilot", "github"]
        case "antigravity": return ["antigravity", "google", "oauth"]
        case "bedrock": return ["bedrock", "aws", "amazon"]
        case "alibaba": return ["alibaba", "qwen", "dashscope"]
        case "zai": return ["zai", "z.ai", "bigmodel", "glm"]
        case "minimax": return ["minimax", "abab"]
        case "kiro": return ["kiro", "aws"]
        case "cursor": return ["cursor"]
        case "openrouter": return ["openrouter"]
        case "deepseek": return ["deepseek"]
        case "elevenlabs": return ["elevenlabs", "eleven"]
        case "hiyo": return ["hiyo"]
        case "kilo": return ["kilo"]
        default: return [id]
        }
    }

    static func providerMatches(id: String, title: String, query: String) -> Bool {
        let q = query.lowercased()
        guard !q.isEmpty else { return true }
        if title.lowercased().contains(q) || id.lowercased().contains(q) { return true }
        return providerAliases(id: id).contains { $0.contains(q) || q.contains($0) }
    }

    static func pageKeywords(_ tab: SettingsTab, language: String?) -> [String] {
        let vi = L10n.languageCode(language) == "vi"
        switch tab {
        case .general:
            return vi
                ? ["giao diện", "ngôn ngữ", "ngân sách", "làm mới", "thông báo", "hotkey", "khởi động"]
                : ["appearance", "language", "budget", "refresh", "notification", "hotkey", "login"]
        case .actionCenter:
            return vi
                ? ["lỗi", "sửa", "kết nối", "thiết lập", "remediation"]
                : ["error", "fix", "connection", "setup", "remediation"]
        case .providers:
            return vi
                ? ["token", "api key", "quota", "cookie", "oauth", "region", "nhà cung cấp"]
                : ["token", "api key", "quota", "cookie", "oauth", "region", "provider"]
        case .agents:
            return vi
                ? ["agent", "agents", "công cụ", "cli", "ide", "danh mục", "catalog"]
                : ["agent", "agents", "tool", "cli", "ide", "catalog"]
        case .aiCoding:
            return vi
                ? ["claude code", "codex", "proxy", "model", "profile", "backend", "cli"]
                : ["claude code", "codex", "proxy", "model", "profile", "backend", "cli"]
        case .insights:
            return vi
                ? ["phân tích", "usage", "project", "chi tiêu", "overview", "hoạt động"]
                : ["insights", "usage", "project", "spend", "overview", "activity"]
        case .advanced:
            return vi
                ? ["debug", "cấu hình", "finder", "storage"]
                : ["debug", "config", "finder", "storage"]
        case .about:
            return vi
                ? ["phiên bản", "cập nhật", "brew", "giới thiệu"]
                : ["version", "update", "brew", "about"]
        }
    }
}

private struct SettingsWindowAppearanceView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { apply(to: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { apply(to: nsView) }
    }

    private func apply(to view: NSView) {
        guard let window = view.window else { return }
        // Appearance is app-wide (SettingsStore.applyAppearance); here we only
        // keep the window background matched to Instrument paper/ink so
        // AppKit clears to the right color during live resize in both modes.
        window.appearance = nil
        // VocabbyTheme.background: light #FBFAF7 / dark #17170F
        window.backgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 23 / 255, green: 23 / 255, blue: 15 / 255, alpha: 1)
                : NSColor(srgbRed: 251 / 255, green: 250 / 255, blue: 247 / 255, alpha: 1)
        }
    }
}

// MARK: - Instrument layout primitives
//
// Avoid SwiftUI's `Form(.grouped)` — inside our NSWindow it can drive
// NSISEngine recursion. These plain containers mirror the Linux instrument
// Settings CSS (`.settings-page` / `.sw-card` transparent / `.sw-row`
// hairline-top) so macOS Settings matches the popover redesign language.

/// Scrollable settings page — stack of section groups on paper background.
struct SettingsPage<Content: View>: View {
    var maxContentWidth: CGFloat? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(.horizontal, 26)
            .padding(.top, 22)
            .padding(.bottom, 30)
            .frame(maxWidth: maxContentWidth ?? .infinity, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: maxContentWidth == nil ? .leading : .top)
        }
        .background(SettingsTheme.background)
    }
}

/// Section group: uppercase eyebrow + hairline-divided rows (no filled card).
/// Rows supply their own top hairline via `SettingsLabeledRow` /
/// `SettingsRowDivider` no longer draws a second rule.
struct SettingsCard<Content: View>: View {
    var header: String? = nil
    var footer: LocalizedStringKey? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let header {
                SettingsSectionHeader(title: header)
            }
            VStack(spacing: 0) { content() }
            if let footer {
                Text(footer)
                    .font(.plexSans(12))
                    .foregroundStyle(SettingsTheme.tertiary)
                    .padding(.top, 10)
            }
        }
    }
}

/// Legacy separator between rows. Instrument rows already draw a top hairline
/// on `SettingsLabeledRow`, so this is a no-op kept for call-site compatibility.
struct SettingsRowDivider: View {
    var body: some View { EmptyView() }
}

// MARK: - Shared row views

/// Pane title + optional subtitle, underlined by the strong ink rule.
struct SettingsPaneHeader: View {
    let title: String
    var subtitle: String? = nil
    /// Action Center nằm trong header để thẳng lề nội dung + ngang tiêu đề.
    var showsActionCenter: Bool = true

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.plexSans(22, weight: .bold))
                    .tracking(-0.5)
                    .foregroundStyle(SettingsTheme.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.plexSans(13))
                        .foregroundStyle(SettingsTheme.secondary)
                }
            }
            Spacer(minLength: 8)
            if showsActionCenter { ActionCenterIconButton() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 16)
        .inkRuleBottom()
        .padding(.bottom, 4)
    }
}

/// Uppercase mono eyebrow above each settings group (HỆ THỐNG / SỬ DỤNG / …).
struct SettingsSectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .plexEyebrow()
            .padding(.top, 22)
            .padding(.bottom, 4)
    }
}

/// Shared trailing-column width so menus, toggles, and fields share one edge.
enum SettingsControlMetrics {
    static let trailingWidth: CGFloat = 160
    static let rowMinHeight: CGFloat = 52
    static let verticalPadding: CGFloat = 12
}

/// Title + optional subtitle + trailing control. Top hairline replaces the
/// old card-internal divider (Linux `.sw-row { border-top: hairline }`).
/// Trailing controls sit in a fixed-width column so pickers/toggles/fields
/// align top-to-bottom on the trailing edge.
struct SettingsLabeledRow<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let trailing: () -> Content

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.plexSans(14, weight: .medium))
                    .foregroundStyle(SettingsTheme.primary)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.plexSans(12))
                        .foregroundStyle(SettingsTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing()
                .font(.plexSans(12))
                .frame(width: SettingsControlMetrics.trailingWidth, alignment: .trailing)
        }
        .padding(.vertical, SettingsControlMetrics.verticalPadding)
        .frame(maxWidth: .infinity, minHeight: SettingsControlMetrics.rowMinHeight, alignment: .center)
        .contentShape(Rectangle())
        .hairlineTop(SettingsTheme.hairline)
    }
}
