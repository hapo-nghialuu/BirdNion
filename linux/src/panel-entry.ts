// Cửa sổ panel phụ cạnh popover — port của macOS `AgentDetailPanelCoordinator`
// (NSPanel con). Bốn loại nội dung: chi tiết ngày, chi tiết agent, hoạt động
// 52 tuần, và danh sách model tràn.
//
// Vòng đời giữ nguyên semantics macOS: hover mở panel transient, click ghim;
// panel đã ghim không bị hover khác chiếm chỗ, chỉ đóng bằng nút ✕.

import { getCurrentWindow } from "@tauri-apps/api/window";
import { listen } from "@tauri-apps/api/event";
import { t } from "./i18n";
import { logoMark } from "./logos";
import { usd, tokens as tokensLabel, tokensShort, dayLabel } from "./usage";
import type { CombinedDay, CombinedModel } from "./usage";

export const PANEL_PAYLOAD_EVENT = "birdnion-panel-payload";

export type PanelPayload =
  | { kind: "day"; pinned: boolean; day: CombinedDay; windowUsd: number; windowLabel: string }
  | { kind: "models"; models: CombinedModel[]; mode: "model" | "token" }
  | { kind: "agent"; agentId: string; displayName: string; rows: AgentPanelRow[] }
  | { kind: "activity"; cells: ActivityCell[]; peakUsd: number; avgUsd: number; streak: number };

export type AgentPanelRow = { label: string; value: string };
export type ActivityCell = { date: string; usd: number; tokens: number };

function el(tag: string, className: string, text?: string): HTMLElement {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
}

function header(title: string, subtitle: string, pinned: boolean): HTMLElement {
  const head = el("div", "panel-head");
  const col = el("div", "panel-head-text");
  col.append(el("div", "panel-title", title));
  if (subtitle) col.append(el("div", "panel-subtitle", subtitle));
  head.append(col);
  if (pinned) {
    const close = el("button", "panel-close", "✕");
    close.addEventListener("click", () => { void getCurrentWindow().hide(); });
    head.append(close);
  } else {
    head.append(el("span", "panel-hint", t("clickToPin")));
  }
  return head;
}

function modelRow(model: CombinedModel, mode: "usd" | "token"): HTMLElement {
  const row = el("div", "panel-row");
  row.append(el("span", `panel-tick tint-${model.source}`));
  row.append(el("span", "panel-row-name", shortModelName(model.name)));
  row.append(el("span", "panel-row-value",
    mode === "token"
      ? tokensShort(model.tokens)
      : `${tokensShort(model.tokens)} · ${usd(model.usd)}`));
  return row;
}

function shortModelName(name: string): string {
  const slash = name.lastIndexOf("/");
  return slash >= 0 ? name.slice(slash + 1) : name;
}

/** Chi tiết một ngày: hero + phân bổ theo agent + danh sách model. */
function dayPanel(payload: Extract<PanelPayload, { kind: "day" }>): HTMLElement {
  const wrap = el("div", "panel-content");
  const share = payload.windowUsd > 0
    ? `${Math.round((payload.day.usd / payload.windowUsd) * 100)}% ${t("ofPeriod")} ${payload.windowLabel}`
    : "";
  wrap.append(header(dayLabel(payload.day.date),
    `${tokensLabel(payload.day.tokens)}${share ? ` · ${share}` : ""}`, payload.pinned));

  const hero = el("div", "panel-hero", usd(payload.day.usd));
  wrap.append(hero);

  const agents: { id: string; label: string; usd: number; tokens: number }[] = [
    { id: "claude", label: "Claude Code", usd: payload.day.claudeUsd, tokens: payload.day.claudeTokens },
    { id: "codex", label: "Codex CLI", usd: payload.day.codexUsd, tokens: payload.day.codexTokens },
    { id: "grok", label: "Grok CLI", usd: payload.day.grokUsd, tokens: payload.day.grokTokens },
    { id: "omp", label: "Oh My Pi", usd: payload.day.ompUsd, tokens: payload.day.ompTokens },
    { id: "pi", label: "Pi Agent", usd: payload.day.piUsd, tokens: payload.day.piTokens },
  ].filter((a) => a.usd > 0 || a.tokens > 0).sort((a, b) => b.usd - a.usd);

  if (agents.length > 0) {
    wrap.append(el("div", "panel-section-title", t("costByAgent").toUpperCase()));
    for (const agent of agents) {
      const row = el("div", "panel-row");
      row.append(el("span", `panel-tick tint-${agent.id}`));
      row.append(logoMark(agent.id, "panel-row-logo"));
      row.append(el("span", "panel-row-name", agent.label));
      row.append(el("span", "panel-row-value",
        `${tokensShort(agent.tokens)} · ${usd(agent.usd)}`));
      wrap.append(row);
    }
  }

  const models = [...payload.day.models].sort((a, b) => b.usd - a.usd);
  if (models.length > 0) {
    wrap.append(el("div", "panel-section-title",
      `${t("costByModel").toUpperCase()} (${models.length})`));
    for (const model of models.slice(0, 10)) wrap.append(modelRow(model, "usd"));
  }
  return wrap;
}

