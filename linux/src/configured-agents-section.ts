import { t } from "./i18n";
import { logoMark, logoUrl } from "./logos";
import { buildAgentPanelPayload } from "./agent-panel-payload";
import { showAgentPanel } from "./side-panel";

/** Chỉ cần id + tên để vẽ badge — nhận cả `InstalledAgent`. */
export type ConfiguredAgent = { id: string; displayName: string };

function el(tag: string, className: string, text?: string): HTMLElement {
  const node = document.createElement(tag);
  node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function initials(name: string): string {
  const parts = name.trim().split(/\s+/).filter(Boolean);
  if (parts.length === 0) return "?";
  if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase();
  return (parts[0][0] + parts[1][0]).toUpperCase();
}

/** Dòng gộp các agent chỉ có cấu hình (không quota, không log chi phí). */
export function configuredAgentsSection(
  agents: readonly ConfiguredAgent[],
): HTMLElement | null {
  if (agents.length === 0) return null;
  const wrap = el("div", "agents-section");
  const row = el("div", "agents-row agents-configured-row is-clickable");
  row.append(el("span", "agents-section-title", t("configured").toUpperCase()));
  const badges = el("span", "agents-configured-badges");
  for (const agent of agents.slice(0, 4)) {
    badges.append(logoUrl(agent.id)
      ? logoMark(agent.id, "agents-configured-logo")
      : el("span", "agents-configured-badge", initials(agent.displayName)));
  }
  row.append(badges);
  row.append(el("span", "agents-row-meta", t("configuredNoLogs", { n: agents.length })));
  row.append(el("span", "agents-row-chevron", "›"));
  const first = agents[0];
  row.addEventListener("click", () => showAgentPanel(
    buildAgentPanelPayload({ agentId: first.id, displayName: first.displayName }), "config", true));
  wrap.append(row);
  return wrap;
}

/** Stable slot lets provider polling move an agent between Agenda/configured. */
export function configuredAgentsSlot(agents: readonly ConfiguredAgent[]): HTMLElement {
  const slot = el("div", "configured-agents-slot");
  refreshConfiguredAgentsSlot(slot, agents);
  return slot;
}

export function refreshConfiguredAgentsSlot(
  slot: HTMLElement,
  agents: readonly ConfiguredAgent[],
): void {
  const section = configuredAgentsSection(agents);
  slot.replaceChildren(...(section ? [section] : []));
}
