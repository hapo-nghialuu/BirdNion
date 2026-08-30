// Minimal vi/en string table for the web UI — mirrors the macOS app's
// hardcoded-dictionary approach (AppLocalizer) rather than gettext.
// Lựa chọn lưu ở localStorage; mặc định "system" = theo locale hệ điều hành,
// đúng như macOS `SettingsStore.Language.system`.

const LANG_KEY = "birdnion.lang";

export type Lang = "vi" | "en";
/** Lựa chọn người dùng: "" = theo hệ thống (macOS Language.system). */
export type LangPreference = Lang | "";

/** Ngôn ngữ hệ thống quy về vi/en; không nhận diện được thì dùng vi. */
function systemLang(): Lang {
  const tags = navigator.languages?.length ? navigator.languages : [navigator.language];
  for (const tag of tags) {
    const base = (tag || "").toLowerCase().split("-")[0];
    if (base === "vi") return "vi";
    if (base === "en") return "en";
  }
  return "vi";
}

export function langPreference(): LangPreference {
  const raw = localStorage.getItem(LANG_KEY);
  return raw === "en" || raw === "vi" ? raw : "";
}

export function currentLang(): Lang {
  const pref = langPreference();
  return pref === "" ? systemLang() : pref;
}

export function setLang(lang: LangPreference) {
  if (lang === "") localStorage.removeItem(LANG_KEY);
  else localStorage.setItem(LANG_KEY, lang);
}

