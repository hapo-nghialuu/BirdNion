// Payload cho panel phụ "agent" — 3 tab Overview / Activity / Config, port
// từ macOS `AgentDetailPanelRoot` + `ActivityPanelRoot` (agent-centric
// remake 2026-08-24). Popover đã có sẵn report từ scanner (Combined +
// ProviderStatus) nên panel chỉ NHẬN dữ liệu qua payload này — không tự gọi
// lại scanner (panel-entry.ts chỉ render, không invoke Tauri command nào).

import { CombinedDay, CombinedModel, UsageSourceId, scanFreshness } from "./usage";
import { t } from "./i18n";

export type AgentOverviewRow = { label: string; value: string };
export type AgentConfigRow = { label: string; value: string };

export type AgentActivityDay = {
  date: string;
  usd: number;
  tokens: number;
  /** Ngày có bằng chứng chi phí thật (usd>0 hoặc tokens>0) — ngày đệm cho đủ
   *  tuần luôn là false, KHÔNG nội suy giá trị. */
  hasEvidence: boolean;
  models: CombinedModel[];
};

export type AgentActivityBlock = {
  /** Tuần Thứ 2 → Chủ nhật, cũ → mới; tuần đầu/cuối được đệm ô ngày thật
   *  nhưng không bằng chứng cho đủ 7 ngày. */
  weeks: AgentActivityDay[][];
  totalUsd: number;
  peakUsd: number;
  avgUsd: number;
  currentStreak: number;
  longestStreak: number;
};

export type AgentPanelPayload = {
  kind: "agent";
  agentId: string;
  displayName: string;
  overviewRows: AgentOverviewRow[];
  activity: AgentActivityBlock | null;
  configRows: AgentConfigRow[];
};

/** Path log cục bộ mà scanner của từng agent thật sự đọc (khớp
 *  `src-tauri/src/*_scanner.rs` + `installed_agents.rs`) — không fabricate,
 *  chỉ nêu sự thật về nơi BirdNion lấy dữ liệu. */
const LOCAL_LOG_PATH: Partial<Record<UsageSourceId, string>> = {
  claude: "~/.claude",
  codex: "~/.codex",
  grok: "~/.grok/sessions",
  omp: "~/.omp/agent/sessions",
  pi: "~/.pi/agent/sessions",
};

function dayUsd(day: CombinedDay, source: UsageSourceId): number {
  switch (source) {
    case "claude": return day.claudeUsd;
    case "codex": return day.codexUsd;
    case "grok": return day.grokUsd;
    case "omp": return day.ompUsd;
    case "pi": return day.piUsd;
    default: return 0;
  }
}

function dayTokens(day: CombinedDay, source: UsageSourceId): number {
  switch (source) {
    case "claude": return day.claudeTokens;
    case "codex": return day.codexTokens;
    case "grok": return day.grokTokens;
    case "omp": return day.ompTokens;
    case "pi": return day.piTokens;
    default: return 0;
  }
}

function addDays(dateStr: string, delta: number): string {
  const d = new Date(dateStr + "T12:00:00");
  d.setDate(d.getDate() + delta);
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}

/** 0 = Thứ 2 … 6 = Chủ nhật (ISO), khác `Date#getDay()` vốn 0 = Chủ nhật. */
function mondayIndex(dateStr: string): number {
  const dow = new Date(dateStr + "T12:00:00").getDay();
  return (dow + 6) % 7;
}

function emptyDay(date: string): AgentActivityDay {
  return { date, usd: 0, tokens: 0, hasEvidence: false, models: [] };
}

/** Đệm đầu/cuối cho đủ tuần Thứ 2 → CN rồi cắt thành từng tuần 7 ngày. Ô đệm
 *  dùng ngày thật (tính theo lịch) nhưng đánh dấu không bằng chứng — giữ
 *  nguyên tắc "không fabricate" xuyên suốt BirdNion. */
function toWeeks(days: AgentActivityDay[]): AgentActivityDay[][] {
  if (days.length === 0) return [];
  const leadPad = mondayIndex(days[0].date);
  const lead: AgentActivityDay[] = [];
  for (let i = leadPad; i > 0; i--) lead.push(emptyDay(addDays(days[0].date, -i)));
  const last = days[days.length - 1];
  const trailPad = 6 - mondayIndex(last.date);
  const trail: AgentActivityDay[] = [];
  for (let i = 1; i <= trailPad; i++) trail.push(emptyDay(addDays(last.date, i)));
  const full = [...lead, ...days, ...trail];
  const weeks: AgentActivityDay[][] = [];
  for (let i = 0; i < full.length; i += 7) weeks.push(full.slice(i, i + 7));
  return weeks;
}

