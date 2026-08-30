// Khối Cost by với ba chế độ của tab All. Quota Agenda và Đã cấu hình
// nằm ở các module riêng để polling có thể cập nhật capability slots tại chỗ.
//
// Quy ước giữ nguyên macOS: mỗi agent chỉ xuất hiện ở khối nó thật sự có dữ
// liệu, mỗi khối cắt ở N dòng rồi gộp phần còn lại vào một dòng "+N", khối
// rỗng thì ẩn hẳn.

import {
  Combined, CombinedDay, CombinedModel, UsageSourceId,
  USAGE_SOURCE_IDS,
  activeUsageSourceIds, combinedWindowSourceTotals, isKiroSyntheticAggregate,
  usd, tokensShort,
} from "./usage";
import { t } from "./i18n";
import { logoMark } from "./logos";
import { showModelsPanel, showAgentPanel, bindHoverPanel } from "./side-panel";
import { buildAgentPanelPayload } from "./agent-panel-payload";

/** Nguồn có log chi phí thật (khớp `UsageSourceId`) — agent khác như cursor
 * hoặc gemini chỉ có quota/config, không có tab Activity. */
function isUsageSourceId(id: string): id is UsageSourceId {
  return (USAGE_SOURCE_IDS as readonly string[]).includes(id);
}

const COST_ROW_LIMIT = 5;

/** Chế độ của khối "Chi phí theo": theo agent, theo model ($), theo token. */
export type CostBreakdownMode = "agent" | "model" | "token";
const MODE_KEY = "birdnion.costByMode";

export function costByMode(): CostBreakdownMode {
  const raw = localStorage.getItem(MODE_KEY);
  return raw === "model" || raw === "token" ? raw : "agent";
}

export function setCostByMode(mode: CostBreakdownMode): void {
  localStorage.setItem(MODE_KEY, mode);
}

function el(tag: string, className: string, text?: string): HTMLElement {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
}

// ------------------------------------------------------------- Cost by

type CostRow = {
  id: string;
  name: string;
  amount: number;
  display: string;
  css: string;
};

const SOURCE_LABEL: Record<UsageSourceId, string> = {
  claude: "Claude Code",
  codex: "Codex CLI",
  grok: "Grok CLI",
  kiro: "Kiro",
  omp: "Oh My Pi",
  pi: "Pi Agent",
};

/** Khối "Chi phí theo" với 3 chế độ; mọi số tính trong đúng cửa sổ ngày
 *  đang chọn ở chart (parity macOS `AllAgentsCostBreakdownSection`). */
export function costBySection(
  combined: Combined,
  windowDays: number,
  onModeChange: () => void,
): HTMLElement | null {
  const window = combined.daily.slice(-Math.max(1, windowDays));
  const mode = costByMode();
  const rows = mode === "agent" ? agentRows(window) : modelRows(window, mode);
  if (rows.length === 0) return null;

  const wrap = el("div", "agents-section");
  const head = el("div", "agents-section-head");
  head.append(el("span", "agents-section-title", t("costBy").toUpperCase()));
  head.append(modePicker(mode, onModeChange));
  wrap.append(head);

  const total = Math.max(rows.reduce((sum, r) => sum + r.amount, 0), 0.0001);
  wrap.append(shareBar(rows, total));

  for (const row of rows.slice(0, COST_ROW_LIMIT)) {
    const node = costRow(row, total, mode);
    if (mode === "agent") {
      node.classList.add("is-clickable");
      // Khác quota: hàng chi phí có CẢ hover (panel tạm) lẫn click (ghim).
      const payload = () => buildAgentPanelPayload({
        agentId: row.id,
        displayName: row.name,
        daily: combined.daily,
        source: row.id as UsageSourceId,
        sourceLabel: SOURCE_LABEL[row.id as UsageSourceId],
      });
      bindHoverPanel(node, () => showAgentPanel(payload(), "cost", false));
      node.addEventListener("click", () => showAgentPanel(payload(), "cost", true));
    }
    wrap.append(node);
  }
  const rest = rows.slice(COST_ROW_LIMIT);
  if (rest.length > 0) {
    const amount = rest.reduce((sum, r) => sum + r.amount, 0);
    const label = mode === "agent"
      ? t("moreAgents", { n: rest.length })
      : t("moreModels", { n: rest.length });
    const display = mode === "token" ? tokensShort(Math.round(amount)) : usd(amount);
    const node = costRow(
      { id: "rest", name: label, amount, display, css: "muted" }, total, mode);
    if (mode !== "agent") {
      // Hover dòng "+N model khác" mở panel liệt kê toàn bộ model tràn.
      const overflow = overflowModels(window, rest.map((r) => r.id));
      bindHoverPanel(node, () => showModelsPanel(overflow, mode));
    } else {
      // Mode agent: click mở panel của agent bị ẩn đầu tiên (macOS summaryRow).
      const next = rest[0];
      node.classList.add("is-clickable");
      node.addEventListener("click", () => showAgentPanel(
        buildAgentPanelPayload({
          agentId: next.id,
          displayName: next.name,
          daily: isUsageSourceId(next.id) ? combined.daily : undefined,
          source: isUsageSourceId(next.id) ? next.id : undefined,
        }),
        "cost",
        true,
      ));
    }
    wrap.append(node);
  }
  return wrap;
}

