// Cửa sổ panel phụ cạnh popover — port của macOS `AgentDetailPanelCoordinator`
// (NSPanel con). Bốn loại nội dung: chi tiết ngày, chi tiết agent, hoạt động
// 52 tuần, và danh sách model tràn.
//
// Vòng đời giữ nguyên semantics macOS: hover mở panel transient, click ghim;
// panel đã ghim không bị hover khác chiếm chỗ, chỉ đóng bằng nút ✕.

import { getCurrentWindow } from "@tauri-apps/api/window";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { t } from "./i18n";
import { logoMark } from "./logos";
import { usd, tokens as tokensLabel, tokensShort, dayLabel } from "./usage";
import type { CombinedDay, CombinedModel } from "./usage";
import type { AgentCostDay, AgentPanelPayload, AgentQuotaWindow, AgentTabId } from "./agent-panel-payload";

export const PANEL_PAYLOAD_EVENT = "birdnion-panel-payload";

export type PanelPayload =
  | { kind: "day"; pinned: boolean; day: CombinedDay; windowUsd: number; windowLabel: string }
  | { kind: "models"; models: CombinedModel[]; mode: "model" | "token" }
  | AgentPanelPayload
  | {
      kind: "activity";
      cells: ActivityCell[];
      peakUsd: number;
      avgUsd: number;
      streak: number;
      longestStreak: number;
    };

export type ActivityCell = {
  date: string;
  usd: number;
  tokens: number;
  /** Model dùng trong ngày — hiện khi click ô (macOS `selectedDayModels`). */
  models?: CombinedModel[];
};

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
    // Qua command chứ không hide() thẳng: popover cần biết để bỏ cờ ghim.
    close.addEventListener("click", () => {
      void invoke("close_side_panel").catch(() => { void getCurrentWindow().hide(); });
    });
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
// 3 tab THẬT: Quota / Chi phí (Cost) / Config — port của macOS
// `AgentDetailPanelRoot` (đọc lại Swift làm nguồn sự thật 2026-08-24, sửa lại
// cấu trúc tab SAI của bản trước — KHÔNG có tab Activity ở đây; banded
// heatmap thuộc `activityPanel()` riêng bên dưới). State tab/kỳ/ngày chọn
// sống trong closure của lần render này — payload mới (agent khác) sẽ dựng
// lại từ đầu, giống macOS `@State` reset khi đổi `snapshot`.

const MAX_WEEK_COLUMNS = 23;
const MAX_MODEL_ROWS = 8;
const PERIOD_OPTIONS = [7, 30, 90] as const;

