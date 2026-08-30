import { t } from "./i18n";
import { logoMark } from "./logos";
import {
  buildQuotaAgendaRows,
  type QuotaAgendaBuildOptions,
  type QuotaAgendaRow,
} from "./quota-agenda";
import type { ProviderStatus } from "./provider-tab";

export type QuotaAgendaSectionOptions = QuotaAgendaBuildOptions & {
  onProviderSelect: (providerId: string) => void;
};

const ROW_LIMIT = 3;

function el(tag: string, className: string, text?: string): HTMLElement {
  const node = document.createElement(tag);
  node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function countdown(resetAt: number, now: number): string {
  const minutes = Math.max(1, Math.ceil((resetAt - now) / 60));
  if (minutes >= 1440) return `${Math.floor(minutes / 1440)}d ${Math.floor(minutes % 1440 / 60)}h`;
  if (minutes >= 60) return `${Math.floor(minutes / 60)}h ${minutes % 60}m`;
  return `${minutes}m`;
}

function freshness(observedAt: number | null, now: number): string {
  if (observedAt == null) return t("quotaAgenda.freshnessUnknown");
  const seconds = Math.max(0, Math.floor(now - observedAt));
  if (seconds < 5) return t("time.justUpdated");
  if (seconds < 60) return t("time.secondsAgo", { n: seconds });
  if (seconds < 3600) return t("time.minutesAgo", { n: Math.floor(seconds / 60) });
  if (seconds < 86400) return t("time.hoursAgo", { n: Math.floor(seconds / 3600) });
  return t("quotaAgenda.daysAgo", { n: Math.floor(seconds / 86400) });
}

function resetState(row: QuotaAgendaRow, now: number): string {
  if (row.state === "scheduled" && row.resetAt != null) {
    return t("quotaAgenda.resetsIn", { time: countdown(row.resetAt, now) });
  }
  if (row.state === "awaitingRefresh") return t("quotaAgenda.awaitingRefresh");
  if (row.state === "stale") return t("quotaAgenda.lastKnown");
  return t("quotaAgenda.resetUnknown");
}

function agendaRow(row: QuotaAgendaRow, now: number, onSelect: (id: string) => void): HTMLElement {
  const button = el("button", `quota-agenda-row is-${row.state}`);
  button.setAttribute("type", "button");
  button.append(logoMark(row.providerId, "quota-agenda-logo"));
  const identity = el("span", "quota-agenda-identity");
  identity.append(el("span", "quota-agenda-agent", row.agentName));
  if (row.agentName !== row.providerName) {
    identity.append(el("span", "quota-agenda-provider", `· ${row.providerName}`));
  }
  const value = row.remainingPct == null
    ? "—"
    : `${Math.round(row.remainingPct)}%${row.percentageKind === "lastKnown" ? "*" : ""}`;
  const tone = row.remainingPct == null ? ""
    : row.remainingPct <= 20 ? " tone-critical"
      : row.remainingPct <= 50 ? " tone-warning" : " tone-ok";
  const percent = el("span", `quota-agenda-percent is-${row.percentageKind}${tone}`, value);
  if (row.percentageKind === "lastKnown") percent.title = t("quotaAgenda.lastKnown");
  const meta = el("span", "quota-agenda-meta");
  meta.append(
    el("span", "quota-agenda-window", row.windowLabel.toUpperCase()),
    el("span", `quota-agenda-reset is-${row.state}`, resetState(row, now)),
    el("span", "quota-agenda-source", row.sourceLabel ?? t("quotaAgenda.sourceUnknown")),
    el("span", "quota-agenda-account", row.accountHidden
      ? t("quotaAgenda.accountHidden")
      : row.accountLabel ?? t("quotaAgenda.accountUnknown")),
    el("span", "quota-agenda-freshness", freshness(row.observedAt, now)),
  );
  button.append(identity, percent, meta, el("span", "quota-agenda-chevron", "›"));
  button.addEventListener("click", () => onSelect(row.providerId));
  return button;
}

export function quotaAgendaSection(
  statuses: readonly ProviderStatus[],
  options: QuotaAgendaSectionOptions,
): HTMLElement | null {
  const now = options.nowSeconds ?? Date.now() / 1000;
  const rows = buildQuotaAgendaRows(statuses, { ...options, nowSeconds: now });
  if (rows.length === 0) return null;
  const wrap = el("div", "agents-section quota-agenda");
  const head = el("div", "agents-section-head");
  head.append(el("span", "agents-section-title", t("quotaAgenda.title").toUpperCase()));
  head.append(el("span", "agents-section-meta", t("quotaAgenda.providers", { n: rows.length })));
  wrap.append(head);
  rows.slice(0, ROW_LIMIT).forEach((row) =>
    wrap.append(agendaRow(row, now, options.onProviderSelect)));
  const hidden = rows.slice(ROW_LIMIT);
  if (hidden.length > 0) {
    const more = el("button", "agents-more-row quota-agenda-more", t("quotaAgenda.more", { n: hidden.length }));
    more.setAttribute("type", "button");
    more.addEventListener("click", () => options.onProviderSelect(hidden[0].providerId));
    wrap.append(more);
  }
  return wrap;
}

export function quotaAgendaSlot(
  statuses: readonly ProviderStatus[],
  options: QuotaAgendaSectionOptions,
): HTMLElement {
  const slot = el("div", "quota-agenda-slot");
  refreshQuotaAgendaSlot(slot, statuses, options);
  return slot;
}

export function refreshQuotaAgendaSlot(
  slot: HTMLElement,
  statuses: readonly ProviderStatus[],
  options: QuotaAgendaSectionOptions,
): void {
  const section = quotaAgendaSection(statuses, options);
  slot.replaceChildren(...(section ? [section] : []));
}
