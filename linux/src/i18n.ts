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
  usedPct: { vi: "Đã dùng {n}%", en: "{n}% used" },
  updatedAt: { vi: "cập nhật", en: "updated" },
  resetInDays: { vi: "reset sau {n} ngày", en: "resets in {n}d" },
  resetInHours: { vi: "reset sau {n} giờ", en: "resets in {n}h" },
  resetInMins: { vi: "reset sau {n} phút", en: "resets in {n}m" },
  claudeFootnote: { vi: "Ước tính từ log Claude Code cục bộ.", en: "Estimated from local Claude Code logs." },
  codexFootnote: { vi: "Ước tính từ log Codex cục bộ.", en: "Estimated from local Codex logs." },
  loadError: { vi: "Lỗi khi tải", en: "Load error" },
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
