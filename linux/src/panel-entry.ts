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
import type { AgentActivityBlock, AgentActivityDay, AgentPanelPayload } from "./agent-panel-payload";

export const PANEL_PAYLOAD_EVENT = "birdnion-panel-payload";

export type PanelPayload =
  | { kind: "day"; pinned: boolean; day: CombinedDay; windowUsd: number; windowLabel: string }
  | { kind: "models"; models: CombinedModel[]; mode: "model" | "token" }
  | AgentPanelPayload
  | { kind: "activity"; cells: ActivityCell[]; peakUsd: number; avgUsd: number; streak: number };

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

// -------------------------------------------------------- Agent detail panel
// 3 tab Overview / Activity / Config — port của macOS `AgentDetailPanelRoot`
// + `ActivityPanelRoot` (agent-centric remake 2026-08-24). State tab/kỳ/ngày
// chọn sống trong closure của lần render này — payload mới (agent khác) sẽ
// dựng lại từ đầu, giống macOS `@State` reset khi đổi `snapshot`.

type AgentTab = "overview" | "activity" | "config";
const MAX_WEEK_COLUMNS = 23;
const MAX_MODEL_ROWS = 8;
const PERIOD_OPTIONS = [7, 30, 90] as const;

function agentPanel(payload: Extract<PanelPayload, { kind: "agent" }>): HTMLElement {
  const wrap = el("div", "panel-content");
  const hasOverview = payload.overviewRows.length > 0 || payload.activity != null;
  let tab: AgentTab = hasOverview ? "overview" : "config";
  let periodDays: number = 30;
  let selectedDate: string | null = null;

  wrap.append(header(payload.displayName, "", true));

  const tabsEl = el("div", "panel-tabs");
  const bodyEl = el("div", "panel-tab-body");
  wrap.append(tabsEl, bodyEl);

  function paintTabs(): void {
    tabsEl.textContent = "";
    const items: { id: AgentTab; label: string; enabled: boolean }[] = [
      { id: "overview", label: t("insightsOverview"), enabled: hasOverview },
      { id: "activity", label: t("insightsSegmentActivity"), enabled: payload.activity != null },
      { id: "config", label: "Config", enabled: true },
    ];
    for (const item of items) {
      const btn = el("button",
        `panel-tab${tab === item.id ? " is-active" : ""}${!item.enabled ? " is-disabled" : ""}`,
        item.label.toUpperCase());
      if (item.enabled) {
        btn.addEventListener("click", () => {
          if (tab === item.id) return;
          tab = item.id;
          selectedDate = null;
          paintTabs();
          paintBody();
        });
      } else {
        (btn as HTMLButtonElement).disabled = true;
      }
      tabsEl.append(btn);
    }
  }

  function paintBody(): void {
    bodyEl.textContent = "";
    if (tab === "overview") bodyEl.append(overviewTab());
    else if (tab === "activity" && payload.activity) bodyEl.append(activityTab(payload.activity));
    else bodyEl.append(configTab());
  }

  function overviewTab(): HTMLElement {
    const box = el("div", "panel-tab-content");
    if (payload.overviewRows.length > 0) {
      box.append(el("div", "panel-section-title", t("quota").toUpperCase()));
      for (const row of payload.overviewRows) {
        const r = el("div", "panel-row");
        r.append(el("span", "panel-tick tint-muted"));
        r.append(el("span", "panel-row-name", row.label));
        r.append(el("span", "panel-row-value", row.value));
        box.append(r);
      }
    }
    if (payload.activity) box.append(costHero(payload.activity));
    if (payload.overviewRows.length === 0 && !payload.activity) {
      box.append(el("div", "panel-empty", t("agentPanelNoOverview")));
    }
    return box;
  }

  function costHero(activity: AgentActivityBlock): HTMLElement {
    const flat = activity.weeks.flat();
    const windowDays = flat.slice(-periodDays);
    const windowUsd = windowDays.reduce((s, d) => s + d.usd, 0);
    const windowTokens = windowDays.reduce((s, d) => s + d.tokens, 0);
    const today = flat[flat.length - 1];

    const box = el("div", "panel-cost-hero");
    const top = el("div", "panel-cost-hero-top");

    const left = el("div", "panel-cost-hero-col");
    left.append(el("div", "panel-cost-hero-eyebrow",
      t("totalCostPeriod", { period: `${periodDays}d` }).toUpperCase()));
    left.append(el("div", "panel-cost-hero-value", usd(windowUsd)));
    left.append(el("div", "panel-cost-hero-note", tokensLabel(windowTokens)));
    top.append(left);

    const right = el("div", "panel-cost-hero-col panel-cost-hero-col-end");
    right.append(periodPicker());
    right.append(el("div", "panel-cost-hero-eyebrow", t("today").toUpperCase()));
    right.append(el("div", "panel-cost-hero-today", usd(today?.usd ?? 0)));
    top.append(right);
    box.append(top);

    box.append(miniChart(windowDays));

    if (windowDays.length > 0) {
      const range = el("div", "panel-cost-hero-range");
      range.append(el("span", "", dayLabel(windowDays[0].date)));
      range.append(el("span", "", dayLabel(windowDays[windowDays.length - 1].date)));
      box.append(range);
    }

    const filterDay = selectedDate ? windowDays.find((d) => d.date === selectedDate) : undefined;
    const models = aggregateModels(filterDay ? [filterDay] : windowDays);
    if (models.length > 0) box.append(modelsSection(models, filterDay ? dayLabel(filterDay.date) : null));
    return box;
  }

  function periodPicker(): HTMLElement {
    const group = el("div", "panel-period-picker");
    for (const days of PERIOD_OPTIONS) {
      const active = periodDays === days;
      const btn = el("button", `panel-period-btn${active ? " is-active" : ""}`, `${days}d`);
      btn.addEventListener("click", () => {
        if (periodDays === days) return;
        periodDays = days;
        selectedDate = null;
        paintBody();
      });
      group.append(btn);
    }
    return group;
  }

  function miniChart(days: AgentActivityDay[]): HTMLElement {
    const chart = el("div", "panel-mini-chart");
    const max = Math.max(...days.map((d) => d.tokens), 1);
    for (const day of days) {
      const active = day.hasEvidence && day.tokens > 0;
      const bar = el("span",
        `panel-mini-bar${active ? " is-active" : ""}${selectedDate === day.date ? " is-selected" : ""}`);
      const fraction = active ? day.tokens / max : 0;
      bar.style.height = `${Math.max(56 * fraction, active ? 3 : 1)}px`;
      bar.title = day.hasEvidence
        ? `${dayLabel(day.date)}: ${tokensLabel(day.tokens)} · ${usd(day.usd)}`
        : `${dayLabel(day.date)}: ${t("noActivity")}`;
      if (day.hasEvidence) {
        bar.classList.add("is-clickable");
        bar.addEventListener("click", () => {
          selectedDate = selectedDate === day.date ? null : day.date;
          paintBody();
        });
      }
      chart.append(bar);
    }
    return chart;
  }

  function modelsSection(models: CombinedModel[], filterLabel: string | null): HTMLElement {
    const box = el("div", "panel-models-section");
    const title = t("agentPanelModelsTitle").toUpperCase()
      + (filterLabel ? ` · ${filterLabel.toUpperCase()}` : "");
    box.append(el("div", "panel-section-title", title));
    for (const model of models.slice(0, MAX_MODEL_ROWS)) box.append(modelRow(model, "usd"));
    const rest = models.slice(MAX_MODEL_ROWS);
    if (rest.length > 0) {
      const row = el("div", "panel-row");
      row.append(el("span", "panel-tick tint-muted"));
      row.append(el("span", "panel-row-name", t("moreModels", { n: rest.length })));
      row.append(el("span", "panel-row-value",
        `${tokensShort(rest.reduce((s, m) => s + m.tokens, 0))} · ${usd(rest.reduce((s, m) => s + m.usd, 0))}`));
      box.append(row);
    }
    return box;
  }

  function activityTab(activity: AgentActivityBlock): HTMLElement {
    const box = el("div", "panel-tab-content");
    const flat = activity.weeks.flat();
    const firstIdx = activity.weeks.findIndex((week) => week.some((d) => d.hasEvidence));
    const meaningful = firstIdx >= 0
      ? activity.weeks.slice(firstIdx)
      : activity.weeks.slice(-MAX_WEEK_COLUMNS);
    const maxTokens = Math.max(...flat.map((d) => d.tokens), 1);

    const sub = el("div", "panel-activity-sub");
    sub.append(el("span", "panel-activity-sub-label",
      `${t("insightsSegmentActivity").toUpperCase()} · ${meaningful.length} ${t("weeksWord").toUpperCase()}`));
    sub.append(el("span", "panel-activity-sub-total", usd(activity.totalUsd)));
    box.append(sub);

    // Vượt quá MAX_WEEK_COLUMNS thì wrap xuống band tiếp theo — mọi band
    // dùng chung thang màu (maxTokens tính trên cả window).
    for (let i = 0; i < meaningful.length; i += MAX_WEEK_COLUMNS) {
      const band = meaningful.slice(i, i + MAX_WEEK_COLUMNS);
      box.append(heatmapBand(band, maxTokens));
      box.append(rangeRow(band));
    }

    if (selectedDate) {
      const day = flat.find((d) => d.date === selectedDate);
      if (day) {
        box.append(selectedDayRow(day));
        if (day.models.length > 0) {
          const list = el("div", "panel-day-models");
          for (const model of day.models.slice(0, 6)) list.append(modelRow(model, "usd"));
          box.append(list);
        }
      }
    }

    box.append(legendRow());
    box.append(footerStats(activity));
    return box;
  }

  function heatmapBand(weeks: AgentActivityDay[][], maxTokens: number): HTMLElement {
    const row = el("div", "panel-heatband");
    const labels = el("div", "panel-heatband-labels");
    for (const key of ["mon", "", "wed", "", "fri", "", "sun"]) {
      labels.append(el("span", "panel-heatband-weekday", key ? t(`weekday.${key}`) : ""));
    }
    row.append(labels);

    for (const week of weeks) {
      const col = el("div", "panel-heatband-col");
      for (const day of week) {
        const level = day.hasEvidence ? heatLevel(day.tokens, maxTokens) : 0;
        const cell = el("span",
          `panel-heat-cell level-${level}${selectedDate === day.date ? " is-selected" : ""}`);
        cell.title = day.hasEvidence
          ? `${dayLabel(day.date)}: ${tokensLabel(day.tokens)} · ${usd(day.usd)}`
          : `${dayLabel(day.date)}: ${t("noActivity")}`;
        if (day.hasEvidence) {
          cell.classList.add("is-clickable");
          cell.addEventListener("click", () => {
            selectedDate = selectedDate === day.date ? null : day.date;
            paintBody();
          });
        }
        col.append(cell);
      }
      row.append(col);
    }
    return row;
  }

  function rangeRow(weeks: AgentActivityDay[][]): HTMLElement {
    const row = el("div", "panel-heatband-range");
    const firstWeek = weeks[0];
    const lastWeek = weeks[weeks.length - 1];
    row.append(el("span", "", firstWeek ? dayLabel(firstWeek[0].date) : ""));
    row.append(el("span", "", lastWeek ? dayLabel(lastWeek[lastWeek.length - 1].date) : ""));
    return row;
  }

  function selectedDayRow(day: AgentActivityDay): HTMLElement {
    const row = el("div", "panel-row panel-day-detail");
    row.append(el("span", "panel-tick tint-muted"));
    row.append(el("span", "panel-row-name", dayLabel(day.date)));
    row.append(el("span", "panel-row-value",
      day.hasEvidence ? `${tokensLabel(day.tokens)} · ${usd(day.usd)}` : t("noActivity")));
    return row;
  }

  function legendRow(): HTMLElement {
    const row = el("div", "panel-legend");
    row.append(el("span", "panel-legend-label", t("less")));
    const swatches = el("span", "panel-legend-swatches");
    for (let level = 0; level <= 4; level++) {
      swatches.append(el("span", `panel-heat-cell panel-legend-cell level-${level}`));
    }
    row.append(swatches);
    row.append(el("span", "panel-legend-label", t("more")));
    row.append(el("span", "panel-legend-note", t("shadedByTokens")));
    return row;
  }

  function footerStats(activity: AgentActivityBlock): HTMLElement {
    const row = el("div", "panel-stats");
    row.append(statCell(t("peakDay"), usd(activity.peakUsd)));
    row.append(statCell(t("avgPerActiveDay"), usd(activity.avgUsd)));

    const streakCell = el("div", "panel-stat");
    streakCell.append(el("span", "panel-stat-label", t("streak").toUpperCase()));
    streakCell.append(el("span", "panel-stat-value panel-stat-streak",
      `${activity.currentStreak} ${t("daysWord")}`));
    if (activity.currentStreak > 0) {
      if (activity.currentStreak >= activity.longestStreak) {
        streakCell.append(el("span", "panel-streak-record", t("agentPanelStreakRecord").toUpperCase()));
      } else {
        const remain = activity.longestStreak - activity.currentStreak + 1;
        streakCell.append(el("span", "panel-streak-countdown",
          t("agentPanelStreakCountdown", { n: remain, best: activity.longestStreak }).toUpperCase()));
      }
    }
    row.append(streakCell);
    return row;
  }

  function configTab(): HTMLElement {
    const box = el("div", "panel-tab-content");
    if (payload.configRows.length === 0) {
      box.append(el("div", "panel-empty", t("agentPanelNoConfig")));
      return box;
    }
    for (const row of payload.configRows) {
      const item = el("div", "panel-config-row");
      item.append(el("div", "panel-config-label", row.label));
      item.append(el("div", "panel-config-value", row.value));
      box.append(item);
    }
    return box;
  }

  paintTabs();
  paintBody();
  return wrap;
}

/** Gộp model theo danh sách ngày đang xét (window hoặc 1 ngày filter) —
 *  parity macOS `AgentDetailPanelRoot.windowModels`. */
function aggregateModels(days: AgentActivityDay[]): CombinedModel[] {
  const totals = new Map<string, CombinedModel>();
  for (const day of days) {
    for (const model of day.models) {
      const existing = totals.get(model.name);
      if (existing) { existing.usd += model.usd; existing.tokens += model.tokens; }
      else totals.set(model.name, { ...model });
    }
  }
  return [...totals.values()].sort((a, b) => (b.tokens - a.tokens) || (b.usd - a.usd));
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
