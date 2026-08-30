import { t } from "./i18n";
import { logoMark } from "./logos";
import { settingsIcon } from "./settings-icons";
import type { QuotaAgendaRow } from "./quota-agenda";

export const QUOTA_AGENDA_PROVIDER_SELECTED_EVENT =
  "birdnion-quota-agenda-provider-selected";

export type QuotaAgendaProviderSelectedPayload = { providerId: string };

export type QuotaAgendaPanelPayload = {
  kind: "quotaAgenda";
  rows: QuotaAgendaRow[];
};

export type QuotaAgendaPanelActions = {
  onClose: () => void | Promise<void>;
  onProviderSelect: (providerId: string) => void | Promise<void>;
};

const ROW_LIMIT = 3;

function el(tag: string, className: string, text?: string): HTMLElement {
  const node = document.createElement(tag);
  node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function runPanelAction(action: () => void | Promise<void>): void {
  try {
    void Promise.resolve(action()).catch(() => {});
  } catch {
    // The companion panel is auxiliary; event failures stay contained.
  }
}

function countdown(resetAt: number, now: number): string {
  const minutes = Math.max(1, Math.ceil((resetAt - now) / 60));
  if (minutes >= 1440) {
    return `${Math.floor(minutes / 1440)}d ${Math.floor(minutes % 1440 / 60)}h`;
  }
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

function account(row: QuotaAgendaRow): string {
  if (row.accountHidden) return t("quotaAgenda.accountHidden");
  return row.accountLabel ?? t("quotaAgenda.accountUnknown");
}

function remaining(row: QuotaAgendaRow): { value: string; className: string } {
  const value = row.remainingPct == null
    ? "—"
    : `${Math.round(row.remainingPct)}%${row.percentageKind === "lastKnown" ? "*" : ""}`;
  const tone = row.remainingPct == null ? ""
    : row.remainingPct <= 20 ? " tone-critical"
      : row.remainingPct <= 50 ? " tone-warning" : " tone-ok";
  return { value, className: `quota-agenda-percent is-${row.percentageKind}${tone}` };
}

function accessibilityLabel(row: QuotaAgendaRow, now: number): string {
  const amount = row.remainingPct == null
    ? t("quotaAgenda.percentageUnavailable")
    : row.percentageKind === "lastKnown"
      ? `${t("quotaAgenda.lastKnown")} ${Math.round(row.remainingPct)}%`
      : `${Math.round(row.remainingPct)}%`;
  return [
    row.agentName,
    row.providerName,
    row.windowLabel,
    amount,
    resetState(row, now),
    row.sourceLabel ?? t("quotaAgenda.sourceUnknown"),
    account(row),
    freshness(row.observedAt, now),
  ].join(", ");
}

function agendaRow(
  row: QuotaAgendaRow,
  now: number,
  onSelect: (providerId: string) => void | Promise<void>,
): HTMLElement {
  const button = el("button", `quota-agenda-row is-${row.state}`);
  button.setAttribute("type", "button");
  button.setAttribute("aria-label", accessibilityLabel(row, now));
  button.append(logoMark(row.providerId, "quota-agenda-logo"));

  const identity = el("span", "quota-agenda-identity");
  identity.append(el("span", "quota-agenda-agent", row.agentName));
  if (row.agentName !== row.providerName) {
    identity.append(el("span", "quota-agenda-provider", `· ${row.providerName}`));
  }

  const amount = remaining(row);
  const percent = el("span", amount.className, amount.value);
  if (row.percentageKind === "lastKnown") percent.title = t("quotaAgenda.lastKnown");

  const reset = el("span", "quota-agenda-reset-line");
  reset.append(
    el("span", "quota-agenda-window", row.windowLabel.toUpperCase()),
    el("span", `quota-agenda-reset is-${row.state}`, resetState(row, now)),
  );
  const meta = el("span", "quota-agenda-meta");
  meta.title = [
    row.sourceLabel ?? t("quotaAgenda.sourceUnknown"),
    account(row),
    freshness(row.observedAt, now),
  ].join(" · ");
  meta.append(
    el("span", "quota-agenda-source", row.sourceLabel ?? t("quotaAgenda.sourceUnknown")),
    el("span", "quota-agenda-account", account(row)),
    el("span", "quota-agenda-freshness", freshness(row.observedAt, now)),
  );
  button.append(identity, percent, reset, meta, el("span", "quota-agenda-chevron", "›"));
  button.addEventListener("click", () => runPanelAction(() => onSelect(row.providerId)));
  return button;
}

function panelHeader(count: number, onClose: () => void | Promise<void>): HTMLElement {
  const head = el("div", "panel-head quota-agenda-panel-head");
  head.append(settingsIcon("calendar", "quota-agenda-panel-icon"));
  const text = el("div", "panel-head-text");
  text.append(
    el("div", "panel-title", t("quotaAgenda.title")),
    el("div", "panel-subtitle", t("quotaAgenda.withData", { n: count })),
  );
  const close = el("button", "panel-close", "✕");
  close.setAttribute("type", "button");
  close.title = t("quotaAgenda.close");
  close.setAttribute("aria-label", t("quotaAgenda.close"));
  close.addEventListener("click", () => runPanelAction(onClose));
  head.append(text, close);
  return head;
}

export function quotaAgendaPanel(
  payload: QuotaAgendaPanelPayload,
  actions: QuotaAgendaPanelActions,
  now = Date.now() / 1000,
): HTMLElement {
  const wrap = el("div", "panel-content quota-agenda-panel");
  wrap.append(panelHeader(payload.rows.length, actions.onClose));
  if (payload.rows.length === 0) {
    const empty = el("div", "quota-agenda-empty");
    empty.append(settingsIcon("calendar", "quota-agenda-empty-icon"));
    empty.append(
      el("div", "quota-agenda-empty-title", t("quotaAgenda.emptyTitle")),
      el("div", "quota-agenda-empty-body", t("quotaAgenda.emptyBody")),
    );
    wrap.append(empty);
  } else {
    payload.rows.slice(0, ROW_LIMIT).forEach((row) =>
      wrap.append(agendaRow(row, now, actions.onProviderSelect)));
    const hidden = payload.rows.slice(ROW_LIMIT);
    if (hidden.length > 0) {
      const more = el("button", "quota-agenda-more", t("quotaAgenda.more", { n: hidden.length }));
      more.setAttribute("type", "button");
      more.addEventListener("click", () =>
        runPanelAction(() => actions.onProviderSelect(hidden[0].providerId)));
      wrap.append(more);
    }
  }
  wrap.append(el("div", "quota-agenda-trust", t("quotaAgenda.explicitOnly")));
  return wrap;
}

/** Selection order is contractual: hide the companion panel first, then
 * notify the main webview. */
export async function selectQuotaAgendaProvider(
  providerId: string,
  closePanel: () => void | Promise<void>,
  notifyMain: (payload: QuotaAgendaProviderSelectedPayload) => void | Promise<void>,
): Promise<void> {
  await closePanel();
  await notifyMain({ providerId });
}
