// Settings → Agent: bảng liệt kê agent phát hiện được trên máy cùng
// capability (quota / chi phí / config) và chi phí 90 ngày.
// Port từ macOS `AgentsPane` + `AgentInventoryRow` (remake 2026-08-23).
//
// Nguồn dữ liệu: catalog agent từ backend (`list_installed_agents`) + trạng
// thái provider + báo cáo cost đã quét. Hàng nào bật hiển thị xếp lên trước,
// rồi tới agent có chi phí thật, còn lại theo A→Z (parity macOS).

import { invoke } from "@tauri-apps/api/core";
import { t } from "./i18n";
import { logoMark } from "./logos";
import { usd } from "./usage";

export type InstalledAgent = {
  id: string;
  displayName: string;
  kind: string;
  sourceLabel: string;
  hasQuota: boolean;
  hasCost: boolean;
  hasConfig: boolean;
  cost90dUsd: number | null;
};

const VISIBILITY_KEY = "birdnion.agentVisibility";
type Filter = "all" | "quota" | "cost" | "config";

function el(tag: string, className: string, text?: string): HTMLElement {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
}

function hiddenIds(): Set<string> {
  try {
    const raw = localStorage.getItem(VISIBILITY_KEY);
    return new Set(raw ? (JSON.parse(raw) as string[]) : []);
  } catch {
    return new Set();
  }
}

function setHidden(id: string, hidden: boolean): void {
  const set = hiddenIds();
  if (hidden) set.add(id); else set.delete(id);
  localStorage.setItem(VISIBILITY_KEY, JSON.stringify([...set]));
}

/** Visibility chỉ ảnh hưởng hiển thị trong popover — scanner và tổng chi phí
 *  giữ nguyên (đúng semantics macOS `InstalledAgentVisibilityStore`). */
export function visibleAgentIds(all: InstalledAgent[]): string[] {
  const hidden = hiddenIds();
  return all.map((a) => a.id).filter((id) => !hidden.has(id));
}

export async function agentsPane(): Promise<HTMLElement> {
  const page = el("div", "settings-page");
  const header = el("div", "sw-pane-header");
  const textCol = el("div", "sw-pane-header-text");
  textCol.append(el("div", "sw-pane-title", t("settingsTabAgents")));
  textCol.append(el("div", "sw-pane-subtitle", t("settingsAgentsSubtitle")));
  header.append(textCol);
  page.append(header);

  let agents: InstalledAgent[] = [];
  try {
    agents = await invoke<InstalledAgent[]>("list_installed_agents");
  } catch {
    agents = [];
  }

  let filter: Filter = "all";
  let query = "";

  const controls = el("div", "agents-controls");
  const search = document.createElement("input");
  search.type = "search";
  search.className = "agents-search";
  search.placeholder = t("agentsSearch");
  search.addEventListener("input", () => { query = search.value.trim().toLowerCase(); paint(); });
  controls.append(search);

  const filterRow = el("div", "agents-filters");
  controls.append(filterRow);
  page.append(controls);

  const table = el("div", "agents-table");
  page.append(table);

  function counts() {
    return {
      all: agents.length,
      quota: agents.filter((a) => a.hasQuota).length,
      cost: agents.filter((a) => a.hasCost).length,
      config: agents.filter((a) => !a.hasQuota && !a.hasCost).length,
    };
  }

  function matches(agent: InstalledAgent): boolean {
    if (query && !agent.displayName.toLowerCase().includes(query)
      && !agent.id.toLowerCase().includes(query)) return false;
    if (filter === "quota") return agent.hasQuota;
    if (filter === "cost") return agent.hasCost;
    if (filter === "config") return !agent.hasQuota && !agent.hasCost;
    return true;
  }

  /** Agent đang bật lên trước, rồi agent có chi phí thật, còn lại A→Z. */
  function sorted(list: InstalledAgent[]): InstalledAgent[] {
    const hidden = hiddenIds();
    return [...list].sort((a, b) => {
      const av = hidden.has(a.id) ? 0 : 1;
      const bv = hidden.has(b.id) ? 0 : 1;
      if (av !== bv) return bv - av;
      const ac = (a.cost90dUsd ?? 0) > 0 ? 1 : 0;
      const bc = (b.cost90dUsd ?? 0) > 0 ? 1 : 0;
      if (ac !== bc) return bc - ac;
      return a.displayName.localeCompare(b.displayName);
    });
  }

  function paint(): void {
    const c = counts();
    filterRow.textContent = "";
    const options: { id: Filter; label: string }[] = [
      { id: "all", label: t("agentsFilterAll", { n: c.all }) },
      { id: "quota", label: t("agentsFilterQuota", { n: c.quota }) },
      { id: "cost", label: t("agentsFilterCost", { n: c.cost }) },
      { id: "config", label: t("agentsFilterConfig", { n: c.config }) },
    ];
    for (const option of options) {
      const chip = el("button",
        `agents-filter${filter === option.id ? " is-active" : ""}`,
        option.label.toUpperCase());
      chip.addEventListener("click", () => { filter = option.id; paint(); });
      filterRow.append(chip);
    }

    table.textContent = "";
    table.append(tableHead());
    const rows = sorted(agents.filter(matches));
    if (rows.length === 0) {
      table.append(el("div", "empty", t("agentsEmpty")));
      return;
    }
    for (const agent of rows) table.append(agentRow(agent, paint));
  }

  paint();
  return page;
}

function tableHead(): HTMLElement {
  const head = el("div", "agents-thead");
  head.append(el("span", "agents-th agents-th-show", t("agentsColShow")));
  head.append(el("span", "agents-th agents-th-name", t("agentsColAgent")));
  head.append(el("span", "agents-th agents-th-source", t("agentsColSource")));
  head.append(el("span", "agents-th agents-th-data", t("agentsColData")));
  head.append(el("span", "agents-th agents-th-cost", t("agentsCol90d")));
  return head;
}

function agentRow(agent: InstalledAgent, onChange: () => void): HTMLElement {
  const row = el("div", "agents-trow");
  const hidden = hiddenIds().has(agent.id);

  const toggle = el("button", `agents-switch${hidden ? "" : " is-on"}`);
  toggle.append(el("span", "agents-switch-knob"));
  toggle.addEventListener("click", () => {
    setHidden(agent.id, !hidden);
    onChange();
  });
  row.append(toggle);

  const nameCell = el("span", "agents-name-cell");
  nameCell.append(logoMark(agent.id, "agents-row-logo agents-row-logo-lg"));
  const nameCol = el("span", "agents-name-col");
  nameCol.append(el("span", "agents-name", agent.displayName));
  nameCol.append(el("span", "agents-kind", agent.kind.toUpperCase()));
  nameCell.append(nameCol);
  row.append(nameCell);

  row.append(el("span", "agents-source", agent.sourceLabel));

  const data = el("span", "agents-data");
  data.append(badge("Quota", agent.hasQuota));
  data.append(badge("Cost", agent.hasCost));
  data.append(badge("Config", agent.hasConfig));
  row.append(data);

  row.append(el("span", "agents-cost",
    agent.cost90dUsd != null ? usd(agent.cost90dUsd) : "—"));
  return row;
}

function badge(label: string, active: boolean): HTMLElement {
  return el("span", `agents-badge${active ? " is-active" : ""}`, label.toUpperCase());
}
