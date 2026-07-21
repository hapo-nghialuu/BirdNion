// Minimal vi/en string table for the web UI — mirrors the macOS app's
// hardcoded-dictionary approach (AppLocalizer) rather than gettext.
// Language persists in localStorage; vi is the default like on macOS.

const LANG_KEY = "birdnion.lang";

export type Lang = "vi" | "en";

export function currentLang(): Lang {
  return localStorage.getItem(LANG_KEY) === "en" ? "en" : "vi";
}

export function setLang(lang: Lang) {
  localStorage.setItem(LANG_KEY, lang);
}

const STRINGS: Record<string, { vi: string; en: string }> = {
  today: { vi: "Hôm nay", en: "Today" },
  days: { vi: "ngày", en: "days" },
  totalCostPeriod: { vi: "Tổng chi phí {period}", en: "Total cost {period}" },
  estTotal: { vi: "Ước tính {n} ngày", en: "Est. {n}-day total" },
  estFootnote: {
    vi: "Ước tính từ log cục bộ Claude Code CLI, Codex và Grok.",
    en: "Estimated from local Claude Code CLI, Codex, and Grok logs.",
  },
  hourBarsNote: {
    vi: "Cột giờ chỉ gồm Claude — Codex/Grok chỉ có độ phân giải theo ngày.",
    en: "Hour bars are Claude-only — Codex/Grok logs have day resolution.",
  },
  codexToday: { vi: "Codex (hôm nay)", en: "Codex (today)" },
  activity90: { vi: "Hoạt động 90 ngày", en: "90-day activity" },
  activity120: { vi: "Hoạt động 120 ngày", en: "120-day activity" },
  activeDays: { vi: "ngày active", en: "active days" },
  peakDay: { vi: "Ngày cao nhất", en: "Peak day" },
  avgActive: { vi: "TB/ngày active", en: "Avg active day" },
  streakUnit: { vi: "ngày", en: "days" },
  noActivity: { vi: "Không có hoạt động.", en: "No activity." },
  topModels: { vi: "Model dùng nhiều (90 ngày)", en: "Top models (90 days)" },
  topModels120: { vi: "Model dùng nhiều (120 ngày)", en: "Top models (120 days)" },
  moreModels: { vi: "+{n} model khác", en: "+{n} more models" },
  topModel: { vi: "Model dùng nhiều", en: "Top model" },
  latestTokens: { vi: "Token mới nhất", en: "Latest tokens" },
  lastUpdated: { vi: "Cập nhật {time}", en: "Updated {time}" },
  noLogs: {
    vi: "Không tìm thấy log Claude (~/.claude), Codex (~/.codex) hoặc Grok (~/.grok).",
    en: "No Claude (~/.claude), Codex (~/.codex), or Grok (~/.grok) logs found.",
  },
  scanningSources: { vi: "Đang quét {names}…", en: "Scanning {names}…" },
  grokFootnote: {
    vi: "Ước tính từ log Grok Build cục bộ (~/.grok/sessions).",
    en: "Estimated from local Grok Build logs (~/.grok/sessions).",
  },
  noQuota: { vi: "Không có dữ liệu quota.", en: "No quota data." },
  creditsHistoryCount: { vi: "{n} giao dịch credit", en: "{n} credit events" },
  usedPct: { vi: "Đã dùng {n}%", en: "{n}% used" },
  updatedAt: { vi: "cập nhật", en: "updated" },
  resetInDays: { vi: "reset sau {n} ngày", en: "resets in {n}d" },
  resetInHours: { vi: "reset sau {n} giờ", en: "resets in {n}h" },
  resetInMins: { vi: "reset sau {n} phút", en: "resets in {n}m" },
  claudeFootnote: { vi: "Ước tính từ log Claude Code cục bộ.", en: "Estimated from local Claude Code logs." },
  codexFootnote: { vi: "Ước tính từ log Codex cục bộ.", en: "Estimated from local Codex logs." },
  loadError: { vi: "Lỗi khi tải", en: "Load error" },
  popoverReady: { vi: "Sẵn sàng", en: "Ready" },
  popoverUpdating: { vi: "Đang cập nhật…", en: "Updating…" },
  popoverRefresh: { vi: "Làm mới", en: "Refresh" },
  footerSettings: { vi: "Cài đặt…", en: "Settings…" },
  footerAbout: { vi: "Giới thiệu BirdNion", en: "About BirdNion" },
  footerQuit: { vi: "Thoát BirdNion", en: "Quit BirdNion" },
  tabAll: { vi: "All", en: "All" },

  // Claude Code quick-apply — macOS AppLocalizer `claudeCode.*` parity
  ccTitle: { vi: "Backend Claude Code", en: "Claude Code backend" },
  ccStateOn: { vi: "Đang bật", en: "On" },
  ccStateOff: { vi: "Sẵn sàng", en: "Ready" },
  ccStateStale: { vi: "Cần cập nhật", en: "Needs update" },
  ccStateSetup: { vi: "Cần setup", en: "Needs setup" },
  ccPowerOn: { vi: "Đang bật · {name}", en: "On · {name}" },
  ccPowerOff: { vi: "Đang tắt — bấm để bật", en: "Off — tap to enable" },
  ccPowerStale: { vi: "Giá trị đã đổi — bấm để cập nhật", en: "Values changed — tap to update" },
  ccNeedSetup: { vi: "Cần cấu hình model — bấm để mở cài đặt", en: "Configure models — tap to open settings" },
  ccGlobalTarget: { vi: "Toàn cục · ~/.claude/settings.json", en: "Global · ~/.claude/settings.json" },
  ccProjectTarget: { vi: "Theo project · {path}", en: "Project · {path}" },
  ccProjectNone: { vi: "Theo project · chưa chọn thư mục", en: "Project · no folder chosen" },
  ccApplied: { vi: "Đã áp dụng", en: "Applied" },
  ccDeactivated: { vi: "Đã tắt", en: "Deactivated" },
  ccError: { vi: "Lỗi", en: "Error" },
  ccScope: { vi: "Phạm vi", en: "Scope" },
  ccScopeGlobal: { vi: "Toàn cục", en: "Global" },
  ccScopeProject: { vi: "Project", en: "Project" },
  ccProjectPath: { vi: "Đường dẫn project", en: "Project path" },
  ccModelHaiku: { vi: "Model Haiku", en: "Haiku model" },
  ccModelSonnet: { vi: "Model Sonnet", en: "Sonnet model" },
  ccModelOpus: { vi: "Model Opus", en: "Opus model" },
  ccDisable1M: { vi: "Tắt ngữ cảnh 1M token", en: "Disable 1M-token context" },

  // Settings — provider list, polling, about
  settingsProvidersLabel: {
    vi: "Providers (lưu vào ~/.config/birdnion/settings.json)",
    en: "Providers (saved to ~/.config/birdnion/settings.json)",
  },
  settingsMoveUp: { vi: "Chuyển lên", en: "Move up" },
  settingsMoveDown: { vi: "Chuyển xuống", en: "Move down" },
  settingsRefreshInterval: { vi: "Chu kỳ riêng (giây)", en: "Refresh interval (sec)" },
  settingsShowInTray: { vi: "Hiện trên tray", en: "Show in tray" },
  settingsRegion: { vi: "Khu vực", en: "Region" },
  settingsGlobalPolling: { vi: "Chu kỳ làm mới chung", en: "Global refresh interval" },
  settingsGlobalPollingSubtitle: {
    vi: "Áp dụng cho mọi provider không có chu kỳ riêng (30–1800 giây). 0 = thủ công.",
    en: "Applies to providers without their own interval (30-1800 sec). 0 = manual.",
  },
  settingsGlobalPollingManualHint: {
    vi: "Chế độ thủ công — chỉ làm mới khi bạn bấm \"Làm mới ngay\".",
    en: "Manual mode — only refreshes when you tap \"Refresh now\".",
  },
  settingsSeconds: { vi: "giây", en: "sec" },
  settingsRefreshNow: { vi: "Làm mới ngay", en: "Refresh now" },
  settingsRefreshOnOpen: {
    vi: "Làm mới khi mở",
    en: "Refresh on open",
  },
  settingsProviderStorage: {
    vi: "Hiện dung lượng lưu trữ của provider",
    en: "Show provider storage footprint",
  },
  providerStorageLabel: { vi: "Dung lượng dữ liệu", en: "Data storage" },
  settingsCheckUpdate: { vi: "Kiểm tra cập nhật", en: "Check for updates" },
  settingsCheckingUpdate: { vi: "Đang kiểm tra…", en: "Checking…" },
  settingsUpToDate: { vi: "Đã là bản mới nhất", en: "Up to date" },
  settingsUpdateAvailable: { vi: "Có bản cập nhật", en: "Update available" },
  settingsViewRelease: { vi: "Xem bản phát hành", en: "View release" },
  settingsAbout: { vi: "Giới thiệu", en: "About" },
  settingsVersion: { vi: "Phiên bản", en: "Version" },
  settingsRepo: { vi: "Kho mã nguồn trên GitHub", en: "GitHub repository" },
  settingsApiKey: { vi: "API key", en: "API key" },
  settingsManualCookie: { vi: "Cookie thủ công (tuỳ chọn)", en: "Manual cookie (optional)" },
  settingsAdminApiKey: {
    vi: "Admin API key (tuỳ chọn, dashboard tổ chức)",
    en: "Admin API key (optional, org dashboard)",
  },
  settingsLaunchAtLogin: { vi: "Khởi động cùng máy", en: "Launch at login" },
  settingsLaunchAtLoginSub: {
    vi: "Tự mở BirdNion khi đăng nhập.",
    en: "Open BirdNion automatically at login.",
  },
  settingsSave: { vi: "Lưu cài đặt", en: "Save settings" },
  settingsSaved: { vi: "Đã lưu ✓", en: "Saved ✓" },

  // Settings window tabs (macOS SettingsTab titles)
  settingsTabGeneral: { vi: "Cài chung", en: "General" },
  settingsTabProviders: { vi: "Nhà cung cấp", en: "Providers" },
  settingsTabClaudeCode: { vi: "AI Coding", en: "AI Coding" },
  settingsTabDisplay: { vi: "Hiển thị", en: "Display" },
  settingsTabAdvanced: { vi: "Nâng cao", en: "Advanced" },
  settingsTabAbout: { vi: "Giới thiệu", en: "About" },

  settingsGeneralSubtitle: {
    vi: "Ngôn ngữ, giao diện, tray và tần suất làm mới.",
    en: "Language, appearance, tray, and refresh cadence.",
  },
  settingsAdvancedSubtitle: {
    vi: "Quyền riêng tư và tuỳ chọn nhà phát triển.",
    en: "Privacy and developer options.",
  },
  settingsSidebarSearch: { vi: "Tìm kiếm", en: "Search" },

  settingsAppearance: { vi: "Giao diện", en: "Appearance" },
  settingsAppearanceSub: {
    vi: "Sáng, tối hoặc theo hệ thống",
    en: "Light, dark, or follow the system",
  },
  settingsAppearanceLight: { vi: "Sáng", en: "Light" },
  settingsAppearanceDark: { vi: "Tối", en: "Dark" },
  settingsAppearanceAuto: { vi: "Tự động", en: "Auto" },

  settingsSectionSystem: { vi: "HỆ THỐNG", en: "SYSTEM" },
  settingsSectionUsage: { vi: "SỬ DỤNG", en: "USAGE" },
  settingsSectionAutomation: { vi: "TỰ ĐỘNG", en: "AUTOMATION" },
  settingsSectionShortcut: { vi: "PHÍM TẮT", en: "SHORTCUT" },
  settingsSectionMenuBar: { vi: "TRAY / MENU BAR", en: "TRAY / MENU BAR" },
  settingsSectionPrivacy: { vi: "QUYỀN RIÊNG TƯ", en: "PRIVACY" },
  settingsSectionDeveloper: { vi: "NHÀ PHÁT TRIỂN", en: "DEVELOPER" },
  settingsSectionInfo: { vi: "THÔNG TIN", en: "INFO" },
  settingsSectionQuota: { vi: "QUOTA", en: "QUOTA" },
  settingsSectionCost: { vi: "CHI PHÍ", en: "COST" },

  settingsLanguage: { vi: "Ngôn ngữ", en: "Language" },
  settingsLanguageSub: {
    vi: "Đổi ngay trong UI; lần mở sau cũng giữ ngôn ngữ này.",
    en: "Changes the UI immediately and persists across restarts.",
  },
  settingsRefreshFrequency: { vi: "Tần suất làm mới", en: "Refresh frequency" },
  settingsRefreshFrequencySub: {
    vi: "Mỗi bao lâu app gọi lại nhà cung cấp.",
    en: "How often the app re-fetches providers.",
  },
  settingsRefreshOnOpenSub: {
    vi: "Làm mới tất cả nhà cung cấp mỗi lần mở popover.",
    en: "Refresh all providers every time the popover opens.",
  },
  settingsStatusChecks: { vi: "Kiểm tra trạng thái", en: "Status checks" },
  settingsStatusChecksSub: {
    vi: "Poll trạng thái của các nhà cung cấp.",
    en: "Poll status for enabled providers.",
  },
  settingsSessionNotify: { vi: "Thông báo phiên 5 giờ", en: "Session notifications" },
  settingsSessionNotifySub: {
    vi: "Báo khi phiên quota chạm 0% và khi khôi phục.",
    en: "Notify when a session quota hits 0% and on recovery.",
  },
  settingsQuotaWarn: { vi: "Thông báo cảnh báo quota", en: "Quota warning notifications" },
  settingsQuotaWarnSub: {
    vi: "Cảnh báo khi còn dưới ngưỡng đã đặt.",
    en: "Warn when remaining quota falls below the threshold.",
  },
  settingsWarnThreshold: { vi: "Ngưỡng cảnh báo", en: "Warning threshold" },
  settingsWarnThresholdSub: {
    vi: "Phần trăm còn lại để báo mức 1.",
    en: "Remaining percent for level-1 warning.",
  },
  settingsCriticalThreshold: { vi: "Ngưỡng nghiêm trọng", en: "Critical threshold" },
  settingsCriticalThresholdSub: {
    vi: "Phần trăm còn lại để báo mức 2.",
    en: "Remaining percent for level-2 critical warning.",
  },
  settingsHotkey: { vi: "Mở popover", en: "Open popover" },
  settingsHotkeySub: {
    vi: "Phím tắt trong cửa sổ chính (Linux không có global hotkey ổn định).",
    en: "In-window shortcut (Linux has no stable global hotkey).",
  },
  settingsShowTrayPercent: {
    vi: "Hiển thị % trên menu bar / tray",
    en: "Show percent in menu bar / tray",
  },
  settingsShowTrayPercentSub: {
    vi: "Hiện % quota cạnh icon tray; lần lượt xoay qua từng provider đang hoạt động.",
    en: "Shows remaining % next to the tray icon; rotates through active providers.",
  },
  settingsDisplayFooter: {
    vi: "Giống menu bar macOS: bật thì hiện chữ % cạnh icon; tắt thì chỉ còn logo. Hover vẫn xem tooltip tổng.",
    en: "macOS menu-bar parity: on = % text next to the icon; off = logo only. Hover still shows the full tooltip.",
  },
  settingsHidePersonal: { vi: "Ẩn thông tin cá nhân", en: "Hide personal info" },
  settingsHidePersonalSub: {
    vi: "Che email / nhãn tài khoản trên UI provider.",
    en: "Mask email / account labels on provider cards.",
  },
  settingsProviderStorageSub: {
    vi: "Hiện dung lượng on-disk của provider trên thẻ chi tiết.",
    en: "Show on-disk footprint on provider detail cards.",
  },
  settingsDeveloperFooter: {
    vi: "Tuỳ chọn nâng cao cho debug và footprint.",
    en: "Advanced options for debug and storage footprints.",
  },

  aboutTagline: {
    vi: "Theo dõi quota & cost AI trên tray.",
    en: "Track AI quota & cost from the tray.",
  },
  settingsSignInGithub: { vi: "Đăng nhập GitHub", en: "Sign in with GitHub" },
  settingsClaudeSource: { vi: "Nguồn dữ liệu", en: "Data source" },
  claudeSourceAuto: { vi: "Tự động", en: "Auto" },
  claudeSourceOauth: { vi: "OAuth (Claude Code)", en: "OAuth (Claude Code)" },
  claudeSourceWeb: { vi: "Cookie trình duyệt (claude.ai)", en: "Browser cookie (claude.ai)" },
  claudeSourceCli: { vi: "CLI (không hỗ trợ trên Linux)", en: "CLI (not supported on Linux)" },
  claudeSourceApi: { vi: "Admin API", en: "Admin API" },

  // Codex account management
  codexAccountsLabel: { vi: "Tài khoản Codex", en: "Codex accounts" },
  codexAccountSystem: { vi: "Hệ thống (~/.codex)", en: "System (~/.codex)" },
  codexAccountActive: { vi: "Đang dùng", en: "Active" },
  codexAccountSwitch: { vi: "Dùng", en: "Use" },
  codexAccountRemove: { vi: "Xoá", en: "Remove" },
  codexAccountSaveCurrent: { vi: "Lưu account hiện tại", en: "Save current account" },
  codexAccountLoadError: { vi: "Không tải được danh sách account", en: "Failed to load accounts" },
  // Popover Codex accounts card (macOS popover.accounts / provider.* parity)
  popoverAccounts: { vi: "Tài khoản", en: "Accounts" },
  codexAccountSystemManaged: { vi: "Hệ thống · ~/.codex", en: "System · ~/.codex" },
  codexAccountAppManaged: { vi: "Quản lý bởi app", en: "Managed by app" },
  codexAccountQuotaMissing: {
    vi: "Chưa có snapshot quota cho account này",
    en: "No quota snapshot for this account yet",
  },
  codexAccountRemoveTitle: { vi: "Xoá {name}?", en: "Remove {name}?" },
  codexAccountRemoveMessage: {
    vi: "Tài khoản managed sẽ bị xoá khỏi BirdNion.",
    en: "The managed account will be removed from BirdNion.",
  },

  // Provider error classification (mirrors macOS ProviderErrorClassifier)
  "providerError.cookieExpiredOrMissing.title": { vi: "Cookie hết hạn", en: "Cookie expired" },
  "providerError.cookieExpiredOrMissing.hint": {
    vi: "Cookie hết hạn — đăng nhập lại trình duyệt",
    en: "Cookie expired — sign in again in your browser",
  },
  "providerError.tokenInvalidOrMissing.title": { vi: "Token không hợp lệ", en: "Invalid token" },
  "providerError.tokenInvalidOrMissing.hint": {
    vi: "Token sai — dán lại API key",
    en: "Invalid token — re-paste your API key",
  },
  "providerError.apiSchemaChanged.title": { vi: "Phản hồi lạ", en: "Unexpected response" },
  "providerError.apiSchemaChanged.hint": {
    vi: "Phản hồi lạ — có thể cần cập nhật app",
    en: "Unexpected response — the app may need an update",
  },
  "providerError.networkUnreachableOrTimeout.title": { vi: "Lỗi mạng", en: "Network error" },
  "providerError.networkUnreachableOrTimeout.hint": {
    vi: "Mất mạng hoặc quá thời gian — kiểm tra kết nối",
    en: "Network down or timed out — check your connection",
  },
  "providerError.rateLimited.title": { vi: "Bị giới hạn tần suất", en: "Rate limited" },
  "providerError.rateLimited.hint": {
    vi: "Bị giới hạn tần suất — đợi rồi thử lại",
    en: "Rate limited — wait and retry",
  },
  "providerError.unknown.title": { vi: "Lỗi không xác định", en: "Unknown error" },
  "providerError.unknown.hint": { vi: "Lỗi không xác định — xem chi tiết", en: "Unknown error — see details" },

  // Self-test (Settings detail; not on popover card — macOS uses menu-bar toggle there)
  "provider.selfTest": { vi: "Kiểm tra", en: "Self-test" },
  "provider.selfTest.running": { vi: "Đang kiểm tra…", en: "Testing…" },
  "provider.selfTest.pass": { vi: "Đạt", en: "Passed" },
  "provider.selfTest.fail": { vi: "Lỗi", en: "Failed" },
  "provider.selfTest.disabled": { vi: "Bật provider để kiểm tra", en: "Enable the provider to test" },
  "provider.loading": { vi: "Đang tải…", en: "Loading…" },

  // Popover menu-bar visibility (macOS MenuBarVisibilityToggle)
  "popover.menuBarVisibility": { vi: "Hiển thị trên menu bar", en: "Menu bar visibility" },
  "popover.visibilityOn": {
    vi: "Provider này đang hiển thị trên menu bar. Tắt để ẩn.",
    en: "This provider is visible in the menu bar. Turn off to hide it.",
  },
  "popover.visibilityOff": {
    vi: "Provider này đang ẩn khỏi menu bar. Bật để hiển thị.",
    en: "This provider is hidden from the menu bar. Turn on to show it.",
  },
  "popover.lowestQuota": { vi: "Quota thấp nhất", en: "Lowest quota" },
  "time.justUpdated": { vi: "vừa cập nhật", en: "just updated" },
  "time.secondsAgo": { vi: "{n} giây trước", en: "{n}s ago" },
  "time.minutesAgo": { vi: "{n} phút trước", en: "{n}m ago" },
  "time.hoursAgo": { vi: "{n} giờ trước", en: "{n}h ago" },

  // Settings detail grid (macOS ProvidersPane detailInfoGrid)
  "provider.status": { vi: "Trạng thái", en: "Status" },
  "provider.source": { vi: "Nguồn", en: "Source" },
  "provider.plan": { vi: "Gói", en: "Plan" },
  "provider.planName": { vi: "Tên gói", en: "Plan name" },
  "provider.account": { vi: "Tài khoản", en: "Account" },
  "provider.version": { vi: "Phiên bản", en: "Version" },
  "provider.kiroContext": { vi: "Context window", en: "Context window" },
  "provider.serviceStatus": { vi: "Tình trạng", en: "Service status" },
  "provider.error": { vi: "Lỗi", en: "Error" },
  "provider.updated": { vi: "Cập nhật", en: "Updated" },
  "provider.storage": { vi: "Dung lượng", en: "Storage" },
  "provider.storageNone": { vi: "Không có dữ liệu cục bộ", en: "No local data" },
  "provider.disabled": { vi: "Đã tắt", en: "Disabled" },
  "provider.notLoaded": { vi: "Chưa tải", en: "Not loaded" },
  "provider.choose": { vi: "Chọn một nhà cung cấp", en: "Choose a provider" },
  "provider.reload": { vi: "Đọc lại settings.json và làm mới quota", en: "Reload settings.json and refresh quota" },
  "provider.remainingPct": { vi: "Còn {n}%", en: "{n}% left" },
  "provider.noDataShort": { vi: "Chưa có dữ liệu", en: "No data" },
  "provider.allOperational": { vi: "Tất cả hệ thống hoạt động bình thường", en: "All Systems Operational" },

  // Settings usage section (macOS usageSection)
  "provider.noData": { vi: "Chưa có dữ liệu — bấm làm mới.", en: "No data yet — hit refresh." },
  "provider.disabledNoData": { vi: "Đang tắt — không có dữ liệu.", en: "Disabled — no data." },
  "provider.reserve": { vi: "{n}% dự phòng", en: "{n}% reserve" },
  "provider.resetAfter": { vi: "Reset sau {t}", en: "Resets in {t}" },
  "provider.enoughUntilReset": { vi: "Đủ dùng đến khi reset", en: "On pace until reset" },
  "provider.mayRunOut": { vi: "Có thể hết trước khi reset", en: "May run out before reset" },
  "provider.outOfCredits": { vi: "Hết", en: "Empty" },
  "provider.creditsLeft": { vi: "{n} còn lại", en: "{n} left" },
  "provider.creditsUnlimited": { vi: "∞ Không giới hạn", en: "∞ Unlimited" },
  "provider.today": { vi: "Hôm nay", en: "Today" },
  "provider.last30": { vi: "30 ngày", en: "30 days" },
  "provider.justUpdated": { vi: "vừa cập nhật", en: "just updated" },
  "provider.secondsAgo": { vi: "{n} giây trước", en: "{n}s ago" },
  "provider.minutesAgo": { vi: "{n} phút trước", en: "{n}m ago" },
  "provider.hoursAgo": { vi: "{n} giờ trước", en: "{n}h ago" },

  // Settings setup section
  settingsSectionSetup: { vi: "THIẾT LẬP", en: "SETUP" },
  settingsSectionLinks: { vi: "LIÊN KẾT", en: "LINKS" },
  settingsAccountLabel: { vi: "Nhãn tài khoản", en: "Account label" },
  settingsAccountLabelPlaceholder: {
    vi: "Tùy chọn — để trống để tự suy ra",
    en: "Optional — leave empty to infer",
  },
  settingsRefreshEvery: { vi: "Làm mới mỗi", en: "Refresh every" },
  settingsRefreshDefault: { vi: "Mặc định chung", en: "Global default" },
  settingsSearchProviders: { vi: "Tìm nhà cung cấp", en: "Search providers" },
  settingsCookieSource: { vi: "Nguồn cookie", en: "Cookie source" },
  "cookieSource.auto": { vi: "Tự động", en: "Auto" },
  "cookieSource.manual": { vi: "Thủ công", en: "Manual" },
  "cookieSource.off": { vi: "Tắt", en: "Off" },
  settingsBedrockAuth: { vi: "Xác thực", en: "Authentication" },
  "bedrockAuth.keys": { vi: "Khóa truy cập", en: "Access keys" },
  "bedrockAuth.profile": { vi: "AWS profile", en: "AWS profile" },
  settingsBedrockRegion: { vi: "Region (us-east-1)", en: "Region (us-east-1)" },
  settingsBedrockBudget: { vi: "Ngân sách tháng (USD)", en: "Monthly budget (USD)" },
  settingsGheHost: { vi: "GitHub Enterprise Host (trống = github.com)", en: "GitHub Enterprise Host (empty = github.com)" },
  "hint.grok": { vi: "Đọc ~/.grok/auth.json (grok login)", en: "Reads ~/.grok/auth.json (grok login)" },
  "hint.gemini": {
    vi: "Đăng nhập bằng Gemini CLI (~/.gemini/oauth_creds.json)",
    en: "Sign in with Gemini CLI (~/.gemini/oauth_creds.json)",
  },
  "hint.kiro": { vi: "Đăng nhập bằng `kiro-cli login`", en: "Sign in via `kiro-cli login`" },
  "hint.codex": {
    vi: "Đăng nhập bằng lệnh `codex` trong Terminal.",
    en: "Sign in by running `codex` in a terminal.",
  },

  // Quota-warning card (macOS QuotaWarningCard)
  quotaWarnTitle: { vi: "CẢNH BÁO QUOTA", en: "QUOTA WARNINGS" },
  quotaWarnCustomize: { vi: "Tùy chỉnh ngưỡng {w}", en: "Customize {w} thresholds" },
  quotaWarnSession: { vi: "Phiên (5 giờ)", en: "Session (5h)" },
  quotaWarnWeekly: { vi: "Tuần", en: "Weekly" },
  quotaWarnWarn: { vi: "Cảnh báo", en: "Warning" },
  quotaWarnCritical: { vi: "Nguy hiểm", en: "Critical" },
  quotaWarnInherit: { vi: "Kế thừa: {a}%, {b}%", en: "Inherited: {a}%, {b}%" },
  quotaWarnFooter: {
    vi: "Dùng ngưỡng chung trừ khi bật tùy chỉnh riêng cho từng cửa sổ.",
    en: "Uses the global thresholds unless customized per window.",
  },

  // FreeModel multi-account
  fmAccountsLabel: { vi: "Tài khoản FreeModel", en: "FreeModel accounts" },
  fmAccountBrowser: { vi: "Trình duyệt (tự động)", en: "Browser (auto)" },
  fmAccountAdd: { vi: "Thêm tài khoản", en: "Add account" },
  fmAccountCookiePlaceholder: {
    vi: "Dán cookie (bm_session=… hoặc cả chuỗi Cookie)",
    en: "Paste cookie (bm_session=… or the full Cookie string)",
  },
  fmAccountLabelPlaceholder: { vi: "Nhãn (tuỳ chọn)", en: "Label (optional)" },
  fmAccountAddHint: {
    vi: "Mỗi tài khoản là một cookie bm_session dán từ trình duyệt đã đăng nhập freemodel.dev (DevTools → Application → Cookies).",
    en: "Each account is one bm_session cookie pasted from a browser signed in to freemodel.dev (DevTools → Application → Cookies).",
  },

  // ElevenLabs multi-key
  elKeysLabel: { vi: "API keys ElevenLabs", en: "ElevenLabs API keys" },
  elKeysEmpty: {
    vi: "Chưa có API key — dán key bên dưới để thêm.",
    en: "No API keys yet — paste a key below to add one.",
  },
  elKeyPlaceholder: { vi: "Dán API key ElevenLabs…", en: "Paste ElevenLabs API key…" },
  elKeyLabelPlaceholder: { vi: "Nhãn (tuỳ chọn)", en: "Label (optional)" },
  elKeyAdd: { vi: "Thêm key", en: "Add key" },
  elKeySwitch: { vi: "Dùng key này", en: "Use this key" },
  elKeyActive: { vi: "Đang dùng", en: "Active" },
  elKeysAddHint: {
    vi: "Lưu nhiều API key và chuyển nhanh trên popover. Key được lưu riêng (elevenlabs-keys.json).",
    en: "Store multiple API keys and switch from the popover. Keys live in a separate file (elevenlabs-keys.json).",
  },

  // Claude Code pane (macOS ClaudeCodePane)
  ccxSelectProvider: {
    vi: "Dùng provider bất kỳ làm backend cho Claude Code và Codex CLI",
    en: "Back Claude Code and Codex CLI with any provider",
  },
  ccxCustomSection: { vi: "TUỲ CHỈNH", en: "CUSTOM" },
  ccxAddConfig: { vi: "Thêm config", en: "Add config" },
  ccxNewConfig: { vi: "Config mới", en: "New config" },
  ccxBackendTitle: { vi: "Backend Claude Code", en: "Claude Code backend" },
  "ccxState.on": { vi: "Đang bật", en: "On" },
  "ccxState.off": { vi: "Sẵn sàng", en: "Ready" },
  "ccxState.stale": { vi: "Cần cập nhật", en: "Needs update" },
  "ccxState.needsSetup": { vi: "Cần setup", en: "Needs setup" },
  ccxSubOn: { vi: "Đang bật · {name}", en: "On · {name}" },
  ccxSubOff: { vi: "Đang tắt — bấm để bật", en: "Off — tap to enable" },
  ccxSubStale: { vi: "Giá trị đã đổi — bấm để cập nhật", en: "Values changed — tap to update" },
  ccxSubNeedDir: { vi: "Chưa chọn thư mục project", en: "No project folder chosen" },
  ccxSubNeedModels: { vi: "Chọn đủ 3 model để bật", en: "Pick all 3 models to enable" },
  ccxSubNeedBase: { vi: "Nhập Base URL + Token để bật", en: "Enter Base URL + Token to enable" },
  ccxTargetGlobal: { vi: "Toàn cục · ~/.claude/settings.json", en: "Global · ~/.claude/settings.json" },
  ccxScope: { vi: "Phạm vi", en: "Scope" },
  ccxScopeGlobal: { vi: "Toàn cục", en: "Global" },
  ccxScopeProject: { vi: "Theo project", en: "Per project" },
  ccxGlobalNote: { vi: "→ ~/.claude/settings.json", en: "→ ~/.claude/settings.json" },
  ccxChoose: { vi: "Chọn…", en: "Choose…" },
  ccxProjectNote: {
    vi: "Ghi vào .claude/settings.json của project (nhớ gitignore nếu repo chia sẻ để tránh lộ token).",
    en: "Writes to the project's .claude/settings.json (gitignore it in shared repos to avoid leaking tokens).",
  },
  ccxRemoveEnvTitle: { vi: "Gỡ env settings", en: "Remove env settings" },
  ccxRemoveEnv: { vi: "Gỡ env", en: "Remove env" },
  ccxRemoveEnvSub: {
    vi: "Xoá env/apiKeyHelper trong {path}; không xoá token/provider của BirdNion.",
    en: "Removes env/apiKeyHelper in {path}; BirdNion tokens/providers stay untouched.",
  },
  ccxRemoveEnvConfirm: {
    vi: "BirdNion sẽ xoá env và apiKeyHelper trong {path}. Các setting khác vẫn giữ nguyên.",
    en: "BirdNion will remove env and apiKeyHelper in {path}. Other settings stay intact.",
  },
  ccxRemoveEnvNone: { vi: "Không có env để gỡ.", en: "No env to remove." },
  ccxRemoveEnvDone: { vi: "Đã gỡ env trong {path}", en: "Removed env in {path}" },
  ccxDeactivated: { vi: "Đã tắt Claude Code cho provider này", en: "Claude Code disabled for this provider" },
  ccxUpdated: { vi: "Đã cập nhật giá trị vào settings.json", en: "Values updated in settings.json" },
  ccxSaved: { vi: "Đã lưu vào {path}", en: "Saved to {path}" },
  ccxToken: { vi: "Token", en: "Token" },
  ccxTokenOf: { vi: "Dùng key của {name}", en: "Uses {name}'s key" },
  ccxBaseUrl: { vi: "Base URL", en: "Base URL" },
  ccxModelSection: { vi: "MODEL", en: "MODELS" },
  ccxModelsLoading: { vi: "Đang tải model…", en: "Loading models…" },
  ccxModelsLoaded: { vi: "Đã tải {n} model", en: "{n} models loaded" },
  ccxLoadModels: { vi: "Tải model", en: "Load models" },
  ccxReloadModels: { vi: "Tải lại", en: "Reload" },
  ccxModelPlaceholder: { vi: "— chưa tải —", en: "— not loaded —" },
  ccxModelOptional: { vi: "tuỳ chọn", en: "optional" },
  ccxDisable1M: { vi: "Tắt 1M context", en: "Disable 1M context" },
  ccxName: { vi: "Tên", en: "Name" },
  ccxNamePlaceholder: { vi: "Tên hiển thị", en: "Display name" },
  ccxTokenKind: { vi: "Kiểu key", en: "Key kind" },
  ccxShowToken: { vi: "Hiện token", en: "Show token" },
  ccxHideToken: { vi: "Ẩn token", en: "Hide token" },
  ccxAdvanced: { vi: "NÂNG CAO", en: "ADVANCED" },
  ccxHelperPlaceholder: { vi: "vd: echo 'sk-...' (tuỳ chọn)", en: "e.g. echo 'sk-...' (optional)" },
  ccxExtraEnv: { vi: "Env tuỳ chỉnh", en: "Custom env" },
  ccxAddEnv: { vi: "Thêm env", en: "Add env" },
  ccxPasteJson: { vi: "Dán JSON", en: "Paste JSON" },
  ccxPasteTitle: { vi: "Dán JSON cấu hình Claude Code", en: "Paste Claude Code config JSON" },
  ccxPasteHint: {
    vi: "Dán cả khối settings.json (có \"env\") hoặc chỉ khối env. App sẽ tự tách field.",
    en: "Paste the whole settings.json block (with \"env\") or just the env block. Fields are extracted automatically.",
  },
  ccxImport: { vi: "Nhập", en: "Import" },
  ccxCancel: { vi: "Huỷ", en: "Cancel" },
  ccxImported: { vi: "Đã nhập từ JSON", en: "Imported from JSON" },
  ccxJsonInvalid: { vi: "JSON không hợp lệ", en: "Invalid JSON" },
  ccxJsonNoEnv: {
    vi: "Không tìm thấy khối env / các biến ANTHROPIC_*",
    en: "No env block / ANTHROPIC_* variables found",
  },
  ccxDeleteConfig: { vi: "Xoá config", en: "Delete config" },
  // Empty state — macOS `claudeCode.empty.remake*` (3-step onboarding)
  ccxEmptyTitle: {
    vi: "Kết nối provider với Claude Code & Codex CLI",
    en: "Connect a provider to Claude Code & Codex CLI",
  },
  ccxEmptyBody: {
    vi: "Tạo config từ API của provider bất kỳ. BirdNion tự chuyển đổi giao thức khi cần — một config dùng được cho cả hai agent.",
    en: "Create a config from any provider's API. BirdNion converts protocols when needed — one config serves both agents.",
  },
  ccxOpenProviders: { vi: "Mở tab Nhà cung cấp", en: "Open Providers tab" },
  ccxEmptyStep1: { vi: "Nhập API nguồn", en: "Enter the upstream API" },
  ccxEmptyStep2: { vi: "Chọn agent & model", en: "Pick agent & model" },
  ccxEmptyStep3: { vi: "Bấm nút nguồn", en: "Hit the power button" },
  // Step breadcrumb / card headers (macOS stepTitle keys)
  "ccx.step.upstream": { vi: "API nguồn", en: "Upstream API" },
  "ccx.step.proxy": { vi: "Proxy local", en: "Local proxy" },
  "claudeCode.model": { vi: "Model", en: "Model" },
  // Dual-status sidebar labels (CC: … · CX: …)
  "ccxState.proxyStopped": { vi: "Proxy đã dừng", en: "Proxy stopped" },
  "ccxSide.cc": { vi: "CC", en: "CC" },
  "ccxSide.cx": { vi: "CX", en: "CX" },
  // AI Coding agent picker + Codex CLI (macOS AppLocalizer parity)
  "aiCoding.step.agent": { vi: "AI Coding Agent", en: "AI Coding Agent" },
  "aiCoding.target": { vi: "Agent", en: "Agent" },
  "aiCoding.agent.claudeCode": { vi: "Claude Code", en: "Claude Code" },
  "aiCoding.agent.codex": { vi: "Codex CLI", en: "Codex CLI" },
  "aiCoding.claudeCode.settings": { vi: "Kích hoạt Claude Code", en: "Activate Claude Code" },
  "codexConfig.newName": { vi: "Config mới", en: "New config" },
  "codexConfig.connection": { vi: "Kết nối", en: "Connection" },
  "codexConfig.connection.direct": { vi: "API nguồn gốc", en: "Original upstream" },
  "codexConfig.connection.proxy": { vi: "Proxy local", en: "Local proxy" },
  "codexConfig.model": { vi: "Model", en: "Model" },
  "codexConfig.target": { vi: "Kích hoạt Codex CLI", en: "Activate Codex CLI" },
  "codexConfig.target.path": { vi: "~/.codex/config.toml", en: "~/.codex/config.toml" },
  "codexConfig.apply": { vi: "Áp dụng cho Codex", en: "Apply to Codex" },
  "codexConfig.update": { vi: "Cập nhật Codex", en: "Update Codex" },
  "codexConfig.deactivate": { vi: "Tắt config", en: "Disable config" },
  "codexConfig.delete": { vi: "Xoá config", en: "Delete config" },
  "codexConfig.deleteConfirm": {
    vi: "Xoá config Codex này? Config Claude Code liên kết cũng sẽ bị xoá nếu đây là custom profile.",
    en: "Delete this Codex config? The linked Claude Code config will also be removed for custom profiles.",
  },
  "codexConfig.state.ready": { vi: "Sẵn sàng", en: "Ready" },
  "codexConfig.state.active": { vi: "Đang dùng", en: "Active" },
  "codexConfig.state.stale": { vi: "Cần cập nhật", en: "Needs update" },
  "codexConfig.state.setup": { vi: "Cần setup", en: "Setup" },
  "codexConfig.applied": { vi: "Đã áp dụng provider cho Codex CLI.", en: "Provider applied to Codex CLI." },
  "codexConfig.updated": { vi: "Đã cập nhật provider cho Codex CLI.", en: "Provider updated for Codex CLI." },
  "codexConfig.runWith": {
    vi: "Chạy: `{cmd}` (mặc định toàn cục đã trỏ vào config này; flag chỉ cần khi muốn ghim riêng cho một repo).",
    en: "Run: `{cmd}` (the global default already points at this config; the flag is only needed to pin a specific repo).",
  },
  "codexConfig.deactivated": {
    vi: "Đã trả Codex CLI về config trước đó.",
    en: "Codex CLI restored to its previous config.",
  },
  "codexConfig.error.incomplete": {
    vi: "Nhập Base URL, API key và model trước.",
    en: "Enter the Base URL, API key, and model first.",
  },
  "codexConfig.proxy.running": {
    vi: "Codex CLI có thể dùng endpoint local này.",
    en: "Codex CLI can use this local endpoint.",
  },
  "codexConfig.proxy.stopped": {
    vi: "Khởi động proxy trước khi áp dụng cho Codex CLI.",
    en: "Start the proxy before applying it to Codex CLI.",
  },
  "codexConfig.projectUse.title": { vi: "Dùng theo project", en: "Per-project use" },
  "codexConfig.projectUse.copy": { vi: "Sao chép lệnh", en: "Copy command" },
  "codexConfig.projectUse.hint": {
    vi: "Codex không cho khai provider trong config của project. Chạy lệnh này trong repo muốn dùng config; file ~/.codex/*.config.toml tự cập nhật mỗi lần Áp dụng.",
    en: "Codex ignores provider keys in project-local config. Run this command inside the repo that should use this config; the ~/.codex/*.config.toml overlay refreshes on every Apply.",
  },
  "codexConfig.proxy.stopConfirmTitle": { vi: "Dừng proxy local?", en: "Stop local proxy?" },
  "codexConfig.proxy.stopConfirmMessage": {
    vi: "Codex CLI và Claude Code dùng proxy này sẽ không hoạt động cho đến khi bật lại.",
    en: "Codex CLI and Claude Code profiles using this proxy cannot work until you enable it again.",
  },
  ccxCompatibility: { vi: "Chuẩn API", en: "API standard" },
  ccxCompatibilityHint: {
    vi: "Anthropic = /v1/messages · Chat = /v1/chat/completions · Responses = /v1/responses",
    en: "Anthropic = /v1/messages · Chat = /v1/chat/completions · Responses = /v1/responses",
  },
  ccxProtocolAnthropic: { vi: "Anthropic", en: "Anthropic" },
  ccxProtocolOpenAIChat: { vi: "OpenAI Chat", en: "OpenAI Chat" },
  ccxProtocolResponses: { vi: "OpenAI Responses", en: "OpenAI Responses" },
  ccxOpenAIBaseUrl: { vi: "Base URL", en: "Base URL" },
  ccxOpenAIApiKey: { vi: "API key", en: "API key" },
  ccxConnection: { vi: "Kết nối", en: "Connection" },
  ccxConnectionDirect: { vi: "API nguồn gốc", en: "Original upstream" },
  ccxConnectionProxy: { vi: "Proxy local", en: "Local proxy" },
  ccxStepProxy: { vi: "Proxy local", en: "Local proxy" },
  ccxNeedProxyConfig: { vi: "Nhập Base URL + API key để bật", en: "Enter base URL + API key to enable" },
  ccxProxyLocalEndpoint: { vi: "Local endpoint", en: "Local endpoint" },
  ccxProxyStart: { vi: "Khởi động", en: "Start" },
  ccxProxyUpdate: { vi: "Cập nhật", en: "Update" },
  ccxProxyRetry: { vi: "Thử lại", en: "Retry" },
  ccxProxyRefresh: { vi: "Làm mới trạng thái", en: "Refresh status" },
  ccxProxyCopyEndpoint: { vi: "Sao chép endpoint", en: "Copy endpoint" },
  ccxProxyStarted: { vi: "Proxy local đã sẵn sàng.", en: "Local proxy is ready." },
  ccxProxyStop: { vi: "Dừng proxy local", en: "Stop local proxy" },
  ccxProxyStopConfirmTitle: { vi: "Dừng proxy local?", en: "Stop local proxy?" },
  ccxProxyStopConfirmMessage: {
    vi: "Claude Code dùng proxy này sẽ không hoạt động cho đến khi bật lại.",
    en: "Claude Code profiles using this proxy cannot work until you enable it again.",
  },
  ccxProxyStopDone: { vi: "Đã dừng proxy local.", en: "Local proxy stopped." },
  ccxProxyStopNone: { vi: "Không có proxy local đang chạy.", en: "No local proxy is running." },
  ccxProxyTapToStart: {
    vi: "Proxy local chưa chạy — nút nguồn sẽ tự khởi động proxy rồi áp dụng.",
    en: "The local proxy isn't running — the power button will start it and apply.",
  },
  ccxProxyStatusNeedsConfig: { vi: "Cần thông tin API nguồn", en: "Upstream API details needed" },
  ccxProxyStatusChecking: { vi: "Đang kiểm tra proxy local", en: "Checking local proxy" },
  ccxProxyStatusStarting: { vi: "Đang khởi động proxy local", en: "Starting local proxy" },
  ccxProxyStatusRunning: { vi: "Proxy local đang chạy", en: "Local proxy is running" },
  ccxProxyStatusNeedsUpdate: { vi: "Profile cần cập nhật proxy", en: "Profile needs a proxy update" },
  ccxProxyStatusStopped: { vi: "Proxy local đang dừng", en: "Local proxy is stopped" },
  ccxProxyStatusFailed: { vi: "Proxy local cần xử lý", en: "Local proxy needs attention" },
  ccxProxyDetailNeedsConfig: {
    vi: "Nhập Base URL và API key trước khi khởi động.",
    en: "Enter the Base URL and API key before starting.",
  },
  ccxProxyDetailChecking: {
    vi: "Đang kiểm tra endpoint trên máy này.",
    en: "Checking the endpoint on this machine.",
  },
  ccxProxyDetailStarting: {
    vi: "Đang chờ CLIProxyAPI sẵn sàng.",
    en: "Waiting for CLIProxyAPI to become ready.",
  },
  ccxProxyDetailRunning: {
    vi: "Claude Code có thể dùng endpoint local này.",
    en: "Claude Code can use this local endpoint.",
  },
  ccxProxyDetailNeedsUpdate: {
    vi: "Proxy đang chạy nhưng chưa nạp thay đổi của profile này.",
    en: "The proxy is running but has not loaded this profile's changes.",
  },
  ccxProxyDetailStopped: {
    vi: "Khởi động proxy trước khi áp dụng cho Claude Code.",
    en: "Start the proxy before applying it to Claude Code.",
  },
  ccxProxyDetailFailed: {
    vi: "Kiểm tra API nguồn rồi thử lại.",
    en: "Check the upstream API and try again.",
  },
  aboutCheckNow: { vi: "Kiểm tra cập nhật", en: "Check for updates" },
  aboutReleaseNotes: { vi: "Ghi chú phát hành", en: "Release notes" },
  aboutCopyright: {
    vi: "© BirdNion. Theo dõi quota & cost AI trên tray.",
    en: "© BirdNion. Track AI quota & cost from the tray.",
  },
  aboutBrewInstall: { vi: "Cài bằng Homebrew", en: "Install with Homebrew" },
  aboutCopied: { vi: "Đã sao chép", en: "Copied" },
  aboutCopy: { vi: "Sao chép", en: "Copy" },

  // Links section titles (macOS linksSection)
  "link.dashboard": { vi: "Bảng điều khiển", en: "Dashboard" },
  "link.status": { vi: "Trạng thái dịch vụ", en: "Service status" },
  "link.usage": { vi: "Trang sử dụng", en: "Usage page" },
  "link.subscription": { vi: "Gói đăng ký", en: "Subscription" },
  "link.billing": { vi: "Thanh toán", en: "Billing" },
  "link.changelog": { vi: "Changelog", en: "Changelog" },
  "link.apiKeys": { vi: "API keys", en: "API keys" },
};

/** t("estTotal", {n: 30}) — placeholder substitution via {name}. */
export function t(key: string, params?: Record<string, string | number>): string {
  const entry = STRINGS[key];
  let s = entry ? entry[currentLang()] : key;
  if (params) {
    for (const [k, v] of Object.entries(params)) {
      s = s.split(`{${k}}`).join(String(v));
    }
  }
  return s;
}
