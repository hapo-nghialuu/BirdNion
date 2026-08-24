// Ba khối capability của tab All — port từ macOS (agent-centric remake
// 2026-08-23/24): Quota → Cost by (Agent/Model/Token) → Đã cấu hình.
//
// Quy ước giữ nguyên macOS: mỗi agent chỉ xuất hiện ở khối nó thật sự có dữ
// liệu, mỗi khối cắt ở N dòng rồi gộp phần còn lại vào một dòng "+N", khối
// rỗng thì ẩn hẳn.

import { Combined, CombinedDay, CombinedModel, UsageSourceId, usd, tokensShort } from "./usage";
import { t } from "./i18n";
import { logoMark, logoUrl } from "./logos";
import { showModelsPanel, showAgentPanel, closeTransientPanel } from "./side-panel";
import { buildAgentPanelPayload } from "./agent-panel-payload";
import type { ProviderStatus } from "./provider-tab";

/** 5 nguồn có log chi phí thật (khớp `UsageSourceId`) — agent khác (kiro,
 *  cursor, gemini…) chỉ có quota hoặc config, không có tab Activity. */
const USAGE_SOURCE_IDS: readonly UsageSourceId[] = ["claude", "codex", "grok", "omp", "pi"];
function isUsageSourceId(id: string): id is UsageSourceId {
  return (USAGE_SOURCE_IDS as readonly string[]).includes(id);
}

const QUOTA_ROW_LIMIT = 3;
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

function sectionHead(title: string, trailing?: string): HTMLElement {
  const head = el("div", "agents-section-head");
  head.append(el("span", "agents-section-title", title.toUpperCase()));
  if (trailing) head.append(el("span", "agents-section-meta", trailing));
  return head;
}

// ---------------------------------------------------------------- Quota

/** Danh sách quota trong tab All — thứ tự bám theo tab strip provider,
 *  không sort theo % còn lại (parity macOS `AllUsageOverview.quotaRows`).
 *  `daily` (combined.daily đầy đủ, không windowed) chỉ dùng để widen panel
 *  phụ khi agent này cũng có log chi phí thật (claude/codex/grok/omp/pi). */
export function quotaSection(statuses: ProviderStatus[], daily: CombinedDay[]): HTMLElement | null {
  const rows = statuses
    .map((status) => {
      const window = lowestWindow(status);
      return window ? { status, window } : null;
    })
    .filter((row): row is { status: ProviderStatus; window: QuotaWindowLike } => row != null);
  if (rows.length === 0) return null;

  const wrap = el("div", "agents-section");
  wrap.append(sectionHead(
    t("quota"),
    t("agentsWithQuota", { n: rows.length, total: statuses.length }),
  ));

  for (const row of rows.slice(0, QUOTA_ROW_LIMIT)) {
    wrap.append(quotaRow(row.status, row.window, daily));
  }
  const rest = rows.length - QUOTA_ROW_LIMIT;
  if (rest > 0) {
    wrap.append(el("div", "agents-more-row", t("moreAgentsWithQuota", { n: rest })));
  }
  return wrap;
}

type QuotaWindowLike = { label: string; remainingPct: number };

function lowestWindow(status: ProviderStatus): QuotaWindowLike | null {
  const windows = (status.windows ?? []).filter((w) => Number.isFinite(w.remainingPct));
  if (windows.length === 0) return null;
  return windows.reduce((lowest, w) => (w.remainingPct < lowest.remainingPct ? w : lowest));
}

function quotaRow(status: ProviderStatus, window: QuotaWindowLike, daily: CombinedDay[]): HTMLElement {
  const row = el("div", "agents-row");
  row.append(logoMark(status.id, "agents-row-logo"));
  row.append(el("span", "agents-row-name", status.displayName));
  row.append(el("span", "agents-row-window", window.label.toUpperCase()));

  const track = el("span", "agents-quota-track");
  const fill = el("span", "agents-quota-fill");
  fill.style.width = `${Math.max(0, Math.min(100, window.remainingPct))}%`;
  fill.classList.add(quotaTone(window.remainingPct));
  track.append(fill);
  row.append(track);

  const pct = el("span", `agents-row-pct ${quotaTone(window.remainingPct)}`,
    `${Math.round(window.remainingPct)}%`);
  row.append(pct, el("span", "agents-row-chevron", "›"));

  row.classList.add("is-clickable");
  const source = isUsageSourceId(status.id) ? status.id : undefined;
  const buildPayload = () => buildAgentPanelPayload({
    agentId: status.id,
    displayName: status.displayName,
    quotaWindows: status.windows ?? [],
    daily: source ? daily : undefined,
    source,
    sourceLabel: status.sourceLabel,
    scannedAt: status.lastUpdated,
  });
  row.addEventListener("mouseenter", () => showAgentPanel(buildPayload(), false));
  row.addEventListener("mouseleave", () => closeTransientPanel());
  row.addEventListener("click", () => showAgentPanel(buildPayload(), true));
  return row;
}

function quotaTone(remaining: number): string {
  if (remaining <= 20) return "tone-critical";
  if (remaining <= 50) return "tone-warning";
  return "tone-ok";
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
      node.addEventListener("click", () => {
        showAgentPanel(buildAgentPanelPayload({
          agentId: row.id,
          displayName: row.name,
          daily: combined.daily,
          source: row.id as UsageSourceId,
          sourceLabel: SOURCE_LABEL[row.id as UsageSourceId],
        }));
      });
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
      node.addEventListener("mouseenter", () => showModelsPanel(overflow, mode));
      node.addEventListener("mouseleave", () => closeTransientPanel());
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
  const totals: Record<UsageSourceId, number> = {
    claude: 0, codex: 0, grok: 0, omp: 0, pi: 0, kiro: 0,
  };
  for (const day of window) {
    totals.claude += day.claudeUsd;
    totals.codex += day.codexUsd;
    totals.grok += day.grokUsd;
    totals.omp += day.ompUsd;
    totals.pi += day.piUsd;
  }
  return (Object.keys(totals) as UsageSourceId[])
    .filter((id) => totals[id] > 0)
    .map((id) => ({
      id,
      name: SOURCE_LABEL[id],
      amount: totals[id],
      display: usd(totals[id]),
      css: id,
    }))
    .sort((a, b) => b.amount - a.amount);
}

/** Gộp model thật theo cửa sổ đang chọn; màu chấm theo agent chi phối. */
function modelRows(window: CombinedDay[], mode: CostBreakdownMode): CostRow[] {
  const byName = new Map<string, { usd: number; tokens: number; sources: Map<string, number> }>();
  for (const day of window) {
    for (const model of day.models) {
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

// --------------------------------------------------------- Đã cấu hình

/** Dòng gộp các agent chỉ có cấu hình (không quota, không log chi phí).
 *  Ẩn hẳn khi rỗng — parity macOS `AllAgentsConfiguredSection`. Agent có
 *  brand mark thì dùng logo, còn lại dùng monogram như bản macOS. */
export function configuredSection(agents: ConfiguredAgent[]): HTMLElement | null {
  if (agents.length === 0) return null;
  const wrap = el("div", "agents-section");
  const row = el("div", "agents-row agents-configured-row");
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
  wrap.append(row);
  return wrap;
}

/** Chỉ cần id + tên để vẽ badge — nhận cả `InstalledAgent`. */
export type ConfiguredAgent = { id: string; displayName: string };

function initials(name: string): string {
  const parts = name.trim().split(/\s+/).filter(Boolean);
  if (parts.length === 0) return "?";
  if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase();
  return (parts[0][0] + parts[1][0]).toUpperCase();
}
