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
  estTotal: { vi: "Ước tính {n} ngày", en: "Est. {n}-day total" },
  estFootnote: {
    vi: "Ước tính từ log cục bộ của Claude Code CLI và Codex.",
    en: "Estimated from local Claude Code CLI and Codex logs.",
  },
  hourBarsNote: {
    vi: "Cột giờ chỉ gồm Claude — log Codex chỉ ghi theo ngày.",
    en: "Hour bars are Claude-only — Codex logs have day resolution.",
  },
  codexToday: { vi: "Codex (hôm nay)", en: "Codex (today)" },
  activity90: { vi: "Hoạt động 90 ngày", en: "90-day activity" },
  activeDays: { vi: "ngày active", en: "active days" },
  peakDay: { vi: "Ngày cao nhất", en: "Peak day" },
  avgActive: { vi: "TB/ngày active", en: "Avg active day" },
  streakUnit: { vi: "ngày", en: "days" },
  noActivity: { vi: "Không có hoạt động.", en: "No activity." },
  topModels: { vi: "Model dùng nhiều (90 ngày)", en: "Top models (90 days)" },
  topModel: { vi: "Model dùng nhiều", en: "Top model" },
  latestTokens: { vi: "Token mới nhất", en: "Latest tokens" },
  noLogs: {
    vi: "Không tìm thấy log Claude Code (~/.claude) hoặc Codex (~/.codex).",
    en: "No Claude Code (~/.claude) or Codex (~/.codex) logs found.",
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

  // Claude Code quick-apply
  ccTitle: { vi: "Claude Code", en: "Claude Code" },
  ccStateOn: { vi: "Bật", en: "On" },
  ccStateOff: { vi: "Tắt", en: "Off" },
  ccStateStale: { vi: "Lệch", en: "Stale" },
  ccStateSetup: { vi: "Cần cấu hình", en: "Needs setup" },
  ccPowerOn: { vi: "Đang dùng {name} cho Claude Code", en: "Claude Code is using {name}" },
  ccPowerOff: { vi: "Bấm để áp dụng cho Claude Code", en: "Tap to apply to Claude Code" },
  ccPowerStale: { vi: "Giá trị đã thay đổi — bấm để cập nhật", en: "Values changed — tap to update" },
  ccNeedSetup: { vi: "Chưa cấu hình đủ model cho Claude Code", en: "Claude Code models not fully configured" },
  ccGlobalTarget: { vi: "~/.claude/settings.json", en: "~/.claude/settings.json" },
  ccProjectNone: { vi: "Chưa chọn thư mục project", en: "No project folder chosen" },
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
    vi: "Làm mới khi mở lại cửa sổ",
    en: "Refresh when opening the window",
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
  settingsLaunchAtLogin: { vi: "Khởi động cùng hệ thống", en: "Launch at login" },
  settingsSave: { vi: "Lưu cài đặt", en: "Save settings" },
  settingsSaved: { vi: "Đã lưu ✓", en: "Saved ✓" },
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

  // Self-test
  "provider.selfTest": { vi: "Kiểm tra", en: "Self-test" },
  "provider.selfTest.running": { vi: "Đang kiểm tra…", en: "Testing…" },
  "provider.selfTest.pass": { vi: "Đạt", en: "Passed" },
  "provider.selfTest.fail": { vi: "Lỗi", en: "Failed" },
  "provider.selfTest.disabled": { vi: "Bật provider để kiểm tra", en: "Enable the provider to test" },
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