/** Chuỗi ngày hoạt động liên tiếp — parity với streak trong `usage.ts`
 *  (`combine()`), cộng thêm kỷ lục dài nhất (macOS `WeeklyActivityBucketBuilder`). */
function streakMetrics(days: AgentActivityDay[]): { current: number; longest: number } {
  let longest = 0;
  let run = 0;
  for (const day of days) {
    if (day.hasEvidence) { run++; longest = Math.max(longest, run); } else { run = 0; }
  }
  let i = days.length - 1;
  if (i >= 0 && !days[i].hasEvidence) i--;
  let current = 0;
  while (i >= 0 && days[i].hasEvidence) { current++; i--; }
  return { current, longest };
}

/** `lastUpdated`/`scannedAt` có thể ở giây (backend Rust) hoặc milli-giây
 *  (frontend) — cùng quy ước chuẩn hoá đang dùng ở `provider-tab.ts`. */
function normalizeToMillis(ts: number | null | undefined): number | null {
  if (ts == null || !Number.isFinite(ts) || ts <= 0) return null;
  return ts > 1e12 ? ts : ts * 1000;
}

export type BuildAgentPanelPayloadOptions = {
  agentId: string;
  displayName: string;
  /** Cửa sổ quota còn lại (nếu agent này có quota trực tiếp). */
  quotaWindows?: { label: string; remainingPct: number }[];
  /** Toàn bộ `combined.daily` (không windowed) — chỉ cần khi agent có log
   *  chi phí thật (`source` khớp một trong 5 `UsageSourceId`). */
  daily?: CombinedDay[];
  source?: UsageSourceId;
  /** Nhãn nguồn hiển thị ở tab Config (ví dụ path binary/provider bridge). */
  sourceLabel?: string;
  /** Epoch giây hoặc milli-giây của lượt quét gần nhất — `null`/`undefined`
   *  khi chưa có dữ liệu freshness thật. */
  scannedAt?: number | null;
};

/** Dựng payload panel "agent" từ dữ liệu popover đã có sẵn (Combined +
 *  ProviderStatus) — KHÔNG gọi lại scanner. Trả về `activity: null` khi
 *  agent chưa từng có bằng chứng chi phí thật, để panel không vẽ chart rỗng. */
export function buildAgentPanelPayload(opts: BuildAgentPanelPayloadOptions): AgentPanelPayload {
  const overviewRows: AgentOverviewRow[] = (opts.quotaWindows ?? [])
    .filter((w) => Number.isFinite(w.remainingPct))
    .map((w) => ({
      label: w.label.toUpperCase(),
      value: t("provider.remainingPct", { n: Math.round(w.remainingPct) }),
    }));

  let activity: AgentActivityBlock | null = null;
  if (opts.source && opts.daily && opts.daily.length > 0) {
    const source = opts.source;
    const days: AgentActivityDay[] = opts.daily.map((d) => {
      const usdVal = dayUsd(d, source);
      const tokensVal = dayTokens(d, source);
      return {
        date: d.date,
        usd: usdVal,
        tokens: tokensVal,
        hasEvidence: usdVal > 0 || tokensVal > 0,
        models: d.models.filter((m) => m.source === source),
      };
    });
    if (days.some((d) => d.hasEvidence)) {
      const totalUsd = days.reduce((s, d) => s + d.usd, 0);
      const peakUsd = days.reduce((m, d) => Math.max(m, d.usd), 0);
      const activeDays = days.filter((d) => d.hasEvidence).length;
      const avgUsd = activeDays > 0 ? totalUsd / activeDays : 0;
      const { current, longest } = streakMetrics(days);
      activity = {
        weeks: toWeeks(days),
        totalUsd,
        peakUsd,
        avgUsd,
        currentStreak: current,
        longestStreak: longest,
      };
    }
  }

  const configRows: AgentConfigRow[] = [];
  if (opts.sourceLabel) {
    configRows.push({ label: t("provider.source").toUpperCase(), value: opts.sourceLabel });
  }
  const localLog = opts.source ? LOCAL_LOG_PATH[opts.source] : undefined;
  if (localLog) {
    configRows.push({ label: t("agentPanelLocalLog").toUpperCase(), value: localLog });
  }
  const freshness = scanFreshness(normalizeToMillis(opts.scannedAt));
  if (freshness) {
    configRows.push({ label: t("agentPanelLastScanned").toUpperCase(), value: freshness });
  }

  return {
    kind: "agent",
    agentId: opts.agentId,
    displayName: opts.displayName,
    overviewRows,
    activity,
    configRows,
  };
}
