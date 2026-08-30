import type { ProviderStatus, QuotaWindow, StaleQuotaWarning } from "./provider-tab";

export type QuotaAgendaState = "scheduled" | "awaitingRefresh" | "unknown" | "stale";
export type QuotaAgendaPercentageKind = "current" | "lastKnown" | "unavailable";

export type QuotaAgendaRow = {
  providerId: string;
  providerName: string;
  agentId: string;
  agentName: string;
  windowLabel: string;
  remainingPct: number | null;
  percentageKind: QuotaAgendaPercentageKind;
  state: QuotaAgendaState;
  resetAt: number | null;
  observedAt: number | null;
  sourceLabel: string | null;
  accountLabel: string | null;
  accountHidden: boolean;
};

export type QuotaAgendaBuildOptions = {
  agents: readonly { id: string; displayName: string }[] | null;
  staleWarnings: ReadonlyMap<string, StaleQuotaWarning>;
  hidePersonalInfo: boolean;
  nowSeconds?: number;
};

const SUPPLEMENTARY_LABELS = new Set([
  "số dư", "bonus credits", "daily routines",
]);
const INFO_ONLY_LABELS = new Set(["gia hạn", "chi phí 30 ngày", "vượt hạn mức"]);
const PROVIDER_AGENT_ALIASES: Readonly<Record<string, string>> = {
  opencodego: "opencode",
};

function explicitReset(window: QuotaWindow): number | null {
  const reset = window.resetsAt;
  return reset != null && Number.isFinite(reset) && reset > 0 ? reset : null;
}

function unixSeconds(value: number | null | undefined): number | null {
  if (value == null || !Number.isFinite(value) || value <= 0) return null;
  return value > 1e12 ? value / 1000 : value;
}

/** One centralized supplementary heuristic until every backend supplies flags. */
export function isQuotaAgendaSupplementary(window: QuotaWindow): boolean {
  return window.isSupplementary === true
    || SUPPLEMENTARY_LABELS.has(window.label.trim().toLocaleLowerCase());
}

/** Mirrors the one current backend gap: FreeModel serializes a 0/0 plan as 100%. */
export function isQuotaAgendaInactive(status: ProviderStatus, window: QuotaWindow): boolean {
  if (window.isInactive === true) return true;
  if (status.id !== "freemodel") return false;
  return /^\$0(?:\.0+)?\s*\/\s*\$0(?:\.0+)?(?:\s|$)/.test(window.subtitle?.trim() ?? "");
}

/** Missing denominators must stay Unknown, never become a green 100% claim. */
export function isQuotaAgendaPlaceholder(status: ProviderStatus, window: QuotaWindow): boolean {
  const label = window.label.trim().toLocaleLowerCase();
  if (INFO_ONLY_LABELS.has(label)) return true;
  if (status.id === "kiro"
    && label === "credits"
    && window.usedPct === 0
    && window.remainingPct === 100
    && !window.subtitle?.trim()
    && explicitReset(window) == null) return true;
  return status.id === "cursor"
    && ["plan", "total", "on-demand"].includes(label)
    && window.usedPct === 0
    && window.remainingPct === 100
    && !hasPositiveDenominator(window.subtitle);
}

function hasPositiveDenominator(subtitle: string | undefined): boolean {
  const rhs = subtitle?.split("/", 2)[1];
  const match = rhs?.match(/[0-9][0-9,]*(?:\.[0-9]+)?/);
  return match != null && Number(match[0].replace(/,/g, "")) > 0;
}

export function quotaAgendaAgentId(providerId: string): string {
  return PROVIDER_AGENT_ALIASES[providerId] ?? providerId;
}

/** Agenda selector is intentionally independent from provider-tab lowestWindow. */
export function selectQuotaAgendaWindow(
  status: ProviderStatus,
  nowSeconds: number,
): QuotaWindow | null {
  const eligible = status.windows.filter((window) =>
    !isQuotaAgendaInactive(status, window)
      && !isQuotaAgendaPlaceholder(status, window)
      && Number.isFinite(window.remainingPct));
  const primary = eligible.filter((window) => !isQuotaAgendaSupplementary(window));
  const scheduled = primary
    .filter((window) => (explicitReset(window) ?? 0) > nowSeconds)
    .sort((left, right) => explicitReset(left)! - explicitReset(right)!);
  return scheduled[0] ?? primary.reduce<QuotaWindow | null>((lowest, window) => {
    if (lowest == null || window.remainingPct < lowest.remainingPct) return window;
    return lowest;
  }, null);
}

export function buildQuotaAgendaRows(
  statuses: readonly ProviderStatus[],
  options: QuotaAgendaBuildOptions,
): QuotaAgendaRow[] {
  if (options.agents == null) return [];
  const now = options.nowSeconds ?? Date.now() / 1000;
  const names = new Map(options.agents.map((agent) => [agent.id, agent.displayName]));
  const ordered: { row: QuotaAgendaRow; order: number }[] = [];

  statuses.forEach((status, order) => {
    const agentId = quotaAgendaAgentId(status.id);
    const agentName = names.get(agentId);
    if (agentName == null) return;
    const stale = options.staleWarnings.get(status.id);
    if (status.error && !stale) return;
    const window = selectQuotaAgendaWindow(status, now);
    if (!window) return;
    const explicit = explicitReset(window);
    const observed = unixSeconds(stale?.lastGoodUpdated ?? status.lastUpdated);
    let state: QuotaAgendaState = "unknown";
    let percentageKind: QuotaAgendaPercentageKind = "current";
    let remainingPct: number | null = Math.max(0, Math.min(100, window.remainingPct));
    let resetAt: number | null = null;
    const account = status.accountLabel?.trim() || status.signedInEmail?.trim() || null;

    if (stale) {
      state = "stale";
      percentageKind = "lastKnown";
    } else if (explicit != null && explicit > now) {
      state = "scheduled";
      resetAt = explicit;
    } else if (explicit != null && observed != null && observed < explicit) {
      state = "awaitingRefresh";
      percentageKind = "unavailable";
      remainingPct = null;
    }

    ordered.push({
      order,
      row: {
        providerId: status.id,
        providerName: status.displayName,
        agentId,
        agentName,
        windowLabel: window.label,
        remainingPct,
        percentageKind,
        state,
        resetAt,
        observedAt: observed,
        sourceLabel: status.sourceLabel?.trim() || null,
        accountLabel: options.hidePersonalInfo ? null : account,
        accountHidden: options.hidePersonalInfo && account != null,
      },
    });
  });

  const rank: Record<QuotaAgendaState, number> = {
    scheduled: 0, awaitingRefresh: 1, unknown: 2, stale: 3,
  };
  ordered.sort((left, right) => rank[left.row.state] - rank[right.row.state]
    || ((left.row.resetAt ?? 0) - (right.row.resetAt ?? 0))
    || left.order - right.order);
  return ordered.map((item) => item.row);
}
