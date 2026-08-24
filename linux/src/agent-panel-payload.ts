// Payload cho panel phụ "agent" — 3 tab THẬT: Quota / Chi phí (Cost) / Config,
// port từ macOS `AgentDetailPanelRoot` (đọc lại Swift làm nguồn sự thật
// 2026-08-24 — bản trước có Overview/Activity/Config là SAI cấu trúc tab).
// KHÔNG có tab Activity ở đây: banded heatmap thuộc panel "activity" riêng,
// mở từ hàng stats của chart (xem `all-tab.ts` + `panel-entry.ts`). Popover
// đã có sẵn report từ scanner (Combined + ProviderStatus) nên panel chỉ NHẬN
// dữ liệu qua payload này — không tự gọi lại scanner.

import { CombinedDay, CombinedModel, UsageSourceId, scanFreshness } from "./usage";
import { t } from "./i18n";

export type AgentTabId = "quota" | "cost" | "config";

export type AgentQuotaWindow = { label: string; remainingPct: number };
export type AgentConfigRow = { label: string; value: string };

export type AgentCostDay = {
  date: string;
  usd: number;
  tokens: number;
  /** Ngày có bằng chứng chi phí thật (usd>0 hoặc tokens>0) — KHÔNG nội suy. */
  hasEvidence: boolean;
  models: CombinedModel[];
};

export type AgentPanelPayload = {
  kind: "agent";
  agentId: string;
  displayName: string;
  quotaWindows: AgentQuotaWindow[];
  /** null khi agent này chưa từng có bằng chứng chi phí cục bộ thật — panel
   *  disable tab Cost thay vì vẽ chart rỗng (parity macOS `costSummary == nil`
   *  khi không có `hasLocalCost`/confidence/evidence). */
  costDays: AgentCostDay[] | null;
  configRows: AgentConfigRow[];
  /** Tab mở đầu theo nguồn click ("quota"/"cost"/"config"); undefined = panel
   *  tự suy theo capability — parity macOS `initialTab: String?` + fallback
   *  heuristics trong `.onAppear` (cost → quota → config). */
  initialTab?: AgentTabId;
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
 *  ProviderStatus) — KHÔNG gọi lại scanner. Trả về `costDays: null` khi agent
 *  chưa từng có bằng chứng chi phí thật, để tab Cost bị disable thay vì vẽ
 *  chart rỗng. */
export function buildAgentPanelPayload(opts: BuildAgentPanelPayloadOptions): AgentPanelPayload {
  const quotaWindows: AgentQuotaWindow[] = (opts.quotaWindows ?? [])
    .filter((w) => Number.isFinite(w.remainingPct))
    .map((w) => ({ label: w.label, remainingPct: w.remainingPct }));

  let costDays: AgentCostDay[] | null = null;
  if (opts.source && opts.daily && opts.daily.length > 0) {
    const source = opts.source;
    const days: AgentCostDay[] = opts.daily.map((d) => {
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
    if (days.some((d) => d.hasEvidence)) costDays = days;
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
    quotaWindows,
    costDays,
    configRows,
  };
}