/** Model thuộc phần tràn của Cost by — dùng cho panel hover "+N model khác". */
function overflowModels(window: CombinedDay[], names: string[]): CombinedModel[] {
  const wanted = new Set(names);
  const merged = new Map<string, CombinedModel>();
  for (const day of window) {
    for (const model of day.models) {
      if (isKiroSyntheticAggregate(model)) continue;
      if (!wanted.has(model.name)) continue;
      const existing = merged.get(model.name);
      if (existing) {
        existing.usd += model.usd;
        existing.tokens += model.tokens;
      } else {
        merged.set(model.name, { ...model });
      }
    }
  }
  return [...merged.values()];
}

function agentRows(window: CombinedDay[]): CostRow[] {
  const totals = combinedWindowSourceTotals(window);
  return activeUsageSourceIds(window)
    .map((id) => ({
      id,
      name: SOURCE_LABEL[id],
      amount: totals[id].usd,
      display: usd(totals[id].usd),
      css: id,
    }))
    .sort((a, b) => b.amount - a.amount);
}

/** Gộp model thật theo cửa sổ đang chọn; màu chấm theo agent chi phối. */
function modelRows(window: CombinedDay[], mode: CostBreakdownMode): CostRow[] {
  const byName = new Map<string, { usd: number; tokens: number; sources: Map<string, number> }>();
  for (const day of window) {
    for (const model of day.models) {
      if (isKiroSyntheticAggregate(model)) continue;
      const entry = byName.get(model.name)
        ?? { usd: 0, tokens: 0, sources: new Map<string, number>() };
      entry.usd += model.usd;
      entry.tokens += model.tokens;
      entry.sources.set(model.source, (entry.sources.get(model.source) ?? 0) + model.tokens);
      byName.set(model.name, entry);
    }
  }
  return [...byName.entries()]
    .map(([name, entry]) => {
      let css = "muted";
      let best = -1;
      for (const [source, count] of entry.sources) {
        if (count > best) { best = count; css = source; }
      }
      const amount = mode === "token" ? entry.tokens : entry.usd;
      return {
        id: name,
        name: shortModelName(name),
        amount,
        display: mode === "token" ? tokensShort(entry.tokens) : usd(entry.usd),
        css,
      };
    })
    .filter((row) => row.amount > 0)
    .sort((a, b) => b.amount - a.amount);
}

function modePicker(mode: CostBreakdownMode, onChange: () => void): HTMLElement {
  const group = el("div", "agents-mode-picker");
  const modes: { id: CostBreakdownMode; label: string }[] = [
    { id: "agent", label: t("costByAgent") },
    { id: "model", label: t("costByModel") },
    { id: "token", label: t("costByToken") },
  ];
  for (const item of modes) {
    const button = el("button", `agents-mode${mode === item.id ? " is-active" : ""}`,
      item.label.toUpperCase());
    button.addEventListener("click", () => {
      setCostByMode(item.id);
      onChange();
    });
    group.append(button);
  }
  return group;
}

function shareBar(rows: CostRow[], total: number): HTMLElement {
  const bar = el("div", "agents-share-bar");
  for (const row of rows) {
    const seg = el("span", `agents-share-seg tint-${row.css}`);
    seg.style.flexGrow = `${Math.max(row.amount / total, 0.0001)}`;
    bar.append(seg);
  }
  return bar;
}

function costRow(row: CostRow, total: number, mode: CostBreakdownMode): HTMLElement {
  const node = el("div", "agents-row");
  node.append(el("span", `agents-row-tick tint-${row.css}`));
  if (mode === "agent" && row.id !== "rest") {
    node.append(logoMark(row.id, "agents-row-logo"));
  }
  node.append(el("span", "agents-row-name", row.name));
  node.append(el("span", "agents-row-pctmuted",
    `${Math.round((row.amount / total) * 100)}%`));
  node.append(el("span", "agents-row-amount", row.display));
  node.append(el("span", "agents-row-chevron", "›"));
  return node;
}

function shortModelName(name: string): string {
  const trimmed = name.trim();
  const slash = trimmed.lastIndexOf("/");
  return slash >= 0 ? trimmed.slice(slash + 1) : trimmed;
}