function modelsPanel(payload: Extract<PanelPayload, { kind: "models" }>): HTMLElement {
  const wrap = el("div", "panel-content");
  wrap.append(header(t("moreModels", { n: payload.models.length }), "", false));
  const sorted = [...payload.models].sort((a, b) =>
    payload.mode === "token" ? b.tokens - a.tokens : b.usd - a.usd);
  for (const model of sorted) wrap.append(modelRow(model, "usd"));
  return wrap;
}

function agentPanel(payload: Extract<PanelPayload, { kind: "agent" }>): HTMLElement {
  const wrap = el("div", "panel-content");
  wrap.append(header(payload.displayName, "", true));
  for (const row of payload.rows) {
    const node = el("div", "panel-row");
    node.append(el("span", "panel-row-name", row.label));
    node.append(el("span", "panel-row-value", row.value));
    wrap.append(node);
  }
  return wrap;
}

function activityPanel(payload: Extract<PanelPayload, { kind: "activity" }>): HTMLElement {
  const wrap = el("div", "panel-content");
  const activeDays = payload.cells.filter((c) => c.tokens > 0).length;
  wrap.append(header(t("insightsSegmentActivity"),
    `${activeDays} ${t("activeDaysWord")}`, true));

  const max = Math.max(...payload.cells.map((c) => c.tokens), 1);
  const grid = el("div", "panel-heat");
  for (const cell of payload.cells) {
    const box = el("span", `panel-heat-cell level-${heatLevel(cell.tokens, max)}`);
    box.title = cell.tokens > 0
      ? `${cell.date}: ${tokensLabel(cell.tokens)} · ${usd(cell.usd)}`
      : `${cell.date}: ${t("noActivity")}`;
    grid.append(box);
  }
  wrap.append(grid);

  const stats = el("div", "panel-stats");
  stats.append(statCell(t("peakDay"), usd(payload.peakUsd)));
  stats.append(statCell(t("avgPerActiveDay"), usd(payload.avgUsd)));
  stats.append(statCell(t("streak"), `${payload.streak} ${t("daysWord")}`));
  wrap.append(stats);
  return wrap;
}

function statCell(label: string, value: string): HTMLElement {
  const cell = el("div", "panel-stat");
  cell.append(el("span", "panel-stat-label", label.toUpperCase()));
  cell.append(el("span", "panel-stat-value", value));
  return cell;
}

function heatLevel(tokenCount: number, max: number): number {
  if (tokenCount <= 0) return 0;
  const fraction = tokenCount / max;
  if (fraction <= 0.25) return 1;
  if (fraction <= 0.5) return 2;
  if (fraction <= 0.75) return 3;
  return 4;
}

function render(payload: PanelPayload): void {
  const root = document.getElementById("panel");
  if (!root) return;
  root.textContent = "";
  switch (payload.kind) {
    case "day": root.append(dayPanel(payload)); break;
    case "models": root.append(modelsPanel(payload)); break;
    case "agent": root.append(agentPanel(payload)); break;
    case "activity": root.append(activityPanel(payload)); break;
  }
}

void listen<PanelPayload>(PANEL_PAYLOAD_EVENT, (event) => render(event.payload));

// Payload đầu tiên được nhét sẵn khi cửa sổ mở (tránh nháy trống).
const seeded = (window as unknown as { __BIRDNION_PANEL__?: PanelPayload }).__BIRDNION_PANEL__;
if (seeded) render(seeded);