const STRINGS: Record<string, { vi: string; en: string }> = {
  today: { vi: "Hôm nay", en: "Today" },
  days: { vi: "ngày", en: "days" },
  totalCostPeriod: { vi: "Tổng chi phí {period}", en: "Total cost {period}" },
  estTotal: { vi: "Ước tính {n} ngày", en: "Est. {n}-day total" },
  estFootnote: {
    vi: "Ước tính từ sáu nguồn log chi phí cục bộ.",
    en: "Estimated from six local cost-log sources.",
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
    vi: "Không tìm thấy log chi phí Claude, Codex, Grok, Kiro, Oh My Pi hoặc Pi.",
    en: "No Claude, Codex, Grok, Kiro, Oh My Pi, or Pi cost logs found.",
  },
  scanningSources: { vi: "Đang quét {names}…", en: "Scanning {names}…" },
  grokFootnote: {
    vi: "Ước tính từ log Grok Build cục bộ (~/.grok/sessions).",
    en: "Estimated from local Grok Build logs (~/.grok/sessions).",
  },
  kiroFootnote: {
    vi: "Credit bị tính phí thật từ log Kiro CLI; token của storage cũ là ước tính.",
    en: "Real billed credits from Kiro CLI logs; tokens from legacy storage are estimated.",
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
  "popover.tray": { vi: "Tray", en: "Tray" },
  footerSettings: { vi: "Cài đặt", en: "Settings" },
  footerAbout: { vi: "Giới thiệu", en: "About" },
  footerQuit: { vi: "Thoát", en: "Quit" },
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
  settingsTabInsights: { vi: "Phân tích", en: "Insights" },
  settingsTabActionCenter: { vi: "Trung tâm xử lý", en: "Action Center" },
  actionCenterTitle: { vi: "Trung tâm xử lý", en: "Action Center" },
  actionCenterSubtitle: {
    vi: "Các vấn đề thiết lập và kết nối đang tồn tại. Mục đã xử lý sẽ tự biến mất.",
    en: "Current setup and connection issues. Resolved items disappear automatically.",
  },
  actionCenterCurrent: { vi: "Cần xử lý", en: "Needs attention" },
  actionCenterEmptyTitle: { vi: "Không có vấn đề đang mở", en: "No open issues" },
  actionCenterEmptyBody: {
    vi: "BirdNion sẽ hiển thị tại đây khi provider cần sửa thiết lập hoặc thử kết nối lại.",
    en: "BirdNion will list providers here when setup needs fixing or a connection should be retried.",
  },
  "actionCenter.setup.title": { vi: "Cần sửa thiết lập", en: "Setup needs attention" },
  "actionCenter.setup.hint": {
    vi: "Mở đúng trường cấu hình cần kiểm tra; BirdNion không tự cài CLI hoặc đăng nhập thay bạn.",
    en: "Open the exact setting to check. BirdNion does not install CLIs or sign in on your behalf.",
  },
  "actionCenter.connection.title": { vi: "Kết nối chưa ổn định", en: "Connection is unstable" },
  "actionCenter.connection.hint": {
    vi: "Thử lại kết nối hiện tại. Danh sách này không chứa quota, budget hoặc lịch sử lỗi.",
    en: "Retry the current connection. Quota, budgets, and issue history are not included here.",
  },
  "actionCenter.service.title": { vi: "Dịch vụ đang có sự cố", en: "Service incident" },
  "actionCenter.service.hint": {
    vi: "Provider đang báo trạng thái dịch vụ không bình thường. Hãy thử lại sau.",
    en: "The provider reports a non-operational service state. Retry later.",
  },
  actionCenterFix: { vi: "Sửa thiết lập", en: "Fix setup" },
  actionCenterRetry: { vi: "Thử lại", en: "Retry" },
  actionCenterOpen: { vi: "Mở Trung tâm xử lý", en: "Open Action Center" },
  settingsTabDisplay: { vi: "Hiển thị", en: "Display" },
  settingsTabAdvanced: { vi: "Nâng cao", en: "Advanced" },
  settingsTabAbout: { vi: "Giới thiệu", en: "About" },

  // Local usage insights + privacy-safe project costs.
  insightsTitle: { vi: "Phân tích", en: "Insights" },
  insightsSubtitle: {
    vi: "Xu hướng chi phí và project từ log cục bộ.",
    en: "Cost trends and projects from local logs.",
  },
  insightsOverview: { vi: "Tổng quan", en: "Overview" },
  insightsProjects: { vi: "Projects", en: "Projects" },
  insightsPeriodToday: { vi: "Hôm nay", en: "Today" },
  insightsOpenDetails: { vi: "Mở chi tiết phân tích", en: "Open Insights details" },
  insightsUnavailable: { vi: "Chưa có dữ liệu", en: "Unavailable" },
  insightsNoProject: { vi: "Chưa có project", en: "No project yet" },
  insightsUnknownProject: { vi: "Không xác định", en: "Unknown" },
  insightsVsPrevious: { vi: "so với {amount} tuần trước", en: "vs {amount} prior week" },
  insightsTopProject: { vi: "Top: {project}", en: "Top: {project}" },
  insightsConfidenceUnavailable: { vi: "Độ tin cậy: chưa có", en: "Confidence: unavailable" },
  insightsConfidenceLive: { vi: "Độ tin cậy: live", en: "Confidence: live" },
  insightsConfidenceMixed: { vi: "Live {live}/{total} nguồn", en: "Live {live}/{total} sources" },
  insightsWeeklyPulse: { vi: "Nhịp 7 ngày", en: "7-day pulse" },
  insightsCurrent7: { vi: "7 ngày hiện tại", en: "Current 7 days" },
  insightsPrevious7: { vi: "7 ngày trước", en: "Previous 7 days" },
  insightsTopSourceLabel: { vi: "Nguồn dùng nhiều", en: "Top source" },
  insightsTopModelLabel: { vi: "Model dùng nhiều", en: "Top model" },
  insightsConfidenceLabel: { vi: "Độ tin cậy", en: "Confidence" },
  insightsCopySummary: { vi: "Sao chép tóm tắt", en: "Copy summary" },
  insightsCopyFailed: { vi: "Không thể sao chép", en: "Copy failed" },
  insightsCopyPulse: {
    vi: "7 ngày: {current}; trước đó: {previous}; thay đổi: {change}",
    en: "7 days: {current}; previous: {previous}; change: {change}",
  },
  insightsCopySource: { vi: "Nguồn đứng đầu: {source}", en: "Top source: {source}" },
  insightsCopyModel: { vi: "Model đứng đầu: {model}", en: "Top model: {model}" },
  insightsNoProjects: { vi: "Chưa có dữ liệu project trong kỳ này.", en: "No project data in this period." },
  insightsUnknownAttribution: { vi: "Không xác định", en: "Unknown attribution" },
  insightsExactAttribution: { vi: "CWD đã xác minh", en: "Verified cwd" },
  insightsDerivedAttribution: { vi: "Từ thư mục session", en: "Session-derived" },
  insightsModelBreakdown: { vi: "Theo model", en: "By model" },
  insightsNoModelBreakdown: { vi: "Không có chi tiết model.", en: "No model breakdown." },
  insightsDailyBreakdown: { vi: "Theo ngày", en: "By day" },
  insightsLoadError: { vi: "Không đọc được dữ liệu phân tích.", en: "Could not load Insights data." },

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
  settingsMonthlyBudget: { vi: "Ngân sách tuần (USD)", en: "Weekly budget (USD)" },
  settingsMonthlyBudgetSub: {
    vi: "Ngân sách theo tuần lịch — ước tính từ sáu nguồn chi phí cục bộ trên tab All.",
    en: "Calendar-week budget from all six local cost sources on the All tab.",
  },
  settingsMonthlyBudgetPlaceholder: { vi: "Tắt", en: "Off" },
  budgetPerProviderTitle: { vi: "Ngân sách tuần theo nguồn", en: "Per-source weekly budgets" },
  settingsPerProviderBudgetSub: {
    vi: "Ngân sách tuần riêng cho từng nguồn chi phí — độc lập với ngân sách tổng ở trên.",
    en: "A separate weekly budget per cost source — independent of the total budget above.",
  },
  settingsClaudeBudget: { vi: "Ngân sách tuần Claude (USD)", en: "Claude weekly budget (USD)" },
  settingsCodexBudget: { vi: "Ngân sách tuần Codex (USD)", en: "Codex weekly budget (USD)" },
  settingsGrokBudget: { vi: "Ngân sách tuần Grok (USD)", en: "Grok weekly budget (USD)" },
  settingsOMPBudget: { vi: "Ngân sách tuần Oh My Pi (USD)", en: "Oh My Pi weekly budget (USD)" },
  settingsPiBudget: { vi: "Ngân sách tuần Pi (USD)", en: "Pi weekly budget (USD)" },
  settingsKiroBudget: { vi: "Ngân sách tuần Kiro (USD)", en: "Kiro weekly budget (USD)" },
  budgetPerProviderNoData: { vi: "Chưa có dữ liệu chi phí", en: "No cost data yet" },
  budgetPerProviderNoDataHint: {
    vi: "{source}: chưa có dữ liệu chi phí — không đủ căn cứ để đánh giá ngân sách.",
    en: "{source}: no cost data available yet — not enough evidence to assess this budget.",
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
  settingsWeeklyDigest: { vi: "Digest hàng tuần", en: "Weekly digest" },
  settingsWeeklyDigestSub: {
    vi: "Thông báo 1 lần/tuần tổng chi phí và token — mặc định TẮT vì có thể lộ chi phí ngoài popover.",
    en: "One notification a week with total cost and tokens — OFF by default since it can reveal spend outside the popover.",
  },
  weeklyDigestTitle: { vi: "BirdNion — Digest tuần", en: "BirdNion — Weekly digest" },
  weeklyDigestSummary: { vi: "{usd} · {tokens} trong 7 ngày qua", en: "{usd} · {tokens} in the past 7 days" },
  weeklyDigestChange: { vi: "{sign}{pct}% so với 7 ngày trước", en: "{sign}{pct}% vs the prior 7 days" },
  weeklyDigestTopSource: { vi: "Nguồn nhiều nhất: {source}", en: "Top source: {source}" },
  weeklyDigestTopModel: { vi: "Model nhiều nhất: {model}", en: "Top model: {model}" },
  weeklyDigestForecast: { vi: "Dự báo cả tháng: {usd}", en: "Monthly forecast: {usd}" },
  weeklyDigestBudgetOnTrack: { vi: "Trong ngân sách.", en: "On track with budget." },
  weeklyDigestBudgetForecast: { vi: "Dự báo sẽ vượt ngân sách.", en: "Forecast to exceed budget." },
  weeklyDigestBudgetOver: { vi: "Đã vượt ngân sách tuần.", en: "Already over the weekly budget." },
  weeklyDigestCaveat: {
    vi: "Dữ liệu lịch sử (chưa quét mới) cho: {sources}.",
    en: "Historical (not freshly scanned) data for: {sources}.",
  },
  weeklyDigestProviderBudgetForecast: {
    vi: "{source}: dự phóng vượt ngân sách ({usd} / {budget}).",
    en: "{source}: may exceed budget (forecast {usd} of {budget}).",
  },
  weeklyDigestProviderBudgetOver: {
    vi: "{source}: đã vượt ngân sách ({usd} / {budget}).",
    en: "{source}: already over budget ({usd} of {budget}).",
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
  antigravityAccountsLabel: { vi: "Tài khoản Google", en: "Google accounts" },
  antigravityAccountsEmpty: { vi: "Chưa có tài khoản nào.", en: "No accounts." },
  antigravityAccountAddPrimary: { vi: "+ Thêm tài khoản", en: "+ Add account" },
  antigravityAdvancedSetup: { vi: "Cài đặt nâng cao", en: "Advanced setup" },
  antigravityAccountAdd: { vi: "Thêm", en: "Add" },
  antigravityAccountLabelPlaceholder: { vi: "Nhãn", en: "Label" },
  antigravityAccountEmailPlaceholder: { vi: "Email (không bắt buộc)", en: "Email (optional)" },
  antigravityCredentialPlaceholder: { vi: "OAuth credentials JSON", en: "OAuth credentials JSON" },
  antigravityAccountAddHint: {
    vi: "Linux hiện cần OAuth credentials JSON. Cùng nhãn sẽ cập nhật tài khoản cũ.",
    en: "Linux currently requires OAuth credentials JSON. A duplicate label updates the existing account.",
  },
  // Popover Codex accounts card (macOS popover.accounts / provider.* parity)
  popoverAccounts: { vi: "Tài khoản", en: "Accounts" },
  codexAccountSystemManaged: { vi: "Hệ thống · ~/.codex", en: "System · ~/.codex" },
  codexAccountAppManaged: { vi: "Quản lý bởi app", en: "Managed by app" },
  codexAccountQuotaMissing: {
    vi: "Chưa có snapshot quota cho account này",
    en: "No quota snapshot for this account yet",
  },
  codexAccountQuotaHelp: {
    vi: "Quota thấp nhất: {label} còn {n}%",
    en: "Lowest quota: {label} has {n}% remaining",
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
  "providerError.notConfigured.title": { vi: "Chưa cấu hình", en: "Not configured" },
  "providerError.notConfigured.hint": {
    vi: "Chưa cấu hình — kết nối provider trong Cài đặt",
    en: "Not configured — connect this provider in Settings",
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
  "staleQuota.notice": { vi: "Dữ liệu quota có thể đã cũ", en: "Quota data may be outdated" },
  // Cause line for the stale banner: states only WHY the refresh failed. The
  // error card's `providerError.*.hint` strings are instructions and must not
  // be reused here — the provider still has valid data on screen.
  "staleQuota.cause.cookieExpiredOrMissing": {
    vi: "Phiên trình duyệt đã hết hạn", en: "Browser session expired" },
  "staleQuota.cause.notConfigured": {
    vi: "Không làm mới được trong nền", en: "Couldn't refresh in the background" },
  "staleQuota.cause.tokenInvalidOrMissing": {
    vi: "Token bị từ chối", en: "Token was rejected" },
  "staleQuota.cause.apiSchemaChanged": {
    vi: "Provider trả phản hồi lạ", en: "Provider returned an unexpected response" },
  "staleQuota.cause.networkUnreachableOrTimeout": {
    vi: "Không kết nối được provider", en: "Couldn't reach the provider" },
  "staleQuota.cause.rateLimited": {
    vi: "Provider đang giới hạn tần suất", en: "Provider is rate limiting" },
  "staleQuota.cause.unknown": {
    vi: "Lần làm mới gần nhất thất bại", en: "The last refresh failed" },

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

  // Data Confidence Pass — All-tab compact per-source scan badge.
  "confidence.state.live": { vi: "LIVE", en: "LIVE" },
  "confidence.state.history": { vi: "LỊCH SỬ", en: "HISTORY" },
  "confidence.state.unavailable": { vi: "CHƯA CÓ", en: "NO DATA" },
  "confidence.fresh.justNow": { vi: "vừa xong", en: "just now" },
  "confidence.fresh.minutes": { vi: "{n} phút", en: "{n}m" },
  "confidence.fresh.hours": { vi: "{n} giờ", en: "{n}h" },
  "confidence.fresh.days": { vi: "{n} ngày", en: "{n}d" },

  // Budget & weekly forecast (Phase 2) — All-tab + per-provider cards.
  budgetMonthly: { vi: "Ngân sách tuần", en: "Weekly budget" },
  "budgetStatus.on-track": { vi: "Đúng tiến độ", en: "On track" },
  "budgetStatus.forecast-over": { vi: "Dự phóng vượt", en: "Forecast over" },
  "budgetStatus.already-over": { vi: "Đã vượt", en: "Already over" },
  budgetMtd: { vi: "Đã chi tuần này {amount}", en: "Spent this week {amount}" },
  budgetProjected: { vi: "Dự phóng cuối tuần {amount}", en: "Projected by week end {amount}" },
  budgetProjectedAmount: { vi: "dự phóng {amount}", en: "projected {amount}" },
  budgetRemaining: { vi: "Còn lại {amount}", en: "{amount} remaining" },
  budgetRemainingWithDays: {
    vi: "Còn lại {amount} · {n} ngày nữa hết tuần",
    en: "{amount} left · {n} days left in week",
  },
  budgetOverBy: { vi: "Vượt {amount}", en: "Over by {amount}" },
  budgetOfLimit: { vi: "{spent} / {budget}", en: "{spent} / {budget}" },
  budgetHint: {
    vi: "Ước tính local Claude+Codex+Grok — đã chi {mtd}, dự phóng {projected} cuối tuần, ngân sách tuần {budget} ({status}).",
    en: "Estimated from local Claude+Codex+Grok — spent {mtd}, projected {projected} by week end, weekly budget {budget} ({status}).",
  },
  peakDayShort: { vi: "Cao nhất", en: "Peak" },
  avgActiveShort: { vi: "TB/ngày", en: "Avg/day" },
  appearanceTitle: { vi: "Giao diện", en: "Appearance" },
  appearanceLight: { vi: "Chuyển sang sáng", en: "Switch to light" },
  appearanceDark: { vi: "Chuyển sang tối", en: "Switch to dark" },
  aboutUpdateNow: { vi: "Cập nhật ngay", en: "Update now" },

  // Settings detail grid (macOS ProvidersPane detailInfoGrid)
  "provider.status": { vi: "Trạng thái", en: "Status" },
  "provider.source": { vi: "Nguồn", en: "Source" },
  "provider.plan": { vi: "Gói", en: "Plan" },
  "provider.planName": { vi: "Tên gói", en: "Plan name" },
  "provider.account": { vi: "Tài khoản", en: "Account" },
  "provider.version": { vi: "Phiên bản", en: "Version" },
  "provider.kiroContext": { vi: "Context window", en: "Context window" },
  "provider.serviceStatus": { vi: "Tình trạng", en: "Service status" },
  "provider.serviceStatus.ok": { vi: "Ổn định", en: "Operational" },
  "provider.serviceStatus.issue": { vi: "Sự cố", en: "Issues" },
  "provider.serviceStatus.unknown": { vi: "Chưa có dữ liệu", en: "No data yet" },
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
  "provider.daysAgo": { vi: "{n} ngày trước", en: "{n}d ago" },

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
  guidedSetupHeader: { vi: "KẾT NỐI PROVIDER", en: "CONNECT PROVIDER" },
  "guidedSetup.needsSource": {
    vi: "Chưa phát hiện nguồn đăng nhập",
    en: "No sign-in source detected",
  },
  guidedSetupDetected: { vi: "Đã phát hiện {source}", en: "Detected {source}" },
  "guidedSetup.testing": {
    vi: "Đang kiểm tra kết nối thật…",
    en: "Testing the real connection…",
  },
  "guidedSetup.live": { vi: "Đã xác minh ngay bây giờ", en: "Verified just now" },
  "guidedSetup.failed": {
    vi: "Kết nối cần được sửa",
    en: "Connection needs attention",
  },
  guidedSetupPrivacyNote: {
    vi: "BirdNion chỉ xác minh sau khi attempt hiện tại trả quota thật. Receipt nằm trên máy và không lưu token hoặc tài khoản.",
    en: "BirdNion verifies only after the current attempt returns real quota. The on-device receipt stores no token or account.",
  },
  guidedSetupLastVerified: {
    vi: "Xác minh lần cuối {time} · {detail}",
    en: "Last verified {time} · {detail}",
  },
  guidedSetupConnect: { vi: "Kết nối & kiểm tra", en: "Connect & test" },
  guidedSetupRetry: { vi: "Thử lại", en: "Retry" },
  guidedSetupFix: { vi: "Sửa thiết lập", en: "Fix setup" },
  guidedSetupSaveFailed: {
    vi: "Không thể lưu thiết lập. Kết nối chưa được kiểm tra.",
    en: "Settings could not be saved. The connection was not tested.",
  },
  guidedSetupReceiptSaveFailed: {
    vi: "Đã kiểm tra kết nối nhưng chưa thể xác nhận và lưu receipt trên máy. Hãy giữ cửa sổ ở phía trước rồi thử lại.",
    en: "The connection passed, but its on-device receipt could not be confirmed and saved. Keep this window in front and retry.",
  },
  guidedSetupTestFailed: {
    vi: "Không thể hoàn tất kiểm tra kết nối. Hãy thử lại.",
    en: "The connection test could not be completed. Try again.",
  },
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

  // Hiyo multi-key
  hiyoKeysLabel: { vi: "API keys Hiyo", en: "Hiyo API keys" },
  hiyoKeysEmpty: {
    vi: "Chưa có API key — dán key bên dưới để thêm.",
    en: "No API keys yet — paste a key below to add one.",
  },
  hiyoKeyPlaceholder: { vi: "Dán API key Hiyo…", en: "Paste Hiyo API key…" },
  hiyoKeyLabelPlaceholder: { vi: "Nhãn (tuỳ chọn)", en: "Label (optional)" },
  hiyoKeyAdd: { vi: "Thêm key", en: "Add key" },
  hiyoKeySwitch: { vi: "Dùng key này", en: "Use this key" },
  hiyoKeyActive: { vi: "Đang dùng", en: "Active" },
  hiyoKeysAddHint: {
    vi: "Lưu nhiều API key và chuyển nhanh. Key được lưu riêng (hiyo-keys.json).",
    en: "Store multiple API keys and switch between them. Keys live in a separate file (hiyo-keys.json).",
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
  "settingsTabAgents": { vi: "Agent", en: "Agents" },
  "settingsAgentsSubtitle": {
    vi: "Mỗi agent khai báo có quota, có log chi phí, hay chỉ có cấu hình. BirdNion chỉ hiển thị đúng thứ agent đó cung cấp.",
    en: "Each agent reports quota, local cost logs, or config only. BirdNion displays exactly what the agent provides.",
  },
  "agentsSearch": { vi: "Tìm agent", en: "Search agents" },
  "agentsFilterAll": { vi: "Tất cả {n}", en: "All {n}" },
  "agentsFilterQuota": { vi: "Có quota {n}", en: "Quota {n}" },
  "agentsFilterCost": { vi: "Có chi phí {n}", en: "Cost {n}" },
  "agentsFilterConfig": { vi: "Chỉ config {n}", en: "Config {n}" },
  "agentsColShow": { vi: "HIỆN", en: "SHOW" },
  "agentsColAgent": { vi: "AGENT", en: "AGENT" },
  "agentsColSource": { vi: "NGUỒN", en: "SOURCE" },
  "agentsColData": { vi: "DỮ LIỆU", en: "DATA" },
  "agentsCol90d": { vi: "90 NGÀY", en: "90 DAYS" },
  "agentsEmpty": { vi: "Không tìm thấy agent nào.", en: "No agents found." },
  "actionCenterNoIssues": { vi: "Không có vấn đề", en: "No open issues" },
  "actionCenterIssues": { vi: "{n} việc cần xử lý", en: "{n} open issues" },
  "insightsSegmentActivity": { vi: "Hoạt động", en: "Activity" },
  "budgetPeriod": { vi: "Kỳ ngân sách", en: "Budget period" },
  "budgetPeriodWeek": { vi: "Tuần", en: "Week" },
  "budgetPeriodMonth": { vi: "Tháng", en: "Month" },
  "weekday.mon": { vi: "T2", en: "Mon" },
  "weekday.wed": { vi: "T4", en: "Wed" },
  "weekday.fri": { vi: "T6", en: "Fri" },
  "weekday.sun": { vi: "CN", en: "Sun" },
  "activeDaysWord": { vi: "ngày active", en: "active days" },
  "activeDaysLabel": { vi: "Ngày active", en: "Active days" },
  "language.system": { vi: "Theo hệ thống", en: "System" },
  "language.vietnamese": { vi: "Tiếng Việt", en: "Vietnamese" },
  "language.english": { vi: "Tiếng Anh", en: "English" },
  "nAgents": { vi: "{n} agent", en: "{n} agents" },
  "daysWord": { vi: "ngày", en: "days" },
  "less": { vi: "ÍT", en: "LESS" },
  "more": { vi: "NHIỀU", en: "MORE" },
  "shadedByTokens": { vi: "đậm nhạt theo token", en: "shaded by tokens" },
  "avgPerActiveDay": { vi: "TB/ngày", en: "Avg/day" },
  "streak": { vi: "Chuỗi ngày", en: "Streak" },
  "clickToPin": { vi: "CLICK ĐỂ GHIM", en: "CLICK TO PIN" },
  "ofPeriod": { vi: "của", en: "of" },
  "quota": { vi: "Quota", en: "Quota" },
  "agentsWithQuota": { vi: "{n}/{total} agent có quota", en: "{n}/{total} agents with quota" },
  "moreAgentsWithQuota": { vi: "+{n} agent còn quota cao ›", en: "+{n} more agents with quota ›" },
  "quotaAgenda.title": { vi: "Lịch quota", en: "Quota Agenda" },
  "quotaAgenda.providers": { vi: "{n} provider", en: "{n} providers" },
  "quotaAgenda.more": { vi: "+{n} provider khác ›", en: "+{n} more providers ›" },
  "quotaAgenda.resetsIn": { vi: "reset sau {time}", en: "resets in {time}" },
  "quotaAgenda.awaitingRefresh": { vi: "Chờ làm mới", en: "Awaiting refresh" },
  "quotaAgenda.lastKnown": { vi: "Dữ liệu lần trước", en: "Last known" },
  "quotaAgenda.resetUnknown": { vi: "Chưa rõ reset", en: "Reset unknown" },
  "quotaAgenda.sourceUnknown": { vi: "Nguồn chưa rõ", en: "Source unknown" },
  "quotaAgenda.accountHidden": { vi: "Đã ẩn tài khoản", en: "Account hidden" },
  "quotaAgenda.accountUnknown": { vi: "Tài khoản chưa rõ", en: "Account unknown" },
  "quotaAgenda.freshnessUnknown": { vi: "Chưa rõ độ mới", en: "Freshness unknown" },
  "quotaAgenda.daysAgo": { vi: "{n} ngày trước", en: "{n}d ago" },
  "costBy": { vi: "Chi phí theo", en: "Cost by" },
  "costByAgent": { vi: "Agent", en: "Agent" },
  "costByModel": { vi: "Model", en: "Model" },
  "costByToken": { vi: "Token", en: "Token" },
  "moreAgents": { vi: "{n} agent khác", en: "{n} more agents" },
  "configured": { vi: "Đã cấu hình", en: "Configured" },
  "configuredNoLogs": { vi: "{n} agent · không có log", en: "{n} agents · no logs" },

  // Agent detail side panel — 3 tab THẬT Quota/Cost/Config (đọc lại macOS
  // `AgentDetailPanelRoot` làm nguồn sự thật 2026-08-24 — không có tab
  // Activity, banded heatmap thuộc panel "activity" riêng).
  "cost": { vi: "Chi phí", en: "Cost" },
  "agentPanelQuotaDisabled": { vi: "Quota — không", en: "Quota — none" },
  "agentPanelCostDisabled": { vi: "Chi phí — không", en: "Cost — none" },
  "agentPanelCurrentQuota": { vi: "Quota hiện tại", en: "Current quota" },
  "agentPanelNoQuota": { vi: "Không có quota trực tiếp.", en: "No direct quota surface." },
  "agentPanelLocalLog": { vi: "Log cục bộ", en: "Local log" },
  "agentPanelLastScanned": { vi: "Quét gần nhất", en: "Last scanned" },
  "agentPanelNoConfig": { vi: "Không có thông tin cấu hình.", en: "No configuration details." },
  "agentPanelModelsTitle": { vi: "Model trong agent này", en: "Models in this agent" },
  "weeksWord": { vi: "tuần", en: "weeks" },
  "agentPanelStreakRecord": { vi: "Đang là kỷ lục", en: "Record pace" },
  "agentPanelStreakCountdown": {
    vi: "Còn {n} ngày vượt kỷ lục {best}",
    en: "{n}d to beat {best}d best",
  },
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