function agentPanel(payload: Extract<PanelPayload, { kind: "agent" }>): HTMLElement {
  const wrap = el("div", "panel-content");
  const hasQuota = payload.quotaWindows.length > 0;
  const hasCost = payload.costDays != null;

  // Tab mở đầu theo nguồn click, fallback theo capability (cost → quota →
  // config) — parity macOS `AgentDetailPanelRoot.onAppear`.
  let tab: AgentTabId;
  if (payload.initialTab === "quota" && hasQuota) tab = "quota";
  else if (payload.initialTab === "cost" && hasCost) tab = "cost";
  else if (payload.initialTab === "config") tab = "config";
  else if (hasCost) tab = "cost";
  else if (hasQuota) tab = "quota";
  else tab = "config";

  let periodDays: number = 30;
  let selectedDate: string | null = null;

  wrap.append(header(payload.displayName, "", true));

  const tabsEl = el("div", "panel-tabs");
  const bodyEl = el("div", "panel-tab-body");
  wrap.append(tabsEl, bodyEl);

  function paintTabs(): void {
    tabsEl.textContent = "";
    // Tab disabled vẫn hiện (nhãn suffix "— không"/"— none") — không ẩn đi,
    // giống macOS `tabBar` (Config luôn enabled).
    const items: { id: AgentTabId; label: string; enabled: boolean }[] = [
      { id: "quota", label: hasQuota ? t("quota") : t("agentPanelQuotaDisabled"), enabled: hasQuota },
      { id: "cost", label: hasCost ? t("cost") : t("agentPanelCostDisabled"), enabled: hasCost },
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
    if (tab === "quota") bodyEl.append(quotaTab());
    else if (tab === "cost" && payload.costDays) bodyEl.append(costTab(payload.costDays));
    else bodyEl.append(configTab());
  }

  // ---- Quota tab: mỗi window = label + bar 56×3 + % phải (đỏ dưới 20%) —
  // parity macOS `quotaTabContent`. Không có window nào thì hiện dòng
  // "Không có quota trực tiếp." thay vì vẽ bar rỗng (không fabricate).
  function quotaTab(): HTMLElement {
    const box = el("div", "panel-tab-content");
    if (payload.quotaWindows.length > 0) {
      box.append(el("div", "panel-section-title", t("agentPanelCurrentQuota").toUpperCase()));
      for (const win of payload.quotaWindows) box.append(quotaWindowRow(win));
    } else {
      box.append(el("div", "panel-empty", t("agentPanelNoQuota")));
    }
    return box;
  }

  function quotaWindowRow(win: AgentQuotaWindow): HTMLElement {
    const tone = win.remainingPct < 20 ? "tone-critical" : "tone-ok";
    const row = el("div", "panel-quota-row");
    row.append(el("span", "panel-quota-label", win.label.toUpperCase()));
    const track = el("span", "panel-quota-track");
    const fill = el("span", `panel-quota-fill ${tone}`);
    fill.style.width = `${Math.max(0, Math.min(100, win.remainingPct))}%`;
    track.append(fill);
    row.append(track);
    row.append(el("span", `panel-quota-pct ${tone}`, `${Math.round(win.remainingPct)}%`));
    return row;
  }

  // ---- Cost tab: hero (7/30/90d) + mini chart + model list, cùng bám theo
  // period đang chọn — parity macOS `costTabContent`. SOURCE + LOCAL LOG
  // KHÔNG nằm ở đây, chúng thuộc tab Config.
  function costTab(days: AgentCostDay[]): HTMLElement {
    const box = el("div", "panel-tab-content");
    box.append(costHero(days));
    return box;
  }

  function costHero(days: AgentCostDay[]): HTMLElement {
    const windowDays = days.slice(-periodDays);
    const windowUsd = windowDays.reduce((s, d) => s + d.usd, 0);
    const windowTokens = windowDays.reduce((s, d) => s + d.tokens, 0);
    const today = days[days.length - 1];

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

  function miniChart(days: AgentCostDay[]): HTMLElement {
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
function aggregateModels(days: AgentCostDay[]): CombinedModel[] {
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

// ------------------------------------------------------------ Activity panel
// Banded heatmap 23-cột/band, thang màu chung, streak spotlight + stats
// footer — mở từ hàng stats của chart tab All (KHÔNG phải tab của agent
// panel; đọc lại Swift `ActivityPanelRoot` làm nguồn sự thật 2026-08-24).

/** Ô trong lưới hoạt động — `models` chỉ có ở ngày thật, ô đệm để trống. */
type DayCell = { date: string; usd: number; tokens: number; models?: CombinedModel[] };

function activityPanel(payload: Extract<PanelPayload, { kind: "activity" }>): HTMLElement {
  const wrap = el("div", "panel-content");
  const weeks = toActivityWeeks(payload.cells);
  const activeDays = payload.cells.filter((c) => c.usd > 0 || c.tokens > 0).length;

  wrap.append(header(t("insightsSegmentActivity"),
    `${weeks.length} ${t("weeksWord").toUpperCase()} · ${activeDays} ${t("activeDaysWord").toUpperCase()}`,
    true));

  const bodyEl = el("div", "panel-tab-content");
  wrap.append(bodyEl);

  let selectedDate: string | null = null;

  function paint(): void {
    bodyEl.textContent = "";
    // Heatmap bắt đầu từ tuần có dữ liệu đầu tiên — không vẽ cả window trống.
    const meaningful = meaningfulActivityWeeks(weeks);
    const flat = meaningful.flat();
    const totalUsd = payload.cells.reduce((s, c) => s + c.usd, 0);

    const sub = el("div", "panel-activity-sub");
    sub.append(el("span", "panel-activity-sub-label",
      `${t("insightsSegmentActivity").toUpperCase()} · ${meaningful.length} ${t("weeksWord").toUpperCase()}`));
    sub.append(el("span", "panel-activity-sub-total", usd(totalUsd)));
    bodyEl.append(sub);

    const maxTokens = Math.max(...flat.map((d) => d.tokens), 1);
    // Vượt quá MAX_WEEK_COLUMNS thì wrap xuống band tiếp theo — mọi band
    // dùng chung thang màu (maxTokens tính trên cả window).
    for (let i = 0; i < meaningful.length; i += MAX_WEEK_COLUMNS) {
      const band = meaningful.slice(i, i + MAX_WEEK_COLUMNS);
      bodyEl.append(heatmapBand(band, maxTokens, selectedDate, (date) => {
        selectedDate = selectedDate === date ? null : date;
        paint();
      }));
      bodyEl.append(heatmapRangeRow(band));
    }

    if (selectedDate) {
      const day = flat.find((d) => d.date === selectedDate);
      if (day) {
        bodyEl.append(heatmapSelectedDayRow(day));
        // Click ô còn liệt kê model của đúng ngày đó (macOS parity), tối đa 6
        // dòng rồi gộp phần dư — panel cao tự động nên không được dài vô hạn.
        const models = [...(day.models ?? [])].sort((a, b) => b.tokens - a.tokens);
        for (const model of models.slice(0, 6)) bodyEl.append(modelRow(model, "usd"));
        if (models.length > 6) {
          bodyEl.append(el("div", "panel-row-more",
            t("moreModels", { n: models.length - 6 })));
        }
      }
    }

    bodyEl.append(heatmapLegendRow());
    bodyEl.append(activityFooterStats(payload.peakUsd, payload.avgUsd, payload.streak, payload.longestStreak));
  }

  paint();
  return wrap;
}

function addDays(dateStr: string, delta: number): string {
  const d = new Date(dateStr + "T12:00:00");
  d.setDate(d.getDate() + delta);
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}

/** 0 = Thứ 2 … 6 = Chủ nhật (ISO), khác `Date#getDay()` vốn 0 = Chủ nhật. */
function mondayIndex(dateStr: string): number {
  const dow = new Date(dateStr + "T12:00:00").getDay();
  return (dow + 6) % 7;
}

/** Đệm đầu/cuối cho đủ tuần Thứ 2 → CN rồi cắt thành từng tuần 7 ngày. Ô đệm
 *  dùng ngày thật nhưng usd/tokens=0 (không fabricate, chỉ để lưới thẳng
 *  hàng thứ — giống ô đệm không bằng chứng của macOS `weekBands`). */
function toActivityWeeks(days: DayCell[]): DayCell[][] {
  if (days.length === 0) return [];
  const leadPad = mondayIndex(days[0].date);
  const lead: DayCell[] = [];
  for (let i = leadPad; i > 0; i--) lead.push({ date: addDays(days[0].date, -i), usd: 0, tokens: 0 });
  const last = days[days.length - 1];
  const trailPad = 6 - mondayIndex(last.date);
  const trail: DayCell[] = [];
  for (let i = 1; i <= trailPad; i++) trail.push({ date: addDays(last.date, i), usd: 0, tokens: 0 });
  const full = [...lead, ...days, ...trail];
  const weeks: DayCell[][] = [];
  for (let i = 0; i < full.length; i += 7) weeks.push(full.slice(i, i + 7));
  return weeks;
}

function meaningfulActivityWeeks(weeks: DayCell[][]): DayCell[][] {
  const firstIdx = weeks.findIndex((week) => week.some((d) => d.usd > 0 || d.tokens > 0));
  return firstIdx >= 0 ? weeks.slice(firstIdx) : weeks.slice(-MAX_WEEK_COLUMNS);
}

function heatmapBand(
  weeks: DayCell[][],
  maxTokens: number,
  selectedDate: string | null,
  onSelect: (date: string) => void,
): HTMLElement {
  const row = el("div", "panel-heatband");
  const labels = el("div", "panel-heatband-labels");
  for (const key of ["mon", "", "wed", "", "fri", "", "sun"]) {
    labels.append(el("span", "panel-heatband-weekday", key ? t(`weekday.${key}`) : ""));
  }
  row.append(labels);

  for (const week of weeks) {
    const col = el("div", "panel-heatband-col");
    for (const day of week) {
      const active = day.usd > 0 || day.tokens > 0;
      const level = active ? heatLevel(day.tokens, maxTokens) : 0;
      const cell = el("span",
        `panel-heat-cell level-${level}${selectedDate === day.date ? " is-selected" : ""}`);
      cell.title = active
        ? `${dayLabel(day.date)}: ${tokensLabel(day.tokens)} · ${usd(day.usd)}`
        : `${dayLabel(day.date)}: ${t("noActivity")}`;
      if (active) {
        cell.classList.add("is-clickable");
        cell.addEventListener("click", () => onSelect(day.date));
      }
      col.append(cell);
    }
    row.append(col);
  }
  return row;
}

function heatmapRangeRow(weeks: DayCell[][]): HTMLElement {
  const row = el("div", "panel-heatband-range");
  const firstWeek = weeks[0];
  const lastWeek = weeks[weeks.length - 1];
  row.append(el("span", "", firstWeek ? dayLabel(firstWeek[0].date) : ""));
  row.append(el("span", "", lastWeek ? dayLabel(lastWeek[lastWeek.length - 1].date) : ""));
  return row;
}

function heatmapSelectedDayRow(day: DayCell): HTMLElement {
  const active = day.usd > 0 || day.tokens > 0;
  const row = el("div", "panel-row panel-day-detail");
  row.append(el("span", "panel-tick tint-muted"));
  row.append(el("span", "panel-row-name", dayLabel(day.date)));
  row.append(el("span", "panel-row-value",
    active ? `${tokensLabel(day.tokens)} · ${usd(day.usd)}` : t("noActivity")));
  return row;
}

function heatmapLegendRow(): HTMLElement {
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

function activityFooterStats(
  peakUsd: number,
  avgUsd: number,
  currentStreak: number,
  longestStreak: number,
): HTMLElement {
  const row = el("div", "panel-stats");
  row.append(statCell(t("peakDay"), usd(peakUsd)));
  row.append(statCell(t("avgPerActiveDay"), usd(avgUsd)));

  const streakCell = el("div", "panel-stat");
  streakCell.append(el("span", "panel-stat-label", t("streak").toUpperCase()));
  streakCell.append(el("span", "panel-stat-value panel-stat-streak",
    `${currentStreak} ${t("daysWord")}`));
  if (currentStreak > 0) {
    if (currentStreak >= longestStreak) {
      streakCell.append(el("span", "panel-streak-record", t("agentPanelStreakRecord").toUpperCase()));
    } else {
      const remain = longestStreak - currentStreak + 1;
      streakCell.append(el("span", "panel-streak-countdown",
        t("agentPanelStreakCountdown", { n: remain, best: longestStreak }).toUpperCase()));
    }
  }
  row.append(streakCell);
  return row;
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

/** Khớp cửa sổ với chiều cao nội dung — port của macOS `refitToContent`.
 *
 *  Dùng `ResizeObserver` thay vì gọi tay sau mỗi lần render: nội dung còn đổi
 *  chiều cao khi chuyển tab, chọn ngày hay đổi kỳ bên trong panel, nên bám vào
 *  chính kích thước thật là chắc nhất. Rust chặn trên theo màn hình. */
let lastRequestedHeight = 0;
function fitWindowToContent(root: HTMLElement): void {
  const height = Math.ceil(root.scrollHeight);
  if (height <= 0 || Math.abs(height - lastRequestedHeight) < 2) return;
  lastRequestedHeight = height;
  void invoke("resize_side_panel", { height }).catch(() => { /* phụ trợ */ });
}

const panelRoot = document.getElementById("panel");
if (panelRoot && typeof ResizeObserver !== "undefined") {
  new ResizeObserver(() => fitWindowToContent(panelRoot)).observe(panelRoot);
}

void listen<PanelPayload>(PANEL_PAYLOAD_EVENT, (event) => render(event.payload));

// Payload đầu tiên được nhét sẵn khi cửa sổ mở (tránh nháy trống).
const seeded = (window as unknown as { __BIRDNION_PANEL__?: PanelPayload }).__BIRDNION_PANEL__;
if (seeded) render(seeded);
